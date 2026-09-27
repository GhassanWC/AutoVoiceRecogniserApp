import 'package:flutter/material.dart';

import '../../../services/diagnostics/audio_diagnostics.dart';

/// DEVELOPMENT ONLY. What the microphone is delivering and what Sayvo did
/// with it, live, so far-field tuning can be done in the room instead of
/// afterwards in a log file.
///
/// Built into the binary only when the build passes
/// `--dart-define=SAYVO_DIAGNOSTICS=true` ([kAudioDiagnosticsUi]); a
/// production App Store build does not contain it. Shows numbers only — never
/// transcript text — so a screenshot of a tuning session is not a recording
/// of somebody's conversation.
class AudioDiagnosticsPanel extends StatelessWidget {
  const AudioDiagnosticsPanel({super.key, required this.stream});

  final Stream<AudioDiagnostics> stream;

  @override
  Widget build(BuildContext context) {
    if (!kAudioDiagnosticsUi) return const SizedBox.shrink();
    return StreamBuilder<AudioDiagnostics>(
      stream: stream,
      initialData: AudioDiagnostics.idle,
      builder: (context, snapshot) {
        final d = snapshot.data ?? AudioDiagnostics.idle;
        return Container(
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.72),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.white24),
          ),
          child: DefaultTextStyle(
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 11.5,
              height: 1.45,
              color: Colors.white,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('AUDIO DIAGNOSTICS  (dev build)',
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 10,
                      letterSpacing: 1.1,
                      color: Colors.white54,
                    )),
                const SizedBox(height: 6),
                _Row('Mic level', '${d.inputDbfs} dBFS'),
                _Row('Peak', '${d.peakDbfs} dBFS'),
                _Row('Noise floor', '${d.noiseFloorDbfs} dBFS'),
                _Row('Gain applied', '${d.gain.toStringAsFixed(2)}×'
                    '${d.clippedSamples > 0 ? '  (${d.clippedSamples} clipped)' : ''}'),
                _Row('Sent to Gemini', '${d.processedDbfs} dBFS'),
                const Divider(height: 14, color: Colors.white24),
                _Row(
                  'Sending audio',
                  d.sending ? 'YES' : 'NO — ${d.notSendingReason}',
                  color: d.sending ? Colors.greenAccent : Colors.orangeAccent,
                ),
                _Row('Chunks', 'sent ${d.chunksSent} · dropped ${d.chunksDropped}'),
                _Row('Speech (local meter)', d.speechDetected ? 'YES' : 'no'),
                _Row(
                  'Gemini detection',
                  d.lastDetectionLatency == null
                      ? 'no utterance yet'
                      : '${d.lastDetectionLatency!.inMilliseconds} ms after '
                          'room rose',
                  color: Colors.cyanAccent,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _Row extends StatelessWidget {
  const _Row(this.label, this.value, {this.color});

  final String label;
  final String value;
  final Color? color;

  @override
  Widget build(BuildContext context) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 132,
            child: Text(label,
                style: const TextStyle(
                    fontFamily: 'monospace', fontSize: 11.5, color: Colors.white60)),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                  fontFamily: 'monospace', fontSize: 11.5, color: color ?? Colors.white),
            ),
          ),
        ],
      );
}
