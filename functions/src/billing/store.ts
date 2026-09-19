/**
 * Firestore persistence for entitlements, usage sessions and purchase
 * ownership.
 *
 * All three collections are written ONLY by the Admin SDK here. Security rules
 * let a user READ their own entitlement (so the app can show the plan) and
 * give the client no write access at all — putting these under users/{uid}
 * would have exposed them, because that subtree is client-writable.
 */

import { createHash } from "node:crypto";

import { getFirestore, Firestore, Timestamp } from "firebase-admin/firestore";

import {
  Entitlement,
  VerifiedSubscription,
  accessFor,
  applyVerifiedSubscription,
  chargeSpeechMs,
  freshEntitlement,
} from "./entitlement.js";
import {
  SessionTelemetry,
  SpeechReport,
  UsageSession,
  applySpeechReport,
  closeSession,
  isStale,
  newSession,
  sanitizeTelemetry,
} from "./usage.js";

export const ENTITLEMENTS = "entitlements";
export const USAGE_SESSIONS = "usageSessions";
export const SUBSCRIPTION_OWNERS = "subscriptionOwners";

/** Raised when a purchase already belongs to a different account. */
export class PurchaseOwnershipError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "PurchaseOwnershipError";
  }
}

let db: Firestore | null = null;
function firestore(): Firestore {
  db ??= getFirestore();
  return db;
}

/**
 * Test seam. Production never calls this: the default is the real Admin SDK
 * instance, which is the only thing allowed to write these collections.
 */
export function useFirestoreForTests(instance: Firestore | null): void {
  db = instance;
}

/**
 * Document id for a purchase handle. Hashed because Play purchase tokens are
 * long and are credentials in their own right — the id ends up in logs and
 * exports, the raw token should not.
 */
export function ownerKey(store: string, handle: string): string {
  return `${store}_${createHash("sha256").update(handle).digest("hex").slice(0, 40)}`;
}

function toEntitlement(data: FirebaseFirestore.DocumentData | undefined, nowMs: number): Entitlement {
  if (!data) return freshEntitlement(nowMs);
  return {
    plan: data.plan ?? "free",
    subscriptionStatus: data.subscriptionStatus ?? "none",
    store: data.store ?? null,
    storeProductId: data.storeProductId ?? null,
    storeHandle: data.storeHandle ?? null,
    currentPeriodStart: data.currentPeriodStart ?? null,
    currentPeriodEnd: data.currentPeriodEnd ?? null,
    allowanceMs: data.allowanceMs ?? 0,
    usedMs: data.usedMs ?? 0,
    freeUsedMs: data.freeUsedMs ?? 0,
    entitlementUpdatedAt: data.entitlementUpdatedAt ?? nowMs,
    appliedEventIds: data.appliedEventIds ?? [],
  };
}

/**
 * The stored shape. The derived fields are written alongside the raw ones so
 * the app, which streams this document and never computes entitlement itself,
 * has the answer rather than a puzzle.
 */
function toDocument(entitlement: Entitlement, nowMs: number) {
  const access = accessFor(entitlement, nowMs);
  return {
    ...entitlement,
    allowanceSource: access.source,
    remainingMs: access.remainingMs,
    // Convenience for the client, which only ever READS this document.
    updatedAt: Timestamp.now(),
  };
}

/** Reads the entitlement, creating the free-tier default on first sight. */
export async function readEntitlement(
  uid: string,
  nowMs: number,
): Promise<Entitlement> {
  const snapshot = await firestore().collection(ENTITLEMENTS).doc(uid).get();
  return toEntitlement(snapshot.data(), nowMs);
}

/**
 * Applies a store-verified subscription inside a transaction, so two
 * concurrent webhooks or purchases cannot both reset a period — and so the
 * ownership claim on the purchase handle is atomic.
 *
 * A purchase belongs to whichever account claims it first. A second account
 * presenting the same Apple original transaction id or Play purchase token is
 * refused, which is what stops one paid subscription being shared around.
 */
export async function applyVerified(
  uid: string,
  verified: VerifiedSubscription,
  nowMs: number,
): Promise<Entitlement> {
  const entitlementRef = firestore().collection(ENTITLEMENTS).doc(uid);
  const ownerRef = firestore()
    .collection(SUBSCRIPTION_OWNERS)
    .doc(ownerKey(verified.store, verified.handle));

  return firestore().runTransaction(async (tx) => {
    // Every read before any write: Firestore transactions require it.
    const [snapshot, ownerSnapshot] = await Promise.all([
      tx.get(entitlementRef),
      tx.get(ownerRef),
    ]);

    const owner = ownerSnapshot.data();
    if (owner && owner.uid !== uid) {
      throw new PurchaseOwnershipError(
        "That subscription is already attached to another Sayvo account.",
      );
    }

    const current = toEntitlement(snapshot.data(), nowMs);
    const result = applyVerifiedSubscription(current, verified, nowMs);

    if (!owner) {
      tx.set(ownerRef, {
        uid,
        store: verified.store,
        productId: verified.productId,
        claimedAt: Timestamp.now(),
      });
    }
    if (result.changed) {
      tx.set(entitlementRef, toDocument(result.entitlement, nowMs), { merge: true });
    }
    return result.entitlement;
  });
}

/** The account that owns a purchase handle, or null if unclaimed. */
export async function ownerOfPurchase(
  store: string,
  handle: string,
): Promise<string | null> {
  const snapshot = await firestore()
    .collection(SUBSCRIPTION_OWNERS)
    .doc(ownerKey(store, handle))
    .get();
  const data = snapshot.data();
  return typeof data?.uid === "string" ? data.uid : null;
}

export interface SessionStart {
  sessionId: string;
  remainingMs: number;
}

/**
 * Opens a metered session if the user has translated-speech allowance left.
 * Sessions left open by a crashed client are closed first — they cost nothing,
 * because nothing is charged without an accepted report.
 */
export async function openSession(
  uid: string,
  sessionId: string,
  nowMs: number,
): Promise<SessionStart | null> {
  await settleStaleSessions(uid, nowMs);

  const entitlementRef = firestore().collection(ENTITLEMENTS).doc(uid);
  const sessionRef = firestore().collection(USAGE_SESSIONS).doc(sessionId);

  return firestore().runTransaction(async (tx) => {
    const snapshot = await tx.get(entitlementRef);
    const entitlement = toEntitlement(snapshot.data(), nowMs);
    const access = accessFor(entitlement, nowMs);
    if (!access.allowed) return null;

    // Persist the default free entitlement on first use so the lifetime
    // allowance exists server-side from the very first session.
    if (!snapshot.exists) {
      tx.set(entitlementRef, toDocument(entitlement, nowMs), { merge: true });
    }
    tx.set(sessionRef, newSession(uid, nowMs));
    return { sessionId, remainingMs: access.remainingMs };
  });
}

export interface SessionCharge {
  remainingMs: number;
  allowanceMs: number;
  usedMs: number;
  allowed: boolean;
  /** What this report actually cost, after replay and clamping rules. */
  chargedMs: number;
  status: string;
}

/**
 * Accepts a cumulative translated-speech report for a session and says what is
 * left. Server clock only, and every anti-replay rule lives in
 * [applySpeechReport].
 */
export async function reportSpeech(
  uid: string,
  sessionId: string,
  report: SpeechReport,
  nowMs: number,
  telemetry?: Partial<SessionTelemetry>,
): Promise<SessionCharge> {
  const entitlementRef = firestore().collection(ENTITLEMENTS).doc(uid);
  const sessionRef = firestore().collection(USAGE_SESSIONS).doc(sessionId);

  return firestore().runTransaction(async (tx) => {
    const [sessionSnap, entitlementSnap] = await Promise.all([
      tx.get(sessionRef),
      tx.get(entitlementRef),
    ]);
    const entitlement = toEntitlement(entitlementSnap.data(), nowMs);
    const data = sessionSnap.data() as UsageSession | undefined;

    // Unknown session, or one belonging to somebody else: charge nothing and
    // report the caller's real balance.
    if (!data || data.uid !== uid) {
      const access = accessFor(entitlement, nowMs);
      return {
        remainingMs: access.remainingMs,
        allowanceMs: access.allowanceMs,
        usedMs: access.usedMs,
        allowed: access.allowed,
        chargedMs: 0,
        status: "unknown-session",
      };
    }

    const outcome = applySpeechReport(data, report, nowMs);
    const charge = chargeSpeechMs(entitlement, outcome.chargeMs, nowMs);

    const sessionChanged =
      outcome.chargeMs > 0 ||
      outcome.session.lastSequence !== data.lastSequence ||
      outcome.session.closed !== data.closed;
    if (sessionChanged) {
      const sessionDoc: Record<string, unknown> = { ...outcome.session };
      if (report.close === true) {
        sessionDoc.telemetry = sanitizeTelemetry(telemetry, data, nowMs);
        sessionDoc.endedAt = nowMs;
      }
      tx.set(sessionRef, sessionDoc);
    }
    if (charge.chargedMs > 0) {
      tx.set(entitlementRef, toDocument(charge.entitlement, nowMs), { merge: true });
    }

    const access = accessFor(charge.entitlement, nowMs);
    return {
      remainingMs: access.remainingMs,
      allowanceMs: access.allowanceMs,
      usedMs: access.usedMs,
      allowed: access.allowed,
      chargedMs: charge.chargedMs,
      status: outcome.status,
    };
  });
}

/**
 * Closes sessions a client abandoned without ending them. Nothing is charged:
 * an abandoned session only ever cost what it had already reported.
 */
export async function settleStaleSessions(uid: string, nowMs: number): Promise<void> {
  const open = await firestore()
    .collection(USAGE_SESSIONS)
    .where("uid", "==", uid)
    .where("closed", "==", false)
    .limit(10)
    .get();

  for (const doc of open.docs) {
    const session = doc.data() as UsageSession;
    if (!isStale(session, nowMs)) continue;
    await firestore()
      .collection(USAGE_SESSIONS)
      .doc(doc.id)
      .set(closeSession(session, nowMs));
  }
}
