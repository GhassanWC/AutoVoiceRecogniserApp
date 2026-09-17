import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';

/// Lightweight level-driven waveform: a handful of rounded bars whose heights
/// follow the microphone level. Purely visual — it never gates or alters the
/// audio pipeline. Animation is just AnimatedContainer easing between the
/// level updates the controller already emits (throttled upstream).
class AudioWaveform extends StatelessWidget {
  const AudioWaveform({
    super.key,
    required this.level,
    this.barCount = 7,
    this.maxBarHeight = 26,
    this.color,
  });

  /// 0..1 microphone level.
  final double level;
  final int barCount;
  final double maxBarHeight;
  final Color? color;

  // Static per-bar shape so the wave has a natural silhouette.
  static const List<double> _shapes = [0.45, 0.75, 1.0, 0.85, 0.6, 0.9, 0.5];

  @override
  Widget build(BuildContext context) {
    final barColor = color ?? AppColors.electricCyan;
    final clamped = level.clamp(0.06, 1.0);
    return ExcludeSemantics(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          for (var i = 0; i < barCount; i++)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 140),
                curve: Curves.easeOut,
                width: 3.5,
                height: 5 + maxBarHeight * _shapes[i % _shapes.length] * clamped,
                decoration: BoxDecoration(
                  color: barColor,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
