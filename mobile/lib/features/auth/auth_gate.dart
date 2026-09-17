import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/auth/auth_controller.dart';
import '../../services/storage/settings_store.dart';
import '../../theme/app_colors.dart';
import '../../widgets/components/app_background.dart';
import '../onboarding/onboarding_flow.dart';
import '../shell/home_shell.dart';
import 'auth_widgets.dart' show BrandMark;
import 'sign_in_screen.dart';

/// Root switch: splash while auth state is unknown, sign-in when signed out,
/// onboarding → main shell when signed in.
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
        settings.onboardingComplete ? const HomeShell() : const OnboardingFlow(),
    };
  }
}

class _Splash extends StatelessWidget {
  const _Splash();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: AppBackground(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const BrandMark(size: 88),
              const SizedBox(height: 20),
              Text('Live Translator',
                  style: theme.textTheme.headlineSmall
                      ?.copyWith(fontWeight: FontWeight.w800)),
              const SizedBox(height: 6),
              Text('Different languages. A closer world.',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: AppColors.textSecondary)),
              const SizedBox(height: 28),
              const SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(strokeWidth: 3),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
