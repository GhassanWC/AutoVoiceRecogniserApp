import 'dart:async';
import 'dart:developer' as developer;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';

import 'entitlement.dart';

/// App-wide view of the SERVER's entitlement for the signed-in user.
///
/// It streams the read-only `entitlements/{uid}` document, so minutes tick
/// down live while a session runs. The value is only ever a mirror: nothing
/// here can grant anything, and a network failure leaves the last known value
/// in place for UX rather than upgrading or downgrading anybody.
class EntitlementController extends ChangeNotifier {
  EntitlementController({
    FirebaseFirestore? firestore,
    FirebaseFunctions? functions,
  })  : _firestore = firestore,
        _functions = functions;

  // Both resolved lazily: constructing this must not require an initialized
  // Firebase app (widget tests build the whole shell without one).
  final FirebaseFirestore? _firestore;
  final FirebaseFunctions? _functions;

  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _subscription;
  String? _uid;

  Entitlement _entitlement = Entitlement.free;
  Entitlement get entitlement => _entitlement;

  /// True once the server's value has been seen at least once. Until then the
  /// UI shows the free default rather than claiming a plan.
  bool _loaded = false;
  bool get loaded => _loaded;

  bool get canStartSession => _entitlement.hasSpeechLeft;

  /// Points at a user (or clears on sign-out).
  void bind(String? uid) {
    if (uid == _uid) return;
    _uid = uid;
    _subscription?.cancel();
    _subscription = null;
    if (uid == null) {
      _entitlement = Entitlement.free;
      _loaded = false;
      notifyListeners();
      return;
    }
    _subscription = (_firestore ?? FirebaseFirestore.instance)
        .collection('entitlements')
        .doc(uid)
        .snapshots()
        .listen(_onSnapshot, onError: (Object error) {
      // Offline or rules hiccup: keep showing what we last knew.
      developer.log('entitlement stream error: $error', name: 'billing');
    });
  }

  void _onSnapshot(DocumentSnapshot<Map<String, dynamic>> snapshot) {
    final data = snapshot.data();
    _entitlement =
        data == null ? Entitlement.free : Entitlement.fromMap(data);
    _loaded = true;
    notifyListeners();
  }

  /// Forces a server read — used after a purchase or a restore, where the
  /// document write and the stream may race the UI.
  Future<void> refresh() async {
    try {
      final result = await (_functions ?? FirebaseFunctions.instance)
          .httpsCallable('getEntitlement')
          .call<Map<String, dynamic>>();
      _entitlement = Entitlement.fromMap(Map<String, dynamic>.from(result.data));
      _loaded = true;
      notifyListeners();
    } catch (e) {
      // Never downgrade on a failed refresh; the stream remains the source.
      developer.log('entitlement refresh failed: $e', name: 'billing');
    }
  }

  /// Applies a server-reported remainder from the usage report, so the UI
  /// counts down between Firestore snapshots without waiting for one.
  ///
  /// This only ever moves when speech was actually translated — a quiet room
  /// produces no reports, so the number on screen simply stays put.
  void applyRemainingMs(int remainingMs) {
    final clamped = remainingMs < 0 ? 0 : remainingMs;
    if (clamped == _entitlement.remainingMs) return;
    final spent = (_entitlement.totalMs - clamped).clamp(0, _entitlement.totalMs);
    _entitlement = Entitlement(
      plan: _entitlement.plan,
      subscriptionStatus: _entitlement.subscriptionStatus,
      store: _entitlement.store,
      storeProductId: _entitlement.storeProductId,
      currentPeriodStart: _entitlement.currentPeriodStart,
      currentPeriodEnd: _entitlement.currentPeriodEnd,
      allowanceMs: _entitlement.allowanceMs,
      usedMs: _entitlement.allowanceSource == 'plan' ? spent : _entitlement.usedMs,
      freeUsedMs:
          _entitlement.allowanceSource == 'free' ? spent : _entitlement.freeUsedMs,
      remainingMs: clamped,
      allowanceSource: _entitlement.allowanceSource,
    );
    notifyListeners();
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }
}
