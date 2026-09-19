/**
 * Sayvo subscription catalog.
 *
 * PRICES ARE NOT HERE ON PURPOSE. The authoritative, localized price always
 * comes from App Store Connect / Google Play product metadata and is shown to
 * the user from the store's own response. The server only ever maps a
 * STORE-VERIFIED product id to a plan and its included minutes.
 */

export type Plan = "free" | "basic" | "plus" | "pro";

/** Product ids, identical on both stores so plans stay platform-neutral. */
export const PRODUCT_IDS: Record<Exclude<Plan, "free">, string> = {
  basic: "sayvo_basic_monthly",
  plus: "sayvo_plus_monthly",
  pro: "sayvo_pro_monthly",
};

/** Included Live Translation minutes per BILLING PERIOD for paid plans. */
export const PLAN_MINUTES: Record<Exclude<Plan, "free">, number> = {
  basic: 15,
  plus: 35,
  pro: 55,
};

/**
 * One-time allowance for a brand new account — five minutes for the LIFETIME
 * of the account, not five per month. It lives on the server so reinstalling
 * the app cannot hand out another five.
 */
export const FREE_LIFETIME_MINUTES = 5;

const PLAN_BY_PRODUCT_ID = new Map<string, Exclude<Plan, "free">>(
  (Object.entries(PRODUCT_IDS) as [Exclude<Plan, "free">, string][]).map(
    ([plan, id]) => [id, plan],
  ),
);

/** null for anything that is not one of our three subscriptions. */
export function planForProductId(productId: string): Exclude<Plan, "free"> | null {
  return PLAN_BY_PRODUCT_ID.get(productId) ?? null;
}

export function minutesForPlan(plan: Plan): number {
  return plan === "free" ? FREE_LIFETIME_MINUTES : PLAN_MINUTES[plan];
}
