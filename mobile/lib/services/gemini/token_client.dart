import 'dart:developer' as developer;

import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_app_check/firebase_app_check.dart';

import '../network/connectivity_probe.dart';
import 'live_translation_service.dart';

/// Fetches a short-lived Gemini Live API ephemeral token from the
/// `createLiveTranslateToken` Cloud Function. The permanent Gemini API key
/// lives ONLY server-side; the app never sees it.
///
/// The function is deployed with `enforceAppCheck: true`, so a request
/// without a valid App Check token is rejected before our code runs. The
/// App Check token is verified (and logged) here first so an attestation
/// failure surfaces as itself instead of a generic error.
class LiveTranslateTokenClient {
  LiveTranslateTokenClient({
    FirebaseFunctions? functions,
    FirebaseAppCheck? appCheck,
    Future<bool> Function()? isOnline,
  })  : _functions = functions ?? FirebaseFunctions.instance,
        _appCheck = appCheck,
        _isOnline = isOnline ?? hasInternetConnection;

  final FirebaseFunctions _functions;
  final FirebaseAppCheck? _appCheck;
  final Future<bool> Function() _isOnline;

  Future<LiveSessionToken> call(String targetLanguageCode) async {
    await _verifyAppCheckToken();
    try {
      final result = await _functions
          .httpsCallable('createLiveTranslateToken')
          .call<Map<String, dynamic>>({'targetLanguageCode': targetLanguageCode});
      final data = result.data;
      final token = data['token'] as String?;
      final model = data['model'] as String?;
      if (token == null || token.isEmpty || model == null) {
        developer.log('createLiveTranslateToken returned an invalid payload: '
            'token=${token == null ? 'null' : '${token.length} chars'} model=$model',
            name: 'live.token');
        throw const TokenRequestException(
            LiveErrorKind.fatal, 'The translation service returned an invalid token.');
      }
      return LiveSessionToken(
        token: token,
        model: model,
        expireTime:
            DateTime.tryParse(data['expireTime'] as String? ?? '')?.toUtc() ??
                DateTime.now().toUtc().add(const Duration(minutes: 25)),
        // Issued by the server alongside the token — this is the metered
        // session the heartbeats will bill.
        sessionId: data['sessionId'] as String?,
        remainingMinutes: (data['remainingMinutes'] as num?)?.toDouble(),
      );
    } on FirebaseFunctionsException catch (e) {
      developer.log(
        'createLiveTranslateToken failed: code=${e.code} '
        'message=${e.message} details=${e.details}',
        name: 'live.token',
        error: e,
      );
      // The server flags an exhausted ACCOUNT allowance explicitly, so it is
      // never confused with Gemini's own capacity limit.
      final outOfMinutes = e.code == 'resource-exhausted' &&
          e.details is Map &&
          (e.details as Map)['reason'] == 'out-of-minutes';
      throw TokenRequestException(
        switch (e.code) {
          _ when outOfMinutes => LiveErrorKind.outOfMinutes,
          'resource-exhausted' => LiveErrorKind.quota,
          // `unauthenticated` is either a missing Firebase sign-in or an
          // App Check rejection from enforceAppCheck — the log line above
          // carries the server message that tells them apart.
          'unauthenticated' || 'permission-denied' => LiveErrorKind.auth,
          // Transport-level failures are "no internet" only when the device
          // is actually offline; otherwise the outage is on the service side
          // and the real code must be shown.
          'unavailable' || 'deadline-exceeded' =>
            await _isOnline() ? LiveErrorKind.fatal : LiveErrorKind.network,
          // `internal` (server-side failure, e.g. the Gemini token endpoint
          // rejecting the request) and everything else is NOT a connectivity
          // problem — never show "internet required" for it.
          _ => LiveErrorKind.fatal,
        },
        'Could not start a session [${e.code}]: ${e.message ?? 'no message'}',
      );
    } on TokenRequestException {
      rethrow;
    } catch (e, stackTrace) {
      developer.log('createLiveTranslateToken failed unexpectedly: ${e.runtimeType}: $e',
          name: 'live.token', error: e, stackTrace: stackTrace);
      if (!await _isOnline()) {
        throw const TokenRequestException(
            LiveErrorKind.network, 'The device is offline.');
      }
      throw TokenRequestException(
          LiveErrorKind.fatal, 'Could not start a translation session: $e');
    }
  }

  /// Confirms this device can mint an App Check token (App Attest with
  /// DeviceCheck fallback in release builds) BEFORE calling the callable,
  /// and logs the outcome — the callable enforces App Check server-side.
  Future<void> _verifyAppCheckToken() async {
    final appCheck = _appCheck ?? FirebaseAppCheck.instance;
    try {
      final token = await appCheck.getToken();
      if (token == null || token.isEmpty) {
        developer.log(
            'App Check returned an EMPTY token — createLiveTranslateToken '
            'will be rejected (enforceAppCheck).',
            name: 'live.token');
        throw const TokenRequestException(
            LiveErrorKind.fatal,
            'Device attestation failed: no App Check token. '
            'Update or reinstall the app and try again.');
      }
      developer.log('App Check token acquired (${token.length} chars).',
          name: 'live.token');
    } on FirebaseException catch (e) {
      developer.log(
          'App Check getToken failed: plugin=${e.plugin} code=${e.code} '
          'message=${e.message}',
          name: 'live.token',
          error: e);
      throw TokenRequestException(
          LiveErrorKind.fatal,
          'Device attestation failed [${e.code}]: '
          '${e.message ?? 'App Check token unavailable'}');
    }
  }
}
