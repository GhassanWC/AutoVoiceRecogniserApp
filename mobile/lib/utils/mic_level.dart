import 'dart:math' as math;
import 'dart:typed_data';

/// RMS of a PCM16LE mono chunk, normalized to 0..1 of full scale.
/// Used ONLY for the microphone waveform animation — never to gate audio.
double pcm16Rms(Uint8List pcm) {
  final samples = pcm.lengthInBytes ~/ 2;
  if (samples == 0) return 0;
  final data = ByteData.sublistView(pcm, 0, samples * 2);
  var sumSquares = 0.0;
  for (var i = 0; i < samples; i++) {
    final sample = data.getInt16(i * 2, Endian.little) / 32768.0;
    sumSquares += sample * sample;
  }
  return math.sqrt(sumSquares / samples);
}

/// Maps a raw RMS value to a 0..1 UI level. Far-field speech is quiet
/// (capture runs without AGC on iOS), so the curve boosts low levels.
double micUiLevel(double rms) => (math.sqrt(rms) * 3.2).clamp(0.0, 1.0);
