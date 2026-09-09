import AVFoundation
import Flutter
import NaturalLanguage
import Speech
import SwiftUI
import Translation
import UIKit

/// Native microphone capture for Live Translator.
///
/// Kept inside AppDelegate.swift so no Xcode project-file changes are needed.
/// Uses AVAudioEngine, resamples to 16 kHz mono PCM16 and streams chunks to
/// Dart over an EventChannel. Background listening relies on the standard
/// `audio` UIBackgroundMode (declared in Info.plist) — no tricks, and iOS's
/// microphone indicator stays visible the whole time, as it should.
@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let audioCapture = AudioCaptureManager()
  private let nativeSpeech = NativeSpeechBridge()

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    guard let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "LiveTranslatorAudio")
    else { return }
    let messenger = registrar.messenger()

    let control = FlutterMethodChannel(
      name: "app.livetranslator/audio", binaryMessenger: messenger)
    let events = FlutterEventChannel(
      name: "app.livetranslator/audio_events", binaryMessenger: messenger)
    events.setStreamHandler(audioCapture)

    // Native on-device Live Translation (production path): Apple speech
    // recognition + Apple Translation, all OS frameworks, zero third-party ML.
    let capabilities = FlutterMethodChannel(
      name: "app.livetranslator/capabilities", binaryMessenger: messenger)
    capabilities.setMethodCallHandler { call, result in
      guard call.method == "probe" else {
        result(FlutterMethodNotImplemented)
        return
      }
      let args = call.arguments as? [String: Any]
      let target = args?["targetLanguage"] as? String ?? "ar"
      let sources = (args?["sourceLanguages"] as? [String]) ?? ["en"]
      CapabilitiesProbe.probe(targetLanguage: target, sourceLanguages: sources) { payload in
        DispatchQueue.main.async { result(payload) }
      }
    }

    let nativeStt = FlutterMethodChannel(
      name: "app.livetranslator/nativestt", binaryMessenger: messenger)
    nativeStt.setMethodCallHandler { [weak self] call, result in
      self?.nativeSpeech.handle(call, result: result)
    }

    let translate = FlutterMethodChannel(
      name: "app.livetranslator/translate", binaryMessenger: messenger)
    translate.setMethodCallHandler { call, result in
      TranslationBridge.handle(call, result: result)
    }

    // Thermal/battery/memory snapshots for on-device AI instrumentation.
    let stats = FlutterMethodChannel(
      name: "app.livetranslator/devicestats", binaryMessenger: messenger)
    stats.setMethodCallHandler { call, result in
      guard call.method == "getStats" else {
        result(FlutterMethodNotImplemented)
        return
      }
      let thermal: String
      switch ProcessInfo.processInfo.thermalState {
      case .nominal: thermal = "nominal"
      case .fair: thermal = "fair"
      case .serious: thermal = "serious"
      case .critical: thermal = "critical"
      @unknown default: thermal = "unknown"
      }
      UIDevice.current.isBatteryMonitoringEnabled = true
      let battery = UIDevice.current.batteryLevel
      var memoryMb = -1
      var info = task_vm_info_data_t()
      var count = mach_msg_type_number_t(
        MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
      let kerr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
          task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
      }
      if kerr == KERN_SUCCESS {
        memoryMb = Int(info.phys_footprint / (1024 * 1024))
      }
      result([
        "thermalState": thermal,
        "batteryPercent": battery < 0 ? -1 : Int(battery * 100),
        "memoryFootprintMb": memoryMb,
      ])
    }

    control.setMethodCallHandler { [weak self] call, result in
      guard let self else { return }
      switch call.method {
      case "start":
        let args = call.arguments as? [String: Any]
        let sampleRate = args?["sampleRate"] as? Int ?? 16000
        do {
          try self.audioCapture.start(sampleRate: Double(sampleRate))
          result(nil)
        } catch {
          result(
            FlutterError(
              code: "audio_start_failed", message: error.localizedDescription, details: nil))
        }
      case "stop":
        self.audioCapture.stop()
        result(nil)
      case "isRunning":
        result(self.audioCapture.isRunning)
      case "micStatus":
        // The OS-level truth (TCC database), read directly — never a plugin's
        // opinion of it. "granted" here MUST allow Start Listening.
        result(AppDelegate.micPermissionString())
      case "micRequest":
        // iOS shows the dialog only while the state is undetermined; a settled
        // state resolves immediately. This is the ONLY permission-request path
        // on iOS — never request through a second library on top of it.
        AVAudioSession.sharedInstance().requestRecordPermission { granted in
          DispatchQueue.main.async { result(granted) }
        }
      case "micDiagnostics":
        result(self.micDiagnostics())
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  /// AVAudioSession.recordPermission mirrors AVAudioApplication on iOS 17+;
  /// it stays the one source of truth here so status and request always come
  /// from the same API family.
  fileprivate static func micPermissionString() -> String {
    switch AVAudioSession.sharedInstance().recordPermission {
    case .granted: return "granted"
    case .denied: return "denied"
    case .undetermined: return "undetermined"
    @unknown default: return "unknown"
    }
  }

  private func micDiagnostics() -> [String: Any] {
    let session = AVAudioSession.sharedInstance()
    let usage =
      Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") as? String
    return [
      "nativeRecordPermission": AppDelegate.micPermissionString(),
      "usageDescriptionPresent": (usage?.isEmpty == false),
      "audioSessionCategory": session.category.rawValue,
      "audioSessionMode": session.mode.rawValue,
      // AVAudioSession has no public "is active" getter; our capture engine
      // owning an active session is the state that matters to this app.
      "audioSessionActive": audioCapture.isRunning,
      "inputAvailable": session.isInputAvailable,
    ]
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Native on-device Live Translation (production path)
//
//   existing environmental microphone + Dart VAD (unchanged)
//     ↓ per-utterance PCM16 @ 16 kHz
//   NativeSpeechBridge: on-device recognition run in PARALLEL for the
//     product's language set (SpeechAnalyzer/SpeechTranscriber on iOS 26,
//     SFSpeechRecognizer before that) → best transcript by NLLanguage score
//     (Apple offers no audio-level language ID — its transcribers are
//     locale-fixed — so auto-detection is built from per-locale recognizers;
//     CapabilitiesProbe keeps SUPPORTED and INSTALLED separate on iOS 26,
//     and AssetInventory downloads the missing supported models)
//     ↓ {text, language}
//   TranslationBridge: Apple Translation framework (iOS 18+), on-device
//     ↓ target-language text
//   existing chat bubbles
// ─────────────────────────────────────────────────────────────────────────────

/// Locale hints for building a recognizer from a bare ISO 639-1 code (used
/// pre-iOS 26 and as a fallback; on iOS 26 the locale is resolved from
/// SpeechTranscriber.supportedLocales itself).
enum ProductLanguages {
  static func recognitionLocale(for code: String) -> String {
    switch code {
    case "en": return "en-US"
    case "ar": return "ar-SA"
    case "hi": return "hi-IN"
    case "th": return "th-TH"
    case "bn": return "bn-IN"
    case "es": return "es-ES"
    case "fr": return "fr-FR"
    case "de": return "de-DE"
    case "zh": return "zh-CN"
    case "ja": return "ja-JP"
    case "ko": return "ko-KR"
    case "pt": return "pt-BR"
    case "ru": return "ru-RU"
    case "it": return "it-IT"
    case "id": return "id-ID"
    case "tr": return "tr-TR"
    case "nl": return "nl-NL"
    case "vi": return "vi-VN"
    case "ur": return "ur-PK"
    case "ta": return "ta-IN"
    default: return code
    }
  }
}

/// The device's raw speech inventory, with the four concepts the product
/// model keeps strictly apart: SUPPORTED (Apple offers it here), INSTALLED
/// (asset already on disk), RESERVED (slot held for this app), plus the
/// reservation capacity. User SELECTION lives in Flutter, never here.
struct SpeechInventory {
  var supportedCodes: Set<String> = []
  var installedCodes: Set<String> = []
  var reservedLocaleIDs: [String] = []
  var maximumReservedLocales: Int = 0
  var diagnostics: [String] = []
  var modern = false

  /// "ready" | "downloadRequired" | "unsupported" for one language code.
  func status(for code: String) -> String {
    if installedCodes.contains(code) { return "ready" }
    if supportedCodes.contains(code) {
      // Pre-iOS 26 there is no app-triggered download API, so a supported-
      // but-not-installed model cannot be fetched — report it honestly.
      return modern ? "downloadRequired" : "unsupported"
    }
    return "unsupported"
  }
}

enum CapabilitiesProbe {
  static func speechInventory() async -> SpeechInventory {
    if #available(iOS 26.0, *) {
      return await modernInventory()
    }
    return legacyInventory()
  }

  /// iOS 26+: SpeechTranscriber.supportedLocales is the CAPABILITY list;
  /// installedLocales only says which models are downloaded. The old
  /// SFSpeechRecognizer.supportsOnDeviceRecognition is NOT a capability
  /// test here — it only reflects already-installed dictation assets.
  @available(iOS 26.0, *)
  static func modernInventory() async -> SpeechInventory {
    var inventory = SpeechInventory()
    inventory.modern = true
    let supportedLocales = await SpeechTranscriber.supportedLocales
    let installedLocales = await SpeechTranscriber.installedLocales
    let reservedLocales = await AssetInventory.reservedLocales
    inventory.supportedCodes =
      Set(supportedLocales.compactMap { $0.language.languageCode?.identifier })
    inventory.installedCodes =
      Set(installedLocales.compactMap { $0.language.languageCode?.identifier })
    inventory.reservedLocaleIDs = reservedLocales.map(\.identifier).sorted()
    inventory.maximumReservedLocales = AssetInventory.maximumReservedLocales
    inventory.diagnostics = [
      "speechStack=SpeechAnalyzer (iOS 26)",
      "supportedLocales=\(supportedLocales.map(\.identifier).sorted().joined(separator: " "))",
      "installedLocales=\(installedLocales.map(\.identifier).sorted().joined(separator: " "))",
      "reservedLocales=\(inventory.reservedLocaleIDs.joined(separator: " "))",
      "maximumReservedLocales=\(inventory.maximumReservedLocales)",
    ]
    return inventory
  }

  /// Pre-iOS 26: SFSpeechRecognizer has no supported/installed split and no
  /// download API — a language is usable only if on-device recognition for
  /// it is available right now.
  static func legacyInventory() -> SpeechInventory {
    var inventory = SpeechInventory()
    var codes: Set<String> = []
    for locale in SFSpeechRecognizer.supportedLocales() {
      guard let code = locale.language.languageCode?.identifier,
        !codes.contains(code),
        SFSpeechRecognizer(locale: locale)?.supportsOnDeviceRecognition == true
      else { continue }
      codes.insert(code)
    }
    inventory.supportedCodes = codes
    inventory.installedCodes = codes
    inventory.diagnostics = [
      "speechStack=SFSpeechRecognizer (pre-iOS 26; supported==installed, no download API)"
    ]
    return inventory
  }

  /// Resolves a language code to the concrete recognition Locale (iOS 26:
  /// straight from supportedLocales; otherwise the static hint table).
  @available(iOS 26.0, *)
  static func resolveModernLocale(for code: String) async -> Locale? {
    let hinted = Locale(identifier: ProductLanguages.recognitionLocale(for: code))
    if let match = await SpeechTranscriber.supportedLocale(equivalentTo: hinted) {
      return match
    }
    return await SpeechTranscriber.supportedLocales
      .first { $0.language.languageCode?.identifier == code }
  }

  /// The full capability report. `supported` describes whether the DEVICE
  /// supports the native architecture — it is NEVER false merely because a
  /// selected language pack is not downloaded yet, and ONE usable language
  /// is enough (single-language sessions are valid).
  static func probe(
    targetLanguage: String, sourceLanguages: [String],
    completion: @escaping ([String: Any]) -> Void
  ) {
    Task {
      let osVersion = "iOS \(UIDevice.current.systemVersion)"
      let inventory = await speechInventory()

      // Per-language status for the user's SELECTION (+ the target, so the
      // UI can show ar→ar readiness too).
      var languageStatus: [String: String] = [:]
      for code in Set(sourceLanguages + [targetLanguage]) {
        languageStatus[code] = inventory.status(for: code)
      }
      let selectedReady = sourceLanguages.filter { languageStatus[$0] == "ready" }.sorted()
      let selectedPending =
        sourceLanguages.filter { languageStatus[$0] == "downloadRequired" }.sorted()
      let selectedUnsupported =
        sourceLanguages.filter { languageStatus[$0] == "unsupported" }.sorted()
      let usableSelected = (selectedReady + selectedPending).sorted()

      // Device-level support: the speech stack offers at least one language.
      let speechSupported = !inventory.supportedCodes.isEmpty
      // Detection runs among the user's selected languages; one selected
      // language needs no competition at all — always fine.
      let languageDetectionSupported = speechSupported

      var base: [String: Any] = [
        "osVersion": osVersion,
        "speechSupported": speechSupported,
        "languageDetectionSupported": languageDetectionSupported,
        "supportedLanguages": inventory.supportedCodes.sorted(),
        "installedLanguages": inventory.installedCodes.sorted(),
        "reservedLocales": inventory.reservedLocaleIDs,
        "maximumReservedLocales": inventory.maximumReservedLocales,
        "availableLanguages": usableSelected,
        "readyLanguages": selectedReady,
        "pendingDownloads": selectedPending,
        "missingLanguages": selectedUnsupported,
        "languageStatus": languageStatus,
        "speechDiagnostics": inventory.diagnostics,
      ]

      guard #available(iOS 18.0, *) else {
        base["supported"] = false
        base["updateRequired"] = true
        base["reason"] = "Live Translation requires iOS 18 or newer for "
          + "on-device translation. Your current version is \(osVersion)."
        base["translationSupported"] = false
        base["translationPairs"] = [String: String]()
        completion(base)
        return
      }

      // Translation: ask the framework per selected pair. "downloadable"
      // is a pending pack, NOT an error.
      let availability = LanguageAvailability()
      let targetLang = Locale.Language(identifier: targetLanguage)
      var pairs: [String: String] = [:]
      var translatableSources = 0
      var sourcesChecked = 0
      for code in usableSelected where code != targetLanguage {
        sourcesChecked += 1
        let status = await availability.status(
          from: Locale.Language(identifier: code), to: targetLang)
        let label: String
        switch status {
        case .installed: label = "installed"
        case .supported: label = "downloadable"
        case .unsupported: label = "unsupported"
        @unknown default: label = "unknown"
        }
        pairs[code] = label
        if label == "installed" || label == "downloadable" { translatableSources += 1 }
      }
      // Same-language passthrough (ar→ar) needs no translation model.
      let translationSupported = sourcesChecked == 0 || translatableSources > 0

      let supported = speechSupported && translationSupported
      var reason = "Supported"
      if !speechSupported {
        reason = "This device has no on-device speech recognition."
      } else if !translationSupported {
        reason = "On-device translation to '\(targetLanguage)' is not "
          + "available for the selected languages."
      } else if !selectedPending.isEmpty {
        reason = "Supported. Language packs to download: "
          + "\(selectedPending.joined(separator: ", "))."
      } else if !selectedUnsupported.isEmpty {
        reason = "Supported. Not available on this device: "
          + "\(selectedUnsupported.joined(separator: ", "))."
      }
      base["supported"] = supported
      base["updateRequired"] = false
      base["reason"] = reason
      base["translationSupported"] = translationSupported
      base["translationPairs"] = pairs
      completion(base)
    }
  }
}

/// Per-utterance on-device recognition with language auto-detection AMONG
/// THE USER'S SELECTED "Listen for" LANGUAGES ONLY: the SAME 16 kHz PCM16
/// utterance (from the unchanged environmental capture + VAD) runs through
/// one on-device recognizer per selected language in parallel —
/// SpeechAnalyzer/SpeechTranscriber on iOS 26, SFSpeechRecognizer before
/// that — and the winner is chosen by NLLanguageRecognizer score (blended
/// with recognizer confidence where the API provides one). A single
/// selected language skips the competition entirely.
///
/// Language model downloads go through Apple's own
/// AssetInventory.assetInstallationRequest(supporting:).downloadAndInstall()
/// ("installAssets" below, with polled progress).
final class NativeSpeechBridge {
  private var detectionLanguages: [String] = []

  // installAssets progress, polled from Dart via "installProgress".
  private var installRunning = false
  private var installLanguage: String?
  private var installFraction: Double = 0
  private var installCompleted = 0
  private var installTotal = 0
  private var installError: String?

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "prepare":
      prepare(call, result: result)
    case "installAssets":
      installAssets(call, result: result)
    case "installProgress":
      result([
        "running": installRunning,
        "language": installLanguage as Any,
        "fraction": installFraction,
        "completed": installCompleted,
        "total": installTotal,
        "error": installError as Any,
      ])
    case "recognize":
      recognize(call, result: result)
    case "releaseLanguage":
      releaseLanguage(call, result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// Pins the detection set to the USER-SELECTED languages whose speech
  /// models are installed right now (downloads are installAssets' job, not
  /// prepare's). Recognizers only ever run for these — never for every
  /// language installed on the phone. Pre-iOS 26 this also requests the
  /// Speech authorization; the iOS 26 SpeechAnalyzer stack is fully
  /// on-device and needs no authorization.
  private func prepare(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let selected = ((call.arguments as? [String: Any])?["languages"] as? [String]) ?? []
    guard !selected.isEmpty else {
      result(FlutterError(
        code: "no_languages", message: "select at least one listening language", details: nil))
      return
    }
    if #available(iOS 26.0, *) {
      Task { @MainActor in
        let inventory = await CapabilitiesProbe.modernInventory()
        let usable = selected.filter { inventory.installedCodes.contains($0) }
        let notReady = selected.filter { !inventory.installedCodes.contains($0) }
        self.detectionLanguages = usable
        result(["languages": usable, "notReady": notReady])
      }
      return
    }
    SFSpeechRecognizer.requestAuthorization { [weak self] status in
      DispatchQueue.main.async {
        guard status == .authorized else {
          result(FlutterError(
            code: "speech_permission_denied",
            message: "Speech recognition permission is \(status.rawValue) — "
              + "enable it in Settings → Live Translator.",
            details: nil))
          return
        }
        let inventory = CapabilitiesProbe.legacyInventory()
        let usable = selected.filter { inventory.installedCodes.contains($0) }
        let notReady = selected.filter { !inventory.installedCodes.contains($0) }
        self?.detectionLanguages = usable
        result(["languages": usable, "notReady": notReady])
      }
    }
  }

  /// Downloads + installs the given supported-but-not-installed languages
  /// through Apple's AssetInventory (iOS 26+). Sequential, one language at a
  /// time, so the polled progress can name what is downloading. Only ever
  /// touches the languages Dart asked for — the user's selection.
  private func installAssets(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard #available(iOS 26.0, *) else {
      // Pre-iOS 26 there is no app-triggered speech-asset download API.
      result(nil)
      return
    }
    guard !installRunning else {
      result(FlutterError(
        code: "busy", message: "an asset installation is already running", details: nil))
      return
    }
    let requestedLanguages =
      ((call.arguments as? [String: Any])?["languages"] as? [String]) ?? []
    installRunning = true
    installError = nil
    installFraction = 0
    installCompleted = 0
    Task { @MainActor in
      let inventory = await CapabilitiesProbe.modernInventory()
      let pending = requestedLanguages.filter {
        inventory.supportedCodes.contains($0) && !inventory.installedCodes.contains($0)
      }
      self.installTotal = pending.count
      var failures: [String] = []
      for code in pending {
        self.installLanguage = code
        self.installFraction = 0
        do {
          let locale = await CapabilitiesProbe.resolveModernLocale(for: code)
            ?? Locale(identifier: ProductLanguages.recognitionLocale(for: code))
          let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
          if let request = try await AssetInventory.assetInstallationRequest(
            supporting: [transcriber])
          {
            let progress = request.progress
            let poll = Task { @MainActor in
              while !Task.isCancelled {
                self.installFraction = progress.fractionCompleted
                try? await Task.sleep(nanoseconds: 300_000_000)
              }
            }
            defer { poll.cancel() }
            try await request.downloadAndInstall()
          }
          self.installCompleted += 1
          self.installFraction = 1
        } catch {
          failures.append("\(code): \(error)")
        }
      }
      self.installRunning = false
      self.installLanguage = nil
      if failures.isEmpty {
        result(nil)
      } else {
        self.installError = failures.joined(separator: "; ")
        result(FlutterError(
          code: "asset_install_failed",
          message: failures.joined(separator: "; "),
          details: nil))
      }
    }
  }

  /// Frees this app's asset-slot reservation for one language (Settings →
  /// Languages → Remove). Only ever releases a reservation matching the
  /// requested language — never another feature's, never silently.
  private func releaseLanguage(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard #available(iOS 26.0, *) else {
      result(nil)
      return
    }
    guard let code = (call.arguments as? [String: Any])?["language"] as? String else {
      result(FlutterError(code: "bad_args", message: "language is required", details: nil))
      return
    }
    Task { @MainActor in
      let reserved = await AssetInventory.reservedLocales
      for locale in reserved where locale.language.languageCode?.identifier == code {
        await AssetInventory.release(reservedLocale: locale)
      }
      result(nil)
    }
  }

  private func recognize(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
      let pcm = (args["pcm16"] as? FlutterStandardTypedData)?.data, !pcm.isEmpty
    else {
      result(FlutterError(code: "bad_args", message: "pcm16 audio is required", details: nil))
      return
    }
    let sampleRate = args["sampleRate"] as? Int ?? 16000
    let languages = detectionLanguages
    guard !languages.isEmpty else {
      result(FlutterError(
        code: "not_prepared", message: "call prepare before recognize", details: nil))
      return
    }
    guard let buffer = Self.floatBuffer(fromPCM16: pcm, sampleRate: Double(sampleRate)) else {
      result(FlutterError(code: "bad_audio", message: "could not build audio buffer", details: nil))
      return
    }
    if #available(iOS 26.0, *) {
      Task {
        let winner = await Self.recognizeModern(buffer: buffer, languages: languages)
        await MainActor.run {
          result(["text": winner?.text ?? "", "language": winner?.language ?? "und"])
        }
      }
    } else {
      recognizeLegacy(buffer: buffer, languages: languages, result: result)
    }
  }

  // ── iOS 26 path: SpeechAnalyzer + SpeechTranscriber ────────────────────────

  @available(iOS 26.0, *)
  private static func recognizeModern(buffer: AVAudioPCMBuffer, languages: [String])
    async -> (text: String, language: String)?
  {
    // ONE selected language: the fastest possible path — a single
    // transcriber, no competition, no scoring.
    if languages.count == 1, let only = languages.first {
      do {
        let text = try await transcribeOnce(buffer: buffer, languageCode: only)
        return text.isEmpty ? nil : (text, only)
      } catch {
        NSLog("[NATIVE STT] \(only) transcriber failed: \(error)")
        return nil
      }
    }
    var hypotheses: [(language: String, text: String)] = []
    await withTaskGroup(of: (String, String)?.self) { group in
      for code in languages {
        group.addTask {
          do {
            let text = try await transcribeOnce(buffer: buffer, languageCode: code)
            return (code, text)
          } catch {
            NSLog("[NATIVE STT] \(code) transcriber failed: \(error)")
            return nil
          }
        }
      }
      for await outcome in group {
        if let outcome, !outcome.1.isEmpty { hypotheses.append(outcome) }
      }
    }
    return pickBest(hypotheses: hypotheses)
  }

  @available(iOS 26.0, *)
  private static func transcribeOnce(buffer: AVAudioPCMBuffer, languageCode: String)
    async throws -> String
  {
    let locale = await CapabilitiesProbe.resolveModernLocale(for: languageCode)
      ?? Locale(identifier: ProductLanguages.recognitionLocale(for: languageCode))
    let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
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
        NSLog("[NATIVE STT] results stream error: \(error)")
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
    guard let converter = AVAudioConverter(from: buffer.format, to: format) else { return nil }
    let ratio = format.sampleRate / buffer.format.sampleRate
    let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
    guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
      return nil
    }
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

  /// NLLanguageRecognizer arbitrates between parallel hypotheses: a wrong-
  /// language transcriber produces text that scores near zero on its own
  /// language. (Length is a mild tiebreaker — truncated wrong-language reads
  /// tend to be short.)
  private static func pickBest(hypotheses: [(language: String, text: String)])
    -> (text: String, language: String)?
  {
    var best: (text: String, language: String, score: Double)?
    for hypothesis in hypotheses {
      let text = hypothesis.text
      if text.isEmpty { continue }
      let nl = NLLanguageRecognizer()
      nl.processString(text)
      let nlProb = nl.languageHypotheses(withMaximum: 8)[
        NLLanguage(rawValue: hypothesis.language)] ?? 0
      let lengthBonus = min(Double(text.count) / 40.0, 1.0)
      let score = nlProb * 0.8 + lengthBonus * 0.2
      if best == nil || score > best!.score {
        best = (text, hypothesis.language, score)
      }
    }
    guard let best else { return nil }
    return (best.text, best.language)
  }

  // ── pre-iOS 26 path: SFSpeechRecognizer ────────────────────────────────────

  private func recognizeLegacy(
    buffer: AVAudioPCMBuffer, languages: [String], result: @escaping FlutterResult
  ) {
    let group = DispatchGroup()
    let lock = NSLock()
    var hypotheses: [(language: String, text: String, confidence: Double)] = []
    var tasks: [SFSpeechRecognitionTask] = []

    for code in languages {
      let locale = Locale(identifier: ProductLanguages.recognitionLocale(for: code))
      guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable
      else { continue }
      let request = SFSpeechAudioBufferRecognitionRequest()
      request.requiresOnDeviceRecognition = true
      request.shouldReportPartialResults = false
      request.append(buffer)
      request.endAudio()
      group.enter()
      var finished = false
      let task = recognizer.recognitionTask(with: request) { recognition, error in
        if finished { return }
        if let recognition, recognition.isFinal {
          finished = true
          let text = recognition.bestTranscription.formattedString
          let segments = recognition.bestTranscription.segments
          let confidence = segments.isEmpty
            ? 0.0
            : segments.reduce(0.0) { $0 + Double($1.confidence) } / Double(segments.count)
          lock.lock()
          hypotheses.append((code, text, confidence))
          lock.unlock()
          group.leave()
        } else if error != nil {
          finished = true
          group.leave()
        }
      }
      tasks.append(task)
    }

    DispatchQueue.global(qos: .userInitiated).async {
      // Hard cap so one wedged recognizer can never hang the session.
      _ = group.wait(timeout: .now() + 15)
      tasks.forEach { $0.cancel() }
      lock.lock()
      let collected = hypotheses
      lock.unlock()

      var best: (language: String, text: String, score: Double)? = nil
      for hypothesis in collected {
        let text = hypothesis.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { continue }
        let nl = NLLanguageRecognizer()
        nl.processString(text)
        let nlProb = nl.languageHypotheses(withMaximum: 8)[
          NLLanguage(rawValue: hypothesis.language)] ?? 0
        let score = hypothesis.confidence * 0.6 + nlProb * 0.4
        if best == nil || score > best!.score {
          best = (hypothesis.language, text, score)
        }
      }
      DispatchQueue.main.async {
        if let best {
          result(["text": best.text, "language": best.language])
        } else {
          // Silence / non-speech: an empty utterance, not an error.
          result(["text": "", "language": "und"])
        }
      }
    }
  }

  private static func floatBuffer(fromPCM16 data: Data, sampleRate: Double)
    -> AVAudioPCMBuffer?
  {
    let frames = data.count / 2
    guard frames > 0,
      let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1,
        interleaved: false),
      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))
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
}

/// Apple Translation framework behind a MethodChannel.
///
/// The framework only hands out TranslationSession through SwiftUI's
/// .translationTask, so a 1×1 invisible SwiftUI host lives in the key
/// window and executes queued jobs (translate / prepare-download). Language
/// packs download through the OS's own prepareTranslation flow — never a
/// custom downloader.
enum TranslationBridge {
  static func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard #available(iOS 18.0, *) else {
      result(FlutterError(
        code: "translation_requires_ios18",
        message: "On-device translation requires iOS 18 or newer.",
        details: nil))
      return
    }
    let args = call.arguments as? [String: Any]
    let source = args?["from"] as? String
    guard let target = args?["to"] as? String else {
      result(FlutterError(code: "bad_args", message: "'to' language is required", details: nil))
      return
    }
    switch call.method {
    case "translate":
      guard let text = args?["text"] as? String, !text.isEmpty else {
        result(FlutterError(code: "bad_args", message: "text is required", details: nil))
        return
      }
      TranslationHost.shared.submit(.init(kind: .translate(text), source: source, target: target)) {
        outcome in
        switch outcome {
        case .success(let translated): result(["text": translated])
        case .failure(let error):
          result(FlutterError(code: "translate_failed", message: "\(error)", details: nil))
        }
      }
    case "prepare":
      TranslationHost.shared.submit(.init(kind: .prepare, source: source, target: target)) {
        outcome in
        switch outcome {
        case .success: result(nil)
        case .failure(let error):
          result(FlutterError(code: "prepare_failed", message: "\(error)", details: nil))
        }
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}

@available(iOS 18.0, *)
final class TranslationHost {
  static let shared = TranslationHost()

  struct Job {
    enum Kind {
      case translate(String)
      case prepare
    }

    let kind: Kind
    let source: String?
    let target: String
    var completion: ((Result<String, Error>) -> Void)?

    init(kind: Kind, source: String?, target: String) {
      self.kind = kind
      self.source = source
      self.target = target
    }
  }

  let model = TranslationHostModel()
  private var hosting: UIHostingController<TranslationHostView>?

  func submit(_ job: Job, completion: @escaping (Result<String, Error>) -> Void) {
    DispatchQueue.main.async {
      self.attachIfNeeded()
      var queued = job
      queued.completion = completion
      self.model.enqueue(queued)
    }
  }

  private func attachIfNeeded() {
    guard hosting == nil else { return }
    guard
      let window = UIApplication.shared.connectedScenes
        .compactMap({ $0 as? UIWindowScene })
        .flatMap({ $0.windows })
        .first(where: { $0.isKeyWindow }) ?? UIApplication.shared.connectedScenes
        .compactMap({ ($0 as? UIWindowScene)?.windows.first }).first
    else { return }
    let controller = UIHostingController(rootView: TranslationHostView(model: model))
    controller.view.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
    controller.view.alpha = 0.01
    controller.view.isUserInteractionEnabled = false
    controller.view.backgroundColor = .clear
    window.addSubview(controller.view)
    hosting = controller
  }
}

/// Serial job queue: each (source→target) batch gets one translationTask
/// session; re-triggering uses Configuration.invalidate() as Apple intends.
@available(iOS 18.0, *)
final class TranslationHostModel: ObservableObject {
  @Published var configuration: TranslationSession.Configuration?

  private var queue: [TranslationHost.Job] = []
  private var draining = false

  func enqueue(_ job: TranslationHost.Job) {
    queue.append(job)
    kick()
  }

  private func kick() {
    guard !draining, let next = queue.first else { return }
    draining = true
    let source = next.source.map { Locale.Language(identifier: $0) }
    let target = Locale.Language(identifier: next.target)
    if configuration?.source == source && configuration?.target == target {
      configuration?.invalidate()  // same pair: bump the session
    } else {
      configuration = TranslationSession.Configuration(source: source, target: target)
    }
  }

  /// Runs inside .translationTask with a live session for the current pair.
  @MainActor
  func run(session: TranslationSession) async {
    while let job = nextJob(matching: session) {
      do {
        switch job.kind {
        case .prepare:
          try await session.prepareTranslation()
          job.completion?(.success(""))
        case .translate(let text):
          let response = try await session.translate(text)
          job.completion?(.success(response.targetText))
        }
      } catch {
        job.completion?(.failure(error))
      }
    }
    draining = false
    kick()  // jobs for a different pair may be waiting
  }

  @MainActor
  private func nextJob(matching session: TranslationSession) -> TranslationHost.Job? {
    guard let job = queue.first else { return nil }
    let source = job.source.map { Locale.Language(identifier: $0) }
    let target = Locale.Language(identifier: job.target)
    guard configuration?.source == source, configuration?.target == target else { return nil }
    return queue.removeFirst()
  }
}

@available(iOS 18.0, *)
struct TranslationHostView: View {
  @ObservedObject var model: TranslationHostModel

  var body: some View {
    Color.clear
      .translationTask(model.configuration) { session in
        await model.run(session: session)
      }
  }
}

final class AudioCaptureManager: NSObject, FlutterStreamHandler {
  private let engine = AVAudioEngine()
  private var converter: AVAudioConverter?
  private var targetFormat: AVAudioFormat?
  private var eventSink: FlutterEventSink?
  private(set) var isRunning = false

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink)
    -> FlutterError?
  {
    eventSink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }

  func start(sampleRate: Double) throws {
    guard !isRunning else { return }

    let session = AVAudioSession.sharedInstance()
    // Environmental capture, not a phone call:
    //  - .measurement disables Apple's voice-call DSP (echo cancellation,
    //    noise suppression, near-field beamforming) that would strip TV audio
    //    and speakers a few meters away out of the signal;
    //  - .allowBluetoothA2DP (NOT .allowBluetooth/HFP) so headphones only ever
    //    receive playback — the narrow-band Bluetooth headset mic must never
    //    replace the phone's environmental microphone;
    //  - .playAndRecord + .defaultToSpeaker so TTS can speak translations
    //    while listening (Earphone Mode).
    try session.setCategory(
      .playAndRecord, mode: .measurement, options: [.allowBluetoothA2DP, .defaultToSpeaker])

    // Prefer the built-in mic with an omnidirectional pickup pattern so the
    // room is heard evenly, instead of a beam pointed at the phone's owner.
    if let builtInMic = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
      if let omni = builtInMic.dataSources?.first(where: {
        $0.supportedPolarPatterns?.contains(.omnidirectional) == true
      }) {
        try? omni.setPreferredPolarPattern(.omnidirectional)
        try? builtInMic.setPreferredDataSource(omni)
      }
      try? session.setPreferredInput(builtInMic)
    }

    try session.setActive(true)

    // Distant speech is quiet and there is no AGC in .measurement mode —
    // open the analog input gain all the way where the hardware allows it.
    if session.isInputGainSettable {
      try? session.setInputGain(1.0)
    }

    let input = engine.inputNode
    // Belt and braces: voice-processing I/O must stay off. It is tuned for
    // telephone conversations and removes exactly the distant/background
    // speech this app exists to hear.
    if input.isVoiceProcessingEnabled {
      try? input.setVoiceProcessingEnabled(false)
    }
    let inputFormat = input.outputFormat(forBus: 0)
    guard inputFormat.sampleRate > 0,
      let outFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true),
      let converter = AVAudioConverter(from: inputFormat, to: outFormat)
    else {
      throw NSError(
        domain: "AudioCapture", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Microphone format not available"])
    }
    self.converter = converter
    self.targetFormat = outFormat

    input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
      self?.handle(buffer: buffer)
    }
    engine.prepare()
    try engine.start()
    isRunning = true

    // A phone call or Siri taking the microphone must flip the UI to
    // "Not Listening" — the app never pretends to listen when it can't.
    NotificationCenter.default.addObserver(
      self, selector: #selector(handleInterruption(_:)),
      name: AVAudioSession.interruptionNotification, object: session)
  }

  @objc private func handleInterruption(_ notification: Notification) {
    guard isRunning,
      let info = notification.userInfo,
      let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
      let type = AVAudioSession.InterruptionType(rawValue: typeValue),
      type == .began
    else { return }
    stop(notify: "mic_lost")
  }

  private func handle(buffer: AVAudioPCMBuffer) {
    guard let converter, let targetFormat, let sink = eventSink else { return }
    let ratio = targetFormat.sampleRate / buffer.format.sampleRate
    let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
    guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
      return
    }
    var fed = false
    let status = converter.convert(to: out, error: nil) { _, outStatus in
      if fed {
        outStatus.pointee = .noDataNow
        return nil
      }
      fed = true
      outStatus.pointee = .haveData
      return buffer
    }
    guard status != .error, out.frameLength > 0, let channel = out.int16ChannelData else { return }
    let data = Data(bytes: channel[0], count: Int(out.frameLength) * 2)
    DispatchQueue.main.async {
      sink(FlutterStandardTypedData(bytes: data))
    }
  }

  func stop(notify reason: String? = nil) {
    guard isRunning else { return }
    isRunning = false
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()
    converter = nil
    targetFormat = nil
    NotificationCenter.default.removeObserver(
      self, name: AVAudioSession.interruptionNotification, object: nil)
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    if let reason, let sink = eventSink {
      DispatchQueue.main.async {
        sink(["event": "stopped", "reason": reason])
      }
    }
  }
}
