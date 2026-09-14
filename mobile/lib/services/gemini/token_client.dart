import 'package:cloud_functions/cloud_functions.dart';

import 'live_translation_service.dart';

/// Fetches a short-lived Gemini Live API ephemeral token from the
/// `createLiveTranslateToken` Cloud Function. The permanent Gemini API key
/// lives ONLY server-side; the app never sees it.
class LiveTranslateTokenClient {
  LiveTranslateTokenClient({FirebaseFunctions? functions})
      : _functions = functions ?? FirebaseFunctions.instance;

  final FirebaseFunctions _functions;

  Future<LiveSessionToken> call(String targetLanguageCode) async {
    try {
      final result = await _functions
          .httpsCallable('createLiveTranslateToken')
          .call<Map<String, dynamic>>({'targetLanguageCode': targetLanguageCode});
      final data = result.data;
      final token = data['token'] as String?;
      final model = data['model'] as String?;
      if (token == null || token.isEmpty || model == null) {
        throw const TokenRequestException(
            LiveErrorKind.fatal, 'The translation service returned an invalid token.');
      }
      return LiveSessionToken(
        token: token,
        model: model,
        expireTime:
            DateTime.tryParse(data['expireTime'] as String? ?? '')?.toUtc() ??
                DateTime.now().toUtc().add(const Duration(minutes: 25)),
      );
    } on FirebaseFunctionsException catch (e) {
      throw TokenRequestException(switch (e.code) {
        'resource-exhausted' => LiveErrorKind.quota,
        'unauthenticated' || 'permission-denied' => LiveErrorKind.auth,
        'unavailable' || 'deadline-exceeded' || 'internal' => LiveErrorKind.network,
        _ => LiveErrorKind.fatal,
      }, e.message ?? e.code);
    } on TokenRequestException {
      rethrow;
    } catch (e) {
      throw TokenRequestException(LiveErrorKind.network, '$e');
    }
  }
}
