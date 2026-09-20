import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:live_translator/services/audio/adaptive_gain.dart';
import 'package:live_translator/utils/mic_level.dart';

/// ~100 ms of 16 kHz mono PCM16 holding a 220 Hz tone at [amplitude] of full
/// scale — a stand-in for a voice at a given loudness.
Uint8List tone(double amplitude, {int samples = 1600}) {
  final pcm = Uint8List(samples * 2);
  final view = ByteData.sublistView(pcm);
  for (var i = 0; i < samples; i++) {
    final value = math.sin(2 * math.pi * 220 * i / 16000) * amplitude;
    view.setInt16(i * 2, (value * 32767).round().clamp(-32768, 32767),
        Endian.little);
  }
  return pcm;
}

/// Digital silence with a whisper of dither, like a quiet room.
Uint8List roomNoise({double amplitude = 0.0008, int samples = 1600}) {
  final random = math.Random(7);
  final pcm = Uint8List(samples * 2);
  final view = ByteData.sublistView(pcm);
  for (var i = 0; i < samples; i++) {
    final value = (random.nextDouble() * 2 - 1) * amplitude;
    view.setInt16(i * 2, (value * 32767).round(), Endian.little);
  }
  return pcm;
}

/// Runs [chunks] of the same signal through the gain so its level tracking
/// settles, and returns the final report.
GainReport settle(AdaptiveGain gain, Uint8List pcm, {int chunks = 40}) {
  final out = Uint8List(pcm.length);
  late GainReport report;
  for (var i = 0; i < chunks; i++) {
    report = gain.apply(pcm, out);
  }
  return report;
}

/// Reads PCM16LE back as normalized doubles, so a test can check the samples
/// really are valid PCM and not, say, byte-swapped. Normalized by 32768 — the
/// same convention as the pipeline, so a legitimate −32768 reads as exactly
/// −1.0 rather than appearing to be out of range.
List<double> samplesOf(Uint8List pcm) {
  final view = ByteData.sublistView(pcm);
  return [
    for (var i = 0; i < pcm.lengthInBytes ~/ 2; i++)
      view.getInt16(i * 2, Endian.little) / 32768.0,
  ];
}

void main() {
  group('quiet speech survives the pipeline', () {
    test('a far-field level is lifted toward a detectable one', () {
      // Roughly −40 dBFS: a real level for someone across a room with no AGC.
      final gain = AdaptiveGain();
      final report = settle(gain, tone(0.014));
      expect(report.appliedGain, greaterThan(2.0));
      expect(report.processedRms, greaterThan(report.rawRms * 2));
      // ...and brought near the target, not past it.
      expect(report.processedRms, closeTo(gain.targetRms, 0.03));
    });

    test('the lift is bounded, however quiet the voice', () {
      final gain = AdaptiveGain();
      final report = settle(gain, tone(0.0015), chunks: 200);
      expect(report.appliedGain, lessThanOrEqualTo(gain.maxGain));
    });

    test('amplified audio is still valid PCM16 in range', () {
      final gain = AdaptiveGain();
      final pcm = tone(0.02);
      final out = Uint8List(pcm.length);
      settle(gain, pcm);
      gain.apply(pcm, out);

      expect(out.lengthInBytes, pcm.lengthInBytes);
      final values = samplesOf(out);
      expect(values.every((v) => v >= -1.0 && v <= 1.0), isTrue);
      // Still a 220 Hz tone, not noise: it crosses zero the same number of
      // times as the input.
      final crossings = _zeroCrossings(values);
      expect(crossings, closeTo(_zeroCrossings(samplesOf(pcm)), 2));
    });

    test('a very low-amplitude chunk is never dropped or zeroed', () {
      final gain = AdaptiveGain();
      final pcm = tone(0.002);
      final out = Uint8List(pcm.length);
      final report = gain.apply(pcm, out);
      expect(report.rawRms, greaterThan(0));
      expect(samplesOf(out).any((v) => v.abs() > 0), isTrue,
          reason: 'quiet audio must still come out the other side');
    });
  });

  group('louder speech is left alone', () {
    test('a normal close voice is not unnecessarily amplified', () {
      // ~−20 dBFS, already above the target.
      final report = settle(AdaptiveGain(), tone(0.1));
      expect(report.appliedGain, closeTo(1.0, 0.01));
      expect(report.processedRms, closeTo(report.rawRms, 0.001));
    });

    test('a loud voice does not clip', () {
      final gain = AdaptiveGain();
      final report = settle(gain, tone(0.95));
      expect(report.appliedGain, closeTo(1.0, 0.01));
      expect(report.clippedSamples, 0);
      expect(report.peakAfterGain, lessThanOrEqualTo(1.0));
    });

    test('a sudden shout after quiet speech is caught by the limiter', () {
      final gain = AdaptiveGain();
      // Gain winds up on a quiet talker...
      settle(gain, tone(0.01));
      expect(gain.gain, greaterThan(2.0));
      // ...then somebody speaks right next to the phone.
      final loud = tone(0.9);
      final out = Uint8List(loud.length);
      final report = gain.apply(loud, out);
      expect(report.peakAfterGain, lessThanOrEqualTo(1.0));
      expect(samplesOf(out).every((v) => v >= -1.0 && v <= 1.0), isTrue);
      // And the gain drops fast so the next chunk is already tamer.
      final after = gain.apply(loud, out);
      expect(after.appliedGain, lessThan(report.appliedGain));
    });
  });

  group('the room itself is not amplified', () {
    test('steady quiet noise does not get runaway gain', () {
      final gain = AdaptiveGain();
      final report = settle(gain, roomNoise(), chunks: 300);
      // Whatever gain it settles on, the amplified noise stays below the
      // ceiling — this is what stops a silent room being walked up to full
      // scale and read as speech.
      expect(report.processedRms, lessThanOrEqualTo(gain.noiseCeiling));
    });

    test('digital silence stays silent', () {
      final gain = AdaptiveGain();
      final pcm = Uint8List(3200);
      final out = Uint8List(3200);
      settle(gain, pcm, chunks: 100);
      final report = gain.apply(pcm, out);
      expect(report.processedRms, 0);
      expect(samplesOf(out).every((v) => v == 0), isTrue);
    });

    test('noise does not stop real speech being lifted afterwards', () {
      final gain = AdaptiveGain();
      settle(gain, roomNoise(), chunks: 100);
      final report = settle(gain, tone(0.014));
      expect(report.appliedGain, greaterThan(2.0));
    });
  });

  group('the A/B baseline', () {
    test('disabled gain passes every sample through untouched', () {
      final gain = AdaptiveGain(enabled: false);
      final pcm = tone(0.01);
      final out = Uint8List(pcm.length);
      settle(gain, pcm);
      final report = gain.apply(pcm, out);
      expect(report.appliedGain, 1.0);
      expect(out, orderedEquals(pcm));
    });
  });

  group('level measurement agrees with the pipeline', () {
    test('rms matches what the waveform and billing see', () {
      // One measurement of level, used by the meter, the UI and the gain —
      // if these diverged, a diagnostic line would be describing a different
      // signal from the one being sent.
      final pcm = tone(0.05);
      final out = Uint8List(pcm.length);
      final report = AdaptiveGain(enabled: false).apply(pcm, out);
      expect(report.rawRms, closeTo(pcm16Rms(pcm), 1e-9));
    });
  });
}

int _zeroCrossings(List<double> values) {
  var count = 0;
  for (var i = 1; i < values.length; i++) {
    if ((values[i - 1] < 0) != (values[i] < 0)) count++;
  }
  return count;
}
