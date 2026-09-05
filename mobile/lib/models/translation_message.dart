/// Lifecycle of one utterance's translation. The transcript itself is always
/// present and displayed — translation catches up (or fails) afterwards.
enum TranslationStatus { pending, done, failed }

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
    this.transcriptionConfidence = 0,
    this.status = TranslationStatus.done,
    this.diagnostics,
  });

  final String id;
  final String? speakerId;

  /// "Speaker 1"…; null → UI shows the generic "Speaker".
  final String? speakerLabel;
  final String sourceLanguage;
  final double languageConfidence;

  /// 0..1 provider confidence in the transcript itself (0 when unknown).
  final double transcriptionConfidence;
  final String originalText;

  /// Empty while [status] is pending/failed.
  final String translatedText;
  final String targetLanguage;
  final DateTime timestamp;
  final TranslationStatus status;

  /// Server-side per-utterance detail (STT provider, latency, …). Only logged
  /// in developer mode; deliberately not persisted to history.
  final Map<String, dynamic>? diagnostics;

  TranslationMessage copyWith({
    String? translatedText,
    TranslationStatus? status,
    String? sourceLanguage,
    double? languageConfidence,
    String? originalText,
  }) {
    return TranslationMessage(
      id: id,
      speakerId: speakerId,
      speakerLabel: speakerLabel,
      sourceLanguage: sourceLanguage ?? this.sourceLanguage,
      languageConfidence: languageConfidence ?? this.languageConfidence,
      transcriptionConfidence: transcriptionConfidence,
      originalText: originalText ?? this.originalText,
      translatedText: translatedText ?? this.translatedText,
      targetLanguage: targetLanguage,
      timestamp: timestamp,
      status: status ?? this.status,
      diagnostics: diagnostics,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'speakerId': speakerId,
        'speakerLabel': speakerLabel,
        'sourceLanguage': sourceLanguage,
        'languageConfidence': languageConfidence,
        'transcriptionConfidence': transcriptionConfidence,
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
        transcriptionConfidence: (json['transcriptionConfidence'] as num?)?.toDouble() ?? 0,
        originalText: json['originalText'] as String? ?? '',
        translatedText: json['translatedText'] as String? ?? '',
        targetLanguage: json['targetLanguage'] as String? ?? 'en',
        timestamp: DateTime.tryParse(json['timestamp'] as String? ?? '') ?? DateTime.now(),
      );
}
