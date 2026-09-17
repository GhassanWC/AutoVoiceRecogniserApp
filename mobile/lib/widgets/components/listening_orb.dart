import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';

/// The visual state the orb renders. Mirrors the controller's states without
/// importing it, so the component stays presentation-only.
enum OrbState { idle, connecting, listening }

/// The hero microphone: layered gradient ring, glow, pulse rings while
/// listening. One [AnimationController] drives the rings and runs ONLY while
/// connecting/listening — idle is a static glow, so an app left open on the
/// Home tab produces no frames. The static core sits in its own
/// [RepaintBoundary]; only the thin rings repaint per frame. Purely visual —
/// audio capture is untouched by anything here.
class ListeningOrb extends StatefulWidget {
  const ListeningOrb({
    super.key,
    required this.state,
    required this.onTap,
    this.size = 168,
    this.micLevel = 0,
  });

  final OrbState state;
  final VoidCallback onTap;
  final double size;

  /// 0..1 microphone level; modulates the listening pulse. Visual only.
  final double micLevel;

  @override
  State<ListeningOrb> createState() => _ListeningOrbState();
}

class _ListeningOrbState extends State<ListeningOrb>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ticker = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2800),
  );

  bool _reduceMotion = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.disableAnimationsOf(context);
    _syncTicker();
  }

  @override
  void didUpdateWidget(ListeningOrb oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state != widget.state) _syncTicker();
  }

  void _syncTicker() {
    final animate = widget.state != OrbState.idle && !_reduceMotion;
    if (animate && !_ticker.isAnimating) {
      _ticker.repeat();
    } else if (!animate && _ticker.isAnimating) {
      _ticker.stop();
      _ticker.value = 0;
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  String get _semanticsLabel => switch (widget.state) {
        OrbState.idle => 'Start listening',
        OrbState.connecting => 'Connecting to translation service',
        OrbState.listening => 'Stop listening',
      };

  @override
  Widget build(BuildContext context) {
    final size = widget.size;
    return Semantics(
      button: true,
      label: _semanticsLabel,
      child: GestureDetector(
        onTap: widget.onTap,
        child: RepaintBoundary(
          child: SizedBox(
            // Room for the pulse rings around the orb itself.
            width: size * 1.45,
            height: size * 1.45,
            child: AnimatedBuilder(
              animation: _ticker,
              builder: (context, child) => CustomPaint(
                painter: _OrbPainter(
                  progress: _ticker.value,
                  state: widget.state,
                  level: widget.micLevel,
                ),
                child: child,
              ),
              child: Center(
                child: RepaintBoundary(
                  child: _OrbCore(state: widget.state, size: size),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _OrbCore extends StatelessWidget {
  const _OrbCore({required this.state, required this.size});

  final OrbState state;
  final double size;

  @override
  Widget build(BuildContext context) {
    final listening = state == OrbState.listening;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: AppColors.orbGradient,
        boxShadow: [
          BoxShadow(
            color: AppColors.primaryBlue.withValues(alpha: listening ? 0.55 : 0.35),
            blurRadius: listening ? 46 : 30,
            spreadRadius: listening ? 6 : 2,
          ),
          BoxShadow(
            color: AppColors.violet.withValues(alpha: 0.25),
            blurRadius: 60,
            offset: const Offset(0, 14),
          ),
        ],
      ),
      // Gradient ring: the inner circle is inset, leaving the gradient as rim.
      padding: EdgeInsets.all(size * 0.055),
      child: DecoratedBox(
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            colors: [Color(0xFF0E3E86), Color(0xFF082757)],
            radius: 0.85,
          ),
        ),
        child: Center(
          child: state == OrbState.connecting
              ? SizedBox(
                  width: size * 0.32,
                  height: size * 0.32,
                  child: const CircularProgressIndicator(
                    strokeWidth: 3,
                    color: Colors.white,
                  ),
                )
              : Icon(
                  state == OrbState.listening
                      ? Icons.stop_rounded
                      : Icons.mic_rounded,
                  size: size * 0.36,
                  color: Colors.white,
                ),
        ),
      ),
    );
  }
}

class _OrbPainter extends CustomPainter {
  _OrbPainter({required this.progress, required this.state, required this.level});

  final double progress;
  final OrbState state;
  final double level;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final baseRadius = size.width / 1.45 / 2;

    switch (state) {
      case OrbState.idle:
        // Static: one faint halo ring; the core's glow does the rest.
        _ring(canvas, center, baseRadius * 1.06,
            AppColors.electricCyan.withValues(alpha: 0.12), 2);
      case OrbState.connecting:
        // A rotating gradient arc just outside the rim.
        final rect = Rect.fromCircle(center: center, radius: baseRadius * 1.08);
        final paint = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3
          ..strokeCap = StrokeCap.round
          ..shader = SweepGradient(
            startAngle: 0,
            endAngle: 2 * math.pi,
            transform: GradientRotation(progress * 2 * math.pi),
            colors: [
              AppColors.electricCyan.withValues(alpha: 0),
              AppColors.electricCyan,
              AppColors.violetBright,
              AppColors.electricCyan.withValues(alpha: 0),
            ],
            stops: const [0.0, 0.35, 0.6, 1.0],
          ).createShader(rect);
        canvas.drawArc(rect, 0, 2 * math.pi, false, paint);
      case OrbState.listening:
        // Two expanding pulse rings; amplitude follows the mic level.
        final boost = 0.6 + 0.4 * level.clamp(0.0, 1.0);
        for (final phase in const [0.0, 0.5]) {
          final t = (progress + phase) % 1.0;
          final alpha = (1 - t) * 0.30 * boost;
          if (alpha <= 0.01) continue;
          _ring(
            canvas,
            center,
            baseRadius * (1.02 + 0.30 * t),
            AppColors.electricCyan.withValues(alpha: alpha),
            2.5 - 1.5 * t,
          );
        }
    }
  }

  void _ring(Canvas canvas, Offset center, double radius, Color color, double width) {
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = width
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(_OrbPainter old) =>
      old.progress != progress || old.state != state || old.level != level;
}
