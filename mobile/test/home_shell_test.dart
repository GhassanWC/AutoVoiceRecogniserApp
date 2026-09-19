import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:live_translator/features/live_translation/live_translation_controller.dart';
import 'package:live_translator/features/live_translation/live_translation_screen.dart';
import 'package:live_translator/features/profile/profile_screen.dart';
import 'package:live_translator/features/shell/home_shell.dart';
import 'package:live_translator/services/audio/audio_capture_service.dart';
import 'package:live_translator/services/audio/audio_playback_service.dart';
import 'package:live_translator/services/auth/auth_controller.dart';
import 'package:live_translator/services/auth/auth_service.dart';
import 'package:live_translator/services/billing/entitlement_controller.dart';
import 'package:live_translator/services/billing/subscription_service.dart';
import 'package:live_translator/services/firestore/session_repository.dart';
import 'package:live_translator/services/firestore/user_repository.dart';
import 'package:live_translator/services/gemini/live_translation_service.dart';
import 'package:live_translator/services/permissions/mic_permission_service.dart';
import 'package:live_translator/services/speech/speech_service.dart';
import 'package:live_translator/services/storage/settings_store.dart';
import 'package:live_translator/utils/plans.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ── Fakes (presentation-only test: the real services are never touched) ──────

class _FakeSocket implements GeminiSocket {
  // Single-subscription with an onCancel: subscription.cancel() then returns
  // a future owned by the test's FakeAsync zone. A plain (or broadcast)
  // controller hands back a root-zone pre-completed future whose
  // continuation never runs under FakeAsync, so the service's
  // `await subscription.cancel()` in stop() would hang forever in this test.
  // Production is unaffected — root-zone microtasks run normally there.
  final StreamController<dynamic> incoming =
      StreamController<dynamic>(onCancel: () async {});
  @override
  int? closeCode;
  @override
  String? closeReason;
  @override
  Stream<dynamic> get messages => incoming.stream;

  /// Count of realtimeInput (microphone) frames actually sent upstream.
  int audioFrames = 0;

  @override
  void send(String data) {
    if (data.contains('realtimeInput')) audioFrames++;
  }
  @override
  Future<void> close() async {
    // Not awaited for the same FakeAsync reason (close() after cancel also
    // returns a root-zone future).
    if (!incoming.isClosed) incoming.close().ignore();
  }

  void serverSends(Map<String, dynamic> message) => incoming.add(jsonEncode(message));
}

class _FakeCapture extends AudioCaptureService {
  bool running = false;
  int startCalls = 0;
  int stopCalls = 0;
  void Function(Uint8List pcm)? onAudio;

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
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    running = false;
  }

  /// ~100 ms of 16 kHz PCM16 — one full uplink chunk.
  void emitChunk() => onAudio!(Uint8List.fromList(List.filled(3200, 7)));
}

class _FakePlayback extends AudioPlaybackService {
  final StreamController<bool> active = StreamController<bool>.broadcast();
  int fedChunks = 0;
  int fedBytes = 0;
  @override
  Stream<bool> get playbackActive => active.stream;
  @override
  Future<void> start() async {}
  @override
  Future<void> feed(Uint8List pcm) async {
    fedChunks++;
    fedBytes += pcm.length;
  }
  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() async => active.close();
}

/// Stands in for the device synthesizer (AVSpeechSynthesizer /
/// android TextToSpeech) so tests can assert what would be spoken.
class _FakeSpeech extends SpeechService {
  final List<({String text, String languageCode})> spoken = [];
  final StreamController<bool> _speaking = StreamController<bool>.broadcast();
  int stopCalls = 0;

  /// Set false to simulate a device with no voice for that language.
  bool available = true;

  @override
  Stream<bool> get speaking => _speaking.stream;

  @override
  Future<bool> speak(String text, {required String languageCode}) async {
    spoken.add((text: text, languageCode: languageCode));
    if (available) _speaking.add(true);
    return available;
  }

  /// Simulates the synthesizer reaching the end of the utterance.
  void finish() => _speaking.add(false);

  @override
  Future<void> stop() async => stopCalls++;

  @override
  Future<void> dispose() async => _speaking.close();
}

class _GrantedPermissions extends MicPermissionService {
  @override
  Future<MicPermissionStatus> currentStatus() async => MicPermissionStatus.granted;
  @override
  Future<MicPermissionStatus> request() async => MicPermissionStatus.granted;
}

class _FakeFirebaseAuth extends Fake implements FirebaseAuth {
  final StreamController<User?> states = StreamController<User?>.broadcast();
  User? user;
  @override
  Stream<User?> authStateChanges() => states.stream;
  @override
  User? get currentUser => user;
}

class _FakeUser extends Fake implements User {
  @override
  String get uid => 'user-1';
  @override
  String? get displayName => 'Sarah Ahmed';
  @override
  String? get email => 'sarah@example.com';
  @override
  String? get photoURL => null;
  @override
  List<UserInfo> get providerData => const [];
}

/// The shell never talks to StoreKit or Play Billing in a widget test; the
/// store's own plugin has no implementation on the test host.
class _NoopSubscriptions extends SubscriptionService {
  _NoopSubscriptions() : super(store: BillingStore.apple);
  @override
  void listen() {}
  @override
  bool get isSupportedPlatform => false;
  @override
  Future<bool> loadProducts() async => false;
  @override
  Future<void> restorePurchases() async {}
}

class _ShellHarness {
  _ShellHarness() {
    settings = SettingsController(SettingsStore());
    service = LiveTranslationService(
      tokenProvider: (target) async => LiveSessionToken(
        token: 'tok',
        model: 'm',
        expireTime: DateTime.now().toUtc().add(const Duration(minutes: 30)),
      ),
      connect: (uri) async {
        final socket = _FakeSocket();
        sockets.add(socket);
        return socket;
      },
      capture: capture,
      playback: playback,
      backoffDelays: const [Duration.zero],
      playbackGateTail: const Duration(milliseconds: 300),
      now: () => clock,
      isOnline: () async => true,
    );
    live = LiveTranslationController(
      settings: settings,
      service: service,
      permissions: _GrantedPermissions(),
      sessionRepository: SessionRepository(firestore: firestore),
      uidProvider: () => 'user-1',
      speech: speech,
    );
    auth = AuthController(
      authService: AuthService(auth: firebaseAuth),
      userRepository: UserRepository(firestore: firestore),
      settings: settings,
    );
  }

  final FakeFirebaseFirestore firestore = FakeFirebaseFirestore();
  final _FakeFirebaseAuth firebaseAuth = _FakeFirebaseAuth();
  final List<_FakeSocket> sockets = [];
  final _FakeCapture capture = _FakeCapture();
  final _FakePlayback playback = _FakePlayback();
  final _FakeSpeech speech = _FakeSpeech();

  /// Entitlement is server-owned; the fake Firestore stands in for it and the
  /// default (no document) is the free tier.
  late final EntitlementController entitlements =
      EntitlementController(firestore: firestore);
  final SubscriptionService subscriptions = _NoopSubscriptions();

  /// Drives the service's half-duplex gate clock (real 300 ms tail).
  DateTime clock = DateTime.utc(2026, 9, 17, 12);

  late final SettingsController settings;
  late final LiveTranslationService service;
  late final LiveTranslationController live;
  late final AuthController auth;

  /// Pumps the signed-in shell. [textScale] stacks on the test's default
  /// scale exactly like app.dart's builder does for the user's text-size
  /// setting plus system dynamic type.
  Future<void> pumpShell(WidgetTester tester, {double textScale = 1.0}) async {
    await settings.load();
    firebaseAuth.user = _FakeUser();
    firebaseAuth.states.add(firebaseAuth.user);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SettingsController>.value(value: settings),
          ChangeNotifierProvider<AuthController>.value(value: auth),
          Provider<SessionRepository>.value(
              value: SessionRepository(firestore: firestore)),
          ChangeNotifierProvider<EntitlementController>.value(
              value: entitlements),
          Provider<SubscriptionService>.value(value: subscriptions),
          ChangeNotifierProvider<LiveTranslationController>.value(value: live),
        ],
        child: MaterialApp(
          theme: ThemeData.dark(useMaterial3: true),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: const HomeShell(),
        ),
      ),
    );
    await tester.pump();
  }
}

void _useSmallPhone(WidgetTester tester) {
  tester.view.physicalSize = const Size(320, 568);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// Pumps a few frames without pumpAndSettle (the orb animates while
/// connecting/listening, so "settled" never arrives by design).
Future<void> _pumpFrames(WidgetTester tester, [int frames = 4]) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('home shell lays out on a small phone at max text scale without overflow',
      (tester) async {
    _useSmallPhone(tester);
    final h = _ShellHarness();
    await h.pumpShell(tester, textScale: 2.2);
    await _pumpFrames(tester);

    expect(tester.takeException(), isNull);
    expect(find.text('Sayvo'), findsOneWidget);
    expect(find.text('Tap to start listening'), findsOneWidget);
    expect(find.bySemanticsLabel('Start listening'), findsOneWidget);

    // Every tab must render cleanly at this scale too.
    await tester.tap(find.text('History'));
    await _pumpFrames(tester);
    expect(tester.takeException(), isNull);
    expect(find.text('No conversations yet'), findsOneWidget);

    await tester.tap(find.text('Profile'));
    await _pumpFrames(tester);
    expect(tester.takeException(), isNull);
    expect(find.text('Sarah Ahmed'), findsOneWidget);
    // At this scale the list is several screens tall and lazily built:
    // scroll the Profile tab's own scrollable (every tab in the IndexedStack
    // has one) to reach each section.
    final profileList = find.descendant(
      of: find.byType(ProfileScreen),
      matching: find.byType(Scrollable),
    );
    await tester.scrollUntilVisible(find.text('Target Language'), 200,
        scrollable: profileList);
    expect(find.text('Target Language'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Delete Account'), 200,
        scrollable: profileList);
    await _pumpFrames(tester);
    expect(tester.takeException(), isNull);
    expect(find.text('Sign Out'), findsOneWidget);
    expect(find.text('Delete Account'), findsOneWidget);
    // Concept-only features must not exist.
    expect(find.textContaining('Premium'), findsNothing);
    expect(find.textContaining('Download'), findsNothing);
  });

  testWidgets('orb starts a session; a tap while connecting is a no-op; stop shows summary',
      (tester) async {
    _useSmallPhone(tester);
    final h = _ShellHarness();
    await h.pumpShell(tester);

    await tester.tap(find.bySemanticsLabel('Start listening'));
    await _pumpFrames(tester);
    expect(h.live.state, ListeningState.starting);
    expect(find.text('Connecting…'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // The old UI disabled the button while starting; the orb must not race
    // the in-flight start with a stop (mic could end up on after "stopped").
    await tester.tap(find.bySemanticsLabel('Connecting to translation service'));
    await _pumpFrames(tester);
    expect(h.live.state, ListeningState.starting);
    expect(find.text('Translation stopped'), findsNothing);

    h.sockets.single.serverSends({'setupComplete': {}});
    await _pumpFrames(tester);
    expect(h.live.state, ListeningState.listening);
    expect(find.text('Listening…'), findsOneWidget);
    expect(find.bySemanticsLabel('Stop listening'), findsOneWidget);
    expect(tester.takeException(), isNull, reason: 'listening layout must not overflow');

    await tester.tap(find.bySemanticsLabel('Stop listening'));
    await _pumpFrames(tester);
    expect(h.live.state, ListeningState.idle);
    expect(find.text('Translation stopped'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('with no minutes left the orb opens the paywall and starts '
      'nothing', (tester) async {
    _useSmallPhone(tester);
    final h = _ShellHarness();
    // The SERVER says this account's translated-speech allowance is spent.
    await h.firestore.collection('entitlements').doc('user-1').set({
      'plan': 'free',
      'subscriptionStatus': 'none',
      'freeUsedMs': kFreeLifetimeMs,
      'remainingMs': 0,
      'allowanceSource': 'free',
    });
    h.entitlements.bind('user-1');
    await h.pumpShell(tester);
    await _pumpFrames(tester);

    await tester.tap(find.bySemanticsLabel('Start listening'));
    await _pumpFrames(tester);

    expect(find.text('Sayvo Plans'), findsOneWidget);
    expect(h.live.state, ListeningState.idle);
    // No token was requested and no socket opened: an exhausted account
    // never reaches the translation service.
    expect(h.sockets, isEmpty);
  });

  // THE multi-turn regression guard at the UI level: one Start Listening,
  // two utterances, both rendered — the redesigned widget tree must not
  // dispose/recreate the controller or service after the first translation.
  testWidgets('one listening session renders TWO consecutive translations',
      (tester) async {
    // Roomy viewport: this test is about behavior, not small-screen layout.
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final h = _ShellHarness();
    await h.settings.setTargetLanguage('ar');
    await h.pumpShell(tester);

    await tester.tap(find.bySemanticsLabel('Start listening'));
    await _pumpFrames(tester);
    h.sockets.single.serverSends({'setupComplete': {}});
    await _pumpFrames(tester);
    expect(h.live.state, ListeningState.listening);

    final screenState =
        tester.state<State<LiveTranslationScreen>>(find.byType(LiveTranslationScreen));
    final socket = h.sockets.single;

    // ── Utterance 1 ──────────────────────────────────────────────────────
    h.capture.emitChunk();
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
    // Translated speech plays, then finishes.
    h.playback.active.add(true);
    await _pumpFrames(tester);
    socket.serverSends({
      'serverContent': {'turnComplete': true}
    });
    await _pumpFrames(tester);

    expect(find.text('أين المترو؟'), findsOneWidget);
    expect(find.text('Where is the metro?'), findsOneWidget);
    // The session must survive the first turn.
    expect(h.live.state, ListeningState.listening);
    expect(h.live.isListening, isTrue);
    expect(h.capture.stopCalls, 0, reason: 'microphone must stay hot');
    expect(h.capture.startCalls, 1, reason: 'capture started exactly once');
    expect(socket.incoming.isClosed, isFalse, reason: 'WebSocket stays open');

    // The screen (and thus its controller subscriptions) must NOT be rebuilt
    // from scratch when the hero view is replaced by the transcript view.
    expect(
      tester.state<State<LiveTranslationScreen>>(find.byType(LiveTranslationScreen)),
      same(screenState),
      reason: 'the live screen must not be recreated after the first translation',
    );

    // Playback ended → the gate must reopen after the 300 ms tail so the
    // next utterance can actually reach Gemini.
    h.playback.active.add(false);
    await _pumpFrames(tester);
    h.clock = h.clock.add(const Duration(milliseconds: 301));
    final sentBefore = socket.audioFrames;
    h.capture.emitChunk();
    expect(socket.audioFrames, sentBefore + 1,
        reason: 'mic uplink must resume after the translated audio finishes');

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
    await _pumpFrames(tester);

    // BOTH translations on screen, in their own bubbles.
    expect(find.text('أين المترو؟'), findsOneWidget);
    expect(find.text('كم سعر التذكرة؟'), findsOneWidget);
    expect(h.live.messages, hasLength(2));
    // Still one uninterrupted session.
    expect(h.sockets, hasLength(1), reason: 'no reconnect');
    expect(h.capture.startCalls, 1, reason: 'no capture restart');
    expect(h.live.state, ListeningState.listening);
    expect(tester.takeException(), isNull);

    // Release the session (and the diagnostics health timer) before teardown.
    await h.live.stopListening();
    await _pumpFrames(tester);
  });

  testWidgets('every finalized translation can be spoken by the device voice',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final h = _ShellHarness();
    await h.settings.setTargetLanguage('ar');
    await h.pumpShell(tester);
    await tester.tap(find.bySemanticsLabel('Start listening'));
    await _pumpFrames(tester);
    final socket = h.sockets.single;
    socket.serverSends({'setupComplete': {}});
    await _pumpFrames(tester);

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
    socket.serverSends({
      'serverContent': {
        'modelTurn': {
          'parts': [
            {
              'inlineData': {
                'mimeType': 'audio/pcm;rate=24000',
                'data': base64Encode(List.filled(48000, 4)),
              }
            }
          ]
        }
      }
    });
    socket.serverSends({
      'serverContent': {'turnComplete': true}
    });
    await _pumpFrames(tester);

    // Gemini's audio was discarded, nothing played by itself, and the pill
    // never claims to be speaking — the session just keeps listening.
    expect(h.playback.fedChunks, 0);
    expect(h.speech.spoken, isEmpty);
    expect(find.textContaining('Speaking translation'), findsNothing);
    expect(find.text('Listening…'), findsOneWidget);
    expect(h.live.state, ListeningState.listening);

    // The speaker button is available IMMEDIATELY once the text is final —
    // it needs no retained audio. (The bubble's own Semantics merges child
    // labels, so match loosely and tap the icon itself.)
    final speaker = find.byIcon(Icons.volume_up_outlined);
    expect(speaker, findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('Play translation')), findsWidgets);

    await tester.tap(speaker);
    await _pumpFrames(tester);
    // Spoken with the device voice, using a real BCP-47 voice locale for the
    // message's target language.
    expect(h.speech.spoken.single.text, 'أين المترو؟');
    expect(h.speech.spoken.single.languageCode, 'ar-SA');
    expect(h.playback.fedChunks, 0, reason: 'no Gemini PCM is ever played');

    // The uplink is quiet while it speaks, then resumes the moment it ends.
    final sentWhileSpeaking = socket.audioFrames;
    h.capture.emitChunk();
    expect(socket.audioFrames, sentWhileSpeaking,
        reason: 'microphone is quiet while the device speaks');
    h.speech.finish();
    await _pumpFrames(tester);
    h.capture.emitChunk();
    expect(socket.audioFrames, sentWhileSpeaking + 1,
        reason: 'microphone resumes as soon as speech ends');

    // Speaking never disturbs the session.
    expect(h.live.state, ListeningState.listening);
    expect(h.capture.startCalls, 1);
    expect(h.capture.stopCalls, 0);
    expect(h.sockets, hasLength(1));
    expect(tester.takeException(), isNull);

    await h.live.stopListening();
    await _pumpFrames(tester);
  });
}
