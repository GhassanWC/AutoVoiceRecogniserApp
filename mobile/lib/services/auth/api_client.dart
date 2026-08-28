import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// Small REST client: guest authentication and history endpoints.
/// Provider API keys live on the backend only — the app never sees them.
class ApiClient {
  ApiClient({this.serverUrlOverride = ''});

  /// From Settings → Developer; empty means platform default.
  String serverUrlOverride;

  static const _tokenKey = 'auth.guestToken';

  String get baseUrl {
    if (serverUrlOverride.trim().isNotEmpty) {
      return serverUrlOverride.trim().replaceAll(RegExp(r'/+$'), '');
    }
    if (kIsWeb) return 'http://localhost:8080';
    // Android emulator reaches the host machine via 10.0.2.2.
    try {
      if (Platform.isAndroid) return 'http://10.0.2.2:8080';
    } catch (_) {
      // Platform is unavailable in some test contexts.
    }
    return 'http://localhost:8080';
  }

  String get webSocketUrl =>
      '${baseUrl.replaceFirst('https', 'wss').replaceFirst('http', 'ws')}/live-translation';

  /// Returns a cached guest token, creating one on first use ("Try without
  /// account" — no registration wall before the core experience).
  Future<String> getAuthToken({required String preferredLanguage}) async {
    final prefs = await SharedPreferences.getInstance();
    final cached = prefs.getString(_tokenKey);
    if (cached != null && cached.isNotEmpty) return cached;

    final response = await http
        .post(
          Uri.parse('$baseUrl/auth/guest'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'preferredLanguage': preferredLanguage}),
        )
        .timeout(const Duration(seconds: 10));
    if (response.statusCode != 200) {
      throw ApiException('Could not reach the translation service (${response.statusCode}).');
    }
    final token = (jsonDecode(response.body) as Map<String, dynamic>)['token'] as String?;
    if (token == null || token.isEmpty) {
      throw ApiException('The translation service returned an invalid response.');
    }
    await prefs.setString(_tokenKey, token);
    return token;
  }

  /// Drops the cached token (e.g. after a 401/4401) so the next call
  /// re-registers a fresh guest.
  Future<void> clearAuthToken() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_tokenKey);
  }
}

class ApiException implements Exception {
  ApiException(this.message);
  final String message;

  @override
  String toString() => message;
}
