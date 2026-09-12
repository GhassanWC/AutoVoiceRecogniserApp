import Accelerate
import CoreML
import Foundation

/// CI parity harness (macOS): runs the EXACT SpeechBrainFbank.swift that
/// ships in the app, plus the compiled Core ML backend, over a raw
/// float32 PCM file. Compiled on the Codemagic Mac with:
///   swiftc -O tools/LangIdParityMain.swift \
///          mobile/ios/Runner/SpeechBrainFbank.swift -o langid_parity \
///          -framework CoreML -framework Accelerate
/// Usage: langid_parity <assetsDir> <pcmFloat32File> <featuresOutFile>
/// Writes the computed features (float32) to featuresOutFile and prints
/// "PROBS p0 p1 …" for the backend's 107 probabilities.
@main
struct LangIdParity {
  static func main() {
    do {
      let args = CommandLine.arguments
      guard args.count == 4 else {
        FileHandle.standardError.write(
          "usage: langid_parity <assetsDir> <pcm.f32> <features.out>\n"
            .data(using: .utf8)!)
        exit(2)
      }
      let assets = URL(fileURLWithPath: args[1])
      let pcmData = try Data(contentsOf: URL(fileURLWithPath: args[2]))
      var samples = [Float](repeating: 0, count: pcmData.count / 4)
      _ = samples.withUnsafeMutableBytes { pcmData.copyBytes(to: $0) }

      let fbank = try SpeechBrainFbank(assetsDirectory: assets)
      let prepared = fbank.prepare(samples: samples)
      let features = fbank.compute(prepared)
      try features.withUnsafeBufferPointer { buffer in
        try Data(buffer: buffer).write(to: URL(fileURLWithPath: args[3]))
      }

      let configuration = MLModelConfiguration()
      configuration.computeUnits = .all
      let model = try MLModel(
        contentsOf: assets.appendingPathComponent("LangIDBackend.mlmodelc"),
        configuration: configuration)
      let shape: [NSNumber] = [
        1, NSNumber(value: fbank.config.frames),
        NSNumber(value: fbank.config.nMels),
      ]
      let input = try MLMultiArray(shape: shape, dataType: .float32)
      let pointer = input.dataPointer.bindMemory(
        to: Float32.self, capacity: features.count)
      for i in 0..<features.count { pointer[i] = features[i] }
      let output = try model.prediction(
        from: MLDictionaryFeatureProvider(dictionary: ["features": input]))
      guard let probs = output.featureValue(for: "probabilities")?.multiArrayValue
      else {
        FileHandle.standardError.write(
          "missing probabilities output\n".data(using: .utf8)!)
        exit(1)
      }
      let line = (0..<probs.count)
        .map { String(format: "%.6f", probs[$0].doubleValue) }
        .joined(separator: " ")
      print("PROBS \(line)")
    } catch {
      FileHandle.standardError.write(
        "langid_parity failed: \(error)\n".data(using: .utf8)!)
      exit(1)
    }
  }
}
