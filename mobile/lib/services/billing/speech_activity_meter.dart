import 'dart:math' as math;

/// One stretch of probable speech, measured for BILLING ONLY.
///
/// A segment is provisional until Sayvo actually shows a translation for it.
/// Speech that produced nothing the user could read is discarded unpaid.
class SpeechSegment {
  SpeechSegment({required this.id, required this.startedAt});

  final int id;
  final DateTime startedAt;
  DateTime? endedAt;

  /// Milliseconds of speech in this segment. Short pauses inside a sentence
  /// are included; the trailing silence that closes the segment is not.
  int activeSpeechMs = 0;

  /// Set once translated text appeared while, or shortly after, this segment
  /// was speaking.
  bool translated = false;

  /// Set when the duration has been added to the cumulative counter. A
  /// committed segment can never be committed again, however many streaming
  /// updates the same translation arrives in.
  bool committed = false;
}

/// Measures how long people actually SPOKE, by observing the microphone's PCM
/// levels, and counts only the speech that Sayvo went on to translate.
///
/// This meter is deliberately passive. It never gates the microphone, never
/// withholds audio from Gemini, never creates translation boundaries and never
/// touches utterance segmentation or language detection. It watches the same
/// levels the waveform uses and keeps a running total for billing — nothing
/// more. Sayvo's earlier local-VAD translation routing is not coming back.
///
/// Why the translation gate matters more than the detector: the only thing
/// that can ever be charged is a segment for which translated text appeared.
/// If the detector fires on a slammed door or a passing bus, no translation
/// follows and the segment is thrown away. That makes the accounting safe
/// against a sensitive detector, which in turn lets the detector stay
/// sensitive enough for quiet, far-field speakers.
class SpeechActivityMeter {
  SpeechActivityMeter({
    this.enterRatio = 2.5,
    this.exitRatio = 1.5,
    this.absoluteFloor = 0.0015,
    this.hangover = const Duration(milliseconds: 700),
    this.minSegmentMs = 200,
    this.untranslatedGrace = const Duration(seconds: 20),
  });

  /// How far above the tracked noise floor a chunk must be to start speech.
  final double enterRatio;

  /// The lower bar speech must fall below to stop — hysteresis, so a speaker
  /// dipping in volume does not chop a sentence into fragments.
  final double exitRatio;

  /// A floor under the floor, so a perfectly silent room cannot make the
  /// threshold collapse toward zero.
  final double absoluteFloor;

  /// How long the level may stay low before a segment is considered over.
  final Duration hangover;

  /// Blips shorter than this are not speech worth billing.
  final int minSegmentMs;

  /// How long a closed segment waits for a translation before being dropped.
  final Duration untranslatedGrace;

  double _noiseFloor = 0.003;
  double get noiseFloor => _noiseFloor;

  bool _inSpeech = false;
  bool get inSpeech => _inSpeech;

  int _nextId = 1;
  SpeechSegment? _open;
  final List<SpeechSegment> _pending = [];

  DateTime? _firstSpeechAt;
  DateTime? _lastSpeechAt;

  int _committedMs = 0;

  /// Cumulative translated-speech milliseconds committed in this session.
  /// Monotonic by construction: it only ever grows.
  int get committedSpeechMs => _committedMs;

  /// Segments measured but not yet paid for, because no translation has
  /// arrived for them (yet).
  int get pendingSegments => _pending.length + (_open == null ? 0 : 1);

  int _translatedUtterances = 0;
  int get translatedUtteranceCount => _translatedUtterances;

  /// Feeds one microphone chunk.
  ///
  /// [rms] is the same 0..1 level the waveform uses, [duration] the chunk's
  /// real length, and [gated] true while the uplink is muted for Sayvo's own
  /// spoken translation — gated audio is the device talking to itself and can
  /// never be billable speech.
  void onAudio({
    required double rms,
    required Duration duration,
    required bool gated,
    required DateTime at,
  }) {
    _expireStale(at);
    if (gated) {
      // The device is speaking. Treat it as silence and let the hangover close
      // whatever was open, without letting our own voice raise the floor.
      _onQuiet(at);
      return;
    }

    final threshold = math.max(
      _noiseFloor * (_inSpeech ? exitRatio : enterRatio),
      absoluteFloor,
    );
    if (rms >= threshold) {
      _onSpeech(at, duration);
    } else {
      _trackNoiseFloor(rms);
      _onQuiet(at);
    }
  }

  void _trackNoiseFloor(double rms) {
    // Falls quickly toward a quieter room, rises slowly, and never runs away
    // in either direction.
    final rate = rms < _noiseFloor ? 0.25 : 0.01;
    _noiseFloor = (_noiseFloor + (rms - _noiseFloor) * rate).clamp(0.0005, 0.05);
  }

  void _onSpeech(DateTime at, Duration duration) {
    if (!_inSpeech) {
      _inSpeech = true;
      _open ??= SpeechSegment(id: _nextId++, startedAt: at);
      _firstSpeechAt ??= at;
    }
    _lastSpeechAt = at.add(duration);
    final segment = _open;
    final from = _firstSpeechAt;
    if (segment != null && from != null) {
      // Span from the first to the last voiced moment, so natural pauses
      // inside a sentence still read as one continuous stretch of speech.
      segment.activeSpeechMs = _lastSpeechAt!.difference(from).inMilliseconds;
    }
  }

  void _onQuiet(DateTime at) {
    if (!_inSpeech) return;
    final last = _lastSpeechAt;
    if (last == null || at.difference(last) < hangover) return;
    _closeSegment(at);
  }

  void _closeSegment(DateTime at) {
    _inSpeech = false;
    _firstSpeechAt = null;
    _lastSpeechAt = null;
    final segment = _open;
    _open = null;
    if (segment == null) return;
    segment.endedAt = at;
    if (segment.activeSpeechMs < minSegmentMs) return; // a blip, not speech
    if (segment.translated) {
      _commit(segment);
    } else {
      _pending.add(segment);
    }
  }

  /// Called whenever Sayvo shows non-empty translated text.
  ///
  /// Gemini's translation lags the speech that produced it, and one
  /// translation can span several detected segments (a speaker pausing
  /// mid-sentence), so everything still awaiting an answer is marked as
  /// answered. Segments older than [untranslatedGrace] have already been
  /// dropped and cannot be revived by a later, unrelated translation.
  void onTranslatedText(DateTime at) {
    _expireStale(at);
    _open?.translated = true;
    for (final segment in _pending) {
      segment.translated = true;
    }
    _commitPending();
  }

  /// One translated utterance finished. Telemetry only — never billing.
  void onUtteranceTranslated() => _translatedUtterances++;

  /// Closes the session: the open segment ends, anything already answered by a
  /// translation is committed, and the rest is discarded unpaid.
  void endSession(DateTime at) {
    _closeSegment(at);
    _commitPending();
    _pending.clear();
  }

  void _commitPending() {
    _pending.removeWhere((segment) {
      if (!segment.translated) return false;
      _commit(segment);
      return true;
    });
  }

  void _commit(SpeechSegment segment) {
    if (segment.committed) return;
    segment.committed = true;
    _committedMs += segment.activeSpeechMs;
  }

  /// Drops segments whose translation never came. This is what keeps a failed
  /// translation, a passing siren, or speech Gemini deliberately ignored from
  /// costing the user anything.
  void _expireStale(DateTime at) {
    _pending.removeWhere((segment) {
      final ended = segment.endedAt;
      return !segment.translated &&
          ended != null &&
          at.difference(ended) > untranslatedGrace;
    });
  }
}
