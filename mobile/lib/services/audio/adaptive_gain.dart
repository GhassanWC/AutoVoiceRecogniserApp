import 'dart:math' as math;
import 'dart:typed_data';

/// What one chunk looked like before and after gain. Diagnostics only — no
/// audio ever leaves this object.
class GainReport {
  const GainReport({
    required this.rawRms,
    required this.rawPeak,
    required this.processedRms,
    required this.appliedGain,
    required this.peakAfterGain,
    required this.clippedSamples,
    required this.noiseFloor,
  });

  final double rawRms;

  /// Loudest input sample in the chunk, 0..1. RMS alone hides a distant voice
  /// whose peaks are the only thing standing above the room.
  final double rawPeak;

  final double processedRms;
  final double appliedGain;
  final double peakAfterGain;
  final int clippedSamples;
  final double noiseFloor;

  static const GainReport idle = GainReport(
    rawRms: 0,
    rawPeak: 0,
    processedRms: 0,
    appliedGain: 1,
    peakAfterGain: 0,
    clippedSamples: 0,
    noiseFloor: 0,
  );
}

/// A bounded, adaptive pre-gain for the microphone signal on its way to Gemini.
///
/// WHY THIS EXISTS. Sayvo captures the whole room deliberately: iOS runs the
/// session in `.measurement` mode and Android keeps noise suppression and echo
/// cancellation off, because that processing is tuned for a phone call and
/// strips out exactly the distant speech this app is for. The cost of that
/// choice is that iOS also loses Apple's automatic gain control, so somebody
/// three metres away arrives as a genuinely quiet signal — accurate, but quiet
/// enough that speech detection can miss it.
///
/// This puts a controlled amount of that gain back, in the digital domain
/// where it is bounded and measurable, instead of reaching for a capture mode
/// that would throw the room away.
///
/// What it is careful about:
///  - it only lifts material that stands above the tracked noise floor, so a
///    fan or an air conditioner is not amplified into the model's ear;
///  - the gain that noise could ever receive is capped by [noiseCeiling], so
///    a silent room cannot be walked up to full scale;
///  - it comes down fast and goes up slowly, so a sudden loud voice cannot
///    clip and a quiet one is not pumped;
///  - it soft-limits near full scale and can never emit a sample outside the
///    Int16 range.
///
/// It is NOT a gate. Every chunk it is given comes back out; quiet chunks are
/// passed through, never dropped. Billing sees the ORIGINAL level, measured
/// before any of this runs.
class AdaptiveGain {
  AdaptiveGain({
    this.targetRms = 0.06,
    this.maxGain = 6.0,
    this.noiseCeiling = 0.035,
    this.gainUpRate = 0.35,
    this.gainDownRate = 0.35,
    this.limitThreshold = 0.89,
    this.contentRatio = 1.25,
    this.absoluteFloor = 0.0006,
    this.enabled = true,
  });

  /// How far above the tracked noise floor a chunk must sit before it is worth
  /// lifting at all.
  ///
  /// This was 2.0, and that is where the quietest speech was lost: a person
  /// three metres away in a room with any air conditioning arrives at barely
  /// more than the floor, failed this test, and was handed a gain of exactly
  /// 1.0 — the one signal in the building that needed help got none. 1.25 is
  /// low enough to catch them. It is safe to be this low because it does not
  /// decide what gets SENT (everything does) and because [noiseCeiling]
  /// separately caps how loud the room itself can ever be made.
  final double contentRatio;

  /// A floor under the floor: below this, a chunk is silence however the
  /// ratio works out.
  final double absoluteFloor;

  /// Where speech should land, roughly −24 dBFS: loud enough to detect, with
  /// plenty of headroom left for a sudden nearby voice.
  final double targetRms;

  /// Never more than this, however quiet the room. Far-field speech that
  /// needs more than 6× is below the microphone's noise floor anyway, and
  /// amplifying further would only raise hiss.
  final double maxGain;

  /// The loudest the amplified NOISE FLOOR is ever allowed to become. This is
  /// what stops a quiet room being walked up to full scale, and it is the
  /// clause — not [contentRatio] — that keeps a fan or an air conditioner out
  /// of the model's ear.
  ///
  /// It is also a hard cap on how much help a distant voice can get: in a
  /// room with a floor of 0.01 the old 0.02 allowed 2× and no more, whatever
  /// [maxGain] said. 0.035 buys a distant speaker ~3.5× in that same room
  /// while still holding amplified noise around −29 dBFS.
  final double noiseCeiling;

  /// Gain falls quickly (no clipping) and rises quickly enough to be useful
  /// within an utterance.
  ///
  /// This was 0.08 per 100 ms chunk — a ~2 second climb to a useful gain, so
  /// the opening words of every quiet sentence went upstream under-amplified
  /// and the model saw exactly the fragment it was least able to detect.
  /// 0.35 gets most of the way inside ~300 ms. The soft limiter and the
  /// [noiseCeiling] cap are what make a fast attack safe.
  final double gainUpRate;
  final double gainDownRate;

  /// Where the soft limiter starts, as a fraction of full scale.
  final double limitThreshold;

  /// Escape hatch: when false every chunk passes through untouched, which is
  /// the A/B baseline for a device comparison.
  final bool enabled;

  /// PCM16 normalization. 32768 is the convention used by [pcm16Rms] too, so
  /// the level in a diagnostic line is the same number the meter and the
  /// waveform are looking at — and it round-trips every sample exactly.
  static const double _int16Scale = 32768.0;

  /// The room is ASSUMED quiet until measured otherwise, and deliberately so:
  /// a session that starts while somebody is already talking must treat that
  /// voice as speech, not adopt its level as the floor. The floor drops fast
  /// toward a genuinely quieter room and only creeps up on non-speech.
  double _noiseFloor = 0.003;
  double get noiseFloor => _noiseFloor;

  double _gain = 1.0;
  double get gain => _gain;

  /// Applies gain to one PCM16LE mono chunk, returning the chunk to send and
  /// what happened to it. The input buffer is never modified in place.
  GainReport apply(Uint8List pcm, Uint8List out) {
    final samples = pcm.lengthInBytes ~/ 2;
    if (samples == 0) return GainReport.idle;
    final input = ByteData.sublistView(pcm, 0, samples * 2);

    var sumSquares = 0.0;
    var rawPeak = 0.0;
    for (var i = 0; i < samples; i++) {
      final value = input.getInt16(i * 2, Endian.little) / _int16Scale;
      sumSquares += value * value;
      final magnitude = value.abs();
      if (magnitude > rawPeak) rawPeak = magnitude;
    }
    final rawRms = math.sqrt(sumSquares / samples);

    // Worked out BEFORE the floor moves, so the two stay consistent.
    final isContent = rawRms > math.max(_noiseFloor * contentRatio, absoluteFloor);
    _trackNoiseFloor(rawRms, isContent: isContent);
    if (!enabled) {
      out.setRange(0, samples * 2, pcm);
      return GainReport(
        rawRms: rawRms,
        rawPeak: rawPeak,
        processedRms: rawRms,
        appliedGain: 1,
        peakAfterGain: rawPeak,
        clippedSamples: 0,
        noiseFloor: _noiseFloor,
      );
    }

    _updateGain(rawRms, isContent);

    // Nothing to do: hand the samples straight through rather than paying for
    // a pointless copy-with-multiply.
    if (_gain <= 1.0001) {
      out.setRange(0, samples * 2, pcm);
      return GainReport(
        rawRms: rawRms,
        rawPeak: rawPeak,
        processedRms: rawRms,
        appliedGain: 1,
        peakAfterGain: rawPeak,
        clippedSamples: 0,
        noiseFloor: _noiseFloor,
      );
    }

    final output = ByteData.sublistView(out, 0, samples * 2);
    var outSumSquares = 0.0;
    var outPeak = 0.0;
    var clipped = 0;
    for (var i = 0; i < samples; i++) {
      var value = (input.getInt16(i * 2, Endian.little) / _int16Scale) * _gain;
      final magnitude = value.abs();
      if (magnitude > limitThreshold) {
        final limited = _softLimit(magnitude);
        if (limited >= 0.9999) clipped++;
        value = value.isNegative ? -limited : limited;
      }
      final scaled = (value * _int16Scale).round().clamp(-32768, 32767);
      output.setInt16(i * 2, scaled, Endian.little);
      final normalized = scaled / _int16Scale;
      outSumSquares += normalized * normalized;
      final outMagnitude = normalized.abs();
      if (outMagnitude > outPeak) outPeak = outMagnitude;
    }

    return GainReport(
      rawRms: rawRms,
      rawPeak: rawPeak,
      processedRms: math.sqrt(outSumSquares / samples),
      appliedGain: _gain,
      peakAfterGain: outPeak,
      clippedSamples: clipped,
      noiseFloor: _noiseFloor,
    );
  }

  void _trackNoiseFloor(double rms, {required bool isContent}) {
    // Drops quickly toward a quieter room. It may only creep UP on material
    // that is not speech: letting the floor chase a voice would raise it
    // until that voice stopped counting as content and the gain switched
    // off — precisely for the continuous quiet talker this exists to help.
    if (rms < _noiseFloor) {
      _noiseFloor += (rms - _noiseFloor) * 0.2;
    } else if (!isContent) {
      _noiseFloor += (rms - _noiseFloor) * 0.005;
    }
    _noiseFloor = _noiseFloor.clamp(0.0002, 0.05);
  }

  void _updateGain(double rawRms, bool isContent) {
    // Only material standing clear of the floor is worth lifting; anything
    // else is the room itself.
    // However quiet the room, the amplified floor must stay below the
    // ceiling — this is the clause that stops runaway gain on silence.
    final noiseCap = noiseCeiling / math.max(_noiseFloor, 1e-6);
    final ceiling = math.max(1.0, math.min(maxGain, noiseCap));
    final desired = isContent
        ? (targetRms / math.max(rawRms, 1e-6)).clamp(1.0, ceiling)
        : 1.0;
    final rate = desired < _gain ? gainDownRate : gainUpRate;
    _gain += (desired - _gain) * rate;
    if (_gain < 1.0) _gain = 1.0;
    if (_gain > maxGain) _gain = maxGain;
  }

  /// Smoothly bends everything above the threshold into the remaining
  /// headroom, so a loud sample is squeezed rather than squared off.
  double _softLimit(double magnitude) {
    final over = (magnitude - limitThreshold) / (1 - limitThreshold);
    final squashed = _tanh(over);
    return limitThreshold + (1 - limitThreshold) * squashed;
  }

  static double _tanh(double x) {
    if (x > 10) return 1;
    final e = math.exp(2 * x);
    return (e - 1) / (e + 1);
  }

  /// A new session starts from a neutral state rather than inheriting the
  /// last room's floor.
  void reset() {
    _noiseFloor = 0.003;
    _gain = 1.0;
  }
}
