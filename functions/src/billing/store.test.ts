import { afterEach, beforeEach, describe, expect, it } from "vitest";
import type { Firestore } from "firebase-admin/firestore";

import {
  ENTITLEMENTS,
  USAGE_SESSIONS,
  applyVerified,
  chargeSession,
  openSession,
  readEntitlement,
  settleStaleSessions,
  useFirestoreForTests,
} from "./store.js";
import { PRODUCT_IDS } from "./plans.js";
import { SESSION_STALE_SECONDS } from "./usage.js";

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

  /** Writes land immediately; these paths are serialized in the tests. */
  async runTransaction<T>(
    fn: (tx: {
      get: (ref: { collection: string; id: string }) => Promise<unknown>;
      set: (
        ref: { collection: string; id: string },
        value: Record<string, unknown>,
        options?: { merge?: boolean },
      ) => void;
    }) => Promise<T>,
  ): Promise<T> {
    return fn({
      get: async (ref) => this.snapshot(ref.collection, ref.id),
      set: (ref, value, options) =>
        this.write(ref.collection, ref.id, value, options),
    });
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
const MINUTE = 60_000;

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

describe("opening a session", () => {
  it("a brand-new account is allowed and gets its free tier persisted", async () => {
    const started = await openSession("u1", "s1", NOW);
    expect(started).toEqual({ sessionId: "s1", remainingMinutes: 5 });
    // The lifetime allowance now exists server-side, so a reinstall cannot
    // hand out a second set of free minutes.
    expect(entitlementDoc()).toMatchObject({ plan: "free", freeMinutesUsed: 0 });
    expect(sessionDoc("s1")).toMatchObject({ uid: "u1", closed: false });
  });

  it("refuses once the lifetime free minutes are spent", async () => {
    fake.write(ENTITLEMENTS, "u1", {
      plan: "free",
      subscriptionStatus: "none",
      minutesAllowance: 0,
      minutesUsed: 0,
      freeMinutesUsed: 5,
      appliedEventIds: [],
    });
    expect(await openSession("u1", "s1", NOW)).toBeNull();
    // Nothing was opened, so nothing can be metered against it.
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
      minutesAllowance: 15,
      minutesUsed: 15,
      freeMinutesUsed: 5,
      appliedEventIds: [],
    });
    expect(await openSession("u1", "s1", NOW)).toBeNull();
  });

  it("settles a session abandoned by a crashed client before starting a new one",
    async () => {
      await openSession("u1", "s1", NOW);
      // The client vanished; the next start happens well past the stale mark.
      const later = NOW + (SESSION_STALE_SECONDS + 30) * 1000;
      await openSession("u1", "s2", later);

      expect(sessionDoc("s1")).toMatchObject({ closed: true });
      // The abandoned session was billed — capped, not for the whole gap.
      const entitlement = entitlementDoc() as { freeMinutesUsed: number };
      expect(entitlement.freeMinutesUsed).toBeCloseTo(1.5, 3);
      expect(sessionDoc("s2")).toMatchObject({ closed: false });
    });
});

describe("charging a session", () => {
  it("bills elapsed server time and reports the remainder", async () => {
    await openSession("u1", "s1", NOW);
    const charge = await chargeSession("u1", "s1", NOW + 60_000);
    expect(charge.allowed).toBe(true);
    expect(charge.remainingMinutes).toBeCloseTo(4, 3);
    expect(entitlementDoc()).toMatchObject({ freeMinutesUsed: 1 });
  });

  it("cannot be driven past the entitlement", async () => {
    await openSession("u1", "s1", NOW);
    // Six one-minute ticks against a five-minute lifetime allowance.
    let charge = { remainingMinutes: 5, allowed: true };
    for (let i = 1; i <= 6; i++) {
      charge = await chargeSession("u1", "s1", NOW + i * 60_000);
    }
    expect(charge.allowed).toBe(false);
    expect(charge.remainingMinutes).toBe(0);
    // And a further session cannot be opened at all.
    expect(await openSession("u1", "s2", NOW + 7 * 60_000)).toBeNull();
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
      minutesAllowance: 55,
      minutesUsed: 0,
      freeMinutesUsed: 0,
      appliedEventIds: [],
    });

    // The victim's own balance comes back, and the attacker's session is
    // untouched: no cross-account metering in either direction.
    const charge = await chargeSession("victim", "s1", NOW + 60_000);
    expect(charge.remainingMinutes).toBe(55);
    expect(sessionDoc("s1")).toMatchObject({ uid: "attacker", chargedSeconds: 0 });
  });

  it("charges nothing for a session id that was never opened", async () => {
    const charge = await chargeSession("u1", "made-up", NOW + 60_000);
    expect(charge.remainingMinutes).toBe(5);
    expect(charge.allowed).toBe(true);
    expect(entitlementDoc()).toBeUndefined();
  });

  it("stops billing once the session is closed", async () => {
    await openSession("u1", "s1", NOW);
    await chargeSession("u1", "s1", NOW + 60_000, { close: true });
    const used = (entitlementDoc() as { freeMinutesUsed: number }).freeMinutesUsed;
    expect(used).toBeCloseTo(1, 3);

    // A late or replayed tick against the closed session adds nothing.
    await chargeSession("u1", "s1", NOW + 10 * 60_000);
    expect((entitlementDoc() as { freeMinutesUsed: number }).freeMinutesUsed)
      .toBeCloseTo(1, 3);
  });

  it("a single tick cannot bill more than the cap", async () => {
    await openSession("u1", "s1", NOW);
    // An hour of silence, then one tick: at most 90 s may be charged.
    await chargeSession("u1", "s1", NOW + 60 * 60_000);
    expect((entitlementDoc() as { freeMinutesUsed: number }).freeMinutesUsed)
      .toBeCloseTo(1.5, 3);
  });
});

describe("applying a verified subscription", () => {
  it("writes the plan the STORE reported", async () => {
    const entitlement = await applyVerified(
      "u1",
      {
        store: "apple",
        productId: PRODUCT_IDS.plus,
        status: "active",
        periodStart: NOW,
        periodEnd: NOW + 30 * 24 * 60 * MINUTE,
        eventId: "txn-1",
      },
      NOW,
    );
    expect(entitlement.plan).toBe("plus");
    expect(entitlement.minutesAllowance).toBe(35);
    expect(entitlementDoc()).toMatchObject({
      plan: "plus",
      store: "apple",
      storeProductId: PRODUCT_IDS.plus,
      minutesAllowance: 35,
    });
  });

  it("is idempotent: the same store event applied twice bills once", async () => {
    const verified = {
      store: "google" as const,
      productId: PRODUCT_IDS.pro,
      status: "active" as const,
      periodStart: NOW,
      periodEnd: NOW + 30 * 24 * 60 * MINUTE,
      eventId: "order-9",
    };
    await applyVerified("u1", verified, NOW);
    await openSession("u1", "s1", NOW);
    await chargeSession("u1", "s1", NOW + 60_000);
    expect((entitlementDoc() as { minutesUsed: number }).minutesUsed)
      .toBeCloseTo(1, 3);

    // Replaying the identical event must not reset the period's usage.
    await applyVerified("u1", verified, NOW + 2 * 60_000);
    expect((entitlementDoc() as { minutesUsed: number }).minutesUsed)
      .toBeCloseTo(1, 3);
  });

  it("an expired subscription leaves no paid allowance", async () => {
    await applyVerified(
      "u1",
      {
        store: "apple",
        productId: PRODUCT_IDS.pro,
        status: "active",
        periodStart: NOW,
        periodEnd: NOW + 30 * 24 * 60 * MINUTE,
        eventId: "txn-1",
      },
      NOW,
    );
    await applyVerified(
      "u1",
      {
        store: "apple",
        productId: PRODUCT_IDS.pro,
        status: "expired",
        periodStart: NOW,
        periodEnd: NOW + 30 * 24 * 60 * MINUTE,
        eventId: "txn-2",
      },
      NOW + 31 * 24 * 60 * MINUTE,
    );
    expect(entitlementDoc()).toMatchObject({ minutesAllowance: 0 });
    // Only whatever is left of the lifetime free minutes remains.
    const later = NOW + 31 * 24 * 60 * MINUTE;
    expect(await openSession("u1", "s9", later)).toEqual({
      sessionId: "s9",
      remainingMinutes: 5,
    });
  });
});

describe("stale sessions", () => {
  it("leaves a live session alone", async () => {
    await openSession("u1", "s1", NOW);
    await settleStaleSessions("u1", NOW + 30_000);
    expect(sessionDoc("s1")).toMatchObject({ closed: false, chargedSeconds: 0 });
  });

  it("closes and bills only sessions past the stale window", async () => {
    await openSession("u1", "s1", NOW);
    await settleStaleSessions("u1", NOW + (SESSION_STALE_SECONDS + 1) * 1000);
    expect(sessionDoc("s1")).toMatchObject({ closed: true });
    expect((entitlementDoc() as { freeMinutesUsed: number }).freeMinutesUsed)
      .toBeGreaterThan(0);
  });
});

describe("reading an entitlement", () => {
  it("an account that has never been seen reads as the free tier", async () => {
    const entitlement = await readEntitlement("nobody", NOW);
    expect(entitlement.plan).toBe("free");
    expect(entitlement.freeMinutesUsed).toBe(0);
    // Reading must not create the document — only a real session does.
    expect(fake.data.size).toBe(0);
  });
});
