/**
 * Store-side purchase verification.
 *
 * NOTHING here trusts the client. The app sends only an opaque handle — an
 * Apple transaction id or a Google purchase token — and the entitlement that
 * results is built from what APPLE or GOOGLE says about that handle, never
 * from a product id or plan the client asserts.
 *
 * Credentials live in Secret Manager and are injected by index.ts. When they
 * are absent this module FAILS CLOSED (BillingConfigError) rather than
 * granting anything: an unconfigured backend must never hand out Pro.
 */

import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";

import {
  AppStoreServerAPIClient,
  Environment,
  SignedDataVerifier,
} from "@apple/app-store-server-library";
import { GoogleAuth } from "google-auth-library";

import { SubscriptionStatus, VerifiedSubscription } from "./entitlement.js";

export class BillingConfigError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "BillingConfigError";
  }
}

export class BillingVerificationError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "BillingVerificationError";
  }
}

// ── Apple ────────────────────────────────────────────────────────────────────

/** Apple's auto-renewable subscription status codes. */
const APPLE_STATUS: Record<number, SubscriptionStatus> = {
  1: "active", // active
  2: "expired", // expired
  3: "grace", // billing retry
  4: "grace", // billing grace period
  5: "revoked", // revoked
};

export interface AppleTransactionPayload {
  productId?: string;
  originalTransactionId?: string;
  transactionId?: string;
  purchaseDate?: number;
  expiresDate?: number;
  revocationDate?: number;
}

/**
 * Maps Apple's decoded transaction + subscription status onto our verified
 * shape. Pure, so the mapping rules are unit-tested without Apple's servers.
 */
export function mapAppleTransaction(
  payload: AppleTransactionPayload,
  statusCode: number,
  notificationId?: string,
): VerifiedSubscription {
  const productId = payload.productId;
  const transactionId = payload.transactionId ?? payload.originalTransactionId;
  if (!productId || !transactionId) {
    throw new BillingVerificationError("Apple transaction is missing identifiers");
  }
  // A refund wins over whatever the status says.
  const status: SubscriptionStatus = payload.revocationDate
    ? "revoked"
    : (APPLE_STATUS[statusCode] ?? "expired");
  const periodStart = payload.purchaseDate ?? 0;
  const periodEnd = payload.expiresDate ?? periodStart;
  return {
    store: "apple",
    productId,
    status,
    // The ORIGINAL id survives renewals, so it is what we re-query with.
    handle: payload.originalTransactionId ?? transactionId,
    periodStart,
    periodEnd,
    // Per-period id: a renewal has a NEW transactionId, so renewals apply
    // while replays of the same transaction do not.
    eventId: notificationId ? `apple:${transactionId}:${notificationId}` : `apple:${transactionId}`,
  };
}

export interface AppleDeps {
  issuerId: string;
  keyId: string;
  /** Contents of the .p8 App Store Connect API key. */
  privateKey: string;
  bundleId: string;
  environment: Environment;
  appAppleId?: number;
  /** Apple root certificates (DER), required for signature verification. */
  rootCertificates: Buffer[];
}

function requireAppleDeps(deps: Partial<AppleDeps> | null): AppleDeps {
  if (
    !deps?.issuerId ||
    !deps.keyId ||
    !deps.privateKey ||
    !deps.bundleId ||
    !deps.rootCertificates?.length
  ) {
    throw new BillingConfigError(
      "Apple App Store verification is not configured (issuerId, keyId, .p8 " +
        "private key, bundleId, and Apple's root certificates in " +
        "functions/apple-root-certs are all required).",
    );
  }
  return deps as AppleDeps;
}

/**
 * Apple's PUBLIC root CA certificates, which the library needs to check the
 * signature on everything Apple sends back. They are certificates, not
 * secrets, so they ship with the functions bundle rather than living in
 * Secret Manager. An empty result makes verification fail closed.
 */
let cachedRootCertificates: Buffer[] | null = null;
export function appleRootCertificates(directory?: string): Buffer[] {
  if (cachedRootCertificates && !directory) return cachedRootCertificates;
  // The functions package root, both under `firebase deploy` and vitest.
  const dir =
    directory ??
    process.env.APPLE_ROOT_CERT_DIR ??
    join(process.cwd(), "apple-root-certs");
  let certificates: Buffer[] = [];
  try {
    certificates = readdirSync(dir)
      .filter((name) => name.endsWith(".cer") || name.endsWith(".der"))
      .sort()
      .map((name) => readFileSync(join(dir, name)));
  } catch {
    // Missing directory: leave the list empty so callers fail closed.
    certificates = [];
  }
  if (!directory) cachedRootCertificates = certificates;
  return certificates;
}

/**
 * Asks Apple about [transactionId] and returns what Apple says. The signed
 * payloads are verified against Apple's root certificates by the official
 * library — an unsigned or tampered payload throws instead of granting.
 *
 * A TestFlight or sandbox purchase does not exist in Production, so both
 * environments are tried; the environment is never taken from the client.
 */
export async function verifyAppleTransaction(
  transactionId: string,
  rawDeps: Partial<AppleDeps> | null,
): Promise<VerifiedSubscription> {
  const deps = requireAppleDeps(rawDeps);
  const order =
    deps.environment === Environment.SANDBOX
      ? [Environment.SANDBOX, Environment.PRODUCTION]
      : [Environment.PRODUCTION, Environment.SANDBOX];

  let lastError: unknown;
  for (const environment of order) {
    try {
      return await lookupAppleTransaction(transactionId, {
        ...deps,
        environment,
      });
    } catch (error) {
      lastError = error;
    }
  }
  throw lastError instanceof BillingVerificationError
    ? lastError
    : new BillingVerificationError(
        `Apple could not verify that transaction: ${
          lastError instanceof Error ? lastError.message : String(lastError)
        }`,
      );
}

async function lookupAppleTransaction(
  transactionId: string,
  deps: AppleDeps,
): Promise<VerifiedSubscription> {
  const client = new AppStoreServerAPIClient(
    deps.privateKey,
    deps.keyId,
    deps.issuerId,
    deps.bundleId,
    deps.environment,
  );
  const verifier = new SignedDataVerifier(
    deps.rootCertificates,
    true,
    deps.environment,
    deps.bundleId,
    deps.appAppleId,
  );

  const statuses = await client.getAllSubscriptionStatuses(transactionId);
  for (const group of statuses.data ?? []) {
    for (const item of group.lastTransactions ?? []) {
      if (!item.signedTransactionInfo) continue;
      const decoded = await verifier.verifyAndDecodeTransaction(
        item.signedTransactionInfo,
      );
      if (decoded.transactionId !== transactionId &&
          decoded.originalTransactionId !== transactionId) {
        continue;
      }
      return mapAppleTransaction(
        decoded as AppleTransactionPayload,
        item.status ?? 2,
      );
    }
  }
  throw new BillingVerificationError(
    "Apple returned no subscription for that transaction",
  );
}

// ── Google Play ──────────────────────────────────────────────────────────────

/** subscriptionsv2 state strings we care about. */
const GOOGLE_STATUS: Record<string, SubscriptionStatus> = {
  SUBSCRIPTION_STATE_ACTIVE: "active",
  SUBSCRIPTION_STATE_IN_GRACE_PERIOD: "grace",
  SUBSCRIPTION_STATE_ON_HOLD: "grace",
  SUBSCRIPTION_STATE_PAUSED: "expired",
  SUBSCRIPTION_STATE_CANCELED: "active", // cancelled but paid until periodEnd
  SUBSCRIPTION_STATE_EXPIRED: "expired",
  SUBSCRIPTION_STATE_PENDING: "none",
};

export interface GoogleSubscriptionV2 {
  subscriptionState?: string;
  latestOrderId?: string;
  lineItems?: {
    productId?: string;
    expiryTime?: string;
    offerDetails?: { basePlanId?: string };
  }[];
  startTime?: string;
}

/** Pure mapping of Play's subscriptionsv2 response — unit-tested. */
export function mapGoogleSubscription(
  response: GoogleSubscriptionV2,
  purchaseToken: string,
): VerifiedSubscription {
  const line = response.lineItems?.[0];
  const productId = line?.productId;
  if (!productId) {
    throw new BillingVerificationError("Play response has no product");
  }
  const state = response.subscriptionState ?? "";
  const status: SubscriptionStatus = GOOGLE_STATUS[state] ?? "expired";
  const periodStart = response.startTime ? Date.parse(response.startTime) : 0;
  const periodEnd = line.expiryTime ? Date.parse(line.expiryTime) : periodStart;
  // orderId changes per renewal, so renewals apply and replays do not. The
  // token is included so two users cannot collide.
  const orderId = response.latestOrderId ?? String(periodEnd);
  return {
    store: "google",
    productId,
    status,
    // A purchase token stays valid for the life of the subscription.
    handle: purchaseToken,
    periodStart,
    periodEnd,
    eventId: `google:${purchaseToken.slice(-24)}:${orderId}`,
  };
}

export interface GoogleDeps {
  packageName: string;
  /** Injected for tests; defaults to Application Default Credentials. */
  fetchFn?: typeof fetch;
  accessToken?: () => Promise<string>;
}

async function defaultAccessToken(): Promise<string> {
  const auth = new GoogleAuth({
    scopes: ["https://www.googleapis.com/auth/androidpublisher"],
  });
  const token = await auth.getAccessToken();
  if (!token) {
    throw new BillingConfigError(
      "No Google Play access token: grant the functions service account " +
        "access in Play Console and enable the Android Publisher API.",
    );
  }
  return token;
}

/** Asks Google Play about [purchaseToken] and returns what Play says. */
export async function verifyGoogleSubscription(
  purchaseToken: string,
  deps: GoogleDeps | null,
): Promise<VerifiedSubscription> {
  if (!deps?.packageName) {
    throw new BillingConfigError("Google Play packageName is not configured.");
  }
  const doFetch = deps.fetchFn ?? fetch;
  const token = await (deps.accessToken ?? defaultAccessToken)();
  const url =
    `https://androidpublisher.googleapis.com/androidpublisher/v3/applications/` +
    `${encodeURIComponent(deps.packageName)}/purchases/subscriptionsv2/tokens/` +
    `${encodeURIComponent(purchaseToken)}`;

  const response = await doFetch(url, {
    headers: { Authorization: `Bearer ${token}` },
  });
  if (!response.ok) {
    throw new BillingVerificationError(
      `Play verification failed (${response.status})`,
    );
  }
  return mapGoogleSubscription(
    (await response.json()) as GoogleSubscriptionV2,
    purchaseToken,
  );
}
