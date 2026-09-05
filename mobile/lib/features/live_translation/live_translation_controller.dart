import 'dart:async';
import 'dart:developer' as developer;

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
  final Set<String> _openSegments = {};
  DateTime? _sessionStartedAt;
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

    // 3. Local VAD so silence never leaves the phone.
    _vad = VadSegmenter(
      sampleRate: AudioCaptureService.sampleRate,
      onSegmentStart: (segmentId, sampleRate) {
        if (!client.isConnected) return;
        _openSegments.add(segmentId);
        client.sendSegmentStart(segmentId, sampleRate);
      },
      onAudio: (segmentId, sequence, pcm) {
        if (_openSegments.contains(segmentId)) {
          client.sendAudio(segmentId, sequence, pcm);
        }
      },
      onSegmentEnd: (segmentId, durationMs) {
        if (_openSegments.remove(segmentId)) {
          client.sendSegmentEnd(segmentId, durationMs);
        }
      },
      onLevel: _handleLevel,
      onDiagnostics: _handleVadDiagnostics,
    );

    // 4. Native microphone capture (starts the Android foreground service).
    try {
      await audioCapture.start(
        onAudio: (pcm) => _vad?.addAudio(pcm),
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
      // recorded after the user pressed Stop.
      await audioCapture.stop();
      _vad?.flush();
      _vad = null;
      _openSegments.clear();
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
      case TranslationCompleteEvent(:final messageId, :final translatedText):
        _updateMessage(
          messageId,
          (m) => m.copyWith(translatedText: translatedText, status: TranslationStatus.done),
          speak: true,
        );
      case TranslationFailedEvent(:final messageId):
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
    _logPipeline(message);
    notifyListeners();
  }

  /// Updates the existing message in place — never creates a second bubble.
  void _updateMessage(
    String messageId,
    TranslationMessage Function(TranslationMessage) change, {
    bool speak = false,
  }) {
    final index = messages.indexWhere((m) => m.id == messageId);
    if (index < 0) return;
    final alreadyDone = messages[index].status == TranslationStatus.done;
    final updated = change(messages[index]);
    messages[index] = updated;
    final sessionIndex = _sessionMessages.indexWhere((m) => m.id == messageId);
    if (sessionIndex >= 0) _sessionMessages[sessionIndex] = updated;
    if (settings.settings.developerDiagnostics) {
      developer.log(
        '[PIPELINE] update id=$messageId status=${updated.status.name} '
        'translated="${updated.translatedText}"',
        name: 'pipeline',
      );
    }
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

  DateTime _lastVadLog = DateTime.fromMillisecondsSinceEpoch(0);

  /// Developer mode: VAD internals in the console. Segment events always log;
  /// per-chunk level lines are throttled to one per second.
  void _handleVadDiagnostics(VadDiagnostics d) {
    if (!settings.settings.developerDiagnostics) return;
    if (d.event != null) {
      developer.log('[VAD] $d', name: 'vad');
      return;
    }
    final now = DateTime.now();
    if (now.difference(_lastVadLog).inMilliseconds >= 1000) {
      _lastVadLog = now;
      developer.log('[VAD] $d', name: 'vad');
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
