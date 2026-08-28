import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:live_translator/services/audio/vad_segmenter.dart';

const sampleRate = 16000;
const chunkMs = 100;
const chunkBytes = sampleRate * 2 * chunkMs ~/ 1000; // 3200

Uint8List silence() => Uint8List(chunkBytes);

Uint8List loud() {
  final chunk = Uint8List(chunkBytes);
  final data = ByteData.sublistView(chunk);
  for (var i = 0; i < chunkBytes ~/ 2; i++) {
    data.setInt16(i * 2, i.isEven ? 8000 : -8000, Endian.little);
  }
  return chunk;
}

class _Recorder {
  final starts = <String>[];
  final chunks = <(String, int)>[];
  final ends = <(String, int)>[];

  late final VadSegmenter vad;
  int _idCounter = 0;

  _Recorder() {
    vad = VadSegmenter(
      sampleRate: sampleRate,
      segmentIdFactory: () => 'seg-${_idCounter++}',
      onSegmentStart: (id, _) => starts.add(id),
      onAudio: (id, sequence, _) => chunks.add((id, sequence)),
      onSegmentEnd: (id, durationMs) => ends.add((id, durationMs)),
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
    // 800 ms hangover → 8 silent chunks close the segment.
    for (var i = 0; i < 8; i++) {
      recorder.vad.addAudio(silence());
    }

    expect(recorder.starts, hasLength(1));
    expect(recorder.ends, hasLength(1));
    final (id, durationMs) = recorder.ends.single;
    expect(id, recorder.starts.single);
    // 3 pre-roll (350 ms cap) + 10 speech + 8 hangover chunks = 2100 ms.
    expect(durationMs, 2100);
    // Sequences are contiguous from zero.
    final sequences = recorder.chunks.map((c) => c.$2).toList();
    expect(sequences, List.generate(21, (i) => i));
  });

  test('splits an endless monologue at the maximum segment length', () {
    final recorder = _Recorder();
    for (var i = 0; i < 205; i++) {
      recorder.vad.addAudio(loud());
    }
    // 10 s cap → segments of 100 chunks each.
    expect(recorder.starts.length, greaterThanOrEqualTo(2));
    expect(recorder.ends.first.$2, 10000);
  });

  test('reports a too-short blip with duration 0 so nothing is transcribed', () {
    final recorder = _Recorder();
    recorder.vad.addAudio(loud()); // 100 ms blip
    for (var i = 0; i < 8; i++) {
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
}
