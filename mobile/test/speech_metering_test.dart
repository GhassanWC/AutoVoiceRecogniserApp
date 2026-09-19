import 'package:flutter_test/flutter_test.dart';
import 'package:live_translator/services/billing/speech_activity_meter.dart';
import 'package:live_translator/services/billing/usage_meter.dart';

/// A hand-cranked clock, so these tests measure logic rather than wall time.
class _Clock {
  DateTime now = DateTime.utc(2026, 9, 19, 12);
  DateTime call() => now;
  void advance(Duration d) => now = now.add(d);
}

const double _silence = 0.0004;
const double _roomNoise = 0.0012;
const double _speech = 0.05;

/// Feeds [total] of audio at [rms] in the 100 ms chunks the capture service
/// produces.
void _feed(
  SpeechActivityMeter meter,
  _Clock clock, {
  required double rms,
  required Duration total,
  bool gated = false,
}) {
  const chunk = Duration(milliseconds: 100);
  for (var elapsed = Duration.zero; elapsed < total; elapsed += chunk) {
    meter.onAudio(rms: rms, duration: chunk, gated: gated, at: clock.now);
    clock.advance(chunk);
  }
}

/// Speaks for [duration] and then has Sayvo translate it, which is the only
/// sequence that costs a user anything.
void _speakAndTranslate(
  SpeechActivityMeter meter,
  _Clock clock,
  Duration duration,
) {
  _feed(meter, clock, rms: _speech, total: duration);
  meter.onTranslatedText(clock.now);
  // The trailing silence that closes the segment is never itself billable.
  _feed(meter, clock, rms: _silence, total: const Duration(seconds: 2));
}

void main() {
  group('a quiet room costs nothing', () {
    test('ten minutes of listening with nobody speaking', () {
      final clock = _Clock();
      final meter = SpeechActivityMeter();
      _feed(meter, clock, rms: _silence, total: const Duration(minutes: 10));
      meter.endSession(clock.now);
      expect(meter.committedSpeechMs, 0);
    });

    test('thirty minutes of background listening in a quiet room', () {
      final clock = _Clock();
      final meter = SpeechActivityMeter();
      // Background listening is the same path; there is no separate rate and
      // no separate meter.
      _feed(meter, clock, rms: _silence, total: const Duration(minutes: 30));
      meter.endSession(clock.now);
      expect(meter.committedSpeechMs, 0);
    });

    test('steady room noise that never produces a translation', () {
      final clock = _Clock();
      final meter = SpeechActivityMeter();
      _feed(meter, clock, rms: _roomNoise, total: const Duration(minutes: 5));
      meter.endSession(clock.now);
      expect(meter.committedSpeechMs, 0);
    });
  });

  group('only translated speech is charged', () {
    test('ten minutes open, two minutes spoken: about two minutes', () {
      final clock = _Clock();
      final meter = SpeechActivityMeter();

      _feed(meter, clock, rms: _silence, total: const Duration(minutes: 4));
      _speakAndTranslate(meter, clock, const Duration(minutes: 1));
      _feed(meter, clock, rms: _silence, total: const Duration(minutes: 2));
      _speakAndTranslate(meter, clock, const Duration(minutes: 1));
      _feed(meter, clock, rms: _silence, total: const Duration(minutes: 2));
      meter.endSession(clock.now);

      // Two minutes of speech inside a ten-minute session.
      expect(meter.committedSpeechMs, closeTo(120000, 500));
    });

    test('eight seconds of speech costs about eight seconds, once', () {
      final clock = _Clock();
      final meter = SpeechActivityMeter();
      _speakAndTranslate(meter, clock, const Duration(seconds: 8));
      meter.endSession(clock.now);
      expect(meter.committedSpeechMs, closeTo(8000, 200));
    });

    test('model latency after the speech is not charged', () {
      final clock = _Clock();
      final meter = SpeechActivityMeter();
      _feed(meter, clock, rms: _speech, total: const Duration(seconds: 8));
      // Four seconds of Gemini thinking, then the translation lands.
      _feed(meter, clock, rms: _silence, total: const Duration(seconds: 4));
      meter.onTranslatedText(clock.now);
      _feed(meter, clock, rms: _silence, total: const Duration(seconds: 2));
      meter.endSession(clock.now);
      // Eight seconds, not twelve.
      expect(meter.committedSpeechMs, closeTo(8000, 200));
    });

    test('speech that is never translated is discarded unpaid', () {
      final clock = _Clock();
      final meter = SpeechActivityMeter();
      _feed(meter, clock, rms: _speech, total: const Duration(seconds: 9));
      // Nothing ever comes back; the segment waits, then expires.
      _feed(meter, clock, rms: _silence, total: const Duration(seconds: 30));
      meter.endSession(clock.now);
      expect(meter.committedSpeechMs, 0);
    });

    test('a segment still waiting when the session ends is not charged', () {
      final clock = _Clock();
      final meter = SpeechActivityMeter();
      _feed(meter, clock, rms: _speech, total: const Duration(seconds: 6));
      _feed(meter, clock, rms: _silence, total: const Duration(seconds: 2));
      // Stop pressed before any translation arrived.
      meter.endSession(clock.now);
      expect(meter.committedSpeechMs, 0);
    });

    test('a blip too short to be speech is ignored', () {
      final clock = _Clock();
      final meter = SpeechActivityMeter();
      _feed(meter, clock, rms: _speech, total: const Duration(milliseconds: 100));
      meter.onTranslatedText(clock.now);
      _feed(meter, clock, rms: _silence, total: const Duration(seconds: 2));
      meter.endSession(clock.now);
      expect(meter.committedSpeechMs, 0);
    });
  });

  group('one utterance is charged once', () {
    test('streaming partial translations do not each charge', () {
      final clock = _Clock();
      final meter = SpeechActivityMeter();
      _feed(meter, clock, rms: _speech, total: const Duration(seconds: 10));
      // "أين" → "أين الفندق" → "أين الفندق؟" — one utterance, three updates.
      meter.onTranslatedText(clock.now);
      meter.onTranslatedText(clock.now.add(const Duration(milliseconds: 300)));
      meter.onTranslatedText(clock.now.add(const Duration(milliseconds: 700)));
      _feed(meter, clock, rms: _silence, total: const Duration(seconds: 2));
      meter.endSession(clock.now);
      expect(meter.committedSpeechMs, closeTo(10000, 300));
    });

    test('a translation arriving after the segment closed still pays it once', () {
      final clock = _Clock();
      final meter = SpeechActivityMeter();
      _feed(meter, clock, rms: _speech, total: const Duration(seconds: 5));
      _feed(meter, clock, rms: _silence, total: const Duration(seconds: 3));
      // The segment has closed and is waiting; the translation lands late.
      meter.onTranslatedText(clock.now);
      meter.onTranslatedText(clock.now);
      meter.endSession(clock.now);
      expect(meter.committedSpeechMs, closeTo(5000, 300));
    });

    test('durations accumulate exactly, never rounded up to whole minutes', () {
      final clock = _Clock();
      final meter = SpeechActivityMeter();
      for (final seconds in [10, 17, 21, 4, 13]) {
        _speakAndTranslate(meter, clock, Duration(seconds: seconds));
      }
      meter.endSession(clock.now);
      // 65 seconds of speech — not five minutes, and not one minute each.
      expect(meter.committedSpeechMs, closeTo(65000, 1500));
    });
  });

  group('the app talking to itself is free', () {
    test('translated playback through the speaker charges nothing', () {
      final clock = _Clock();
      final meter = SpeechActivityMeter();
      // Loud audio while the uplink is muted for Sayvo's own voice.
      _feed(meter, clock,
          rms: _speech, total: const Duration(seconds: 12), gated: true);
      meter.onTranslatedText(clock.now);
      meter.endSession(clock.now);
      expect(meter.committedSpeechMs, 0);
    });

    test('pressing the speaker ten times still charges nothing', () {
      final clock = _Clock();
      final meter = SpeechActivityMeter();
      for (var i = 0; i < 10; i++) {
        _feed(meter, clock,
            rms: _speech, total: const Duration(seconds: 3), gated: true);
        _feed(meter, clock, rms: _silence, total: const Duration(seconds: 1));
      }
      meter.endSession(clock.now);
      expect(meter.committedSpeechMs, 0);
    });

    test('the gate closes an open segment rather than extending it', () {
      final clock = _Clock();
      final meter = SpeechActivityMeter();
      _feed(meter, clock, rms: _speech, total: const Duration(seconds: 4));
      meter.onTranslatedText(clock.now);
      // Sayvo starts speaking the translation aloud.
      _feed(meter, clock,
          rms: _speech, total: const Duration(seconds: 20), gated: true);
      meter.endSession(clock.now);
      // Only the four seconds somebody actually said.
      expect(meter.committedSpeechMs, closeTo(4000, 300));
    });
  });

  group('reporting to the server', () {
    test('reports a cumulative total, never a delta', () async {
      final clock = _Clock();
      final sent = <Map<String, dynamic>>[];
      final speech = SpeechActivityMeter();
      final meter = UsageMeter(
        speech: speech,
        now: clock.call,
        flushDelay: Duration.zero,
        sender: (payload) async {
          sent.add(payload);
          return {'remainingMs': 200000, 'allowed': true};
        },
      )..start('session-1');

      _speakAndTranslate(speech, clock, const Duration(seconds: 8));
      meter.onUtteranceTranslated();
      await Future<void>.delayed(const Duration(milliseconds: 30));

      _speakAndTranslate(speech, clock, const Duration(seconds: 6));
      meter.onUtteranceTranslated();
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(sent.length, greaterThanOrEqualTo(2));
      final totals =
          sent.map((p) => p['cumulativeSpeechMs'] as int).toList();
      // Each report carries the running total, so a lost one costs nothing.
      expect(totals.first, closeTo(8000, 300));
      expect(totals.last, closeTo(14000, 600));
      // Sequence numbers only ever increase.
      final sequences = sent.map((p) => p['sequence'] as int).toList();
      expect(sequences, orderedEquals(List.generate(sent.length, (i) => i + 1)));
      meter.dispose();
    });

    test('says nothing at all while the room is silent', () async {
      final clock = _Clock();
      var calls = 0;
      final speech = SpeechActivityMeter();
      final meter = UsageMeter(
        speech: speech,
        now: clock.call,
        flushDelay: const Duration(milliseconds: 5),
        safetyInterval: const Duration(milliseconds: 20),
        sender: (_) async {
          calls++;
          return {'remainingMs': 300000, 'allowed': true};
        },
      )..start('session-2');

      _feed(speech, clock, rms: _silence, total: const Duration(minutes: 5));
      await Future<void>.delayed(const Duration(milliseconds: 80));
      // No speech, no translation, nothing to report: no Firestore write, no
      // network call, no cost.
      expect(calls, 0);
      meter.dispose();
    });

    test('stopping flushes the final total and closes the session', () async {
      final clock = _Clock();
      final sent = <Map<String, dynamic>>[];
      final speech = SpeechActivityMeter();
      final meter = UsageMeter(
        speech: speech,
        now: clock.call,
        flushDelay: const Duration(seconds: 30),
        sender: (payload) async {
          sent.add(payload);
          return {'remainingMs': 100000, 'allowed': true};
        },
      )..start('session-3');

      _feed(speech, clock, rms: _speech, total: const Duration(seconds: 7));
      speech.onTranslatedText(clock.now);
      // Stop pressed before the batching timer fired.
      await meter.finish();

      expect(sent, hasLength(1));
      expect(sent.single['close'], isTrue);
      expect(sent.single['cumulativeSpeechMs'], closeTo(7000, 300));
      expect(meter.isRunning, isFalse);
      meter.dispose();
    });

    test('a dropped report is carried by the next one, not lost or doubled',
        () async {
      final clock = _Clock();
      final sent = <int>[];
      var failNext = true;
      final speech = SpeechActivityMeter();
      final meter = UsageMeter(
        speech: speech,
        now: clock.call,
        flushDelay: Duration.zero,
        sender: (payload) async {
          if (failNext) {
            failNext = false;
            throw Exception('offline');
          }
          sent.add(payload['cumulativeSpeechMs'] as int);
          return {'remainingMs': 100000, 'allowed': true};
        },
      )..start('session-4');

      _speakAndTranslate(speech, clock, const Duration(seconds: 5));
      meter.onUtteranceTranslated();
      await Future<void>.delayed(const Duration(milliseconds: 30));

      _speakAndTranslate(speech, clock, const Duration(seconds: 5));
      meter.onUtteranceTranslated();
      await Future<void>.delayed(const Duration(milliseconds: 30));

      // The first report never landed; the second carries the whole total.
      expect(sent, hasLength(1));
      expect(sent.single, closeTo(10000, 600));
      meter.dispose();
    });

    test('an exhausted allowance cuts the session off', () async {
      final clock = _Clock();
      var exhausted = 0;
      final speech = SpeechActivityMeter();
      final meter = UsageMeter(
        speech: speech,
        now: clock.call,
        flushDelay: Duration.zero,
        sender: (_) async => {'remainingMs': 0, 'allowed': false},
      );
      meter.onExhausted = () => exhausted++;
      meter.start('session-5');

      _speakAndTranslate(speech, clock, const Duration(seconds: 9));
      meter.onUtteranceTranslated();
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(exhausted, greaterThanOrEqualTo(1));
      meter.dispose();
    });

    test('the server remainder is what reaches the UI', () async {
      final clock = _Clock();
      final remainders = <int>[];
      final speech = SpeechActivityMeter();
      final meter = UsageMeter(
        speech: speech,
        now: clock.call,
        flushDelay: Duration.zero,
        sender: (_) async => {'remainingMs': 123456, 'allowed': true},
      );
      meter.onRemaining = remainders.add;
      meter.start('session-6');

      _speakAndTranslate(speech, clock, const Duration(seconds: 4));
      meter.onUtteranceTranslated();
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(remainders, isNotEmpty);
      expect(remainders.last, 123456);
      meter.dispose();
    });

    test('telemetry separates audio streamed from speech translated', () async {
      final clock = _Clock();
      final speech = SpeechActivityMeter();
      final meter = UsageMeter(speech: speech, now: clock.call, sender: (_) async => {})
        ..start('session-7');
      meter.onConnected();

      // Five minutes of audio streamed; ten seconds of it translated.
      for (var i = 0; i < 3000; i++) {
        meter.onMicAudio(
          rms: _silence,
          duration: const Duration(milliseconds: 100),
          gated: false,
          sentUpstream: true,
        );
        clock.advance(const Duration(milliseconds: 100));
      }
      _speakAndTranslate(speech, clock, const Duration(seconds: 10));
      meter.onUtteranceTranslated();
      meter.onDisconnected();

      final telemetry = meter.telemetry();
      expect(telemetry['audioSentMs'], 300000);
      expect(telemetry['committedSpeechMs'], closeTo(10000, 400));
      expect(telemetry['translatedUtteranceCount'], 1);
      expect(telemetry['connectedMs']! > 0, isTrue);
      meter.dispose();
    });

    test('an unknown session id reports nothing', () async {
      var calls = 0;
      final meter = UsageMeter(sender: (_) async {
        calls++;
        return const {};
      });
      // finish() without start() has nothing to close.
      await meter.finish();
      expect(calls, 0);
      meter.dispose();
    });
  });
}
