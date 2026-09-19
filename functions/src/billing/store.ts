/**
 * Firestore persistence for entitlements and usage sessions.
 *
 * Both collections are written ONLY by the Admin SDK here. Security rules let
 * a user READ their own entitlement (so the app can show the plan) and give
 * the client no write access at all — putting these under users/{uid} would
 * have exposed them, because that subtree is client-writable.
 */

import { getFirestore, Firestore, Timestamp } from "firebase-admin/firestore";

import {
  Entitlement,
  VerifiedSubscription,
  accessFor,
  applyVerifiedSubscription,
  chargeSeconds,
  freshEntitlement,
} from "./entitlement.js";
import { UsageSession, isStale, newSession, tick } from "./usage.js";

export const ENTITLEMENTS = "entitlements";
export const USAGE_SESSIONS = "usageSessions";

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

function toEntitlement(data: FirebaseFirestore.DocumentData | undefined, nowMs: number): Entitlement {
  if (!data) return freshEntitlement(nowMs);
  return {
    plan: data.plan ?? "free",
    subscriptionStatus: data.subscriptionStatus ?? "none",
    store: data.store ?? null,
    storeProductId: data.storeProductId ?? null,
    currentPeriodStart: data.currentPeriodStart ?? null,
    currentPeriodEnd: data.currentPeriodEnd ?? null,
    minutesAllowance: data.minutesAllowance ?? 0,
    minutesUsed: data.minutesUsed ?? 0,
    freeMinutesUsed: data.freeMinutesUsed ?? 0,
    entitlementUpdatedAt: data.entitlementUpdatedAt ?? nowMs,
    appliedEventIds: data.appliedEventIds ?? [],
  };
}

function toDocument(entitlement: Entitlement) {
  return {
    ...entitlement,
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
 * concurrent webhooks/purchases cannot both reset a period.
 */
export async function applyVerified(
  uid: string,
  verified: VerifiedSubscription,
  nowMs: number,
): Promise<Entitlement> {
  const ref = firestore().collection(ENTITLEMENTS).doc(uid);
  return firestore().runTransaction(async (tx) => {
    const snapshot = await tx.get(ref);
    const current = toEntitlement(snapshot.data(), nowMs);
    const result = applyVerifiedSubscription(current, verified, nowMs);
    if (result.changed) {
      tx.set(ref, toDocument(result.entitlement), { merge: true });
    }
    return result.entitlement;
  });
}

export interface SessionStart {
  sessionId: string;
  remainingMinutes: number;
}

/**
 * Opens a metered session if the user has allowance left. Any session left
 * open by a crashed client is settled first, so its time is billed before the
 * next one is allowed to start.
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
      tx.set(entitlementRef, toDocument(entitlement), { merge: true });
    }
    tx.set(sessionRef, newSession(uid, nowMs));
    return { sessionId, remainingMinutes: access.remainingMinutes };
  });
}

export interface SessionCharge {
  remainingMinutes: number;
  allowed: boolean;
}

/**
 * Charges elapsed time for a session and reports how much is left, so the
 * client can stop itself before running over. Server clock only.
 */
export async function chargeSession(
  uid: string,
  sessionId: string,
  nowMs: number,
  options: { close?: boolean } = {},
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
      return { remainingMinutes: access.remainingMinutes, allowed: access.allowed };
    }

    const result = tick(data, nowMs, options);
    const charged = chargeSeconds(entitlement, result.chargeSeconds, nowMs);
    if (result.chargeSeconds > 0 || options.close === true) {
      tx.set(sessionRef, result.session);
      tx.set(entitlementRef, toDocument(charged), { merge: true });
    }
    const access = accessFor(charged, nowMs);
    return { remainingMinutes: access.remainingMinutes, allowed: access.allowed };
  });
}

/** Bills and closes sessions a client abandoned without ending them. */
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
    await chargeSession(uid, doc.id, nowMs, { close: true });
  }
}
