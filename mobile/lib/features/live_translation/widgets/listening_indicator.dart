import 'package:flutter/material.dart';

/// "● Listening" pill with a pulsing dot and a small level-driven waveform.
/// Color is never the only cue — the text "Listening" is always present, and
/// tapping opens an explanation sheet with a Stop button (privacy §62).
class ListeningIndicator extends StatefulWidget {
  const ListeningIndicator({
    super.key,
    required this.micLevel,
    required this.activityLabel,
    required this.onStop,
  });

  final double micLevel;
  final String? activityLabel;
  final Future<void> Function() onStop;

  @override
  State<ListeningIndicator> createState() => _ListeningIndicatorState();
}

class _ListeningIndicatorState extends State<ListeningIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1100))
        ..repeat(reverse: true);

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  void _showMicSheet() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Icon(Icons.mic_rounded, size: 48),
              const SizedBox(height: 12),
              Text(
                'Microphone is currently active because Live Translation is running.',
                textAlign: TextAlign.center,
                style: Theme.of(sheetContext).textTheme.titleMedium,
              ),
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: () {
                  Navigator.pop(sheetContext);
                  widget.onStop();
                },
                icon: const Icon(Icons.stop_rounded),
                label: const Text('Stop Listening'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: _showMicSheet,
      borderRadius: BorderRadius.circular(24),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
        decoration: BoxDecoration(
          color: theme.colorScheme.errorContainer.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(24),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            FadeTransition(
              opacity: Tween(begin: 0.35, end: 1.0).animate(_pulse),
              child: Icon(Icons.circle, size: 12, color: theme.colorScheme.error),
            ),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Listening',
                    style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800)),
                Text(
                  widget.activityLabel ?? 'Automatically detecting languages',
                  style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.outline),
                ),
              ],
            ),
            const SizedBox(width: 14),
            _Waveform(level: widget.micLevel),
          ],
        ),
      ),
    );
  }
}

class _Waveform extends StatelessWidget {
  const _Waveform({required this.level});

  final double level;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    const shapes = [0.5, 0.9, 0.65, 1.0, 0.55];
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final shape in shapes)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 1.5),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 140),
              width: 4,
              height: 6 + 22 * shape * level.clamp(0.05, 1.0),
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(3),
              ),
            ),
          ),
      ],
    );
  }
}
