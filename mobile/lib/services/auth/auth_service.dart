import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

/// User-facing auth failure with a friendly message.
class AuthException implements Exception {
  const AuthException(this.code, this.message);
  final String code;
  final String message;
  @override
  String toString() => message;
}

/// Wraps FirebaseAuth + the social providers behind one clean interface so
/// the rest of the app (and tests) never touch provider SDKs directly.
class AuthService {
  AuthService({FirebaseAuth? auth}) : _auth = auth ?? FirebaseAuth.instance;

  final FirebaseAuth _auth;
  bool _googleInitialized = false;

  /// Android needs the OAuth *web* client ID to obtain a Firebase-compatible
  /// idToken. Pass it at build time:
  ///   --dart-define=GOOGLE_SERVER_CLIENT_ID=xxx.apps.googleusercontent.com
  /// iOS reads its client ID from GoogleService-Info.plist automatically.
  static const String _serverClientId = String.fromEnvironment('GOOGLE_SERVER_CLIENT_ID');

  Stream<User?> authStateChanges() => _auth.authStateChanges();
  User? get currentUser => _auth.currentUser;

  // ── Email / password ────────────────────────────────────────────────────────

  Future<User> signUpWithEmail({
    required String email,
    required String password,
    String? displayName,
  }) async {
    try {
      final credential = await _auth.createUserWithEmailAndPassword(
          email: email.trim(), password: password);
      final user = credential.user!;
      if (displayName != null && displayName.trim().isNotEmpty) {
        await user.updateDisplayName(displayName.trim());
        await user.reload();
      }
      return _auth.currentUser ?? user;
    } on FirebaseAuthException catch (e) {
      throw _friendly(e);
    }
  }

  Future<User> signInWithEmail({required String email, required String password}) async {
    try {
      final credential =
          await _auth.signInWithEmailAndPassword(email: email.trim(), password: password);
      return credential.user!;
    } on FirebaseAuthException catch (e) {
      throw _friendly(e);
    }
  }

  Future<void> sendPasswordResetEmail(String email) async {
    try {
      await _auth.sendPasswordResetEmail(email: email.trim());
    } on FirebaseAuthException catch (e) {
      throw _friendly(e);
    }
  }

  // ── Google ──────────────────────────────────────────────────────────────────

  Future<AuthCredential> _googleCredential() async {
    if (!_googleInitialized) {
      await GoogleSignIn.instance.initialize(
        serverClientId: _serverClientId.isEmpty ? null : _serverClientId,
      );
      _googleInitialized = true;
    }
    final GoogleSignInAccount account;
    try {
      account = await GoogleSignIn.instance.authenticate();
    } on GoogleSignInException catch (e) {
      if (e.code == GoogleSignInExceptionCode.canceled) {
        throw const AuthException('canceled', 'Sign-in was canceled.');
      }
      throw AuthException('google', 'Google Sign-In failed: ${e.description ?? e.code.name}');
    }
    final idToken = account.authentication.idToken;
    if (idToken == null) {
      throw const AuthException('google', 'Google Sign-In did not return a credential.');
    }
    return GoogleAuthProvider.credential(idToken: idToken);
  }

  Future<User> signInWithGoogle() async {
    final credential = await _googleCredential();
    try {
      final result = await _auth.signInWithCredential(credential);
      return result.user!;
    } on FirebaseAuthException catch (e) {
      throw _friendly(e);
    }
  }

  // ── Apple (iOS) ─────────────────────────────────────────────────────────────

  Future<(AuthCredential, String?)> _appleCredential() async {
    final rawNonce = _randomNonce();
    final AuthorizationCredentialAppleID apple;
    try {
      apple = await SignInWithApple.getAppleIDCredential(
        scopes: [AppleIDAuthorizationScopes.email, AppleIDAuthorizationScopes.fullName],
        nonce: sha256.convert(utf8.encode(rawNonce)).toString(),
      );
    } on SignInWithAppleAuthorizationException catch (e) {
      if (e.code == AuthorizationErrorCode.canceled) {
        throw const AuthException('canceled', 'Sign-in was canceled.');
      }
      throw AuthException('apple', 'Sign in with Apple failed: ${e.message}');
    }
    final credential = OAuthProvider('apple.com').credential(
      idToken: apple.identityToken,
      rawNonce: rawNonce,
    );
    final name = [apple.givenName, apple.familyName]
        .where((part) => part != null && part.isNotEmpty)
        .join(' ');
    return (credential, name.isEmpty ? null : name);
  }

  Future<User> signInWithApple() async {
    final (credential, name) = await _appleCredential();
    try {
      final result = await _auth.signInWithCredential(credential);
      final user = result.user!;
      // Apple only shares the name on the FIRST authorization — capture it.
      if (name != null && (user.displayName == null || user.displayName!.isEmpty)) {
        await user.updateDisplayName(name);
        await user.reload();
      }
      return _auth.currentUser ?? user;
    } on FirebaseAuthException catch (e) {
      throw _friendly(e);
    }
  }

  // ── Session ─────────────────────────────────────────────────────────────────

  Future<void> signOut() async {
    if (_googleInitialized) {
      try {
        await GoogleSignIn.instance.signOut();
      } catch (_) {
        // Google session cleanup is best-effort; Firebase sign-out is the gate.
      }
    }
    await _auth.signOut();
  }

  /// Deletes the Firebase account. Throws [AuthException] with code
  /// 'requires-recent-login' when the user must reauthenticate first —
  /// call one of the reauthenticate methods, then retry.
  Future<void> deleteAccount() async {
    final user = _auth.currentUser;
    if (user == null) return;
    try {
      await user.delete();
    } on FirebaseAuthException catch (e) {
      throw _friendly(e);
    }
  }

  Future<void> reauthenticateWithPassword(String password) async {
    final user = _auth.currentUser;
    final email = user?.email;
    if (user == null || email == null) {
      throw const AuthException('no-user', 'No signed-in user.');
    }
    try {
      await user.reauthenticateWithCredential(
          EmailAuthProvider.credential(email: email, password: password));
    } on FirebaseAuthException catch (e) {
      throw _friendly(e);
    }
  }

  Future<void> reauthenticateWithGoogle() async {
    final user = _auth.currentUser;
    if (user == null) throw const AuthException('no-user', 'No signed-in user.');
    try {
      await user.reauthenticateWithCredential(await _googleCredential());
    } on FirebaseAuthException catch (e) {
      throw _friendly(e);
    }
  }

  Future<void> reauthenticateWithApple() async {
    final user = _auth.currentUser;
    if (user == null) throw const AuthException('no-user', 'No signed-in user.');
    final (credential, _) = await _appleCredential();
    try {
      await user.reauthenticateWithCredential(credential);
    } on FirebaseAuthException catch (e) {
      throw _friendly(e);
    }
  }

  // ── Helpers ─────────────────────────────────────────────────────────────────

  static String _randomNonce([int length = 32]) {
    const charset = '0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._';
    final random = Random.secure();
    return List.generate(length, (_) => charset[random.nextInt(charset.length)]).join();
  }

  static AuthException _friendly(FirebaseAuthException e) => AuthException(
        e.code,
        switch (e.code) {
          'invalid-email' => 'That email address looks invalid.',
          'user-disabled' => 'This account has been disabled.',
          'user-not-found' || 'wrong-password' || 'invalid-credential' =>
            'Email or password is incorrect.',
          'email-already-in-use' => 'An account already exists for that email.',
          'weak-password' => 'Please choose a stronger password (at least 6 characters).',
          'too-many-requests' => 'Too many attempts. Please wait a moment and try again.',
          'network-request-failed' => 'Internet connection required. Please try again.',
          'requires-recent-login' =>
            'For security, please sign in again before deleting your account.',
          _ => e.message ?? 'Something went wrong (${e.code}). Please try again.',
        },
      );
}
