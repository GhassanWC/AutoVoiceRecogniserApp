/// Sayvo's subscription catalog, mirroring functions/src/billing/plans.ts.
///
/// PRICES ARE DELIBERATELY ABSENT. The only price ever shown to a user is the
/// localized one the App Store or Google Play returns for the product, so the
/// app cannot disagree with what the store will actually charge.
enum SayvoPlan { free, basic, plus, pro }

/// Store product ids — identical on both platforms.
const String kBasicProductId = 'sayvo_basic_monthly';
const String kPlusProductId = 'sayvo_plus_monthly';
const String kProProductId = 'sayvo_pro_monthly';

/// One-time allowance for a new account, for the LIFETIME of the account.
const int kFreeLifetimeMinutes = 5;

/// Included minutes of TRANSLATED SPEECH per billing period.
///
/// A Sayvo minute is a minute of speech Sayvo translated — not a minute of the
/// microphone being switched on. Listening to a silent room costs nothing.
const Map<SayvoPlan, int> kPlanMinutes = {
  SayvoPlan.free: kFreeLifetimeMinutes,
  SayvoPlan.basic: 15,
  SayvoPlan.plus: 35,
  SayvoPlan.pro: 55,
};

const int kMsPerMinute = 60000;

/// Everything is accounted in milliseconds; minutes are for reading.
const int kFreeLifetimeMs = kFreeLifetimeMinutes * kMsPerMinute;

int planAllowanceMs(SayvoPlan plan) => planMinutes(plan) * kMsPerMinute;

/// "12m 24s" / "48s" / "1h 04m" — friendly, and never rounded up to a whole
/// minute, because a user who spoke for ten seconds did not spend a minute.
String formatSpeechDuration(int milliseconds) {
  final total = milliseconds < 0 ? 0 : milliseconds;
  final seconds = total ~/ 1000;
  if (seconds < 60) return '${seconds}s';
  final minutes = seconds ~/ 60;
  if (minutes < 60) {
    final remainder = seconds % 60;
    return remainder == 0 ? '${minutes}m' : '${minutes}m ${remainder}s';
  }
  final hours = minutes ~/ 60;
  final remainder = minutes % 60;
  return '${hours}h ${remainder.toString().padLeft(2, '0')}m';
}

const Map<SayvoPlan, String> kPlanProductIds = {
  SayvoPlan.basic: kBasicProductId,
  SayvoPlan.plus: kPlusProductId,
  SayvoPlan.pro: kProProductId,
};

/// The paid plans, in display order. Plus is the recommended one.
const List<SayvoPlan> kPurchasablePlans = [
  SayvoPlan.basic,
  SayvoPlan.plus,
  SayvoPlan.pro,
];

const SayvoPlan kRecommendedPlan = SayvoPlan.plus;

/// All product ids the app asks the store about.
Set<String> get kAllProductIds => kPlanProductIds.values.toSet();

String planDisplayName(SayvoPlan plan) => switch (plan) {
      SayvoPlan.free => 'Free',
      SayvoPlan.basic => 'Sayvo Basic',
      SayvoPlan.plus => 'Sayvo Plus',
      SayvoPlan.pro => 'Sayvo Pro',
    };

int planMinutes(SayvoPlan plan) => kPlanMinutes[plan] ?? 0;

SayvoPlan? planFromId(String? id) => switch (id) {
      'free' => SayvoPlan.free,
      'basic' => SayvoPlan.basic,
      'plus' => SayvoPlan.plus,
      'pro' => SayvoPlan.pro,
      _ => null,
    };

SayvoPlan? planForProductId(String productId) => switch (productId) {
      kBasicProductId => SayvoPlan.basic,
      kPlusProductId => SayvoPlan.plus,
      kProProductId => SayvoPlan.pro,
      _ => null,
    };
