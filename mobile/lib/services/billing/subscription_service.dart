import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io' show Platform;

import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;
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

class PurchaseResult {
  const PurchaseResult(this.outcome, {this.message});
  final PurchaseOutcome outcome;
  final String? message;
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
  })  : _injectedIap = iap,
        _functions = functions,
        _injectedStore = store,
        _uidProvider = uidProvider;

  /// Who is signed in, so a purchase can carry the account it was made for.
  final String? Function()? _uidProvider;

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

  bool get isSupportedPlatform =>
      !kIsWeb && (Platform.isIOS || Platform.isAndroid);

  /// Starts listening for purchase updates. Safe to call more than once.
  void listen() {
    _subscription ??= _iap.purchaseStream.listen(
      _onPurchases,
      onError: (Object error) {
        developer.log('purchase stream error: $error', name: 'billing');
        _results.add(PurchaseResult(PurchaseOutcome.failed, message: '$error'));
      },
    );
  }

  /// Loads the three subscriptions and their localized prices from the store.
  Future<bool> loadProducts() async {
    if (!isSupportedPlatform) return false;
    if (!await _iap.isAvailable()) return false;
    final response = await _iap.queryProductDetails(kAllProductIds);
    if (response.error != null) {
      developer.log('queryProductDetails: ${response.error}', name: 'billing');
    }
    _products = response.productDetails;
    if (response.notFoundIDs.isNotEmpty) {
      // Normal until the products are live in App Store Connect / Play.
      developer.log('products not found: ${response.notFoundIDs}', name: 'billing');
    }
    return _products.isNotEmpty;
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
  Future<void> restorePurchases() => _iap.restorePurchases();

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
    for (final purchase in purchases) {
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
      }
    }
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
  Future<bool> _verify(PurchaseDetails purchase) async {
    try {
      final callable = (_functions ?? FirebaseFunctions.instance)
          .httpsCallable('verifySubscriptionPurchase');
      await callable.call<Map<String, dynamic>>(verificationPayload(purchase));
      _results.add(const PurchaseResult(PurchaseOutcome.success));
      return true;
    } on FirebaseFunctionsException catch (e) {
      developer.log('verification rejected: ${e.code} ${e.message}',
          name: 'billing');
      _results.add(PurchaseResult(PurchaseOutcome.failed, message: e.message));
      // The server had an answer, and the answer was no.
      return e.code == 'permission-denied' || e.code == 'invalid-argument';
    } catch (e) {
      developer.log('verification failed: $e', name: 'billing');
      _results.add(PurchaseResult(PurchaseOutcome.failed, message: '$e'));
      return false;
    }
  }

  Future<void> dispose() async {
    await _subscription?.cancel();
    _subscription = null;
    await _results.close();
  }
}
