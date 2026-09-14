import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:live_translator/features/live_translation/live_translation_controller.dart';
import 'package:live_translator/models/translation_message.dart';
import 'package:live_translator/services/audio/audio_capture_service.dart';
import 'package:live_translator/services/audio/audio_playback_service.dart';
import 'package:live_translator/services/firestore/session_repository.dart';
import 'package:live_translator/services/gemini/live_translation_service.dart';
import 'package:live_translator/services/permissions/mic_permission_service.dart';
import 'package:live_translator/services/storage/settings_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FakeSocket implements GeminiSocket {
  final StreamController<dynamic> incoming = StreamController<dynamic>.broadcast();
  final List<String> sent = [];
  @override
  Stream<dynamic> get messages => incoming.stream;
  @override
  void send(String data) => sent.add(data);
  @override
  Future<void> close() async {
    if (!incoming.isClosed) await incoming.close();
  }

  void serverSends(Map<String, dynamic> message) => incoming.add(jsonEncode(message));
}

class FakeCapture extends AudioCaptureService {
  bool running = false;
  @override
  bool get isCapturing => running;
  @override
  Future<void> start({
    required void Function(Uint8List pcm) onAudio,
    required void Function(String reason) onStopped,
  }) async {
    running = true;
  }

  @override
  Future<void> stop() async {
    running = false;
  }
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
  }) {
    settings = SettingsController(SettingsStore());
    var call = 0;
    service = LiveTranslationService(
      tokenProvider: (target) async {
        tokenTargets.add(target);
        final error = call < tokenErrors.length ? tokenErrors[call] : null;
        call++;
        if (error != null) throw error;
        return LiveSessionToken(
          token: 'tok',
          model: 'm',
          expireTime: DateTime.now().toUtc().add(const Duration(minutes: 30)),
        );
      },
      connect: (uri) async {
        final socket = FakeSocket();
        sockets.add(socket);
        return socket;
      },
      capture: FakeCapture(),
      playback: FakePlayback(),
      backoffDelays: const [Duration.zero],
      playbackGateTail: Duration.zero,
    );
    controller = LiveTranslationController(
      settings: settings,
      service: service,
      permissions: permissions ?? GrantedPermissions(),
      sessionRepository: SessionRepository(firestore: firestore),
      uidProvider: () => 'user-1',
    );
  }

  final FakeFirebaseFirestore firestore = FakeFirebaseFirestore();
  final List<FakeSocket> sockets = [];
  final List<String> tokenTargets = [];
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

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
}
