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

/**
 * Included minutes of TRANSLATED SPEECH per billing period.
 *
 * A Sayvo minute is a minute of speech that Sayvo actually translated — not a
 * minute of the microphone being switched on. Silence, waiting, background
 * noise that produces nothing, and the app's own spoken playback all cost
 * zero. See usage.ts for how that is measured and accounted.
 */
export const PLAN_MINUTES: Record<Exclude<Plan, "free">, number> = {
  basic: 15,
  plus: 35,
  pro: 55,
};

/**
 * One-time allowance for a brand new account — five minutes of translated
 * speech for the LIFETIME of the account, not five per month. It lives on the
 * server so reinstalling the app cannot hand out another five.
 */
export const FREE_LIFETIME_MINUTES = 5;

export const MS_PER_MINUTE = 60_000;

/**
 * Allowances in MILLISECONDS, which is the unit everything is accounted in.
 * Usage is never rounded up to a whole minute: three utterances of 10 s, 17 s
 * and 21 s cost 48 seconds, not three minutes. Minutes exist only for display.
 */
export const PLAN_ALLOWANCE_MS: Record<Exclude<Plan, "free">, number> = {
  basic: PLAN_MINUTES.basic * MS_PER_MINUTE,
  plus: PLAN_MINUTES.plus * MS_PER_MINUTE,
  pro: PLAN_MINUTES.pro * MS_PER_MINUTE,
};

export const FREE_LIFETIME_MS = FREE_LIFETIME_MINUTES * MS_PER_MINUTE;

const PLAN_BY_PRODUCT_ID = new Map<string, Exclude<Plan, "free">>(
  (Object.entries(PRODUCT_IDS) as [Exclude<Plan, "free">, string][]).map(
    ([plan, id]) => [id, plan],
  ),
);

/** null for anything that is not one of our three subscriptions. */
export function planForProductId(productId: string): Exclude<Plan, "free"> | null {
  return PLAN_BY_PRODUCT_ID.get(productId) ?? null;
}

/** Included translated-speech milliseconds for a plan. */
export function allowanceMsForPlan(plan: Plan): number {
  return plan === "free" ? FREE_LIFETIME_MS : PLAN_ALLOWANCE_MS[plan];
}
