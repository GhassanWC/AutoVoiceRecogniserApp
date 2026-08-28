import 'translation_message.dart';

/// A saved listening session (only stored when the user enables history).
class ConversationSession {
  const ConversationSession({
    required this.id,
    required this.targetLanguage,
    required this.startedAt,
    required this.endedAt,
    required this.messages,
  });

  final String id;
  final String targetLanguage;
  final DateTime startedAt;
  final DateTime? endedAt;
  final List<TranslationMessage> messages;

  Map<String, dynamic> toJson() => {
        'id': id,
        'targetLanguage': targetLanguage,
        'startedAt': startedAt.toIso8601String(),
        'endedAt': endedAt?.toIso8601String(),
        'messages': messages.map((m) => m.toJson()).toList(),
      };

  factory ConversationSession.fromJson(Map<String, dynamic> json) => ConversationSession(
        id: json['id'] as String,
        targetLanguage: json['targetLanguage'] as String? ?? 'en',
        startedAt: DateTime.tryParse(json['startedAt'] as String? ?? '') ?? DateTime.now(),
        endedAt: json['endedAt'] == null ? null : DateTime.tryParse(json['endedAt'] as String),
        messages: (json['messages'] as List<dynamic>? ?? [])
            .map((m) => TranslationMessage.fromJson(m as Map<String, dynamic>))
            .toList(),
      );
}
