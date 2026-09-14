import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/auth/auth_controller.dart';
import '../../services/storage/settings_store.dart';
import '../live_translation/live_translation_screen.dart';
import '../onboarding/onboarding_flow.dart';
import 'sign_in_screen.dart';

/// Root switch: splash while auth state is unknown, sign-in when signed out,
/// onboarding → main translator when signed in.
class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthController>();
    final settings = context.watch<SettingsController>().settings;
    return switch (auth.status) {
      AuthStatus.unknown => const _Splash(),
      AuthStatus.signedOut => const SignInScreen(),
      AuthStatus.signedIn =>
        settings.onboardingComplete ? const LiveTranslationScreen() : const OnboardingFlow(),
    };
  }
}

class _Splash extends StatelessWidget {
  const _Splash();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.translate_rounded, size: 72, color: theme.colorScheme.primary),
            const SizedBox(height: 16),
            Text('Live Translator',
                style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
            const SizedBox(height: 24),
            const SizedBox(
              width: 28,
              height: 28,
              child: CircularProgressIndicator(strokeWidth: 3),
            ),
          ],
        ),
      ),
    );
  }
}
