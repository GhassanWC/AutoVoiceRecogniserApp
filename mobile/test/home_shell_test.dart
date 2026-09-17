import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:live_translator/features/live_translation/live_translation_controller.dart';
import 'package:live_translator/features/profile/profile_screen.dart';
import 'package:live_translator/features/shell/home_shell.dart';
import 'package:live_translator/services/audio/audio_capture_service.dart';
import 'package:live_translator/services/audio/audio_playback_service.dart';
import 'package:live_translator/services/auth/auth_controller.dart';
import 'package:live_translator/services/auth/auth_service.dart';
import 'package:live_translator/services/firestore/session_repository.dart';
import 'package:live_translator/services/firestore/user_repository.dart';
import 'package:live_translator/services/gemini/live_translation_service.dart';
import 'package:live_translator/services/permissions/mic_permission_service.dart';
import 'package:live_translator/services/storage/settings_store.dart';
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
  @override
  void send(String data) {}
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
  @override
  bool get isCapturing => running;
  @override
  Future<void> start({
    required void Function(Uint8List pcm) onAudio,
    required void Function(String reason) onStopped,
  }) async =>
      running = true;
  @override
  Future<void> stop() async => running = false;
}

class _FakePlayback extends AudioPlaybackService {
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
      capture: _FakeCapture(),
      playback: _FakePlayback(),
      backoffDelays: const [Duration.zero],
      playbackGateTail: Duration.zero,
      isOnline: () async => true,
    );
    live = LiveTranslationController(
      settings: settings,
      service: service,
      permissions: _GrantedPermissions(),
      sessionRepository: SessionRepository(firestore: firestore),
      uidProvider: () => 'user-1',
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
    expect(find.text('Live Translator'), findsOneWidget);
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
}
