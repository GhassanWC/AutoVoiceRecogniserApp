import 'dart:async';

import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:live_translator/features/auth/auth_gate.dart';
import 'package:live_translator/features/auth/sign_in_screen.dart';
import 'package:live_translator/features/onboarding/onboarding_flow.dart';
import 'package:live_translator/services/auth/auth_controller.dart';
import 'package:live_translator/services/auth/auth_service.dart';
import 'package:live_translator/services/firestore/user_repository.dart';
import 'package:live_translator/services/storage/settings_store.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
  String? get displayName => 'Test User';
  @override
  String? get email => 'test@example.com';
  @override
  String? get photoURL => null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<(_FakeFirebaseAuth, WidgetTester)> pumpGate(WidgetTester tester) async {
    final auth = _FakeFirebaseAuth();
    final settings = SettingsController(SettingsStore());
    await settings.load();
    final controller = AuthController(
      authService: AuthService(auth: auth),
      userRepository: UserRepository(firestore: FakeFirebaseFirestore()),
      settings: settings,
    );
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SettingsController>.value(value: settings),
          ChangeNotifierProvider<AuthController>.value(value: controller),
        ],
        child: const MaterialApp(home: AuthGate()),
      ),
    );
    return (auth, tester);
  }

  testWidgets('unknown auth state shows the splash', (tester) async {
    await pumpGate(tester);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Live Translator'), findsOneWidget);
  });

  testWidgets('signed-out shows the sign-in screen', (tester) async {
    final (auth, _) = await pumpGate(tester);
    auth.states.add(null);
    await tester.pumpAndSettle();
    expect(find.byType(SignInScreen), findsOneWidget);
    expect(find.text('Sign In'), findsWidgets);
  });

  testWidgets('signed-in (fresh user) goes to onboarding', (tester) async {
    final (auth, _) = await pumpGate(tester);
    auth.user = _FakeUser();
    auth.states.add(auth.user);
    await tester.pumpAndSettle();
    expect(find.byType(OnboardingFlow), findsOneWidget);
  });

  testWidgets('signing out returns to the sign-in screen', (tester) async {
    final (auth, _) = await pumpGate(tester);
    auth.user = _FakeUser();
    auth.states.add(auth.user);
    await tester.pumpAndSettle();
    auth.user = null;
    auth.states.add(null);
    await tester.pumpAndSettle();
    expect(find.byType(SignInScreen), findsOneWidget);
  });
}
