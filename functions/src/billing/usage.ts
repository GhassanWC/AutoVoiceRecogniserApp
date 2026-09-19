/**
 * Live-translation usage metering.
 *
 * What is metered is ACTIVE SESSION TIME — from the moment the server mints a
 * Gemini token until the session ends — not messages, bubbles or characters.
 * Every timestamp used for billing is the SERVER's, so a client cannot
 * under-report by lying about its clock.
 *
 * The client heartbeats while it listens; each heartbeat charges only the
 * elapsed time since the previous one, so a session costs a couple of writes
 * per minute rather than one per second.
 */

/**
 * Longest stretch a single tick may charge. A client that stops heartbeating
 * (crash, airplane mode, killed app) is charged at most this much beyond its
 * last proof of life, which also bounds what a stalled session can cost.
 */
export const MAX_TICK_SECONDS = 90;

/** How long after the last heartbeat a session is considered abandoned. */
export const SESSION_STALE_SECONDS = 150;

export interface UsageSession {
  uid: string;
  /** Server epoch ms. */
  startedAt: number;
  lastTickAt: number;
  /** Seconds already charged to the entitlement. */
  chargedSeconds: number;
  closed: boolean;
}

export function newSession(uid: string, nowMs: number): UsageSession {
  return {
    uid,
    startedAt: nowMs,
    lastTickAt: nowMs,
    chargedSeconds: 0,
    closed: false,
  };
}

/**
 * Seconds to charge for a tick at [nowMs]. Clamped to [0, MAX_TICK_SECONDS]:
 * never negative (a clock going backwards must not refund minutes) and never
 * unbounded (a long gap must not bill for time we cannot prove).
 */
export function tickSeconds(session: UsageSession, nowMs: number): number {
  const elapsed = (nowMs - session.lastTickAt) / 1000;
  if (!(elapsed > 0)) return 0;
  return Math.min(elapsed, MAX_TICK_SECONDS);
}

export interface TickResult {
  session: UsageSession;
  chargeSeconds: number;
}

/** Advances a session's watermark, returning what to charge. */
export function tick(
  session: UsageSession,
  nowMs: number,
  options: { close?: boolean } = {},
): TickResult {
  if (session.closed) {
    return { session, chargeSeconds: 0 };
  }
  const chargeSeconds = tickSeconds(session, nowMs);
  return {
    session: {
      ...session,
      lastTickAt: nowMs,
      chargedSeconds: session.chargedSeconds + chargeSeconds,
      closed: options.close === true,
    },
    chargeSeconds,
  };
}

export function isStale(session: UsageSession, nowMs: number): boolean {
  return (
    !session.closed && nowMs - session.lastTickAt > SESSION_STALE_SECONDS * 1000
  );
}
