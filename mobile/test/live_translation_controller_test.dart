import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:live_translator/features/live_translation/live_translation_controller.dart';
import 'package:live_translator/models/translation_message.dart';
import 'package:live_translator/models/ws_events.dart';
import 'package:live_translator/services/auth/api_client.dart';
import 'package:live_translator/services/storage/settings_store.dart';
import 'package:live_translator/services/websocket/live_translation_client.dart';

/// Feeds scripted server events into the controller without any network.
class FakeLiveTranslationClient extends LiveTranslationClient {
  FakeLiveTranslationClient() : super(api: ApiClient(serverUrlOverride: 'http://localhost'));

  final StreamController<ServerEvent> fakeEvents = StreamController.broadcast();
  final StreamController<LiveConnectionState> fakeStates = StreamController.broadcast();

  @override
  Stream<ServerEvent> get events => fakeEvents.stream;

  @override
  Stream<LiveConnectionState> get connectionStates => fakeStates.stream;

  @override
  Future<void> disconnect() async {}

  @override
  void dispose() {}

  Future<void> emit(ServerEvent event) async {
    fakeEvents.add(event);
    await Future<void>.delayed(Duration.zero); // let the stream deliver
  }
}

TranslationStartedEvent started(String id) => TranslationStartedEvent(
      messageId: id,
      speakerId: null,
      speakerLabel: null,
      sourceLanguage: 'und',
      targetLanguage: 'ar',
      timestamp: DateTime(2026, 9, 6, 12, 0),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeLiveTranslationClient client;
  late LiveTranslationController controller;

  setUp(() {
    client = FakeLiveTranslationClient();
    controller = LiveTranslationController(
      settings: SettingsController(SettingsStore()),
      client: client,
    );
  });

  test('translation_started creates an in-progress bubble immediately', () async {
    await client.emit(started('msg_1'));

    expect(controller.messages, hasLength(1));
    final message = controller.messages.single;
    expect(message.id, 'msg_1');
    expect(message.status, TranslationStatus.pending); // renders "Translating…"
    expect(message.translatedText, isEmpty);
    expect(message.sourceLanguage, 'und');
    expect(message.targetLanguage, 'ar');
  });

  test('translation_delta for an existing message appends into the same bubble', () async {
    await client.emit(started('msg_1'));
    await client.emit(const TranslationDeltaEvent(messageId: 'msg_1', delta: 'مرح', reset: false));
    await client.emit(const TranslationDeltaEvent(messageId: 'msg_1', delta: 'باً', reset: false));

    expect(controller.messages, hasLength(1));
    expect(controller.messages.single.translatedText, 'مرحباً');
    expect(controller.messages.single.status, TranslationStatus.pending);
  });

  test('translation_delta for an UNKNOWN messageId still creates the bubble', () async {
    // No translation_started ever arrived (ordering/network race).
    await client.emit(const TranslationDeltaEvent(messageId: 'msg_x', delta: 'مرح', reset: false));

    expect(controller.messages, hasLength(1)); // created, not dropped
    expect(controller.messages.single.id, 'msg_x');
    expect(controller.messages.single.translatedText, 'مرح');
  });

  test('translation_complete for an unknown messageId still creates and finalizes it', () async {
    await client.emit(const TranslationCompleteEvent(
      messageId: 'msg_y',
      translatedText: 'مرحباً',
      sourceLanguage: 'en',
      originalText: 'Hello',
    ));

    expect(controller.messages, hasLength(1));
    final message = controller.messages.single;
    expect(message.id, 'msg_y');
    expect(message.status, TranslationStatus.done);
    expect(message.translatedText, 'مرحباً');
    expect(message.originalText, 'Hello');
    expect(message.sourceLanguage, 'en');
  });

  test('multiple deltas and the completion never create duplicate bubbles', () async {
    await client.emit(started('msg_1'));
    for (final delta in ['مر', 'ح', 'ب', 'اً']) {
      await client.emit(TranslationDeltaEvent(messageId: 'msg_1', delta: delta, reset: false));
    }
    await client.emit(started('msg_1')); // duplicate announcement (reconnect)
    await client.emit(const TranslationCompleteEvent(
      messageId: 'msg_1',
      translatedText: 'مرحباً',
    ));

    expect(controller.messages, hasLength(1)); // one bubble through it all
    expect(controller.messages.single.translatedText, 'مرحباً');
    expect(controller.messages.single.status, TranslationStatus.done);
  });
}
