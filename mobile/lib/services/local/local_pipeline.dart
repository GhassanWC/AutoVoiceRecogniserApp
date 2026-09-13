import 'dart:async';
import 'dart:developer' as developer;
import 'dart:typed_data';

import 'package:uuid/uuid.dart';

import 'device_stats.dart';
import 'local_speech_engine.dart';
import 'local_translation_engine.dart';

/// Fully on-device utterance pipeline (the experimental engine):
///
///   existing environmental capture + VAD segments (unchanged far-field tuning)
///       ↓ per utterance, PCM16 stays in RAM only
///   local Whisper (multilingual, auto language)
///       ↓ transcript + ISO language
///   local translator (Phase A: passthrough; Phase B: M2M100)
///       ↓
///   the SAME chat-bubble flow the cloud engine uses (same messageId updates)
///
/// No network, no API keys, no backend — and mandatory latency/thermal
/// instrumentation for every utterance.
class LocalPipeline {
  LocalPipeline({
    required this.engine,
    required this.translator,
    required this.targetLanguage,
    required this.onMessageCreated,
    required this.onMessageResolved,
    this.onMessageDiscarded,
    this.diagnosticsLog,
    this.minSpeechMsForLangId = 1500,
    this.mergeGapMs = 1000,
    DeviceStatsService? stats,
    String Function()? messageIdFactory,
  })  : _stats = stats ?? DeviceStatsService(),
        _messageIdFactory = messageIdFactory ?? (() => 'local_${const Uuid().v4()}');

  final LocalSpeechEngine engine;
  final LocalTranslator translator;
  final String targetLanguage;

  /// A pending bubble should appear (utterance just ended, inference running).
  final void Function(String messageId) onMessageCreated;

  /// Inference finished: fill transcript/language/translation into the bubble.
  final void Function(
    String messageId, {
    required String originalText,
    required String sourceLanguage,
    required String translatedText,
    required bool translated,
  }) onMessageResolved;

  /// The utterance should NOT become a bubble (language unidentifiable,
  /// recognizer unavailable, pure silence): remove the pending bubble and
  /// optionally surface [reason] subtly. Null → legacy resolve behavior.
  final void Function(String messageId, String reason)? onMessageDiscarded;

  /// Developer-mode logger (null → dart:developer).
  final void Function(String line)? diagnosticsLog;

  /// Language identification needs speech CONTEXT: a VAD segment shorter
  /// than this is held and merged with speech arriving within [mergeGapMs]
  /// ("Hello" · 300 ms pause · "how are you?" becomes ONE detector
  /// utterance). Long silence flushes whatever is held — unrelated speech
  /// across a long pause is never merged. The 5-second model window itself
  /// is an INPUT FORMAT (native tile-padding handles short speech), not a
  /// requirement that a person talks for five seconds.
  final int minSpeechMsForLangId;
  final int mergeGapMs;

  final DeviceStatsService _stats;
  final String Function() _messageIdFactory;

  final Map<String, BytesBuilder> _segments = {};
  Future<void> _queue = Future<void>.value();

  BytesBuilder? _pending;
  int _pendingDurationMs = 0;
  int _pendingSampleRate = 16000;
  Timer? _mergeTimer;

  void handleSegmentStart(String segmentId, int sampleRate) {
    _segments[segmentId] = BytesBuilder(copy: false);
  }

  void handleAudio(String segmentId, int sequence, Uint8List pcm) {
    _segments[segmentId]?.add(pcm);
  }

  void handleSegmentEnd(String segmentId, int durationMs, int sampleRate) {
    final builder = _segments.remove(segmentId);
    if (builder == null) return;
    if (durationMs == 0) return; // VAD blip — nothing worth a bubble
    final pcm = builder.takeBytes();
    if (pcm.isEmpty) return;

    // Accumulate until there is enough voiced speech for language ID.
    (_pending ??= BytesBuilder(copy: false)).add(pcm);
    _pendingDurationMs += durationMs;
    _pendingSampleRate = sampleRate;
    _mergeTimer?.cancel();
    if (_pendingDurationMs >= minSpeechMsForLangId) {
      _flushPending();
    } else {
      _log('[LOCAL] holding ${_pendingDurationMs}ms of speech for language '
          'ID (min $minSpeechMsForLangId; merge window ${mergeGapMs}ms)');
      _mergeTimer =
          Timer(Duration(milliseconds: mergeGapMs), _flushPending);
    }
  }

  /// Emits the accumulated utterance: the bubble appears now, and inference
  /// runs on the pipeline's serial queue (one utterance at a time).
  void _flushPending() {
    _mergeTimer?.cancel();
    _mergeTimer = null;
    final pending = _pending;
    if (pending == null) return;
    _pending = null;
    final durationMs = _pendingDurationMs;
    _pendingDurationMs = 0;
    final pcm = pending.takeBytes();
    if (pcm.isEmpty) return;
    final sampleRate = _pendingSampleRate;

    final messageId = _messageIdFactory();
    onMessageCreated(messageId);
    _queue = _queue.then((_) => _process(messageId, pcm, durationMs, sampleRate));
  }

  Future<void> _process(
    String messageId,
    Uint8List pcm,
    int durationMs,
    int sampleRate,
  ) async {
    final started = DateTime.now();
    try {
      final transcript = await engine.transcribe(pcm, sampleRate);
      final transcriptMs = DateTime.now().difference(started).inMilliseconds;

      if (transcript.text.isEmpty) {
        // No renderable speech: unidentifiable language, unavailable
        // recognizer, or silence. Never a nonsense bubble.
        final reason = transcript.discardNotice ?? '';
        if (onMessageDiscarded != null) {
          onMessageDiscarded!(messageId, reason);
        } else {
          onMessageResolved(
            messageId,
            originalText: '',
            sourceLanguage: 'und',
            translatedText: '…',
            translated: false,
          );
        }
        _log('[LOCAL] id=$messageId discarded (${transcriptMs}ms)'
            '${reason.isEmpty ? '' : ' reason="$reason"'}');
        return;
      }

      final translateStarted = DateTime.now();
      final translated = await translator.translate(
        text: transcript.text,
        sourceLanguage: transcript.language,
        targetLanguage: targetLanguage,
      );
      final translateMs = DateTime.now().difference(translateStarted).inMilliseconds;
      final totalMs = DateTime.now().difference(started).inMilliseconds;

      onMessageResolved(
        messageId,
        originalText: transcript.text,
        sourceLanguage: transcript.language,
        // Phase A: cross-language pairs surface the source transcript until
        // the local translation model (M2M100) lands in Phase B.
        translatedText: translated ?? transcript.text,
        translated: translated != null,
      );

      final stats = await _stats.read();
      _log('[LOCAL] id=$messageId lang=${transcript.language} '
          'audioMs=$durationMs finalTranscriptMs=$transcriptMs '
          'translateMs=$translateMs speechEndToResultMs=$totalMs '
          '$stats transcript="${transcript.text}"');
    } catch (error) {
      onMessageResolved(
        messageId,
        originalText: '',
        sourceLanguage: 'und',
        translatedText: 'On-device recognition failed',
        translated: false,
      );
      _log('[LOCAL] id=$messageId ERROR $error');
    }
  }

  /// Resolves when all queued utterances finished (Stop Listening). Any
  /// speech still held for merging is flushed first, so nothing is lost.
  Future<void> drain() {
    _flushPending();
    return _queue;
  }

  void _log(String line) {
    if (diagnosticsLog != null) {
      diagnosticsLog!(line);
    } else {
      developer.log(line, name: 'local');
    }
  }
}
