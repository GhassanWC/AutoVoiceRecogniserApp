import '../../utils/plans.dart';

/// What the SERVER says this account may do. Every field here is read-only to
/// the app: entitlements live in a Firestore collection the client cannot
/// write, and only Cloud Functions change them after Apple or Google has
/// verified a purchase.
///
/// The unit is MILLISECONDS OF TRANSLATED SPEECH, not microphone time. Minutes
/// exist only where a person reads them.
class Entitlement {
  const Entitlement({
    required this.plan,
    required this.subscriptionStatus,
    required this.allowanceMs,
    required this.usedMs,
    required this.freeUsedMs,
    required this.remainingMs,
    required this.allowanceSource,
    this.store,
    this.storeProductId,
    this.currentPeriodStart,
    this.currentPeriodEnd,
  });

  final SayvoPlan plan;
  final String subscriptionStatus;

  /// Included translated-speech ms for the allowance in force.
  final int allowanceMs;

  /// Translated-speech ms used against the paid period.
  final int usedMs;

  /// Translated-speech ms used against the one-time free allowance.
  final int freeUsedMs;
  final int remainingMs;

  /// 'plan' while a paid subscription is live, otherwise 'free'.
  final String allowanceSource;
  final String? store;
  final String? storeProductId;
  final DateTime? currentPeriodStart;
  final DateTime? currentPeriodEnd;

  /// A brand new account: five minutes of translated speech for the lifetime
  /// of the account.
  static const Entitlement free = Entitlement(
    plan: SayvoPlan.free,
    subscriptionStatus: 'none',
    allowanceMs: kFreeLifetimeMs,
    usedMs: 0,
    freeUsedMs: 0,
    remainingMs: kFreeLifetimeMs,
    allowanceSource: 'free',
  );

  bool get isPaid => plan != SayvoPlan.free && allowanceSource == 'plan';
  bool get hasSpeechLeft => remainingMs > 0;

  /// Included ms of whichever allowance is currently in force.
  int get totalMs =>
      allowanceSource == 'plan' ? allowanceMs : kFreeLifetimeMs;

  /// Translated-speech ms spent against the allowance in force.
  int get spentMs => allowanceSource == 'plan' ? usedMs : freeUsedMs;

  static DateTime? _date(Object? value) {
    if (value is int) return DateTime.fromMillisecondsSinceEpoch(value);
    if (value is double) return DateTime.fromMillisecondsSinceEpoch(value.round());
    return null;
  }

  static int _ms(Object? value) => value is num ? value.round() : 0;

  /// Parses either the Firestore document or the getEntitlement callable
  /// response — both carry the same field names.
  ///
  /// The server writes the derived fields alongside the raw ones, but a
  /// document is only as fresh as its last write: a subscription that lapsed
  /// since then would still claim to be live. So expiry is re-checked here
  /// against the period end, and a lapsed plan falls back to whatever free
  /// allowance was never used — the same rule the server applies.
  factory Entitlement.fromMap(Map<String, dynamic> data, {DateTime? now}) {
    final plan = planFromId(data['plan'] as String?) ?? SayvoPlan.free;
    final periodEnd = _date(data['currentPeriodEnd']);
    final status = data['subscriptionStatus'] as String? ?? 'none';
    final paidIsLive = plan != SayvoPlan.free &&
        (status == 'active' || status == 'grace') &&
        (periodEnd == null || (now ?? DateTime.now()).isBefore(periodEnd));
    final source = paidIsLive ? 'plan' : 'free';
    final allowance = _ms(data['allowanceMs']);
    final used = _ms(data['usedMs']);
    final freeUsed = _ms(data['freeUsedMs']);
    // Prefer the server's computed remainder, but only while it still agrees
    // with what the plan's own dates say.
    final stored = data['allowanceSource'] as String?;
    final remaining = data.containsKey('remainingMs') && stored == source
        ? _ms(data['remainingMs'])
        : (source == 'plan' ? allowance - used : kFreeLifetimeMs - freeUsed);
    return Entitlement(
      plan: plan,
      subscriptionStatus: status,
      store: data['store'] as String?,
      storeProductId: data['storeProductId'] as String?,
      currentPeriodStart: _date(data['currentPeriodStart']),
      currentPeriodEnd: periodEnd,
      allowanceMs: source == 'plan' ? allowance : kFreeLifetimeMs,
      usedMs: used,
      freeUsedMs: freeUsed,
      remainingMs: remaining < 0 ? 0 : remaining,
      allowanceSource: source,
    );
  }
}
