import 'package:flutter/foundation.dart';

/// A record of how far the last purchase actually got.
///
/// TEMPORARY. This exists because a TestFlight build has no console: when a
/// purchase does not reach the backend there is no way, from the outside, to
/// tell whether the store never delivered it, the app never called the
/// callable, or the callable answered no. Each of those needs a different
/// fix, and guessing between them has already cost several rounds.
///
/// Every field is written at the exact point the purchase path passes it, so
/// the first "no" on screen is the line where it stopped.
@immutable
class BillingDiagnostics {
  const BillingDiagnostics({
    this.listenerAttached = false,
    this.buyRequested = false,
    this.buyProductId,
    this.buyError,
    this.purchaseReceived = false,
    this.purchaseStatus,
    this.productId,
    this.purchaseIdExists,
    this.callableCalled = false,
    this.callableResult,
    this.errorCode,
    this.errorMessage,
    this.errorDetails,
    this.clientReason,
    this.updatedAt,
  });

  /// Did we subscribe to the store's purchase stream at all? Without this,
  /// StoreKit has nobody to deliver to and nothing else below can happen.
  final bool listenerAttached;

  /// Did the app ask the store to start a purchase?
  final bool buyRequested;
  final String? buyProductId;

  /// Anything thrown by the store when starting the purchase.
  final String? buyError;

  /// Did the store deliver a transaction back to us? "No" here, with
  /// buyRequested "yes", means the break is between StoreKit and the plugin —
  /// nothing in our billing code is involved.
  final bool purchaseReceived;
  final String? purchaseStatus;
  final String? productId;

  /// Whether the delivered transaction carried the id the backend needs.
  final bool? purchaseIdExists;

  /// Was verifySubscriptionPurchase actually invoked?
  final bool callableCalled;

  /// 'success' or 'failure', once it has been.
  final String? callableResult;

  final String? errorCode;
  final String? errorMessage;
  final String? errorDetails;

  /// Why the callable was NOT called, when it wasn't. This is the field that
  /// replaces a generic "could not be verified" with something true.
  final String? clientReason;

  final DateTime? updatedAt;

  BillingDiagnostics copyWith({
    bool? listenerAttached,
    bool? buyRequested,
    String? buyProductId,
    String? buyError,
    bool? purchaseReceived,
    String? purchaseStatus,
    String? productId,
    bool? purchaseIdExists,
    bool? callableCalled,
    String? callableResult,
    String? errorCode,
    String? errorMessage,
    String? errorDetails,
    String? clientReason,
    bool clearError = false,
  }) =>
      BillingDiagnostics(
        listenerAttached: listenerAttached ?? this.listenerAttached,
        buyRequested: buyRequested ?? this.buyRequested,
        buyProductId: buyProductId ?? this.buyProductId,
        buyError: buyError ?? this.buyError,
        purchaseReceived: purchaseReceived ?? this.purchaseReceived,
        purchaseStatus: purchaseStatus ?? this.purchaseStatus,
        productId: productId ?? this.productId,
        purchaseIdExists: purchaseIdExists ?? this.purchaseIdExists,
        callableCalled: callableCalled ?? this.callableCalled,
        callableResult: callableResult ?? this.callableResult,
        errorCode: clearError ? null : (errorCode ?? this.errorCode),
        errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
        errorDetails: clearError ? null : (errorDetails ?? this.errorDetails),
        clientReason: clearError ? null : (clientReason ?? this.clientReason),
        updatedAt: DateTime.now(),
      );

  /// The first thing that did not happen — the line to look at.
  String get stoppedAt {
    if (!listenerAttached) return 'The app never listened for purchases.';
    if (!buyRequested && !purchaseReceived) {
      return 'No purchase has been attempted on this run.';
    }
    if (buyError != null) return 'The store refused to start the purchase.';
    if (!purchaseReceived) {
      return 'The store never delivered the transaction back to the app.';
    }
    if (purchaseIdExists == false) {
      return 'The transaction arrived without a transaction id.';
    }
    if (!callableCalled) {
      return clientReason ?? 'The app did not call the backend.';
    }
    if (callableResult == 'success') return 'Completed: the backend granted it.';
    return 'The backend was called and answered with an error.';
  }
}
