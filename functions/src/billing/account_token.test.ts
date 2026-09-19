import { describe, expect, it } from "vitest";

import { accountTokenForUid, accountTokenMatches } from "./account_token.js";

describe("the account token attached to a purchase", () => {
  it("matches the app's derivation exactly", () => {
    // Pinned on both sides: mobile/test/subscription_test.dart asserts the
    // same uid produces this same UUID. If either derivation drifts, a
    // purchase would look as though it belonged to somebody else.
    expect(accountTokenForUid("uid-abc123")).toBe(
      "9e65ab7b-6d88-590e-a831-0012d8bac0ae",
    );
  });

  it("is a well-formed v5 UUID, which is what Apple requires", () => {
    const token = accountTokenForUid("some-firebase-uid");
    expect(token).toMatch(
      /^[0-9a-f]{8}-[0-9a-f]{4}-5[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/,
    );
  });

  it("is stable for one account and different for another", () => {
    expect(accountTokenForUid("a")).toBe(accountTokenForUid("a"));
    expect(accountTokenForUid("a")).not.toBe(accountTokenForUid("b"));
  });

  it("accepts a purchase that carries no token at all", () => {
    // Purchases made before the app started sending one are not suspicious.
    expect(accountTokenMatches("uid-abc123", null)).toBe(true);
    expect(accountTokenMatches("uid-abc123", undefined)).toBe(true);
    expect(accountTokenMatches("uid-abc123", "")).toBe(true);
  });

  it("spots a token belonging to a different account", () => {
    expect(accountTokenMatches("uid-abc123", accountTokenForUid("uid-abc123")))
      .toBe(true);
    expect(accountTokenMatches("uid-abc123", accountTokenForUid("somebody-else")))
      .toBe(false);
  });

  it("ignores the case the store echoes the token back in", () => {
    const upper = accountTokenForUid("uid-abc123").toUpperCase();
    expect(accountTokenMatches("uid-abc123", upper)).toBe(true);
  });
});
