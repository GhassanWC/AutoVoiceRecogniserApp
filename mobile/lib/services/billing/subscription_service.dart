import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io' show Platform;

import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart'
    show debugPrint, kIsWeb, visibleForTesting;
import 'package:flutter/services.dart' show MethodChannel;
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../utils/account_token.dart';
import '../../utils/plans.dart';

/// Outcome of a purchase attempt, as far as the APP is concerned. A granted
/// entitlement is never implied by any of these — only the server decides
/// that, after the store has verified the purchase.
enum PurchaseOutcome { success, cancelled, pending, failed, unavailable }

/// The only two payment systems Sayvo uses.
enum BillingStore { apple, google }

/// Why the paywall has prices, or hasn't.
enum ProductQueryOutcome {
  /// The store returned at least one product.
  loaded,

  /// In-app purchase is not possible here at all (web, desktop preview).
  unsupportedPlatform,

  /// The store itself said no — commonly purchases restricted on the device
  /// (Screen Time → Content & Privacy → In-app Purchases).
  storeUnavailable,

  /// The store answered, and did not recognise our product ids. Almost always
  /// App Store Connect / Play Console configuration rather than the app.
  productsNotFound,

  /// The store returned an error for the query.
  queryFailed,
}

/// The result of asking the store about our products, kept so the paywall and
/// the logs can say WHY there are no prices instead of only that there are
/// none.
class ProductQueryReport {
  const ProductQueryReport({
    required this.supportedPlatform,
    required this.storeAvailable,
    required this.requested,
    required this.products,
    required this.notFoundIds,
    required this.error,
    required this.attempts,
  });

  factory ProductQueryReport.unsupported(Set<String> requested) =>
      ProductQueryReport(
        supportedPlatform: false,
        storeAvailable: false,
        requested: requested,
        products: const [],
        notFoundIds: const [],
        error: null,
        attempts: 0,
      );

  factory ProductQueryReport.storeUnavailable(Set<String> requested) =>
      ProductQueryReport(
        supportedPlatform: true,
        storeAvailable: false,
        requested: requested,
        products: const [],
        notFoundIds: const [],
        error: null,
        attempts: 0,
      );

  final bool supportedPlatform;
  final bool storeAvailable;
  final Set<String> requested;
  final List<ProductDetails> products;
  final List<String> notFoundIds;
  final String? error;
  final int attempts;

  List<String> get returnedIds => [for (final p in products) p.id]..sort();

  ProductQueryOutcome get outcome {
    if (!supportedPlatform) return ProductQueryOutcome.unsupportedPlatform;
    if (!storeAvailable) return ProductQueryOutcome.storeUnavailable;
    if (products.isNotEmpty) return ProductQueryOutcome.loaded;
    if (error != null) return ProductQueryOutcome.queryFailed;
    return ProductQueryOutcome.productsNotFound;
  }

  /// What to tell the user. Each case is actionable by somebody: the device
  /// owner, or whoever configures the store.
  String get message => switch (outcome) {
        ProductQueryOutcome.loaded => '',
        ProductQueryOutcome.unsupportedPlatform =>
          'Subscriptions are not available on this device.',
        ProductQueryOutcome.storeUnavailable =>
          'In-app purchases are turned off for this device. Check Screen Time '
              '→ Content & Privacy Restrictions → In-app Purchases.',
        ProductQueryOutcome.productsNotFound =>
          'Sayvo plans are not available from the App Store yet. This usually '
              'clears within a few hours of them going live.',
        ProductQueryOutcome.queryFailed =>
          'The App Store could not be reached. Check your connection and try '
              'again.',
      };
}

/// Sends one purchase to the backend for verification. Injectable so the
/// purchase and restore flows can be tested without a Firebase app, exactly
/// as the usage meter's sender is.
typedef VerifySender = Future<void> Function(Map<String, dynamic> payload);

class PurchaseResult {
  const PurchaseResult(this.outcome, {this.message});
  final PurchaseOutcome outcome;
  final String? message;
}

/// What a Restore Purchases actually did, so the UI can tell "nothing to
/// restore" apart from "restored and verified".
class RestoreReport {
  const RestoreReport({required this.delivered, required this.verified});

  /// Transactions the store handed back.
  final int delivered;

  /// Of those, how many the server accepted.
  final int verified;

  bool get foundNothing => delivered == 0;
}

/// Wraps the platform billing clients: StoreKit on iOS, Google Play Billing
/// on Android, through the official `in_app_purchase` plugin. There is no
/// other payment path — no web checkout, no third-party processor.
///
/// The plugin's purchase callback is treated as a HINT ONLY. Every purchase is
/// sent to `verifySubscriptionPurchase`, which asks Apple/Google directly and
/// is the only thing that can change an entitlement.
class SubscriptionService {
  SubscriptionService({
    InAppPurchase? iap,
    FirebaseFunctions? functions,
    BillingStore? store,
    String? Function()? uidProvider,
    VerifySender? verifySender,
  })  : _injectedIap = iap,
        _functions = functions,
        _injectedStore = store,
        _uidProvider = uidProvider,
        _verifySender = verifySender;

  final VerifySender? _verifySender;

  /// Who is signed in, so a purchase can carry the account it was made for.
  final String? Function()? _uidProvider;

  /// How many times a store query that returns nothing is retried, and how
  /// long the first wait is (it lengthens each attempt).
  static const int productQueryAttempts = 3;
  static const Duration productQueryRetryDelay = Duration(milliseconds: 800);

  final BillingStore? _injectedStore;

  /// Which platform billing system is in play. iOS always uses Apple's, and
  /// Android always uses Google Play's — there is no third path.
  BillingStore get store =>
      _injectedStore ??
      (!kIsWeb && Platform.isIOS ? BillingStore.apple : BillingStore.google);

  // Resolved lazily so constructing this needs neither a store connection nor
  // an initialized Firebase app.
  final InAppPurchase? _injectedIap;
  final FirebaseFunctions? _functions;

  InAppPurchase get _iap => _injectedIap ?? InAppPurchase.instance;

  StreamSubscription<List<PurchaseDetails>>? _subscription;
  final StreamController<PurchaseResult> _results =
      StreamController<PurchaseResult>.broadcast();

  /// Emits as purchases resolve — including ones the store completes later
  /// (pending payments, or a purchase finished outside the app).
  Stream<PurchaseResult> get results => _results.stream;

  List<ProductDetails> _products = const [];

  /// Store products with their LOCALIZED prices. Empty until [loadProducts].
  List<ProductDetails> get products => _products;

  ProductDetails? productFor(SayvoPlan plan) {
    final id = kPlanProductIds[plan];
    if (id == null) return null;
    for (final product in _products) {
      if (product.id == id) return product;
    }
    return null;
  }

  /// Whether in-app purchase exists here at all.
  ///
  /// An injected [store] means a caller is standing in for a platform — only
  /// tests do that — so it answers for the platform too. Production never
  /// injects one and falls through to the real check.
  bool get isSupportedPlatform =>
      _injectedStore != null ||
      (!kIsWeb && (Platform.isIOS || Platform.isAndroid));

  /// Starts listening for purchase updates. Safe to call more than once.
  ///
  /// Nothing can be verified without this: restored and completed purchases
  /// both arrive on the store's stream, never as a return value.
  void listen() {
    if (_subscription != null) {
      debugPrint('[BILLING-IOS] listen: already attached');
      return;
    }
    _subscription = _iap.purchaseStream.listen(
      _onPurchases,
      onError: (Object error) {
        debugPrint('[BILLING-IOS] purchase stream error: $error');
        _results.add(PurchaseResult(PurchaseOutcome.failed, message: '$error'));
      },
      onDone: () => debugPrint('[BILLING-IOS] purchase stream closed'),
    );
    debugPrint('[BILLING-IOS] purchase listener attached');
  }

  /// What the last store query actually returned.
  ///
  /// The paywall can only say "no prices" on its own; this says WHY, which is
  /// the difference between an App Store Connect problem, a device with
  /// purchases restricted, and a transient query failure.
  ProductQueryReport? _lastQuery;
  ProductQueryReport? get lastQuery => _lastQuery;

  /// Loads the three subscriptions and their localized prices from the store.
  ///
  /// Retries a few times when the store answers with nothing at all: StoreKit
  /// can come back empty for a moment right after launch, and a single attempt
  /// at screen-open would leave the paywall showing dashes for the rest of the
  /// session.
  Future<bool> loadProducts() async {
    if (!isSupportedPlatform) {
      _lastQuery = ProductQueryReport.unsupported(kAllProductIds);
      _logQuery();
      return false;
    }
    await _ensureBundleId();
    final available = await _iap.isAvailable();
    if (!available) {
      _lastQuery = ProductQueryReport.storeUnavailable(kAllProductIds);
      _logQuery();
      return false;
    }

    ProductQueryReport report = ProductQueryReport.storeUnavailable(kAllProductIds);
    for (var attempt = 1; attempt <= productQueryAttempts; attempt++) {
      final response = await _iap.queryProductDetails(kAllProductIds);
      report = ProductQueryReport(
        supportedPlatform: true,
        storeAvailable: true,
        requested: kAllProductIds,
        products: response.productDetails,
        notFoundIds: response.notFoundIDs,
        error: response.error?.toString(),
        attempts: attempt,
      );
      _products = response.productDetails;
      if (_products.isNotEmpty) break;
      if (attempt < productQueryAttempts) {
        await Future<void>.delayed(productQueryRetryDelay * attempt);
      }
    }

    _lastQuery = report;
    _logQuery();
    return _products.isNotEmpty;
  }

  /// TEMPORARY far-side diagnostics for the "prices show —" investigation.
  ///
  /// Uses [debugPrint], not `dart:developer`: developer.log goes to the VM
  /// service, which is not attached in a TestFlight build, so those lines
  /// never reach a real device. Nothing personal or payment-related is
  /// printed — product metadata, counts and ids only.
  void _logQuery() {
    final report = _lastQuery;
    if (report == null) return;
    debugPrint(
      '[BILLING-IOS] storeAvailable=${report.storeAvailable} '
      'supportedPlatform=${report.supportedPlatform} '
      'bundleId=${_bundleId ?? 'unknown'} '
      'requestedProductIds=${report.requested.toList()..sort()} '
      'returnedProductsCount=${report.products.length} '
      'returnedProductIds=${report.returnedIds} '
      'notFoundIds=${report.notFoundIds} '
      'queryError=${report.error ?? 'none'} '
      'attempts=${report.attempts}',
    );
    for (final product in report.products) {
      debugPrint(
        '[BILLING-IOS] product id=${product.id} title=${product.title} '
        'price=${product.price} currencyCode=${product.currencyCode} '
        'rawPrice=${product.rawPrice}',
      );
    }
  }

  static const MethodChannel _appInfo =
      MethodChannel('app.livetranslator/app_info');
  String? _bundleId;

  /// Reads the bundle id the app is ACTUALLY running under, so a mismatch
  /// with App Store Connect is visible rather than assumed.
  ///
  /// Strictly best effort, and time-boxed: a diagnostic must never be able to
  /// hold up the paywall, on a platform without the channel or anywhere else.
  Future<void> _ensureBundleId() async {
    if (_bundleId != null || kIsWeb) return;
    try {
      _bundleId = await _appInfo
          .invokeMethod<String>('bundleId')
          .timeout(const Duration(seconds: 1));
    } catch (_) {
      _bundleId = null;
    }
  }

  /// Starts the platform's own purchase sheet. Upgrades and downgrades go
  /// through the same call — the stores handle proration within the
  /// subscription group.
  ///
  /// The signed-in account's purchase identifier is recorded WITH the purchase
  /// by the store (Play's obfuscated account id, Apple's appAccountToken), so
  /// a subscription carries the account it was bought for and a mismatch is
  /// visible server-side.
  Future<void> buy(ProductDetails product) async {
    final uid = _uidProvider?.call();
    final param = PurchaseParam(
      productDetails: product,
      applicationUserName: uid == null ? null : accountTokenForUid(uid),
    );
    await _iap.buyNonConsumable(purchaseParam: param);
  }

  /// Asks the store to replay past purchases; entitlement is then re-verified
  /// server-side exactly like a fresh purchase.
  ///
  /// The store's own call returns as soon as IT is done — the transactions
  /// arrive afterwards, on the purchase stream, and the backend call happens
  /// later still. Reporting a result before that has been through says "no
  /// subscription found" for a restore that is about to succeed, so this
  /// waits for the stream, bounded, and reports what actually arrived.
  Future<RestoreReport> restorePurchases() async {
    _restoreDelivered = 0;
    _restoreVerified = 0;
    final settled = _restoreSettled = Completer<void>();
    debugPrint('[BILLING-IOS] restore requested');
    try {
      await _iap.restorePurchases();
    } catch (e) {
      debugPrint('[BILLING-IOS] restore call failed: $e');
    }
    if (!settled.isCompleted) {
      // Nothing to restore looks exactly like a slow store, so give up after
      // a bounded wait rather than hanging the button.
      await settled.future
          .timeout(restoreSettleWindow, onTimeout: () {})
          .catchError((_) {});
    }
    _restoreSettled = null;
    final report =
        RestoreReport(delivered: _restoreDelivered, verified: _restoreVerified);
    debugPrint('[BILLING-IOS] restore finished delivered=${report.delivered} '
        'verified=${report.verified}');
    return report;
  }

  /// The region the billing callables are deployed to. Stated explicitly
  /// rather than relying on the default, so the app and the deployment cannot
  /// silently disagree about where the function lives.
  static const String functionsRegion = 'us-central1';

  /// The Firebase project this build actually talks to. Best effort: without
  /// an initialized app (tests) it reports unknown rather than throwing.
  static String firebaseProjectId() {
    try {
      return Firebase.app().options.projectId;
    } catch (_) {
      return 'unknown';
    }
  }

  Future<void> _callVerify(Map<String, dynamic> payload) async {
    final functions = _functions ??
        FirebaseFunctions.instanceFor(
          app: Firebase.app(),
          region: functionsRegion,
        );
    await functions
        .httpsCallable('verifySubscriptionPurchase')
        .call<Map<String, dynamic>>(payload);
  }

  /// Re-reads the authoritative entitlement after the backend accepts a
  /// purchase, before the transaction is finished with the store. Wired to
  /// EntitlementController.refresh in main.dart.
  Future<void> Function()? onVerified;

  /// One line at startup naming the project and region this build will call,
  /// so a mismatch is visible in a TestFlight log instead of inferred.
  void logStartupDiagnostics() {
    debugPrint('[BILLING-IOS] firebaseProject=${firebaseProjectId()}');
    debugPrint('[BILLING-IOS] functionsRegion=$functionsRegion');
  }

  /// How long a restore waits for the store to deliver before concluding
  /// there was nothing to restore.
  static const Duration restoreSettleWindow = Duration(seconds: 10);

  Completer<void>? _restoreSettled;
  int _restoreDelivered = 0;
  int _restoreVerified = 0;

  /// Opens the PLATFORM's own subscription management — Apple's subscriptions
  /// screen on iOS, Play's on Android. Sayvo never sends anyone to a web
  /// checkout or a third-party billing portal.
  Future<bool> openManageSubscription({String? productId}) async {
    if (kIsWeb) return false;
    final uri = store == BillingStore.apple
        ? Uri.parse('https://apps.apple.com/account/subscriptions')
        : Uri.parse(
            'https://play.google.com/store/account/subscriptions'
            '?package=com.livetranslator.live_translator'
            '${productId == null ? '' : '&sku=$productId'}',
          );
    try {
      return await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (e) {
      developer.log('could not open subscription management: $e', name: 'billing');
      return false;
    }
  }

  Future<void> _onPurchases(List<PurchaseDetails> purchases) async {
    debugPrint('[BILLING-IOS] purchases received: ${purchases.length}');
    for (final purchase in purchases) {
      _restoreDelivered++;
      // Product id and status are our own metadata. The verification data is
      // the receipt and is never printed.
      debugPrint(
        '[BILLING-IOS] purchase productId=${purchase.productID} '
        'status=${purchase.status.name} '
        'hasPurchaseId=${purchase.purchaseID != null} '
        'pendingComplete=${purchase.pendingCompletePurchase} '
        'error=${purchase.error?.code ?? 'none'}',
      );
      var settled = true;
      switch (purchase.status) {
        case PurchaseStatus.pending:
          // Deferred payment (e.g. Ask to Buy). Nothing is granted yet, and
          // the store will deliver it again when it resolves.
          _results.add(const PurchaseResult(PurchaseOutcome.pending));
          continue;
        case PurchaseStatus.canceled:
          _results.add(const PurchaseResult(PurchaseOutcome.cancelled));
        case PurchaseStatus.error:
          _results.add(PurchaseResult(PurchaseOutcome.failed,
              message: purchase.error?.message));
        case PurchaseStatus.purchased:
        case PurchaseStatus.restored:
          settled = await _verify(purchase);
      }
      // Finishing a transaction tells the store to stop delivering it. Only
      // do that once the SERVER has settled it — either granting the
      // entitlement or rejecting the purchase outright. A backend outage must
      // leave the transaction in the queue so it is redelivered, rather than
      // discarding a purchase somebody paid for.
      if (settled && purchase.pendingCompletePurchase) {
        await _iap.completePurchase(purchase);
        debugPrint('[BILLING-IOS] transaction finished with the store');
      } else if (!settled) {
        debugPrint('[BILLING-IOS] transaction LEFT PENDING for redelivery');
      }
    }
    // A restore only knows it is done once the stream has been through.
    if (_restoreSettled?.isCompleted == false) _restoreSettled!.complete();
  }

  /// The payload sent for verification: an opaque store handle and nothing
  /// else. No plan, no product id, no price — the server asks the store.
  @visibleForTesting
  Map<String, dynamic> verificationPayload(PurchaseDetails purchase) =>
      store == BillingStore.apple
          ? {'store': 'apple', 'transactionId': purchase.purchaseID}
          : {
              'store': 'google',
              'purchaseToken': purchase.verificationData.serverVerificationData,
            };

  /// Hands the opaque store handle to the backend. The plan is NEVER sent —
  /// the server derives it from what Apple/Google say about this purchase.
  ///
  /// Returns whether the purchase is SETTLED: verified, or definitively
  /// refused. A transient failure returns false so the transaction stays in
  /// the store's queue and is delivered again.
  /// Returns true ONLY when the backend positively granted the entitlement.
  ///
  /// Every other outcome — a missing transaction id, a network failure, App
  /// Check, auth, or a rejection — returns false, which leaves the StoreKit
  /// transaction unfinished so the store delivers it again. Finishing a
  /// transaction the backend never accepted destroys a purchase somebody paid
  /// for, and there is no way to get it back.
  Future<bool> _verify(PurchaseDetails purchase) async {
    final payload = verificationPayload(purchase);
    debugPrint(
      '[BILLING-IOS] verify start project=${firebaseProjectId()} '
      'region=$functionsRegion status=${purchase.status.name} '
      'productId=${purchase.productID} '
      'hasPurchaseId=${purchase.purchaseID != null}',
    );

    final handleField =
        payload.containsKey('transactionId') ? 'transactionId' : 'purchaseToken';
    final handle = payload[handleField];
    if (handle is! String || handle.isEmpty) {
      // Nothing to verify with. Reported visibly and left UNFINISHED.
      debugPrint('[BILLING-IOS] missing_purchase_id — transaction left pending');
      _results.add(const PurchaseResult(
        PurchaseOutcome.failed,
        message: 'missing_purchase_id: the store gave no transaction id.',
      ));
      return false;
    }
    // The handle is a credential; only its shape is printed.
    debugPrint('[BILLING-IOS] calling verifySubscriptionPurchase '
        'store=${payload['store']} $handleField=${handle.length} chars');

    try {
      await (_verifySender ?? _callVerify)(payload);
      _restoreVerified++;
      debugPrint('[BILLING-IOS] callable OK — backend granted the entitlement');
      // The authoritative entitlement is re-read BEFORE the transaction is
      // finished, so the plan is in hand by the time the store lets go of it.
      try {
        await onVerified?.call();
        debugPrint('[BILLING-IOS] entitlement refreshed after verification');
      } catch (e) {
        debugPrint('[BILLING-IOS] entitlement refresh failed (non-fatal): $e');
      }
      _results.add(const PurchaseResult(PurchaseOutcome.success));
      return true;
    } on FirebaseFunctionsException catch (e) {
      // The exact failure, not a blanket message — code, message and details
      // are what separate a rejected purchase from a callable we never
      // reached.
      debugPrint(
        '[BILLING-IOS] callable FAILED code=${e.code} message=${e.message} '
        'details=${e.details}',
      );
      _results.add(PurchaseResult(
        PurchaseOutcome.failed,
        message: _describeCallableFailure(e),
      ));
      return false;
    } catch (e) {
      debugPrint('[BILLING-IOS] callable THREW ${e.runtimeType}: $e');
      _results.add(PurchaseResult(
        PurchaseOutcome.failed,
        message: 'Could not reach Sayvo to confirm the purchase '
            '(${e.runtimeType}). It stays pending and will retry.',
      ));
      return false;
    }
  }

  /// "Purchase could not be verified" belongs to ONE case: the backend looked
  /// at the purchase and refused it. Everything else is the app failing to
  /// reach the backend, and saying otherwise hides the real fault.
  String _describeCallableFailure(FirebaseFunctionsException e) =>
      switch (e.code) {
        'permission-denied' =>
          e.message ?? 'The store could not confirm that purchase.',
        'unauthenticated' =>
          'Sign-in or device attestation failed [${e.code}]. The purchase '
              'stays pending.',
        'not-found' =>
          'Sayvo could not find the verification service [${e.code}]. The '
              'purchase stays pending and will retry.',
        'failed-precondition' =>
          e.message ?? 'Purchases are not ready on the server yet.',
        _ => 'Verification could not complete [${e.code}]: '
            '${e.message ?? 'no message'}. The purchase stays pending.',
      };

  Future<void> dispose() async {
    await _subscription?.cancel();
    _subscription = null;
    await _results.close();
  }
}
