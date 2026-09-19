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

  /// Audio actually handed to the speaker. Must stay EMPTY unless the user
  /// explicitly replayed a translation.
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

/// Records the lease handover, standing in for the usage meter.
class RecordingObserver implements LiveSessionObserver {
  final List<String> log = [];

  /// Runs inside onLeaseEnding, so a test can see what had happened by then.
  void Function()? onEnding;
  int? tokenRequestsAtSettle;

  @override
  void onConnected() => log.add('connected');
  @override
  void onDisconnected() => log.add('disconnected');
  @override
  void onMicAudio({
    required double rms,
    required Duration duration,
    required bool gated,
    required bool sentUpstream,
  }) {}
  @override
  void onTranslatedText() => log.add('translated');
  @override
  void onUtteranceTranslated() => log.add('utterance');
  @override
  Future<void> onLeaseEnding() async {
    log.add('leaseEnding');
    onEnding?.call();
  }

  @override
  void onLeaseStarted(String? sessionId) => log.add('leaseStarted:$sessionId');
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
    Duration leaseRenewalMargin = const Duration(seconds: 30),
    this.observer,
  }) {
    var call = 0;
    service = LiveTranslationService(
      isOnline: () async => online,
      setupTimeout: setupTimeout,
      leaseRenewalMargin: leaseRenewalMargin,
      now: now,
      tokenProvider: (target) async {
        tokenRequests.add(target);
        final error = call < tokenErrors.length ? tokenErrors[call] : null;
        call++;
        if (error != null) throw error;
        return LiveSessionToken(
          token: 'tok-$call',
          model: 'models/gemini-3.5-live-translate-preview',
          // Each lease carries its own metered session id.
          sessionId: 'session-$call',
          expireTime: tokenExpiry ??
              DateTime.now().toUtc().add(const Duration(minutes: 5)),
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
    service.observer = observer;
    service.events.listen(events.add);
    service.stateChanges.listen(states.add);
    // Releases the diagnostics health timer so it cannot leak between tests.
    addTearDown(service.stop);
  }

  /// Accounting seam, so lease handover can be observed.
  final LiveSessionObserver? observer;

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

  Future<void> startListening() async {
    await service.start(targetLanguageCode: 'ar');
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
    // Playback is NOT armed with the session — nothing plays until the user
    // taps a message's speaker button.
    expect(h.playback.startCalls, 0);
  });

  test('no microphone chunks are sent before setupComplete arrives', () async {
    final h = Harness();
    await h.service.start(targetLanguageCode: 'ar');
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
    await h.service.start(targetLanguageCode: 'ar');
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
    await h.service.start(targetLanguageCode: 'ar');
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

  // THE continuous-translation guard. Translated audio arriving used to be
  // played automatically, which gated the microphone and left the session
  // deaf after the first utterance. Five turns, each carrying audio, must all
  // translate on ONE session with the microphone streaming throughout.
  test('ONE session translates FIVE consecutive utterances while audio arrives',
      () async {
    var clock = DateTime.utc(2026, 9, 18, 9);
    final h = Harness(
      playbackGateTail: const Duration(milliseconds: 300),
      now: () => clock,
    );
    await h.startListening();
    final socket = h.socket;

    const phrases = [
      ('Where is the metro?', 'أين المترو؟'),
      ('How much is the ticket?', 'كم سعر التذكرة؟'),
      ('Does it stop at the museum?', 'هل يتوقف عند المتحف؟'),
      ('When is the last train?', 'متى آخر قطار؟'),
      ('Thank you very much', 'شكرا جزيلا'),
    ];

    for (var turn = 0; turn < phrases.length; turn++) {
      final (source, translation) = phrases[turn];

      // The user speaks: microphone chunks must reach Gemini every turn.
      final sentBefore = h.sentAudio(socket).length;
      h.mic();
      expect(h.sentAudio(socket), hasLength(sentBefore + 1),
          reason: 'microphone must still stream on turn ${turn + 1}');

      socket.serverSends({
        'serverContent': {
          'inputTranscription': {'text': source, 'languageCode': 'en'}
        }
      });
      socket.serverSends({
        'serverContent': {
          'outputTranscription': {'text': translation}
        }
      });
      // Gemini also sends the spoken translation (1 s of 24 kHz PCM16). It
      // must be collected, never played, and never touch the uplink gate.
      socket.serverSends({
        'serverContent': {
          'modelTurn': {
            'parts': [
              {
                'inlineData': {
                  'mimeType': 'audio/pcm;rate=24000',
                  'data': base64Encode(List.filled(48000, turn + 1)),
                }
              }
            ]
          }
        }
      });
      socket.serverSends({
        'serverContent': {'turnComplete': true}
      });
      await h.pump();

      expect(h.playback.startCalls, 0,
          reason: 'translated audio must never start playback by itself');
      expect(h.playback.fed, isEmpty,
          reason: 'translated audio must never be auto-played');
      expect(h.service.state, LiveServiceState.listening,
          reason: 'still listening after turn ${turn + 1}');
      expect(h.capture.stopCalls, 0, reason: 'microphone must stay hot');

      // Time passes between utterances exactly as it would in the room.
      clock = clock.add(const Duration(seconds: 3));
    }

    final finalized = h.events.whereType<UtteranceFinalized>().toList();
    expect(finalized, hasLength(5), reason: 'all five utterances translated');
    for (var i = 0; i < phrases.length; i++) {
      expect(finalized[i].sourceText, phrases[i].$1);
      expect(finalized[i].translatedText, phrases[i].$2);
    }
    // Gemini's audio was received and thrown away — the device synthesizer
    // speaks translations instead, so nothing is buffered or played.
    expect(h.playback.fed, isEmpty);
    expect(h.playback.startCalls, 0);
    expect(finalized.map((e) => e.utteranceId).toSet(), hasLength(5),
        reason: 'every utterance gets its own bubble');

    // One uninterrupted session start to finish.
    expect(h.tokenRequests, hasLength(1));
    expect(h.sockets, hasLength(1));
    expect(h.capture.startCalls, 1);
    expect(h.service.state, LiveServiceState.listening);
  });

  test('translated audio arriving never gates the microphone', () async {
    var clock = DateTime.utc(2026, 9, 18, 9);
    final h = Harness(
      playbackGateTail: const Duration(milliseconds: 300),
      now: () => clock,
    );
    await h.startListening();
    final socket = h.socket;

    // 10 seconds of translated audio lands at once.
    for (var i = 0; i < 10; i++) {
      socket.serverSends({
        'serverContent': {
          'modelTurn': {
            'parts': [
              {
                'inlineData': {
                  'mimeType': 'audio/pcm;rate=24000',
                  'data': base64Encode(List.filled(48000, 5)),
                }
              }
            ]
          }
        }
      });
    }
    await h.pump();

    // Not a millisecond of gating: the uplink is unaffected, and nothing was
    // handed to the speaker.
    h.mic();
    expect(h.sentAudio(socket), hasLength(1));
    clock = clock.add(const Duration(milliseconds: 1));
    h.mic();
    expect(h.sentAudio(socket), hasLength(2));
    expect(h.playback.fed, isEmpty);
    expect(h.playback.startCalls, 0);
  });

  test('speaking a translation quiets the uplink, then the microphone resumes',
      () async {
    var clock = DateTime.utc(2026, 9, 18, 9);
    final h = Harness(now: () => clock);
    await h.startListening();
    final socket = h.socket;

    // The device synthesizer starts: the uplink goes quiet so the spoken
    // translation cannot be picked up and re-translated.
    h.service.gateUplinkForSpeech(const Duration(seconds: 3));
    h.mic();
    expect(h.sentAudio(socket), isEmpty, reason: 'quiet while speaking');

    // The session itself is untouched throughout.
    expect(h.service.state, LiveServiceState.listening);
    expect(h.capture.stopCalls, 0);
    expect(socket.closed, isFalse);

    // The synthesizer reports it finished early — the microphone resumes at
    // once rather than waiting out the estimate.
    h.service.releaseSpeechGate();
    h.mic();
    expect(h.sentAudio(socket), hasLength(1),
        reason: 'microphone resumes the moment speech ends');

    // And the gate expires by itself even if that signal never arrives.
    h.service.gateUplinkForSpeech(const Duration(seconds: 3));
    h.mic();
    expect(h.sentAudio(socket), hasLength(1));
    clock = clock.add(const Duration(seconds: 4));
    h.mic();
    expect(h.sentAudio(socket), hasLength(2),
        reason: 'a speech gate can never latch the microphone off');
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

  // ── Source-language segmentation ──────────────────────────────────────────
  //
  // Gemini reports the detected source language per input transcription. A
  // change there means a different speaker, and must open a NEW bubble — even
  // mid-turn, before any turnComplete. Previously the first language latched
  // for the whole turn, so a Thai speaker's words were appended to the Hindi
  // speaker's bubble and inherited the Hindi flag.

  void sendSource(Harness h, String text, String? language) {
    h.socket.serverSends({
      'serverContent': {
        'inputTranscription': {
          'text': text,
          if (language != null) 'languageCode': language,
        }
      }
    });
  }

  void sendTranslation(Harness h, String text) {
    h.socket.serverSends({
      'serverContent': {
        'outputTranscription': {'text': text}
      }
    });
  }

  test('a Hindi utterance produces ONE Hindi-owned bubble', () async {
    final h = Harness();
    await h.startListening();

    sendSource(h, 'मेट्रो कहाँ है', 'hi-IN');
    sendTranslation(h, 'أين المترو؟');
    h.socket.serverSends({
      'serverContent': {'turnComplete': true}
    });
    await h.pump();

    final finalized = h.events.whereType<UtteranceFinalized>().single;
    expect(finalized.sourceText, 'मेट्रो कहाँ है');
    expect(finalized.translatedText, 'أين المترو؟');
    expect(finalized.sourceLanguageCode, 'hi');
  });

  test('two chunks of the SAME language stay in one utterance', () async {
    final h = Harness();
    await h.startListening();

    // Same language, once tagged regionally and once bare: normalized, these
    // are the same speaker, so they must not split.
    sendSource(h, 'मेट्रो ', 'hi-IN');
    sendSource(h, 'कहाँ है', 'hi');
    await h.pump();

    final updates = h.events.whereType<TranscriptUpdate>().toList();
    expect(updates.map((u) => u.utteranceId).toSet(), hasLength(1),
        reason: 'hi and hi-IN are the same language');
    expect(updates.last.sourceText, 'मेट्रो कहाँ है');
    expect(h.events.whereType<UtteranceFinalized>(), isEmpty,
        reason: 'no boundary was crossed');
  });

  test('Thai after Hindi opens a NEW bubble and never touches the Hindi one',
      () async {
    final h = Harness();
    await h.startListening();

    sendSource(h, 'मेट्रो कहाँ है', 'hi-IN');
    sendTranslation(h, 'أين المترو؟');
    await h.pump();

    // A different source language mid-turn — no turnComplete in sight.
    sendSource(h, 'รถไฟฟ้าอยู่ที่ไหน', 'th-TH');
    sendTranslation(h, 'أين القطار؟');
    await h.pump();

    // The Hindi utterance was closed at the switch, with ONLY its own text.
    final hindi = h.events.whereType<UtteranceFinalized>().single;
    expect(hindi.sourceLanguageCode, 'hi');
    expect(hindi.sourceText, 'मेट्रो कहाँ है');
    expect(hindi.translatedText, 'أين المترو؟');
    expect(hindi.sourceText, isNot(contains('รถไฟฟ้า')),
        reason: 'Thai speech must never land in the Hindi bubble');
    expect(hindi.translatedText, isNot(contains('القطار')),
        reason: "Thai's translation must not extend the Hindi bubble");

    // The Thai one is a different utterance carrying the Thai language.
    final thai = h.events.whereType<TranscriptUpdate>().last;
    expect(thai.utteranceId, isNot(hindi.utteranceId));
    expect(thai.sourceLanguageCode, 'th');
    expect(thai.sourceText, 'รถไฟฟ้าอยู่ที่ไหน');
    expect(thai.translatedText, 'أين القطار؟');
  });

  test('Hindi → Thai → English produces three language-owned bubbles', () async {
    final h = Harness();
    await h.startListening();

    sendSource(h, 'नमस्ते', 'hi-IN');
    sendTranslation(h, 'مرحبا');
    sendSource(h, 'สวัสดี', 'th-TH');
    sendTranslation(h, 'أهلا');
    sendSource(h, 'Good morning', 'en-US');
    sendTranslation(h, 'صباح الخير');
    h.socket.serverSends({
      'serverContent': {'turnComplete': true}
    });
    await h.pump();

    final finalized = h.events.whereType<UtteranceFinalized>().toList();
    expect(finalized, hasLength(3));
    expect(finalized.map((e) => e.sourceLanguageCode), ['hi', 'th', 'en']);
    expect(finalized.map((e) => e.sourceText), ['नमस्ते', 'สวัสดี', 'Good morning']);
    expect(finalized.map((e) => e.translatedText),
        ['مرحبا', 'أهلا', 'صباح الخير']);
    expect(finalized.map((e) => e.utteranceId).toSet(), hasLength(3),
        reason: 'each language segment owns its own bubble');
  });

  // THE race: Gemini's translation lags its input, so a segment's translation
  // can arrive AFTER the next speaker's source text has already opened a new
  // segment. Routing translation to "whichever utterance is open" put the
  // first speaker's words into the second speaker's bubble — and finalized the
  // first bubble with an empty translation.
  test('a delayed translation goes to the speaker who produced it, not to the '
      'speaker who is talking now', () async {
    final h = Harness();
    await h.startListening();

    // 1. Hindi source.
    sendSource(h, 'मेट्रो कहाँ है', 'hi-IN');
    await h.pump();
    // 2. Thai source arrives BEFORE Hindi's translation.
    sendSource(h, 'รถไฟฟ้าอยู่ที่ไหน', 'th-TH');
    await h.pump();
    // 3. Hindi's translation finally arrives — while Thai is the open segment.
    sendTranslation(h, 'أين المترو؟');
    await h.pump();
    // 4. Thai's own translation.
    sendTranslation(h, 'أين القطار؟');
    h.socket.serverSends({
      'serverContent': {'turnComplete': true}
    });
    await h.pump();

    final finalized = h.events.whereType<UtteranceFinalized>().toList();
    expect(finalized, hasLength(2));

    final hindi = finalized[0];
    final thai = finalized[1];

    // The Hindi bubble keeps its own source AND its own translation.
    expect(hindi.sourceLanguageCode, 'hi');
    expect(hindi.sourceText, 'मेट्रो कहाँ है');
    expect(hindi.translatedText, 'أين المترو؟',
        reason: 'the delayed translation belongs to the Hindi speaker');

    // The Thai bubble has ONLY Thai content.
    expect(thai.sourceLanguageCode, 'th');
    expect(thai.sourceText, 'รถไฟฟ้าอยู่ที่ไหน');
    expect(thai.translatedText, 'أين القطار؟');
    expect(thai.translatedText, isNot(contains('المترو')),
        reason: "the Hindi speaker's translation must never land in Thai");

    // Two distinct bubbles, neither relabelled.
    expect(hindi.utteranceId, isNot(thai.utteranceId));
  });

  test('a delayed translation does not steal the next speaker\'s translation '
      'when the first speaker was already translated', () async {
    final h = Harness();
    await h.startListening();

    // The common clean case: Hindi is fully translated before Thai starts.
    sendSource(h, 'नमस्ते', 'hi-IN');
    sendTranslation(h, 'مرحبا');
    await h.pump();
    sendSource(h, 'สวัสดี', 'th-TH');
    sendTranslation(h, 'أهلا');
    h.socket.serverSends({
      'serverContent': {'turnComplete': true}
    });
    await h.pump();

    final finalized = h.events.whereType<UtteranceFinalized>().toList();
    expect(finalized, hasLength(2));
    // Neither bubble borrows the other's translation.
    expect(finalized[0].translatedText, 'مرحبا');
    expect(finalized[1].translatedText, 'أهلا');
  });

  // KNOWN LIMITATION, pinned deliberately.
  //
  // When the first speaker's translation had ALREADY started before the
  // switch, the remainder of it is indistinguishable from the start of the
  // next speaker's translation: both appear as "one translation chunk right
  // after a language switch", and Live Translate attaches no segment marker
  // to outputTranscription. Claiming that chunk for the previous speaker
  // would break the far more common clean case (first speaker fully
  // translated, then the next speaks) by stealing the NEW speaker's first
  // words — see the test above. So the remainder goes to the open segment.
  //
  // The source text is still correctly split, and both flags stay right; only
  // the tail of an already-started translation can land one bubble late.
  test('LIMITATION: the tail of an already-started translation follows the '
      'open segment', () async {
    final h = Harness();
    await h.startListening();

    sendSource(h, 'मेट्रो कहाँ है', 'hi-IN');
    sendTranslation(h, 'أين '); // Hindi translation STARTS
    await h.pump();
    sendSource(h, 'รถไฟฟ้าอยู่ที่ไหน', 'th-TH'); // switch
    sendTranslation(h, 'المترو؟'); // remainder of the HINDI translation
    sendTranslation(h, 'أين القطار؟'); // Thai's own translation
    h.socket.serverSends({
      'serverContent': {'turnComplete': true}
    });
    await h.pump();

    final finalized = h.events.whereType<UtteranceFinalized>().toList();
    expect(finalized, hasLength(2));

    // The split of SOURCE speech and the flags are still exactly right.
    expect(finalized[0].sourceLanguageCode, 'hi');
    expect(finalized[0].sourceText, 'मेट्रो कहाँ है');
    expect(finalized[1].sourceLanguageCode, 'th');
    expect(finalized[1].sourceText, 'รถไฟฟ้าอยู่ที่ไหน');

    // But the Hindi bubble keeps only the part translated before the switch,
    // and the remainder is attributed to the open (Thai) segment.
    expect(finalized[0].translatedText, 'أين');
    expect(finalized[1].translatedText, 'المترو؟أين القطار؟');
  });

  test('a speaker who never gets a translation still closes as their own '
      'bubble', () async {
    final h = Harness();
    await h.startListening();

    sendSource(h, 'नमस्ते', 'hi-IN');
    await h.pump();
    sendSource(h, 'สวัสดี', 'th-TH'); // Hindi still has no translation
    await h.pump();
    h.socket.serverSends({
      'serverContent': {'turnComplete': true}
    });
    await h.pump();

    final finalized = h.events.whereType<UtteranceFinalized>().toList();
    expect(finalized, hasLength(2));
    expect(finalized[0].sourceLanguageCode, 'hi');
    expect(finalized[0].sourceText, 'नमस्ते');
    expect(finalized[0].translatedText, isEmpty);
    expect(finalized[1].sourceLanguageCode, 'th');
    expect(finalized[1].sourceText, 'สวัสดี');
  });

  test('a late event cannot relabel an already-closed bubble', () async {
    final h = Harness();
    await h.startListening();

    sendSource(h, 'नमस्ते', 'hi-IN');
    sendSource(h, 'สวัสดี', 'th-TH'); // closes the Hindi segment for source
    await h.pump();

    // More Thai keeps arriving, and then the turn ends.
    sendSource(h, ' ครับ', 'th-TH');
    h.socket.serverSends({
      'serverContent': {'turnComplete': true}
    });
    await h.pump();

    final finalized = h.events.whereType<UtteranceFinalized>().toList();
    expect(finalized, hasLength(2));
    final hindi = finalized.firstWhere((e) => e.sourceLanguageCode == 'hi');
    final thai = finalized.firstWhere((e) => e.sourceLanguageCode == 'th');

    // Nothing that arrived after the switch changed the Hindi bubble's
    // language or text — its language is assigned once, at creation.
    expect(hindi.sourceLanguageCode, 'hi',
        reason: 'a closed bubble is immutable');
    expect(hindi.sourceText, 'नमस्ते');
    expect(hindi.sourceText, isNot(contains('สวัสดี')));
    expect(thai.sourceText, 'สวัสดี ครับ');
  });

  test('an utterance opened by translation adopts the first language reported',
      () async {
    final h = Harness();
    await h.startListening();

    // Translation lands before any source transcription (wire order is not
    // guaranteed) — this must NOT create a second bubble.
    sendTranslation(h, 'مرحبا');
    sendSource(h, 'नमस्ते', 'hi-IN');
    await h.pump();

    final updates = h.events.whereType<TranscriptUpdate>().toList();
    expect(updates.map((u) => u.utteranceId).toSet(), hasLength(1));
    expect(updates.last.sourceLanguageCode, 'hi');
    expect(updates.last.translatedText, 'مرحبا');
    expect(h.events.whereType<UtteranceFinalized>(), isEmpty);
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

  test('Gemini translated audio is received and discarded, never played',
      () async {
    final h = Harness();
    await h.startListening();

    void sendAudio(int bytes) => h.socket.serverSends({
          'serverContent': {
            'modelTurn': {
              'parts': [
                {
                  'inlineData': {
                    'mimeType': 'audio/pcm;rate=24000',
                    'data': base64Encode(List.filled(bytes, 3)),
                  }
                }
              ]
            }
          }
        });

    // Live Translate emits AUDIO because the ephemeral token locks that
    // modality. The transcript is used; the audio is dropped on the floor.
    h.socket.serverSends({
      'serverContent': {
        'inputTranscription': {'text': 'Hello', 'languageCode': 'en'}
      }
    });
    h.socket.serverSends({
      'serverContent': {
        'outputTranscription': {'text': 'مرحبا'}
      }
    });
    sendAudio(48000);
    sendAudio(48000);
    h.socket.serverSends({
      'serverContent': {'turnComplete': true}
    });
    await h.pump();

    final finalized = h.events.whereType<UtteranceFinalized>().single;
    expect(finalized.translatedText, 'مرحبا',
        reason: 'the TEXT is what the device synthesizer will speak');
    expect(h.playback.fed, isEmpty, reason: 'never routed to the speaker');
    expect(h.playback.startCalls, 0, reason: 'the player is never even armed');

    // And the microphone was never gated by any of it.
    h.mic();
    expect(h.sentAudio(h.socket), hasLength(1));
    expect(h.service.state, LiveServiceState.listening);
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
    await h.service.start(targetLanguageCode: 'ar');
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
    // A FRESH lease, because tokens are single-use: the old one could not
    // open a second connection however much of its five minutes remains.
    // The resume handle, not the token, is what continues the conversation.
    expect(h.uris.last.toString(), contains('access_token=tok-2'));
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
    await h.service.start(targetLanguageCode: 'ar');
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

  // ── Gemini lease ──────────────────────────────────────────────────────────
  //
  // The lease is a COST AND SECURITY bound: a token is single-use and good
  // for at most five minutes, so a long conversation renews several times.
  // None of that is customer usage — a lease spent in silence costs nothing.

  test('an expiring lease is replaced without interrupting the session',
      () async {
    final recorder = RecordingObserver();
    final h = Harness(
      observer: recorder,
      leaseRenewalMargin: Duration.zero,
      tokenExpiry: DateTime.now().toUtc().add(const Duration(milliseconds: 250)),
    );
    await h.startListening();
    expect(h.tokenRequests, hasLength(1));
    final statesBefore = h.states.length;

    await Future<void>.delayed(const Duration(milliseconds: 400));
    await h.pump();
    h.sockets.last.serverSends({'setupComplete': {}});
    await h.pump();

    // A second lease, on a second connection.
    expect(h.tokenRequests, hasLength(2));
    expect(h.sockets, hasLength(2));
    expect(h.uris.last.toString(), contains('access_token=tok-2'));
    // The session never wavered: still listening, microphone never stopped,
    // and the UI saw no state change at all.
    expect(h.service.state, LiveServiceState.listening);
    expect(h.capture.stopCalls, 0);
    expect(h.capture.startCalls, 1);
    expect(h.states.length, statesBefore);
    expect(h.events.whereType<ServiceError>(), isEmpty);
  });

  test('accounting settles the old lease BEFORE the new one is requested',
      () async {
    // This ordering is what lets the server refuse a renewal to an account
    // that has just run out.
    final recorder = RecordingObserver();
    final h = Harness(
      observer: recorder,
      leaseRenewalMargin: Duration.zero,
      tokenExpiry: DateTime.now().toUtc().add(const Duration(milliseconds: 250)),
    );
    recorder.onEnding = () => recorder.tokenRequestsAtSettle = h.tokenRequests.length;
    await h.startListening();

    await Future<void>.delayed(const Duration(milliseconds: 400));
    await h.pump();

    expect(recorder.log, contains('leaseEnding'));
    expect(recorder.log.indexOf('leaseEnding'),
        lessThan(recorder.log.indexOf('leaseStarted:session-2')));
    // Only the first lease had been requested when the settle ran.
    expect(recorder.tokenRequestsAtSettle, 1);
    // Each lease hands accounting its own metered session id.
    expect(recorder.log.where((e) => e.startsWith('leaseStarted:')),
        ['leaseStarted:session-1', 'leaseStarted:session-2']);
  });

  test('a renewal resumes the same Gemini session rather than starting one',
      () async {
    final h = Harness(
      leaseRenewalMargin: Duration.zero,
      tokenExpiry: DateTime.now().toUtc().add(const Duration(milliseconds: 250)),
    );
    await h.startListening();
    h.socket.serverSends({
      'sessionResumptionUpdate': {'resumable': true, 'newHandle': 'handle-9'}
    });
    await h.pump();

    await Future<void>.delayed(const Duration(milliseconds: 400));
    await h.pump();

    final setup = jsonDecode(h.sockets.last.sent.first) as Map<String, dynamic>;
    expect(setup['setup']['sessionResumption'], {'handle': 'handle-9'});
  });

  test('an exhausted account is refused a new lease and lands on the paywall',
      () async {
    final h = Harness(
      leaseRenewalMargin: Duration.zero,
      tokenExpiry: DateTime.now().toUtc().add(const Duration(milliseconds: 250)),
      tokenErrors: [
        null,
        const TokenRequestException(
            LiveErrorKind.outOfMinutes, 'out of minutes'),
      ],
    );
    await h.startListening();

    await Future<void>.delayed(const Duration(milliseconds: 400));
    await h.pump();

    expect(h.service.state, LiveServiceState.error);
    final error = h.events.whereType<ServiceError>().single;
    expect(error.kind, LiveErrorKind.outOfMinutes);
    // No second connection was opened for a lease that was never granted.
    expect(h.sockets, hasLength(1));
    expect(h.capture.stopCalls, 1, reason: 'the microphone must stop');
  });

  test('a lease spent in silence renews cleanly', () async {
    final h = Harness(
      leaseRenewalMargin: Duration.zero,
      tokenExpiry: DateTime.now().toUtc().add(const Duration(milliseconds: 250)),
    );
    await h.startListening();
    // Digital silence for the life of the lease. It is still STREAMED —
    // transport is unchanged, and that is the documented cost follow-up —
    // but it buys the user nothing and costs them nothing.
    for (var i = 0; i < 5; i++) {
      h.mic(0);
    }
    await Future<void>.delayed(const Duration(milliseconds: 400));
    await h.pump();
    h.sockets.last.serverSends({'setupComplete': {}});
    await h.pump();

    expect(h.sentAudio(h.sockets.first), hasLength(5));
    expect(h.service.state, LiveServiceState.listening);
    expect(h.tokenRequests, hasLength(2));
    expect(h.events.whereType<ServiceError>(), isEmpty);
  });
}
