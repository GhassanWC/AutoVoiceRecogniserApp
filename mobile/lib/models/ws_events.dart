import 'dart:convert';
import 'dart:typed_data';

import 'translation_message.dart';

/// Client ⇄ server protocol. Must stay in sync with
/// backend/src/modules/realtime/protocol.ts.

const int kProtocolVersion = 1;
const int kBinaryHeaderBytes = 41;

/// Binary audio frame: [version u8][segmentId 36 ascii][sequence u32 LE][pcm].
Uint8List encodeAudioFrame(String segmentId, int sequence, Uint8List pcm) {
  assert(segmentId.length == 36, 'segmentId must be a uuid v4 string');
  final frame = Uint8List(kBinaryHeaderBytes + pcm.length);
  final view = ByteData.view(frame.buffer);
  view.setUint8(0, kProtocolVersion);
  frame.setRange(1, 37, ascii.encode(segmentId));
  view.setUint32(37, sequence, Endian.little);
  frame.setRange(kBinaryHeaderBytes, frame.length, pcm);
  return frame;
}

sealed class ServerEvent {
  const ServerEvent();

  static ServerEvent? parse(String raw) {
    final dynamic decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      return null;
    }
    if (decoded is! Map<String, dynamic>) return null;
    final json = decoded;
    switch (json['type']) {
      case 'session_started':
        return SessionStartedEvent(
          sessionId: json['sessionId'] as String? ?? '',
          targetLanguage: json['targetLanguage'] as String? ?? 'en',
        );
      case 'status':
        return StatusEvent(
          segmentId: json['segmentId'] as String? ?? '',
          state: json['state'] as String? ?? '',
        );
      case 'partial_transcription':
        return PartialTranscriptionEvent(
          segmentId: json['segmentId'] as String? ?? '',
          speakerId: json['speakerId'] as String?,
          language: json['language'] as String?,
          text: json['text'] as String? ?? '',
        );
      case 'translation':
        return TranslationEvent(
          TranslationMessage(
            id: json['id'] as String? ?? '',
            speakerId: json['speakerId'] as String?,
            speakerLabel: json['speakerLabel'] as String?,
            sourceLanguage: json['sourceLanguage'] as String? ?? 'und',
            languageConfidence: (json['languageConfidence'] as num?)?.toDouble() ?? 0,
            transcriptionConfidence: (json['transcriptionConfidence'] as num?)?.toDouble() ?? 0,
            originalText: json['originalText'] as String? ?? '',
            translatedText: json['translatedText'] as String? ?? '',
            targetLanguage: json['targetLanguage'] as String? ?? 'en',
            timestamp:
                DateTime.tryParse(json['timestamp'] as String? ?? '')?.toLocal() ?? DateTime.now(),
            diagnostics: json['diagnostics'] is Map<String, dynamic>
                ? json['diagnostics'] as Map<String, dynamic>
                : null,
          ),
        );
      case 'transcript_final':
        return TranscriptFinalEvent(
          TranslationMessage(
            id: json['messageId'] as String? ?? '',
            speakerId: json['speakerId'] as String?,
            speakerLabel: json['speakerLabel'] as String?,
            sourceLanguage: json['sourceLanguage'] as String? ?? 'und',
            languageConfidence: (json['languageConfidence'] as num?)?.toDouble() ?? 0,
            transcriptionConfidence: (json['transcriptionConfidence'] as num?)?.toDouble() ?? 0,
            originalText: json['originalText'] as String? ?? '',
            translatedText: '',
            targetLanguage: json['targetLanguage'] as String? ?? 'en',
            timestamp:
                DateTime.tryParse(json['timestamp'] as String? ?? '')?.toLocal() ?? DateTime.now(),
            status: TranslationStatus.pending,
            diagnostics: json['diagnostics'] is Map<String, dynamic>
                ? json['diagnostics'] as Map<String, dynamic>
                : null,
          ),
        );
      case 'translation_delta':
        return TranslationDeltaEvent(
          messageId: json['messageId'] as String? ?? '',
          delta: json['delta'] as String? ?? '',
          reset: json['reset'] as bool? ?? false,
        );
      case 'translation_complete':
        return TranslationCompleteEvent(
          messageId: json['messageId'] as String? ?? '',
          translatedText: json['translatedText'] as String? ?? '',
          sourceLanguage: json['sourceLanguage'] as String?,
          originalText: json['originalText'] as String?,
          latency: json['latency'] is Map<String, dynamic>
              ? json['latency'] as Map<String, dynamic>
              : null,
        );
      case 'translation_failed':
        return TranslationFailedEvent(
          messageId: json['messageId'] as String? ?? '',
          reason: json['reason'] as String?,
          status: json['status'] as int?,
        );
      case 'segment_dropped':
        return SegmentDroppedEvent(
          segmentId: json['segmentId'] as String? ?? '',
          reason: json['reason'] as String? ?? '',
        );
      case 'limit_reached':
        return LimitReachedEvent(json['message'] as String? ?? '');
      case 'error':
        return ServerErrorEvent(
          code: json['code'] as String? ?? 'unknown',
          message: json['message'] as String? ?? '',
          recoverable: json['recoverable'] as bool? ?? true,
        );
      case 'session_ended':
        return SessionEndedEvent(
          sessionId: json['sessionId'] as String? ?? '',
          translationCount: json['translationCount'] as int? ?? 0,
          durationSeconds: json['durationSeconds'] as int? ?? 0,
        );
      case 'pong':
        return const PongEvent();
      default:
        return null;
    }
  }
}

class SessionStartedEvent extends ServerEvent {
  const SessionStartedEvent({required this.sessionId, required this.targetLanguage});
  final String sessionId;
  final String targetLanguage;
}

class StatusEvent extends ServerEvent {
  const StatusEvent({required this.segmentId, required this.state});
  final String segmentId;

  /// hearing | transcribing | translating
  final String state;
}

class PartialTranscriptionEvent extends ServerEvent {
  const PartialTranscriptionEvent({
    required this.segmentId,
    required this.speakerId,
    required this.language,
    required this.text,
  });
  final String segmentId;
  final String? speakerId;
  final String? language;
  final String text;
}

class TranslationEvent extends ServerEvent {
  const TranslationEvent(this.message);
  final TranslationMessage message;
}

/// A finalized transcript, shown immediately with "Translating…" — the
/// translation arrives (or fails) later for the same message id.
class TranscriptFinalEvent extends ServerEvent {
  const TranscriptFinalEvent(this.message);
  final TranslationMessage message;
}

/// A streamed chunk of translated text — append to the SAME bubble (or
/// replace its partial text when [reset] is true after a server-side retry).
class TranslationDeltaEvent extends ServerEvent {
  const TranslationDeltaEvent({
    required this.messageId,
    required this.delta,
    required this.reset,
  });
  final String messageId;
  final String delta;
  final bool reset;
}

class TranslationCompleteEvent extends ServerEvent {
  const TranslationCompleteEvent({
    required this.messageId,
    required this.translatedText,
    this.sourceLanguage,
    this.originalText,
    this.latency,
  });
  final String messageId;
  final String translatedText;

  /// Authoritative language, detected by the translator from the actual text.
  final String? sourceLanguage;

  /// Source transcript delivered at finalization (realtime-translate path).
  final String? originalText;

  /// {speechEndToFirstDeltaMs, speechEndToFinalMs} — developer diagnostics.
  final Map<String, dynamic>? latency;
}

class TranslationFailedEvent extends ServerEvent {
  const TranslationFailedEvent({required this.messageId, this.reason, this.status});
  final String messageId;

  /// Real provider failure detail, for developer diagnostics.
  final String? reason;
  final int? status;
}

class SegmentDroppedEvent extends ServerEvent {
  const SegmentDroppedEvent({required this.segmentId, required this.reason});
  final String segmentId;
  final String reason;
}

class LimitReachedEvent extends ServerEvent {
  const LimitReachedEvent(this.message);
  final String message;
}

class ServerErrorEvent extends ServerEvent {
  const ServerErrorEvent({required this.code, required this.message, required this.recoverable});
  final String code;
  final String message;
  final bool recoverable;
}

class SessionEndedEvent extends ServerEvent {
  const SessionEndedEvent({
    required this.sessionId,
    required this.translationCount,
    required this.durationSeconds,
  });
  final String sessionId;
  final int translationCount;
  final int durationSeconds;
}

class PongEvent extends ServerEvent {
  const PongEvent();
}
