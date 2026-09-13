import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:live_translator/services/native/detecting_speech_engine.dart';
import 'package:live_translator/services/native/language_id.dart';

/// REGRESSION GUARD (critical): the developer detector tests and the live
/// session engine must route utterance PCM through the SAME
/// prepareLanguageIdAudio() path. Two preprocessing pipelines caused the
/// live-mode "Couldn't identify the spoken language." regression — never
/// again.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('prepareLanguageIdAudio (the single preprocessing path)', () {
    test('is deterministic: same PCM in → identical bytes out', () {
      final pcm = Uint8List.fromList(
          List.generate(16000 * 2 * 2, (i) => i % 251)); // 2 s
      final a = prepareLanguageIdAudio(pcm);
      final b = prepareLanguageIdAudio(pcm);
      expect(a, b);
      expect(a, pcm, reason: 'well-formed audio passes through unchanged');
    });

    test('trims an odd trailing byte (PCM16 must be even)', () {
      final pcm = Uint8List.fromList(List.generate(1601, (i) => i % 251));
      expect(prepareLanguageIdAudio(pcm).length, 1600);
    });

    test('caps runaway buffers at 15 s, keeping the middle', () {
      final pcm = Uint8List(20 * 16000 * 2); // 20 s of zeros
      final out = prepareLanguageIdAudio(pcm);
      expect(out.length, 15 * 16000 * 2);
    });
  });

  test('LIVE engine sends exactly prepareLanguageIdAudio(pcm) to the detector',
      () async {
    const channel = MethodChannel('app.livetranslator/langid');
    Uint8List? receivedByNative;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'warmup') return null;
      if (call.method == 'detectAndTranscribe') {
        final args = call.arguments as Map<Object?, Object?>;
        receivedByNative = args['pcm16'] as Uint8List;
        return <Object?, Object?>{
          'language': 'en',
          'confidence': 0.9,
          'alternatives': [
            {'language': 'en', 'confidence': 0.9},
            {'language': 'de', 'confidence': 0.02},
          ],
          'detectionMs': 5,
          'speechAvailable': true,
          'backend': 'onDevice',
          'locale': 'en-US',
          'text': 'hello there',
          'speechMs': 10,
        };
      }
      return null;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));

    // Deliberately malformed input (odd length) so pass-through would differ.
    final raw = Uint8List.fromList(
        List.generate(16000 * 2 * 2 + 1, (i) => (i * 7) % 251));
    final engine = DetectingSpeechEngine();
    await engine.load(const []);
    final transcript = await engine.transcribe(raw, 16000);

    expect(transcript.text, 'hello there');
    expect(transcript.language, 'en');
    expect(receivedByNative, isNotNull);
    expect(receivedByNative, prepareLanguageIdAudio(raw),
        reason: 'live path MUST use the shared preparation function — the '
            'same one the developer detector tests call');
  });

  test('margin rule: dominant low-confidence top-1 is ACCEPTED, photo finish is not',
      () async {
    const channel = MethodChannel('app.livetranslator/langid');
    var top1 = 0.34;
    var top2 = 0.05;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'warmup') return null;
      return <Object?, Object?>{
        'language': 'en',
        'confidence': top1,
        'alternatives': [
          {'language': 'en', 'confidence': top1},
          {'language': 'de', 'confidence': top2},
        ],
        'detectionMs': 5,
        'speechAvailable': true,
        'backend': 'onDevice',
        'locale': 'en-US',
        'text': 'hello',
        'speechMs': 10,
      };
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));

    final engine = DetectingSpeechEngine();
    await engine.load(const []);
    final pcm = Uint8List(16000 * 2);

    // en 0.34 vs cy-like 0.05: strong identification despite top1 < 0.40.
    final dominant = await engine.transcribe(pcm, 16000);
    expect(dominant.discardNotice, isNull);
    expect(dominant.text, 'hello');

    // en 0.27 vs de 0.25: genuinely ambiguous → discarded with the notice.
    top1 = 0.27;
    top2 = 0.25;
    final ambiguous = await engine.transcribe(pcm, 16000);
    expect(ambiguous.discardNotice, "Couldn't identify the spoken language.");
    expect(ambiguous.text, isEmpty);
  });
}
