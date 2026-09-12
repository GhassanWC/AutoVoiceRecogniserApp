import CoreML
import Flutter
import Foundation
import Speech

/// On-device spoken-language identification straight from AUDIO —
/// VoxLingua107 ECAPA-TDNN (SpeechBrain, Apache-2.0) converted to Core ML
/// at build time (tools/convert_langid_coreml.py → Runner bundle
/// LanguageID/). 107 languages, ~45 MB, zero network, zero recurring cost.
///
/// This is the FIRST stage of the new pipeline: detect the language from
/// the utterance audio itself, THEN run exactly one Apple speech recognizer
/// for that language. Detection never depends on transcription.
final class AudioLanguageDetector {
  struct Candidate {
    let language: String
    let confidence: Double
  }

  struct DetectionResult {
    let language: String
    let confidence: Double
    let alternatives: [Candidate]
  }

  enum DetectorError: LocalizedError {
    case modelMissing
    case badAudio
    case inferenceFailed(String)

    var errorDescription: String? {
      switch self {
      case .modelMissing:
        return "The language-identification model is not in this build "
          + "(the CI conversion step did not run)."
      case .badAudio:
        return "The audio buffer was empty or unreadable."
      case .inferenceFailed(let detail):
        return "Language identification failed: \(detail)"
      }
    }
  }

  static let shared = AudioLanguageDetector()

  /// Fixed analysis window baked into the Core ML graph (5 s @ 16 kHz).
  private static let windowSamples = 80_000
  private static let sampleRate = 16_000

  /// CI may ship either ONE fused model or a SPLIT pair (frontend
  /// wav→features + backend features→probabilities). The split exists
  /// because coremltools' fused-graph conversion diverged numerically; the
  /// separately-converted halves passed the parity gate. model_info.json's
  /// "pipeline" field says which layout this build carries.
  private enum LoadedModel {
    case single(MLModel)
    case split(frontend: MLModel, backend: MLModel)
  }

  private var model: LoadedModel?
  private var labels: [String] = []
  private let loadLock = NSLock()

  // ── Bundle assets ──────────────────────────────────────────────────────────

  private static var assetDirectory: URL? {
    Bundle.main.resourceURL?.appendingPathComponent("LanguageID")
  }

  /// True when the CI-bundled model is inside this build (either layout).
  static var isModelBundled: Bool {
    guard let dir = assetDirectory else { return false }
    let fm = FileManager.default
    return fm.fileExists(
      atPath: dir.appendingPathComponent("VoxLingua107LangID.mlmodelc").path)
      || (fm.fileExists(
        atPath: dir.appendingPathComponent("LangIDFrontend.mlmodelc").path)
        && fm.fileExists(
          atPath: dir.appendingPathComponent("LangIDBackend.mlmodelc").path))
  }

  static var bundledModelBytes: Int {
    guard let dir = assetDirectory,
      let files = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey])
    else { return 0 }
    var total = 0
    for case let url as URL in files {
      total += (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }
    return total
  }

  private func loadIfNeeded() throws {
    loadLock.lock()
    defer { loadLock.unlock() }
    if model != nil { return }
    guard let dir = Self.assetDirectory else { throw DetectorError.modelMissing }
    let labelsURL = dir.appendingPathComponent("labels.json")
    guard let labelData = try? Data(contentsOf: labelsURL),
      let labelList = try? JSONDecoder().decode([String].self, from: labelData),
      !labelList.isEmpty
    else { throw DetectorError.modelMissing }
    let configuration = MLModelConfiguration()
    configuration.computeUnits = .all  // let Core ML pick ANE/GPU/CPU
    let fm = FileManager.default
    let singleURL = dir.appendingPathComponent("VoxLingua107LangID.mlmodelc")
    let frontURL = dir.appendingPathComponent("LangIDFrontend.mlmodelc")
    let backURL = dir.appendingPathComponent("LangIDBackend.mlmodelc")
    do {
      if fm.fileExists(atPath: singleURL.path) {
        model = .single(try MLModel(contentsOf: singleURL, configuration: configuration))
      } else if fm.fileExists(atPath: frontURL.path),
        fm.fileExists(atPath: backURL.path)
      {
        model = .split(
          frontend: try MLModel(contentsOf: frontURL, configuration: configuration),
          backend: try MLModel(contentsOf: backURL, configuration: configuration))
      } else {
        throw DetectorError.modelMissing
      }
      labels = labelList
    } catch let error as DetectorError {
      throw error
    } catch {
      throw DetectorError.inferenceFailed("\(error)")
    }
  }

  // ── Detection ──────────────────────────────────────────────────────────────

  /// PCM16LE mono 16 kHz utterance → detected language + top alternatives.
  /// Runs entirely on-device; call from any thread (inference is sync
  /// inside, so dispatch from a background context).
  func detect(pcm16: Data) throws -> DetectionResult {
    try loadIfNeeded()
    guard let model, !labels.isEmpty else { throw DetectorError.modelMissing }
    let sampleCount = pcm16.count / 2
    guard sampleCount > Self.sampleRate / 4 else { throw DetectorError.badAudio }

    // PCM16 → normalized floats in the model's fixed window. Short
    // utterances are TILE-padded (repeated), not zero-padded — the graph's
    // per-utterance feature normalization would otherwise be skewed by
    // silence. Long utterances use their middle 5 seconds.
    let input = try MLMultiArray(
      shape: [1, NSNumber(value: Self.windowSamples)], dataType: .float32)
    let pointer = input.dataPointer.bindMemory(
      to: Float32.self, capacity: Self.windowSamples)
    pcm16.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
      let int16 = raw.bindMemory(to: Int16.self)
      let start = sampleCount > Self.windowSamples
        ? (sampleCount - Self.windowSamples) / 2
        : 0
      for i in 0..<Self.windowSamples {
        let index = sampleCount > Self.windowSamples
          ? start + i
          : i % sampleCount  // tile
        pointer[i] = Float32(Int16(littleEndian: int16[index])) / 32768.0
      }
    }

    let output: MLFeatureProvider
    do {
      switch model {
      case .single(let fused):
        output = try fused.prediction(
          from: try MLDictionaryFeatureProvider(dictionary: ["waveform": input]))
      case .split(let frontend, let backend):
        let frontOut = try frontend.prediction(
          from: try MLDictionaryFeatureProvider(dictionary: ["waveform": input]))
        guard let features = frontOut.featureValue(for: "features")?.multiArrayValue
        else { throw DetectorError.inferenceFailed("missing features output") }
        output = try backend.prediction(
          from: try MLDictionaryFeatureProvider(dictionary: ["features": features]))
      }
    } catch let error as DetectorError {
      throw error
    } catch {
      throw DetectorError.inferenceFailed("\(error)")
    }
    guard let probabilities = output.featureValue(for: "probabilities")?.multiArrayValue
    else { throw DetectorError.inferenceFailed("missing probabilities output") }

    var scored: [Candidate] = []
    let count = min(probabilities.count, labels.count)
    scored.reserveCapacity(count)
    for i in 0..<count {
      scored.append(Candidate(
        language: labels[i], confidence: probabilities[i].doubleValue))
    }
    scored.sort { $0.confidence > $1.confidence }
    let top = scored[0]
    let alternatives = Array(scored.prefix(5))
    NSLog("[LANG-ID] %@", alternatives.enumerated()
      .map { "\($0.offset + 1). \($0.element.language) \(String(format: "%.2f", $0.element.confidence))" }
      .joined(separator: "  "))
    return DetectionResult(
      language: top.language, confidence: top.confidence, alternatives: alternatives)
  }
}

/// Maps a detected ISO language code to the best Apple speech option on
/// THIS device — the one place locale mapping lives. Two separate stages by
/// design: "language detected" vs "can Apple transcribe it here".
enum AppleSpeechLocaleResolver {
  /// Preferred concrete locales for codes where the bare code is ambiguous.
  private static let hints: [String: String] = [
    "en": "en-US", "ar": "ar-SA", "hi": "hi-IN", "th": "th-TH", "bn": "bn-IN",
    "es": "es-ES", "fr": "fr-FR", "de": "de-DE", "zh": "zh-CN", "ja": "ja-JP",
    "ko": "ko-KR", "pt": "pt-BR", "ru": "ru-RU", "it": "it-IT", "id": "id-ID",
    "tr": "tr-TR", "nl": "nl-NL", "vi": "vi-VN", "ur": "ur-PK", "ta": "ta-IN",
  ]

  static func hintedLocale(for code: String) -> Locale {
    Locale(identifier: hints[code] ?? code)
  }

  enum Availability {
    case transcriberReady(Locale)     // SpeechTranscriber asset installed
    case onDevice(Locale)             // SFSpeechRecognizer on-device
    case networkBacked(Locale)        // SFSpeechRecognizer via Apple servers
    case unsupported
  }

  /// Best available Apple recognition path for a detected language, in the
  /// product's priority order. Never throws, never crashes on exotic codes.
  static func resolve(languageCode code: String) async -> Availability {
    if #available(iOS 26.0, *) {
      let hinted = hintedLocale(for: code)
      var match = await SpeechTranscriber.supportedLocale(equivalentTo: hinted)
      if match == nil {
        match = await SpeechTranscriber.supportedLocales.first {
          $0.language.languageCode?.identifier == code
        }
      }
      if let match {
        let installed = await SpeechTranscriber.installedLocales
        if installed.contains(where: { $0.language.languageCode?.identifier == code }) {
          return .transcriberReady(match)
        }
      }
    }
    guard let locale = sfLocale(for: code),
      let recognizer = SFSpeechRecognizer(locale: locale)
    else { return .unsupported }
    if recognizer.supportsOnDeviceRecognition { return .onDevice(locale) }
    return .networkBacked(locale)
  }

  private static func sfLocale(for code: String) -> Locale? {
    let hinted = hintedLocale(for: code)
    let supported = SFSpeechRecognizer.supportedLocales()
    if let exact = supported.first(where: { $0.identifier == hinted.identifier }) {
      return exact
    }
    return supported.first { $0.language.languageCode?.identifier == code }
  }
}

/// MethodChannel front for the detector — used by the ISOLATED developer
/// test first (Settings → Developer → Test Language Detection); the full
/// pipeline adopts it only after the test passes on a real iPhone.
enum LanguageIdBridge {
  static func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "status":
      Task {
        var speech: [String: String] = [:]
        // How each product-relevant language would be transcribed today.
        for code in ["en", "ar", "hi", "th", "bn"] {
          switch await AppleSpeechLocaleResolver.resolve(languageCode: code) {
          case .transcriberReady(let locale): speech[code] = "transcriber:\(locale.identifier)"
          case .onDevice(let locale): speech[code] = "onDevice:\(locale.identifier)"
          case .networkBacked(let locale): speech[code] = "network:\(locale.identifier)"
          case .unsupported: speech[code] = "unsupported"
          }
        }
        let payload: [String: Any] = [
          "modelBundled": AudioLanguageDetector.isModelBundled,
          "modelBytes": AudioLanguageDetector.bundledModelBytes,
          "speechPaths": speech,
        ]
        await MainActor.run { result(payload) }
      }
    case "detect":
      guard let data = ((call.arguments as? [String: Any])?["pcm16"]
        as? FlutterStandardTypedData)?.data
      else {
        result(FlutterError(code: "bad_args", message: "pcm16 audio is required", details: nil))
        return
      }
      DispatchQueue.global(qos: .userInitiated).async {
        do {
          let detection = try AudioLanguageDetector.shared.detect(pcm16: data)
          Task {
            // Report the Apple speech path for the winner too — stage 2
            // honesty ("detected" vs "transcribable") in one round trip.
            let availability = await AppleSpeechLocaleResolver.resolve(
              languageCode: detection.language)
            let speechPath: String
            switch availability {
            case .transcriberReady(let locale): speechPath = "transcriber:\(locale.identifier)"
            case .onDevice(let locale): speechPath = "onDevice:\(locale.identifier)"
            case .networkBacked(let locale): speechPath = "network:\(locale.identifier)"
            case .unsupported: speechPath = "unsupported"
            }
            await MainActor.run {
              result([
                "language": detection.language,
                "confidence": detection.confidence,
                "alternatives": detection.alternatives.map {
                  ["language": $0.language, "confidence": $0.confidence]
                },
                "speechPath": speechPath,
              ])
            }
          }
        } catch {
          DispatchQueue.main.async {
            result(FlutterError(
              code: "langid_failed",
              message: (error as? LocalizedError)?.errorDescription ?? "\(error)",
              details: nil))
          }
        }
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}
