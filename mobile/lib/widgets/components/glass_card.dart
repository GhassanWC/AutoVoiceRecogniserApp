import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';

/// The app's standard surface: translucent white fill, hairline border,
/// generous radius. Cheap by design — no backdrop blur (the background is a
/// static gradient, so translucency alone reads as glass).
class AppGlassCard extends StatelessWidget {
  const AppGlassCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.radius = 20,
    this.onTap,
    this.margin,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry? margin;

  @override
  Widget build(BuildContext context) {
    final borderRadius = BorderRadius.circular(radius);
    Widget card = Ink(
      decoration: BoxDecoration(
        color: AppColors.glassFill,
        borderRadius: borderRadius,
        border: Border.all(color: AppColors.glassBorder),
      ),
      child: Padding(padding: padding, child: child),
    );
    if (onTap != null) {
      card = InkWell(borderRadius: borderRadius, onTap: onTap, child: card);
    }
    return Padding(
      padding: margin ?? EdgeInsets.zero,
      child: Material(type: MaterialType.transparency, child: card),
    );
  }
}
