import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../models/conversation_session.dart';

/// Local translation history. Only ever written when the user has enabled
/// "Save translation history" (off by default). Text only — never audio.
class HistoryStore {
  static const _indexKey = 'history.sessions.v1';
  static const _maxSessions = 100;

  Future<List<ConversationSession>> loadSessions() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_indexKey);
      if (raw == null) return [];
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .map((item) => ConversationSession.fromJson(item as Map<String, dynamic>))
          .toList()
        ..sort((a, b) => b.startedAt.compareTo(a.startedAt));
    } catch (_) {
      return [];
    }
  }

  Future<void> saveSession(ConversationSession session) async {
    if (session.messages.isEmpty) return;
    final sessions = await loadSessions();
    sessions.removeWhere((s) => s.id == session.id);
    sessions.insert(0, session);
    while (sessions.length > _maxSessions) {
      sessions.removeLast();
    }
    await _persist(sessions);
  }

  Future<void> deleteSession(String id) async {
    final sessions = await loadSessions();
    sessions.removeWhere((s) => s.id == id);
    await _persist(sessions);
  }

  Future<void> deleteAll() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_indexKey);
  }

  Future<void> _persist(List<ConversationSession> sessions) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_indexKey, jsonEncode(sessions.map((s) => s.toJson()).toList()));
  }
}
