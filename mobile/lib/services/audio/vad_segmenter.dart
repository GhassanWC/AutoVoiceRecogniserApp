import 'dart:math' as math;
import 'dart:typed_data';

typedef SegmentStartCallback = void Function(String segmentId, int sampleRate);
typedef SegmentAudioCallback = void Function(String segmentId, int sequence, Uint8List pcm);
typedef SegmentEndCallback = void Function(String segmentId, int durationMs);
typedef LevelCallback = void Function(double level, bool isSpeech);
typedef DiagnosticsCallback = void Function(VadDiagnostics diagnostics);

/// Per-chunk VAD state, surfaced for developer-mode logging.
class VadDiagnostics {
  const VadDiagnostics({
    required this.rms,
    required this.noiseFloor,
    required this.threshold,
    required this.isSpeech,
    this.event,
    this.segmentId,
  });

  final double rms;
  final double noiseFloor;
  final double threshold;
  final bool isSpeech;

  /// 'segment_start' | 'segment_end' | 'segment_discarded' | null (level tick).
  final String? event;
  final String? segmentId;

  @override
  String toString() =>
      'rms=${rms.toStringAsFixed(4)} floor=${noiseFloor.toStringAsFixed(4)} '
      'threshold=${threshold.toStringAsFixed(4)} speech=$isSpeech'
      '${event == null ? '' : ' event=$event seg=$segmentId'}';
}

/// Energy-based voice activity detection over a PCM16 mono stream.
///
/// This is an *environmental* detector, not a voice-call one: its only job is
/// segmentation and upload-cost reduction. It must fire for anyone audible to
/// the microphone — a person 30 cm away, someone across the room, a TV at
/// normal volume — and stay quiet for steady background noise (air
/// conditioning, fridge hum, traffic rumble).
///
/// How the threshold adapts:
///  - the noise floor tracks *steady* levels: it follows drops quickly and
///    sub-threshold ambience slowly, so a constant hum raises the floor until
///    it sits below `floor × onsetRatio` and stops triggering;
///  - while sound is above the threshold the floor rises only glacially, so
///    sustained speech (a TV monologue, a long story) is never re-learned as
///    "noise" — this was the bug that made distant speech undetectable;
///  - the absolute minimum threshold is low (≈ −49 dBFS) because iOS capture
///    runs without automatic gain control and distant speech is quiet.
///
/// Segmentation:
///  - ~1.5 s of pre-roll is kept from before the trigger so the start of the
///    first word is never clipped;
///  - a hangover of sub-threshold audio closes the segment so sentence endings
///    survive; within a segment everything is streamed (speech and short
///    pauses alike);
///  - closing uses a lower "release" threshold than opening, so quiet trailing
///    syllables do not count as silence.
///
/// Silence never leaves the phone. All timing is derived from sample counts,
/// which keeps the class deterministic and unit-testable.
class VadSegmenter {
  VadSegmenter({
    required this.sampleRate,
    required this.onSegmentStart,
    required this.onAudio,
    required this.onSegmentEnd,
    this.onLevel,
    this.onDiagnostics,
    String Function()? segmentIdFactory,
    this.silenceHangoverMs = 900,
    this.maxSegmentMs = 15000,
    this.minSegmentMs = 350,
    this.preRollMs = 1500,
    this.minThreshold = 0.0035,
    this.onsetRatio = 2.0,
    this.releaseRatio = 1.4,
  }) : _segmentIdFactory = segmentIdFactory ?? _defaultIdFactory;

  final int sampleRate;
  final SegmentStartCallback onSegmentStart;
  final SegmentAudioCallback onAudio;
  final SegmentEndCallback onSegmentEnd;
  final LevelCallback? onLevel;
  final DiagnosticsCallback? onDiagnostics;

  /// Sub-threshold audio needed to consider the utterance finished.
  final int silenceHangoverMs;
  final int maxSegmentMs;
  final int minSegmentMs;

  /// Audio kept from just before speech was detected, so the beginning of the
  /// sentence is not lost when the detector wakes up.
  final int preRollMs;

  /// Absolute floor for the speech threshold (≈ −49 dBFS RMS). Must stay low:
  /// clearly audible speech from across a room can be this quiet on an
  /// un-gained iPhone microphone.
  final double minThreshold;

  /// A segment opens when RMS ≥ noiseFloor × onsetRatio…
  final double onsetRatio;

  /// …and audio inside a segment counts as silence below noiseFloor × releaseRatio.
  final double releaseRatio;

  final String Function() _segmentIdFactory;

  static String _defaultIdFactory() {
    // uuid-v4-shaped id without an extra dependency in this hot path.
    final random = math.Random.secure();
    String hex(int count) =>
        List.generate(count, (_) => random.nextInt(16).toRadixString(16)).join();
    return '${hex(8)}-${hex(4)}-4${hex(3)}-a${hex(3)}-${hex(12)}';
  }

  static const double _floorMin = 0.0012;
  static const double _floorMax = 0.02;

  double _noiseFloor = 0.003;

  String? _segmentId;
  int _sequence = 0;
  int _segmentBytes = 0;
  int _silentBytes = 0;
  final List<Uint8List> _preRoll = [];
  int _preRollBytes = 0;

  bool get isSpeaking => _segmentId != null;

  /// Current adaptive noise floor (RMS, 0..1) — exposed for diagnostics.
  double get noiseFloor => _noiseFloor;

  /// Current segment-opening threshold (RMS, 0..1).
  double get onsetThreshold => math.max(minThreshold, _noiseFloor * onsetRatio);

  double get _releaseThreshold => math.max(minThreshold * 0.8, _noiseFloor * releaseRatio);

  int _msToBytes(int ms) => (sampleRate * 2 * ms) ~/ 1000;
  int _bytesToMs(int bytes) => (bytes * 1000) ~/ (sampleRate * 2);

  /// Feed a chunk of PCM16LE mono audio (any size; ~50–150 ms works best).
  void addAudio(Uint8List pcm) {
    if (pcm.isEmpty) return;
    final rms = _rms(pcm);
    final threshold = onsetThreshold;
    final inSegment = _segmentId != null;
    final isSpeech = rms >= (inSegment ? _releaseThreshold : threshold);

    _adaptNoiseFloor(rms, isAboveThreshold: rms >= threshold, inSegment: inSegment);

    // Perceptual level for the waveform: map −60..0 dBFS to 0..1 so distant
    // speech is visible instead of flatlining near zero.
    final dbfs = rms <= 0 ? -60.0 : math.max(-60.0, 20 * math.log(rms) / math.ln10);
    onLevel?.call(((dbfs + 60) / 60).clamp(0.0, 1.0), isSpeech);
    onDiagnostics?.call(VadDiagnostics(
      rms: rms,
      noiseFloor: _noiseFloor,
      threshold: threshold,
      isSpeech: isSpeech,
      segmentId: _segmentId,
    ));

    if (_segmentId == null) {
      if (isSpeech) {
        _openSegment(pcm, rms, threshold);
      } else {
        _pushPreRoll(pcm);
      }
      return;
    }

    // Inside a segment: everything is streamed (speech and short pauses),
    // so words are not chopped out of the middle of a sentence.
    _emit(pcm);
    _silentBytes = isSpeech ? 0 : _silentBytes + pcm.length;

    if (_bytesToMs(_silentBytes) >= silenceHangoverMs) {
      _closeSegment(rms, threshold);
    } else if (_bytesToMs(_segmentBytes) >= maxSegmentMs) {
      _closeSegment(rms, threshold);
    }
  }

  void _adaptNoiseFloor(double rms, {required bool isAboveThreshold, required bool inSegment}) {
    if (rms < _noiseFloor) {
      // Follow drops quickly — a quiet room should re-arm sensitivity fast.
      _noiseFloor = _noiseFloor * 0.9 + rms * 0.1;
    } else if (!inSegment && !isAboveThreshold) {
      // Sub-threshold ambience (hum, rumble): converge onto it over ~15 s so
      // steady noise stops looking like speech, without chasing speech peaks.
      _noiseFloor = _noiseFloor * 0.995 + rms * 0.005;
    } else {
      // Sound above the threshold IS the signal we exist to capture. Rise only
      // glacially (×1.0002 per chunk ≈ +2% per 10 s) so hours of TV or
      // conversation can never teach the detector that speech is noise.
      _noiseFloor = math.min(_noiseFloor * 1.0002, _floorMax);
    }
    _noiseFloor = _noiseFloor.clamp(_floorMin, _floorMax);
  }

  /// Force-close any open segment (used when the user presses Stop).
  void flush() {
    if (_segmentId != null) _closeSegment(0, onsetThreshold);
    _preRoll.clear();
    _preRollBytes = 0;
  }

  void _openSegment(Uint8List trigger, double rms, double threshold) {
    _segmentId = _segmentIdFactory();
    _sequence = 0;
    _segmentBytes = 0;
    _silentBytes = 0;
    onSegmentStart(_segmentId!, sampleRate);
    onDiagnostics?.call(VadDiagnostics(
      rms: rms,
      noiseFloor: _noiseFloor,
      threshold: threshold,
      isSpeech: true,
      event: 'segment_start',
      segmentId: _segmentId,
    ));
    for (final chunk in _preRoll) {
      _emit(chunk);
    }
    _preRoll.clear();
    _preRollBytes = 0;
    _emit(trigger);
  }

  void _emit(Uint8List pcm) {
    onAudio(_segmentId!, _sequence, pcm);
    _sequence++;
    _segmentBytes += pcm.length;
  }

  void _closeSegment(double rms, double threshold) {
    final id = _segmentId!;
    final durationMs = _bytesToMs(_segmentBytes);
    // The trailing silence hangover is part of the segment audio but is not
    // speech — a short blip must not pass the minimum just because the
    // hangover followed it.
    final speechMs = _bytesToMs(_segmentBytes - _silentBytes);
    _segmentId = null;
    _segmentBytes = 0;
    _silentBytes = 0;
    final kept = speechMs >= minSegmentMs;
    onDiagnosticsEvent(kept ? 'segment_end' : 'segment_discarded', id, rms, threshold);
    if (kept) {
      onSegmentEnd(id, durationMs);
    } else {
      // Too short to be an utterance — tell the pipeline to forget it.
      onSegmentEnd(id, 0);
    }
  }

  void onDiagnosticsEvent(String event, String segmentId, double rms, double threshold) {
    onDiagnostics?.call(VadDiagnostics(
      rms: rms,
      noiseFloor: _noiseFloor,
      threshold: threshold,
      isSpeech: false,
      event: event,
      segmentId: segmentId,
    ));
  }

  void _pushPreRoll(Uint8List pcm) {
    _preRoll.add(pcm);
    _preRollBytes += pcm.length;
    final maxBytes = _msToBytes(preRollMs);
    while (_preRollBytes > maxBytes && _preRoll.isNotEmpty) {
      _preRollBytes -= _preRoll.removeAt(0).length;
    }
  }

  double _rms(Uint8List pcm) {
    final data = ByteData.sublistView(pcm);
    final sampleCount = pcm.length ~/ 2;
    if (sampleCount == 0) return 0;
    double sum = 0;
    for (var i = 0; i < sampleCount; i++) {
      final sample = data.getInt16(i * 2, Endian.little) / 32768.0;
      sum += sample * sample;
    }
    return math.sqrt(sum / sampleCount);
  }
}
