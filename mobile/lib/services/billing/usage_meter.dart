import 'dart:async';
import 'dart:developer' as developer;

import 'package:cloud_functions/cloud_functions.dart';

import '../gemini/live_translation_service.dart';
import 'speech_activity_meter.dart';

/// Sends one usage report to the backend and returns its raw reply. Injectable
/// so the reporting lifecycle can be tested without a live Firebase app.
typedef MeterSender = Future<Map<String, dynamic>> Function(
    Map<String, dynamic> payload);

/// Reports TRANSLATED SPEECH to the server while a session runs.
///
/// A Sayvo minute is a minute of speech Sayvo translated, not a minute of the
/// microphone being on, so this reports nothing at all while a room is quiet.
/// Silence, waiting, noise that produces no translation, the device's own
/// spoken playback, model latency and reconnects are all free.
///
/// What goes to the server is a CUMULATIVE total with a sequence number, never
/// a delta and never "please add N minutes". A retry, a duplicate or an
/// out-of-order call is therefore harmless: the server takes the difference
/// against what it has already accepted, and refuses anything that goes
/// backwards or outruns its own clock.
class UsageMeter implements LiveSessionObserver {
  UsageMeter({
    FirebaseFunctions? functions,
    MeterSender? sender,
    SpeechActivityMeter? speech,
    DateTime Function()? now,
    this.flushDelay = const Duration(seconds: 2),
    this.safetyInterval = const Duration(seconds: 20),
  })  : _functions = functions,
        _sender = sender,
        _speech = speech ?? SpeechActivityMeter(),
        _now = now ?? DateTime.now;

  /// Resolved lazily, and only when something is actually reported: touching
  /// FirebaseFunctions.instance eagerly would require Firebase to be
  /// initialized just to construct a controller.
  final FirebaseFunctions? _functions;
  final MeterSender? _sender;
  final SpeechActivityMeter _speech;
  final DateTime Function() _now;

  /// How long rapid utterances are batched before one report goes out.
  final Duration flushDelay;

  /// Backstop for a long utterance that has not finalized yet. Nothing is
  /// sent on this timer unless there is unreported speech.
  final Duration safetyInterval;

  Timer? _flushTimer;
  Timer? _safetyTimer;
  String? _sessionId;
  int _sequence = 0;

  /// Translated speech already settled with EARLIER metered sessions — either
  /// previous listening sessions, or earlier Gemini leases within this one.
  /// The speech meter counts forever; only what is past this line belongs to
  /// the session being reported now.
  int _baselineMs = 0;

  /// Reported to the CURRENT metered session, relative to [_baselineMs].
  int _reportedMs = 0;
  bool _sending = false;

  /// Whether a lease has been taken out since the last [finish].
  bool _leased = false;

  // Telemetry: how much audio we stream for how much translated speech.
  int _connectedMs = 0;
  int _audioSentMs = 0;
  DateTime? _connectedAt;

  /// Called when the server reports the allowance is exhausted.
  void Function()? onExhausted;

  /// Called with each fresh server remainder so the UI can count down.
  void Function(int remainingMs)? onRemaining;

  bool get isRunning => _sessionId != null;

  /// Translated speech this metered session is responsible for.
  int get _sessionCommittedMs => _speech.committedSpeechMs - _baselineMs;

  /// Translated-speech ms committed locally but not yet accepted by the server.
  int get unreportedMs => _sessionCommittedMs - _reportedMs;

  /// Exposed for the controller's session summary and for tests.
  SpeechActivityMeter get speech => _speech;

  /// Begins reporting for a new LISTENING session.
  ///
  /// The speech meter keeps counting across sessions, so everything committed
  /// so far is drawn behind the line: this session reports only its own
  /// translated speech, never a total that a previous session already paid.
  void start(String sessionId) {
    if (_sessionId == sessionId) return;
    _flushTimer?.cancel();
    _safetyTimer?.cancel();
    _baselineMs = _speech.committedSpeechMs;
    _sessionId = sessionId;
    _sequence = 0;
    _reportedMs = 0;
    _connectedMs = 0;
    _audioSentMs = 0;
    _connectedAt = null;
    _armSafetyTimer();
  }

  void _armSafetyTimer() {
    _safetyTimer?.cancel();
    _safetyTimer = Timer.periodic(safetyInterval, (_) {
      // Quiet room, nothing translated: there is nothing to say, so say
      // nothing. No write, no wake-up, no cost.
      if (unreportedMs > 0) unawaited(_send(close: false));
    });
  }

  /// Sends the final total and closes the session, so the last translated
  /// utterance is paid for and nothing can be charged afterwards.
  Future<void> finish() async {
    _flushTimer?.cancel();
    _flushTimer = null;
    _safetyTimer?.cancel();
    _safetyTimer = null;
    _speech.endSession(_now());
    _closeConnectedWindow();
    _leased = false;
    final sessionId = _sessionId;
    if (sessionId == null) return;
    await _send(close: true);
    _sessionId = null;
  }

  void stopTimers() {
    _flushTimer?.cancel();
    _flushTimer = null;
    _safetyTimer?.cancel();
    _safetyTimer = null;
  }

  // ── LiveSessionObserver ───────────────────────────────────────────────────

  @override
  void onConnected() => _connectedAt = _now();

  @override
  void onDisconnected() => _closeConnectedWindow();

  @override
  void onMicAudio({
    required double rms,
    required Duration duration,
    required bool gated,
    required bool sentUpstream,
  }) {
    _speech.onAudio(rms: rms, duration: duration, gated: gated, at: _now());
    if (sentUpstream) _audioSentMs += duration.inMilliseconds;
  }

  /// Diagnostics only. Nothing in the audio path may branch on this: the
  /// billing detector must never decide what Gemini gets to hear.
  @override
  bool get isSpeechDetected => _speech.inSpeech;

  @override
  void onTranslatedText() {
    _speech.onTranslatedText(_now());
    if (unreportedMs > 0) _scheduleFlush();
  }

  @override
  void onUtteranceTranslated() {
    _speech.onUtteranceTranslated();
    // The utterance is done, so its speech is now committed; batch briefly in
    // case several land together.
    _scheduleFlush();
  }

  /// A Gemini lease is ending. Settle what this metered session owes before
  /// the server is asked for another one — that settlement is exactly what
  /// makes an exhausted account fail to get a new lease.
  @override
  Future<void> onLeaseEnding() async {
    final sessionId = _sessionId;
    if (sessionId == null) return;
    _flushTimer?.cancel();
    _flushTimer = null;
    await _send(close: true);
    // Whatever the server accepted is behind us now; anything it did not
    // carries into the next lease rather than being charged twice or lost.
    _baselineMs += _reportedMs;
    _reportedMs = 0;
    _sessionId = null;
  }

  /// A new lease is in force. The listening session, the conversation and the
  /// speech meter all continue — only the metered session id changes.
  @override
  void onLeaseStarted(String? sessionId) {
    if (sessionId == null || _sessionId == sessionId) return;
    if (_leased) {
      // A renewal: keep the telemetry and the speech already measured.
      _sessionId = sessionId;
      _sequence = 0;
      _reportedMs = 0;
      _armSafetyTimer();
    } else {
      start(sessionId);
    }
    _leased = true;
  }

  // ── Reporting ─────────────────────────────────────────────────────────────

  void _scheduleFlush() {
    if (_sessionId == null) return;
    _flushTimer?.cancel();
    _flushTimer = Timer(flushDelay, () {
      if (unreportedMs > 0) unawaited(_send(close: false));
    });
  }

  void _closeConnectedWindow() {
    final since = _connectedAt;
    if (since == null) return;
    _connectedMs += _now().difference(since).inMilliseconds;
    _connectedAt = null;
  }

  Future<void> _send({required bool close}) async {
    final sessionId = _sessionId;
    if (sessionId == null) return;
    // One report in flight at a time: overlapping calls would report the same
    // total twice, and while that is harmless server-side it is pure noise.
    if (_sending && !close) return;
    _sending = true;
    // Cumulative FOR THIS metered session: the server takes the difference
    // against what it has already accepted for it.
    final cumulative = _sessionCommittedMs;
    final sequence = ++_sequence;
    try {
      final data = await (_sender ?? _callFunction)({
        'sessionId': sessionId,
        'sequence': sequence,
        'cumulativeSpeechMs': cumulative,
        'close': close,
        if (close) 'telemetry': telemetry(),
      });
      // Only what the SERVER accepted counts as reported.
      _reportedMs = cumulative;
      final remaining = (data['remainingMs'] as num?)?.toInt();
      if (remaining != null) onRemaining?.call(remaining);
      if (data['allowed'] == false && !close) onExhausted?.call();
    } catch (e) {
      // A dropped report must not stop a paid session: the total is
      // cumulative, so the next successful report carries it anyway.
      developer.log('usage report failed: $e', name: 'billing');
    } finally {
      _sending = false;
    }
  }

  /// Non-PII operational counters, so we can answer "how much audio did we
  /// stream for each minute of translated speech". No transcripts, no audio,
  /// no languages, nothing about what was said.
  Map<String, int> telemetry() {
    final connected = _connectedAt == null
        ? _connectedMs
        : _connectedMs + _now().difference(_connectedAt!).inMilliseconds;
    return {
      'connectedMs': connected,
      'audioSentMs': _audioSentMs,
      'committedSpeechMs': _sessionCommittedMs,
      'translatedUtteranceCount': _speech.translatedUtteranceCount,
    };
  }

  Future<Map<String, dynamic>> _callFunction(Map<String, dynamic> payload) async {
    final functions = _functions ?? FirebaseFunctions.instance;
    final response = await functions
        .httpsCallable('meterLiveTranslateSession')
        .call<Map<String, dynamic>>(payload);
    return Map<String, dynamic>.from(response.data);
  }

  void dispose() => stopTimers();
}
