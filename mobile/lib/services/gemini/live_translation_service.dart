import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../utils/mic_level.dart';
import '../audio/audio_capture_service.dart';
import '../audio/audio_playback_service.dart';

/// Connection lifecycle of one live translation session.
enum LiveServiceState { idle, connecting, listening, reconnecting, stopping, error }

/// User-facing error categories (each maps to specific UI copy).
enum LiveErrorKind { quota, network, auth, fatal }

/// Ephemeral credential minted by the Cloud Function.
class LiveSessionToken {
  const LiveSessionToken({required this.token, required this.model, required this.expireTime});
  final String token;
  final String model;
  final DateTime expireTime;
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

/// The utterance is complete — this is what gets persisted.
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
  })  : _tokenProvider = tokenProvider,
        _connect = connect ?? defaultSocketConnector,
        capture = capture ?? AudioCaptureService(),
        playback = playback ?? AudioPlaybackService(),
        _newUtteranceId = utteranceIdFactory ?? (() => const Uuid().v4()),
        _now = now ?? DateTime.now {
    _playbackSubscription = this.playback.playbackActive.listen(_onPlaybackActive);
  }

  static const String websocketBase =
      'wss://generativelanguage.googleapis.com/ws/'
      'google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent';

  /// ~100 ms of 16 kHz mono PCM16.
  static const int _sendChunkBytes = 3200;

  final TokenProvider _tokenProvider;
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
  bool _playAudio = true;
  bool _setupDone = false;
  bool _captureRunning = false;
  int _reconnectAttempts = 0;
  String? _resumeHandle;

  // Current-utterance aggregation.
  String? _utteranceId;
  final StringBuffer _sourceBuffer = StringBuffer();
  final StringBuffer _translationBuffer = StringBuffer();
  String? _sourceLanguageCode;

  // Half-duplex gate.
  bool _playbackActive = false;
  DateTime _gateUntil = DateTime.fromMillisecondsSinceEpoch(0);
  final BytesBuilder _pendingAudio = BytesBuilder(copy: true);

  bool get _uplinkGated => _playbackActive || _now().isBefore(_gateUntil);

  // ── Public API ──────────────────────────────────────────────────────────────

  /// Starts a session translating into [targetLanguageCode] (BCP-47, already
  /// mapped through geminiCodeFor). Microphone capture must be permitted
  /// beforehand — permission UX is the controller's job.
  Future<void> start({required String targetLanguageCode, required bool playAudio}) async {
    if (_state != LiveServiceState.idle && _state != LiveServiceState.error) return;
    final generation = ++_generation;
    _targetLanguageCode = targetLanguageCode;
    _playAudio = playAudio;
    _reconnectAttempts = 0;
    _resumeHandle = null;
    _resetUtterance();
    _setState(LiveServiceState.connecting);

    final LiveSessionToken token;
    try {
      token = await _tokenProvider(targetLanguageCode);
    } on TokenRequestException catch (e) {
      if (generation != _generation) return;
      _failSession(e.kind, e.message);
      return;
    } catch (e) {
      if (generation != _generation) return;
      _failSession(LiveErrorKind.network, '$e');
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
    if (_state == LiveServiceState.idle) return;
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
    try {
      final socket = await _connect(Uri.parse('$websocketBase?access_token=${token.token}'));
      if (generation != _generation) {
        await socket.close();
        return;
      }
      _socket = socket;
      _socketSubscription = socket.messages.listen(
        (dynamic frame) => _onFrame(generation, frame),
        onError: (Object _) => _onSocketClosed(generation),
        onDone: () => _onSocketClosed(generation),
        cancelOnError: true,
      );
      socket.send(jsonEncode(_setupMessage(token.model, resuming: resuming)));
      _setupTimer?.cancel();
      _setupTimer = Timer(setupTimeout, () {
        if (generation != _generation || _setupDone) return;
        _onSocketClosed(generation);
      });
    } catch (_) {
      if (generation != _generation) return;
      await _handleConnectionLoss(generation);
    }
  }

  Map<String, dynamic> _setupMessage(String model, {required bool resuming}) => {
        'setup': {
          'model': model,
          'generationConfig': {
            'responseModalities': ['AUDIO'],
            'inputAudioTranscription': <String, dynamic>{},
            'outputAudioTranscription': <String, dynamic>{},
            'translationConfig': {
              'targetLanguageCode': _targetLanguageCode,
              'echoTargetLanguage': true,
            },
          },
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
    if (_playAudio) await playback.start();
    if (generation != _generation) return;
    _setState(LiveServiceState.listening);
  }

  void _onSocketClosed(int generation) {
    if (generation != _generation) return;
    _socketSubscription?.cancel();
    _socketSubscription = null;
    _socket = null;
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
      _failSession(LiveErrorKind.network,
          'Connection to the translation service was lost. Check your internet connection and try again.');
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
      } catch (_) {
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
    final Map<String, dynamic> message;
    try {
      message = jsonDecode(text) as Map<String, dynamic>;
    } catch (_) {
      return;
    }

    if (message.containsKey('setupComplete')) {
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
    if (content is! Map) return;

    if (content['interrupted'] == true) {
      unawaited(playback.stop());
    }

    final input = content['inputTranscription'];
    if (input is Map) {
      final text = input['text'];
      if (text is String && text.isNotEmpty) {
        _utteranceId ??= _newUtteranceId();
        _sourceBuffer.write(text);
        final language = input['languageCode'];
        if (language is String && language.isNotEmpty) {
          _sourceLanguageCode ??= language;
        }
        _emitUpdate();
      }
    }

    final output = content['outputTranscription'];
    if (output is Map) {
      final text = output['text'];
      if (text is String && text.isNotEmpty) {
        _utteranceId ??= _newUtteranceId();
        _translationBuffer.write(text);
        _emitUpdate();
      }
    }

    final modelTurn = content['modelTurn'];
    if (_playAudio && modelTurn is Map) {
      final parts = modelTurn['parts'];
      if (parts is List) {
        for (final part in parts) {
          if (part is! Map) continue;
          final inline = part['inlineData'];
          if (inline is! Map) continue;
          final mime = inline['mimeType'];
          final data = inline['data'];
          if (data is String && (mime is! String || mime.startsWith('audio/pcm'))) {
            try {
              unawaited(playback.feed(base64Decode(data)));
            } catch (_) {
              // Malformed audio chunk — skip; transcripts are unaffected.
            }
          }
        }
      }
    }

    if (content['turnComplete'] == true || content['generationComplete'] == true) {
      // generationComplete arrives before turnComplete for the same turn;
      // finalizing on the first of the two and resetting makes the second
      // a no-op (buffers empty).
      _finalizePendingUtterance();
    }
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

  void _finalizePendingUtterance() {
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
    _micLevel.add(micUiLevel(pcm16Rms(pcm)));
    if (_state != LiveServiceState.listening || !_setupDone) return;
    if (_uplinkGated) {
      // The device is speaking a translation: DROP room audio so the speaker
      // output can't be re-ingested and re-translated in a feedback loop.
      _pendingAudio.clear();
      return;
    }
    _pendingAudio.add(pcm);
    if (_pendingAudio.length < _sendChunkBytes) return;
    final chunk = _pendingAudio.takeBytes();
    final socket = _socket;
    if (socket == null) return;
    socket.send(jsonEncode({
      'realtimeInput': {
        'audio': {'data': base64Encode(chunk), 'mimeType': 'audio/pcm;rate=16000'},
      },
    }));
  }

  void _onPlaybackActive(bool active) {
    _playbackActive = active;
    if (!active) _gateUntil = _now().add(playbackGateTail);
    _speaking.add(active);
  }

  void _onCaptureStopped(String reason) {
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
