import { describe, expect, it } from "vitest";

import {
  Entitlement,
  OVERRUN_GRACE_MS,
  VerifiedSubscription,
  accessFor,
  applyVerifiedSubscription,
  chargeSpeechMs,
  freshEntitlement,
} from "./entitlement.js";
import {
  FREE_LIFETIME_MS,
  MS_PER_MINUTE,
  PLAN_ALLOWANCE_MS,
  PRODUCT_IDS,
} from "./plans.js";

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

/** Charges [minutes] of TRANSLATED SPEECH, the only thing that costs anything. */
function speak(entitlement: Entitlement, minutes: number, at = T0) {
  return chargeSpeechMs(entitlement, minutes * MS_PER_MINUTE, at).entitlement;
}

describe("free tier", () => {
  it("a new account starts with five LIFETIME minutes of translated speech", () => {
    const access = accessFor(freshEntitlement(T0), T0);
    expect(access.allowed).toBe(true);
    expect(access.source).toBe("free");
    expect(access.remainingMs).toBe(FREE_LIFETIME_MS);
  });

  it("the free allowance is consumed and never reset by time passing", () => {
    const after = speak(freshEntitlement(T0), 2);
    expect(accessFor(after, T0).remainingMs).toBe(3 * MS_PER_MINUTE);
    // A month later it is still three minutes: this is a lifetime allowance.
    expect(accessFor(after, T0 + 31 * DAY).remainingMs).toBe(3 * MS_PER_MINUTE);
  });

  it("blocks once the lifetime allowance is spent", () => {
    const spent = speak(freshEntitlement(T0), 5);
    const access = accessFor(spent, T0);
    expect(access.allowed).toBe(false);
    expect(access.remainingMs).toBe(0);
  });

  it("free usage lives on the server document, so it survives a reinstall", () => {
    // A reinstalled app reads back exactly this document; there is no local
    // counter anywhere that a fresh install could reset.
    const used = speak(freshEntitlement(T0), 4);
    const reread: Entitlement = JSON.parse(JSON.stringify(used));
    expect(accessFor(reread, T0 + 90 * DAY).remainingMs).toBe(1 * MS_PER_MINUTE);
  });
});

describe("paid plans", () => {
  const cases = [
    ["basic", PRODUCT_IDS.basic, 15],
    ["plus", PRODUCT_IDS.plus, 35],
    ["pro", PRODUCT_IDS.pro, 55],
  ] as const;

  for (const [plan, productId, minutes] of cases) {
    it(`a verified ${plan} purchase grants ${minutes} translated-speech minutes`, () => {
      const result = applyVerifiedSubscription(
        freshEntitlement(T0),
        verified({ productId }),
        T0,
      );
      expect(result.entitlement.plan).toBe(plan);
      expect(result.entitlement.allowanceMs).toBe(minutes * MS_PER_MINUTE);
      const access = accessFor(result.entitlement, T0);
      expect(access.source).toBe("plan");
      expect(access.remainingMs).toBe(minutes * MS_PER_MINUTE);
    });
  }

  it("charges translated speech to the plan, leaving free minutes untouched", () => {
    const paid = applyVerifiedSubscription(
      freshEntitlement(T0),
      verified(),
      T0,
    ).entitlement;
    const after = speak(paid, 10);
    expect(after.usedMs).toBe(10 * MS_PER_MINUTE);
    expect(after.freeUsedMs).toBe(0);
    expect(accessFor(after, T0).remainingMs).toBe(25 * MS_PER_MINUTE);
  });

  it("stops the user once the plan allowance is spent", () => {
    const paid = applyVerifiedSubscription(
      freshEntitlement(T0),
      verified(),
      T0,
    ).entitlement;
    const spent = speak(paid, 35);
    expect(accessFor(spent, T0).allowed).toBe(false);
  });
});

describe("what a charge may do", () => {
  it("accumulates exact durations rather than rounding to whole minutes", () => {
    let e = freshEntitlement(T0);
    for (const ms of [10_000, 17_000, 21_000]) {
      e = chargeSpeechMs(e, ms, T0).entitlement;
    }
    expect(e.freeUsedMs).toBe(48_000);
    expect(accessFor(e, T0).remainingMs).toBe(FREE_LIFETIME_MS - 48_000);
  });

  it("charges nothing for zero or negative speech", () => {
    const e = freshEntitlement(T0);
    expect(chargeSpeechMs(e, 0, T0).chargedMs).toBe(0);
    expect(chargeSpeechMs(e, -5_000, T0).chargedMs).toBe(0);
    expect(chargeSpeechMs(e, -5_000, T0).entitlement.freeUsedMs).toBe(0);
  });

  it("one long utterance cannot walk through the cap", () => {
    // Half a minute left, and a client reporting an hour of speech.
    const nearlySpent = speak(freshEntitlement(T0), 4.5);
    const charge = chargeSpeechMs(nearlySpent, 60 * MS_PER_MINUTE, T0);
    expect(charge.chargedMs).toBe(30_000 + OVERRUN_GRACE_MS);
    expect(accessFor(charge.entitlement, T0).allowed).toBe(false);
  });

  it("an exhausted account cannot be charged further", () => {
    const spent = speak(freshEntitlement(T0), 5);
    const charge = chargeSpeechMs(spent, 60_000, T0);
    expect(charge.chargedMs).toBe(OVERRUN_GRACE_MS);
    const again = chargeSpeechMs(charge.entitlement, 60_000, T0);
    expect(again.chargedMs).toBe(0);
  });

  it("charges to whichever bucket is in force", () => {
    const paid = applyVerifiedSubscription(
      freshEntitlement(T0),
      verified(),
      T0,
    ).entitlement;
    // Inside the period it is the plan's; once it has lapsed it is whatever
    // free allowance was never used.
    expect(chargeSpeechMs(paid, 60_000, T0).entitlement.usedMs).toBe(60_000);
    expect(
      chargeSpeechMs(paid, 60_000, T0 + 31 * DAY).entitlement.freeUsedMs,
    ).toBe(60_000);
  });
});

describe("billing periods", () => {
  it("a new period resets usage to zero", () => {
    const first = applyVerifiedSubscription(
      freshEntitlement(T0),
      verified(),
      T0,
    ).entitlement;
    const used = speak(first, 30);

    const renewed = applyVerifiedSubscription(
      used,
      verified({
        eventId: "txn-2",
        periodStart: T0 + 30 * DAY,
        periodEnd: T0 + 60 * DAY,
      }),
      T0 + 30 * DAY,
    );
    expect(renewed.periodAdvanced).toBe(true);
    expect(renewed.entitlement.usedMs).toBe(0);
    expect(accessFor(renewed.entitlement, T0 + 30 * DAY).remainingMs).toBe(
      PLAN_ALLOWANCE_MS.plus,
    );
  });

  it("unused minutes do NOT roll over", () => {
    const first = applyVerifiedSubscription(
      freshEntitlement(T0),
      verified(),
      T0,
    ).entitlement;
    // Only five of thirty-five minutes used; the other thirty are gone.
    const used = speak(first, 5);
    const renewed = applyVerifiedSubscription(
      used,
      verified({
        eventId: "txn-2",
        periodStart: T0 + 30 * DAY,
        periodEnd: T0 + 60 * DAY,
      }),
      T0 + 30 * DAY,
    ).entitlement;
    expect(renewed.allowanceMs).toBe(PLAN_ALLOWANCE_MS.plus);
    expect(accessFor(renewed, T0 + 30 * DAY).remainingMs).toBe(
      PLAN_ALLOWANCE_MS.plus,
    );
  });

  it("does not reset on a calendar month, only on a real new period", () => {
    const paid = applyVerifiedSubscription(
      freshEntitlement(T0),
      verified({ periodStart: T0, periodEnd: T0 + 30 * DAY }),
      T0,
    ).entitlement;
    const used = speak(paid, 20);
    // The first of the next calendar month, still inside the paid period.
    const calendarRollover = Date.parse("2026-10-01T00:00:00Z");
    expect(accessFor(used, calendarRollover).remainingMs).toBe(
      15 * MS_PER_MINUTE,
    );
  });

  it("silence across a period boundary creates no usage", () => {
    const paid = applyVerifiedSubscription(
      freshEntitlement(T0),
      verified(),
      T0,
    ).entitlement;
    // Nothing was translated, so nothing was ever charged — before or after.
    const renewed = applyVerifiedSubscription(
      paid,
      verified({
        eventId: "txn-2",
        periodStart: T0 + 30 * DAY,
        periodEnd: T0 + 60 * DAY,
      }),
      T0 + 30 * DAY,
    ).entitlement;
    expect(renewed.usedMs).toBe(0);
    expect(renewed.freeUsedMs).toBe(0);
  });

  it("an entitlement past its period end grants nothing", () => {
    const paid = applyVerifiedSubscription(
      freshEntitlement(T0),
      verified(),
      T0,
    ).entitlement;
    const access = accessFor(paid, T0 + 31 * DAY);
    expect(access.source).toBe("free");
    expect(access.remainingMs).toBe(FREE_LIFETIME_MS);
  });
});

describe("losing a subscription", () => {
  it("expiry removes the paid allowance", () => {
    const paid = applyVerifiedSubscription(
      freshEntitlement(T0),
      verified(),
      T0,
    ).entitlement;
    const expired = applyVerifiedSubscription(
      paid,
      verified({ eventId: "txn-2", status: "expired" }),
      T0 + 31 * DAY,
    ).entitlement;
    expect(expired.allowanceMs).toBe(0);
    expect(accessFor(expired, T0 + 31 * DAY).source).toBe("free");
  });

  it("a refund/revocation removes entitlement immediately", () => {
    const paid = applyVerifiedSubscription(
      freshEntitlement(T0),
      verified(),
      T0,
    ).entitlement;
    const revoked = applyVerifiedSubscription(
      paid,
      verified({ eventId: "txn-2", status: "revoked" }),
      T0 + DAY,
    ).entitlement;
    expect(revoked.allowanceMs).toBe(0);
    // Mid-period, and already gone.
    expect(accessFor(revoked, T0 + DAY).source).toBe("free");
  });

  it("a PENDING purchase grants nothing", () => {
    // Play reports an unpaid purchase as pending, which maps to "none".
    const pending = applyVerifiedSubscription(
      freshEntitlement(T0),
      verified({ store: "google", status: "none" }),
      T0,
    ).entitlement;
    expect(pending.allowanceMs).toBe(0);
    const access = accessFor(pending, T0);
    expect(access.source).toBe("free");
    expect(access.plan).toBe("free");
  });

  it("grace periods keep the user translating", () => {
    const grace = applyVerifiedSubscription(
      freshEntitlement(T0),
      verified({ status: "grace" }),
      T0,
    ).entitlement;
    expect(accessFor(grace, T0).source).toBe("plan");
    expect(accessFor(grace, T0).allowed).toBe(true);
  });

  it("a user who already spent their free minutes is fully paywalled", () => {
    const spentFree = speak(freshEntitlement(T0), 5);
    const paid = applyVerifiedSubscription(spentFree, verified(), T0).entitlement;
    const expired = applyVerifiedSubscription(
      paid,
      verified({ eventId: "txn-2", status: "expired" }),
      T0 + 31 * DAY,
    ).entitlement;
    expect(accessFor(expired, T0 + 31 * DAY).allowed).toBe(false);
  });
});

describe("trust boundary", () => {
  it("a product id we do not sell grants nothing", () => {
    const result = applyVerifiedSubscription(
      freshEntitlement(T0),
      verified({ productId: "sayvo_unlimited_forever" }),
      T0,
    );
    expect(result.changed).toBe(false);
    expect(result.entitlement.plan).toBe("free");
    expect(result.entitlement.allowanceMs).toBe(0);
  });

  it("replaying the same store event changes nothing", () => {
    const once = applyVerifiedSubscription(
      freshEntitlement(T0),
      verified(),
      T0,
    ).entitlement;
    const used = speak(once, 10);
    const replayed = applyVerifiedSubscription(used, verified(), T0 + 60_000);
    expect(replayed.changed).toBe(false);
    expect(replayed.entitlement.usedMs).toBe(10 * MS_PER_MINUTE);
  });

  it("a replayed RENEWAL cannot reset usage twice", () => {
    const first = applyVerifiedSubscription(
      freshEntitlement(T0),
      verified(),
      T0,
    ).entitlement;
    const renewal = verified({
      eventId: "txn-2",
      periodStart: T0 + 30 * DAY,
      periodEnd: T0 + 60 * DAY,
    });
    const renewed = applyVerifiedSubscription(first, renewal, T0 + 30 * DAY)
      .entitlement;
    const used = speak(renewed, 12, T0 + 31 * DAY);
    const replayed = applyVerifiedSubscription(used, renewal, T0 + 32 * DAY);
    expect(replayed.changed).toBe(false);
    expect(replayed.entitlement.usedMs).toBe(12 * MS_PER_MINUTE);
  });

  it("upgrading mid-period re-bases the allowance without refunding usage", () => {
    const plus = applyVerifiedSubscription(
      freshEntitlement(T0),
      verified(),
      T0,
    ).entitlement;
    const used = speak(plus, 20);
    const pro = applyVerifiedSubscription(
      used,
      verified({ eventId: "txn-2", productId: PRODUCT_IDS.pro }),
      T0 + DAY,
    ).entitlement;
    expect(pro.plan).toBe("pro");
    expect(pro.allowanceMs).toBe(PLAN_ALLOWANCE_MS.pro);
    expect(pro.usedMs).toBe(20 * MS_PER_MINUTE);
    expect(accessFor(pro, T0 + DAY).remainingMs).toBe(35 * MS_PER_MINUTE);
  });

  it("keeps the store handle and account token the store reported", () => {
    const e = applyVerifiedSubscription(
      freshEntitlement(T0),
      verified({ handle: "2000000999" }),
      T0,
    ).entitlement;
    expect(e.storeHandle).toBe("2000000999");
  });
});
