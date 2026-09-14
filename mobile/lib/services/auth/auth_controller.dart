import 'dart:async';
import 'dart:developer' as developer;

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import '../firestore/user_repository.dart';
import '../storage/settings_store.dart';
import 'auth_service.dart';

enum AuthStatus { unknown, signedOut, signedIn }

/// Outcome of a delete-account attempt.
enum DeleteAccountResult { deleted, needsReauth, failed }

/// App-wide authentication state. Bridges Firebase auth state to the UI and
/// keeps the Firestore profile in sync with the local settings mirror:
///  - on sign-in the profile's targetLanguageCode wins (survives reinstalls);
///  - a profile without one is seeded from the local onboarding choice;
///  - later changes (Settings / listen bar / Profile) write to both.
class AuthController extends ChangeNotifier {
  AuthController({
    required AuthService authService,
    required UserRepository userRepository,
    required SettingsController settings,
  })  : _authService = authService,
        _userRepository = userRepository,
        _settings = settings {
    _subscription = _authService.authStateChanges().listen(_onAuthStateChanged);
    _settings.onTargetLanguageChanged = _pushTargetLanguage;
  }

  final AuthService _authService;
  final UserRepository _userRepository;
  final SettingsController _settings;
  StreamSubscription<User?>? _subscription;

  AuthStatus _status = AuthStatus.unknown;
  AuthStatus get status => _status;

  User? _user;
  User? get user => _user;
  String? get uid => _user?.uid;

  bool _busy = false;
  bool get busy => _busy;

  String? _errorMessage;
  String? get errorMessage => _errorMessage;

  void clearError() {
    if (_errorMessage == null) return;
    _errorMessage = null;
    notifyListeners();
  }

  Future<void> _onAuthStateChanged(User? user) async {
    _user = user;
    _status = user == null ? AuthStatus.signedOut : AuthStatus.signedIn;
    notifyListeners();
    if (user != null) {
      await _syncProfile(user);
    }
  }

  Future<void> _syncProfile(User user) async {
    try {
      await _userRepository.ensureUserDoc(user);
      final profile = await _userRepository.fetchProfile(user.uid);
      final remote = profile?.targetLanguageCode;
      if (remote != null && remote.isNotEmpty) {
        if (remote != _settings.settings.targetLanguage) {
          await _settings.applyRemoteTargetLanguage(remote);
        }
      } else {
        // First sign-in: seed the profile from the local onboarding choice.
        await _userRepository.setTargetLanguage(user.uid, _settings.settings.targetLanguage);
      }
    } catch (e) {
      // Offline sign-in restore etc. — local mirror keeps working.
      developer.log('profile sync failed: $e', name: 'auth');
    }
  }

  Future<void> _pushTargetLanguage(String code) async {
    final uid = this.uid;
    if (uid == null) return;
    try {
      await _userRepository.setTargetLanguage(uid, code);
    } catch (e) {
      developer.log('target language push failed: $e', name: 'auth');
    }
  }

  // ── UI-facing flows (return true on success, expose errorMessage on failure)

  Future<bool> _run(Future<void> Function() action) async {
    _busy = true;
    _errorMessage = null;
    notifyListeners();
    try {
      await action();
      return true;
    } on AuthException catch (e) {
      _errorMessage = e.code == 'canceled' ? null : e.message;
      return false;
    } catch (e) {
      _errorMessage = 'Something went wrong. Please try again.';
      developer.log('auth flow failed: $e', name: 'auth');
      return false;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<bool> signInWithEmail(String email, String password) =>
      _run(() => _authService.signInWithEmail(email: email, password: password));

  Future<bool> signUpWithEmail(String email, String password, {String? displayName}) =>
      _run(() => _authService.signUpWithEmail(
          email: email, password: password, displayName: displayName));

  Future<bool> sendPasswordReset(String email) =>
      _run(() => _authService.sendPasswordResetEmail(email));

  Future<bool> signInWithGoogle() => _run(_authService.signInWithGoogle);

  Future<bool> signInWithApple() => _run(_authService.signInWithApple);

  Future<void> signOut() async {
    await _run(_authService.signOut);
  }

  /// Which reauth path applies for delete-account ('password', 'google.com',
  /// 'apple.com', or null when no provider info is available).
  String? get primaryProviderId =>
      _user?.providerData.isNotEmpty == true ? _user!.providerData.first.providerId : null;

  /// Safe delete: user data first (so a half-failed attempt can simply be
  /// retried), then the auth account. Returns [DeleteAccountResult.needsReauth]
  /// when Firebase demands a recent sign-in — reauthenticate and call again.
  Future<DeleteAccountResult> deleteAccount() async {
    final uid = this.uid;
    if (uid == null) return DeleteAccountResult.failed;
    _busy = true;
    _errorMessage = null;
    notifyListeners();
    try {
      await _userRepository.deleteAllUserData(uid);
      await _authService.deleteAccount();
      return DeleteAccountResult.deleted;
    } on AuthException catch (e) {
      if (e.code == 'requires-recent-login') return DeleteAccountResult.needsReauth;
      _errorMessage = e.message;
      return DeleteAccountResult.failed;
    } catch (e) {
      _errorMessage = 'Could not delete the account. Please try again.';
      developer.log('delete account failed: $e', name: 'auth');
      return DeleteAccountResult.failed;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<bool> reauthenticateWithPassword(String password) =>
      _run(() => _authService.reauthenticateWithPassword(password));

  Future<bool> reauthenticateWithProvider() => _run(() async {
        switch (primaryProviderId) {
          case 'google.com':
            await _authService.reauthenticateWithGoogle();
          case 'apple.com':
            await _authService.reauthenticateWithApple();
          default:
            throw const AuthException('no-provider', 'Please sign in again to continue.');
        }
      });

  @override
  void dispose() {
    _settings.onTargetLanguageChanged = null;
    _subscription?.cancel();
    super.dispose();
  }
}
