import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:live_translator/models/translation_message.dart';
import 'package:live_translator/models/ws_events.dart';

void main() {
  test('binary audio frames match the backend layout', () {
    const segmentId = '123e4567-e89b-42d3-a456-426614174000';
    final pcm = Uint8List.fromList([1, 2, 3, 4]);
    final frame = encodeAudioFrame(segmentId, 258, pcm);

    expect(frame.length, kBinaryHeaderBytes + 4);
    expect(frame[0], kProtocolVersion);
    expect(ascii.decode(frame.sublist(1, 37)), segmentId);
    expect(
      ByteData.sublistView(frame).getUint32(37, Endian.little),
      258,
    );
    expect(frame.sublist(kBinaryHeaderBytes), [1, 2, 3, 4]);
  });

  test('parses a translation event', () {
    final event = ServerEvent.parse(jsonEncode({
      'type': 'translation',
      'id': 'msg_1',
      'segmentId': 'seg',
      'speakerId': 'speaker_1',
      'speakerLabel': 'Speaker 1',
      'sourceLanguage': 'es',
      'languageConfidence': 0.97,
      'originalText': 'Hola hermano.',
      'translatedText': 'مرحباً يا أخي',
      'targetLanguage': 'ar',
      'timestamp': '2026-08-27T12:00:00Z',
    }));

    expect(event, isA<TranslationEvent>());
    final message = (event as TranslationEvent).message;
    expect(message.speakerLabel, 'Speaker 1');
    expect(message.sourceLanguage, 'es');
    expect(message.translatedText, 'مرحباً يا أخي');
  });

  test('parses a transcript_final event as a pending message', () {
    final event = ServerEvent.parse(jsonEncode({
      'type': 'transcript_final',
      'messageId': 'msg_1',
      'segmentId': 'seg',
      'speakerId': 'speaker_2',
      'speakerLabel': 'Speaker 2',
      'sourceLanguage': 'und',
      'languageConfidence': 0.4,
      'transcriptionConfidence': 0.9,
      'originalText': 'Hola hermano',
      'targetLanguage': 'ar',
      'translationStatus': 'pending',
      'timestamp': '2026-09-05T12:00:00Z',
    }));

    expect(event, isA<TranscriptFinalEvent>());
    final message = (event as TranscriptFinalEvent).message;
    expect(message.id, 'msg_1');
    expect(message.status, TranslationStatus.pending);
    expect(message.originalText, 'Hola hermano');
    expect(message.sourceLanguage, 'und');
    expect(message.translatedText, isEmpty);
  });

  test('parses translation_complete and translation_failed updates', () {
    final complete = ServerEvent.parse(jsonEncode({
      'type': 'translation_complete',
      'messageId': 'msg_1',
      'translatedText': 'مرحباً يا أخي',
      'targetLanguage': 'ar',
      'sourceLanguage': 'es',
    }));
    expect(complete, isA<TranslationCompleteEvent>());
    expect((complete as TranslationCompleteEvent).messageId, 'msg_1');
    expect(complete.translatedText, 'مرحباً يا أخي');
    expect(complete.sourceLanguage, 'es'); // the translator's language verdict

    final failed = ServerEvent.parse(
        '{"type":"translation_failed","messageId":"msg_1","status":429,"reason":"insufficient_quota"}');
    expect(failed, isA<TranslationFailedEvent>());
    expect((failed as TranslationFailedEvent).messageId, 'msg_1');
    expect(failed.status, 429);
    expect(failed.reason, 'insufficient_quota');
  });

  test('parses status, error, limit and session events', () {
    expect(
      ServerEvent.parse('{"type":"status","segmentId":"s","state":"translating"}'),
      isA<StatusEvent>(),
    );
    expect(
      ServerEvent.parse('{"type":"error","code":"x","message":"m","recoverable":true}'),
      isA<ServerErrorEvent>(),
    );
    expect(
      ServerEvent.parse('{"type":"limit_reached","message":"m"}'),
      isA<LimitReachedEvent>(),
    );
    expect(
      ServerEvent.parse(
          '{"type":"session_ended","sessionId":"s","translationCount":3,"durationSeconds":60}'),
      isA<SessionEndedEvent>(),
    );
  });

  test('returns null for malformed payloads instead of throwing', () {
    expect(ServerEvent.parse('not json'), isNull);
    expect(ServerEvent.parse('{"type":"who_knows"}'), isNull);
    expect(ServerEvent.parse('[1,2,3]'), isNull);
  });
}
