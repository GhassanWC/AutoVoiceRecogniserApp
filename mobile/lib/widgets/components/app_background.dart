import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';

/// The midnight canvas every screen sits on: a vertical navy gradient with
/// two soft radial accents (blue top-left, violet bottom-right). Purely
/// static — painted once, no animation, no blur.
class AppBackground extends StatelessWidget {
  const AppBackground({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(gradient: AppColors.backgroundGradient),
      child: Stack(
        fit: StackFit.expand,
        children: [
          const _RadialAccent(
            alignment: Alignment(-1.2, -1.1),
            color: AppColors.primaryBlue,
            radius: 0.9,
          ),
          const _RadialAccent(
            alignment: Alignment(1.3, 1.2),
            color: AppColors.violet,
            radius: 1.0,
          ),
          child,
        ],
      ),
    );
  }
}

class _RadialAccent extends StatelessWidget {
  const _RadialAccent({
    required this.alignment,
    required this.color,
    required this.radius,
  });

  final Alignment alignment;
  final Color color;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: alignment,
            radius: radius,
            colors: [color.withValues(alpha: 0.14), Colors.transparent],
          ),
        ),
      ),
    );
  }
}
