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
  int? closeCode;
  @override
  String? closeReason;

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
    Duration setupTimeout = const Duration(seconds: 15),
    Future<GeminiSocket> Function(Uri uri)? connectOverride,
    // Real production tail (300 ms) + a controllable clock let a test prove
    // the half-duplex gate REOPENS instead of latching closed.
    Duration playbackGateTail = Duration.zero,
    DateTime Function()? now,
  }) {
    var call = 0;
    service = LiveTranslationService(
      isOnline: () async => online,
      setupTimeout: setupTimeout,
      now: now,
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
        if (connectOverride != null) return connectOverride(uri);
        final socket = FakeSocket();
        sockets.add(socket);
        return socket;
      },
      capture: capture,
      playback: playback,
      backoffDelays: const [Duration.zero, Duration.zero, Duration.zero],
      playbackGateTail: playbackGateTail,
      utteranceIdFactory: () => 'utt-${++utteranceCounter}',
    );
    service.events.listen(events.add);
    service.stateChanges.listen(states.add);
    // Releases the diagnostics health timer so it cannot leak between tests.
    addTearDown(service.stop);
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
    // Ephemeral tokens with a server-locked setup must use the CONSTRAINED
    // endpoint.
    expect(
        h.uris.single.toString(),
        startsWith('wss://generativelanguage.googleapis.com/ws/'
            'google.ai.generativelanguage.v1beta.GenerativeService.'
            'BidiGenerateContentConstrained?'));

    final setup = jsonDecode(h.socket.sent.first) as Map<String, dynamic>;
    final setupBody = setup['setup'] as Map<String, dynamic>;
    expect(setupBody['model'], 'models/gemini-3.5-live-translate-preview');
    final config = setupBody['generationConfig'] as Map<String, dynamic>;
    expect(config['responseModalities'], ['AUDIO']);
    expect(config['translationConfig'],
        {'targetLanguageCode': 'ar', 'echoTargetLanguage': true});
    // Transcription configs live at the SETUP level, not in generationConfig —
    // the API closes the session right after setup when they are misplaced.
    expect(config.containsKey('inputAudioTranscription'), isFalse);
    expect(config.containsKey('outputAudioTranscription'), isFalse);
    expect(setupBody['inputAudioTranscription'], isEmpty);
    expect(setupBody['outputAudioTranscription'], isEmpty);
    // Present-but-empty on a fresh start; carries the handle on resume.
    expect(setupBody['sessionResumption'], isEmpty);

    expect(h.service.state, LiveServiceState.listening);
    expect(h.capture.startCalls, 1);
    expect(h.playback.startCalls, 1);
  });

  test('no microphone chunks are sent before setupComplete arrives', () async {
    final h = Harness();
    await h.service.start(targetLanguageCode: 'ar', playAudio: true);
    // Connected, setup frame sent — but setupComplete has NOT arrived, so
    // capture is not running yet and nothing may reach the uplink.
    expect(h.capture.startCalls, 0);
    expect(h.socket.sent, hasLength(1),
        reason: 'only the setup frame may be sent before setupComplete');
    expect(jsonDecode(h.socket.sent.single), contains('setup'));

    h.socket.serverSends({'setupComplete': {}});
    await h.pump();
    h.mic();
    expect(h.sentAudio(h.socket), hasLength(1),
        reason: 'audio flows only after setupComplete');

    // The reconnect window is where premature audio is physically possible:
    // capture KEEPS running while the new socket exists and its
    // setupComplete has not yet arrived — the _onMicChunk guard is the only
    // barrier. (Deleting that guard must fail this test.)
    await h.socket.dropConnection();
    await h.pump();
    await h.pump();
    final reconnected = h.sockets.last;
    expect(reconnected, isNot(same(h.sockets.first)));
    h.mic();
    h.mic();
    expect(h.sentAudio(reconnected), isEmpty,
        reason: 'mic chunks must be dropped until the NEW connection has '
            'received setupComplete');
    reconnected.serverSends({'setupComplete': {}});
    await h.pump();
    h.mic();
    expect(h.sentAudio(reconnected), hasLength(1));
  });

  test('setup timeout really closes the stalled socket before reconnecting', () async {
    final h = Harness(setupTimeout: Duration.zero);
    await h.service.start(targetLanguageCode: 'ar', playAudio: true);
    // setupComplete never arrives; the timeout must actually CLOSE the old
    // socket (not just abandon it) and then retry on a fresh connection.
    for (var i = 0; i < 4; i++) {
      await h.pump();
    }
    expect(h.sockets.first.closed, isTrue,
        reason: 'a stalled connection must be closed, not leaked');
    expect(h.sockets.length, greaterThan(1), reason: 'a reconnect follows');
  });

  test('handshake errors never leak the access token', () async {
    final h = Harness(
      online: true,
      connectOverride: (uri) async =>
          throw Exception("Connection to '$uri' was not upgraded to websocket"),
    );
    await h.service.start(targetLanguageCode: 'ar', playAudio: true);
    for (var i = 0; i < 12; i++) {
      await h.pump();
    }
    final error = h.events.whereType<ServiceError>().single;
    expect(error.kind, LiveErrorKind.fatal);
    expect(error.message, isNot(contains('tok-')),
        reason: 'the ephemeral token must never reach user-facing messages');
    expect(error.message, contains('access_token=<redacted>'));
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

  // The multi-turn regression guard: ONE Start Listening must translate an
  // unlimited number of utterances. Exercises the full lifecycle —
  // setupComplete → mic → utterance 1 → translated audio → turnComplete →
  // utterance 2 — with the REAL 300 ms playback tail.
  test('ONE session translates TWO consecutive utterances (no restart)', () async {
    var clock = DateTime.utc(2026, 9, 17, 12);
    final h = Harness(
      playbackGateTail: const Duration(milliseconds: 300),
      now: () => clock,
    );
    await h.startListening();
    final socket = h.socket;
    expect(h.service.state, LiveServiceState.listening);

    // ── Utterance 1 ──────────────────────────────────────────────────────
    h.mic();
    expect(h.sentAudio(socket), hasLength(1), reason: 'mic streams once listening');

    socket.serverSends({
      'serverContent': {
        'inputTranscription': {'text': 'Where is the metro?', 'languageCode': 'en'}
      }
    });
    socket.serverSends({
      'serverContent': {
        'outputTranscription': {'text': 'أين المترو؟'}
      }
    });
    // Translated speech starts playing → the half-duplex gate closes so the
    // speaker output cannot loop back in.
    h.playback.active.add(true);
    await h.pump();
    h.mic();
    expect(h.sentAudio(socket), hasLength(1), reason: 'gated while device speaks');

    socket.serverSends({
      'serverContent': {'turnComplete': true}
    });
    await h.pump();

    final first = h.events.whereType<UtteranceFinalized>().single;
    expect(first.sourceText, 'Where is the metro?');
    expect(first.translatedText, 'أين المترو؟');

    // turnComplete finalizes the bubble ONLY — it must not end the session,
    // stop capture, or close the socket.
    expect(h.service.state, LiveServiceState.listening);
    expect(h.capture.stopCalls, 0, reason: 'microphone must stay hot');
    expect(h.capture.onAudio, isNotNull, reason: 'capture callback still wired');
    expect(socket.closed, isFalse, reason: 'WebSocket must stay open');

    // Translated audio finishes → the 300 ms tail must EXPIRE, never latch.
    h.playback.active.add(false);
    await h.pump();
    h.mic();
    expect(h.sentAudio(socket), hasLength(1), reason: 'still inside the 300ms tail');
    clock = clock.add(const Duration(milliseconds: 301));
    h.mic();
    expect(h.sentAudio(socket), hasLength(2),
        reason: 'the gate MUST reopen once the tail elapses');

    // ── Utterance 2 (same session) ───────────────────────────────────────
    socket.serverSends({
      'serverContent': {
        'inputTranscription': {'text': 'How much is the ticket?', 'languageCode': 'en'}
      }
    });
    socket.serverSends({
      'serverContent': {
        'outputTranscription': {'text': 'كم سعر التذكرة؟'}
      }
    });
    socket.serverSends({
      'serverContent': {'turnComplete': true}
    });
    await h.pump();

    final finalized = h.events.whereType<UtteranceFinalized>().toList();
    expect(finalized, hasLength(2), reason: 'the SECOND utterance must finalize too');
    expect(finalized[1].sourceText, 'How much is the ticket?');
    expect(finalized[1].translatedText, 'كم سعر التذكرة؟');
    expect(finalized[1].utteranceId, isNot(finalized[0].utteranceId),
        reason: 'buffers reset → utterance 2 gets its own bubble');

    // One session start to finish: no new token, no new socket, no restart.
    expect(h.tokenRequests, hasLength(1));
    expect(h.sockets, hasLength(1));
    expect(h.service.state, LiveServiceState.listening);
  });

  test('a latched "still speaking" claim cannot gate the microphone forever',
      () async {
    var clock = DateTime.utc(2026, 9, 17, 12);
    final h = Harness(
      playbackGateTail: const Duration(milliseconds: 300),
      now: () => clock,
    );
    await h.startListening();
    final socket = h.socket;

    // The model sends 1 second of translated audio (24 kHz PCM16 = 48 000 B).
    socket.serverSends({
      'serverContent': {
        'modelTurn': {
          'parts': [
            {
              'inlineData': {
                'mimeType': 'audio/pcm;rate=24000',
                'data': base64Encode(List.filled(48000, 1)),
              }
            }
          ]
        }
      }
    });
    await h.pump();

    // The native player reports "speaking" and then NEVER reports the end —
    // a lost completion callback (engine reconfiguration / route change).
    h.playback.active.add(true);
    await h.pump();
    h.mic();
    expect(h.sentAudio(socket), isEmpty,
        reason: 'gated while the queued audio can still be playing');

    // Past the hard ceiling the claim is stale and the microphone MUST
    // resume even though playbackActive is still true.
    clock = clock.add(const Duration(seconds: 12));
    h.mic();
    expect(h.sentAudio(socket), hasLength(1),
        reason: 'a stuck playback claim must never latch the microphone off');
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
