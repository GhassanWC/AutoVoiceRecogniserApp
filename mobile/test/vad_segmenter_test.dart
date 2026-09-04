import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:live_translator/services/audio/vad_segmenter.dart';

const sampleRate = 16000;
const chunkMs = 100;
const chunkBytes = sampleRate * 2 * chunkMs ~/ 1000; // 3200

Uint8List silence() => Uint8List(chunkBytes);

/// A square wave with the given peak amplitude; its RMS equals amplitude/32768.
Uint8List tone(int amplitude) {
  final chunk = Uint8List(chunkBytes);
  final data = ByteData.sublistView(chunk);
  for (var i = 0; i < chunkBytes ~/ 2; i++) {
    data.setInt16(i * 2, i.isEven ? amplitude : -amplitude, Endian.little);
  }
  return chunk;
}

/// Near-field speech: loud (RMS ≈ 0.24, ≈ −12 dBFS).
Uint8List loud() => tone(8000);

/// Distant/TV speech on an un-gained mic: quiet but clearly audible
/// (RMS ≈ 0.009, ≈ −41 dBFS) — must still be captured.
Uint8List distantSpeech() => tone(300);

/// Steady air-conditioner-style hum (RMS ≈ 0.005) — must NOT trigger.
Uint8List hum() => tone(164);

class _Recorder {
  final starts = <String>[];
  final chunks = <(String, int)>[];
  final ends = <(String, int)>[];
  final diagnostics = <VadDiagnostics>[];

  late final VadSegmenter vad;
  int _idCounter = 0;

  _Recorder() {
    vad = VadSegmenter(
      sampleRate: sampleRate,
      segmentIdFactory: () => 'seg-${_idCounter++}',
      onSegmentStart: (id, _) => starts.add(id),
      onAudio: (id, sequence, _) => chunks.add((id, sequence)),
      onSegmentEnd: (id, durationMs) => ends.add((id, durationMs)),
      onDiagnostics: diagnostics.add,
    );
  }
}

void main() {
  test('detects an utterance with pre-roll and closes it after the hangover', () {
    final recorder = _Recorder();
    for (var i = 0; i < 5; i++) {
      recorder.vad.addAudio(silence());
    }
    for (var i = 0; i < 10; i++) {
      recorder.vad.addAudio(loud());
    }
    // 900 ms hangover → 9 silent chunks close the segment.
    for (var i = 0; i < 9; i++) {
      recorder.vad.addAudio(silence());
    }

    expect(recorder.starts, hasLength(1));
    expect(recorder.ends, hasLength(1));
    final (id, durationMs) = recorder.ends.single;
    expect(id, recorder.starts.single);
    // All 5 quiet chunks fit inside the 1.5 s pre-roll window, so the start of
    // the sentence is fully preserved: 5 pre-roll + 10 speech + 9 hangover.
    expect(durationMs, 2400);
    // Sequences are contiguous from zero.
    final sequences = recorder.chunks.map((c) => c.$2).toList();
    expect(sequences, List.generate(24, (i) => i));
  });

  test('keeps up to 1.5 s of pre-roll so sentence beginnings are not lost', () {
    final recorder = _Recorder();
    for (var i = 0; i < 40; i++) {
      recorder.vad.addAudio(silence()); // 4 s of room tone
    }
    recorder.vad.addAudio(loud());
    // Only the most recent 15 chunks (1.5 s) of pre-roll are emitted.
    expect(recorder.chunks, hasLength(16));
  });

  test('splits an endless monologue at the maximum segment length', () {
    final recorder = _Recorder();
    for (var i = 0; i < 205; i++) {
      recorder.vad.addAudio(loud());
    }
    // 15 s cap → the first segment closes at exactly 15000 ms and detection
    // continues immediately — sustained speech must never become "noise".
    expect(recorder.starts.length, greaterThanOrEqualTo(2));
    expect(recorder.ends.first.$2, 15000);
  });

  test('captures distant/TV-level speech after ambience calibration', () {
    final recorder = _Recorder();
    for (var i = 0; i < 10; i++) {
      recorder.vad.addAudio(silence()); // quiet room, floor settles low
    }
    for (var i = 0; i < 10; i++) {
      recorder.vad.addAudio(distantSpeech());
    }
    for (var i = 0; i < 9; i++) {
      recorder.vad.addAudio(silence());
    }

    expect(recorder.starts, hasLength(1));
    expect(recorder.ends.single.$2, greaterThan(0)); // kept, not discarded
  });

  test('steady air-conditioner hum alone never triggers speech', () {
    final recorder = _Recorder();
    for (var i = 0; i < 200; i++) {
      recorder.vad.addAudio(hum()); // 20 s of constant hum
    }
    expect(recorder.starts, isEmpty);
  });

  test('speech clearly above a steady hum is still detected', () {
    final recorder = _Recorder();
    for (var i = 0; i < 100; i++) {
      recorder.vad.addAudio(hum()); // floor converges onto the hum
    }
    for (var i = 0; i < 10; i++) {
      recorder.vad.addAudio(loud());
    }
    expect(recorder.starts, hasLength(1));
  });

  test('reports a too-short blip with duration 0 so nothing is transcribed', () {
    final recorder = _Recorder();
    recorder.vad.addAudio(loud()); // 100 ms blip
    for (var i = 0; i < 9; i++) {
      recorder.vad.addAudio(silence());
    }
    expect(recorder.ends, hasLength(1));
    expect(recorder.ends.single.$2, 0);
  });

  test('pure silence produces no segments at all', () {
    final recorder = _Recorder();
    for (var i = 0; i < 100; i++) {
      recorder.vad.addAudio(silence());
    }
    expect(recorder.starts, isEmpty);
    expect(recorder.chunks, isEmpty);
  });

  test('flush closes an open segment immediately', () {
    final recorder = _Recorder();
    for (var i = 0; i < 6; i++) {
      recorder.vad.addAudio(loud());
    }
    expect(recorder.ends, isEmpty);
    recorder.vad.flush();
    expect(recorder.ends, hasLength(1));
    expect(recorder.ends.single.$2, 600);
  });

  test('emits diagnostics with rms, noise floor, threshold and segment events', () {
    final recorder = _Recorder();
    for (var i = 0; i < 3; i++) {
      recorder.vad.addAudio(silence());
    }
    for (var i = 0; i < 5; i++) {
      recorder.vad.addAudio(loud());
    }
    recorder.vad.flush();

    final levelTicks = recorder.diagnostics.where((d) => d.event == null);
    expect(levelTicks.length, 8); // one per chunk
    expect(levelTicks.first.isSpeech, isFalse);
    expect(levelTicks.last.isSpeech, isTrue);
    expect(levelTicks.last.rms, greaterThan(levelTicks.last.threshold));
    expect(recorder.diagnostics.map((d) => d.event), contains('segment_start'));
    expect(recorder.diagnostics.map((d) => d.event), contains('segment_end'));
  });
}
