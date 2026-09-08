import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:live_translator/services/local/local_language_detect.dart';
import 'package:live_translator/services/local/local_pipeline.dart';
import 'package:live_translator/services/local/local_speech_engine.dart';
import 'package:live_translator/services/local/local_translation_engine.dart';
import 'package:live_translator/services/local/whisperkit_models.dart';

class FakeLocalSpeechEngine implements LocalSpeechEngine {
  FakeLocalSpeechEngine(this.responses);

  /// Consumed in order; each transcription pops one.
  final List<LocalTranscript> responses;
  final List<int> receivedByteLengths = [];
  bool loaded = false;

  @override
  bool get isLoaded => loaded;

  @override
  Future<void> load(String modelPath) async {
    loaded = true;
  }

  @override
  Future<LocalTranscript> transcribe(Uint8List pcm16, int sampleRate) async {
    receivedByteLengths.add(pcm16.length);
    if (responses.isEmpty) throw StateError('no scripted transcript');
    return responses.removeAt(0);
  }

  @override
  Future<void> dispose() async {}
}

class _Resolved {
  _Resolved(this.messageId, this.originalText, this.sourceLanguage, this.translatedText,
      this.translated);
  final String messageId;
  final String originalText;
  final String sourceLanguage;
  final String translatedText;
  final bool translated;
}

({LocalPipeline pipeline, List<String> created, List<_Resolved> resolved}) buildPipeline(
  FakeLocalSpeechEngine engine, {
  String targetLanguage = 'ar',
}) {
  final created = <String>[];
  final resolved = <_Resolved>[];
  var counter = 0;
  final pipeline = LocalPipeline(
    engine: engine,
    translator: const PassthroughLocalTranslator(),
    targetLanguage: targetLanguage,
    messageIdFactory: () => 'local_${counter++}',
    onMessageCreated: created.add,
    onMessageResolved: (id,
        {required originalText,
        required sourceLanguage,
        required translatedText,
        required translated}) {
      resolved.add(_Resolved(id, originalText, sourceLanguage, translatedText, translated));
    },
    diagnosticsLog: (_) {},
  );
  return (pipeline: pipeline, created: created, resolved: resolved);
}

void feedSegment(LocalPipeline pipeline, String segmentId, {int chunks = 5, int durationMs = 500}) {
  pipeline.handleSegmentStart(segmentId, 16000);
  for (var i = 0; i < chunks; i++) {
    pipeline.handleAudio(segmentId, i, Uint8List(3200));
  }
  pipeline.handleSegmentEnd(segmentId, durationMs, 16000);
}

void main() {
  group('detectLanguageByScript (on-device)', () {
    test('identifies the product languages by script', () {
      expect(detectLanguageByScript('สวัสดีครับทุกคน'), 'th');
      expect(detectLanguageByScript('আসসালামু আলাইকুম'), 'bn');
      expect(detectLanguageByScript('नमस्ते आप कैसे हैं'), 'hi');
      expect(detectLanguageByScript('வணக்கம்'), 'ta');
      expect(detectLanguageByScript('السلام عليكم'), 'ar');
      expect(detectLanguageByScript('آپ کیسے ہیں'), 'ur');
    });

    test('Latin script and noise return null (Whisper verdict is used instead)', () {
      expect(detectLanguageByScript('Hello everybody'), isNull);
      expect(detectLanguageByScript('12345'), isNull);
    });
  });

  group('WhisperKit model catalog', () {
    test('catalog is multilingual-only and keys survive the ggml migration', () {
      expect(kWhisperKitModelCatalog, isNotEmpty);
      for (final spec in kWhisperKitModelCatalog) {
        expect(spec.variant.contains('.en'), isFalse, reason: 'multilingual models only');
        expect(spec.variant, startsWith('openai_whisper-'));
      }
      // The old ggml settings keys must still resolve so a stored model
      // choice survives the whisper.cpp → WhisperKit migration.
      expect(whisperKitModelForKey('large-v3-turbo-q5_0').variant,
          'openai_whisper-large-v3-v20240930_626MB');
      expect(whisperKitModelForKey('small-q5_1').variant, 'openai_whisper-small');
      expect(whisperKitModelForKey('nonsense').key, kWhisperKitModelCatalog.first.key);
    });
  });

  group('LocalPipeline (Phase A)', () {
    test('utterance → pending bubble → transcript + language resolve the SAME id', () async {
      final engine =
          FakeLocalSpeechEngine([const LocalTranscript(text: 'สวัสดีครับ', language: 'th')]);
      final harness = buildPipeline(engine);
      feedSegment(harness.pipeline, 'seg-1');
      await harness.pipeline.drain();

      expect(harness.created, ['local_0']); // bubble at speech end
      expect(harness.resolved, hasLength(1));
      final result = harness.resolved.single;
      expect(result.messageId, 'local_0'); // same bubble updated
      expect(result.originalText, 'สวัสดีครับ');
      expect(result.sourceLanguage, 'th'); // → "Speaker · Thai 🇹🇭"
      expect(result.translated, isFalse); // Phase A: cross-language pending M2M100
      expect(result.translatedText, 'สวัสดีครับ');
      expect(engine.receivedByteLengths.single, 5 * 3200); // full utterance audio
    });

    test('Arabic→Arabic passes through fully offline (acceptance case)', () async {
      final engine =
          FakeLocalSpeechEngine([const LocalTranscript(text: 'السلام عليكم', language: 'ar')]);
      final harness = buildPipeline(engine);
      feedSegment(harness.pipeline, 'seg-1');
      await harness.pipeline.drain();

      final result = harness.resolved.single;
      expect(result.sourceLanguage, 'ar');
      expect(result.translatedText, 'السلام عليكم');
      expect(result.translated, isTrue); // source == target → complete result
    });

    test('VAD-discarded blips (duration 0) never create a bubble', () async {
      final engine = FakeLocalSpeechEngine([]);
      final harness = buildPipeline(engine);
      feedSegment(harness.pipeline, 'seg-1', durationMs: 0);
      await harness.pipeline.drain();

      expect(harness.created, isEmpty);
      expect(engine.receivedByteLengths, isEmpty); // no inference wasted
    });

    test('multiple utterances resolve in order with distinct message ids', () async {
      final engine = FakeLocalSpeechEngine([
        const LocalTranscript(text: 'Hello', language: 'en'),
        const LocalTranscript(text: 'Good morning', language: 'en'),
      ]);
      final harness = buildPipeline(engine);
      feedSegment(harness.pipeline, 'seg-1');
      feedSegment(harness.pipeline, 'seg-2');
      await harness.pipeline.drain();

      expect(harness.created, ['local_0', 'local_1']);
      expect(harness.resolved.map((r) => r.messageId), ['local_0', 'local_1']);
      expect(harness.resolved.map((r) => r.originalText), ['Hello', 'Good morning']);
    });

    test('an engine failure resolves the bubble with an error, never hangs', () async {
      final engine = FakeLocalSpeechEngine([]); // throws on transcribe
      final harness = buildPipeline(engine);
      feedSegment(harness.pipeline, 'seg-1');
      await harness.pipeline.drain();

      expect(harness.resolved.single.translated, isFalse);
      expect(harness.resolved.single.translatedText, contains('failed'));
    });
  });
}
