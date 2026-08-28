import 'dart:math' as math;
import 'dart:typed_data';

typedef SegmentStartCallback = void Function(String segmentId, int sampleRate);
typedef SegmentAudioCallback = void Function(String segmentId, int sequence, Uint8List pcm);
typedef SegmentEndCallback = void Function(String segmentId, int durationMs);
typedef LevelCallback = void Function(double level, bool isSpeech);

/// Energy-based voice activity detection over a PCM16 mono stream.
///
/// Splits the microphone stream into speech segments so that:
///  - silence never leaves the phone (privacy, battery, API cost),
///  - each segment approximates one utterance (natural sentence boundaries
///    via a silence hangover),
///  - segments are capped so one long monologue still translates in pieces.
///
/// The noise floor adapts, so a restaurant and a quiet room both work without
/// tuning. All timing is derived from sample counts, which makes the class
/// deterministic and unit-testable.
class VadSegmenter {
  VadSegmenter({
    required this.sampleRate,
    required this.onSegmentStart,
    required this.onAudio,
    required this.onSegmentEnd,
    this.onLevel,
    String Function()? segmentIdFactory,
    this.silenceHangoverMs = 800,
    this.maxSegmentMs = 10000,
    this.minSegmentMs = 350,
    this.preRollMs = 350,
    this.minThreshold = 0.012,
    this.noiseFloorRatio = 3.0,
  }) : _segmentIdFactory = segmentIdFactory ?? _defaultIdFactory;

  final int sampleRate;
  final SegmentStartCallback onSegmentStart;
  final SegmentAudioCallback onAudio;
  final SegmentEndCallback onSegmentEnd;
  final LevelCallback? onLevel;

  /// Silence needed to consider the utterance finished.
  final int silenceHangoverMs;
  final int maxSegmentMs;
  final int minSegmentMs;

  /// Audio kept from just before speech was detected, so the first syllable
  /// is not clipped.
  final int preRollMs;
  final double minThreshold;
  final double noiseFloorRatio;

  final String Function() _segmentIdFactory;

  static String _defaultIdFactory() {
    // uuid-v4-shaped id without an extra dependency in this hot path.
    final random = math.Random.secure();
    String hex(int count) =>
        List.generate(count, (_) => random.nextInt(16).toRadixString(16)).join();
    return '${hex(8)}-${hex(4)}-4${hex(3)}-a${hex(3)}-${hex(12)}';
  }

  double _noiseFloor = 0.006;

  String? _segmentId;
  int _sequence = 0;
  int _segmentBytes = 0;
  int _silentBytes = 0;
  final List<Uint8List> _preRoll = [];
  int _preRollBytes = 0;

  bool get isSpeaking => _segmentId != null;

  int _msToBytes(int ms) => (sampleRate * 2 * ms) ~/ 1000;
  int _bytesToMs(int bytes) => (bytes * 1000) ~/ (sampleRate * 2);

  /// Feed a chunk of PCM16LE mono audio (any size; ~50–150 ms works best).
  void addAudio(Uint8List pcm) {
    if (pcm.isEmpty) return;
    final rms = _rms(pcm);

    // Adapt the noise floor: follow quiet levels quickly, rise only slowly so
    // sustained speech does not teach the detector that speech is "noise".
    if (rms < _noiseFloor) {
      _noiseFloor = _noiseFloor * 0.9 + rms * 0.1;
    } else {
      _noiseFloor = math.min(_noiseFloor * 1.008, 0.04);
    }
    _noiseFloor = math.max(_noiseFloor, 0.002);

    final threshold = math.max(minThreshold, _noiseFloor * noiseFloorRatio);
    final isSpeech = rms >= threshold;
    onLevel?.call(math.min(1.0, rms * 6), isSpeech);

    if (_segmentId == null) {
      if (isSpeech) {
        _openSegment(pcm);
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
      _closeSegment();
    } else if (_bytesToMs(_segmentBytes) >= maxSegmentMs) {
      _closeSegment();
    }
  }

  /// Force-close any open segment (used when the user presses Stop).
  void flush() {
    if (_segmentId != null) _closeSegment();
    _preRoll.clear();
    _preRollBytes = 0;
  }

  void _openSegment(Uint8List trigger) {
    _segmentId = _segmentIdFactory();
    _sequence = 0;
    _segmentBytes = 0;
    _silentBytes = 0;
    onSegmentStart(_segmentId!, sampleRate);
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

  void _closeSegment() {
    final id = _segmentId!;
    final durationMs = _bytesToMs(_segmentBytes);
    // The trailing silence hangover is part of the segment audio but is not
    // speech — a short blip must not pass the minimum just because 800 ms of
    // silence followed it.
    final speechMs = _bytesToMs(_segmentBytes - _silentBytes);
    _segmentId = null;
    _segmentBytes = 0;
    _silentBytes = 0;
    if (speechMs >= minSegmentMs) {
      onSegmentEnd(id, durationMs);
    } else {
      // Too short to be an utterance — tell the pipeline to forget it.
      onSegmentEnd(id, 0);
    }
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
