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

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<SettingsController>.value(value: settings),
        ChangeNotifierProvider<AuthController>.value(value: authController),
        Provider<SessionRepository>.value(value: sessionRepository),
        ChangeNotifierProvider<LiveTranslationController>(
          create: (_) => LiveTranslationController(
            settings: settings,
            service: liveService,
            sessionRepository: sessionRepository,
            uidProvider: () => authController.uid,
          ),
        ),
      ],
      child: const LiveTranslatorApp(),
    ),
  );
}
