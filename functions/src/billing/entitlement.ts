/**
 * Server-authoritative entitlement state.
 *
 * Everything here is a PURE function over the stored document plus a
 * store-VERIFIED fact, so the rules that decide who may translate — and for
 * how long — are unit-testable and can never be influenced by what the client
 * claims. The client never writes these fields: they live in a collection the
 * security rules make read-only for the owner and writable only by the Admin
 * SDK (Cloud Functions).
 *
 * The unit of account is a MILLISECOND OF TRANSLATED SPEECH. It is not
 * microphone wall-clock time: a ten-minute session in a quiet room costs
 * nothing. See usage.ts for what counts as translated speech.
 */

import {
  FREE_LIFETIME_MS,
  Plan,
  allowanceMsForPlan,
  planForProductId,
} from "./plans.js";

export type Store = "apple" | "google";

/**
 * Mirrors the meaningful store states. Only "active" and "grace" grant the
 * paid allowance; everything else falls back to whatever is left of the free
 * lifetime allowance.
 */
export type SubscriptionStatus =
  | "none"
  | "active"
  | "grace"
  | "expired"
  | "revoked";

export interface Entitlement {
  plan: Plan;
  subscriptionStatus: SubscriptionStatus;
  store: Store | null;
  storeProductId: string | null;
  /**
   * The opaque handle the store gave us for this subscription (Apple original
   * transaction id / Play purchase token). Kept so the server can ask the
   * store again when a period ends, instead of waiting for the app to.
   */
  storeHandle: string | null;
  /** Epoch ms. */
  currentPeriodStart: number | null;
  currentPeriodEnd: number | null;
  /** Included translated-speech milliseconds for the CURRENT paid period. */
  allowanceMs: number;
  /** Translated-speech milliseconds consumed in the current paid period. */
  usedMs: number;
  /** Translated-speech milliseconds consumed against the free allowance. */
  freeUsedMs: number;
  entitlementUpdatedAt: number;
  /**
   * Store event/transaction identifiers already applied. Makes every
   * entitlement update idempotent: a replayed webhook or a double-submitted
   * purchase changes nothing.
   */
  appliedEventIds: string[];
}

/** How many applied ids to keep (bounded so the document cannot grow forever). */
const MAX_APPLIED_EVENT_IDS = 50;

/**
 * How far past the allowance a single accepted report may push usage, so that
 * a sentence already being translated can finish rather than being cut off
 * mid-way. Strictly bounded: it is a courtesy, not an overrun budget.
 */
export const OVERRUN_GRACE_MS = 15_000;

export function freshEntitlement(nowMs: number): Entitlement {
  return {
    plan: "free",
    subscriptionStatus: "none",
    store: null,
    storeProductId: null,
    storeHandle: null,
    currentPeriodStart: null,
    currentPeriodEnd: null,
    allowanceMs: 0,
    usedMs: 0,
    freeUsedMs: 0,
    entitlementUpdatedAt: nowMs,
    appliedEventIds: [],
  };
}

/** Which allowance a session is charged against right now. */
export type AllowanceSource = "plan" | "free";

export interface Access {
  allowed: boolean;
  source: AllowanceSource;
  /** Never negative. */
  remainingMs: number;
  /** The allowance in force, so the client can render a progress bar. */
  allowanceMs: number;
  usedMs: number;
  plan: Plan;
}

function paidIsLive(entitlement: Entitlement, nowMs: number): boolean {
  if (entitlement.plan === "free") return false;
  if (
    entitlement.subscriptionStatus !== "active" &&
    entitlement.subscriptionStatus !== "grace"
  ) {
    return false;
  }
  // An entitlement that has run past its period is not live, even if a
  // renewal notification has not reached us yet.
  return entitlement.currentPeriodEnd === null || nowMs < entitlement.currentPeriodEnd;
}

/**
 * The single authority on "may this user start translating, and against which
 * bucket". A lapsed subscriber falls back to whatever free allowance they
 * never used, which is normally zero — so they see the paywall.
 */
export function accessFor(entitlement: Entitlement, nowMs: number): Access {
  if (paidIsLive(entitlement, nowMs)) {
    const remaining = entitlement.allowanceMs - entitlement.usedMs;
    return {
      allowed: remaining > 0,
      source: "plan",
      remainingMs: Math.max(0, remaining),
      allowanceMs: entitlement.allowanceMs,
      usedMs: entitlement.usedMs,
      plan: entitlement.plan,
    };
  }
  const remaining = FREE_LIFETIME_MS - entitlement.freeUsedMs;
  return {
    allowed: remaining > 0,
    source: "free",
    remainingMs: Math.max(0, remaining),
    allowanceMs: FREE_LIFETIME_MS,
    usedMs: entitlement.freeUsedMs,
    plan: "free",
  };
}

export interface ChargeResult {
  entitlement: Entitlement;
  /** What was actually taken off the allowance, after the grace clamp. */
  chargedMs: number;
}

/**
 * Charges [speechMs] of TRANSLATED SPEECH to the right bucket. Returns the new
 * entitlement — never mutates.
 *
 * Charging is additive and clamped: usage can never decrease, and a single
 * charge can never push usage more than [OVERRUN_GRACE_MS] past the allowance,
 * so no one long utterance can walk through the cap.
 */
export function chargeSpeechMs(
  entitlement: Entitlement,
  speechMs: number,
  nowMs: number,
): ChargeResult {
  if (!(speechMs > 0)) return { entitlement, chargedMs: 0 };
  const access = accessFor(entitlement, nowMs);
  // Bounded overrun: TOTAL usage may reach the allowance plus a small grace,
  // so a sentence in flight can finish. The grace is a ceiling on the whole
  // period, not a fresh allowance handed out on every report.
  const headroom = Math.max(
    0,
    access.allowanceMs + OVERRUN_GRACE_MS - access.usedMs,
  );
  const chargedMs = Math.min(speechMs, headroom);
  if (chargedMs <= 0) return { entitlement, chargedMs: 0 };
  if (access.source === "plan") {
    return {
      entitlement: {
        ...entitlement,
        usedMs: entitlement.usedMs + chargedMs,
        entitlementUpdatedAt: nowMs,
      },
      chargedMs,
    };
  }
  return {
    entitlement: {
      ...entitlement,
      freeUsedMs: entitlement.freeUsedMs + chargedMs,
      entitlementUpdatedAt: nowMs,
    },
    chargedMs,
  };
}

/** A fact established by Apple or Google — never by the client. */
export interface VerifiedSubscription {
  store: Store;
  productId: string;
  status: SubscriptionStatus;
  /**
   * The handle to ask the store about this subscription again: Apple's
   * ORIGINAL transaction id, or Play's purchase token. Both survive renewals,
   * so the server can re-check a lapsed period on its own.
   */
  handle: string;
  /** Epoch ms. */
  periodStart: number;
  periodEnd: number;
  /**
   * Stable id for THIS state change (Apple transactionId / Google orderId,
   * suffixed by the notification id where one exists). Used for idempotency.
   */
  eventId: string;
  /**
   * The account identifier the store recorded with the purchase, when there
   * is one (Apple appAccountToken / Google obfuscatedExternalAccountId).
   */
  accountToken?: string | null;
  /**
   * Google only: whether Play has the purchase acknowledged. Undefined means
   * the acknowledgement attempt did not come back OK and should be retried.
   */
  acknowledged?: boolean;
}

export interface ApplyResult {
  entitlement: Entitlement;
  /** False when the event had already been applied. */
  changed: boolean;
  /** True when a new billing period reset the used allowance. */
  periodAdvanced: boolean;
}

/** Statuses that grant nothing: the paid allowance goes to zero. */
function grantsNothing(status: SubscriptionStatus): boolean {
  // "none" is Play's PENDING state — a purchase that has not been paid for.
  return status === "expired" || status === "revoked" || status === "none";
}

/**
 * Applies a STORE-VERIFIED subscription state.
 *
 * Idempotent by [VerifiedSubscription.eventId]: replaying a webhook, or a
 * client submitting the same receipt twice, is a no-op. A product id we do
 * not sell is ignored rather than trusted.
 */
export function applyVerifiedSubscription(
  entitlement: Entitlement,
  verified: VerifiedSubscription,
  nowMs: number,
): ApplyResult {
  if (entitlement.appliedEventIds.includes(verified.eventId)) {
    return { entitlement, changed: false, periodAdvanced: false };
  }

  const plan = planForProductId(verified.productId);
  if (plan === null) {
    // Not one of our products — never grant anything for it.
    return { entitlement, changed: false, periodAdvanced: false };
  }

  const appliedEventIds = [...entitlement.appliedEventIds, verified.eventId].slice(
    -MAX_APPLIED_EVENT_IDS,
  );

  // A lost or unpaid subscription keeps its history but grants nothing; the
  // user falls back to their unused free allowance via accessFor().
  if (grantsNothing(verified.status)) {
    return {
      entitlement: {
        ...entitlement,
        plan,
        subscriptionStatus: verified.status,
        store: verified.store,
        storeProductId: verified.productId,
        storeHandle: verified.handle,
        currentPeriodStart: verified.periodStart,
        currentPeriodEnd: verified.periodEnd,
        allowanceMs: 0,
        entitlementUpdatedAt: nowMs,
        appliedEventIds,
      },
      changed: true,
      periodAdvanced: false,
    };
  }

  // A NEW billing period (renewal, or a switch that re-based the period)
  // resets usage. Unused allowance never rolls over: it is replaced, not
  // added to.
  const periodAdvanced =
    entitlement.currentPeriodStart === null ||
    verified.periodStart > entitlement.currentPeriodStart;
  // An upgrade/downgrade inside the same period re-bases the allowance to the
  // new plan while keeping what has already been used.
  const planChanged = entitlement.plan !== plan;

  return {
    entitlement: {
      ...entitlement,
      plan,
      subscriptionStatus: verified.status,
      store: verified.store,
      storeProductId: verified.productId,
      storeHandle: verified.handle,
      currentPeriodStart: verified.periodStart,
      currentPeriodEnd: verified.periodEnd,
      allowanceMs: allowanceMsForPlan(plan),
      usedMs: periodAdvanced ? 0 : entitlement.usedMs,
      entitlementUpdatedAt: nowMs,
      appliedEventIds,
    },
    changed: true,
    periodAdvanced: periodAdvanced || planChanged,
  };
}
