import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:live_translator/utils/mic_level.dart';

Uint8List pcmOf(List<int> samples) {
  final data = ByteData(samples.length * 2);
  for (var i = 0; i < samples.length; i++) {
    data.setInt16(i * 2, samples[i], Endian.little);
  }
  return data.buffer.asUint8List();
}

void main() {
  test('silence has zero level', () {
    expect(pcm16Rms(pcmOf(List.filled(160, 0))), 0);
    expect(micUiLevel(0), 0);
  });

  test('full-scale square wave has RMS 1.0', () {
    final rms = pcm16Rms(pcmOf(List.filled(160, -32768)));
    expect(rms, closeTo(1.0, 0.001));
    expect(micUiLevel(rms), 1.0);
  });

  test('a known sine amplitude produces the expected RMS', () {
    const amplitude = 8192; // quarter scale
    final samples = [
      for (var i = 0; i < 1600; i++) (amplitude * math.sin(2 * math.pi * i / 100)).round()
    ];
    final rms = pcm16Rms(pcmOf(samples));
    expect(rms, closeTo(amplitude / 32768 / math.sqrt2, 0.005));
  });

  test('empty and odd-length chunks are safe', () {
    expect(pcm16Rms(Uint8List(0)), 0);
    expect(pcm16Rms(Uint8List(1)), 0);
  });
}
