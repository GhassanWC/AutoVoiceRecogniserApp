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
      let target = (call.arguments as? [String: Any])?["targetLanguage"] as? String ?? "ar"
      CapabilitiesProbe.probe(targetLanguage: target) { payload in
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
//   NativeSpeechBridge: SFSpeechRecognizer on-device, run in PARALLEL for the
//     product's language set → best transcript picked by recognizer
//     confidence × NLLanguageRecognizer score  (Apple offers no audio-level
//     language ID — SpeechTranscriber/SFSpeechRecognizer are locale-fixed —
//     so auto-detection is built from per-locale recognizers, and
//     CapabilitiesProbe reports honestly which locales this device has)
//     ↓ {text, language}
//   TranslationBridge: Apple Translation framework (iOS 18+), on-device
//     ↓ target-language text
//   existing chat bubbles
// ─────────────────────────────────────────────────────────────────────────────

/// The product's auto-detected language set. The user only ever picks the
/// TARGET language; sources are detected per utterance from this set.
enum ProductLanguages {
  static let core = ["en", "ar", "hi", "th", "bn"]

  static func recognitionLocale(for code: String) -> String {
    switch code {
    case "en": return "en-US"
    case "ar": return "ar-SA"
    case "hi": return "hi-IN"
    case "th": return "th-TH"
    case "bn": return "bn-IN"
    default: return code
    }
  }

  static func candidates(target: String) -> [String] {
    core.contains(target) ? core : core + [target]
  }
}

/// Answers, from the actual OS APIs on THIS device (never from a version
/// number alone): can the full Live Translator experience run here?
enum CapabilitiesProbe {
  static func probe(targetLanguage: String, completion: @escaping ([String: Any]) -> Void) {
    let osVersion = "iOS \(UIDevice.current.systemVersion)"

    // Speech: which product languages have ON-DEVICE recognition on this
    // hardware/OS (assets may differ per device — never assume from version).
    var speechByLanguage: [String: Bool] = [:]
    for code in ProductLanguages.candidates(target: targetLanguage) {
      let locale = Locale(identifier: ProductLanguages.recognitionLocale(for: code))
      let recognizer = SFSpeechRecognizer(locale: locale)
      speechByLanguage[code] = recognizer?.supportsOnDeviceRecognition ?? false
    }
    let availableLanguages = speechByLanguage.filter { $0.value }.map { $0.key }.sorted()
    let missingLanguages = speechByLanguage.filter { !$0.value }.map { $0.key }.sorted()
    let speechSupported = !availableLanguages.isEmpty
    // Our detection = parallel per-locale recognition, meaningful from 2
    // languages up. Fewer → the product would silently degrade; report it.
    let languageDetectionSupported = availableLanguages.count >= 2

    guard #available(iOS 18.0, *) else {
      completion([
        "supported": false,
        "updateRequired": true,
        "reason": "Live Translation requires iOS 18 or newer for on-device "
          + "translation. Your current version is \(osVersion).",
        "osVersion": osVersion,
        "speechSupported": speechSupported,
        "languageDetectionSupported": languageDetectionSupported,
        "translationSupported": false,
        "availableLanguages": availableLanguages,
        "missingLanguages": missingLanguages,
        "translationPairs": [String: String](),
      ])
      return
    }

    // Translation: ask the framework per pair (installed / supported /
    // unsupported). "supported" means downloadable on demand — that is NOT
    // an error, just a pending language pack.
    Task {
      let availability = LanguageAvailability()
      let targetLang = Locale.Language(identifier: targetLanguage)
      var pairs: [String: String] = [:]
      var translatableSources = 0
      var sourcesChecked = 0
      for code in availableLanguages where code != targetLanguage {
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

      let supported = speechSupported && languageDetectionSupported && translationSupported
      var reason = "Supported"
      if !speechSupported {
        reason = "This device has no on-device speech recognition for the "
          + "Live Translator languages."
      } else if !languageDetectionSupported {
        reason = "Automatic language detection needs at least two on-device "
          + "speech languages; this device only has: "
          + "\(availableLanguages.joined(separator: ", "))."
      } else if !translationSupported {
        reason = "On-device translation to '\(targetLanguage)' is not "
          + "available for this device's languages."
      } else if !missingLanguages.isEmpty {
        reason = "Supported. Not yet recognizable on this device: "
          + "\(missingLanguages.joined(separator: ", "))."
      }
      completion([
        "supported": supported,
        "updateRequired": false,
        "reason": reason,
        "osVersion": osVersion,
        "speechSupported": speechSupported,
        "languageDetectionSupported": languageDetectionSupported,
        "translationSupported": translationSupported,
        "availableLanguages": availableLanguages,
        "missingLanguages": missingLanguages,
        "translationPairs": pairs,
      ])
    }
  }
}

/// Per-utterance on-device recognition with language auto-detection:
/// the SAME 16 kHz PCM16 utterance (from the unchanged environmental
/// capture + VAD) runs through one on-device SFSpeechRecognizer per
/// available product language in parallel; the winner is chosen by average
/// segment confidence blended with NLLanguageRecognizer's score of the
/// hypothesis text.
final class NativeSpeechBridge {
  private var detectionLanguages: [String] = []

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "prepare":
      prepare(call, result: result)
    case "recognize":
      recognize(call, result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// Requests speech-recognition authorization (first run shows the OS
  /// dialog) and fixes the detection set to the languages this device can
  /// recognize on-device right now.
  private func prepare(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let target = (call.arguments as? [String: Any])?["targetLanguage"] as? String ?? "ar"
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
        var available: [String] = []
        for code in ProductLanguages.candidates(target: target) {
          let locale = Locale(identifier: ProductLanguages.recognitionLocale(for: code))
          if SFSpeechRecognizer(locale: locale)?.supportsOnDeviceRecognition == true {
            available.append(code)
          }
        }
        self?.detectionLanguages = available
        result(["languages": available])
      }
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

    // One on-device recognition task per candidate language, in parallel.
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
      let outcome = group.wait(timeout: .now() + 15)
      tasks.forEach { $0.cancel() }
      lock.lock()
      let collected = hypotheses
      lock.unlock()

      // Blend recognizer confidence with NLLanguageRecognizer's opinion of
      // the hypothesis text — a wrong-language recognizer produces low-
      // confidence gibberish that also scores near zero on its language.
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
        } else if outcome == .timedOut && collected.isEmpty {
          result(FlutterError(
            code: "recognition_timeout",
            message: "on-device recognition produced no result within 15s",
            details: nil))
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
