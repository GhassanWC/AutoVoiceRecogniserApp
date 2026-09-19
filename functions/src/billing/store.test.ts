import { afterEach, beforeEach, describe, expect, it } from "vitest";
import type { Firestore } from "firebase-admin/firestore";

import {
  ENTITLEMENTS,
  PurchaseOwnershipError,
  SUBSCRIPTION_OWNERS,
  USAGE_SESSIONS,
  applyVerified,
  openSession,
  ownerOfPurchase,
  readEntitlement,
  reportSpeech,
  settleStaleSessions,
  useFirestoreForTests,
} from "./store.js";
import { FREE_LIFETIME_MS, MS_PER_MINUTE, PRODUCT_IDS } from "./plans.js";
import { REPORT_SLACK_MS, SESSION_STALE_SECONDS } from "./usage.js";
import { VerifiedSubscription } from "./entitlement.js";

/**
 * A minimal in-memory stand-in for the Admin SDK surface this module uses.
 * It is deliberately small: the point is to exercise the real gating and
 * charging logic, not to re-implement Firestore.
 */
class FakeFirestore {
  readonly data = new Map<string, Record<string, unknown>>();

  private key(collection: string, id: string) {
    return `${collection}/${id}`;
  }

  collection(name: string) {
    const store = this;
    const makeDoc = (id: string) => ({
      id,
      get: async () => store.snapshot(name, id),
      set: (value: Record<string, unknown>, options?: { merge?: boolean }) =>
        store.write(name, id, value, options),
    });
    const query = (filters: Array<[string, string, unknown]>, max: number) => ({
      where: (field: string, op: string, value: unknown) =>
        query([...filters, [field, op, value]], max),
      limit: (n: number) => query(filters, n),
      get: async () => {
        const docs = [...store.data.entries()]
          .filter(([key]) => key.startsWith(`${name}/`))
          .filter(([, value]) =>
            filters.every(([field, , expected]) => value[field] === expected),
          )
          .slice(0, max)
          .map(([key, value]) => ({
            id: key.slice(name.length + 1),
            data: () => value,
          }));
        return { docs, empty: docs.length === 0 };
      },
    });
    return {
      doc: makeDoc,
      where: (field: string, op: string, value: unknown) =>
        query([[field, op, value]], 100),
    };
  }

  snapshot(collection: string, id: string) {
    const value = this.data.get(this.key(collection, id));
    return { exists: value !== undefined, id, data: () => value };
  }

  write(
    collection: string,
    id: string,
    value: Record<string, unknown>,
    options?: { merge?: boolean },
  ) {
    const key = this.key(collection, id);
    const existing = options?.merge ? (this.data.get(key) ?? {}) : {};
    this.data.set(key, { ...existing, ...value });
  }

  /**
   * Transactions run one at a time and their writes land immediately.
   *
   * Real Firestore reaches the same outcome by retrying a transaction whose
   * read set another one changed; modelling that faithfully is not the job of
   * this fake, so it serializes instead. What the tests then exercise is the
   * ownership logic under contention — the atomicity itself is Firestore's
   * guarantee, not ours.
   */
  private queue: Promise<unknown> = Promise.resolve();

  runTransaction<T>(
    fn: (tx: {
      get: (ref: { collection: string; id: string }) => Promise<unknown>;
      set: (
        ref: { collection: string; id: string },
        value: Record<string, unknown>,
        options?: { merge?: boolean },
      ) => void;
    }) => Promise<T>,
  ): Promise<T> {
    const run = this.queue.then(
      () =>
        fn({
          get: async (ref) => this.snapshot(ref.collection, ref.id),
          set: (ref, value, options) =>
            this.write(ref.collection, ref.id, value, options),
        }),
      () =>
        fn({
          get: async (ref) => this.snapshot(ref.collection, ref.id),
          set: (ref, value, options) =>
            this.write(ref.collection, ref.id, value, options),
        }),
    );
    // The queue must not be poisoned by a transaction that threw.
    this.queue = run.catch(() => undefined);
    return run;
  }
}

/**
 * The fake's doc handles must carry their collection so the transaction can
 * route reads and writes; wrap collection() to attach it.
 */
function fakeFirestore(): { fake: FakeFirestore; db: Firestore } {
  const fake = new FakeFirestore();
  const db = {
    collection(name: string) {
      const inner = fake.collection(name);
      return {
        doc: (id: string) => ({ ...inner.doc(id), collection: name, id }),
        where: inner.where,
      };
    },
    runTransaction: fake.runTransaction.bind(fake),
  } as unknown as Firestore;
  return { fake, db };
}

const NOW = Date.UTC(2026, 8, 19, 12, 0, 0);
const SECOND = 1000;
const MINUTE = 60 * SECOND;

let fake: FakeFirestore;

beforeEach(() => {
  const created = fakeFirestore();
  fake = created.fake;
  useFirestoreForTests(created.db);
});

afterEach(() => useFirestoreForTests(null));

function entitlementDoc(uid = "u1") {
  return fake.data.get(`${ENTITLEMENTS}/${uid}`) as
    | Record<string, unknown>
    | undefined;
}

function sessionDoc(id: string) {
  return fake.data.get(`${USAGE_SESSIONS}/${id}`) as
    | Record<string, unknown>
    | undefined;
}

function verified(
  overrides: Partial<VerifiedSubscription> = {},
): VerifiedSubscription {
  return {
    store: "apple",
    productId: PRODUCT_IDS.plus,
    status: "active",
    handle: "2000000111",
    periodStart: NOW,
    periodEnd: NOW + 30 * 24 * 60 * MINUTE,
    eventId: "txn-1",
    ...overrides,
  };
}

/** Reports [ms] of cumulative translated speech for a session. */
function report(
  uid: string,
  sessionId: string,
  sequence: number,
  cumulativeSpeechMs: number,
  at: number,
  close = false,
) {
  return reportSpeech(
    uid,
    sessionId,
    { sequence, cumulativeSpeechMs, close },
    at,
  );
}

describe("opening a session", () => {
  it("a brand-new account is allowed and gets its free tier persisted", async () => {
    const started = await openSession("u1", "s1", NOW);
    expect(started).toEqual({ sessionId: "s1", remainingMs: FREE_LIFETIME_MS });
    // The lifetime allowance now exists server-side, so a reinstall cannot
    // hand out a second set of free minutes.
    expect(entitlementDoc()).toMatchObject({ plan: "free", freeUsedMs: 0 });
    expect(sessionDoc("s1")).toMatchObject({ uid: "u1", closed: false });
  });

  it("opening a session charges nothing by itself", async () => {
    await openSession("u1", "s1", NOW);
    // Ten minutes of microphone time, and not one report: a silent room is
    // free, however long it is listened to.
    expect(entitlementDoc()).toMatchObject({ freeUsedMs: 0 });
    const second = await openSession("u1", "s2", NOW + 10 * MINUTE);
    expect(second?.remainingMs).toBe(FREE_LIFETIME_MS);
  });

  it("refuses once the lifetime free allowance is spent", async () => {
    fake.write(ENTITLEMENTS, "u1", {
      plan: "free",
      subscriptionStatus: "none",
      allowanceMs: 0,
      usedMs: 0,
      freeUsedMs: FREE_LIFETIME_MS,
      appliedEventIds: [],
    });
    expect(await openSession("u1", "s1", NOW)).toBeNull();
    // Nothing was opened, so nothing can be reported against it.
    expect(sessionDoc("s1")).toBeUndefined();
  });

  it("refuses once a paid allowance is spent", async () => {
    fake.write(ENTITLEMENTS, "u1", {
      plan: "basic",
      subscriptionStatus: "active",
      store: "apple",
      storeProductId: PRODUCT_IDS.basic,
      currentPeriodStart: NOW - 5 * MINUTE,
      currentPeriodEnd: NOW + 20 * 24 * 60 * MINUTE,
      allowanceMs: 15 * MINUTE,
      usedMs: 15 * MINUTE,
      freeUsedMs: FREE_LIFETIME_MS,
      appliedEventIds: [],
    });
    expect(await openSession("u1", "s1", NOW)).toBeNull();
  });

  it("closes a session abandoned by a crashed client, without charging", async () => {
    await openSession("u1", "s1", NOW);
    await report("u1", "s1", 1, 30_000, NOW + 40 * SECOND);
    // The client vanished; the next start happens well past the stale mark.
    const later = NOW + (SESSION_STALE_SECONDS + 60) * SECOND;
    await openSession("u1", "s2", later);

    expect(sessionDoc("s1")).toMatchObject({ closed: true });
    // Only the 30 s it actually reported — nothing for the hour it hung.
    expect(entitlementDoc()).toMatchObject({ freeUsedMs: 30_000 });
    expect(sessionDoc("s2")).toMatchObject({ closed: false });
  });
});

describe("reporting translated speech", () => {
  it("charges the reported speech and returns the remainder", async () => {
    await openSession("u1", "s1", NOW);
    const charge = await report("u1", "s1", 1, 8_000, NOW + 30 * SECOND);
    expect(charge.allowed).toBe(true);
    expect(charge.chargedMs).toBe(8_000);
    expect(charge.remainingMs).toBe(FREE_LIFETIME_MS - 8_000);
    expect(entitlementDoc()).toMatchObject({ freeUsedMs: 8_000 });
  });

  it("a replayed report does not charge twice", async () => {
    await openSession("u1", "s1", NOW);
    await report("u1", "s1", 1, 8_000, NOW + 30 * SECOND);
    const replay = await report("u1", "s1", 1, 8_000, NOW + 31 * SECOND);
    expect(replay.chargedMs).toBe(0);
    expect(entitlementDoc()).toMatchObject({ freeUsedMs: 8_000 });
  });

  it("five utterances accumulate exactly, with no rounding to minutes", async () => {
    await openSession("u1", "s1", NOW);
    const durations = [10_000, 17_000, 21_000, 4_000, 13_000];
    let cumulative = 0;
    let at = NOW;
    for (const [i, ms] of durations.entries()) {
      cumulative += ms;
      at += 40 * SECOND;
      await report("u1", "s1", i + 1, cumulative, at);
    }
    expect(entitlementDoc()).toMatchObject({ freeUsedMs: 65_000 });
  });

  it("cannot be driven past the entitlement", async () => {
    await openSession("u1", "s1", NOW);
    let cumulative = 0;
    let charge = { allowed: true, remainingMs: FREE_LIFETIME_MS, chargedMs: 0 };
    // Six minutes of speech, reported a minute at a time, against five.
    for (let i = 1; i <= 6; i++) {
      cumulative += MINUTE;
      charge = await report("u1", "s1", i, cumulative, NOW + i * 70 * SECOND);
    }
    expect(charge.allowed).toBe(false);
    expect(charge.remainingMs).toBe(0);
    // And a further session cannot be opened at all.
    expect(await openSession("u1", "s2", NOW + 10 * MINUTE)).toBeNull();
  });

  it("charges nothing for a session belonging to somebody else", async () => {
    await openSession("attacker", "s1", NOW);
    fake.write(ENTITLEMENTS, "victim", {
      plan: "pro",
      subscriptionStatus: "active",
      store: "apple",
      storeProductId: PRODUCT_IDS.pro,
      currentPeriodStart: NOW - MINUTE,
      currentPeriodEnd: NOW + 20 * 24 * 60 * MINUTE,
      allowanceMs: 55 * MINUTE,
      usedMs: 0,
      freeUsedMs: 0,
      appliedEventIds: [],
    });

    const charge = await report("victim", "s1", 1, 60_000, NOW + 90 * SECOND);
    expect(charge.chargedMs).toBe(0);
    expect(charge.remainingMs).toBe(55 * MINUTE);
    expect(sessionDoc("s1")).toMatchObject({ uid: "attacker", acceptedSpeechMs: 0 });
  });

  it("charges nothing for a session id that was never opened", async () => {
    const charge = await report("u1", "made-up", 1, 60_000, NOW + 90 * SECOND);
    expect(charge.chargedMs).toBe(0);
    expect(charge.remainingMs).toBe(FREE_LIFETIME_MS);
    expect(entitlementDoc()).toBeUndefined();
  });

  it("stops charging once the session is closed", async () => {
    await openSession("u1", "s1", NOW);
    await report("u1", "s1", 1, 12_000, NOW + 30 * SECOND, true);
    expect(entitlementDoc()).toMatchObject({ freeUsedMs: 12_000 });

    // A late or replayed report against the closed session adds nothing.
    await report("u1", "s1", 2, 120_000, NOW + 5 * MINUTE);
    expect(entitlementDoc()).toMatchObject({ freeUsedMs: 12_000 });
  });

  it("clamps a client claiming more speech than time has passed", async () => {
    await openSession("u1", "s1", NOW);
    const charge = await report("u1", "s1", 1, 4 * MINUTE, NOW + 5 * SECOND);
    expect(charge.status).toBe("clamped");
    expect(charge.chargedMs).toBe(5 * SECOND + REPORT_SLACK_MS);
  });

  it("refuses a cumulative counter that goes backwards", async () => {
    await openSession("u1", "s1", NOW);
    await report("u1", "s1", 1, 20_000, NOW + 30 * SECOND);
    const shrunk = await report("u1", "s1", 2, 1_000, NOW + 60 * SECOND);
    expect(shrunk.status).toBe("decreasing");
    expect(entitlementDoc()).toMatchObject({ freeUsedMs: 20_000 });
  });

  it("stores non-PII telemetry when the session closes", async () => {
    await openSession("u1", "s1", NOW);
    await reportSpeech(
      "u1",
      "s1",
      { sequence: 1, cumulativeSpeechMs: 20_000, close: true },
      NOW + 10 * MINUTE,
      {
        connectedMs: 10 * MINUTE,
        audioSentMs: 9 * MINUTE,
        committedSpeechMs: 20_000,
        translatedUtteranceCount: 3,
      },
    );
    expect(sessionDoc("s1")).toMatchObject({
      telemetry: {
        connectedMs: 10 * MINUTE,
        audioSentMs: 9 * MINUTE,
        committedSpeechMs: 20_000,
        translatedUtteranceCount: 3,
      },
    });
  });
});

describe("who owns a purchase", () => {
  it("the first account to present a purchase claims it", async () => {
    await applyVerified("u1", verified(), NOW);
    expect(await ownerOfPurchase("apple", "2000000111")).toBe("u1");
    expect(fake.data.size).toBeGreaterThan(0);
  });

  it("a second account cannot claim the same Apple subscription", async () => {
    await applyVerified("u1", verified(), NOW);
    await expect(
      applyVerified("u2", verified({ eventId: "txn-2" }), NOW + MINUTE),
    ).rejects.toBeInstanceOf(PurchaseOwnershipError);
    // And the would-be claimant got nothing.
    expect(entitlementDoc("u2")).toBeUndefined();
  });

  it("a second account cannot claim the same Play purchase token", async () => {
    const play = verified({ store: "google", handle: "play-token-xyz" });
    await applyVerified("u1", play, NOW);
    await expect(
      applyVerified("u2", { ...play, eventId: "order-2" }, NOW + MINUTE),
    ).rejects.toBeInstanceOf(PurchaseOwnershipError);
  });

  it("two parallel claims leave exactly one owner", async () => {
    // The fake serializes transactions the way Firestore serializes a
    // contended one: whoever commits first owns it, the other is refused.
    const results = await Promise.allSettled([
      applyVerified("u1", verified(), NOW),
      applyVerified("u2", verified({ eventId: "txn-2" }), NOW),
    ]);
    const fulfilled = results.filter((r) => r.status === "fulfilled");
    expect(fulfilled).toHaveLength(1);
    const owner = await ownerOfPurchase("apple", "2000000111");
    expect(["u1", "u2"]).toContain(owner);
  });

  it("the owner can restore the same purchase as often as they like", async () => {
    await applyVerified("u1", verified(), NOW);
    const restored = await applyVerified("u1", verified(), NOW + 5 * MINUTE);
    expect(restored.plan).toBe("plus");
    // A renewal for the same owner is fine too.
    const renewed = await applyVerified(
      "u1",
      verified({
        eventId: "txn-2",
        periodStart: NOW + 30 * 24 * 60 * MINUTE,
        periodEnd: NOW + 60 * 24 * 60 * MINUTE,
      }),
      NOW + 30 * 24 * 60 * MINUTE,
    );
    expect(renewed.plan).toBe("plus");
    expect(await ownerOfPurchase("apple", "2000000111")).toBe("u1");
  });

  it("stores the owner under a hashed key, never the raw token", async () => {
    await applyVerified("u1", verified({ store: "google", handle: "secret-token" }), NOW);
    const keys = [...fake.data.keys()].filter((k) =>
      k.startsWith(`${SUBSCRIPTION_OWNERS}/`),
    );
    expect(keys).toHaveLength(1);
    expect(keys[0]).not.toContain("secret-token");
  });
});

describe("applying a verified subscription", () => {
  it("writes the plan the STORE reported", async () => {
    const entitlement = await applyVerified("u1", verified(), NOW);
    expect(entitlement.plan).toBe("plus");
    expect(entitlement.allowanceMs).toBe(35 * MINUTE);
    expect(entitlementDoc()).toMatchObject({
      plan: "plus",
      store: "apple",
      storeProductId: PRODUCT_IDS.plus,
      allowanceMs: 35 * MINUTE,
    });
  });

  it("keeps the store's handle so the server can re-check a lapsed period",
    async () => {
      await applyVerified("u1", verified({ handle: "2000000999" }), NOW);
      const stored = await readEntitlement("u1", NOW);
      expect(stored.storeHandle).toBe("2000000999");
      expect(stored.store).toBe("apple");
    });

  it("is idempotent: the same store event applied twice bills once", async () => {
    const event = verified({ store: "google", handle: "play-token", eventId: "order-9" });
    await applyVerified("u1", event, NOW);
    await openSession("u1", "s1", NOW);
    await report("u1", "s1", 1, 60_000, NOW + 90 * SECOND);
    expect(entitlementDoc()).toMatchObject({ usedMs: 60_000 });

    // Replaying the identical event must not reset the period's usage.
    await applyVerified("u1", event, NOW + 2 * MINUTE);
    expect(entitlementDoc()).toMatchObject({ usedMs: 60_000 });
  });

  it("a pending Play purchase grants nothing", async () => {
    await applyVerified(
      "u1",
      verified({ store: "google", handle: "pending-token", status: "none" }),
      NOW,
    );
    expect(entitlementDoc()).toMatchObject({ allowanceMs: 0 });
    // Only the free allowance is available.
    expect(await openSession("u1", "s1", NOW)).toEqual({
      sessionId: "s1",
      remainingMs: FREE_LIFETIME_MS,
    });
  });

  it("an expired subscription leaves no paid allowance", async () => {
    await applyVerified("u1", verified(), NOW);
    const later = NOW + 31 * 24 * 60 * MINUTE;
    await applyVerified(
      "u1",
      verified({ eventId: "txn-2", status: "expired" }),
      later,
    );
    expect(entitlementDoc()).toMatchObject({ allowanceMs: 0 });
    expect(await openSession("u1", "s9", later)).toEqual({
      sessionId: "s9",
      remainingMs: FREE_LIFETIME_MS,
    });
  });
});

describe("stale sessions", () => {
  it("leaves a live session alone", async () => {
    await openSession("u1", "s1", NOW);
    await settleStaleSessions("u1", NOW + 30 * SECOND);
    expect(sessionDoc("s1")).toMatchObject({ closed: false });
  });

  it("closes sessions past the stale window without charging them", async () => {
    await openSession("u1", "s1", NOW);
    await settleStaleSessions("u1", NOW + (SESSION_STALE_SECONDS + 1) * SECOND);
    expect(sessionDoc("s1")).toMatchObject({ closed: true });
    // The free-tier document exists (opening a session creates it), but not
    // one millisecond was charged for the abandoned microphone.
    expect(entitlementDoc()).toMatchObject({ freeUsedMs: 0, usedMs: 0 });
  });
});

describe("reading an entitlement", () => {
  it("an account that has never been seen reads as the free tier", async () => {
    const entitlement = await readEntitlement("nobody", NOW);
    expect(entitlement.plan).toBe("free");
    expect(entitlement.freeUsedMs).toBe(0);
    // Reading must not create the document — only a real session does.
    expect(fake.data.size).toBe(0);
  });
});
