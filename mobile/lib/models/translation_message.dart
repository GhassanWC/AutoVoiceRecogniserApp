class TranslationMessage {
  const TranslationMessage({
    required this.id,
    required this.speakerId,
    required this.speakerLabel,
    required this.sourceLanguage,
    required this.languageConfidence,
    required this.originalText,
    required this.translatedText,
    required this.targetLanguage,
    required this.timestamp,
  });

  final String id;
  final String? speakerId;

  /// "Speaker 1"…; null → UI shows the generic "Speaker".
  final String? speakerLabel;
  final String sourceLanguage;
  final double languageConfidence;
  final String originalText;
  final String translatedText;
  final String targetLanguage;
  final DateTime timestamp;

  Map<String, dynamic> toJson() => {
        'id': id,
        'speakerId': speakerId,
        'speakerLabel': speakerLabel,
        'sourceLanguage': sourceLanguage,
        'languageConfidence': languageConfidence,
        'originalText': originalText,
        'translatedText': translatedText,
        'targetLanguage': targetLanguage,
        'timestamp': timestamp.toIso8601String(),
      };

  factory TranslationMessage.fromJson(Map<String, dynamic> json) => TranslationMessage(
        id: json['id'] as String,
        speakerId: json['speakerId'] as String?,
        speakerLabel: json['speakerLabel'] as String?,
        sourceLanguage: json['sourceLanguage'] as String? ?? 'und',
        languageConfidence: (json['languageConfidence'] as num?)?.toDouble() ?? 0,
        originalText: json['originalText'] as String? ?? '',
        translatedText: json['translatedText'] as String? ?? '',
        targetLanguage: json['targetLanguage'] as String? ?? 'en',
        timestamp: DateTime.tryParse(json['timestamp'] as String? ?? '') ?? DateTime.now(),
      );
}
