import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app.dart';
import 'features/live_translation/live_translation_controller.dart';
import 'firebase_options.dart';
import 'services/auth/auth_controller.dart';
import 'services/auth/auth_service.dart';
import 'services/billing/entitlement_controller.dart';
import 'services/billing/subscription_service.dart';
import 'services/firestore/session_repository.dart';
import 'services/firestore/user_repository.dart';
import 'services/gemini/live_translation_service.dart';
import 'services/gemini/token_client.dart';
import 'services/storage/settings_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  await FirebaseAppCheck.instance.activate(
    // Debug providers in development builds; hardware attestation in release.
    providerAndroid:
        kDebugMode ? const AndroidDebugProvider() : const AndroidPlayIntegrityProvider(),
    providerApple: kDebugMode
        ? const AppleDebugProvider()
        : const AppleAppAttestWithDeviceCheckFallbackProvider(),
  );

  final settings = SettingsController(SettingsStore());
  await settings.load();

  final userRepository = UserRepository();
  final sessionRepository = SessionRepository();
  final authController = AuthController(
    authService: AuthService(),
    userRepository: userRepository,
    settings: settings,
  );
  final liveService = LiveTranslationService(
    tokenProvider: LiveTranslateTokenClient().call,
  );

  // Server-authoritative plan + minutes. It follows the signed-in user and is
  // read-only to the app.
  final entitlements = EntitlementController();
  entitlements.bind(authController.uid);
  authController.addListener(() => entitlements.bind(authController.uid));

  final subscriptions = SubscriptionService()..listen();

  final liveController = LiveTranslationController(
    settings: settings,
    service: liveService,
    sessionRepository: sessionRepository,
    uidProvider: () => authController.uid,
  );
  // The metering heartbeat is the freshest number there is, so let it drive
  // the counter between Firestore snapshots.
  liveController.onMinutesRemaining = entitlements.applyRemaining;

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<SettingsController>.value(value: settings),
        ChangeNotifierProvider<AuthController>.value(value: authController),
        Provider<SessionRepository>.value(value: sessionRepository),
        ChangeNotifierProvider<EntitlementController>.value(value: entitlements),
        Provider<SubscriptionService>.value(value: subscriptions),
        ChangeNotifierProvider<LiveTranslationController>.value(
          value: liveController,
        ),
      ],
      child: const SayvoApp(),
    ),
  );
}
