import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';
import '../../widgets/components/app_background.dart';
import '../../widgets/components/app_error_banner.dart';
import '../../widgets/components/gradient_button.dart';

/// Shared building blocks for the auth screens: midnight background, glowing
/// brand mark, glass fields (via theme), gradient CTA.

class AuthScaffold extends StatelessWidget {
  const AuthScaffold({
    super.key,
    required this.title,
    required this.subtitle,
    required this.children,
    this.showBack = true,
  });

  final String title;
  final String subtitle;
  final List<Widget> children;
  final bool showBack;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: AppBackground(
        child: SafeArea(
          child: Stack(
            children: [
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 480),
                  child: ListView(
                    shrinkWrap: true,
                    padding: EdgeInsets.fromLTRB(24, showBack ? 56 : 40, 24, 24),
                    children: [
                      const Center(child: BrandMark()),
                      const SizedBox(height: 18),
                      Text(title,
                          textAlign: TextAlign.center,
                          style: theme.textTheme.headlineSmall
                              ?.copyWith(fontWeight: FontWeight.w800)),
                      const SizedBox(height: 8),
                      Text(subtitle,
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodyMedium
                              ?.copyWith(color: AppColors.textSecondary)),
                      const SizedBox(height: 26),
                      ...children,
                    ],
                  ),
                ),
              ),
              // Topmost so a full-height (scrolling) list can never swallow
              // its taps.
              if (showBack)
                const Positioned(
                  top: 4,
                  left: 4,
                  child: BackButton(color: AppColors.textPrimary),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The Sayvo mark: a glowing gradient disc with the translate glyph.
class BrandMark extends StatelessWidget {
  const BrandMark({super.key, this.size = 74});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: AppColors.orbGradient,
        boxShadow: [
          BoxShadow(
            color: AppColors.primaryBlue.withValues(alpha: 0.45),
            blurRadius: 30,
          ),
        ],
      ),
      child: Icon(Icons.translate_rounded, size: size * 0.46, color: Colors.white),
    );
  }
}

/// The controller's exact error text (Firebase/Google codes included when
/// the service surfaces them) in the shared error card.
class AuthErrorText extends StatelessWidget {
  const AuthErrorText(this.message, {super.key});
  final String? message;

  @override
  Widget build(BuildContext context) {
    if (message == null) return const SizedBox.shrink();
    return AppErrorBanner(
      message: message!,
      margin: const EdgeInsets.only(bottom: 14),
    );
  }
}

/// Gradient CTA with busy state — auth screens' primary action.
class BusyFilledButton extends StatelessWidget {
  const BusyFilledButton({
    super.key,
    required this.busy,
    required this.onPressed,
    required this.label,
  });

  final bool busy;
  final VoidCallback? onPressed;
  final String label;

  @override
  Widget build(BuildContext context) {
    return GradientButton(label: label, onPressed: onPressed, busy: busy);
  }
}

class OrDivider extends StatelessWidget {
  const OrDivider({super.key, this.label = 'or continue with email'});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      const Expanded(child: Divider()),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Text(
          label,
          style: Theme.of(context)
              .textTheme
              .bodySmall
              ?.copyWith(color: AppColors.textTertiary),
        ),
      ),
      const Expanded(child: Divider()),
    ]);
  }
}

/// Google + Apple buttons (Apple only on iOS, per platform guidelines).
class SocialSignInButtons extends StatelessWidget {
  const SocialSignInButtons({
    super.key,
    required this.busy,
    required this.onGoogle,
    required this.onApple,
  });

  final bool busy;
  final VoidCallback onGoogle;
  final VoidCallback onApple;

  static bool get _isIos => !kIsWeb && Platform.isIOS;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        OutlinedButton.icon(
          onPressed: busy ? null : onGoogle,
          icon: const Icon(Icons.g_mobiledata_rounded,
              size: 30, color: Colors.white),
          label: const Text('Continue with Google'),
        ),
        if (_isIos) ...[
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: busy ? null : onApple,
            icon: const Icon(Icons.apple_rounded, size: 26, color: Colors.white),
            label: const Text('Continue with Apple'),
          ),
        ],
      ],
    );
  }
}
