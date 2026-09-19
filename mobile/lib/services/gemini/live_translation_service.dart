import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:typed_data';

import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../utils/languages.dart' show normalizeDetectedLanguage;
import '../../utils/mic_level.dart';
import '../audio/audio_capture_service.dart';
import '../audio/audio_playback_service.dart';
import '../diagnostics/live_diagnostics.dart';
import '../network/connectivity_probe.dart';

/// Connection lifecycle of one live translation session.
enum LiveServiceState { idle, connecting, listening, reconnecting, stopping, error }

/// User-facing error categories (each maps to specific UI copy).
///
/// [outOfMinutes] is this ACCOUNT's included minutes being spent, which opens
/// the paywall; [quota] is Gemini's own capacity, which is not the user's
/// fault and must never be shown as "buy more".
enum LiveErrorKind { outOfMinutes, quota, network, auth, fatal }

/// Ephemeral credential minted by the Cloud Function.
class LiveSessionToken {
  const LiveSessionToken({
    required this.token,
    required this.model,
    required this.expireTime,
    this.sessionId,
    this.remainingMinutes,
  });
  final String token;
  final String model;
  final DateTime expireTime;

  /// Server-issued id for the METERED session this token opened. The client
  /// never invents it — heartbeats quote it back so the server bills the
  /// right session.
  final String? sessionId;

  /// Minutes left at the moment the token was minted.
  final double? remainingMinutes;
}

/// Thrown by the token provider when minting fails.
class TokenRequestException implements Exception {
  const TokenRequestException(this.kind, this.message);
  final LiveErrorKind kind;
  final String message;
  @override
  String toString() => 'TokenRequestException(${kind.name}): $message';
}

typedef TokenProvider = Future<LiveSessionToken> Function(String targetLanguageCode);

/// Thin socket seam so tests never touch real WebSockets.
abstract class GeminiSocket {
  Stream<dynamic> get messages;
  void send(String data);
  Future<void> close();

  /// WebSocket close code/reason, available once the connection has closed
  /// (null before that, and for test fakes that never set them).
  int? get closeCode;
  String? get closeReason;
}

typedef SocketConnector = Future<GeminiSocket> Function(Uri uri);

class _ChannelSocket implements GeminiSocket {
  _ChannelSocket(this._channel);
  final WebSocketChannel _channel;
  @override
  Stream<dynamic> get messages => _channel.stream;
  @override
  void send(String data) => _channel.sink.add(data);
  @override
  Future<void> close() => _channel.sink.close();
  @override
  int? get closeCode => _channel.closeCode;
  @override
  String? get closeReason => _channel.closeReason;
}

Future<GeminiSocket> defaultSocketConnector(Uri uri) async {
  final channel = WebSocketChannel.connect(uri);
  await channel.ready;
  return _ChannelSocket(channel);
}

// ── Events ────────────────────────────────────────────────────────────────────

sealed class LiveTranslateEvent {
  const LiveTranslateEvent();
}

/// Incremental transcript for the utterance currently being spoken.
/// UI-only — partials are never persisted.
class TranscriptUpdate extends LiveTranslateEvent {
  const TranscriptUpdate({
    required this.utteranceId,
    required this.sourceText,
    required this.translatedText,
    this.sourceLanguageCode,
  });
  final String utteranceId;
  final String sourceText;
  final String translatedText;
  final String? sourceLanguageCode;
}

/// The utterance is complete — the TEXT here is what gets persisted.
class UtteranceFinalized extends LiveTranslateEvent {
  const UtteranceFinalized({
    required this.utteranceId,
    required this.sourceText,
    required this.translatedText,
    required this.at,
    this.sourceLanguageCode,
  });
  final String utteranceId;
  final String sourceText;
  final String translatedText;
  final DateTime at;
  final String? sourceLanguageCode;
}

class ServiceError extends LiveTranslateEvent {
  const ServiceError(this.kind, this.message);
  final LiveErrorKind kind;
  final String message;
}

// ── The service ───────────────────────────────────────────────────────────────

/// Owns the entire Gemini Live Translate session:
///
///   ephemeral token → WebSocket → setup → microphone streaming →
///   incoming transcripts/audio → finalized utterances → clean shutdown.
///
/// The user picks only the TARGET language; Gemini detects the source
/// automatically per utterance. No local ASR, no local language detection,
/// no VAD gating — every audible microphone chunk is streamed (except while
/// the device itself is speaking a translation, see [_uplinkGated]).
class LiveTranslationService {
  LiveTranslationService({
    required TokenProvider tokenProvider,
    SocketConnector? connect,
    AudioCaptureService? capture,
    AudioPlaybackService? playback,
    this.backoffDelays = const [
      Duration(seconds: 1),
      Duration(seconds: 2),
      Duration(seconds: 4),
    ],
    this.setupTimeout = const Duration(seconds: 15),
    this.playbackGateTail = const Duration(milliseconds: 300),
    String Function()? utteranceIdFactory,
    DateTime Function()? now,
    Future<bool> Function()? isOnline,
  })  : _tokenProvider = tokenProvider,
        _isOnline = isOnline ?? hasInternetConnection,
        _connect = connect ?? defaultSocketConnector,
        capture = capture ?? AudioCaptureService(),
        playback = playback ?? AudioPlaybackService(),
        _newUtteranceId = utteranceIdFactory ?? (() => const Uuid().v4()),
        _now = now ?? DateTime.now {
    _playbackSubscription = this.playback.playbackActive.listen(_onPlaybackActive);
  }

  /// The CONSTRAINED endpoint: sessions opened with an ephemeral token whose
  /// bidiGenerateContentSetup is locked server-side must connect here.
  static const String websocketBase =
      'wss://generativelanguage.googleapis.com/ws/'
      'google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContentConstrained';

  /// ~100 ms of 16 kHz mono PCM16.
  static const int _sendChunkBytes = 3200;

  final TokenProvider _tokenProvider;
  final Future<bool> Function() _isOnline;
  final SocketConnector _connect;
  final AudioCaptureService capture;
  final AudioPlaybackService playback;
  final List<Duration> backoffDelays;
  final Duration setupTimeout;
  final Duration playbackGateTail;
  final String Function() _newUtteranceId;
  final DateTime Function() _now;

  LiveServiceState _state = LiveServiceState.idle;
  LiveServiceState get state => _state;

  /// The server-issued metered session id for the token in use, or null when
  /// no session is open.
  String? get meteredSessionId => _token?.sessionId;

  final StreamController<LiveServiceState> _stateChanges = StreamController.broadcast();
  Stream<LiveServiceState> get stateChanges => _stateChanges.stream;

  final StreamController<LiveTranslateEvent> _events = StreamController.broadcast();
  Stream<LiveTranslateEvent> get events => _events.stream;

  final StreamController<double> _micLevel = StreamController.broadcast();

  /// 0..1 microphone level for the waveform animation only.
  Stream<double> get micLevel => _micLevel.stream;

  final StreamController<bool> _speaking = StreamController.broadcast();

  /// True while the device is playing a translation (mic uplink gated).
  Stream<bool> get speaking => _speaking.stream;

  // Session internals — all guarded by [_generation]: every async continuation
  // captures the generation it belongs to and no-ops if a stop()/restart
  // superseded it.
  int _generation = 0;
  GeminiSocket? _socket;
  StreamSubscription<dynamic>? _socketSubscription;
  StreamSubscription<bool>? _playbackSubscription;
  Timer? _setupTimer;
  Timer? _reconnectTimer;
  LiveSessionToken? _token;
  String _targetLanguageCode = 'en';
  bool _setupDone = false;
  bool _captureRunning = false;
  int _reconnectAttempts = 0;
  String? _resumeHandle;
  String? _lastSocketError;
  bool _firstFrameLogged = false;
  bool _socketErrorRecorded = false;

  // Current-utterance aggregation.
  String? _utteranceId;
  final StringBuffer _sourceBuffer = StringBuffer();
  final StringBuffer _translationBuffer = StringBuffer();
  String? _sourceLanguageCode;

  /// A segment closed by a LANGUAGE SWITCH whose translation had not arrived
  /// yet. It keeps ownership of the next translation chunk, so a lagging
  /// translation lands in the bubble that produced it rather than the next
  /// speaker's.
  String? _tailId;
  String? _tailLanguage;
  final StringBuffer _tailSource = StringBuffer();

  /// Bytes of Gemini audio received and discarded this session (diagnostics).
  int _discardedAudioBytes = 0;

  // Half-duplex gate.
  bool _playbackActive = false;
  DateTime _gateUntil = DateTime.fromMillisecondsSinceEpoch(0);

  /// When the audio we have handed to the player can, at the earliest, have
  /// finished playing (derived from the PCM byte count we fed).
  DateTime _queuedAudioEndsAt = DateTime.fromMillisecondsSinceEpoch(0);
  final BytesBuilder _pendingAudio = BytesBuilder(copy: true);

  /// Slack for device-side buffering before a "still speaking" claim from the
  /// native player is treated as stale.
  static const Duration _playbackClaimSlack = Duration(seconds: 2);

  /// Hard ceiling on how long ONE uninterrupted "still speaking" claim may
  /// gate the microphone. A single translated utterance is far shorter, and
  /// the queued-audio horizon already covers legitimately longer queues — this
  /// exists only so a lost completion callback from the native player (engine
  /// reconfiguration, route change, flushed buffer) can never latch the uplink
  /// off for the rest of the session.
  static const Duration _maxContinuousGate = Duration(seconds: 10);

  DateTime? _playbackActiveSince;

  // Diagnostics only (see live_diagnostics.dart).
  Timer? _healthTimer;
  int _chunksSent = 0;
  int _chunksDropped = 0;
  DateTime? _lastChunkAt;
  bool? _lastGateState;
  String? _lastServerKeys;

  bool get _uplinkGated {
    final now = _now();
    if (now.isBefore(_gateUntil)) return true;
    if (!_playbackActive) return false;
    // The player says it is still speaking — believe it (that is what keeps
    // speaker output from looping back in), but never indefinitely.
    final byQueuedAudio = _queuedAudioEndsAt.add(_playbackClaimSlack);
    final byCeiling = (_playbackActiveSince ?? now).add(_maxContinuousGate);
    final deadline = byQueuedAudio.isAfter(byCeiling) ? byQueuedAudio : byCeiling;
    return now.isBefore(deadline);
  }

  /// Diagnostics: how much queued translated audio is still due to play.
  String get _queuedAudioLabel {
    final remaining = _queuedAudioEndsAt.difference(_now());
    return remaining.isNegative ? 'none' : '${remaining.inMilliseconds}ms';
  }

  // ── Public API ──────────────────────────────────────────────────────────────

  /// Starts a session translating into [targetLanguageCode] (BCP-47, already
  /// mapped through geminiCodeFor). Microphone capture must be permitted
  /// beforehand — permission UX is the controller's job.
  ///
  /// Gemini's generated speech is discarded — translations are read aloud on
  /// demand by the device synthesizer instead (see SpeechService). Routing
  /// Gemini's audio to the speaker while the microphone was live is what used
  /// to gate the uplink and stop a session translating after one utterance.
  Future<void> start({required String targetLanguageCode}) async {
    if (_state != LiveServiceState.idle && _state != LiveServiceState.error) return;
    final generation = ++_generation;
    _targetLanguageCode = targetLanguageCode;
    _reconnectAttempts = 0;
    _resumeHandle = null;
    _lastSocketError = null;
    _playbackActive = false;
    _playbackActiveSince = null;
    _gateUntil = DateTime.fromMillisecondsSinceEpoch(0);
    _queuedAudioEndsAt = DateTime.fromMillisecondsSinceEpoch(0);
    _chunksSent = 0;
    _chunksDropped = 0;
    _discardedAudioBytes = 0;
    _lastChunkAt = null;
    _lastGateState = null;
    _lastServerKeys = null;
    _clearTail();
    resetLiveTraceThrottles();
    liveTrace('SESSION_START', 'target=$targetLanguageCode');
    _resetUtterance();
    _setState(LiveServiceState.connecting);

    final LiveSessionToken token;
    try {
      token = await _tokenProvider(targetLanguageCode);
    } on TokenRequestException catch (e) {
      if (generation != _generation) return;
      _failSession(e.kind, e.message);
      return;
    } catch (e, stackTrace) {
      if (generation != _generation) return;
      // An unmapped error is NOT a connectivity problem — surface it as-is.
      developer.log('token provider threw unexpectedly: ${e.runtimeType}: $e',
          name: 'live.session', error: e, stackTrace: stackTrace);
      _failSession(LiveErrorKind.fatal, 'Could not start a translation session: $e');
      return;
    }
    if (generation != _generation) return;
    _token = token;
    await _openSocket(generation, resuming: false);
  }

  /// Stops everything and returns to idle. Callable from any state; must
  /// never throw — Start Listening has to become usable again.
  Future<void> stop() async {
    _generation++;
    _healthTimer?.cancel();
    _healthTimer = null;
    if (_state == LiveServiceState.idle) return;
    liveTrace('SESSION_STOP',
        'sent=$_chunksSent dropped=$_chunksDropped state=${_state.name}');
    _setState(LiveServiceState.stopping);
    _setupTimer?.cancel();
    _reconnectTimer?.cancel();
    // Capture stops FIRST: not one extra sample is recorded after Stop.
    await _stopCapture();
    _finalizePendingUtterance();
    await playback.stop();
    await _closeSocket();
    _token = null;
    _resumeHandle = null;
    _setState(LiveServiceState.idle);
  }

  /// Quiets the microphone uplink for [duration] while the device's speech
  /// synthesizer is audible, so the spoken translation cannot be picked up by
  /// the live microphone and re-translated.
  ///
  /// The session is untouched — state stays [LiveServiceState.listening], the
  /// socket stays open, capture keeps running — and the gate always expires,
  /// so a session can never be left deaf.
  void gateUplinkForSpeech(Duration duration) {
    final until = _now().add(duration);
    if (until.isAfter(_gateUntil)) _gateUntil = until;
    liveTrace('TTS_GATE', 'uplink quiet for ${duration.inMilliseconds}ms '
        'state=${_state.name}');
  }

  /// Reopens the uplink the moment the synthesizer reports it has stopped,
  /// rather than waiting out the estimate.
  void releaseSpeechGate() {
    if (!_now().isBefore(_gateUntil)) return;
    _gateUntil = _now();
    liveTrace('TTS_GATE', 'released early, uplink open');
  }

  Future<void> dispose() async {
    await stop();
    await _playbackSubscription?.cancel();
    await _events.close();
    await _stateChanges.close();
    await _micLevel.close();
    await _speaking.close();
    await playback.dispose();
  }

  // ── Connection ──────────────────────────────────────────────────────────────

  Future<void> _openSocket(int generation, {required bool resuming}) async {
    final token = _token;
    if (token == null) return;
    _setupDone = false;
    _firstFrameLogged = false;
    _socketErrorRecorded = false;
    // Cancel any timer from a previous connection BEFORE the connect await:
    // a stale timer firing mid-connect would start a second reconnect flow
    // for the same generation (two live sockets, duplicated frames).
    _setupTimer?.cancel();
    try {
      final socket = await _connect(Uri.parse('$websocketBase?access_token=${token.token}'));
      if (generation != _generation) {
        await socket.close();
        return;
      }
      // Log the endpoint only — the access_token must never reach the logs.
      developer.log('WebSocket opened: $websocketBase (resuming=$resuming)',
          name: 'live.socket');
      _socket = socket;
      _socketSubscription = socket.messages.listen(
        (dynamic frame) => _onFrame(generation, frame),
        onError: (Object error) {
          _socketErrorRecorded = true;
          _lastSocketError = _sanitizeError(error);
          developer.log('WebSocket stream error: $_lastSocketError',
              name: 'live.socket');
          _onSocketClosed(generation);
        },
        onDone: () => _onSocketClosed(generation),
        cancelOnError: true,
      );
      socket.send(jsonEncode(_setupMessage(token.model, resuming: resuming)));
      developer.log(
          'setup sent (model=${token.model}, target=$_targetLanguageCode, '
          'resumeHandle=${resuming && _resumeHandle != null})',
          name: 'live.socket');
      _setupTimer?.cancel();
      _setupTimer = Timer(setupTimeout, () {
        if (generation != _generation || _setupDone) return;
        developer.log(
            'setupComplete NOT received within ${setupTimeout.inSeconds}s — '
            'closing this connection',
            name: 'live.socket');
        _onSocketClosed(generation);
      });
    } catch (e) {
      // Handshake failure: DNS/TLS errors, or the Gemini endpoint refusing
      // the upgrade (e.g. an invalid/expired ephemeral token → HTTP 4xx).
      // dart:io puts the FULL request URI — access token included — into
      // WebSocketException messages, so sanitize before storing or logging.
      _lastSocketError = _sanitizeError(e);
      developer.log('WebSocket connect failed: $_lastSocketError',
          name: 'live.socket');
      if (generation != _generation) return;
      await _handleConnectionLoss(generation);
    }
  }

  /// Strips the ephemeral access token from error text before it can reach
  /// logs, [_lastSocketError], or user-facing messages. dart:io embeds the
  /// full request URI (including ?access_token=...) in handshake errors.
  String _sanitizeError(Object error) {
    var text = '$error';
    final token = _token?.token;
    if (token != null && token.isNotEmpty) {
      text = text.replaceAll(token, '<redacted>');
    }
    return text.replaceAll(
        RegExp(r"access_token=[^&'\s]+"), 'access_token=<redacted>');
  }

  /// A valid BidiGenerateContentSetup, mirroring the server-locked token
  /// constraints: translationConfig and responseModalities live INSIDE
  /// generationConfig; the transcription configs and sessionResumption sit
  /// at the setup level. Misplaced fields get the session closed right
  /// after setup.
  Map<String, dynamic> _setupMessage(String model, {required bool resuming}) => {
        'setup': {
          'model': model,
          'generationConfig': {
            'responseModalities': ['AUDIO'],
            'translationConfig': {
              'targetLanguageCode': _targetLanguageCode,
              'echoTargetLanguage': true,
            },
          },
          'inputAudioTranscription': <String, dynamic>{},
          'outputAudioTranscription': <String, dynamic>{},
          'sessionResumption': {
            if (resuming && _resumeHandle != null) 'handle': _resumeHandle,
          },
        },
      };

  Future<void> _onSetupComplete(int generation) async {
    _setupTimer?.cancel();
    _setupDone = true;
    _reconnectAttempts = 0;
    // Capture first: it owns the audio-session configuration (playAndRecord)
    // that playback then joins.
    if (!_captureRunning) {
      try {
        await capture.start(onAudio: _onMicChunk, onStopped: _onCaptureStopped);
        _captureRunning = true;
      } catch (_) {
        if (generation != _generation) return;
        _failSession(LiveErrorKind.fatal,
            'Could not start the microphone. It may be in use by another app.');
        return;
      }
    }
    if (generation != _generation) return;
    // Playback is NOT started here: nothing plays until the user taps a
    // message's speaker button.
    _setState(LiveServiceState.listening);
    liveTrace('SETUP_COMPLETE',
        'capture=$_captureRunning target=$_targetLanguageCode');
    _startHealthTrace();
  }

  void _onSocketClosed(int generation) {
    if (generation != _generation) return;
    final socket = _socket;
    developer.log(
        'WebSocket closed: code=${socket?.closeCode} '
        'reason=${socket?.closeReason} setupComplete=$_setupDone',
        name: 'live.socket');
    // The close-frame fallback must not clobber a more specific error the
    // stream onError handler recorded moments earlier.
    if (socket != null && !_setupDone && !_socketErrorRecorded) {
      _lastSocketError =
          'closed during setup (code=${socket.closeCode}, reason=${socket.closeReason})';
    }
    // A connection that died during setup leaves its 15s timer armed; kill
    // it so it cannot fire into a later reconnect of the same generation.
    _setupTimer?.cancel();
    _socketSubscription?.cancel();
    _socketSubscription = null;
    _socket = null;
    if (socket != null) {
      // Really close it. Cancelling the stream subscription alone leaves the
      // underlying WebSocket (and its server-side session) open — on the
      // setup-timeout path this is the ONLY close. Idempotent on dead sockets.
      socket.close().ignore();
    }
    unawaited(_handleConnectionLoss(generation));
  }

  Future<void> _handleConnectionLoss(int generation) async {
    if (generation != _generation) return;
    if (_state != LiveServiceState.listening &&
        _state != LiveServiceState.connecting &&
        _state != LiveServiceState.reconnecting) {
      return;
    }
    await playback.stop();
    if (_reconnectAttempts >= backoffDelays.length) {
      // "Internet required" ONLY when the device is genuinely offline;
      // otherwise the service is rejecting us and the real error must show.
      final online = await _isOnline();
      if (generation != _generation) return;
      developer.log(
          'reconnect attempts exhausted (online=$online, '
          'last socket error: ${_lastSocketError ?? 'none'})',
          name: 'live.session');
      if (online) {
        _failSession(
            LiveErrorKind.fatal,
            'Could not stay connected to the translation service.'
            '${_lastSocketError == null ? '' : ' Last error: $_lastSocketError'}');
      } else {
        _failSession(LiveErrorKind.network,
            'Connection to the translation service was lost. Check your internet connection and try again.');
      }
      return;
    }
    final delay = backoffDelays[_reconnectAttempts];
    _reconnectAttempts++;
    _setState(LiveServiceState.reconnecting);
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(delay, () async {
      if (generation != _generation) return;
      final token = _token;
      final tokenValid = token != null &&
          _now().toUtc().isBefore(token.expireTime.subtract(const Duration(seconds: 10)));
      if (tokenValid && _resumeHandle != null) {
        await _openSocket(generation, resuming: true);
        return;
      }
      // Fresh token (single-use tokens can't reopen without a resume handle).
      try {
        _token = await _tokenProvider(_targetLanguageCode);
      } on TokenRequestException catch (e) {
        if (generation != _generation) return;
        if (e.kind == LiveErrorKind.quota || e.kind == LiveErrorKind.auth) {
          _failSession(e.kind, e.message); // never retry quota/auth
          return;
        }
        await _handleConnectionLoss(generation); // burns another attempt
        return;
      } catch (e) {
        developer.log('token refresh during reconnect failed: $e',
            name: 'live.session', error: e);
        if (generation != _generation) return;
        await _handleConnectionLoss(generation);
        return;
      }
      if (generation != _generation) return;
      _resumeHandle = null;
      await _openSocket(generation, resuming: false);
    });
  }

  // ── Incoming frames ─────────────────────────────────────────────────────────

  void _onFrame(int generation, dynamic frame) {
    if (generation != _generation) return;
    final String text;
    if (frame is String) {
      text = frame;
    } else if (frame is List<int>) {
      text = utf8.decode(frame, allowMalformed: true);
    } else {
      return;
    }
    if (!_firstFrameLogged) {
      _firstFrameLogged = true;
      // First frame per connection tells us how the server answered setup.
      developer.log(
          'first server message (${text.length} chars): '
          '${text.length > 500 ? '${text.substring(0, 500)}…' : text}',
          name: 'live.socket');
    }
    final Map<String, dynamic> message;
    try {
      message = jsonDecode(text) as Map<String, dynamic>;
    } catch (_) {
      return;
    }

    if (message.containsKey('setupComplete')) {
      developer.log('setupComplete received', name: 'live.socket');
      unawaited(_onSetupComplete(generation));
      return;
    }

    final resumption = message['sessionResumptionUpdate'];
    if (resumption is Map) {
      if (resumption['resumable'] == true && resumption['newHandle'] is String) {
        _resumeHandle = resumption['newHandle'] as String;
      }
      return;
    }

    if (message.containsKey('goAway')) {
      // Server is about to close this connection; the resulting onDone
      // triggers the reconnect path (with the resume handle if we have one).
      return;
    }

    final content = message['serverContent'];
    if (content is! Map) {
      liveTrace('SERVER_MESSAGE', 'keys=${message.keys.toList()} (no serverContent)');
      return;
    }
    // Log when the FRAME SHAPE changes (new kind of server message) rather
    // than on a timer — audio bursts repeat the same shape many times/second.
    final keys = (content.keys.map((k) => '$k').toList()..sort()).join(',');
    if (keys != _lastServerKeys) {
      _lastServerKeys = keys;
      liveTrace('SERVER_MESSAGE', 'serverContent=[$keys]');
    }

    if (content['interrupted'] == true) {
      liveTrace('MODEL_INTERRUPTED', 'model turn cut short');
    }

    final input = content['inputTranscription'];
    if (input is Map) {
      final text = input['text'];
      if (text is String && text.isNotEmpty) {
        final raw = input['languageCode'];
        // A language change opens a NEW utterance before this text is stored,
        // so the incoming words can never land in the previous speaker's
        // bubble (see _openOrContinueUtterance).
        _openOrContinueUtterance(raw is String && raw.isNotEmpty ? raw : null);
        _sourceBuffer.write(text);
        // Content is user speech — log shape only, never the words.
        liveTrace(
            'INPUT_TRANSCRIPTION',
            'utterance=$_utteranceId +${text.length}ch '
                'total=${_sourceBuffer.length}ch lang=$_sourceLanguageCode');
        _emitUpdate();
      }
    }

    final output = content['outputTranscription'];
    if (output is Map) {
      final text = output['text'];
      if (text is String && text.isNotEmpty) {
        // Ownership, not "whoever is open": a segment closed by a language
        // switch before its translation arrived still owns that translation,
        // so a lagging translation lands in the bubble that produced it
        // instead of the next speaker's.
        if (_tailId != null) {
          _finalizeTailWithTranslation(text);
          return;
        }
        if (_utteranceId == null) _openUtterance(null);
        _translationBuffer.write(text);
        liveTrace(
            'OUTPUT_TRANSCRIPTION',
            'utterance=$_utteranceId +${text.length}ch '
                'total=${_translationBuffer.length}ch');
        _emitUpdate();
      }
    }

    final modelTurn = content['modelTurn'];
    if (modelTurn is Map) {
      final parts = modelTurn['parts'];
      if (parts is List) {
        for (final part in parts) {
          if (part is! Map) continue;
          final inline = part['inlineData'];
          if (inline is! Map) continue;
          final mime = inline['mimeType'];
          final data = inline['data'];
          if (data is String && (mime is! String || mime.startsWith('audio/pcm'))) {
            // RECEIVED AND DISCARDED. Live Translate emits AUDIO because the
            // ephemeral token locks that modality, but the app speaks
            // translations with the device's own synthesizer instead. Nothing
            // here may touch the speaker or the uplink gate — routing this
            // audio out loud is what used to stop the session translating.
            _discardedAudioBytes += data.length;
          }
        }
      }
    }

    if (content['turnComplete'] == true || content['generationComplete'] == true) {
      liveTrace(
          content['turnComplete'] == true ? 'TURN_COMPLETE' : 'GENERATION_COMPLETE',
          'utterance=$_utteranceId source=${_sourceBuffer.length}ch '
              'translation=${_translationBuffer.length}ch '
              'geminiAudioDiscarded=${_discardedAudioBytes}B '
              'state=${_state.name} capture=$_captureRunning');
      // generationComplete arrives before turnComplete for the same turn;
      // finalizing on the first of the two and resetting makes the second
      // a no-op (buffers empty).
      _finalizePendingUtterance();
    }
  }

  // ── Utterance segmentation ──────────────────────────────────────────────────
  //
  // One bubble = one speaker's continuous speech in ONE language. Gemini gives
  // no speaker identity, but it does report the detected source language per
  // input transcription, and a change there is a hard segment boundary: when
  // a Hindi speaker is followed by a Thai speaker inside the same model turn,
  // the Thai words must NOT extend the Hindi bubble or inherit its flag.
  //
  // Boundaries are therefore: turnComplete/generationComplete (as before) OR a
  // source-language change (new). Each utterance's language is assigned once,
  // at creation, and never mutated — so a late event can never relabel a
  // bubble that has already been closed.

  /// Opens a new utterance, or keeps the current one, for incoming source
  /// speech tagged [rawLanguage].
  void _openOrContinueUtterance(String? rawLanguage) {
    final incoming =
        rawLanguage == null ? null : normalizeDetectedLanguage(rawLanguage);

    if (_utteranceId == null) {
      _openUtterance(incoming);
      return;
    }
    // No language reported: this is more of whatever is already open.
    if (incoming == null) return;

    final current = _sourceLanguageCode;
    if (current == null) {
      // The utterance was opened by a translation before any language was
      // known — adopt the first one reported rather than splitting.
      _sourceLanguageCode = incoming;
      return;
    }
    // Compared normalized, so "hi" and "hi-IN" are the same speaker's
    // language while "hi-IN" and "th-TH" are not.
    if (current == incoming) return;

    liveTrace('LANGUAGE_SWITCH',
        'from=$current to=$incoming — closing utterance=$_utteranceId');

    if (_translationBuffer.isEmpty && _sourceBuffer.isNotEmpty) {
      // Its translation has not arrived yet. Gemini's translation LAGS its
      // input, so this segment's translation can land after the next
      // speaker's source text. Closing it now would finalize it with an empty
      // translation AND push its words into the next speaker's bubble, so it
      // keeps ownership of the translation until that translation arrives.
      _finalizeTail(); // at most one segment ever waits
      _tailId = _utteranceId;
      _tailLanguage = _sourceLanguageCode;
      _tailSource
        ..clear()
        ..write(_sourceBuffer.toString());
      liveTrace('TRANSLATION_TAIL',
          'utterance=$_tailId holds the next translation chunk');
      _resetUtterance();
    } else {
      _finalizePendingUtterance();
    }
    _openUtterance(incoming);
  }

  void _openUtterance(String? normalizedLanguage) {
    _utteranceId = _newUtteranceId();
    _sourceLanguageCode = normalizedLanguage;
    _sourceBuffer.clear();
    _translationBuffer.clear();
    liveTrace('UTTERANCE_OPEN',
        'utterance=$_utteranceId lang=${normalizedLanguage ?? 'unknown'}');
  }

  void _emitUpdate() {
    final id = _utteranceId;
    if (id == null) return;
    _events.add(TranscriptUpdate(
      utteranceId: id,
      sourceText: _sourceBuffer.toString(),
      translatedText: _translationBuffer.toString(),
      sourceLanguageCode: _sourceLanguageCode,
    ));
  }

  /// Closes the waiting segment with the translation it was holding out for.
  void _finalizeTailWithTranslation(String translation) {
    final id = _tailId;
    if (id == null) return;
    liveTrace('TRANSLATION_TAIL',
        'utterance=$id claimed its ${translation.length}ch translation');
    _events.add(UtteranceFinalized(
      utteranceId: id,
      sourceText: _tailSource.toString().trim(),
      translatedText: translation.trim(),
      sourceLanguageCode: _tailLanguage,
      at: _now(),
    ));
    _clearTail();
  }

  /// Closes the waiting segment without a translation — its translation never
  /// came (the turn ended, or another speaker switched first).
  void _finalizeTail() {
    final id = _tailId;
    if (id == null) return;
    final source = _tailSource.toString().trim();
    if (source.isNotEmpty) {
      liveTrace('TRANSLATION_TAIL', 'utterance=$id closed with no translation');
      _events.add(UtteranceFinalized(
        utteranceId: id,
        sourceText: source,
        translatedText: '',
        sourceLanguageCode: _tailLanguage,
        at: _now(),
      ));
    }
    _clearTail();
  }

  void _clearTail() {
    _tailId = null;
    _tailLanguage = null;
    _tailSource.clear();
  }

  void _finalizePendingUtterance() {
    // The waiting segment is older, so it closes first and keeps its place in
    // the conversation.
    _finalizeTail();
    final id = _utteranceId;
    if (id == null) return;
    final source = _sourceBuffer.toString().trim();
    final translation = _translationBuffer.toString().trim();
    if (source.isNotEmpty || translation.isNotEmpty) {
      _events.add(UtteranceFinalized(
        utteranceId: id,
        sourceText: source,
        translatedText: translation,
        sourceLanguageCode: _sourceLanguageCode,
        at: _now(),
      ));
    }
    _resetUtterance();
  }

  void _resetUtterance() {
    _utteranceId = null;
    _sourceBuffer.clear();
    _translationBuffer.clear();
    _sourceLanguageCode = null;
  }

  // ── Microphone uplink ───────────────────────────────────────────────────────

  void _onMicChunk(Uint8List pcm) {
    _lastChunkAt = _now();
    _micLevel.add(micUiLevel(pcm16Rms(pcm)));
    if (_state != LiveServiceState.listening || !_setupDone) return;
    final gated = _uplinkGated;
    if (gated != _lastGateState) {
      _lastGateState = gated;
      liveTrace(
          gated ? 'MIC_GATE_CLOSED' : 'MIC_GATE_OPEN',
          'playbackActive=$_playbackActive '
          'queuedAudio=$_queuedAudioLabel '
          'sent=$_chunksSent dropped=$_chunksDropped');
    }
    if (gated) {
      // The device is speaking a translation: DROP room audio so the speaker
      // output can't be re-ingested and re-translated in a feedback loop.
      _chunksDropped++;
      liveTraceThrottled('MIC_CHUNK_DROPPED',
          () => 'total=$_chunksDropped (device is speaking)');
      _pendingAudio.clear();
      return;
    }
    _pendingAudio.add(pcm);
    if (_pendingAudio.length < _sendChunkBytes) return;
    final chunk = _pendingAudio.takeBytes();
    final socket = _socket;
    if (socket == null) {
      liveTrace('MIC_CHUNK_DROPPED', 'socket is null');
      return;
    }
    socket.send(jsonEncode({
      'realtimeInput': {
        'audio': {'data': base64Encode(chunk), 'mimeType': 'audio/pcm;rate=16000'},
      },
    }));
    _chunksSent++;
    liveTraceThrottled(
        'MIC_CHUNK_SENT', () => 'total=$_chunksSent bytes=${chunk.length}');
  }

  void _onPlaybackActive(bool active) {
    if (active && !_playbackActive) _playbackActiveSince = _now();
    if (!active) _playbackActiveSince = null;
    _playbackActive = active;
    if (!active) _gateUntil = _now().add(playbackGateTail);
    liveTrace(active ? 'AUDIO_PLAYBACK_START' : 'AUDIO_PLAYBACK_END',
        'queuedAudio=$_queuedAudioLabel');
    _speaking.add(active);
  }

  /// Diagnostics: a periodic health line so a dead native microphone tap (no
  /// chunks arriving at all) is distinguishable from a latched gate or a
  /// silent server.
  void _startHealthTrace() {
    if (!kLiveDiagnostics) return;
    _healthTimer?.cancel();
    _healthTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      final since = _lastChunkAt == null
          ? 'never'
          : '${_now().difference(_lastChunkAt!).inMilliseconds}ms ago';
      liveTrace(
          'HEALTH',
          'state=${_state.name} setupDone=$_setupDone capture=$_captureRunning '
              'socket=${_socket == null ? 'null' : 'open'} lastMicChunk=$since '
              'sent=$_chunksSent dropped=$_chunksDropped '
              'gated=$_uplinkGated playbackActive=$_playbackActive');
    });
  }

  void _onCaptureStopped(String reason) {
    liveTrace('CAPTURE_STOPPED', 'reason=$reason state=${_state.name}');
    _captureRunning = false;
    if (_state == LiveServiceState.idle || _state == LiveServiceState.stopping) return;
    final generation = _generation;
    if (reason == 'notification') {
      // User pressed Stop on the Android notification — clean stop.
      unawaited(stop());
      return;
    }
    if (generation != _generation) return;
    _failSession(LiveErrorKind.fatal, 'Listening stopped: the microphone became unavailable.');
  }

  Future<void> _stopCapture() async {
    if (!_captureRunning) return;
    _captureRunning = false;
    await capture.stop();
    _pendingAudio.clear();
    _micLevel.add(0);
  }

  // ── State helpers ───────────────────────────────────────────────────────────

  void _setState(LiveServiceState next) {
    if (_state == next) return;
    _state = next;
    _stateChanges.add(next);
  }

  void _failSession(LiveErrorKind kind, String message) {
    _generation++;
    liveTrace('SESSION_FAILED', 'kind=${kind.name} sent=$_chunksSent');
    _healthTimer?.cancel();
    _healthTimer = null;
    _setupTimer?.cancel();
    _reconnectTimer?.cancel();
    unawaited(_stopCapture());
    _finalizePendingUtterance();
    unawaited(playback.stop());
    unawaited(_closeSocket());
    _token = null;
    _resumeHandle = null;
    _setState(LiveServiceState.error);
    _events.add(ServiceError(kind, message));
    // Error state is terminal for the session but fully recoverable: the
    // next start() call proceeds from here as if idle.
  }

  Future<void> _closeSocket() async {
    final subscription = _socketSubscription;
    _socketSubscription = null;
    await subscription?.cancel();
    final socket = _socket;
    _socket = null;
    try {
      await socket?.close();
    } catch (_) {
      // Closing an already-dead socket must never surface.
    }
  }
}
