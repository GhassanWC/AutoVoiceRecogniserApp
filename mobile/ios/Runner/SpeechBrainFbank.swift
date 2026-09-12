import Accelerate
import Foundation

/// SpeechBrain-compatible log-mel Fbank + sentence normalization, computed
/// natively (vDSP) for the VoxLingua107 language-ID backend.
///
/// This class derives NOTHING itself: the windowed DFT basis, the mel
/// filterbank matrix (extracted numerically from the live SpeechBrain
/// Filterbank module) and every scalar (hop, amin, multiplier, top-db,
/// padding mode, shapes) are exported at build time by
/// tools/convert_langid_coreml.py into frontend.json + frontend.bin.
/// The SAME Swift file is compiled by CI with swiftc and gated numerically
/// against SpeechBrain's own features before any build ships.
///
/// Pipeline (mirrors speechbrain.lobes.features.Fbank + InputNormalization
/// with norm_type=sentence, std_norm=false):
///   zero center-pad (n_fft/2) → frames (hop) → windowed DFT (matmul)
///   → power spectrum → mel matmul → 10·log10(max(x, amin)) − 10·log10(ref)
///   → top-db floor (global max − top_db) → per-bin mean subtraction.
final class SpeechBrainFbank {
  struct Config: Decodable {
    let sampleRate: Int
    let windowSamples: Int
    let nFft: Int
    let hop: Int
    let nFreq: Int
    let nMels: Int
    let frames: Int
    let power: Double
    let amin: Double
    let multiplier: Double
    let dbMultiplier: Double
    let topDb: Double
    let padding: String
    let cosBasisCount: Int
    let sinBasisCount: Int
    let melCount: Int
  }

  enum FbankError: LocalizedError {
    case assetsMissing(String)

    var errorDescription: String? {
      switch self {
      case .assetsMissing(let detail):
        return "Language-ID frontend assets are missing or invalid: \(detail)"
      }
    }
  }

  let config: Config
  private let cosBasis: [Float]  // [nFft × nFreq], row-major
  private let sinBasis: [Float]  // [nFft × nFreq], row-major
  private let melMatrix: [Float]  // [nFreq × nMels], row-major

  init(assetsDirectory: URL) throws {
    let configURL = assetsDirectory.appendingPathComponent("frontend.json")
    let binURL = assetsDirectory.appendingPathComponent("frontend.bin")
    guard let configData = try? Data(contentsOf: configURL),
      let parsed = try? JSONDecoder().decode(Config.self, from: configData)
    else { throw FbankError.assetsMissing("frontend.json") }
    guard let blob = try? Data(contentsOf: binURL) else {
      throw FbankError.assetsMissing("frontend.bin")
    }
    let totalFloats = parsed.cosBasisCount + parsed.sinBasisCount + parsed.melCount
    guard blob.count == totalFloats * 4 else {
      throw FbankError.assetsMissing(
        "frontend.bin has \(blob.count) bytes, expected \(totalFloats * 4)")
    }
    var floats = [Float](repeating: 0, count: totalFloats)
    _ = floats.withUnsafeMutableBytes { blob.copyBytes(to: $0) }
    self.config = parsed
    self.cosBasis = Array(floats[0..<parsed.cosBasisCount])
    self.sinBasis = Array(
      floats[parsed.cosBasisCount..<(parsed.cosBasisCount + parsed.sinBasisCount)])
    self.melMatrix = Array(floats[(parsed.cosBasisCount + parsed.sinBasisCount)...])
  }

  /// Pads/trims arbitrary-length audio to the fixed analysis window using
  /// the build-time-validated strategy: long clips keep their middle
  /// window; short clips are zero- or tile-padded per config (the CI
  /// parity test chose whichever mode reproduces official results).
  func prepare(samples: [Float]) -> [Float] {
    let target = config.windowSamples
    if samples.count >= target {
      let start = (samples.count - target) / 2
      return Array(samples[start..<(start + target)])
    }
    if samples.isEmpty { return [Float](repeating: 0, count: target) }
    var out = [Float](repeating: 0, count: target)
    if config.padding == "tile" {
      for i in 0..<target { out[i] = samples[i % samples.count] }
    } else {
      out.replaceSubrange(0..<samples.count, with: samples)
    }
    return out
  }

  /// [windowSamples] Float32 → normalized features [frames × nMels],
  /// row-major (frame-major), exactly as the Core ML backend expects.
  func compute(_ samples: [Float]) -> [Float] {
    let nFft = config.nFft
    let hop = config.hop
    let nFreq = config.nFreq
    let nMels = config.nMels
    let frames = config.frames
    let pad = nFft / 2

    // Zero center-padding (SpeechBrain STFT: center=True, pad_mode=constant).
    var padded = [Float](repeating: 0, count: samples.count + 2 * pad)
    padded.replaceSubrange(pad..<(pad + samples.count), with: samples)

    // Frame matrix [frames × nFft].
    var frameMat = [Float](repeating: 0, count: frames * nFft)
    frameMat.withUnsafeMutableBufferPointer { dst in
      padded.withUnsafeBufferPointer { src in
        for f in 0..<frames {
          let start = f * hop
          memcpy(dst.baseAddress! + f * nFft, src.baseAddress! + start,
                 nFft * MemoryLayout<Float>.size)
        }
      }
    }

    // Windowed DFT via two matmuls: [frames×nFft]·[nFft×nFreq].
    var real = [Float](repeating: 0, count: frames * nFreq)
    var imag = [Float](repeating: 0, count: frames * nFreq)
    vDSP_mmul(frameMat, 1, cosBasis, 1, &real, 1,
              vDSP_Length(frames), vDSP_Length(nFreq), vDSP_Length(nFft))
    vDSP_mmul(frameMat, 1, sinBasis, 1, &imag, 1,
              vDSP_Length(frames), vDSP_Length(nFreq), vDSP_Length(nFft))

    // Power spectrum (power=2 → r²+i²; power=1 → sqrt of that).
    var spec = [Float](repeating: 0, count: frames * nFreq)
    vDSP_vsq(real, 1, &real, 1, vDSP_Length(frames * nFreq))
    vDSP_vsq(imag, 1, &imag, 1, vDSP_Length(frames * nFreq))
    vDSP_vadd(real, 1, imag, 1, &spec, 1, vDSP_Length(frames * nFreq))
    let halfPower = config.power / 2.0
    if abs(halfPower - 1.0) > 1e-9 {
      if abs(halfPower - 0.5) < 1e-9 {
        var count = Int32(frames * nFreq)
        vvsqrtf(&spec, spec, &count)
      } else {
        let exponent = Float(halfPower)
        for i in 0..<spec.count { spec[i] = powf(spec[i], exponent) }
      }
    }

    // Mel projection: [frames×nFreq]·[nFreq×nMels].
    var mel = [Float](repeating: 0, count: frames * nMels)
    vDSP_mmul(spec, 1, melMatrix, 1, &mel, 1,
              vDSP_Length(frames), vDSP_Length(nMels), vDSP_Length(nFreq))

    // dB: multiplier · log10(max(x, amin)) − multiplier · dbMultiplier.
    var lo = Float(config.amin)
    var hi = Float.greatestFiniteMagnitude
    vDSP_vclip(mel, 1, &lo, &hi, &mel, 1, vDSP_Length(frames * nMels))
    var count = Int32(frames * nMels)
    vvlog10f(&mel, mel, &count)
    var scale = Float(config.multiplier)
    var offset = Float(-config.multiplier * config.dbMultiplier)
    vDSP_vsmsa(mel, 1, &scale, &offset, &mel, 1, vDSP_Length(frames * nMels))

    // top-db floor: max over the whole utterance minus topDb.
    var peak: Float = 0
    vDSP_maxv(mel, 1, &peak, vDSP_Length(frames * nMels))
    var floorValue = peak - Float(config.topDb)
    var ceil = Float.greatestFiniteMagnitude
    vDSP_vclip(mel, 1, &floorValue, &ceil, &mel, 1, vDSP_Length(frames * nMels))

    // Sentence normalization: subtract each mel bin's mean over time.
    mel.withUnsafeMutableBufferPointer { buffer in
      for bin in 0..<nMels {
        var mean: Float = 0
        vDSP_meanv(buffer.baseAddress! + bin, nMels, &mean, vDSP_Length(frames))
        var negMean = -mean
        vDSP_vsadd(buffer.baseAddress! + bin, nMels, &negMean,
                   buffer.baseAddress! + bin, nMels, vDSP_Length(frames))
      }
    }
    return mel
  }
}
