import AVFoundation
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

  private static let sampleRate = 16_000

  /// Features are computed NATIVELY (SpeechBrainFbank, vDSP) and only the
  /// ECAPA+classifier backend runs in Core ML — the waveform→features
  /// Core ML conversion diverged irreparably while the backend converted
  /// exactly (diff 0.0000), so the app keeps the good half and replaces
  /// the bad half with build-time-exported, CI-parity-tested Swift DSP.
  private var backend: MLModel?
  private var fbank: SpeechBrainFbank?
  private var labels: [String] = []
  private let loadLock = NSLock()

  // ── Bundle assets ──────────────────────────────────────────────────────────

  private static var assetDirectory: URL? {
    Bundle.main.resourceURL?.appendingPathComponent("LanguageID")
  }

  /// True when the CI-produced assets are inside this build.
  static var isModelBundled: Bool {
    guard let dir = assetDirectory else { return false }
    let fm = FileManager.default
    return fm.fileExists(
      atPath: dir.appendingPathComponent("LangIDBackend.mlmodelc").path)
      && fm.fileExists(atPath: dir.appendingPathComponent("frontend.json").path)
      && fm.fileExists(atPath: dir.appendingPathComponent("frontend.bin").path)
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
    if backend != nil { return }
    guard let dir = Self.assetDirectory else { throw DetectorError.modelMissing }
    let labelsURL = dir.appendingPathComponent("labels.json")
    guard let labelData = try? Data(contentsOf: labelsURL),
      let labelList = try? JSONDecoder().decode([String].self, from: labelData),
      !labelList.isEmpty
    else { throw DetectorError.modelMissing }
    let backURL = dir.appendingPathComponent("LangIDBackend.mlmodelc")
    guard FileManager.default.fileExists(atPath: backURL.path) else {
      throw DetectorError.modelMissing
    }
    let configuration = MLModelConfiguration()
    configuration.computeUnits = .all  // let Core ML pick ANE/GPU/CPU
    do {
      fbank = try SpeechBrainFbank(assetsDirectory: dir)
      backend = try MLModel(contentsOf: backURL, configuration: configuration)
      labels = labelList
    } catch let error as SpeechBrainFbank.FbankError {
      throw DetectorError.inferenceFailed(error.errorDescription ?? "\(error)")
    } catch {
      throw DetectorError.inferenceFailed("\(error)")
    }
  }

  /// Loads the Core ML model + labels once, without detecting anything —
  /// called at Start Listening so no session utterance ever pays the model
  /// load, and the same instance is reused for the whole session.
  func warmup() throws {
    try loadIfNeeded()
  }

  // ── Detection ──────────────────────────────────────────────────────────────

  /// PCM16LE mono 16 kHz utterance → detected language + top alternatives.
  /// Runs entirely on-device; call from any thread (inference is sync
  /// inside, so dispatch from a background context).
  func detect(pcm16: Data) throws -> DetectionResult {
    try loadIfNeeded()
    guard let backend, let fbank, !labels.isEmpty else {
      throw DetectorError.modelMissing
    }
    let sampleCount = pcm16.count / 2
    guard sampleCount > Self.sampleRate / 4 else { throw DetectorError.badAudio }

    // Int16 PCM → Float32 [-1, 1] ONCE (the VAD buffer is already 16 kHz),
    // then the CI-parity-tested native feature pipeline.
    var samples = [Float](repeating: 0, count: sampleCount)
    pcm16.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
      let int16 = raw.bindMemory(to: Int16.self)
      for i in 0..<sampleCount {
        samples[i] = Float(Int16(littleEndian: int16[i])) / 32768.0
      }
    }
    let features = fbank.compute(fbank.prepare(samples: samples))

    let output: MLFeatureProvider
    do {
      let input = try MLMultiArray(
        shape: [1, NSNumber(value: fbank.config.frames),
                NSNumber(value: fbank.config.nMels)],
        dataType: .float32)
      let pointer = input.dataPointer.bindMemory(
        to: Float32.self, capacity: features.count)
      for i in 0..<features.count { pointer[i] = features[i] }
      output = try backend.prediction(
        from: try MLDictionaryFeatureProvider(dictionary: ["features": input]))
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

/// Phase 2: exactly ONE Apple speech recognizer for the DETECTED language
/// (never a parallel competition). The backend is whatever
/// AppleSpeechLocaleResolver picked: installed SpeechTranscriber first,
/// on-device SFSpeechRecognizer second, network-backed SFSpeechRecognizer
/// third.
enum SingleSpeechRecognizer {
  struct Outcome {
    let text: String
  }

  enum RecognizerError: LocalizedError {
    case unavailable(String)
    case notAuthorized
    case timedOut

    var errorDescription: String? {
      switch self {
      case .unavailable(let detail): return "Recognizer unavailable: \(detail)"
      case .notAuthorized:
        return "Speech recognition permission is not granted — enable it in "
          + "Settings → Live Translator."
      case .timedOut: return "Speech recognition timed out."
      }
    }
  }

  /// PCM16LE mono → Float32 AVAudioPCMBuffer (the recognizers' input).
  static func floatBuffer(fromPCM16 data: Data, sampleRate: Double)
    -> AVAudioPCMBuffer?
  {
    let frames = data.count / 2
    guard frames > 0,
      let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1,
        interleaved: false),
      let buffer = AVAudioPCMBuffer(
        pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))
    else { return nil }
    buffer.frameLength = AVAudioFrameCount(frames)
    guard let channel = buffer.floatChannelData?[0] else { return nil }
    data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
      let int16 = raw.bindMemory(to: Int16.self)
      for i in 0..<frames {
        channel[i] = Float(Int16(littleEndian: int16[i])) / 32768.0
      }
    }
    return buffer
  }

  static func ensureAuthorization() async -> Bool {
    if SFSpeechRecognizer.authorizationStatus() == .authorized { return true }
    return await withCheckedContinuation { continuation in
      SFSpeechRecognizer.requestAuthorization { status in
        continuation.resume(returning: status == .authorized)
      }
    }
  }

  static func transcribe(
    pcm16: Data, sampleRate: Int,
    availability: AppleSpeechLocaleResolver.Availability
  ) async throws -> Outcome {
    guard let buffer = floatBuffer(fromPCM16: pcm16,
                                   sampleRate: Double(sampleRate))
    else { throw RecognizerError.unavailable("could not build audio buffer") }
    switch availability {
    case .transcriberReady(let locale):
      if #available(iOS 26.0, *) {
        let text = try await transcriberOnce(buffer: buffer, locale: locale)
        return Outcome(text: text)
      }
      throw RecognizerError.unavailable("SpeechTranscriber needs iOS 26")
    case .onDevice(let locale):
      return Outcome(text: try await sfTranscribe(
        buffer: buffer, locale: locale, onDeviceOnly: true))
    case .networkBacked(let locale):
      return Outcome(text: try await sfTranscribe(
        buffer: buffer, locale: locale, onDeviceOnly: false))
    case .unsupported:
      throw RecognizerError.unavailable("no Apple recognition path")
    }
  }

  /// iOS 26 SpeechAnalyzer/SpeechTranscriber, ONE locale, one utterance.
  @available(iOS 26.0, *)
  private static func transcriberOnce(buffer: AVAudioPCMBuffer, locale: Locale)
    async throws -> String
  {
    let transcriber = SpeechTranscriber(locale: locale,
                                        preset: .progressiveTranscription)
    let analyzer = SpeechAnalyzer(modules: [transcriber])
    var input = buffer
    if let bestFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
      compatibleWith: [transcriber]),
      bestFormat != buffer.format,
      let converted = convert(buffer: buffer, to: bestFormat)
    {
      input = converted
    }
    async let collected: String = {
      var text = ""
      do {
        for try await result in transcriber.results where result.isFinal {
          text += String(result.text.characters)
        }
      } catch {
        NSLog("[PHASE2] transcriber results error: \(error)")
      }
      return text
    }()
    let (inputSequence, inputBuilder) = AsyncStream<AnalyzerInput>.makeStream()
    try await analyzer.start(inputSequence: inputSequence)
    inputBuilder.yield(AnalyzerInput(buffer: input))
    inputBuilder.finish()
    try await analyzer.finalizeAndFinishThroughEndOfInput()
    return await collected.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func convert(buffer: AVAudioPCMBuffer, to format: AVAudioFormat)
    -> AVAudioPCMBuffer?
  {
    guard let converter = AVAudioConverter(from: buffer.format, to: format)
    else { return nil }
    let ratio = format.sampleRate / buffer.format.sampleRate
    let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
    guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity)
    else { return nil }
    var fed = false
    let status = converter.convert(to: out, error: nil) { _, outStatus in
      if fed {
        outStatus.pointee = .endOfStream
        return nil
      }
      fed = true
      outStatus.pointee = .haveData
      return buffer
    }
    return status == .error ? nil : out
  }

  /// SFSpeechRecognizer, ONE locale, one utterance; on-device or
  /// network-backed per the resolver's verdict.
  private static func sfTranscribe(
    buffer: AVAudioPCMBuffer, locale: Locale, onDeviceOnly: Bool
  ) async throws -> String {
    guard await ensureAuthorization() else {
      throw RecognizerError.notAuthorized
    }
    guard let recognizer = SFSpeechRecognizer(locale: locale),
      recognizer.isAvailable
    else {
      throw RecognizerError.unavailable(
        "SFSpeechRecognizer for \(locale.identifier) is not available "
          + (onDeviceOnly ? "on-device" : "(network path)"))
    }
    let request = SFSpeechAudioBufferRecognitionRequest()
    request.requiresOnDeviceRecognition = onDeviceOnly
    request.shouldReportPartialResults = false
    request.append(buffer)
    request.endAudio()
    let resumeQueue = DispatchQueue(label: "langid.sf.single")
    return try await withCheckedThrowingContinuation { continuation in
      var finished = false
      var task: SFSpeechRecognitionTask?
      task = recognizer.recognitionTask(with: request) { result, error in
        resumeQueue.async {
          if finished { return }
          if let result, result.isFinal {
            finished = true
            continuation.resume(
              returning: result.bestTranscription.formattedString)
          } else if let error {
            finished = true
            continuation.resume(throwing: error)
          }
        }
      }
      // Hard cap: one wedged recognizer must never hang the test.
      resumeQueue.asyncAfter(deadline: .now() + 30) {
        if finished { return }
        finished = true
        task?.cancel()
        continuation.resume(throwing: RecognizerError.timedOut)
      }
    }
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
    case "warmup":
      DispatchQueue.global(qos: .userInitiated).async {
        do {
          try AudioLanguageDetector.shared.warmup()
          DispatchQueue.main.async { result(nil) }
        } catch {
          DispatchQueue.main.async {
            result(FlutterError(
              code: "langid_warmup_failed",
              message: (error as? LocalizedError)?.errorDescription ?? "\(error)",
              details: nil))
          }
        }
      }
    case "detectAndTranscribe":
      // Phase 2: utterance → detector → resolver → ONE recognizer → text.
      guard let data = ((call.arguments as? [String: Any])?["pcm16"]
        as? FlutterStandardTypedData)?.data
      else {
        result(FlutterError(code: "bad_args", message: "pcm16 audio is required", details: nil))
        return
      }
      let sampleRate =
        ((call.arguments as? [String: Any])?["sampleRate"] as? Int) ?? 16000
      DispatchQueue.global(qos: .userInitiated).async {
        let detectStarted = Date()
        let detection: AudioLanguageDetector.DetectionResult
        do {
          detection = try AudioLanguageDetector.shared.detect(pcm16: data)
        } catch {
          DispatchQueue.main.async {
            result(FlutterError(
              code: "langid_failed",
              message: (error as? LocalizedError)?.errorDescription ?? "\(error)",
              details: nil))
          }
          return
        }
        let detectionMs = Int(Date().timeIntervalSince(detectStarted) * 1000)
        Task {
          let availability = await AppleSpeechLocaleResolver.resolve(
            languageCode: detection.language)
          var payload: [String: Any] = [
            "language": detection.language,
            "confidence": detection.confidence,
            "detectionMs": detectionMs,
            "alternatives": detection.alternatives.map {
              ["language": $0.language, "confidence": $0.confidence]
            },
          ]
          let backend: String
          let localeId: String?
          switch availability {
          case .transcriberReady(let locale):
            backend = "transcriber"
            localeId = locale.identifier
          case .onDevice(let locale):
            backend = "onDevice"
            localeId = locale.identifier
          case .networkBacked(let locale):
            backend = "network"
            localeId = locale.identifier
          case .unsupported:
            backend = "unsupported"
            localeId = nil
          }
          payload["backend"] = backend
          payload["locale"] = localeId as Any
          if case .unsupported = availability {
            payload["speechAvailable"] = false
            await MainActor.run { result(payload) }
            return
          }
          payload["speechAvailable"] = true
          let speechStarted = Date()
          do {
            let outcome = try await SingleSpeechRecognizer.transcribe(
              pcm16: data, sampleRate: sampleRate, availability: availability)
            payload["text"] = outcome.text
            payload["speechMs"] =
              Int(Date().timeIntervalSince(speechStarted) * 1000)
          } catch {
            payload["speechError"] =
              (error as? LocalizedError)?.errorDescription ?? "\(error)"
            payload["speechMs"] =
              Int(Date().timeIntervalSince(speechStarted) * 1000)
          }
          await MainActor.run { result(payload) }
        }
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
