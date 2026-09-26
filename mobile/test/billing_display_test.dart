import 'dart:async';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:in_app_purchase_platform_interface/in_app_purchase_platform_interface.dart';
import 'package:live_translator/services/billing/entitlement_controller.dart';
import 'package:live_translator/services/billing/speech_activity_meter.dart';
import 'package:live_translator/services/billing/subscription_service.dart';
import 'package:live_translator/services/billing/usage_meter.dart';
import 'package:live_translator/utils/plans.dart';

// ── A fake store ────────────────────────────────────────────────────────────

ProductDetails _product(String id, String price, double raw) => ProductDetails(
      id: id,
      title: id,
      description: id,
      price: price,
      rawPrice: raw,
      currencyCode: 'GBP',
    );

/// Stands in for StoreKit / Play Billing underneath the real
/// [SubscriptionService], so the service's own query and mapping run for real.
class _FakeStore extends InAppPurchasePlatform {
  _FakeStore({
    this.available = true,
    this.products = const [],
    this.notFound = const [],
    this.error,
  });

  final bool available;
  final List<ProductDetails> products;
  final List<String> notFound;
  final IAPError? error;

  int queries = 0;
  Set<String>? lastRequested;

  /// Transactions handed back to the app, as StoreKit does: on the stream,
  /// after the restore call has already returned.
  final StreamController<List<PurchaseDetails>> purchases =
      StreamController<List<PurchaseDetails>>.broadcast();
  void Function()? onRestore;
  void Function()? onComplete;
  final List<String> completed = [];

  @override
  Future<void> restorePurchases({String? applicationUserName}) async =>
      onRestore?.call();

  @override
  Future<void> completePurchase(PurchaseDetails purchase) async {
    onComplete?.call();
    completed.add(purchase.productID);
  }

  @override
  Future<bool> isAvailable() async => available;

  @override
  Future<ProductDetailsResponse> queryProductDetails(
      Set<String> identifiers) async {
    queries++;
    lastRequested = identifiers;
    return ProductDetailsResponse(
      productDetails: products,
      notFoundIDs: notFound,
      error: error,
    );
  }

  @override
  Stream<List<PurchaseDetails>> get purchaseStream => purchases.stream;
}

SubscriptionService _serviceWith(
  _FakeStore store, {
  void Function(Map<String, dynamic> payload)? onVerify,
}) {
  InAppPurchasePlatform.instance = store;
  return SubscriptionService(
    iap: InAppPurchase.instance,
    store: BillingStore.apple,
    verifySender: onVerify == null
        ? null
        : (payload) async => onVerify(payload),
  );
}

/// Captures debugPrint so a test can assert what a TestFlight log would show.
Future<List<String>> _captureLogs(Future<void> Function() body) async {
  final lines = <String>[];
  final original = debugPrint;
  debugPrint = (String? message, {int? wrapWidth}) {
    if (message != null) lines.add(message);
  };
  try {
    await body();
  } finally {
    debugPrint = original;
  }
  return lines;
}

// ── Usage helpers ───────────────────────────────────────────────────────────

class _Clock {
  DateTime now = DateTime.utc(2026, 9, 25, 12);
  DateTime call() => now;
}

const double _silence = 0.0004;
const double _speech = 0.05;

void _feed(
  SpeechActivityMeter meter,
  _Clock clock, {
  required double rms,
  required Duration total,
  bool gated = false,
}) {
  const chunk = Duration(milliseconds: 100);
  for (var elapsed = Duration.zero; elapsed < total; elapsed += chunk) {
    meter.onAudio(rms: rms, duration: chunk, gated: gated, at: clock.now);
    clock.now = clock.now.add(chunk);
  }
}

/// Somebody speaks for [duration] and Sayvo translates it — the only sequence
/// that costs anything.
void _speakAndTranslate(
    SpeechActivityMeter speech, _Clock clock, Duration duration) {
  _feed(speech, clock, rms: _speech, total: duration);
  speech.onTranslatedText(clock.now);
  _feed(speech, clock, rms: _silence, total: const Duration(seconds: 2));
}

/// An entitlement document as the server writes it.
Map<String, dynamic> _paidDoc(String plan, int allowanceMinutes, int usedMs) => {
      'plan': plan,
      'subscriptionStatus': 'active',
      'allowanceMs': allowanceMinutes * kMsPerMinute,
      'usedMs': usedMs,
      'remainingMs': allowanceMinutes * kMsPerMinute - usedMs,
      'allowanceSource': 'plan',
      'currentPeriodEnd':
          DateTime.now().add(const Duration(days: 20)).millisecondsSinceEpoch,
    };

Future<EntitlementController> _boundTo(Map<String, dynamic>? doc) async {
  final firestore = FakeFirebaseFirestore();
  if (doc != null) {
    await firestore.collection('entitlements').doc('uid-1').set(doc);
  }
  final controller = EntitlementController(firestore: firestore)..bind('uid-1');
  await Future<void>.delayed(Duration.zero);
  return controller;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // InAppPurchase.instance registers a real platform implementation on first
  // touch, chosen by defaultTargetPlatform — which is android under test, so
  // it would go off and open a Play billing connection. Pointing the override
  // at a platform with no implementation leaves the field clear for the fake.
  setUpAll(() => debugDefaultTargetPlatformOverride = TargetPlatform.fuchsia);
  tearDownAll(() => debugDefaultTargetPlatformOverride = null);

  // ── Store products ────────────────────────────────────────────────────────

  group('store products', () {
    test('all three products load with their localized prices', () async {
      final store = _FakeStore(products: [
        _product(kBasicProductId, '£8.99', 8.99),
        _product(kPlusProductId, '£17.99', 17.99),
        _product(kProProductId, '£26.99', 26.99),
      ]);
      final service = _serviceWith(store);

      expect(await service.loadProducts(), isTrue);
      expect(store.lastRequested, kAllProductIds);
      expect(service.productFor(SayvoPlan.basic)?.price, '£8.99');
      expect(service.productFor(SayvoPlan.plus)?.price, '£17.99');
      expect(service.productFor(SayvoPlan.pro)?.price, '£26.99');
      expect(service.lastQuery?.outcome, ProductQueryOutcome.loaded);
    });

    test('prices map by product ID, not by list order', () async {
      // The store is free to answer in any order, and has been known to.
      final store = _FakeStore(products: [
        _product(kProProductId, '£26.99', 26.99),
        _product(kBasicProductId, '£8.99', 8.99),
        _product(kPlusProductId, '£17.99', 17.99),
      ]);
      final service = _serviceWith(store);
      await service.loadProducts();

      expect(service.productFor(SayvoPlan.basic)?.id, kBasicProductId);
      expect(service.productFor(SayvoPlan.basic)?.price, '£8.99');
      expect(service.productFor(SayvoPlan.plus)?.price, '£17.99');
      expect(service.productFor(SayvoPlan.pro)?.price, '£26.99');
    });

    test('a partial answer still maps the products that came back', () async {
      final store = _FakeStore(
        products: [_product(kPlusProductId, '£17.99', 17.99)],
        notFound: [kBasicProductId, kProProductId],
      );
      final service = _serviceWith(store);

      expect(await service.loadProducts(), isTrue);
      expect(service.productFor(SayvoPlan.plus)?.price, '£17.99');
      expect(service.productFor(SayvoPlan.basic), isNull);
      expect(service.productFor(SayvoPlan.pro), isNull);
    });

    test('zero products gives a diagnostic state, not just "no"', () async {
      final store = _FakeStore(notFound: kAllProductIds.toList());
      final service = _serviceWith(store);

      expect(await service.loadProducts(), isFalse);
      final report = service.lastQuery!;
      expect(report.outcome, ProductQueryOutcome.productsNotFound);
      expect(report.storeAvailable, isTrue);
      expect(report.returnedIds, isEmpty);
      expect(report.notFoundIds, hasLength(3));
      // The message points at the store, because that is where the fix is.
      expect(report.message, contains('App Store'));
    });

    test('a restricted device is reported as such, not as a missing product',
        () async {
      final service = _serviceWith(_FakeStore(available: false));
      expect(await service.loadProducts(), isFalse);
      final report = service.lastQuery!;
      expect(report.outcome, ProductQueryOutcome.storeUnavailable);
      expect(report.message, contains('Screen Time'));
    });

    test('a query error is reported as a query error', () async {
      final service = _serviceWith(_FakeStore(
        error: IAPError(
            source: 'ios', code: 'storekit_error', message: 'network down'),
      ));
      expect(await service.loadProducts(), isFalse);
      expect(service.lastQuery?.outcome, ProductQueryOutcome.queryFailed);
    });

    test('an empty answer is retried before giving up', () async {
      final store = _FakeStore(notFound: kAllProductIds.toList());
      final service = _serviceWith(store);
      await service.loadProducts();
      // StoreKit can answer empty for a moment after launch; one attempt at
      // screen-open would leave dashes on screen for the whole session.
      expect(store.queries, SubscriptionService.productQueryAttempts);
      expect(service.lastQuery?.attempts,
          SubscriptionService.productQueryAttempts);
    });

    test('a successful query is not retried', () async {
      final store =
          _FakeStore(products: [_product(kPlusProductId, '£17.99', 17.99)]);
      final service = _serviceWith(store);
      await service.loadProducts();
      expect(store.queries, 1);
    });
  });

  group('restore reaches the backend before it reports', () {
    /// A store that hands back one restored transaction, the way StoreKit
    /// does: asynchronously, after restorePurchases() has already returned.
    _FakeStore restoringStore({Duration delay = const Duration(milliseconds: 20)}) {
      final store = _FakeStore(products: const []);
      store.onRestore = () {
        Future<void>.delayed(delay, () {
          store.purchases.add([
            PurchaseDetails(
              productID: kPlusProductId,
              purchaseID: '2000000999',
              verificationData: PurchaseVerificationData(
                localVerificationData: 'local',
                serverVerificationData: 'jws',
                source: 'app_store',
              ),
              transactionDate: null,
              status: PurchaseStatus.restored,
            ),
          ]);
        });
      };
      return store;
    }

    test('waits for the delivered transaction instead of reporting first',
        () async {
      final store = restoringStore();
      final verified = <Map<String, dynamic>>[];
      final service = _serviceWith(store, onVerify: verified.add);
      service.listen();

      final report = await service.restorePurchases();

      // The backend was called before the restore reported anything — the
      // old code answered the user while this was still in flight.
      expect(verified, hasLength(1));
      expect(verified.single['store'], 'apple');
      expect(verified.single['transactionId'], '2000000999');
      expect(report.delivered, 1);
      expect(report.verified, 1);
      expect(report.foundNothing, isFalse);
      await service.dispose();
    });

    test('an empty restore is reported as finding nothing', () async {
      final store = _FakeStore(products: const []);
      final service = _serviceWith(store);
      service.listen();

      final report = await service.restorePurchases();

      expect(report.delivered, 0);
      expect(report.foundNothing, isTrue);
      await service.dispose();
    });

    test('a purchase with no store handle is never sent or finished',
        () async {
      // Verifying nothing would be refused, and finishing it would throw a
      // paid subscription away.
      final store = _FakeStore(products: const []);
      store.onRestore = () {
        store.purchases.add([
          PurchaseDetails(
            productID: kPlusProductId,
            purchaseID: null,
            verificationData: PurchaseVerificationData(
              localVerificationData: '',
              serverVerificationData: '',
              source: 'app_store',
            ),
            transactionDate: null,
            status: PurchaseStatus.restored,
          ),
        ]);
      };
      final verified = <Map<String, dynamic>>[];
      final service = _serviceWith(store, onVerify: verified.add);
      service.listen();

      final report = await service.restorePurchases();

      expect(verified, isEmpty);
      expect(store.completed, isEmpty);
      expect(report.verified, 0);
      await service.dispose();
    });

    test('the log names what arrived, without any receipt data', () async {
      final store = restoringStore();
      final service = _serviceWith(store, onVerify: (_) {});
      service.listen();

      final lines = await _captureLogs(() async {
        await service.restorePurchases();
      });
      final joined = lines.join('\n');

      expect(joined, contains('restore requested'));
      expect(joined, contains('purchase productId=$kPlusProductId'));
      expect(joined, contains('status=restored'));
      expect(joined, contains('calling verifySubscriptionPurchase'));
      expect(joined, contains('restore finished delivered=1'));
      // The receipt itself must never be printed.
      expect(joined, isNot(contains('jws')));
      expect(joined, isNot(contains('local')));
      await service.dispose();
    });
  });

  group('a transaction is only finished once the backend grants it', () {
    PurchaseDetails delivered(
      PurchaseStatus status, {
      String? purchaseId = '2000000999',
    }) =>
        PurchaseDetails(
          productID: kPlusProductId,
          purchaseID: purchaseId,
          verificationData: PurchaseVerificationData(
            localVerificationData: 'local',
            serverVerificationData: 'jws',
            source: 'app_store',
          ),
          transactionDate: null,
          status: status,
        )..pendingCompletePurchase = true;

    /// Pushes one transaction at the service and waits for it to be handled.
    Future<void> deliver(_FakeStore store, PurchaseDetails purchase) async {
      store.purchases.add([purchase]);
      await Future<void>.delayed(const Duration(milliseconds: 30));
    }

    test('a purchased transaction calls the callable', () async {
      final store = _FakeStore();
      final sent = <Map<String, dynamic>>[];
      final service = _serviceWith(store, onVerify: sent.add)..listen();

      await deliver(store, delivered(PurchaseStatus.purchased));

      expect(sent, hasLength(1));
      expect(sent.single['store'], 'apple');
      expect(sent.single['transactionId'], '2000000999');
      await service.dispose();
    });

    test('a restored transaction calls the callable', () async {
      final store = _FakeStore();
      final sent = <Map<String, dynamic>>[];
      final service = _serviceWith(store, onVerify: sent.add)..listen();

      await deliver(store, delivered(PurchaseStatus.restored));

      expect(sent, hasLength(1));
      expect(sent.single['transactionId'], '2000000999');
      await service.dispose();
    });

    test('a null purchase id is never sent and never finished', () async {
      final store = _FakeStore();
      final sent = <Map<String, dynamic>>[];
      final service = _serviceWith(store, onVerify: sent.add)..listen();

      await deliver(store, delivered(PurchaseStatus.purchased, purchaseId: null));

      expect(sent, isEmpty);
      expect(store.completed, isEmpty,
          reason: 'finishing it would destroy a paid purchase');
      await service.dispose();
    });

    test('a network failure leaves the transaction unfinished', () async {
      final store = _FakeStore();
      final service = _serviceWith(store,
          onVerify: (_) => throw Exception('SocketException: no route'))
        ..listen();

      await deliver(store, delivered(PurchaseStatus.purchased));

      expect(store.completed, isEmpty);
      await service.dispose();
    });

    for (final code in ['unauthenticated', 'not-found', 'unavailable']) {
      test('a $code callable failure leaves the transaction unfinished',
          () async {
        // App Check, auth and a missing deployment are all OUR problem, not
        // the user's — the purchase must survive them.
        final store = _FakeStore();
        final service = _serviceWith(store,
            onVerify: (_) =>
                throw FirebaseFunctionsException(code: code, message: code))
          ..listen();

        await deliver(store, delivered(PurchaseStatus.purchased));

        expect(store.completed, isEmpty);
        await service.dispose();
      });
    }

    test('even an outright backend rejection leaves it unfinished', () async {
      // This is what consumed a real purchase: "permission-denied" was read as
      // a final answer and the transaction was finished, so the store never
      // offered it again and the money was gone.
      final store = _FakeStore();
      final service = _serviceWith(store,
          onVerify: (_) => throw FirebaseFunctionsException(
              code: 'permission-denied',
              message: 'Purchase could not be verified.'))
        ..listen();

      await deliver(store, delivered(PurchaseStatus.purchased));

      expect(store.completed, isEmpty);
      await service.dispose();
    });

    test('a granted purchase refreshes the entitlement, THEN finishes',
        () async {
      final store = _FakeStore();
      final order = <String>[];
      final service = _serviceWith(store, onVerify: (_) => order.add('verify'))
        ..onVerified = (() async => order.add('refresh'))
        ..listen();
      store.onComplete = () => order.add('complete');

      await deliver(store, delivered(PurchaseStatus.purchased));

      // The plan must be in hand before the store lets go of the transaction.
      expect(order, ['verify', 'refresh', 'complete']);
      expect(store.completed, [kPlusProductId]);
      await service.dispose();
    });

    test('only a real rejection says the purchase could not be verified',
        () async {
      final store = _FakeStore();
      final messages = <String?>[];
      final service = _serviceWith(store,
          onVerify: (_) => throw FirebaseFunctionsException(
              code: 'not-found', message: 'NOT_FOUND'))
        ..listen();
      service.results.listen((r) => messages.add(r.message));

      await deliver(store, delivered(PurchaseStatus.purchased));

      // A missing deployment must not be dressed up as a refused purchase.
      expect(messages.single, isNot(contains('could not be verified')));
      expect(messages.single, contains('not-found'));
      await service.dispose();
    });
  });

  group('what a TestFlight log shows', () {
    test('the query result is printed where a real device can see it',
        () async {
      final service = _serviceWith(_FakeStore(
        products: [_product(kPlusProductId, '£17.99', 17.99)],
        notFound: [kBasicProductId, kProProductId],
      ));
      final lines = await _captureLogs(service.loadProducts);
      final summary = lines.firstWhere((l) => l.contains('[BILLING-IOS]'));

      expect(summary, contains('storeAvailable=true'));
      expect(summary, contains('returnedProductsCount=1'));
      expect(summary, contains(kPlusProductId));
      // notFoundIDs is the field that says "ask App Store Connect".
      expect(summary, contains('notFoundIds='));
      expect(summary, contains(kBasicProductId));
      expect(summary, contains(kProProductId));
      expect(summary, contains('queryError=none'));

      final product = lines.firstWhere((l) => l.contains('product id='));
      expect(product, contains('price=£17.99'));
      expect(product, contains('currencyCode=GBP'));
      expect(product, contains('rawPrice=17.99'));
    });

    test('nothing personal or payment-related is printed', () async {
      final service = _serviceWith(
          _FakeStore(products: [_product(kPlusProductId, '£17.99', 17.99)]));
      final lines = await _captureLogs(service.loadProducts);
      final joined = lines.join('\n').toLowerCase();
      for (final forbidden in ['token', 'receipt', 'email', 'card', 'uid']) {
        expect(joined, isNot(contains(forbidden)));
      }
    });
  });

  // ── Usage on screen ───────────────────────────────────────────────────────

  group('usage is shown for every plan', () {
    test('Free shows the 5-minute lifetime allowance', () async {
      final controller = await _boundTo({
        'plan': 'free',
        'freeUsedMs': 2 * kMsPerMinute + 14000,
        'remainingMs': 2 * kMsPerMinute + 46000,
        'allowanceSource': 'free',
      });
      expect(formatSpeechDuration(controller.displayedUsedMs), '2m 14s');
      expect(formatSpeechDuration(controller.entitlement.totalMs), '5m');
      expect(formatSpeechDuration(controller.displayedRemainingMs), '2m 46s');
      controller.dispose();
    });

    test('Basic shows used and remaining', () async {
      final controller =
          await _boundTo(_paidDoc('basic', 15, 4 * kMsPerMinute + 32000));
      expect(formatSpeechDuration(controller.displayedUsedMs), '4m 32s');
      expect(formatSpeechDuration(controller.entitlement.totalMs), '15m');
      expect(formatSpeechDuration(controller.displayedRemainingMs), '10m 28s');
      controller.dispose();
    });

    test('Plus shows used and remaining', () async {
      final controller =
          await _boundTo(_paidDoc('plus', 35, 12 * kMsPerMinute + 24000));
      expect(formatSpeechDuration(controller.displayedUsedMs), '12m 24s');
      expect(formatSpeechDuration(controller.entitlement.totalMs), '35m');
      expect(formatSpeechDuration(controller.displayedRemainingMs), '22m 36s');
      controller.dispose();
    });

    test('Pro shows used and remaining', () async {
      final controller =
          await _boundTo(_paidDoc('pro', 55, 18 * kMsPerMinute + 10000));
      expect(formatSpeechDuration(controller.displayedUsedMs), '18m 10s');
      expect(formatSpeechDuration(controller.entitlement.totalMs), '55m');
      expect(formatSpeechDuration(controller.displayedRemainingMs), '36m 50s');
      controller.dispose();
    });
  });

  group('usage updates while a session runs', () {
    /// Wires the meter to the entitlement exactly as main.dart does.
    (UsageMeter, SpeechActivityMeter, _Clock) meterFor(
      EntitlementController controller, {
      Future<Map<String, dynamic>> Function(Map<String, dynamic>)? sender,
    }) {
      final clock = _Clock();
      final speech = SpeechActivityMeter();
      final meter = UsageMeter(
        speech: speech,
        now: clock.call,
        flushDelay: const Duration(minutes: 5),
        safetyInterval: const Duration(minutes: 5),
        sender: sender ?? (_) async => {'remainingMs': 0, 'allowed': true},
      );
      meter.onPendingUsage = controller.applyPendingSpeechMs;
      meter.onRemaining = controller.applyRemainingMs;
      meter.start('session-1');
      return (meter, speech, clock);
    }

    test('translated speech moves the display immediately', () async {
      final controller =
          await _boundTo(_paidDoc('plus', 35, 12 * kMsPerMinute + 24000));
      var notifications = 0;
      controller.addListener(() => notifications++);
      final (meter, speech, clock) = meterFor(controller);

      // Before the batched report reaches the server.
      _speakAndTranslate(speech, clock, const Duration(seconds: 8));
      meter.onUtteranceTranslated();

      expect(notifications, greaterThan(0),
          reason: 'the UI must be told, not left to wait for the server');
      expect(controller.pendingSpeechMs, closeTo(8000, 400));
      expect(controller.displayedUsedMs,
          closeTo(12 * kMsPerMinute + 24000 + 8000, 400));
      expect(controller.displayedRemainingMs,
          closeTo(22 * kMsPerMinute + 36000 - 8000, 400));
      meter.dispose();
      controller.dispose();
    });

    test('silent listening does not change the display', () async {
      final controller =
          await _boundTo(_paidDoc('basic', 15, 4 * kMsPerMinute + 32000));
      final before = controller.displayedUsedMs;
      var notifications = 0;
      controller.addListener(() => notifications++);
      final (meter, speech, clock) = meterFor(controller);

      _feed(speech, clock, rms: _silence, total: const Duration(minutes: 10));

      expect(controller.pendingSpeechMs, 0);
      expect(controller.displayedUsedMs, before);
      expect(notifications, 0, reason: 'nothing changed, so nothing to say');
      meter.dispose();
      controller.dispose();
    });

    test('playing a translation aloud changes usage by zero', () async {
      final controller =
          await _boundTo(_paidDoc('pro', 55, 18 * kMsPerMinute + 10000));
      final before = controller.displayedUsedMs;
      final (meter, speech, clock) = meterFor(controller);

      // Loud audio while the uplink is muted for Sayvo's own voice, ten times.
      for (var i = 0; i < 10; i++) {
        _feed(speech, clock,
            rms: _speech, total: const Duration(seconds: 3), gated: true);
      }

      expect(controller.pendingSpeechMs, 0);
      expect(controller.displayedUsedMs, before);
      meter.dispose();
      controller.dispose();
    });

    test('the server replaces the local estimate rather than stacking on it',
        () async {
      final controller =
          await _boundTo(_paidDoc('plus', 35, 12 * kMsPerMinute + 24000));
      final (meter, speech, clock) = meterFor(
        controller,
        // The server accepted the speech and says what is left.
        sender: (_) async => {
          'remainingMs': 22 * kMsPerMinute + 28000,
          'allowed': true,
        },
      );

      _speakAndTranslate(speech, clock, const Duration(seconds: 8));
      meter.onUtteranceTranslated();
      expect(controller.pendingSpeechMs, greaterThan(0));

      await meter.finish();

      // Reconciled: the overlay is gone and the server's figure stands alone,
      // not added to the estimate it replaced.
      expect(controller.pendingSpeechMs, 0);
      expect(formatSpeechDuration(controller.displayedRemainingMs), '22m 28s');
      expect(formatSpeechDuration(controller.displayedUsedMs), '12m 32s');
      meter.dispose();
      controller.dispose();
    });

    test('a fresh document from Firestore clears the local estimate',
        () async {
      // Stopping and reopening the app must show the authoritative number.
      final firestore = FakeFirebaseFirestore();
      await firestore
          .collection('entitlements')
          .doc('uid-1')
          .set(_paidDoc('basic', 15, 4 * kMsPerMinute));
      final controller = EntitlementController(firestore: firestore)
        ..bind('uid-1');
      await Future<void>.delayed(Duration.zero);

      controller.applyPendingSpeechMs(9000);
      expect(controller.displayedUsedMs, 4 * kMsPerMinute + 9000);

      await firestore
          .collection('entitlements')
          .doc('uid-1')
          .set(_paidDoc('basic', 15, 4 * kMsPerMinute + 9000));
      await Future<void>.delayed(Duration.zero);

      expect(controller.pendingSpeechMs, 0);
      expect(formatSpeechDuration(controller.displayedUsedMs), '4m 9s');
      controller.dispose();
    });

    test('the estimate can never show more than the allowance', () async {
      final controller = await _boundTo(_paidDoc('basic', 15, 14 * kMsPerMinute));
      controller.applyPendingSpeechMs(10 * kMsPerMinute);
      expect(controller.displayedUsedMs, 15 * kMsPerMinute);
      expect(controller.displayedRemainingMs, 0);
      controller.dispose();
    });
  });
}
