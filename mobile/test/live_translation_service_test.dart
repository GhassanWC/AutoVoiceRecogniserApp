import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:live_translator/services/audio/audio_capture_service.dart';
import 'package:live_translator/services/audio/audio_playback_service.dart';
import 'package:live_translator/services/gemini/live_translation_service.dart';

// ── Fakes ─────────────────────────────────────────────────────────────────────

class FakeSocket implements GeminiSocket {
  final StreamController<dynamic> incoming = StreamController<dynamic>.broadcast();
  final List<String> sent = [];
  bool closed = false;

  @override
  Stream<dynamic> get messages => incoming.stream;

  @override
  void send(String data) => sent.add(data);

  @override
  Future<void> close() async {
    closed = true;
    await incoming.close();
  }

  void serverSends(Map<String, dynamic> message) => incoming.add(jsonEncode(message));

  Future<void> dropConnection() => incoming.close();
}

class FakeCapture extends AudioCaptureService {
  void Function(Uint8List pcm)? onAudio;
  void Function(String reason)? onStopped;
  int startCalls = 0;
  int stopCalls = 0;
  bool running = false;

  @override
  bool get isCapturing => running;

  @override
  Future<void> start({
    required void Function(Uint8List pcm) onAudio,
    required void Function(String reason) onStopped,
  }) async {
    startCalls++;
    running = true;
    this.onAudio = onAudio;
    this.onStopped = onStopped;
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    running = false;
  }
}

class FakePlayback extends AudioPlaybackService {
  final StreamController<bool> active = StreamController<bool>.broadcast();
  final List<Uint8List> fed = [];
  int startCalls = 0;
  int stopCalls = 0;

  @override
  Stream<bool> get playbackActive => active.stream;

  @override
  Future<void> start() async => startCalls++;

  @override
  Future<void> feed(Uint8List pcm) async => fed.add(pcm);

  @override
  Future<void> stop() async => stopCalls++;

  @override
  Future<void> dispose() async => active.close();
}

class Harness {
  Harness({
    List<TokenRequestException?> tokenErrors = const [],
    DateTime? tokenExpiry,
    bool online = false,
  }) {
    var call = 0;
    service = LiveTranslationService(
      isOnline: () async => online,
      tokenProvider: (target) async {
        tokenRequests.add(target);
        final error = call < tokenErrors.length ? tokenErrors[call] : null;
        call++;
        if (error != null) throw error;
        return LiveSessionToken(
          token: 'tok-$call',
          model: 'models/gemini-3.5-live-translate-preview',
          expireTime: tokenExpiry ?? DateTime.now().toUtc().add(const Duration(minutes: 30)),
        );
      },
      connect: (uri) async {
        uris.add(uri);
        final socket = FakeSocket();
        sockets.add(socket);
        return socket;
      },
      capture: capture,
      playback: playback,
      backoffDelays: const [Duration.zero, Duration.zero, Duration.zero],
      playbackGateTail: Duration.zero,
      utteranceIdFactory: () => 'utt-${++utteranceCounter}',
    );
    service.events.listen(events.add);
    service.stateChanges.listen(states.add);
  }

  final FakeCapture capture = FakeCapture();
  final FakePlayback playback = FakePlayback();
  final List<FakeSocket> sockets = [];
  final List<Uri> uris = [];
  final List<String> tokenRequests = [];
  final List<LiveTranslateEvent> events = [];
  final List<LiveServiceState> states = [];
  int utteranceCounter = 0;
  late final LiveTranslationService service;

  FakeSocket get socket => sockets.last;

  Future<void> startListening({bool playAudio = true}) async {
    await service.start(targetLanguageCode: 'ar', playAudio: playAudio);
    socket.serverSends({'setupComplete': {}});
    await pump();
  }

  /// ~100 ms of 16 kHz PCM16 (3200 bytes) so one chunk flushes the coalescer.
  void mic([int filler = 7]) =>
      capture.onAudio!(Uint8List.fromList(List.filled(3200, filler)));

  List<Map<String, dynamic>> sentAudio(FakeSocket s) => [
        for (final frame in s.sent)
          if (jsonDecode(frame) case final Map<String, dynamic> m
              when m.containsKey('realtimeInput'))
            m,
      ];

  Future<void> pump() => Future<void>.delayed(Duration.zero);
}

void main() {
  test('sends the exact Live Translate setup message and starts listening', () async {
    final h = Harness();
    await h.startListening();

    expect(h.tokenRequests, ['ar']);
    expect(h.uris.single.toString(), contains('access_token=tok-1'));
    expect(h.uris.single.toString(),
        startsWith('wss://generativelanguage.googleapis.com/ws/'));

    final setup = jsonDecode(h.socket.sent.first) as Map<String, dynamic>;
    expect(setup['setup']['model'], 'models/gemini-3.5-live-translate-preview');
    final config = setup['setup']['generationConfig'] as Map<String, dynamic>;
    expect(config['responseModalities'], ['AUDIO']);
    expect(config['inputAudioTranscription'], isEmpty);
    expect(config['outputAudioTranscription'], isEmpty);
    expect(config['translationConfig'],
        {'targetLanguageCode': 'ar', 'echoTargetLanguage': true});

    expect(h.service.state, LiveServiceState.listening);
    expect(h.capture.startCalls, 1);
    expect(h.playback.startCalls, 1);
  });

  test('microphone chunks are coalesced to ~100 ms and base64-encoded', () async {
    final h = Harness();
    await h.startListening();

    // Two half-chunks buffer, the second flush sends exactly one message.
    h.capture.onAudio!(Uint8List.fromList(List.filled(1600, 1)));
    expect(h.sentAudio(h.socket), isEmpty);
    h.capture.onAudio!(Uint8List.fromList(List.filled(1600, 2)));
    final audio = h.sentAudio(h.socket);
    expect(audio, hasLength(1));
    final payload = audio.single['realtimeInput']['audio'] as Map<String, dynamic>;
    expect(payload['mimeType'], 'audio/pcm;rate=16000');
    expect(base64Decode(payload['data'] as String), hasLength(3200));
  });

  test('aggregates incremental transcripts into one utterance and finalizes on turnComplete',
      () async {
    final h = Harness();
    await h.startListening();

    h.socket.serverSends({
      'serverContent': {
        'inputTranscription': {'text': 'Hello ', 'languageCode': 'en'}
      }
    });
    h.socket.serverSends({
      'serverContent': {
        'inputTranscription': {'text': 'world'}
      }
    });
    h.socket.serverSends({
      'serverContent': {
        'outputTranscription': {'text': 'مرحبا ', 'languageCode': 'ar'}
      }
    });
    h.socket.serverSends({
      'serverContent': {
        'outputTranscription': {'text': 'بالعالم'}
      }
    });
    h.socket.serverSends({
      'serverContent': {'turnComplete': true}
    });
    await h.pump();

    final updates = h.events.whereType<TranscriptUpdate>().toList();
    expect(updates, isNotEmpty);
    expect(updates.every((u) => u.utteranceId == 'utt-1'), isTrue,
        reason: 'partials must update ONE bubble, never create duplicates');
    expect(updates.last.sourceText, 'Hello world');

    final finalized = h.events.whereType<UtteranceFinalized>().single;
    expect(finalized.utteranceId, 'utt-1');
    expect(finalized.sourceText, 'Hello world');
    expect(finalized.translatedText, 'مرحبا بالعالم');
    expect(finalized.sourceLanguageCode, 'en');

    // Next utterance gets a fresh id.
    h.socket.serverSends({
      'serverContent': {
        'inputTranscription': {'text': 'สวัสดี', 'languageCode': 'th'}
      }
    });
    await h.pump();
    expect(h.events.whereType<TranscriptUpdate>().last.utteranceId, 'utt-2');
  });

  test('a generationComplete followed by turnComplete finalizes only once', () async {
    final h = Harness();
    await h.startListening();
    h.socket.serverSends({
      'serverContent': {
        'inputTranscription': {'text': 'Hi', 'languageCode': 'en'}
      }
    });
    h.socket.serverSends({
      'serverContent': {'generationComplete': true}
    });
    h.socket.serverSends({
      'serverContent': {'turnComplete': true}
    });
    await h.pump();
    expect(h.events.whereType<UtteranceFinalized>(), hasLength(1));
  });

  test('plays translated audio and flushes it when interrupted', () async {
    final h = Harness();
    await h.startListening();

    final pcm = base64Encode(List.filled(480, 3));
    h.socket.serverSends({
      'serverContent': {
        'modelTurn': {
          'parts': [
            {
              'inlineData': {'mimeType': 'audio/pcm;rate=24000', 'data': pcm}
            }
          ]
        }
      }
    });
    await h.pump();
    expect(h.playback.fed.single, hasLength(480));

    h.socket.serverSends({
      'serverContent': {'interrupted': true}
    });
    await h.pump();
    expect(h.playback.stopCalls, greaterThan(0));
  });

  test('half-duplex gate: mic chunks are DROPPED while the device is speaking', () async {
    final h = Harness();
    await h.startListening();

    h.mic();
    expect(h.sentAudio(h.socket), hasLength(1));

    h.playback.active.add(true); // device starts speaking a translation
    await h.pump();
    h.mic();
    h.mic();
    expect(h.sentAudio(h.socket), hasLength(1),
        reason: 'speaker output must never loop back into the translator');

    h.playback.active.add(false);
    await h.pump();
    h.mic();
    expect(h.sentAudio(h.socket), hasLength(2));
  });

  test('quota error from the token service fails immediately with NO retries', () async {
    final h = Harness(tokenErrors: [
      const TokenRequestException(LiveErrorKind.quota, 'quota'),
    ]);
    await h.service.start(targetLanguageCode: 'ar', playAudio: true);
    await h.pump();

    expect(h.service.state, LiveServiceState.error);
    final error = h.events.whereType<ServiceError>().single;
    expect(error.kind, LiveErrorKind.quota);
    expect(h.tokenRequests, hasLength(1), reason: 'quota must never be retried');
    expect(h.sockets, isEmpty);
  });

  test('reconnects with the session-resumption handle after a dropped connection', () async {
    final h = Harness();
    await h.startListening();

    h.socket.serverSends({
      'sessionResumptionUpdate': {'resumable': true, 'newHandle': 'handle-1'}
    });
    await h.pump();

    final first = h.socket;
    await first.dropConnection();
    await h.pump();
    await h.pump();

    expect(h.states, contains(LiveServiceState.reconnecting));
    expect(h.sockets, hasLength(2));
    // Same token (still valid) + the resume handle in the new setup.
    expect(h.uris.last.toString(), contains('access_token=tok-1'));
    final setup = jsonDecode(h.sockets.last.sent.first) as Map<String, dynamic>;
    expect(setup['setup']['sessionResumption'], {'handle': 'handle-1'});

    h.sockets.last.serverSends({'setupComplete': {}});
    await h.pump();
    expect(h.service.state, LiveServiceState.listening);
  });

  test('without a resume handle a reconnect mints a fresh token', () async {
    final h = Harness();
    await h.startListening();
    await h.socket.dropConnection();
    await h.pump();
    await h.pump();

    expect(h.tokenRequests, hasLength(2));
    expect(h.uris.last.toString(), contains('access_token=tok-2'));
  });

  test('exhausted reconnect attempts while OFFLINE end in a recoverable network error',
      () async {
    final h = Harness();
    await h.startListening();

    // Every reconnect socket immediately drops.
    for (var i = 0; i < 4; i++) {
      await h.socket.dropConnection();
      await h.pump();
      await h.pump();
    }

    expect(h.service.state, LiveServiceState.error);
    expect(h.events.whereType<ServiceError>().single.kind, LiveErrorKind.network);
    expect(h.capture.stopCalls, greaterThan(0), reason: 'mic must not stay hot after failure');

    // Error state is recoverable: a fresh start() works.
    await h.service.start(targetLanguageCode: 'ar', playAudio: true);
    h.socket.serverSends({'setupComplete': {}});
    await h.pump();
    expect(h.service.state, LiveServiceState.listening);
  });

  test('exhausted reconnect attempts while ONLINE surface a fatal error, not "no internet"',
      () async {
    final h = Harness(online: true);
    await h.startListening();

    for (var i = 0; i < 4; i++) {
      await h.socket.dropConnection();
      await h.pump();
      await h.pump();
    }

    expect(h.service.state, LiveServiceState.error);
    final error = h.events.whereType<ServiceError>().single;
    expect(error.kind, LiveErrorKind.fatal,
        reason: 'a reachable internet means the failure is NOT connectivity');
    expect(error.message, contains('translation service'));
  });

  test('stop() during a session returns cleanly to idle and stops the mic first', () async {
    final h = Harness();
    await h.startListening();
    h.socket.serverSends({
      'serverContent': {
        'inputTranscription': {'text': 'unfinished', 'languageCode': 'en'}
      }
    });
    await h.pump();

    await h.service.stop();
    expect(h.service.state, LiveServiceState.idle);
    expect(h.capture.stopCalls, 1);
    expect(h.socket.closed, isTrue);
    // The in-flight partial is finalized so its text is not lost.
    expect(h.events.whereType<UtteranceFinalized>().single.sourceText, 'unfinished');
  });

  test('stop() during reconnect backoff cancels the pending attempt', () async {
    final h = Harness();
    await h.startListening();
    await h.socket.dropConnection();
    await h.service.stop();
    await h.pump();
    await h.pump();

    expect(h.service.state, LiveServiceState.idle);
    expect(h.sockets, hasLength(1), reason: 'no reconnect after an explicit stop');
  });

  test('capture stopping via the Android notification stops the whole session', () async {
    final h = Harness();
    await h.startListening();
    h.capture.onStopped!('notification');
    await h.pump();
    expect(h.service.state, LiveServiceState.idle);
  });
}
