import 'dart:async';
import 'dart:io';

import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:live_translator/features/subscription/paywall_screen.dart';
import 'package:live_translator/features/subscription/subscription_card.dart';
import 'package:live_translator/services/billing/entitlement.dart';
import 'package:live_translator/services/billing/entitlement_controller.dart';
import 'package:live_translator/services/billing/subscription_service.dart';
import 'package:live_translator/services/billing/usage_meter.dart';
import 'package:live_translator/theme/app_theme.dart';
import 'package:live_translator/utils/plans.dart';
import 'package:provider/provider.dart';

// ── Fakes ───────────────────────────────────────────────────────────────────

ProductDetails _product(String id, String localizedPrice, double raw,
        {String currency = 'GBP'}) =>
    ProductDetails(
      id: id,
      title: id,
      description: id,
      price: localizedPrice,
      rawPrice: raw,
      currencyCode: currency,
    );

PurchaseDetails _purchase({
  String productId = kPlusProductId,
  String purchaseId = 'apple-transaction-1',
  String serverData = 'google-purchase-token-1',
  PurchaseStatus status = PurchaseStatus.purchased,
}) =>
    PurchaseDetails(
      productID: productId,
      purchaseID: purchaseId,
      verificationData: PurchaseVerificationData(
        localVerificationData: 'local',
        serverVerificationData: serverData,
        source: 'test',
      ),
      transactionDate: null,
      status: status,
    );

/// Stands in for the platform billing client. Nothing here talks to StoreKit
/// or Play Billing, but the SERVICE's own routing — which store, and what is
/// sent for verification — is the real implementation.
class _FakeSubscriptions extends SubscriptionService {
  _FakeSubscriptions({
    super.store = BillingStore.apple,
    this.productsAvailable = true,
  });

  final bool productsAvailable;

  final StreamController<PurchaseResult> _emitted =
      StreamController<PurchaseResult>.broadcast();

  /// Localized prices exactly as a UK store would return them — note they are
  /// not the USD figures the plans were designed around, which is the point.
  static final Map<SayvoPlan, ProductDetails> _catalog = {
    SayvoPlan.basic: _product(kBasicProductId, '£8.99', 8.99),
    SayvoPlan.plus: _product(kPlusProductId, '£17.99', 17.99),
    SayvoPlan.pro: _product(kProProductId, '£26.99', 26.99),
  };

  int loadCalls = 0;
  int restoreCalls = 0;
  final List<String> bought = [];
  final List<String?> managedProductIds = [];

  @override
  Stream<PurchaseResult> get results => _emitted.stream;

  @override
  void listen() {}

  @override
  bool get isSupportedPlatform => true;

  @override
  Future<bool> loadProducts() async {
    loadCalls++;
    return productsAvailable;
  }

  @override
  List<ProductDetails> get products =>
      productsAvailable ? _catalog.values.toList() : const [];

  @override
  ProductDetails? productFor(SayvoPlan plan) =>
      productsAvailable ? _catalog[plan] : null;

  @override
  Future<void> buy(ProductDetails product) async => bought.add(product.id);

  @override
  Future<void> restorePurchases() async => restoreCalls++;

  @override
  Future<bool> openManageSubscription({String? productId}) async {
    managedProductIds.add(productId);
    return true;
  }

  void emit(PurchaseResult result) => _emitted.add(result);

  @override
  Future<void> dispose() async {
    await _emitted.close();
    await super.dispose();
  }
}

Widget _wrap(
  Widget child, {
  required SubscriptionService subscriptions,
  required EntitlementController entitlements,
}) =>
    MultiProvider(
      providers: [
        Provider<SubscriptionService>.value(value: subscriptions),
        ChangeNotifierProvider<EntitlementController>.value(value: entitlements),
      ],
      child: MaterialApp(theme: AppTheme.midnight(), home: child),
    );

/// A surface tall enough that the whole paywall is laid out at once —
/// otherwise "this text is absent" would pass merely because it scrolled off.
void _useTallSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(1000, 2600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// Polls until [done] or the timeout, so the meter's real-timer tests do not
/// depend on the host's timer resolution.
Future<void> _waitFor(
  bool Function() done, {
  Duration timeout = const Duration(seconds: 3),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!done() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  // ── The catalog itself ────────────────────────────────────────────────────

  group('plan catalog', () {
    test('product ids and allowances match the server catalog', () {
      expect(kPlanProductIds[SayvoPlan.basic], 'sayvo_basic_monthly');
      expect(kPlanProductIds[SayvoPlan.plus], 'sayvo_plus_monthly');
      expect(kPlanProductIds[SayvoPlan.pro], 'sayvo_pro_monthly');
      expect(planMinutes(SayvoPlan.basic), 15);
      expect(planMinutes(SayvoPlan.plus), 35);
      expect(planMinutes(SayvoPlan.pro), 55);
      expect(kFreeLifetimeMinutes, 5);
      expect(kRecommendedPlan, SayvoPlan.plus);
    });

    test('no price is written into the app source', () {
      // The authoritative price must come from App Store / Play metadata, so
      // the target USD figures must not appear as literals in lib/.
      final offenders = <String>[];
      for (final entity in Directory('lib').listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final source = entity.readAsStringSync();
        for (final price in const ['9.99', '19.99', '29.99']) {
          if (source.contains(price)) offenders.add('${entity.path}: $price');
        }
      }
      expect(offenders, isEmpty,
          reason: 'prices must come from the store, not the app');
    });
  });

  // ── Entitlement: the server's word, parsed ────────────────────────────────

  group('entitlement', () {
    test('a fresh account has five free minutes, not a plan', () {
      const e = Entitlement.free;
      expect(e.plan, SayvoPlan.free);
      expect(e.isPaid, isFalse);
      expect(e.remainingMinutes, 5);
      expect(e.totalMinutes, 5);
      expect(e.hasMinutesLeft, isTrue);
    });

    test('spent free minutes leave nothing, and do not refill', () {
      final e = Entitlement.fromMap({
        'plan': 'free',
        'subscriptionStatus': 'none',
        'freeMinutesUsed': 5.0,
        'remainingMinutes': 0.0,
        'allowanceSource': 'free',
      });
      expect(e.hasMinutesLeft, isFalse);
      expect(e.usedMinutes, 5);
    });

    test('a paid plan reports the plan allowance, not the free one', () {
      final e = Entitlement.fromMap({
        'plan': 'pro',
        'subscriptionStatus': 'active',
        'store': 'apple',
        'storeProductId': kProProductId,
        'minutesAllowance': 55,
        'minutesUsed': 12.5,
        'freeMinutesUsed': 5.0,
        'remainingMinutes': 42.5,
        'allowanceSource': 'plan',
        'currentPeriodEnd': DateTime.utc(2026, 11, 3).millisecondsSinceEpoch,
      });
      expect(e.isPaid, isTrue);
      expect(e.totalMinutes, 55);
      expect(e.usedMinutes, 12.5);
      expect(e.remainingMinutes, 42.5);
      expect(e.currentPeriodEnd, DateTime.utc(2026, 11, 3).toLocal());
    });

    test('a negative remainder from the server is clamped to zero', () {
      final e = Entitlement.fromMap({
        'plan': 'basic',
        'minutesAllowance': 15,
        'minutesUsed': 16.0,
        'allowanceSource': 'plan',
      });
      expect(e.remainingMinutes, 0);
      expect(e.hasMinutesLeft, isFalse);
    });

    test('an unknown plan id from a tampered document reads as free', () {
      final e = Entitlement.fromMap({
        'plan': 'unlimited_pro_max',
        'minutesAllowance': 999999,
        'allowanceSource': 'plan',
      });
      expect(e.plan, SayvoPlan.free);
      expect(e.isPaid, isFalse);
    });
  });

  // ── EntitlementController: a mirror, never a source ───────────────────────

  group('entitlement controller', () {
    test('no document means the free tier, and gating allows a session',
        () async {
      final firestore = FakeFirebaseFirestore();
      final controller = EntitlementController(firestore: firestore)
        ..bind('uid-1');
      await Future<void>.delayed(Duration.zero);
      expect(controller.entitlement.plan, SayvoPlan.free);
      expect(controller.entitlement.remainingMinutes, 5);
      expect(controller.canStartSession, isTrue);
      controller.dispose();
    });

    test('an exhausted account cannot start a session', () async {
      final firestore = FakeFirebaseFirestore();
      await firestore.collection('entitlements').doc('uid-1').set({
        'plan': 'free',
        'freeMinutesUsed': 5.0,
        'remainingMinutes': 0.0,
        'allowanceSource': 'free',
      });
      final controller = EntitlementController(firestore: firestore)
        ..bind('uid-1');
      await Future<void>.delayed(Duration.zero);
      expect(controller.loaded, isTrue);
      expect(controller.canStartSession, isFalse);
      controller.dispose();
    });

    test('the server document drives the plan; the client cannot invent one',
        () async {
      final firestore = FakeFirebaseFirestore();
      await firestore.collection('entitlements').doc('uid-1').set({
        'plan': 'plus',
        'subscriptionStatus': 'active',
        'minutesAllowance': 35,
        'minutesUsed': 5.0,
        'remainingMinutes': 30.0,
        'allowanceSource': 'plan',
      });
      final controller = EntitlementController(firestore: firestore)
        ..bind('uid-1');
      await Future<void>.delayed(Duration.zero);
      expect(controller.entitlement.plan, SayvoPlan.plus);
      expect(controller.entitlement.remainingMinutes, 30);
      controller.dispose();
    });

    test('a failed refresh leaves the known entitlement intact', () async {
      final firestore = FakeFirebaseFirestore();
      await firestore.collection('entitlements').doc('uid-1').set({
        'plan': 'pro',
        'subscriptionStatus': 'active',
        'minutesAllowance': 55,
        'remainingMinutes': 55.0,
        'allowanceSource': 'plan',
      });
      final controller = EntitlementController(firestore: firestore)
        ..bind('uid-1');
      await Future<void>.delayed(Duration.zero);
      // No Firebase app is initialized, so the callable throws — which is the
      // offline case: it must not downgrade anybody.
      await controller.refresh();
      expect(controller.entitlement.plan, SayvoPlan.pro);
      expect(controller.entitlement.remainingMinutes, 55);
      controller.dispose();
    });

    test('a server remainder counts the plan allowance down live', () async {
      final firestore = FakeFirebaseFirestore();
      await firestore.collection('entitlements').doc('uid-1').set({
        'plan': 'basic',
        'subscriptionStatus': 'active',
        'minutesAllowance': 15,
        'minutesUsed': 0.0,
        'remainingMinutes': 15.0,
        'allowanceSource': 'plan',
      });
      final controller = EntitlementController(firestore: firestore)
        ..bind('uid-1');
      await Future<void>.delayed(Duration.zero);
      controller.applyRemaining(13.5);
      expect(controller.entitlement.remainingMinutes, 13.5);
      expect(controller.entitlement.usedMinutes, closeTo(1.5, 0.001));
      controller.dispose();
    });

    test('signing out drops back to the free default', () async {
      final firestore = FakeFirebaseFirestore();
      await firestore.collection('entitlements').doc('uid-1').set({
        'plan': 'pro',
        'minutesAllowance': 55,
        'remainingMinutes': 55.0,
        'allowanceSource': 'plan',
      });
      final controller = EntitlementController(firestore: firestore)
        ..bind('uid-1');
      await Future<void>.delayed(Duration.zero);
      expect(controller.entitlement.isPaid, isTrue);
      controller.bind(null);
      expect(controller.entitlement.plan, SayvoPlan.free);
      expect(controller.loaded, isFalse);
      controller.dispose();
    });
  });

  // ── Which store, and what is sent to the server ───────────────────────────

  group('store routing', () {
    test('iOS sends only Apple\'s transaction id', () {
      final service = SubscriptionService(store: BillingStore.apple);
      final payload = service.verificationPayload(_purchase());
      expect(payload['store'], 'apple');
      expect(payload['transactionId'], 'apple-transaction-1');
      expect(payload.containsKey('purchaseToken'), isFalse);
      // The client never asserts what was bought.
      expect(payload.containsKey('plan'), isFalse);
      expect(payload.containsKey('productId'), isFalse);
      expect(payload.containsKey('price'), isFalse);
    });

    test('Android sends only Google Play\'s purchase token', () {
      final service = SubscriptionService(store: BillingStore.google);
      final payload = service.verificationPayload(_purchase());
      expect(payload['store'], 'google');
      expect(payload['purchaseToken'], 'google-purchase-token-1');
      expect(payload.containsKey('transactionId'), isFalse);
      expect(payload.containsKey('plan'), isFalse);
      expect(payload.containsKey('productId'), isFalse);
    });

    test('there are exactly two payment routes, Apple and Google', () {
      expect(BillingStore.values, [BillingStore.apple, BillingStore.google]);
      expect(SubscriptionService(store: BillingStore.apple).store,
          BillingStore.apple);
      expect(SubscriptionService(store: BillingStore.google).store,
          BillingStore.google);
    });
  });

  // ── The paywall ───────────────────────────────────────────────────────────

  group('paywall', () {
    Future<(_FakeSubscriptions, EntitlementController)> pumpPaywall(
      WidgetTester tester, {
      BillingStore store = BillingStore.apple,
      bool productsAvailable = true,
    }) async {
      _useTallSurface(tester);
      final subs = _FakeSubscriptions(
          store: store, productsAvailable: productsAvailable);
      final entitlements =
          EntitlementController(firestore: FakeFirebaseFirestore());
      addTearDown(() {
        subs.dispose();
        entitlements.dispose();
      });
      await tester.pumpWidget(_wrap(const PaywallScreen(),
          subscriptions: subs, entitlements: entitlements));
      await tester.pumpAndSettle();
      return (subs, entitlements);
    }

    testWidgets('shows the store\'s localized prices, never a built-in one',
        (tester) async {
      await pumpPaywall(tester);

      expect(find.text('£8.99'), findsOneWidget);
      expect(find.text('£17.99'), findsOneWidget);
      expect(find.text('£26.99'), findsOneWidget);
      expect(find.textContaining('9.99'), findsNothing);
      expect(find.textContaining('19.99'), findsNothing);
      expect(find.textContaining('29.99'), findsNothing);
    });

    testWidgets('lists all three plans with their minutes, Plus recommended',
        (tester) async {
      await pumpPaywall(tester);

      expect(find.text('Sayvo Basic'), findsOneWidget);
      expect(find.text('Sayvo Plus'), findsOneWidget);
      expect(find.text('Sayvo Pro'), findsOneWidget);
      expect(find.text('15 min/month'), findsOneWidget);
      expect(find.text('35 min/month'), findsOneWidget);
      expect(find.text('55 min/month'), findsOneWidget);
      expect(find.text('Recommended'), findsOneWidget);
      expect(find.textContaining('Automatically renews'), findsOneWidget);
      expect(find.textContaining('Cancel anytime'), findsOneWidget);
      expect(find.text('Restore Purchases'), findsOneWidget);
      expect(find.text('Privacy Policy'), findsOneWidget);
      expect(find.text('Terms of Use'), findsOneWidget);
    });

    testWidgets('iOS discloses Apple as the processor', (tester) async {
      await pumpPaywall(tester, store: BillingStore.apple);

      expect(
          find.textContaining(
              'Payments are processed securely by Apple through the App Store'),
          findsOneWidget);
      expect(find.textContaining('independent developer'), findsOneWidget);
      expect(find.textContaining('Google Play'), findsNothing);
    });

    testWidgets('Android discloses Google Play as the processor',
        (tester) async {
      await pumpPaywall(tester, store: BillingStore.google);

      expect(
          find.textContaining('Payments are processed securely by Google Play'),
          findsOneWidget);
      expect(find.textContaining('independent developer'), findsOneWidget);
      expect(find.textContaining('App Store'), findsNothing);
    });

    testWidgets('buying uses the selected plan\'s store product',
        (tester) async {
      final (subs, _) = await pumpPaywall(tester);

      // Plus is preselected.
      await tester.tap(find.text('Subscribe'));
      await tester.pump();
      expect(subs.bought, [kPlusProductId]);

      // The button stays busy until the store reports back; a cancellation
      // releases it without granting anything.
      subs.emit(const PurchaseResult(PurchaseOutcome.cancelled));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Sayvo Pro'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Subscribe'));
      await tester.pump();
      expect(subs.bought, [kPlusProductId, kProProductId]);

      subs.emit(const PurchaseResult(PurchaseOutcome.cancelled));
      await tester.pumpAndSettle();
    });

    testWidgets('a cancelled purchase grants nothing and shows no error',
        (tester) async {
      final (subs, entitlements) = await pumpPaywall(tester);

      subs.emit(const PurchaseResult(PurchaseOutcome.cancelled));
      await tester.pumpAndSettle();

      expect(entitlements.entitlement.isPaid, isFalse);
      expect(find.textContaining('pending'), findsNothing);
      // Still on the paywall — nothing was unlocked.
      expect(find.text('Subscribe'), findsOneWidget);
    });

    testWidgets('a pending purchase grants nothing and says so', (tester) async {
      final (subs, entitlements) = await pumpPaywall(tester);

      subs.emit(const PurchaseResult(PurchaseOutcome.pending));
      await tester.pumpAndSettle();

      expect(find.textContaining('pending approval'), findsOneWidget);
      expect(entitlements.entitlement.isPaid, isFalse);
    });

    testWidgets('a failed purchase grants nothing and surfaces the reason',
        (tester) async {
      final (subs, entitlements) = await pumpPaywall(tester);

      subs.emit(const PurchaseResult(PurchaseOutcome.failed,
          message: 'Your card was declined.'));
      await tester.pumpAndSettle();

      expect(find.textContaining('card was declined'), findsOneWidget);
      expect(entitlements.entitlement.isPaid, isFalse);
    });

    testWidgets('restore asks the store and reports what the server returned',
        (tester) async {
      final (subs, _) = await pumpPaywall(tester);

      await tester.tap(find.text('Restore Purchases'));
      await tester.pumpAndSettle();

      expect(subs.restoreCalls, 1);
      // The server said nothing was owned, so nothing is claimed.
      expect(find.text('No previous subscription found.'), findsOneWidget);
    });

    testWidgets('unavailable products disable Subscribe rather than guessing',
        (tester) async {
      final (subs, _) = await pumpPaywall(tester, productsAvailable: false);

      expect(
          find.textContaining('not available on this device'), findsOneWidget);
      expect(find.text('—'), findsNWidgets(3));
      await tester.tap(find.text('Subscribe'));
      await tester.pumpAndSettle();
      expect(subs.bought, isEmpty);
    });
  });

  // ── The Profile plan block ────────────────────────────────────────────────

  group('subscription card', () {
    Future<_FakeSubscriptions> pumpCard(
      WidgetTester tester,
      Map<String, dynamic> document,
    ) async {
      final firestore = FakeFirebaseFirestore();
      await firestore.collection('entitlements').doc('uid-1').set(document);
      final entitlements = EntitlementController(firestore: firestore)
        ..bind('uid-1');
      final subs = _FakeSubscriptions();
      addTearDown(() {
        subs.dispose();
        entitlements.dispose();
      });
      await tester.pumpWidget(_wrap(
        const Scaffold(body: SubscriptionCard()),
        subscriptions: subs,
        entitlements: entitlements,
      ));
      await tester.pumpAndSettle();
      return subs;
    }

    testWidgets('a free user sees the free remainder and an upgrade action',
        (tester) async {
      await pumpCard(tester, {
        'plan': 'free',
        'freeMinutesUsed': 2.0,
        'remainingMinutes': 3.0,
        'allowanceSource': 'free',
      });
      expect(find.text('Free'), findsOneWidget);
      expect(find.text('3 of 5 free minutes remaining'), findsOneWidget);
      expect(find.text('2 min used · 3 min remaining'), findsOneWidget);
      expect(find.text('Upgrade Sayvo'), findsOneWidget);
      expect(find.text('Manage Subscription'), findsNothing);
    });

    testWidgets('a paid user sees plan, usage, renewal date and management',
        (tester) async {
      final subs = await pumpCard(tester, {
        'plan': 'plus',
        'subscriptionStatus': 'active',
        'store': 'apple',
        'storeProductId': kPlusProductId,
        'minutesAllowance': 35,
        'minutesUsed': 10.0,
        'remainingMinutes': 25.0,
        'allowanceSource': 'plan',
        'currentPeriodEnd': DateTime(2026, 11, 3).millisecondsSinceEpoch,
      });
      expect(find.text('Sayvo Plus'), findsOneWidget);
      expect(find.text('35 minutes / month'), findsOneWidget);
      expect(find.text('10 min used · 25 min remaining'), findsOneWidget);
      expect(find.textContaining('Renews'), findsOneWidget);
      expect(find.textContaining('November 3, 2026'), findsOneWidget);
      expect(find.text('Upgrade Sayvo'), findsNothing);

      await tester.tap(find.text('Manage Subscription'));
      await tester.pumpAndSettle();
      expect(subs.managedProductIds, [kPlusProductId]);
    });

    testWidgets('an expired subscription falls back to the free remainder',
        (tester) async {
      await pumpCard(tester, {
        'plan': 'pro',
        'subscriptionStatus': 'expired',
        'minutesAllowance': 0,
        'minutesUsed': 55.0,
        'freeMinutesUsed': 0.0,
        'remainingMinutes': 5.0,
        'allowanceSource': 'free',
      });
      // The plan is gone, so the card shows Free and offers an upgrade.
      expect(find.text('Free'), findsOneWidget);
      expect(find.text('5 of 5 free minutes remaining'), findsOneWidget);
      expect(find.text('Upgrade Sayvo'), findsOneWidget);
    });
  });

  // ── Metering lifecycle ────────────────────────────────────────────────────

  group('usage meter', () {
    test('heartbeats while listening and stops the moment the session ends',
        () async {
      final calls = <({String session, bool close})>[];
      final meter = UsageMeter(
        interval: const Duration(milliseconds: 20),
        sender: (sessionId, close) async {
          calls.add((session: sessionId, close: close));
          return {'remainingMinutes': 12.0, 'allowed': true};
        },
      );

      meter.start('session-a');
      await _waitFor(() => calls.length >= 2);
      expect(calls.length, greaterThanOrEqualTo(2));
      expect(calls.every((c) => c.session == 'session-a'), isTrue);
      expect(calls.every((c) => c.close == false), isTrue);

      await meter.finish();
      expect(meter.isRunning, isFalse);
      expect(calls.last.close, isTrue);
      final atClose = calls.length;

      // Nothing accrues once listening has stopped.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(calls.length, atClose);
      meter.dispose();
    });

    test('the server remainder is reported to the UI', () async {
      final remainders = <double>[];
      final meter = UsageMeter(
        interval: const Duration(milliseconds: 20),
        sender: (_, __) async => {'remainingMinutes': 7.5, 'allowed': true},
      )..onRemaining = remainders.add;
      meter.start('session-b');
      await _waitFor(() => remainders.isNotEmpty);
      meter.stopTimer();
      expect(remainders, isNotEmpty);
      expect(remainders.first, 7.5);
      meter.dispose();
    });

    test('an exhausted allowance cuts the session off', () async {
      var exhausted = 0;
      final meter = UsageMeter(
        interval: const Duration(milliseconds: 20),
        sender: (_, __) async => {'remainingMinutes': 0.0, 'allowed': false},
      )..onExhausted = () => exhausted++;
      meter.start('session-c');
      await _waitFor(() => exhausted > 0);
      meter.stopTimer();
      expect(exhausted, greaterThanOrEqualTo(1));
      meter.dispose();
    });

    test('a dropped heartbeat does not stop a paid session', () async {
      var attempts = 0;
      final meter = UsageMeter(
        interval: const Duration(milliseconds: 20),
        sender: (_, __) async {
          attempts++;
          throw Exception('offline');
        },
      );
      meter.start('session-d');
      await _waitFor(() => attempts >= 2);
      expect(meter.isRunning, isTrue);
      expect(attempts, greaterThanOrEqualTo(2));
      meter.dispose();
    });

    test('finishing without a session bills nothing', () async {
      var calls = 0;
      final meter = UsageMeter(sender: (_, __) async {
        calls++;
        return const {};
      });
      await meter.finish();
      expect(calls, 0);
      meter.dispose();
    });
  });
}
