import { describe, expect, it } from "vitest";

import {
  Entitlement,
  VerifiedSubscription,
  accessFor,
  applyVerifiedSubscription,
  chargeSeconds,
  freshEntitlement,
} from "./entitlement.js";
import { FREE_LIFETIME_MINUTES, PLAN_MINUTES, PRODUCT_IDS } from "./plans.js";
import { MAX_TICK_SECONDS, newSession, tick, tickSeconds } from "./usage.js";

const T0 = Date.parse("2026-09-19T10:00:00Z");
const DAY = 24 * 60 * 60 * 1000;

function verified(
  overrides: Partial<VerifiedSubscription> = {},
): VerifiedSubscription {
  return {
    store: "apple",
    productId: PRODUCT_IDS.plus,
    status: "active",
    handle: "2000000111",
    periodStart: T0,
    periodEnd: T0 + 30 * DAY,
    eventId: "txn-1",
    ...overrides,
  };
}

function minutesOf(entitlement: Entitlement, minutes: number, at = T0) {
  return chargeSeconds(entitlement, minutes * 60, at);
}

describe("free tier", () => {
  it("a new account starts with five LIFETIME minutes", () => {
    const access = accessFor(freshEntitlement(T0), T0);
    expect(access.plan).toBe("free");
    expect(access.source).toBe("free");
    expect(access.remainingMinutes).toBe(FREE_LIFETIME_MINUTES);
    expect(access.allowed).toBe(true);
  });

  it("free minutes are consumed and never reset by time passing", () => {
    let entitlement = freshEntitlement(T0);
    entitlement = minutesOf(entitlement, 3);
    expect(accessFor(entitlement, T0).remainingMinutes).toBeCloseTo(2);

    // A month later — still the same lifetime bucket, NOT a monthly refill.
    expect(accessFor(entitlement, T0 + 40 * DAY).remainingMinutes).toBeCloseTo(2);
  });

  it("blocks once the lifetime allowance is spent", () => {
    let entitlement = freshEntitlement(T0);
    entitlement = minutesOf(entitlement, FREE_LIFETIME_MINUTES);
    const access = accessFor(entitlement, T0);
    expect(access.allowed).toBe(false);
    expect(access.remainingMinutes).toBe(0);
  });

  it("free usage lives on the server document, so it survives a reinstall", () => {
    // A reinstall re-reads the SAME stored entitlement for the same uid;
    // nothing about a fresh client resets it.
    let stored = freshEntitlement(T0);
    stored = minutesOf(stored, 4);
    const afterReinstall = { ...stored };
    expect(accessFor(afterReinstall, T0 + 5 * DAY).remainingMinutes).toBeCloseTo(1);
  });
});

describe("paid plans", () => {
  const cases = [
    ["basic", PRODUCT_IDS.basic, PLAN_MINUTES.basic],
    ["plus", PRODUCT_IDS.plus, PLAN_MINUTES.plus],
    ["pro", PRODUCT_IDS.pro, PLAN_MINUTES.pro],
  ] as const;

  for (const [plan, productId, minutes] of cases) {
    it(`a verified ${plan} purchase grants ${minutes} minutes`, () => {
      const { entitlement, changed } = applyVerifiedSubscription(
        freshEntitlement(T0),
        verified({ productId }),
        T0,
      );
      expect(changed).toBe(true);
      expect(entitlement.plan).toBe(plan);
      expect(entitlement.minutesAllowance).toBe(minutes);
      const access = accessFor(entitlement, T0);
      expect(access.source).toBe("plan");
      expect(access.remainingMinutes).toBe(minutes);
    });
  }

  it("charges paid usage to the plan, leaving free minutes untouched", () => {
    const { entitlement } = applyVerifiedSubscription(
      freshEntitlement(T0),
      verified(),
      T0,
    );
    const used = minutesOf(entitlement, 10);
    expect(used.minutesUsed).toBeCloseTo(10);
    expect(used.freeMinutesUsed).toBe(0);
    expect(accessFor(used, T0).remainingMinutes).toBeCloseTo(PLAN_MINUTES.plus - 10);
  });

  it("stops the user once the plan allowance is spent", () => {
    const { entitlement } = applyVerifiedSubscription(
      freshEntitlement(T0),
      verified(),
      T0,
    );
    const spent = minutesOf(entitlement, PLAN_MINUTES.plus);
    expect(accessFor(spent, T0).allowed).toBe(false);
  });
});

describe("billing periods", () => {
  it("a new period resets usage to zero", () => {
    const first = applyVerifiedSubscription(
      freshEntitlement(T0),
      verified(),
      T0,
    ).entitlement;
    const used = minutesOf(first, 20);

    const renewal = applyVerifiedSubscription(
      used,
      verified({
        eventId: "txn-2",
        periodStart: T0 + 30 * DAY,
        periodEnd: T0 + 60 * DAY,
      }),
      T0 + 30 * DAY,
    );
    expect(renewal.periodAdvanced).toBe(true);
    expect(renewal.entitlement.minutesUsed).toBe(0);
    expect(accessFor(renewal.entitlement, T0 + 30 * DAY).remainingMinutes).toBe(
      PLAN_MINUTES.plus,
    );
  });

  it("unused minutes do NOT roll over", () => {
    const first = applyVerifiedSubscription(
      freshEntitlement(T0),
      verified(),
      T0,
    ).entitlement;
    // Only 5 of 35 used — the other 30 are lost at renewal.
    const used = minutesOf(first, 5);
    const renewed = applyVerifiedSubscription(
      used,
      verified({
        eventId: "txn-2",
        periodStart: T0 + 30 * DAY,
        periodEnd: T0 + 60 * DAY,
      }),
      T0 + 30 * DAY,
    ).entitlement;

    expect(renewed.minutesAllowance).toBe(PLAN_MINUTES.plus);
    expect(accessFor(renewed, T0 + 30 * DAY).remainingMinutes).toBe(
      PLAN_MINUTES.plus,
    );
  });

  it("does not reset on a calendar month, only on a real new period", () => {
    const active = applyVerifiedSubscription(
      freshEntitlement(T0),
      verified({ periodStart: T0, periodEnd: T0 + 30 * DAY }),
      T0,
    ).entitlement;
    const used = minutesOf(active, 12);
    // The 1st of the next calendar month falls inside this period.
    expect(accessFor(used, T0 + 13 * DAY).remainingMinutes).toBeCloseTo(
      PLAN_MINUTES.plus - 12,
    );
  });

  it("an entitlement past its period end grants nothing", () => {
    const active = applyVerifiedSubscription(
      freshEntitlement(T0),
      verified(),
      T0,
    ).entitlement;
    const access = accessFor(active, T0 + 31 * DAY);
    expect(access.source).toBe("free");
    expect(access.allowed).toBe(true); // 5 unused free minutes remain
    expect(access.remainingMinutes).toBe(FREE_LIFETIME_MINUTES);
  });
});

describe("losing a subscription", () => {
  it("expiry removes the paid allowance", () => {
    const active = applyVerifiedSubscription(
      freshEntitlement(T0),
      verified(),
      T0,
    ).entitlement;
    const spentFree = minutesOf(active, 0); // free bucket untouched
    const expired = applyVerifiedSubscription(
      spentFree,
      verified({ eventId: "txn-exp", status: "expired" }),
      T0 + 31 * DAY,
    ).entitlement;

    expect(expired.subscriptionStatus).toBe("expired");
    expect(expired.minutesAllowance).toBe(0);
    expect(accessFor(expired, T0 + 31 * DAY).source).toBe("free");
  });

  it("a refund/revocation removes entitlement immediately", () => {
    const active = applyVerifiedSubscription(
      freshEntitlement(T0),
      verified(),
      T0,
    ).entitlement;
    const revoked = applyVerifiedSubscription(
      active,
      verified({ eventId: "txn-rev", status: "revoked" }),
      T0 + 2 * DAY,
    ).entitlement;

    expect(revoked.subscriptionStatus).toBe("revoked");
    // Mid-period, but revoked beats the period window.
    expect(accessFor(revoked, T0 + 2 * DAY).source).toBe("free");
  });

  it("a user who already spent their free minutes is fully paywalled", () => {
    let entitlement = freshEntitlement(T0);
    entitlement = minutesOf(entitlement, FREE_LIFETIME_MINUTES);
    entitlement = applyVerifiedSubscription(entitlement, verified(), T0).entitlement;
    entitlement = applyVerifiedSubscription(
      entitlement,
      verified({ eventId: "txn-exp", status: "expired" }),
      T0 + 31 * DAY,
    ).entitlement;

    expect(accessFor(entitlement, T0 + 31 * DAY).allowed).toBe(false);
  });
});

describe("trust boundary", () => {
  it("a product id we do not sell grants nothing", () => {
    const forged = applyVerifiedSubscription(
      freshEntitlement(T0),
      verified({ productId: "sayvo_unlimited_forever" }),
      T0,
    );
    expect(forged.changed).toBe(false);
    expect(forged.entitlement.plan).toBe("free");
    expect(accessFor(forged.entitlement, T0).remainingMinutes).toBe(
      FREE_LIFETIME_MINUTES,
    );
  });

  it("replaying the same store event changes nothing", () => {
    const first = applyVerifiedSubscription(
      freshEntitlement(T0),
      verified(),
      T0,
    );
    const used = minutesOf(first.entitlement, 20);

    // The same notification arrives again (webhook retry / double submit).
    const replay = applyVerifiedSubscription(used, verified(), T0 + 60_000);
    expect(replay.changed).toBe(false);
    expect(replay.entitlement.minutesUsed).toBeCloseTo(20);
    expect(replay.entitlement).toBe(used);
  });

  it("a replayed RENEWAL cannot reset usage twice", () => {
    const active = applyVerifiedSubscription(
      freshEntitlement(T0),
      verified(),
      T0,
    ).entitlement;
    const renewal = verified({
      eventId: "txn-2",
      periodStart: T0 + 30 * DAY,
      periodEnd: T0 + 60 * DAY,
    });
    const renewed = applyVerifiedSubscription(active, renewal, T0 + 30 * DAY)
      .entitlement;
    const usedAfter = minutesOf(renewed, 9, T0 + 31 * DAY);

    const replayed = applyVerifiedSubscription(usedAfter, renewal, T0 + 31 * DAY);
    expect(replayed.changed).toBe(false);
    expect(replayed.entitlement.minutesUsed).toBeCloseTo(9);
  });

  it("upgrading mid-period re-bases the allowance without refunding usage", () => {
    const basic = applyVerifiedSubscription(
      freshEntitlement(T0),
      verified({ productId: PRODUCT_IDS.basic }),
      T0,
    ).entitlement;
    const used = minutesOf(basic, 10);

    const upgraded = applyVerifiedSubscription(
      used,
      verified({ eventId: "txn-up", productId: PRODUCT_IDS.pro }),
      T0 + DAY,
    ).entitlement;

    expect(upgraded.plan).toBe("pro");
    expect(upgraded.minutesAllowance).toBe(PLAN_MINUTES.pro);
    expect(upgraded.minutesUsed).toBeCloseTo(10);
    expect(accessFor(upgraded, T0 + DAY).remainingMinutes).toBeCloseTo(
      PLAN_MINUTES.pro - 10,
    );
  });
});

describe("usage metering", () => {
  it("charges elapsed session time, not messages", () => {
    const session = newSession("user-1", T0);
    const result = tick(session, T0 + 30_000);
    expect(result.chargeSeconds).toBeCloseTo(30);
    expect(result.session.chargedSeconds).toBeCloseTo(30);
  });

  it("caps a single tick so a stalled client cannot run up a huge bill", () => {
    const session = newSession("user-1", T0);
    expect(tickSeconds(session, T0 + 60 * 60 * 1000)).toBe(MAX_TICK_SECONDS);
  });

  it("never charges negative time if a clock goes backwards", () => {
    const session = newSession("user-1", T0);
    expect(tickSeconds(session, T0 - 10_000)).toBe(0);
  });

  it("stops accumulating once the session is closed", () => {
    const session = newSession("user-1", T0);
    const closed = tick(session, T0 + 10_000, { close: true });
    expect(closed.session.closed).toBe(true);

    const afterClose = tick(closed.session, T0 + 120_000);
    expect(afterClose.chargeSeconds).toBe(0);
    expect(afterClose.session.chargedSeconds).toBeCloseTo(10);
  });

  it("metered seconds land on the entitlement bucket in use", () => {
    let entitlement = freshEntitlement(T0);
    const session = newSession("user-1", T0);
    const first = tick(session, T0 + 60_000);
    entitlement = chargeSeconds(entitlement, first.chargeSeconds, T0 + 60_000);
    expect(entitlement.freeMinutesUsed).toBeCloseTo(1);
    expect(accessFor(entitlement, T0).remainingMinutes).toBeCloseTo(4);
  });
});
