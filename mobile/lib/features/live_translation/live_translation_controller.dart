import 'dart:async';
import 'dart:developer' as developer;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../../models/conversation_session.dart';
import '../../models/translation_message.dart';
import '../../models/ws_events.dart';
import '../../services/audio/audio_capture_service.dart';
import '../../services/audio/vad_segmenter.dart';
import '../../services/auth/api_client.dart';
import '../../services/mock/mock_conversation_service.dart';
import '../../services/permissions/mic_permission_service.dart';
import '../../services/storage/history_store.dart';
import '../../services/storage/settings_store.dart';
import '../../services/tts/tts_service.dart';
import '../../services/websocket/live_translation_client.dart';

/// The three microphone states the UI must always reflect truthfully.
enum ListeningState { idle, starting, listening }

class SessionSummary {
  const SessionSummary({required this.translationCount, required this.duration});
  final int translationCount;
  final Duration duration;
}

/// Orchestrates the whole listening session:
///
///   mic permission → native capture → VAD segmentation → WebSocket streaming
///   → server results → message list (+ optional history & TTS).
///
/// Invariant it protects: the UI state always matches the real microphone
/// state, and the microphone is only ever started by an explicit user action.
class LiveTranslationController extends ChangeNotifier with WidgetsBindingObserver {
  LiveTranslationController({
    required this.settings,
    MicPermissionService? permissions,
    AudioCaptureService? audioCapture,
    LiveTranslationClient? client,
    HistoryStore? history,
    TtsService? tts,
    MockConversationService? mock,
  })  : permissions = permissions ?? MicPermissionService(),
        audioCapture = audioCapture ?? AudioCaptureService(),
        history = history ?? HistoryStore(),
        tts = tts ?? TtsService(),
        mock = mock ?? MockConversationService() {
    _api = ApiClient(serverUrlOverride: settings.settings.serverUrl);
    this.client = client ?? LiveTranslationClient(api: _api);
    _eventSubscription = this.client.events.listen(_handleServerEvent);
    _connectionSubscription = this.client.connectionStates.listen(_handleConnectionState);
    WidgetsBinding.instance.addObserver(this);
  }

  final SettingsController settings;
  final MicPermissionService permissions;
  final AudioCaptureService audioCapture;
  final HistoryStore history;
  final TtsService tts;
  final MockConversationService mock;
  late final LiveTranslationClient client;
  late final ApiClient _api;

  // ── Observable state ────────────────────────────────────────────────────────

  ListeningState state = ListeningState.idle;
  LiveConnectionState connectionState = LiveConnectionState.disconnected;

  /// Whole on-screen conversation (survives stop; cleared by the user).
  final List<TranslationMessage> messages = [];

  /// "Hearing speech…" / "Translating…" while a segment is in flight.
  String? activityLabel;

  /// 0..1 microphone level for the waveform animation.
  double micLevel = 0;

  /// Persistent problem shown as a banner (null = none).
  String? errorBanner;

  bool permissionPermanentlyDenied = false;

  /// Set when a session just ended, so the UI can show the summary sheet.
  SessionSummary? lastSummary;

  final StreamController<String> _notices = StreamController.broadcast();

  /// One-off user notices (snackbars).
  Stream<String> get notices => _notices.stream;

  bool get isListening => state == ListeningState.listening;

  // ── Session internals ───────────────────────────────────────────────────────

  VadSegmenter? _vad;
  DateTime? _sessionStartedAt;

  /// Bandwidth guard: upload pauses only after this much ABSOLUTE silence
  /// (empty room), and the very chunk that breaks the silence is audible and
  /// therefore uploaded — audible speech is never withheld.
  static const Duration _silencePauseAfter = Duration(seconds: 30);
  static const double _audibleRms = 0.002;
  DateTime _lastAudibleAt = DateTime.now();
  final List<TranslationMessage> _sessionMessages = [];
  String _sessionId = '';
  bool _usingMock = false;
  StreamSubscription<ServerEvent>? _eventSubscription;
  StreamSubscription<LiveConnectionState>? _connectionSubscription;
  DateTime _lastLevelNotify = DateTime.fromMillisecondsSinceEpoch(0);

  // ── Start / stop ────────────────────────────────────────────────────────────

  Future<void> startListening() async {
    if (state != ListeningState.idle) return;
    errorBanner = null;
    permissionPermanentlyDenied = false;
    lastSummary = null;
    _sessionMessages.clear();
    _sessionId = const Uuid().v4();
    _usingMock = settings.settings.mockMode;
    state = ListeningState.starting;
    notifyListeners();

    if (_usingMock) {
      _startMock();
      return;
    }

    // 1. OS microphone permission (separate from the listening session:
    //    granting it never starts listening by itself).
    var permission = await permissions.currentStatus();
    if (permission == MicPermissionStatus.denied) {
      permission = await permissions.request();
    }
    switch (permission) {
      case MicPermissionStatus.granted:
        break;
      case MicPermissionStatus.permanentlyDenied:
        permissionPermanentlyDenied = true;
        _failStart('Microphone access is disabled.');
        return;
      case MicPermissionStatus.denied:
        _failStart('Microphone permission is required for live translation.');
        return;
      case MicPermissionStatus.unsupported:
        _failStart('Microphone capture is not available here. Try Demo Mode in Settings.');
        return;
    }

    // 2. Connect and open the server session.
    _api.serverUrlOverride = settings.settings.serverUrl;
    final connected = _waitForConnection(const Duration(seconds: 12));
    await client.connect(
      targetLanguage: settings.settings.targetLanguage,
      saveHistory: false, // server-side history off in V1; history is local-only
    );
    if (!await connected) {
      await client.disconnect();
      _failStart('Could not connect to the translation service. '
          'Check your internet connection (or enable Demo Mode in Settings).');
      return;
    }

    // 3. Live-subtitle mode: ALL microphone audio streams continuously to the
    //    backend, whose speech provider detects utterances. The local VAD
    //    stays only for the waveform, developer diagnostics and a prolonged-
    //    absolute-silence bandwidth pause — it never again decides whether
    //    distant/quiet room speech is "worth" uploading.
    _lastAudibleAt = DateTime.now();
    _vad = VadSegmenter(
      sampleRate: AudioCaptureService.sampleRate,
      onSegmentStart: (_, __) {},
      onAudio: (_, __, ___) {},
      onSegmentEnd: (_, __) {},
      onLevel: _handleLevel,
      onDiagnostics: _handleVadDiagnostics,
    );
    client.startAudioStream(AudioCaptureService.sampleRate);

    // 4. Native microphone capture (starts the Android foreground service).
    try {
      await audioCapture.start(
        onAudio: _handleCapturedAudio,
        onStopped: _handleCaptureStopped,
      );
    } on AudioCaptureUnsupportedException {
      await client.disconnect();
      _failStart('Microphone capture is not available on this platform. '
          'Run on Android/iOS, or enable Demo Mode in Settings.');
      return;
    } catch (_) {
      await client.disconnect();
      _failStart('Could not start the microphone. '
          'It may be in use by another app.');
      return;
    }

    _sessionStartedAt = DateTime.now();
    state = ListeningState.listening;
    notifyListeners();
  }

  Future<void> stopListening() async {
    if (state == ListeningState.idle) return;
    final startedAt = _sessionStartedAt;

    if (_usingMock) {
      mock.stop();
    } else {
      // Order matters: capture stops first so not a single extra sample is
      // recorded — or streamed — after the user pressed Stop.
      await audioCapture.stop();
      client.stopAudioStream();
      _vad = null;
      client.sendSessionStop();
      // Give in-flight segments a moment to come back before closing.
      await Future<void>.delayed(const Duration(milliseconds: 800));
      await client.disconnect();
    }

    state = ListeningState.idle;
    activityLabel = null;
    micLevel = 0;
    lastSummary = SessionSummary(
      translationCount: _sessionMessages.length,
      duration: startedAt == null ? Duration.zero : DateTime.now().difference(startedAt),
    );

    if (settings.settings.saveHistory && _sessionMessages.isNotEmpty) {
      await history.saveSession(
        ConversationSession(
          id: _sessionId,
          targetLanguage: settings.settings.targetLanguage,
          startedAt: startedAt ?? DateTime.now(),
          endedAt: DateTime.now(),
          messages: List.of(_sessionMessages),
        ),
      );
    }
    _sessionStartedAt = null;
    notifyListeners();
  }

  void _startMock() {
    mock.start(
      targetLanguage: settings.settings.targetLanguage,
      onStatus: (mockState) {
        activityLabel = mockState == 'hearing' ? 'Hearing speech…' : 'Translating…';
        notifyListeners();
      },
      onMessage: (message) {
        activityLabel = null;
        _addMessage(message);
      },
    );
    _sessionStartedAt = DateTime.now();
    state = ListeningState.listening;
    notifyListeners();
  }

  void _failStart(String message) {
    state = ListeningState.idle;
    errorBanner = message;
    notifyListeners();
  }

  Future<bool> _waitForConnection(Duration timeout) async {
    try {
      await client.connectionStates
          .firstWhere((s) => s == LiveConnectionState.connected)
          .timeout(timeout);
      return true;
    } on TimeoutException {
      return false;
    }
  }

  // ── Event handling ──────────────────────────────────────────────────────────

  void _handleServerEvent(ServerEvent event) {
    switch (event) {
      case StatusEvent(:final state):
        activityLabel = switch (state) {
          'hearing' => 'Hearing speech…',
          'transcribing' => 'Transcribing…',
          'translating' => 'Translating…',
          _ => activityLabel,
        };
        notifyListeners();
      case TranslationEvent(:final message):
        activityLabel = null;
        _addMessage(message);
      case TranscriptFinalEvent(:final message):
        activityLabel = null;
        _addTranscript(message);
      case TranslationStartedEvent(
          :final messageId,
          :final speakerId,
          :final speakerLabel,
          :final sourceLanguage,
          :final targetLanguage,
          :final timestamp
        ):
        // Direct realtime-translate path: bubble exists BEFORE any delta.
        _logStage('[6] FLUTTER_RECEIVED translation_started id=$messageId');
        activityLabel = null;
        _ensureMessage(
          messageId,
          speakerId: speakerId,
          speakerLabel: speakerLabel,
          sourceLanguage: sourceLanguage,
          targetLanguage: targetLanguage,
          timestamp: timestamp,
        );
        notifyListeners();
      case TranslationDeltaEvent(:final messageId, :final delta, :final reset):
        _logStage('[7] FLUTTER_RECEIVED translation_delta id=$messageId delta="$delta"');
        // Streamed translation: grow the SAME bubble word by word. Defensive:
        // an unknown messageId (ordering/network race) creates the bubble
        // instead of silently dropping translated text.
        _updateMessage(
          messageId,
          (m) => m.copyWith(translatedText: reset ? delta : m.translatedText + delta),
          createIfMissing: true,
        );
      case TranslationCompleteEvent(
          :final messageId,
          :final translatedText,
          :final sourceLanguage,
          :final originalText,
          :final latency
        ):
        _logStage('[7] FLUTTER_RECEIVED translation_complete id=$messageId');
        if (settings.settings.developerDiagnostics && latency != null) {
          developer.log(
            '[LATENCY] id=$messageId '
            'speechEnd→firstDelta=${latency['speechEndToFirstDeltaMs']}ms '
            'speechEnd→final=${latency['speechEndToFinalMs']}ms',
            name: 'pipeline',
          );
        }
        final languageKnown = sourceLanguage != null && sourceLanguage != 'und';
        _updateMessage(
          messageId,
          (m) => m.copyWith(
            translatedText: translatedText,
            status: TranslationStatus.done,
            // The translator read the actual text — its language verdict
            // replaces the provisional one from the speech provider.
            sourceLanguage: languageKnown ? sourceLanguage : null,
            languageConfidence: languageKnown ? 0.9 : null,
            // Realtime-translate delivers the source transcript only at
            // finalization — fill in the original line then.
            originalText: (originalText != null && originalText.isNotEmpty) ? originalText : null,
          ),
          speak: true,
          createIfMissing: true, // never lose a finished translation to a race
        );
      case LanguageDetectedEvent(:final messageId, :final languageCode):
        // Metadata only: upgrade the existing bubble's language label in
        // place. Unknown codes are ignored — the label simply stays "Speaker".
        if (languageCode.isNotEmpty && languageCode != 'und') {
          _updateMessage(
            messageId,
            (m) => m.copyWith(sourceLanguage: languageCode, languageConfidence: 0.9),
          );
        }
      case TranslationFailedEvent(:final messageId, :final reason, :final status):
        if (settings.settings.developerDiagnostics) {
          developer.log(
            '[PIPELINE] translation FAILED id=$messageId status=$status reason=$reason',
            name: 'pipeline',
          );
        }
        _updateMessage(messageId, (m) => m.copyWith(status: TranslationStatus.failed));
      case SegmentDroppedEvent():
        activityLabel = null;
        notifyListeners();
      case LimitReachedEvent(:final message):
        _notices.add(message.isEmpty ? 'Translation limit reached.' : message);
        stopListening();
      case ServerErrorEvent(:final message, :final recoverable):
        if (recoverable) {
          if (message.isNotEmpty) _notices.add(message);
        } else {
          errorBanner = message;
          stopListening();
        }
      case PartialTranscriptionEvent():
      case SessionStartedEvent():
      case SessionEndedEvent():
      case PongEvent():
        break;
    }
  }

  void _addMessage(TranslationMessage message) {
    messages.add(message);
    _sessionMessages.add(message);
    _logPipeline(message);
    notifyListeners();
    if (settings.settings.autoSpeak) {
      tts.speak(message.translatedText, message.targetLanguage);
    }
  }

  /// Transcript arrived before its translation: display it immediately with a
  /// "Translating…" placeholder. Reconnect-duplicates (same id) are ignored.
  void _addTranscript(TranslationMessage message) {
    if (message.id.isEmpty || messages.any((m) => m.id == message.id)) return;
    messages.add(message);
    _sessionMessages.add(message);
    _logStage('[8] CHAT_MESSAGE_CREATED id=${message.id} (transcript_final)');
    _logPipeline(message);
    notifyListeners();
  }

  /// Numbered live-trace stages for developer diagnostics.
  void _logStage(String stage) {
    if (!settings.settings.developerDiagnostics) return;
    developer.log(stage, name: 'trace');
  }

  /// Creates the in-progress bubble for [messageId] if it does not exist yet
  /// (translation_started, or a delta/complete that arrived first). Returns
  /// the message index, or -1 for an empty id.
  int _ensureMessage(
    String messageId, {
    String? speakerId,
    String? speakerLabel,
    String sourceLanguage = 'und',
    String? targetLanguage,
    DateTime? timestamp,
  }) {
    if (messageId.isEmpty) return -1;
    final existing = messages.indexWhere((m) => m.id == messageId);
    if (existing >= 0) return existing;
    final message = TranslationMessage(
      id: messageId,
      speakerId: speakerId,
      speakerLabel: speakerLabel,
      sourceLanguage: sourceLanguage,
      languageConfidence: 0,
      originalText: '',
      translatedText: '',
      targetLanguage: targetLanguage ?? settings.settings.targetLanguage,
      timestamp: timestamp ?? DateTime.now(),
      status: TranslationStatus.pending,
    );
    messages.add(message);
    _sessionMessages.add(message);
    _logStage('[8] CHAT_MESSAGE_CREATED id=$messageId');
    return messages.length - 1;
  }

  /// Updates the message in place — never creates a second bubble for the
  /// same id. With [createIfMissing], an unknown id gets a bubble first
  /// (defense against event ordering/network races) instead of being dropped.
  void _updateMessage(
    String messageId,
    TranslationMessage Function(TranslationMessage) change, {
    bool speak = false,
    bool createIfMissing = false,
  }) {
    var index = messages.indexWhere((m) => m.id == messageId);
    if (index < 0 && createIfMissing) index = _ensureMessage(messageId);
    if (index < 0) return;
    final alreadyDone = messages[index].status == TranslationStatus.done;
    final updated = change(messages[index]);
    messages[index] = updated;
    final sessionIndex = _sessionMessages.indexWhere((m) => m.id == messageId);
    if (sessionIndex >= 0) _sessionMessages[sessionIndex] = updated;
    _logStage(
      '[8] CHAT_MESSAGE_UPDATED id=$messageId status=${updated.status.name} '
      'translated="${updated.translatedText}"',
    );
    notifyListeners();
    // Speak once per message, even if a retry delivers the result twice.
    if (speak && !alreadyDone && settings.settings.autoSpeak) {
      tts.speak(updated.translatedText, updated.targetLanguage);
    }
  }

  /// User pressed Retry on a failed translation: same text, no new audio.
  void retryTranslation(TranslationMessage message) {
    if (message.status != TranslationStatus.failed) return;
    _updateMessage(message.id, (m) => m.copyWith(status: TranslationStatus.pending));
    client.sendRetryTranslation(message.id);
  }

  void _logPipeline(TranslationMessage message) {
    if (!settings.settings.developerDiagnostics) return;
    developer.log(
      '[PIPELINE] id=${message.id} provider=${message.diagnostics?['sttProvider']} '
      'transcript="${message.originalText}" '
      'language=${message.sourceLanguage} '
      '(detected=${message.diagnostics?['detectedLanguage']}, '
      'confidence=${message.languageConfidence.toStringAsFixed(2)}) '
      'sttConfidence=${message.transcriptionConfidence.toStringAsFixed(2)} '
      'speaker=${message.speakerId} '
      'status=${message.status.name} '
      'translated="${message.translatedText}" '
      'audioMs=${message.diagnostics?['audioMs']}',
      name: 'pipeline',
    );
  }

  void _handleConnectionState(LiveConnectionState next) {
    final previous = connectionState;
    connectionState = next;
    if (state == ListeningState.listening) {
      if (next == LiveConnectionState.reconnecting) {
        errorBanner = 'Connection lost. Trying to reconnect…';
      } else if (next == LiveConnectionState.connected &&
          previous == LiveConnectionState.reconnecting) {
        errorBanner = null;
        _notices.add('Connected');
      }
    }
    notifyListeners();
  }

  /// Every captured chunk: level/diagnostics first (updates the audibility
  /// clock), then continuous upload — held back only during prolonged
  /// absolute silence.
  DateTime _lastStage1Log = DateTime.fromMillisecondsSinceEpoch(0);

  void _handleCapturedAudio(Uint8List pcm) {
    _vad?.addAudio(pcm);
    if (DateTime.now().difference(_lastAudibleAt) < _silencePauseAfter) {
      client.sendStreamAudio(pcm);
      final now = DateTime.now();
      if (now.difference(_lastStage1Log).inMilliseconds >= 1000) {
        _lastStage1Log = now;
        _logStage('[1] MOBILE_AUDIO_SENT (${pcm.length} bytes/chunk, connected=${client.isConnected})');
      }
    }
  }

  DateTime _lastVadLog = DateTime.fromMillisecondsSinceEpoch(0);

  /// Tracks audibility for the silence pause; in developer mode also logs VAD
  /// internals (segment events always, level lines throttled to 1/s).
  void _handleVadDiagnostics(VadDiagnostics d) {
    if (d.rms >= _audibleRms) _lastAudibleAt = DateTime.now();
    if (!settings.settings.developerDiagnostics) return;
    if (d.event != null) {
      developer.log('[VAD] $d', name: 'vad');
      return;
    }
    final now = DateTime.now();
    if (now.difference(_lastVadLog).inMilliseconds >= 1000) {
      _lastVadLog = now;
      developer.log('[VAD] $d streaming=${now.difference(_lastAudibleAt) < _silencePauseAfter}',
          name: 'vad');
    }
  }

  void _handleLevel(double level, bool isSpeech) {
    micLevel = level;
    // Throttle UI updates to ~8 fps; the waveform does not need more.
    final now = DateTime.now();
    if (now.difference(_lastLevelNotify).inMilliseconds > 120) {
      _lastLevelNotify = now;
      notifyListeners();
    }
  }

  void _handleCaptureStopped(String reason) {
    if (state != ListeningState.listening) return;
    if (reason == 'notification') {
      // The user pressed Stop on the Android notification.
      stopListening();
    } else {
      stopListening();
      errorBanner = 'Listening stopped: the microphone became unavailable.';
      notifyListeners();
    }
  }

  // ── User actions on messages ────────────────────────────────────────────────

  void clearConversation() {
    messages.clear();
    _sessionMessages.clear();
    lastSummary = null;
    notifyListeners();
  }

  Future<void> replay(TranslationMessage message) =>
      tts.speak(message.translatedText, message.targetLanguage);

  void reportBadTranslation(TranslationMessage message) {
    // V1: acknowledge locally. Phase 2 sends the report to the backend.
    _notices.add('Thanks — your report helps improve translations.');
  }

  void consumeSummary() {
    lastSummary = null;
  }

  Future<void> openSystemSettings() => permissions.openSystemSettings();

  // ── Lifecycle ───────────────────────────────────────────────────────────────

  @override
  // ignore: avoid_renaming_method_parameters — `state` is taken by our own field.
  void didChangeAppLifecycleState(AppLifecycleState lifecycle) {
    if (lifecycle == AppLifecycleState.resumed &&
        state == ListeningState.listening &&
        !_usingMock &&
        !audioCapture.isCapturing) {
      // The OS ended our background session while we were away — make the UI
      // tell the truth instead of showing a dead "Listening" state.
      state = ListeningState.idle;
      activityLabel = null;
      errorBanner = 'Listening was stopped while the app was in the background.';
      client.disconnect();
      notifyListeners();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    mock.stop();
    audioCapture.stop();
    _eventSubscription?.cancel();
    _connectionSubscription?.cancel();
    client.dispose();
    _notices.close();
    super.dispose();
  }
}
