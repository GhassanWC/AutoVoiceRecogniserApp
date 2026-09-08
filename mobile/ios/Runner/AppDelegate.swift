import AVFoundation
import Flutter
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
