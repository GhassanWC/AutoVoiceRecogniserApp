import '../../utils/plans.dart';

/// What the SERVER says this account may do. Every field here is read-only to
/// the app: entitlements live in a Firestore collection the client cannot
/// write, and only Cloud Functions change them after Apple or Google has
/// verified a purchase.
class Entitlement {
  const Entitlement({
    required this.plan,
    required this.subscriptionStatus,
    required this.minutesAllowance,
    required this.minutesUsed,
    required this.freeMinutesUsed,
    required this.remainingMinutes,
    required this.allowanceSource,
    this.store,
    this.storeProductId,
    this.currentPeriodStart,
    this.currentPeriodEnd,
  });

  final SayvoPlan plan;
  final String subscriptionStatus;
  final int minutesAllowance;
  final double minutesUsed;
  final double freeMinutesUsed;
  final double remainingMinutes;

  /// 'plan' while a paid subscription is live, otherwise 'free'.
  final String allowanceSource;
  final String? store;
  final String? storeProductId;
  final DateTime? currentPeriodStart;
  final DateTime? currentPeriodEnd;

  /// A brand new account: five free minutes for the lifetime of the account.
  static const Entitlement free = Entitlement(
    plan: SayvoPlan.free,
    subscriptionStatus: 'none',
    minutesAllowance: 0,
    minutesUsed: 0,
    freeMinutesUsed: 0,
    remainingMinutes: kFreeLifetimeMinutes * 1.0,
    allowanceSource: 'free',
  );

  bool get isPaid => plan != SayvoPlan.free && allowanceSource == 'plan';
  bool get hasMinutesLeft => remainingMinutes > 0;

  /// Minutes included in whichever allowance is currently in force.
  double get totalMinutes =>
      allowanceSource == 'plan' ? minutesAllowance.toDouble() : kFreeLifetimeMinutes.toDouble();

  double get usedMinutes =>
      allowanceSource == 'plan' ? minutesUsed : freeMinutesUsed;

  static DateTime? _date(Object? value) {
    if (value is int) return DateTime.fromMillisecondsSinceEpoch(value);
    if (value is double) return DateTime.fromMillisecondsSinceEpoch(value.round());
    return null;
  }

  static double _number(Object? value) {
    if (value is num) return value.toDouble();
    return 0;
  }

  /// Parses either the Firestore document or the getEntitlement callable
  /// response — both carry the same field names.
  factory Entitlement.fromMap(Map<String, dynamic> data) {
    final plan = planFromId(data['plan'] as String?) ?? SayvoPlan.free;
    final source = data['allowanceSource'] as String? ??
        (plan == SayvoPlan.free ? 'free' : 'plan');
    final allowance = (data['minutesAllowance'] as num?)?.toInt() ?? 0;
    final used = _number(data['minutesUsed']);
    final freeUsed = _number(data['freeMinutesUsed']);
    // Prefer the server's computed remainder; fall back to deriving it so a
    // raw document read still shows something sensible.
    final remaining = data.containsKey('remainingMinutes')
        ? _number(data['remainingMinutes'])
        : (source == 'plan'
            ? (allowance - used)
            : (kFreeLifetimeMinutes - freeUsed));
    return Entitlement(
      plan: plan,
      subscriptionStatus: data['subscriptionStatus'] as String? ?? 'none',
      store: data['store'] as String?,
      storeProductId: data['storeProductId'] as String?,
      currentPeriodStart: _date(data['currentPeriodStart']),
      currentPeriodEnd: _date(data['currentPeriodEnd']),
      minutesAllowance: allowance,
      minutesUsed: used,
      freeMinutesUsed: freeUsed,
      remainingMinutes: remaining < 0 ? 0 : remaining,
      allowanceSource: source,
    );
  }
}
