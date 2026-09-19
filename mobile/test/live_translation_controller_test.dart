import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';
import 'package:live_translator/features/live_translation/live_translation_controller.dart';
import 'package:live_translator/models/translation_message.dart';
import 'package:live_translator/services/audio/audio_capture_service.dart';
import 'package:live_translator/services/audio/audio_playback_service.dart';
import 'package:live_translator/services/billing/usage_meter.dart';
import 'package:live_translator/services/firestore/session_repository.dart';
import 'package:live_translator/services/gemini/live_translation_service.dart';
import 'package:live_translator/services/permissions/mic_permission_service.dart';
import 'package:live_translator/services/speech/speech_service.dart';
import 'package:live_translator/services/storage/settings_store.dart';
import 'package:live_translator/utils/languages.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FakeSocket implements GeminiSocket {
  final StreamController<dynamic> incoming = StreamController<dynamic>.broadcast();

  /// Count of realtimeInput (microphone) frames actually sent upstream.
  int audioFrames = 0;
  final List<String> sent = [];
  @override
  int? closeCode;
  @override
  String? closeReason;
  @override
  Stream<dynamic> get messages => incoming.stream;
  @override
  void send(String data) {
    sent.add(data);
    if (data.contains('realtimeInput')) audioFrames++;
  }

  @override
  Future<void> close() async {
    if (!incoming.isClosed) await incoming.close();
  }

  void serverSends(Map<String, dynamic> message) => incoming.add(jsonEncode(message));
}

class FakeCapture extends AudioCaptureService {
  bool running = false;
  void Function(Uint8List pcm)? onAudio;

  @override
  bool get isCapturing => running;
  @override
  Future<void> start({
    required void Function(Uint8List pcm) onAudio,
    required void Function(String reason) onStopped,
  }) async {
    running = true;
    this.onAudio = onAudio;
  }

  @override
  Future<void> stop() async {
    running = false;
  }

  /// ~100 ms of 16 kHz PCM16 — one full uplink chunk.
  void emitChunk() => onAudio!(Uint8List.fromList(List.filled(3200, 7)));

  /// The same chunk, but digital silence.
  void emitSilence() => onAudio!(Uint8List(3200));
}

class FakePlayback extends AudioPlaybackService {
  final StreamController<bool> active = StreamController<bool>.broadcast();
  @override
  Stream<bool> get playbackActive => active.stream;
  @override
  Future<void> start() async {}
  @override
  Future<void> feed(Uint8List pcm) async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() async => active.close();
}

/// Stands in for the device synthesizer so tests can drive completion,
/// cancellation and failure deterministically.
class FakeSpeech extends SpeechService {
  final List<({String text, String languageCode})> spoken = [];
  final List<String> prepared = [];
  final StreamController<bool> _speaking = StreamController<bool>.broadcast();
  int stopCalls = 0;

  /// false = no installed voice for that language (speak fails up front).
  bool available = true;

  /// true = speak() throws instead of returning.
  bool throwOnSpeak = false;

  @override
  Stream<bool> get speaking => _speaking.stream;

  @override
  Future<void> prepare(String languageCode) async => prepared.add(languageCode);

  @override
  Future<bool> speak(String text, {required String languageCode}) async {
    if (throwOnSpeak) throw StateError('synthesizer exploded');
    spoken.add((text: text, languageCode: languageCode));
    if (available) _speaking.add(true);
    return available;
  }

  /// The synthesizer finished, was cancelled, or errored after starting —
  /// natively all three surface as "no longer speaking".
  void endSpeech() => _speaking.add(false);

  @override
  Future<void> stop() async => stopCalls++;

  @override
  Future<void> dispose() async => _speaking.close();
}

class GrantedPermissions extends MicPermissionService {
  @override
  Future<MicPermissionStatus> currentStatus() async => MicPermissionStatus.granted;
  @override
  Future<MicPermissionStatus> request() async => MicPermissionStatus.granted;
}

class DeniedPermissions extends MicPermissionService {
  @override
  Future<MicPermissionStatus> currentStatus() async =>
      MicPermissionStatus.permanentlyDenied;
  @override
  Future<MicPermissionStatus> request() async => MicPermissionStatus.permanentlyDenied;
}

class Harness {
  Harness({
    MicPermissionService? permissions,
    List<TokenRequestException?> tokenErrors = const [],
    this.sessionId,
    this.leaseSessionIds,
    Duration? tokenLease,
    Duration leaseRenewalMargin = const Duration(seconds: 30),
  }) {
    settings = SettingsController(SettingsStore());
    var call = 0;
    service = LiveTranslationService(
      tokenProvider: (target) async {
        tokenTargets.add(target);
        final error = call < tokenErrors.length ? tokenErrors[call] : null;
        call++;
        if (error != null) throw error;
        final ids = leaseSessionIds;
        return LiveSessionToken(
          token: 'tok',
          model: 'm',
          // Measured from the harness clock, which is what the service
          // compares against when it schedules the renewal.
          expireTime:
              clock.toUtc().add(tokenLease ?? const Duration(minutes: 5)),
          // Each lease may carry its own metered session id.
          sessionId: ids == null
              ? sessionId
              : ids[(call - 1).clamp(0, ids.length - 1)],
        );
      },
      connect: (uri) async {
        final socket = FakeSocket();
        sockets.add(socket);
        return socket;
      },
      capture: capture,
      playback: FakePlayback(),
      leaseRenewalMargin: leaseRenewalMargin,
      backoffDelays: const [Duration.zero],
      playbackGateTail: Duration.zero,
      now: () => clock,
    );
    controller = LiveTranslationController(
      settings: settings,
      service: service,
      permissions: permissions ?? GrantedPermissions(),
      sessionRepository: SessionRepository(firestore: firestore),
      uidProvider: () => 'user-1',
      speech: speech,
      meter: meter,
    );
  }

  /// Long timers: these tests drive the meter's LIFECYCLE (start on listening,
  /// final flush on stop), not its batching cadence.
  late final UsageMeter meter = UsageMeter(
    flushDelay: const Duration(minutes: 5),
    safetyInterval: const Duration(minutes: 5),
    sender: (payload) async {
      meterCalls.add((
        session: payload['sessionId'] as String,
        close: payload['close'] == true,
        cumulativeSpeechMs: payload['cumulativeSpeechMs'] as int,
      ));
      return {'remainingMs': 540000, 'allowed': true};
    },
  );

  /// The server-issued session id the token carries, when metering applies.
  final String? sessionId;

  /// One metered session id per lease, for renewal tests.
  final List<String>? leaseSessionIds;

  /// Every usage report the controller's meter sent.
  final List<({String session, bool close, int cumulativeSpeechMs})>
      meterCalls = [];

  final FakeFirebaseFirestore firestore = FakeFirebaseFirestore();
  final List<FakeSocket> sockets = [];
  final List<String> tokenTargets = [];
  final FakeCapture capture = FakeCapture();
  final FakeSpeech speech = FakeSpeech();

  /// Drives the service's speech gate clock.
  DateTime clock = DateTime.utc(2026, 9, 18, 12);
  late final SettingsController settings;
  late final LiveTranslationService service;
  late final LiveTranslationController controller;

  FakeSocket get socket => sockets.last;

  Future<void> pump() => Future<void>.delayed(Duration.zero);

  Future<void> startAndConnect() async {
    await controller.startListening();
    socket.serverSends({'setupComplete': {}});
    await pump();
  }
}

/// Sends one complete utterance and returns once it has been applied.
Future<void> _utterance(Harness h, String source, String translation) async {
  h.socket.serverSends({
    'serverContent': {
      'inputTranscription': {'text': source, 'languageCode': 'en'}
    }
  });
  h.socket.serverSends({
    'serverContent': {
      'outputTranscription': {'text': translation}
    }
  });
  h.socket.serverSends({
    'serverContent': {'turnComplete': true}
  });
  await h.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  // ── Source-language ownership in the UI model ───────────────────────────────

  test('a Thai speaker after a Hindi speaker gets a SEPARATE bubble with its '
      'own flag, and the Hindi bubble is untouched', () async {
    final h = Harness();
    await h.settings.setTargetLanguage('ar');
    await h.startAndConnect();

    h.socket.serverSends({
      'serverContent': {
        'inputTranscription': {'text': 'मेट्रो कहाँ है', 'languageCode': 'hi-IN'},
      }
    });
    h.socket.serverSends({
      'serverContent': {
        'outputTranscription': {'text': 'أين المترو؟'}
      }
    });
    await h.pump();
    expect(h.controller.messages, hasLength(1));
    final hindiId = h.controller.messages.single.id;

    // Person B starts speaking Thai — mid-turn, no turnComplete.
    h.socket.serverSends({
      'serverContent': {
        'inputTranscription': {'text': 'รถไฟฟ้าอยู่ที่ไหน', 'languageCode': 'th-TH'},
      }
    });
    h.socket.serverSends({
      'serverContent': {
        'outputTranscription': {'text': 'أين القطار؟'}
      }
    });
    await h.pump();

    expect(h.controller.messages, hasLength(2),
        reason: 'different source languages must not share a bubble');

    final hindi = h.controller.messages.firstWhere((m) => m.id == hindiId);
    final thai = h.controller.messages.firstWhere((m) => m.id != hindiId);

    // Each bubble owns its language — flags come from the message itself.
    expect(hindi.sourceLanguage, 'hi');
    expect(thai.sourceLanguage, 'th');
    expect(detectedLanguageFlag(hindi.sourceLanguage, hindi.languageConfidence),
        languageForCode('hi')!.flag);
    expect(detectedLanguageFlag(thai.sourceLanguage, thai.languageConfidence),
        languageForCode('th')!.flag);

    // No cross-contamination in either direction.
    expect(hindi.originalText, 'मेट्रो कहाँ है');
    expect(hindi.translatedText, 'أين المترو؟');
    expect(thai.originalText, 'รถไฟฟ้าอยู่ที่ไหน');
    expect(thai.translatedText, 'أين القطار؟');
  });

  test('the Hindi bubble keeps its flag after Thai and English follow', () async {
    final h = Harness();
    await h.settings.setTargetLanguage('ar');
    await h.startAndConnect();

    for (final (text, language) in [
      ('नमस्ते', 'hi-IN'),
      ('สวัสดี', 'th-TH'),
      ('Good morning', 'en-US'),
    ]) {
      h.socket.serverSends({
        'serverContent': {
          'inputTranscription': {'text': text, 'languageCode': language},
        }
      });
      await h.pump();
    }
    h.socket.serverSends({
      'serverContent': {'turnComplete': true}
    });
    await h.pump();

    expect(h.controller.messages, hasLength(3));
    expect(h.controller.messages.map((m) => m.sourceLanguage),
        ['hi', 'th', 'en']);
    expect(h.controller.messages.map((m) => m.originalText),
        ['नमस्ते', 'สวัสดี', 'Good morning']);
  });

  // ── Speaker availability + TTS microphone gating ────────────────────────────

  test('the speaker button is available as soon as translated TEXT exists, '
      'without waiting for turnComplete', () async {
    final h = Harness();
    await h.settings.setTargetLanguage('ar');
    await h.startAndConnect();

    h.socket.serverSends({
      'serverContent': {
        'inputTranscription': {'text': 'Where is the metro?', 'languageCode': 'en'},
      }
    });
    await h.pump();
    // Transcript only: nothing to read aloud yet.
    expect(h.controller.canSpeak(h.controller.messages.single), isFalse);

    // The first streamed translation word arrives — still PENDING, no
    // turnComplete, and no Gemini audio of any kind.
    h.socket.serverSends({
      'serverContent': {
        'outputTranscription': {'text': 'أين'}
      }
    });
    await h.pump();
    final message = h.controller.messages.single;
    expect(message.status, TranslationStatus.pending);
    expect(h.controller.canSpeak(message), isTrue,
        reason: 'speaker availability comes from translated text alone');
  });

  test('speaking reads the current translated text, gates the mic, and the '
      'gate reopens on completion', () async {
    final h = Harness();
    await h.settings.setTargetLanguage('ar');
    await h.startAndConnect();
    // Warmed when the session started, so the first tap is instant.
    expect(h.speech.prepared, contains('ar-SA'));

    await _utterance(h, 'Where is the metro?', 'أين المترو؟');
    final message = h.controller.messages.single;

    await h.controller.speakTranslation(message);
    // Reads exactly what is on screen, with a real BCP-47 voice locale.
    expect(h.speech.spoken.single.text, 'أين المترو؟');
    expect(h.speech.spoken.single.languageCode, 'ar-SA');
    expect(h.controller.playingMessageId, message.id);

    // Microphone is quiet while the phone talks...
    final before = h.socket.audioFrames;
    h.capture.emitChunk();
    expect(h.socket.audioFrames, before, reason: 'gated during speech');
    // ...and the session is never disturbed.
    expect(h.controller.state, ListeningState.listening);
    expect(h.sockets, hasLength(1));

    // Completion reopens it immediately.
    h.speech.endSpeech();
    await h.pump();
    expect(h.controller.playingMessageId, isNull);
    h.capture.emitChunk();
    expect(h.socket.audioFrames, before + 1,
        reason: 'microphone resumes the moment speech ends');
  });

  test('a cancelled replay reopens the microphone', () async {
    final h = Harness();
    await h.settings.setTargetLanguage('ar');
    await h.startAndConnect();
    await _utterance(h, 'Where is the metro?', 'أين المترو؟');

    await h.controller.speakTranslation(h.controller.messages.single);
    final before = h.socket.audioFrames;
    h.capture.emitChunk();
    expect(h.socket.audioFrames, before);

    // Cancelled (e.g. the user tapped another message): natively this is the
    // same "no longer speaking" signal as completion.
    h.speech.endSpeech();
    await h.pump();
    h.capture.emitChunk();
    expect(h.socket.audioFrames, before + 1);
    expect(h.controller.playingMessageId, isNull);
  });

  test('a synthesizer with no voice reopens the microphone at once', () async {
    final h = Harness();
    await h.settings.setTargetLanguage('ar');
    await h.startAndConnect();
    await _utterance(h, 'Where is the metro?', 'أين المترو؟');
    h.speech.available = false;

    await h.controller.speakTranslation(h.controller.messages.single);

    // No speech started, so nothing may stay gated or stuck "playing".
    expect(h.controller.playingMessageId, isNull);
    final before = h.socket.audioFrames;
    h.capture.emitChunk();
    expect(h.socket.audioFrames, before + 1,
        reason: 'a failed replay must not gate the microphone');
    expect(h.controller.state, ListeningState.listening);
  });

  test('a synthesizer that throws reopens the microphone at once', () async {
    final h = Harness();
    await h.settings.setTargetLanguage('ar');
    await h.startAndConnect();
    await _utterance(h, 'Where is the metro?', 'أين المترو؟');
    h.speech.throwOnSpeak = true;

    // The error is contained — speaking must never take the session down.
    await h.controller.speakTranslation(h.controller.messages.single);

    expect(h.controller.playingMessageId, isNull);
    final before = h.socket.audioFrames;
    h.capture.emitChunk();
    expect(h.socket.audioFrames, before + 1,
        reason: 'an error must not leave the microphone gated');
    expect(h.controller.state, ListeningState.listening);
  });

  test('the speech gate expires even if the synthesizer never reports back',
      () async {
    final h = Harness();
    await h.settings.setTargetLanguage('ar');
    await h.startAndConnect();
    await _utterance(h, 'Where is the metro?', 'أين المترو؟');

    await h.controller.speakTranslation(h.controller.messages.single);
    final before = h.socket.audioFrames;
    h.capture.emitChunk();
    expect(h.socket.audioFrames, before, reason: 'gated');

    // No completion event ever arrives. The bound alone must free the mic.
    h.clock = h.clock.add(const Duration(seconds: 25));
    h.capture.emitChunk();
    expect(h.socket.audioFrames, before + 1,
        reason: 'the microphone can NEVER stay permanently gated');
  });

  test('switching target language re-points the voice', () async {
    final h = Harness();
    await h.settings.setTargetLanguage('ar');
    await h.startAndConnect();
    expect(h.speech.prepared, contains('ar-SA'));

    await h.settings.setTargetLanguage('th');
    await h.pump();
    expect(h.speech.prepared, contains('th-TH'),
        reason: 'the voice follows the target language');
  });

  test('five consecutive translations are all immediately speakable', () async {
    final h = Harness();
    await h.settings.setTargetLanguage('ar');
    await h.startAndConnect();

    for (final (source, translation) in [
      ('Where is the metro?', 'أين المترو؟'),
      ('How much is the ticket?', 'كم سعر التذكرة؟'),
      ('Does it stop at the museum?', 'هل يتوقف عند المتحف؟'),
      ('When is the last train?', 'متى آخر قطار؟'),
      ('Thank you very much', 'شكرا جزيلا'),
    ]) {
      await _utterance(h, source, translation);
    }

    expect(h.controller.messages, hasLength(5));
    for (final message in h.controller.messages) {
      expect(h.controller.canSpeak(message), isTrue);
    }
  });

  // ── Background listening ────────────────────────────────────────────────────

  test('backgrounding STOPS the session unless the user opted in', () async {
    final h = Harness();
    await h.startAndConnect();
    expect(h.controller.settings.settings.continueInBackground, isFalse,
        reason: 'background listening must be OFF by default');

    h.controller.didChangeAppLifecycleState(AppLifecycleState.paused);
    await h.pump();

    expect(h.controller.state, ListeningState.idle);
    expect(h.controller.listeningInBackground, isFalse);
    expect(h.controller.errorBanner, contains('background'));
  });

  test('with background listening ON, the app leaving the screen keeps the '
      'session and translations keep arriving', () async {
    final h = Harness();
    await h.settings
        .update((s) => s.copyWith(continueInBackground: true));
    await h.settings.setTargetLanguage('ar');
    await h.startAndConnect();
    await _utterance(h, 'Where is the metro?', 'أين المترو؟');
    expect(h.controller.messages, hasLength(1));

    // App goes to the background (and the same state covers a locked screen).
    h.controller.didChangeAppLifecycleState(AppLifecycleState.paused);
    await h.pump();
    expect(h.controller.state, ListeningState.listening,
        reason: 'the session belongs to the app, not the Home screen');
    expect(h.controller.listeningInBackground, isTrue);
    expect(h.controller.errorBanner, isNull);

    // Speech keeps being translated while backgrounded.
    await _utterance(h, 'How much is the ticket?', 'كم سعر التذكرة؟');
    await _utterance(h, 'When is the last train?', 'متى آخر قطار؟');
    expect(h.controller.messages, hasLength(3),
        reason: 'translations continue to arrive in the background');

    // Screen locked, then unlocked: still one uninterrupted session.
    h.controller.didChangeAppLifecycleState(AppLifecycleState.inactive);
    await h.pump();
    expect(h.controller.state, ListeningState.listening);
    await _utterance(h, 'Thank you', 'شكرا');

    // Back in the foreground: SAME session, and the whole conversation is
    // still on screen.
    h.controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await h.pump();
    expect(h.controller.state, ListeningState.listening);
    expect(h.controller.listeningInBackground, isFalse);
    expect(h.controller.messages, hasLength(4));
    expect(h.controller.messages.map((m) => m.translatedText),
        containsAll(<String>['أين المترو؟', 'كم سعر التذكرة؟', 'شكرا']));
    expect(h.sockets, hasLength(1), reason: 'never reconnected');
    expect(h.tokenTargets, hasLength(1), reason: 'never re-minted a token');
  });

  test('five consecutive translations land in five bubbles on one session',
      () async {
    final h = Harness();
    await h.settings.setTargetLanguage('ar');
    await h.startAndConnect();

    const phrases = [
      ('Where is the metro?', 'أين المترو؟'),
      ('How much is the ticket?', 'كم سعر التذكرة؟'),
      ('Does it stop at the museum?', 'هل يتوقف عند المتحف؟'),
      ('When is the last train?', 'متى آخر قطار؟'),
      ('Thank you very much', 'شكرا جزيلا'),
    ];
    for (final (source, translation) in phrases) {
      await _utterance(h, source, translation);
    }

    expect(h.controller.messages, hasLength(5));
    for (var i = 0; i < phrases.length; i++) {
      expect(h.controller.messages[i].originalText, phrases[i].$1);
      expect(h.controller.messages[i].translatedText, phrases[i].$2);
      expect(h.controller.messages[i].status, TranslationStatus.done);
      // Speakable the moment the text is final — no audio has to be kept.
      expect(h.controller.canSpeak(h.controller.messages[i]), isTrue);
    }
    expect(h.controller.state, ListeningState.listening);
    expect(h.sockets, hasLength(1));
  });

  test('start → listening; partial transcripts update ONE bubble in place', () async {
    final h = Harness();
    await h.settings.setTargetLanguage('ar');
    await h.startAndConnect();
    expect(h.controller.state, ListeningState.listening);
    expect(h.tokenTargets, ['ar']);

    h.socket.serverSends({
      'serverContent': {
        'inputTranscription': {'text': 'Hello', 'languageCode': 'en'}
      }
    });
    await h.pump();
    expect(h.controller.messages, hasLength(1));
    final bubble = h.controller.messages.single;
    expect(bubble.originalText, 'Hello');
    expect(bubble.status, TranslationStatus.pending);
    expect(bubble.sourceLanguage, 'en');

    h.socket.serverSends({
      'serverContent': {
        'inputTranscription': {'text': ' there'},
        'outputTranscription': {'text': 'مرحبا'}
      }
    });
    await h.pump();
    expect(h.controller.messages, hasLength(1), reason: 'no duplicate bubbles');
    expect(h.controller.messages.single.originalText, 'Hello there');
    expect(h.controller.messages.single.translatedText, 'مرحبا');
  });

  test('finalized utterances (and ONLY those) are persisted to Firestore', () async {
    final h = Harness();
    await h.settings.setTargetLanguage('ar');
    await h.startAndConnect();

    h.socket.serverSends({
      'serverContent': {
        'inputTranscription': {'text': 'Hello', 'languageCode': 'en'},
        'outputTranscription': {'text': 'مرحبا'}
      }
    });
    await h.pump();
    // Partial only — nothing persisted yet, no session doc either.
    var sessions = await h.firestore.collection('users/user-1/sessions').get();
    expect(sessions.docs, isEmpty);

    h.socket.serverSends({
      'serverContent': {'turnComplete': true}
    });
    await h.pump();
    await h.pump();

    sessions = await h.firestore.collection('users/user-1/sessions').get();
    expect(sessions.docs, hasLength(1));
    expect(sessions.docs.single.data()['targetLanguageCode'], 'ar');
    final messages = await sessions.docs.single.reference.collection('messages').get();
    expect(messages.docs, hasLength(1));
    final data = messages.docs.single.data();
    expect(data['originalText'], 'Hello');
    expect(data['translatedText'], 'مرحبا');
    expect(data['sourceLanguageCode'], 'en');
    expect(data['targetLanguageCode'], 'ar');
    expect(data.containsKey('audio'), isFalse);

    await h.controller.stopListening();
    final ended = await h.firestore.collection('users/user-1/sessions').get();
    expect(ended.docs.single.data()['endedAt'], isNotNull);
    expect(ended.docs.single.data()['messageCount'], 1);
    expect(h.controller.lastSummary?.translationCount, 1);
  });

  test('source language changes are reflected automatically per utterance', () async {
    final h = Harness();
    await h.startAndConnect();

    h.socket.serverSends({
      'serverContent': {
        'inputTranscription': {'text': 'Hello', 'languageCode': 'en'},
        'turnComplete': true
      }
    });
    h.socket.serverSends({
      'serverContent': {
        'inputTranscription': {'text': 'สวัสดี', 'languageCode': 'th'},
        'turnComplete': true
      }
    });
    await h.pump();
    expect(h.controller.messages, hasLength(2));
    expect(h.controller.messages[0].sourceLanguage, 'en');
    expect(h.controller.messages[1].sourceLanguage, 'th');
  });

  test('BCP-47 detected codes are normalized for display (pt-BR → pt)', () async {
    final h = Harness();
    await h.startAndConnect();
    h.socket.serverSends({
      'serverContent': {
        'inputTranscription': {'text': 'Olá', 'languageCode': 'pt-BR'}
      }
    });
    await h.pump();
    expect(h.controller.messages.single.sourceLanguage, 'pt');
  });

  test('quota error shows the quota banner and returns to a startable state', () async {
    final h = Harness(tokenErrors: [
      const TokenRequestException(LiveErrorKind.quota, 'quota'),
    ]);
    await h.controller.startListening();
    await h.pump();
    expect(h.controller.state, ListeningState.idle);
    expect(h.controller.errorBanner, contains('capacity'));
  });

  test('permanently denied microphone never reaches the token service', () async {
    final h = Harness(permissions: DeniedPermissions());
    await h.controller.startListening();
    expect(h.controller.state, ListeningState.idle);
    expect(h.controller.permissionPermanentlyDenied, isTrue);
    expect(h.controller.errorBanner, isNotNull);
    expect(h.tokenTargets, isEmpty);
  });

  test('changing the target language mid-session restarts with the new language', () async {
    final h = Harness();
    await h.settings.setTargetLanguage('ar');
    await h.startAndConnect();
    expect(h.tokenTargets, ['ar']);

    await h.settings.setTargetLanguage('en');
    // Restart is async: old session stops, a new one starts.
    await h.pump();
    await h.pump();
    await h.pump();
    h.socket.serverSends({'setupComplete': {}});
    await h.pump();

    expect(h.tokenTargets, ['ar', 'en']);
    expect(h.controller.state, ListeningState.listening);
  });

  test('stop/start works repeatedly', () async {
    final h = Harness();
    for (var i = 0; i < 3; i++) {
      await h.startAndConnect();
      expect(h.controller.state, ListeningState.listening);
      await h.controller.stopListening();
      expect(h.controller.state, ListeningState.idle);
    }
  });

  // ── Metering ──────────────────────────────────────────────────────────────

  test('a silent session reports zero translated speech when it ends',
      () async {
    final h = Harness(sessionId: 'srv-session-1');
    await h.startAndConnect();
    expect(h.controller.state, ListeningState.listening);
    // Nothing is reported while listening: reports follow translated speech,
    // not the clock.
    expect(h.meterCalls, isEmpty);

    await h.controller.stopListening();
    await h.pump();

    // One closing report, and it carries nothing to charge.
    expect(h.meterCalls, hasLength(1));
    expect(h.meterCalls.single.session, 'srv-session-1');
    expect(h.meterCalls.single.close, isTrue);
    expect(h.meterCalls.single.cumulativeSpeechMs, 0);

    // And the meter is idle: a later report would have to come from a new
    // session, not this one.
    await h.pump();
    expect(h.meterCalls.length, 1);
  });

  test('each listening session is metered under its own server session id',
      () async {
    final h = Harness(sessionId: 'srv-session-2');
    await h.startAndConnect();
    await h.controller.stopListening();
    await h.startAndConnect();
    await h.controller.stopListening();
    await h.pump();
    expect(h.meterCalls.length, 2);
    expect(h.meterCalls.every((c) => c.session == 'srv-session-2' && c.close),
        isTrue);
  });

  test('silence is still STREAMED to Gemini even though it is never charged',
      () async {
    // Deliberate, and documented as a COST OPTIMIZATION FOLLOW-UP: the
    // transport is unchanged by the speech-only accounting, because gating the
    // uplink on a new VAD threshold risks the far-field and quiet-speaker
    // regressions Sayvo has already had once. What the user pays and what
    // Gemini costs us are now different numbers, on purpose.
    final h = Harness(sessionId: 'srv-session-silent');
    await h.startAndConnect();
    for (var i = 0; i < 20; i++) {
      h.capture.emitSilence();
    }
    await h.pump();

    expect(h.socket.audioFrames, 20, reason: 'silence still goes upstream');

    await h.controller.stopListening();
    await h.pump();
    // ...and the user is charged nothing for any of it.
    expect(h.meterCalls.single.cumulativeSpeechMs, 0);
    expect(h.meter.telemetry()['audioSentMs'], 2000);
    expect(h.meter.telemetry()['committedSpeechMs'], 0);
  });

  test('the conversation and the Sayvo session survive a lease renewal',
      () async {
    final h = Harness(
      leaseSessionIds: ['lease-1', 'lease-2'],
      tokenLease: const Duration(milliseconds: 250),
      leaseRenewalMargin: Duration.zero,
    );
    await h.settings.setTargetLanguage('ar');
    await h.startAndConnect();
    await _utterance(h, 'Where is the metro?', 'أين المترو؟');
    expect(h.controller.messages, hasLength(1));
    final firstId = h.controller.messages.single.id;

    // The five-minute lease runs out mid-conversation.
    await Future<void>.delayed(const Duration(milliseconds: 400));
    await h.pump();
    h.sockets.last.serverSends({'setupComplete': {}});
    await h.pump();

    // Still one Sayvo session: same listening state, same bubbles, same ids.
    expect(h.controller.state, ListeningState.listening);
    expect(h.controller.errorBanner, isNull);
    expect(h.controller.messages, hasLength(1));
    expect(h.controller.messages.single.id, firstId);

    // And the conversation carries on under the new lease.
    await _utterance(h, 'How much is the ticket?', 'كم سعر التذكرة؟');
    expect(h.controller.messages, hasLength(2));

    // One Firestore session document for the whole thing, not one per lease.
    final sessions =
        await h.firestore.collection('users').doc('user-1').collection('sessions').get();
    expect(sessions.docs, hasLength(1));

    await h.controller.stopListening();
    await h.pump();
    // The old lease was settled when it ended, and the new one on stop.
    expect(h.meterCalls.map((c) => c.session).toSet(), {'lease-1', 'lease-2'});
    expect(h.meterCalls.where((c) => c.close).length, 2);
  });

  test('an exhausted account cannot renew its lease', () async {
    final h = Harness(
      leaseSessionIds: ['lease-1'],
      tokenLease: const Duration(milliseconds: 250),
      leaseRenewalMargin: Duration.zero,
      tokenErrors: [
        null,
        const TokenRequestException(
            LiveErrorKind.outOfMinutes, 'out of minutes'),
      ],
    );
    await h.startAndConnect();

    await Future<void>.delayed(const Duration(milliseconds: 400));
    await h.pump();

    expect(h.controller.state, ListeningState.idle);
    expect(h.controller.outOfMinutes, isTrue);
    expect(h.controller.errorBanner, isNull);
  });

  test('background translated speech is metered like any other', () async {
    final h = Harness(sessionId: 'srv-session-bg');
    await h.settings.update((s) => s.copyWith(continueInBackground: true));
    await h.settings.setTargetLanguage('ar');
    await h.startAndConnect();

    h.controller.didChangeAppLifecycleState(AppLifecycleState.paused);
    await h.pump();
    expect(h.controller.listeningInBackground, isTrue);

    await _utterance(h, 'Where is the metro?', 'أين المترو؟');
    await _utterance(h, 'How much is the ticket?', 'كم سعر التذكرة؟');

    // Same meter, same rules — there is no separate background rate.
    expect(h.meter.speech.translatedUtteranceCount, 2);

    await h.controller.stopListening();
    await h.pump();
    expect(h.meterCalls.last.close, isTrue);
  });

  test('translated speech reaches the meter; the bubbles are untouched',
      () async {
    final h = Harness(sessionId: 'srv-session-3');
    await h.startAndConnect();

    // Somebody speaks and Sayvo translates it.
    h.socket.serverSends({
      'serverContent': {
        'inputTranscription': {'text': 'wo ist das hotel', 'languageCode': 'de-DE'},
      },
    });
    await h.pump();
    h.socket.serverSends({
      'serverContent': {
        'outputTranscription': {'text': 'where is the hotel'},
      },
    });
    await h.pump();
    h.socket.serverSends({'serverContent': {'turnComplete': true}});
    await h.pump();

    // The conversation is exactly what it was before billing existed: one
    // bubble, its own language, its own translation.
    expect(h.controller.messages, hasLength(1));
    expect(h.controller.messages.single.sourceLanguage, 'de');
    expect(h.controller.messages.single.translatedText, 'where is the hotel');

    // And the meter saw the translation (no audio was fed, so there is no
    // speech duration to charge — the ACCOUNTING is what is wired up here).
    expect(h.meter.speech.translatedUtteranceCount, 1);
  });

  test('a session the server never metered is not billed on stop', () async {
    // No sessionId on the token (e.g. an older server): nothing to charge.
    final h = Harness();
    await h.startAndConnect();
    await h.controller.stopListening();
    await h.pump();
    expect(h.meterCalls, isEmpty);
  });

  test('running out of minutes routes to the paywall, not an error banner',
      () async {
    final h = Harness(tokenErrors: [
      const TokenRequestException(LiveErrorKind.outOfMinutes, 'out of minutes'),
    ]);
    await h.controller.startListening();
    await h.pump();
    expect(h.controller.state, ListeningState.idle);
    expect(h.controller.outOfMinutes, isTrue);
    expect(h.controller.errorBanner, isNull);
    // The flag is one-shot so the paywall opens once per refusal.
    h.controller.consumeOutOfMinutes();
    expect(h.controller.outOfMinutes, isFalse);
  });
}
