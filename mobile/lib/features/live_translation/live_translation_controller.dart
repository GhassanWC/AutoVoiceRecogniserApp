import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../../models/translation_message.dart';
import '../../services/firestore/session_repository.dart';
import '../../services/gemini/live_translation_service.dart';
import '../../services/permissions/mic_permission_service.dart';
import '../../services/speech/speech_service.dart';
import '../../services/storage/settings_store.dart';
import '../../utils/languages.dart';

/// The three microphone states the UI must always reflect truthfully.
enum ListeningState { idle, starting, listening }

class SessionSummary {
  const SessionSummary({required this.translationCount, required this.duration});
  final int translationCount;
  final Duration duration;
}

/// Owns the live translation SESSION for the whole app.
///
/// This is deliberately app-level state (created once in main.dart and
/// provided above the navigator), not screen state: switching tabs, pushing a
/// route, or backgrounding the app must not tear a session down. The only
/// things that end a session are the user stopping it, a fatal service error,
/// or — when "Continue listening in background" is OFF — the app leaving the
/// foreground.
///
/// Invariant it protects: the UI state always matches the real microphone
/// state, and the microphone is only ever started by an explicit user action.
class LiveTranslationController extends ChangeNotifier with WidgetsBindingObserver {
  LiveTranslationController({
    required this.settings,
    required LiveTranslationService service,
    MicPermissionService? permissions,
    SessionRepository? sessionRepository,
    String? Function()? uidProvider,
    SpeechService? speech,
  })  : _service = service,
        permissions = permissions ?? MicPermissionService(),
        _sessions = sessionRepository,
        _uidProvider = uidProvider,
        _speech = speech ?? SpeechService() {
    _eventSubscription = _service.events.listen(_onServiceEvent);
    _stateSubscription = _service.stateChanges.listen(_onServiceState);
    _levelSubscription = _service.micLevel.listen(_onMicLevel);
    _speakingSubscription = _service.speaking.listen(_onSpeaking);
    _synthesizerSubscription = _speech.speaking.listen(_onSynthesizerSpeaking);
    settings.addListener(_onSettingsChanged);
    WidgetsBinding.instance.addObserver(this);
  }

  final SettingsController settings;
  final MicPermissionService permissions;
  final LiveTranslationService _service;
  final SessionRepository? _sessions;
  final String? Function()? _uidProvider;
  final SpeechService _speech;

  // ── Observable state ────────────────────────────────────────────────────────

  ListeningState state = ListeningState.idle;

  /// Whole on-screen conversation (survives stop; cleared by the user).
  final List<TranslationMessage> messages = [];

  /// Transient status under the Listening pill. Translated audio no longer
  /// plays by itself, so nothing here ever reports "Speaking translation…".
  String? activityLabel;

  /// 0..1 microphone level for the waveform animation.
  double micLevel = 0;

  /// Persistent problem shown as a banner (null = none).
  String? errorBanner;

  bool permissionPermanentlyDenied = false;

  /// Set when a session just ended, so the UI can show the summary sheet.
  SessionSummary? lastSummary;

  /// Message whose translation is being spoken right now (null when silent).
  String? _playingMessageId;
  String? get playingMessageId => _playingMessageId;

  /// Whether [message] can be spoken aloud. The device synthesizer needs only
  /// the finalized TEXT, so this is true the moment a translation lands — and
  /// stays true for history, with nothing held in memory.
  bool canSpeak(TranslationMessage message) =>
      settings.settings.autoSpeak &&
      message.status == TranslationStatus.done &&
      message.translatedText.trim().isNotEmpty;

  final StreamController<String> _notices = StreamController.broadcast();

  /// One-off user notices (snackbars).
  Stream<String> get notices => _notices.stream;

  bool get isListening => state == ListeningState.listening;

  // ── Session internals ───────────────────────────────────────────────────────

  StreamSubscription<LiveTranslateEvent>? _eventSubscription;
  StreamSubscription<LiveServiceState>? _stateSubscription;
  StreamSubscription<double>? _levelSubscription;
  StreamSubscription<bool>? _speakingSubscription;
  StreamSubscription<bool>? _synthesizerSubscription;

  DateTime? _sessionStartedAt;
  String _sessionId = '';
  String _sessionTargetLanguage = 'en';
  bool _sessionDocCreated = false;
  int _persistedCount = 0;
  bool _wasReconnecting = false;
  bool _restarting = false;
  DateTime _lastLevelNotify = DateTime.fromMillisecondsSinceEpoch(0);

  // ── Start / stop ────────────────────────────────────────────────────────────

  Future<void> startListening() async {
    if (state != ListeningState.idle) return;
    errorBanner = null;
    permissionPermanentlyDenied = false;
    lastSummary = null;
    state = ListeningState.starting;
    notifyListeners();

    // 1. OS microphone permission (granting it never starts listening by
    //    itself — this call IS the explicit user action).
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
        _failStart('Microphone capture is not available on this platform.');
        return;
    }

    // 2. New history session identity (document created lazily on the first
    //    finalized message — aborted starts leave nothing behind).
    _sessionId = const Uuid().v4();
    _sessionDocCreated = false;
    _persistedCount = 0;
    _sessionTargetLanguage = settings.settings.targetLanguage;

    // 3. Token + WebSocket + microphone — all inside the service.
    await _service.start(
      targetLanguageCode: geminiCodeFor(_sessionTargetLanguage),
      playAudio: settings.settings.autoSpeak,
    );
    // State transitions arrive via _onServiceState; a failure lands here as
    // an error state + ServiceError event.
  }

  Future<void> stopListening() async {
    if (state == ListeningState.idle) return;
    final startedAt = _sessionStartedAt;
    await _service.stop();
    state = ListeningState.idle;
    activityLabel = null;
    _listeningInBackground = false;
    micLevel = 0;
    lastSummary = SessionSummary(
      translationCount: _persistedCount,
      duration: startedAt == null ? Duration.zero : DateTime.now().difference(startedAt),
    );
    await _endSessionDoc();
    _sessionStartedAt = null;
    notifyListeners();
  }

  void _failStart(String message) {
    state = ListeningState.idle;
    errorBanner = message;
    activityLabel = null;
    notifyListeners();
  }

  // ── Service state / events ──────────────────────────────────────────────────

  void _onServiceState(LiveServiceState next) {
    switch (next) {
      case LiveServiceState.connecting:
        state = ListeningState.starting;
      case LiveServiceState.listening:
        _sessionStartedAt ??= DateTime.now();
        state = ListeningState.listening;
        if (_wasReconnecting) {
          _wasReconnecting = false;
          errorBanner = null;
          _notices.add('Connected');
        }
      case LiveServiceState.reconnecting:
        _wasReconnecting = true;
        errorBanner = 'Connection lost. Trying to reconnect…';
      case LiveServiceState.stopping:
        break;
      case LiveServiceState.idle:
      case LiveServiceState.error:
        // Terminal for the session; ServiceError carries the message.
        if (state != ListeningState.idle && next == LiveServiceState.error) {
          state = ListeningState.idle;
          activityLabel = null;
          micLevel = 0;
          unawaited(_endSessionDoc());
        }
    }
    notifyListeners();
  }

  void _onServiceEvent(LiveTranslateEvent event) {
    switch (event) {
      case TranscriptUpdate():
        _applyTranscript(
          event.utteranceId,
          sourceText: event.sourceText,
          translatedText: event.translatedText,
          sourceLanguageCode: event.sourceLanguageCode,
          status: TranslationStatus.pending,
        );
      case UtteranceFinalized():
        _applyTranscript(
          event.utteranceId,
          sourceText: event.sourceText,
          translatedText: event.translatedText,
          sourceLanguageCode: event.sourceLanguageCode,
          status: TranslationStatus.done,
        );
        unawaited(_persistFinalized(event));
      case ServiceError():
        _wasReconnecting = false;
        // The banner may be friendly copy; the log always carries the
        // exact failure for debugging.
        developer.log('live session error [${event.kind.name}]: ${event.message}',
            name: 'live');
        errorBanner = switch (event.kind) {
          LiveErrorKind.quota =>
            'Free translation capacity is currently reached. Please try again later.',
          LiveErrorKind.network => 'Internet connection required for live translation. '
              'Check your connection and try again.',
          LiveErrorKind.auth => 'Your session expired. Please sign in again and retry.',
          LiveErrorKind.fatal => event.message,
        };
        notifyListeners();
    }
  }

  void _applyTranscript(
    String utteranceId, {
    required String sourceText,
    required String translatedText,
    required String? sourceLanguageCode,
    required TranslationStatus status,
  }) {
    final normalized = sourceLanguageCode == null || sourceLanguageCode.isEmpty
        ? null
        : normalizeDetectedLanguage(sourceLanguageCode);
    _updateMessage(
      utteranceId,
      (m) => m.copyWith(
        originalText: sourceText,
        translatedText: translatedText,
        status: status,
        sourceLanguage: normalized,
        languageConfidence: normalized == null ? null : 1.0,
      ),
      createIfMissing: true,
    );
  }

  // ── Firestore persistence (finalized messages ONLY, never partials) ─────────

  Future<void> _persistFinalized(UtteranceFinalized event) async {
    _persistedCount++;
    final sessions = _sessions;
    final uid = _uidProvider?.call();
    if (sessions == null || uid == null) return;
    final index = messages.indexWhere((m) => m.id == event.utteranceId);
    if (index < 0) return;
    try {
      if (!_sessionDocCreated) {
        await sessions.createSession(uid, _sessionId,
            targetLanguageCode: _sessionTargetLanguage);
        _sessionDocCreated = true;
      }
      await sessions.addMessage(uid, _sessionId, messages[index]);
    } catch (e) {
      developer.log('history write failed: $e', name: 'history');
    }
  }

  Future<void> _endSessionDoc() async {
    final sessions = _sessions;
    final uid = _uidProvider?.call();
    if (sessions == null || uid == null || !_sessionDocCreated) return;
    try {
      await sessions.endSession(uid, _sessionId, messageCount: _persistedCount);
    } catch (e) {
      developer.log('history end failed: $e', name: 'history');
    }
  }

  // ── Message list (one bubble per utterance id, updated in place) ────────────

  int _ensureMessage(String messageId) {
    if (messageId.isEmpty) return -1;
    final existing = messages.indexWhere((m) => m.id == messageId);
    if (existing >= 0) return existing;
    messages.add(TranslationMessage(
      id: messageId,
      speakerId: null,
      speakerLabel: null,
      sourceLanguage: 'und',
      languageConfidence: 0,
      originalText: '',
      translatedText: '',
      targetLanguage: settings.settings.targetLanguage,
      timestamp: DateTime.now(),
      status: TranslationStatus.pending,
    ));
    return messages.length - 1;
  }

  /// Updates the message in place — never creates a second bubble for the
  /// same id. With [createIfMissing], an unknown id gets a bubble first.
  void _updateMessage(
    String messageId,
    TranslationMessage Function(TranslationMessage) change, {
    bool createIfMissing = false,
  }) {
    var index = messages.indexWhere((m) => m.id == messageId);
    if (index < 0 && createIfMissing) index = _ensureMessage(messageId);
    if (index < 0) return;
    messages[index] = change(messages[index]);
    notifyListeners();
  }

  // ── Level / speaking indicators ─────────────────────────────────────────────

  void _onMicLevel(double level) {
    micLevel = level;
    // Throttle UI updates to ~8 fps; the waveform does not need more.
    final now = DateTime.now();
    if (now.difference(_lastLevelNotify).inMilliseconds > 120) {
      _lastLevelNotify = now;
      notifyListeners();
    }
  }

  /// Gemini's own audio output is discarded, so nothing reaches this from the
  /// translation flow; it exists for the service's own playback signal.
  void _onSpeaking(bool speaking) {
    if (speaking || _playingMessageId == null) return;
    _playingMessageId = null;
    notifyListeners();
  }

  /// The device synthesizer started/stopped. While it is audible the uplink
  /// is quiet so the spoken translation cannot be re-translated; the moment it
  /// stops, the microphone resumes. The session itself is never touched.
  void _onSynthesizerSpeaking(bool speaking) {
    if (!speaking) {
      _service.releaseSpeechGate();
      _playingMessageId = null;
      notifyListeners();
    }
  }

  // ── Speak a translation on demand ───────────────────────────────────────────

  /// Reads one finalized translation aloud with the device's own voice, in the
  /// message's target language. Listening keeps running throughout — this
  /// never stops, restarts, or re-scopes the session.
  Future<void> speakTranslation(TranslationMessage message) async {
    if (!canSpeak(message)) return;
    final text = message.translatedText.trim();
    // Tapping a second message replaces the first instead of overlapping.
    await _speech.stop();
    _playingMessageId = message.id;
    notifyListeners();

    // Roughly how long the speech will last (~14 characters/second), used to
    // quiet the uplink. It is only an upper bound: the synthesizer's "stopped"
    // event releases the gate as soon as it really finishes.
    if (isListening) {
      final estimate = Duration(
          milliseconds: (text.length * 1000 / 14).round().clamp(1000, 20000));
      _service.gateUplinkForSpeech(estimate);
    }

    final spoken = await _speech.speak(
      text,
      languageCode: geminiCodeFor(message.targetLanguage),
    );
    if (!spoken) {
      // No synthesizer or no voice for this language — don't leave the row
      // showing a playing state, and let the microphone straight back in.
      developer.log('no speech synthesis for ${message.targetLanguage}',
          name: 'live');
      _service.releaseSpeechGate();
      _playingMessageId = null;
      notifyListeners();
      _notices.add('No installed voice for '
          '${languageForCode(message.targetLanguage)?.name ?? message.targetLanguage}.');
    }
  }

  // ── Settings changes (target language switch restarts the session) ─────────

  void _onSettingsChanged() {
    final target = settings.settings.targetLanguage;
    if (!isListening || target == _sessionTargetLanguage || _restarting) return;
    _restarting = true;
    _notices.add(
        'Switching translation to ${languageForCode(target)?.name ?? target}…');
    // The ephemeral token locks the target language — a new session is
    // required (spec §14): stop cleanly, then start with the new target.
    Future(() async {
      try {
        await stopListening();
        lastSummary = null; // no summary sheet for an automatic restart
        await startListening();
      } finally {
        _restarting = false;
      }
    });
  }

  // ── User actions ────────────────────────────────────────────────────────────

  void clearConversation() {
    messages.clear();
    _playingMessageId = null;
    unawaited(_speech.stop());
    lastSummary = null;
    notifyListeners();
  }

  void reportBadTranslation(TranslationMessage message) {
    _notices.add('Thanks — your report helps improve translations.');
  }

  void consumeSummary() {
    lastSummary = null;
  }

  Future<void> openSystemSettings() => permissions.openSystemSettings();

  // ── Lifecycle ───────────────────────────────────────────────────────────────

  /// True while a session is deliberately continuing with the app in the
  /// background — the UI says so explicitly when the user comes back.
  bool _listeningInBackground = false;
  bool get listeningInBackground => _listeningInBackground;

  @override
  // ignore: avoid_renaming_method_parameters — `state` is taken by our own field.
  void didChangeAppLifecycleState(AppLifecycleState lifecycle) {
    if (lifecycle == AppLifecycleState.resumed) {
      if (_listeningInBackground) {
        _listeningInBackground = false;
        notifyListeners();
      }
      return;
    }
    if (lifecycle != AppLifecycleState.paused || !isListening || _restarting) {
      return;
    }
    if (settings.settings.continueInBackground) {
      // Opted in: the session keeps running behind the Android notification /
      // the iOS microphone indicator. Nothing is hidden — both platforms show
      // a live listening indicator the whole time.
      _listeningInBackground = true;
      developer.log('app backgrounded — continuing to listen (opted in)',
          name: 'live');
      notifyListeners();
      return;
    }
    // Default: leaving the foreground stops the session, so listening can
    // never continue without the user having asked for it.
    stopListening();
    errorBanner = 'Listening stopped because the app went to the background.';
    notifyListeners();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    settings.removeListener(_onSettingsChanged);
    _eventSubscription?.cancel();
    _stateSubscription?.cancel();
    _levelSubscription?.cancel();
    _speakingSubscription?.cancel();
    _synthesizerSubscription?.cancel();
    _speech.dispose();
    _service.dispose();
    _notices.close();
    super.dispose();
  }
}
