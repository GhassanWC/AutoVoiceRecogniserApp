import 'dart:math' as math;

import 'package:flutter/foundation.dart';

/// Whether the on-screen audio diagnostics panel is built into this binary.
///
/// OFF unless the build asks for it:
///   flutter build ipa --dart-define=SAYVO_DIAGNOSTICS=true
///
/// A production App Store build therefore contains no developer overlay at
/// all. The `[LT]` log lines are separate and stay on — they are invisible to
/// the user and are what a TestFlight tuning session reads.
const bool kAudioDiagnosticsUi =
    bool.fromEnvironment('SAYVO_DIAGNOSTICS');

/// One snapshot of what the microphone is actually delivering and what Sayvo
/// did with it. Numbers only — never audio, never transcript text.
@immutable
class AudioDiagnostics {
  const AudioDiagnostics({
    required this.inputRms,
    required this.inputPeak,
    required this.processedRms,
    required this.noiseFloor,
    required this.gain,
    required this.clippedSamples,
    required this.sending,
    required this.notSendingReason,
    required this.chunksSent,
    required this.chunksDropped,
    required this.speechDetected,
    required this.lastDetectionLatency,
    required this.lastUtteranceAt,
  });

  static const AudioDiagnostics idle = AudioDiagnostics(
    inputRms: 0,
    inputPeak: 0,
    processedRms: 0,
    noiseFloor: 0,
    gain: 1,
    clippedSamples: 0,
    sending: false,
    notSendingReason: 'not listening',
    chunksSent: 0,
    chunksDropped: 0,
    speechDetected: false,
    lastDetectionLatency: null,
    lastUtteranceAt: null,
  );

  /// Level of the signal as the microphone delivered it, 0..1 of full scale.
  final double inputRms;
  final double inputPeak;

  /// Level of what actually went on the wire, after [gain].
  final double processedRms;

  final double noiseFloor;
  final double gain;
  final int clippedSamples;

  /// Whether audio is reaching Gemini right now, and if not, why. There is no
  /// level in that answer: Sayvo never withholds audio for being quiet.
  final bool sending;
  final String notSendingReason;

  final int chunksSent;
  final int chunksDropped;

  /// The passive billing meter's opinion. Shown because it is a useful second
  /// reading of the room — it gates nothing.
  final bool speechDetected;

  /// Room audio rising above the noise floor → the model's first transcript
  /// for that utterance. This is the number that says whether quiet speech is
  /// being detected late, or not at all.
  final Duration? lastDetectionLatency;
  final DateTime? lastUtteranceAt;

  static String dbfs(double value) => value <= 0
      ? '-inf'
      : (20 * (math.log(value) / math.ln10)).toStringAsFixed(1);

  String get inputDbfs => dbfs(inputRms);
  String get peakDbfs => dbfs(inputPeak);
  String get processedDbfs => dbfs(processedRms);
  String get noiseFloorDbfs => dbfs(noiseFloor);

  AudioDiagnostics copyWith({
    double? inputRms,
    double? inputPeak,
    double? processedRms,
    double? noiseFloor,
    double? gain,
    int? clippedSamples,
    bool? sending,
    String? notSendingReason,
    int? chunksSent,
    int? chunksDropped,
    bool? speechDetected,
    Duration? lastDetectionLatency,
    DateTime? lastUtteranceAt,
  }) =>
      AudioDiagnostics(
        inputRms: inputRms ?? this.inputRms,
        inputPeak: inputPeak ?? this.inputPeak,
        processedRms: processedRms ?? this.processedRms,
        noiseFloor: noiseFloor ?? this.noiseFloor,
        gain: gain ?? this.gain,
        clippedSamples: clippedSamples ?? this.clippedSamples,
        sending: sending ?? this.sending,
        notSendingReason: notSendingReason ?? this.notSendingReason,
        chunksSent: chunksSent ?? this.chunksSent,
        chunksDropped: chunksDropped ?? this.chunksDropped,
        speechDetected: speechDetected ?? this.speechDetected,
        lastDetectionLatency: lastDetectionLatency ?? this.lastDetectionLatency,
        lastUtteranceAt: lastUtteranceAt ?? this.lastUtteranceAt,
      );
}
