import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:live_translator/services/local/local_language_detect.dart';
import 'package:live_translator/services/local/local_model_doctor.dart';
import 'package:live_translator/services/local/local_pipeline.dart';
import 'package:live_translator/services/local/local_speech_engine.dart';
import 'package:live_translator/services/local/local_translation_engine.dart';
import 'package:live_translator/services/local/offline_model_manager.dart';

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

/// Engine whose native load always fails with the given message.
class _ThrowingEngine implements LocalSpeechEngine {
  _ThrowingEngine(this.message);
  final String message;

  @override
  bool get isLoaded => false;

  @override
  Future<void> load(String modelPath) async => throw StateError(message);

  @override
  Future<LocalTranscript> transcribe(Uint8List pcm16, int sampleRate) =>
      throw UnimplementedError();

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

  group('offline model catalog + verification', () {
    test('catalog is multilingual-only, with pinned sizes and checksums', () {
      expect(kOfflineModelCatalog, isNotEmpty);
      for (final spec in kOfflineModelCatalog) {
        expect(spec.fileName.contains('.en'), isFalse, reason: 'multilingual models only');
        expect(spec.sha256.length, 64);
        expect(spec.sizeBytes, greaterThan(10 * 1024 * 1024));
      }
      expect(offlineModelForKey('large-v3-turbo-q5_0').sizeLabel, '547 MB');
      expect(offlineModelForKey('nonsense').key, kOfflineModelCatalog.first.key);
    });

    test('verifyFile accepts only exact size + SHA-256 matches', () async {
      final dir = await Directory.systemTemp.createTemp('model_test');
      final file = File('${dir.path}/model.bin');
      final bytes = List<int>.generate(1024, (i) => i % 251);
      await file.writeAsBytes(bytes);
      final goodSha = sha256.convert(bytes).toString();

      expect(await verifyFile(file.path, 1024, goodSha), isTrue);
      expect(await verifyFile(file.path, 1023, goodSha), isFalse); // wrong size
      expect(await verifyFile(file.path, 1024, 'deadbeef$goodSha'.substring(0, 64)), isFalse);
      expect(await verifyFile('${dir.path}/missing.bin', 1024, goodSha), isFalse);
      await dir.delete(recursive: true);
    });
  });

  group('model load doctor', () {
    test('describeHeader tells real ggml models from saved error pages', () {
      expect(describeHeader([0x6c, 0x6d, 0x67, 0x67, 0, 0]), startsWith('ggml magic OK'));
      expect(describeHeader('<html'.codeUnits), contains('HTML DOCUMENT'));
      expect(describeHeader('{"err'.codeUnits), contains('JSON'));
      expect(describeHeader([1, 2, 3, 4]), contains('UNKNOWN magic'));
      expect(describeHeader([1, 2]), contains('too short'));
    });

    Future<(OfflineModelSpec, OfflineModelManager, Directory)> writeModel(
        List<int> bytes) async {
      final dir = await Directory.systemTemp.createTemp('doctor_test');
      final manager = OfflineModelManager(overrideDirectory: dir);
      final spec = OfflineModelSpec(
        key: 'test',
        displayName: 'Test model',
        fileName: 'ggml-test.bin',
        url: 'https://example.invalid/model.bin',
        sizeBytes: bytes.length,
        sha256: sha256.convert(bytes).toString(),
        notes: '',
      );
      await File(await manager.pathFor(spec)).writeAsBytes(bytes);
      return (spec, manager, dir);
    }

    test('preload checks PASS for a valid ggml file and log every field', () async {
      final bytes = [...kGgmlMagicBytes, ...List<int>.generate(100, (i) => i)];
      final (spec, manager, dir) = await writeModel(bytes);
      final result = await whisperPreloadChecks(spec: spec, manager: manager);

      expect(result.ok, isTrue);
      final joined = result.lines.join('\n');
      expect(joined, contains('[WHISPER LOAD]'));
      expect(joined, contains('exists=true'));
      expect(joined, contains('fileSize=${bytes.length}'));
      expect(joined, contains('expectedSize=${bytes.length}'));
      expect(joined, contains('sha256Valid=true'));
      expect(joined, contains('readable=true'));
      expect(joined, contains('ggml magic OK'));
      await dir.delete(recursive: true);
    });

    test('an HTML error page is rejected even when its checksum matches', () async {
      final bytes = '<html><body>Rate limited</body></html>'.codeUnits;
      final (spec, manager, dir) = await writeModel(bytes);
      final result = await whisperPreloadChecks(spec: spec, manager: manager);

      expect(result.ok, isFalse); // magic gate catches it despite valid sha
      expect(result.lines.join('\n'), contains('HTML DOCUMENT'));
      await dir.delete(recursive: true);
    });

    test('runModelLoadTest surfaces the exact native error, and PASS on success', () async {
      final bytes = [...kGgmlMagicBytes, ...List<int>.generate(64, (i) => i)];
      final (spec, manager, dir) = await writeModel(bytes);

      final failing = await runModelLoadTest(
        spec: spec,
        manager: manager,
        engineFactory: () => _ThrowingEngine('failed to load model: invalid magic'),
        nativeVersion: () => 'whisper.cpp v-test',
        nativeSystemInfo: () => 'NEON=1 METAL=1',
      );
      expect(failing.passed, isFalse);
      expect(failing.details, contains('[WHISPER LOAD ERROR]'));
      expect(failing.details, contains('failed to load model: invalid magic'));
      expect(failing.details, contains('WhisperEngine.version=whisper.cpp v-test'));
      expect(failing.details, contains('small-q5_1 baseline')); // the hint

      final passing = await runModelLoadTest(
        spec: spec,
        manager: manager,
        engineFactory: () => FakeLocalSpeechEngine([]),
        nativeVersion: () => 'whisper.cpp v-test',
        nativeSystemInfo: () => 'NEON=1',
      );
      expect(passing.passed, isTrue);
      expect(passing.details, contains('Model load: PASS'));
      await dir.delete(recursive: true);
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
