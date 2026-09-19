/**
 * Server-authoritative entitlement state.
 *
 * Everything here is a PURE function over the stored document plus a
 * store-VERIFIED fact, so the rules that decide who may translate — and for
 * how long — are unit-testable and can never be influenced by what the client
 * claims. The client never writes these fields: they live in a collection the
 * security rules make read-only for the owner and writable only by the Admin
 * SDK (Cloud Functions).
 */

import {
  FREE_LIFETIME_MINUTES,
  Plan,
  minutesForPlan,
  planForProductId,
} from "./plans.js";

export type Store = "apple" | "google";

/**
 * Mirrors the meaningful store states. Only "active" and "grace" grant the
 * paid allowance; everything else falls back to whatever is left of the free
 * lifetime minutes.
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
  /** Epoch ms. */
  currentPeriodStart: number | null;
  currentPeriodEnd: number | null;
  /** Included minutes for the CURRENT paid period. */
  minutesAllowance: number;
  /** Fractional minutes consumed in the current paid period. */
  minutesUsed: number;
  /** Fractional minutes consumed against the one-time free allowance. */
  freeMinutesUsed: number;
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

export function freshEntitlement(nowMs: number): Entitlement {
  return {
    plan: "free",
    subscriptionStatus: "none",
    store: null,
    storeProductId: null,
    currentPeriodStart: null,
    currentPeriodEnd: null,
    minutesAllowance: 0,
    minutesUsed: 0,
    freeMinutesUsed: 0,
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
  remainingMinutes: number;
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
 * bucket". A lapsed subscriber falls back to whatever free minutes they never
 * used, which is normally zero — so they see the paywall.
 */
export function accessFor(entitlement: Entitlement, nowMs: number): Access {
  if (paidIsLive(entitlement, nowMs)) {
    const remaining = entitlement.minutesAllowance - entitlement.minutesUsed;
    return {
      allowed: remaining > 0,
      source: "plan",
      remainingMinutes: Math.max(0, remaining),
      plan: entitlement.plan,
    };
  }
  const remaining = FREE_LIFETIME_MINUTES - entitlement.freeMinutesUsed;
  return {
    allowed: remaining > 0,
    source: "free",
    remainingMinutes: Math.max(0, remaining),
    plan: "free",
  };
}

/**
 * Charges [seconds] of live translation to the right bucket. Returns the new
 * entitlement — never mutates. Charging is always additive and clamped, so a
 * replay can overcharge at worst by the capped tick, never grant minutes.
 */
export function chargeSeconds(
  entitlement: Entitlement,
  seconds: number,
  nowMs: number,
): Entitlement {
  if (!(seconds > 0)) return entitlement;
  const minutes = seconds / 60;
  const source = accessFor(entitlement, nowMs).source;
  if (source === "plan") {
    return {
      ...entitlement,
      minutesUsed: entitlement.minutesUsed + minutes,
      entitlementUpdatedAt: nowMs,
    };
  }
  return {
    ...entitlement,
    freeMinutesUsed: entitlement.freeMinutesUsed + minutes,
    entitlementUpdatedAt: nowMs,
  };
}

/** A fact established by Apple or Google — never by the client. */
export interface VerifiedSubscription {
  store: Store;
  productId: string;
  status: SubscriptionStatus;
  /** Epoch ms. */
  periodStart: number;
  periodEnd: number;
  /**
   * Stable id for THIS state change (Apple transactionId / Google orderId,
   * suffixed by the notification id where one exists). Used for idempotency.
   */
  eventId: string;
}

export interface ApplyResult {
  entitlement: Entitlement;
  /** False when the event had already been applied. */
  changed: boolean;
  /** True when a new billing period reset the used minutes. */
  periodAdvanced: boolean;
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

  // A lost subscription keeps its history but grants nothing; the user falls
  // back to their unused free minutes via accessFor().
  if (verified.status === "expired" || verified.status === "revoked") {
    return {
      entitlement: {
        ...entitlement,
        plan,
        subscriptionStatus: verified.status,
        store: verified.store,
        storeProductId: verified.productId,
        currentPeriodStart: verified.periodStart,
        currentPeriodEnd: verified.periodEnd,
        minutesAllowance: 0,
        entitlementUpdatedAt: nowMs,
        appliedEventIds,
      },
      changed: true,
      periodAdvanced: false,
    };
  }

  // A NEW billing period (renewal, or a switch that re-based the period)
  // resets usage. Unused minutes never roll over: the allowance is replaced,
  // not added to.
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
      currentPeriodStart: verified.periodStart,
      currentPeriodEnd: verified.periodEnd,
      minutesAllowance: minutesForPlan(plan),
      minutesUsed: periodAdvanced ? 0 : entitlement.minutesUsed,
      entitlementUpdatedAt: nowMs,
      appliedEventIds,
    },
    changed: true,
    periodAdvanced: periodAdvanced || planChanged,
  };
}
