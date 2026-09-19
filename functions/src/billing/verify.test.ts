import { describe, expect, it } from "vitest";

import { accessFor, applyVerifiedSubscription, freshEntitlement } from "./entitlement.js";
import { PLAN_ALLOWANCE_MS, PRODUCT_IDS } from "./plans.js";
import { Environment } from "@apple/app-store-server-library";

import {
  BillingConfigError,
  BillingVerificationError,
  appleRootCertificates,
  mapAppleTransaction,
  mapGoogleSubscription,
  verifyAppleTransaction,
  verifyGoogleSubscription,
} from "./verify.js";

const T0 = Date.parse("2026-09-19T10:00:00Z");
const MONTH = 30 * 24 * 60 * 60 * 1000;

describe("Apple mapping", () => {
  const payload = {
    productId: PRODUCT_IDS.plus,
    transactionId: "2000000999",
    originalTransactionId: "2000000111",
    purchaseDate: T0,
    expiresDate: T0 + MONTH,
  };

  it("maps an active subscription", () => {
    const verified = mapAppleTransaction(payload, 1);
    expect(verified.store).toBe("apple");
    expect(verified.productId).toBe(PRODUCT_IDS.plus);
    expect(verified.status).toBe("active");
    expect(verified.periodEnd).toBe(T0 + MONTH);
  });

  it("carries the ORIGINAL transaction id as the re-query handle", () => {
    // Renewals get a new transactionId, so only the original one can be used
    // to ask Apple about the subscription later.
    expect(mapAppleTransaction(payload, 1).handle).toBe("2000000111");
    expect(
      mapAppleTransaction(
        { ...payload, transactionId: "2000001000", purchaseDate: T0 + MONTH },
        1,
      ).handle,
    ).toBe("2000000111");
  });

  it("maps billing retry and grace to a still-entitled state", () => {
    expect(mapAppleTransaction(payload, 3).status).toBe("grace");
    expect(mapAppleTransaction(payload, 4).status).toBe("grace");
  });

  it("treats a revocation date as revoked whatever the status says", () => {
    const refunded = mapAppleTransaction(
      { ...payload, revocationDate: T0 + 2000 },
      1,
    );
    expect(refunded.status).toBe("revoked");
  });

  it("gives each renewal its own event id so renewals apply but replays do not", () => {
    const first = mapAppleTransaction(payload, 1);
    const renewal = mapAppleTransaction(
      { ...payload, transactionId: "2000001000", purchaseDate: T0 + MONTH },
      1,
    );
    expect(first.eventId).not.toBe(renewal.eventId);
    expect(mapAppleTransaction(payload, 1).eventId).toBe(first.eventId);
  });

  it("refuses a payload without identifiers", () => {
    expect(() => mapAppleTransaction({ productId: PRODUCT_IDS.pro }, 1)).toThrow(
      BillingVerificationError,
    );
  });

  it("fails CLOSED when Apple credentials are missing", async () => {
    await expect(verifyAppleTransaction("2000000999", null)).rejects.toBeInstanceOf(
      BillingConfigError,
    );
    await expect(
      verifyAppleTransaction("2000000999", { issuerId: "only-this" }),
    ).rejects.toBeInstanceOf(BillingConfigError);
  });

  it("fails CLOSED when Apple's root certificates are not deployed", async () => {
    // Everything else configured, but no certificates to check signatures
    // against: no entitlement may be granted on trust alone.
    await expect(
      verifyAppleTransaction("2000000999", {
        issuerId: "issuer",
        keyId: "key",
        privateKey: "-----BEGIN PRIVATE KEY-----",
        bundleId: "com.example.app",
        environment: Environment.PRODUCTION,
        rootCertificates: [],
      }),
    ).rejects.toBeInstanceOf(BillingConfigError);
  });

  it("reports an empty certificate list for a directory that is not there",
    () => {
      expect(appleRootCertificates("./definitely-not-a-directory")).toEqual([]);
    });
});

describe("Google Play mapping", () => {
  const response = {
    subscriptionState: "SUBSCRIPTION_STATE_ACTIVE",
    latestOrderId: "GPA.1234-5678",
    startTime: new Date(T0).toISOString(),
    lineItems: [
      {
        productId: PRODUCT_IDS.pro,
        expiryTime: new Date(T0 + MONTH).toISOString(),
      },
    ],
  };

  it("maps an active subscription", () => {
    const verified = mapGoogleSubscription(response, "token-abcdefghijklmnop");
    expect(verified.store).toBe("google");
    expect(verified.productId).toBe(PRODUCT_IDS.pro);
    expect(verified.status).toBe("active");
    expect(verified.periodStart).toBe(T0);
    expect(verified.periodEnd).toBe(T0 + MONTH);
    // The token is how the server asks Play about this subscription again.
    expect(verified.handle).toBe("token-abcdefghijklmnop");
  });

  it("keeps a cancelled-but-paid subscription entitled until it expires", () => {
    const cancelled = mapGoogleSubscription(
      { ...response, subscriptionState: "SUBSCRIPTION_STATE_CANCELED" },
      "token-abcdefghijklmnop",
    );
    expect(cancelled.status).toBe("active");
    const entitlement = applyVerifiedSubscription(
      freshEntitlement(T0),
      cancelled,
      T0,
    ).entitlement;
    expect(accessFor(entitlement, T0 + 5000).remainingMs).toBe(PLAN_ALLOWANCE_MS.pro);
    // ...and stops the moment the paid period ends.
    expect(accessFor(entitlement, T0 + MONTH + 1).source).toBe("free");
  });

  it("maps expiry", () => {
    expect(
      mapGoogleSubscription(
        { ...response, subscriptionState: "SUBSCRIPTION_STATE_EXPIRED" },
        "t",
      ).status,
    ).toBe("expired");
  });

  it("a pending purchase grants nothing", () => {
    const pending = mapGoogleSubscription(
      { ...response, subscriptionState: "SUBSCRIPTION_STATE_PENDING" },
      "token-pending-1234567890",
    );
    expect(pending.status).toBe("none");
    const result = applyVerifiedSubscription(freshEntitlement(T0), pending, T0);
    // "none" is not an entitled status, so the user stays on free minutes.
    expect(accessFor(result.entitlement, T0).source).toBe("free");
  });

  it("refuses a response with no product", () => {
    expect(() => mapGoogleSubscription({ lineItems: [] }, "t")).toThrow(
      BillingVerificationError,
    );
  });

  it("fails CLOSED when the package name is not configured", async () => {
    await expect(verifyGoogleSubscription("token", null)).rejects.toBeInstanceOf(
      BillingConfigError,
    );
  });

  it("rejects a token Play does not recognise", async () => {
    await expect(
      verifyGoogleSubscription("bogus", {
        packageName: "com.example",
        accessToken: async () => "test-token",
        fetchFn: (async () =>
          new Response("no", { status: 404 })) as unknown as typeof fetch,
      }),
    ).rejects.toBeInstanceOf(BillingVerificationError);
  });

  it("verifies end to end against a Play-shaped response", async () => {
    const verified = await verifyGoogleSubscription("token-xyz-0123456789", {
      packageName: "com.livetranslator.live_translator",
      accessToken: async () => "test-token",
      fetchFn: (async () =>
        new Response(JSON.stringify(response), { status: 200 })) as unknown as typeof fetch,
    });
    const entitlement = applyVerifiedSubscription(
      freshEntitlement(T0),
      verified,
      T0,
    ).entitlement;
    expect(entitlement.plan).toBe("pro");
    expect(entitlement.allowanceMs).toBe(PLAN_ALLOWANCE_MS.pro);
  });

  it("carries Play's obfuscated account id as the account token", () => {
    const withAccount = mapGoogleSubscription(
      {
        ...response,
        externalAccountIdentifiers: {
          obfuscatedExternalAccountId: "9e65ab7b-6d88-590e-a831-0012d8bac0ae",
        },
      },
      "token-abcdefghijklmnop",
    );
    expect(withAccount.accountToken).toBe("9e65ab7b-6d88-590e-a831-0012d8bac0ae");
  });
});

describe("Google Play acknowledgement", () => {
  const pendingAck = {
    subscriptionState: "SUBSCRIPTION_STATE_ACTIVE",
    acknowledgementState: "ACKNOWLEDGEMENT_STATE_PENDING",
    latestOrderId: "GPA.1111-2222",
    startTime: new Date(T0).toISOString(),
    lineItems: [
      {
        productId: PRODUCT_IDS.plus,
        expiryTime: new Date(T0 + MONTH).toISOString(),
      },
    ],
  };

  /** Records every request so the acknowledge call can be asserted. */
  function recordingFetch(acknowledgeStatus = 200) {
    const calls: { url: string; method: string }[] = [];
    const fetchFn = (async (url: string, init?: { method?: string }) => {
      calls.push({ url: String(url), method: init?.method ?? "GET" });
      if (String(url).endsWith(":acknowledge")) {
        return new Response("{}", { status: acknowledgeStatus });
      }
      return new Response(JSON.stringify(pendingAck), { status: 200 });
    }) as unknown as typeof fetch;
    return { calls, fetchFn };
  }

  it("acknowledges a purchase Play is still waiting on", async () => {
    const { calls, fetchFn } = recordingFetch();
    const verified = await verifyGoogleSubscription("token-to-ack", {
      packageName: "com.livetranslator.live_translator",
      accessToken: async () => "test-token",
      fetchFn,
    });
    expect(verified.acknowledged).toBe(true);
    const ack = calls.find((c) => c.url.endsWith(":acknowledge"));
    expect(ack?.method).toBe("POST");
    // Acknowledgement is per product + token.
    expect(ack?.url).toContain(PRODUCT_IDS.plus);
    expect(ack?.url).toContain("token-to-ack");
  });

  it("does not acknowledge a purchase Play has already acknowledged", async () => {
    const calls: string[] = [];
    const verified = await verifyGoogleSubscription("token-done", {
      packageName: "com.livetranslator.live_translator",
      accessToken: async () => "test-token",
      fetchFn: (async (url: string) => {
        calls.push(String(url));
        return new Response(
          JSON.stringify({
            ...pendingAck,
            acknowledgementState: "ACKNOWLEDGEMENT_STATE_ACKNOWLEDGED",
          }),
          { status: 200 },
        );
      }) as unknown as typeof fetch,
    });
    expect(verified.acknowledged).toBe(true);
    expect(calls.some((url) => url.endsWith(":acknowledge"))).toBe(false);
  });

  it("a repeat acknowledgement is safe: the purchase still verifies", async () => {
    // Play answers 400 for an already-acknowledged purchase. That is not a
    // verification failure, and the entitlement must still be granted.
    const { fetchFn } = recordingFetch(400);
    const verified = await verifyGoogleSubscription("token-again", {
      packageName: "com.livetranslator.live_translator",
      accessToken: async () => "test-token",
      fetchFn,
    });
    expect(verified.productId).toBe(PRODUCT_IDS.plus);
    expect(verified.status).toBe("active");
    // Undefined means "we could not confirm it", which the caller logs.
    expect(verified.acknowledged).toBeUndefined();
  });

  it("never acknowledges a purchase that was never paid for", async () => {
    const calls: string[] = [];
    await verifyGoogleSubscription("token-pending", {
      packageName: "com.livetranslator.live_translator",
      accessToken: async () => "test-token",
      fetchFn: (async (url: string) => {
        calls.push(String(url));
        return new Response(
          JSON.stringify({
            ...pendingAck,
            subscriptionState: "SUBSCRIPTION_STATE_PENDING",
          }),
          { status: 200 },
        );
      }) as unknown as typeof fetch,
    });
    expect(calls.some((url) => url.endsWith(":acknowledge"))).toBe(false);
  });
});
