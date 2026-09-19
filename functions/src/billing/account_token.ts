/**
 * The account identifier Sayvo attaches to a store purchase.
 *
 * Apple's `appAccountToken` must be a UUID, so the Firebase uid cannot be sent
 * as-is. A UUID v5 over the uid is stable, requires no storage, and leaks
 * nothing useful: it is derived from the uid, not reversible to it.
 *
 * The same derivation exists in the app (mobile/lib/utils/account_token.dart);
 * both sides must produce identical output, which a test in each pins down.
 */

import { createHash } from "node:crypto";

/** The standard RFC 4122 URL namespace, matching the app's `Namespace.url`. */
const URL_NAMESPACE = "6ba7b811-9dad-11d1-80b4-00c04fd430c8";

function namespaceBytes(uuid: string): Buffer {
  return Buffer.from(uuid.replace(/-/g, ""), "hex");
}

/** UUID v5 (SHA-1) of `sayvo:<uid>` in the URL namespace. */
export function accountTokenForUid(uid: string): string {
  const hash = createHash("sha1")
    .update(namespaceBytes(URL_NAMESPACE))
    .update(Buffer.from(`sayvo:${uid}`, "utf8"))
    .digest();

  const bytes = Buffer.from(hash.subarray(0, 16));
  bytes[6] = (bytes[6] & 0x0f) | 0x50; // version 5
  bytes[8] = (bytes[8] & 0x3f) | 0x80; // RFC 4122 variant

  const hex = bytes.toString("hex");
  return (
    `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-` +
    `${hex.slice(16, 20)}-${hex.slice(20)}`
  );
}

/**
 * Whether a token the store reported belongs to this account.
 *
 * A purchase made before the app started sending one has no token at all,
 * which is not suspicious. A token that belongs to a DIFFERENT account is —
 * though the ownership claim in store.ts is what actually enforces it; this
 * only makes the anomaly visible.
 */
export function accountTokenMatches(
  uid: string,
  token: string | null | undefined,
): boolean {
  if (!token) return true;
  return token.toLowerCase() === accountTokenForUid(uid).toLowerCase();
}
