import 'dart:async';
import 'dart:io';

import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:live_translator/features/subscription/paywall_screen.dart';
import 'package:live_translator/features/subscription/subscription_card.dart';
import 'package:live_translator/services/billing/entitlement.dart';
import 'package:live_translator/services/billing/entitlement_controller.dart';
import 'package:live_translator/services/billing/subscription_service.dart';
import 'package:live_translator/theme/app_theme.dart';
import 'package:live_translator/utils/account_token.dart';
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
  ProductQueryReport? get lastQuery => ProductQueryReport(
        supportedPlatform: true,
        storeAvailable: true,
        requested: kAllProductIds,
        products: products,
        notFoundIds: productsAvailable ? const [] : kAllProductIds.toList(),
        error: null,
        attempts: 1,
      );

  @override
  List<ProductDetails> get products =>
      productsAvailable ? _catalog.values.toList() : const [];

  @override
  ProductDetails? productFor(SayvoPlan plan) =>
      productsAvailable ? _catalog[plan] : null;

  @override
  Future<void> buy(ProductDetails product) async => bought.add(product.id);

  /// What a restore will report back; defaults to finding nothing.
  RestoreReport restoreReport = const RestoreReport(delivered: 0, verified: 0);

  @override
  Future<RestoreReport> restorePurchases() async {
    restoreCalls++;
    return restoreReport;
  }

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
    test('a fresh account has five free minutes of translated speech', () {
      const e = Entitlement.free;
      expect(e.plan, SayvoPlan.free);
      expect(e.isPaid, isFalse);
      expect(e.remainingMs, 5 * kMsPerMinute);
      expect(e.totalMs, 5 * kMsPerMinute);
      expect(e.hasSpeechLeft, isTrue);
    });

    test('a spent free allowance leaves nothing, and does not refill', () {
      final e = Entitlement.fromMap({
        'plan': 'free',
        'subscriptionStatus': 'none',
        'freeUsedMs': kFreeLifetimeMs,
        'remainingMs': 0,
        'allowanceSource': 'free',
      });
      expect(e.hasSpeechLeft, isFalse);
      expect(e.spentMs, kFreeLifetimeMs);
    });

    test('a paid plan reports the plan allowance, not the free one', () {
      final e = Entitlement.fromMap(
        {
          'plan': 'pro',
          'subscriptionStatus': 'active',
          'store': 'apple',
          'storeProductId': kProProductId,
          'allowanceMs': 55 * kMsPerMinute,
          'usedMs': 12 * kMsPerMinute + 30000,
          'freeUsedMs': kFreeLifetimeMs,
          'remainingMs': 42 * kMsPerMinute + 30000,
          'allowanceSource': 'plan',
          'currentPeriodEnd': DateTime.utc(2026, 11, 3).millisecondsSinceEpoch,
        },
        now: DateTime.utc(2026, 9, 20),
      );
      expect(e.isPaid, isTrue);
      expect(e.totalMs, 55 * kMsPerMinute);
      expect(e.spentMs, 12 * kMsPerMinute + 30000);
      expect(e.remainingMs, 42 * kMsPerMinute + 30000);
      expect(e.currentPeriodEnd, DateTime.utc(2026, 11, 3).toLocal());
    });

    test('a negative remainder from the server is clamped to zero', () {
      final e = Entitlement.fromMap(
        {
          'plan': 'basic',
          'subscriptionStatus': 'active',
          'allowanceMs': 15 * kMsPerMinute,
          'usedMs': 16 * kMsPerMinute,
          'allowanceSource': 'plan',
          'currentPeriodEnd':
              DateTime.utc(2026, 10, 20).millisecondsSinceEpoch,
        },
        now: DateTime.utc(2026, 9, 20),
      );
      expect(e.remainingMs, 0);
      expect(e.hasSpeechLeft, isFalse);
    });

    test('a plan whose period has passed falls back to the free remainder', () {
      // The stored document still says the subscription is live, because
      // nothing has written to it since it lapsed.
      final e = Entitlement.fromMap(
        {
          'plan': 'pro',
          'subscriptionStatus': 'active',
          'allowanceMs': 55 * kMsPerMinute,
          'usedMs': 55 * kMsPerMinute,
          'freeUsedMs': 2 * kMsPerMinute,
          'allowanceSource': 'plan',
          'remainingMs': 0,
          'currentPeriodEnd': DateTime.utc(2026, 9, 1).millisecondsSinceEpoch,
        },
        now: DateTime.utc(2026, 9, 20),
      );
      expect(e.isPaid, isFalse);
      expect(e.allowanceSource, 'free');
      // Three unused free minutes, not zero.
      expect(e.remainingMs, 3 * kMsPerMinute);
    });

    test('a plan inside its period uses the server remainder as given', () {
      final e = Entitlement.fromMap(
        {
          'plan': 'plus',
          'subscriptionStatus': 'active',
          'allowanceMs': 35 * kMsPerMinute,
          'usedMs': 10 * kMsPerMinute,
          'allowanceSource': 'plan',
          'remainingMs': 25 * kMsPerMinute,
          'currentPeriodEnd': DateTime.utc(2026, 10, 20).millisecondsSinceEpoch,
        },
        now: DateTime.utc(2026, 9, 20),
      );
      expect(e.isPaid, isTrue);
      expect(e.remainingMs, 25 * kMsPerMinute);
    });

    test('an unknown plan id from a tampered document reads as free', () {
      final e = Entitlement.fromMap({
        'plan': 'unlimited_pro_max',
        'allowanceMs': 999999999,
        'allowanceSource': 'plan',
      });
      expect(e.plan, SayvoPlan.free);
      expect(e.isPaid, isFalse);
    });

    test('durations are shown to the second, never rounded up to a minute', () {
      expect(formatSpeechDuration(48000), '48s');
      expect(formatSpeechDuration(0), '0s');
      expect(formatSpeechDuration(744000), '12m 24s');
      expect(formatSpeechDuration(1356000), '22m 36s');
      expect(formatSpeechDuration(120000), '2m');
      expect(formatSpeechDuration(3840000), '1h 04m');
    });
  });

  group('the account a purchase belongs to', () {
    test('matches the server derivation exactly', () {
      // functions/src/billing/account_token.test.ts pins the same value. A
      // drift here would make every purchase look like somebody else's.
      expect(accountTokenForUid('uid-abc123'),
          '9e65ab7b-6d88-590e-a831-0012d8bac0ae');
    });

    test('is stable per account and different between accounts', () {
      expect(accountTokenForUid('a'), accountTokenForUid('a'));
      expect(accountTokenForUid('a'), isNot(accountTokenForUid('b')));
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
      expect(controller.entitlement.remainingMs, kFreeLifetimeMs);
      expect(controller.canStartSession, isTrue);
      controller.dispose();
    });

    test('an exhausted account cannot start a session', () async {
      final firestore = FakeFirebaseFirestore();
      await firestore.collection('entitlements').doc('uid-1').set({
        'plan': 'free',
        'freeUsedMs': kFreeLifetimeMs,
        'remainingMs': 0,
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
        'allowanceMs': 35 * kMsPerMinute,
        'usedMs': 5 * kMsPerMinute,
        'remainingMs': 30 * kMsPerMinute,
        'allowanceSource': 'plan',
      });
      final controller = EntitlementController(firestore: firestore)
        ..bind('uid-1');
      await Future<void>.delayed(Duration.zero);
      expect(controller.entitlement.plan, SayvoPlan.plus);
      expect(controller.entitlement.remainingMs, 30 * kMsPerMinute);
      controller.dispose();
    });

    test('a failed refresh leaves the known entitlement intact', () async {
      final firestore = FakeFirebaseFirestore();
      await firestore.collection('entitlements').doc('uid-1').set({
        'plan': 'pro',
        'subscriptionStatus': 'active',
        'allowanceMs': 55 * kMsPerMinute,
        'remainingMs': 55 * kMsPerMinute,
        'allowanceSource': 'plan',
      });
      final controller = EntitlementController(firestore: firestore)
        ..bind('uid-1');
      await Future<void>.delayed(Duration.zero);
      // No Firebase app is initialized, so the callable throws — which is the
      // offline case: it must not downgrade anybody.
      await controller.refresh();
      expect(controller.entitlement.plan, SayvoPlan.pro);
      expect(controller.entitlement.remainingMs, 55 * kMsPerMinute);
      controller.dispose();
    });

    test('a server remainder counts the plan allowance down live', () async {
      final firestore = FakeFirebaseFirestore();
      await firestore.collection('entitlements').doc('uid-1').set({
        'plan': 'basic',
        'subscriptionStatus': 'active',
        'allowanceMs': 15 * kMsPerMinute,
        'usedMs': 0,
        'remainingMs': 15 * kMsPerMinute,
        'allowanceSource': 'plan',
      });
      final controller = EntitlementController(firestore: firestore)
        ..bind('uid-1');
      await Future<void>.delayed(Duration.zero);
      controller.applyRemainingMs(13 * kMsPerMinute + 30000);
      expect(controller.entitlement.remainingMs, 13 * kMsPerMinute + 30000);
      expect(controller.entitlement.spentMs, kMsPerMinute + 30000);
      controller.dispose();
    });

    test('signing out drops back to the free default', () async {
      final firestore = FakeFirebaseFirestore();
      await firestore.collection('entitlements').doc('uid-1').set({
        'plan': 'pro',
        'subscriptionStatus': 'active',
        'allowanceMs': 55 * kMsPerMinute,
        'remainingMs': 55 * kMsPerMinute,
        'allowanceSource': 'plan',
        'currentPeriodEnd': DateTime.now()
            .add(const Duration(days: 20))
            .millisecondsSinceEpoch,
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

  // ── Managing an existing subscription ─────────────────────────────────────

  group('manage subscription', () {
    // Named, not referenced: a mock handler is keyed by channel NAME, so this
    // asserts the channel the service actually talks on.
    const channel = MethodChannel('app.livetranslator/billing');
    late List<MethodCall> nativeCalls;
    late List<Uri> opened;

    setUp(() {
      TestWidgetsFlutterBinding.ensureInitialized();
      nativeCalls = <MethodCall>[];
      opened = <Uri>[];
    });

    /// Stands in for the native side. [answer] is what
    /// `showManageSubscriptions` returns, or a throw for a native failure.
    void mockNative(Object? Function() answer) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        nativeCalls.add(call);
        return answer();
      });
      addTearDown(() => TestDefaultBinaryMessengerBinding
          .instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null));
    }

    SubscriptionService serviceFor(BillingStore store) => SubscriptionService(
          store: store,
          openUrl: (uri) async {
            opened.add(uri);
            return true;
          },
        );

    test('iOS asks StoreKit for its own sheet, not a URL', () async {
      mockNative(() => true);

      final shown =
          await serviceFor(BillingStore.apple).openManageSubscription();

      expect(shown, isTrue);
      expect(nativeCalls.single.method, 'showManageSubscriptions');
      // The apps.apple.com page shows the PRODUCTION account only, which is
      // why a TestFlight tester could not find their plan there.
      expect(opened, isEmpty);
    });

    test('a StoreKit failure falls back to the App Store URL', () async {
      mockNative(() => throw PlatformException(code: 'storekit_unavailable'));

      final shown =
          await serviceFor(BillingStore.apple).openManageSubscription();

      expect(nativeCalls, hasLength(1));
      expect(shown, isTrue, reason: 'the fallback still opened something');
      expect(opened.single.host, 'apps.apple.com');
    });

    test('no window scene to present in falls back too', () async {
      mockNative(() => false);

      await serviceFor(BillingStore.apple).openManageSubscription();

      expect(opened.single.host, 'apps.apple.com');
    });

    test('a build without the native handler falls back', () async {
      // No mock at all: the channel answers as unimplemented, exactly as an
      // older binary would.
      final shown =
          await serviceFor(BillingStore.apple).openManageSubscription();

      expect(shown, isTrue);
      expect(opened.single.host, 'apps.apple.com');
    });

    test('both fallbacks failing reports failure rather than throwing',
        () async {
      mockNative(() => false);
      final service = SubscriptionService(
        store: BillingStore.apple,
        openUrl: (_) async => throw Exception('no browser'),
      );

      expect(await service.openManageSubscription(), isFalse);
    });

    test('Android never touches the StoreKit channel', () async {
      mockNative(() => true);

      final shown = await serviceFor(BillingStore.google)
          .openManageSubscription(productId: kPlusProductId);

      expect(shown, isTrue);
      expect(nativeCalls, isEmpty, reason: 'there is no StoreKit on Android');
      expect(opened.single.host, 'play.google.com');
      expect(opened.single.queryParameters['sku'], kPlusProductId);
      expect(opened.single.queryParameters['package'],
          'com.livetranslator.live_translator');
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
      expect(find.text('15 min translated speech / month'), findsOneWidget);
      expect(find.text('35 min translated speech / month'), findsOneWidget);
      expect(find.text('55 min translated speech / month'), findsOneWidget);
      expect(find.textContaining("Silent listening doesn't use your minutes"),
          findsOneWidget);
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

      expect(find.textContaining('not available from the App Store yet'),
          findsOneWidget);
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
        'freeUsedMs': 2 * kMsPerMinute,
        'remainingMs': 3 * kMsPerMinute,
        'allowanceSource': 'free',
      });
      expect(find.text('Free'), findsOneWidget);
      expect(find.text('Free — 5 min translated speech, one time'),
          findsOneWidget);
      expect(find.text('2m of 5m used'), findsOneWidget);
      expect(find.text('3m remaining'), findsOneWidget);
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
        'allowanceMs': 35 * kMsPerMinute,
        'usedMs': 12 * kMsPerMinute + 24000,
        'remainingMs': 22 * kMsPerMinute + 36000,
        'allowanceSource': 'plan',
        'currentPeriodEnd': DateTime(2026, 11, 3).millisecondsSinceEpoch,
      });
      expect(find.text('Sayvo Plus'), findsOneWidget);
      expect(find.text('35 min translated speech / month'), findsOneWidget);
      expect(find.text('12m 24s of 35m used'), findsOneWidget);
      expect(find.text('22m 36s remaining'), findsOneWidget);
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
        'allowanceMs': 0,
        'usedMs': 55 * kMsPerMinute,
        'freeUsedMs': 0,
        'remainingMs': kFreeLifetimeMs,
        'allowanceSource': 'free',
      });
      // The plan is gone, so the card shows Free and offers an upgrade.
      expect(find.text('Free'), findsOneWidget);
      expect(find.text('0s of 5m used'), findsOneWidget);
      expect(find.text('5m remaining'), findsOneWidget);
      expect(find.text('Upgrade Sayvo'), findsOneWidget);
    });
  });
}
