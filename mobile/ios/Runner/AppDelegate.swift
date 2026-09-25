import AVFoundation
import Flutter
import UIKit

/// Native audio for Sayvo: environmental microphone capture
/// (16 kHz mono PCM16 chunks streamed to Dart) and streamed PCM playback
/// (Gemini's 24 kHz translated speech).
///
/// Speech recognition, language detection and translation all happen in the
/// cloud (Gemini Live Translate) — there is deliberately NO on-device ML here.
/// Background listening relies on the standard `audio` UIBackgroundMode and
/// iOS's microphone indicator stays visible the whole time, as it should.
@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let audioCapture = AudioCaptureManager()
  private let audioPlayback = AudioPlaybackManager()
  private let speech = SpeechSynthesizer()

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

    let playbackEvents = FlutterEventChannel(
      name: "app.livetranslator/playback_events", binaryMessenger: messenger)
    playbackEvents.setStreamHandler(audioPlayback)

    // Device text-to-speech: reads a finalized translation aloud on demand.
    let ttsEvents = FlutterEventChannel(
      name: "app.livetranslator/tts_events", binaryMessenger: messenger)
    ttsEvents.setStreamHandler(speech)

    // TEMPORARY (store-products investigation): lets the billing diagnostic
    // report the bundle id the app is ACTUALLY running under, rather than the
    // one we believe is configured. A mismatch is invisible any other way.
    let appInfo = FlutterMethodChannel(
      name: "app.livetranslator/app_info", binaryMessenger: messenger)
    appInfo.setMethodCallHandler { call, result in
      switch call.method {
      case "bundleId":
        result(Bundle.main.bundleIdentifier)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    let tts = FlutterMethodChannel(
      name: "app.livetranslator/tts", binaryMessenger: messenger)
    tts.setMethodCallHandler { [weak self] call, result in
      guard let self else { return }
      switch call.method {
      case "speak":
        let args = call.arguments as? [String: Any]
        let text = args?["text"] as? String ?? ""
        let language = args?["languageCode"] as? String ?? "en"
        result(self.speech.speak(text: text, languageCode: language))
      case "prepare":
        let args = call.arguments as? [String: Any]
        self.speech.prepare(languageCode: args?["languageCode"] as? String ?? "en-US")
        result(nil)
      case "stop":
        self.speech.stop()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
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
      case "playbackStart":
        let args = call.arguments as? [String: Any]
        let sampleRate = args?["sampleRate"] as? Int ?? 24000
        do {
          try self.audioPlayback.start(sampleRate: Double(sampleRate))
          result(nil)
        } catch {
          result(
            FlutterError(
              code: "playback_start_failed", message: error.localizedDescription, details: nil))
        }
      case "playbackChunk":
        let args = call.arguments as? [String: Any]
        if let data = args?["data"] as? FlutterStandardTypedData {
          self.audioPlayback.enqueue(pcm16: data.data)
        }
        result(nil)
      case "playbackStop":
        self.audioPlayback.stop()
        result(nil)
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
// Microphone capture (unchanged environmental-listening configuration)
// ─────────────────────────────────────────────────────────────────────────────

final class AudioCaptureManager: NSObject, FlutterStreamHandler {
  private let engine = AVAudioEngine()
  private var converter: AVAudioConverter?
  private var targetFormat: AVAudioFormat?
  private var eventSink: FlutterEventSink?
  private(set) var isRunning = false

  private var observersRegistered = false

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
    //  - .playAndRecord + .defaultToSpeaker so translated speech can play
    //    while listening. Feedback (speaker → mic) is prevented in Dart: the
    //    microphone uplink is gated while playback is audible.
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

    logCaptureConfiguration(session: session, input: input, inputFormat: inputFormat)

    input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
      self?.handle(buffer: buffer)
    }
    engine.prepare()
    try engine.start()
    isRunning = true

    registerObservers(session: session)
  }

  /// One line per capture start describing what the HARDWARE is actually
  /// doing. This is the evidence that separates "the phone never captured the
  /// distant voice" from "it captured it and something downstream lost it" —
  /// without it, a far-field report is guesswork. Configuration only: no audio
  /// and no transcript ever reaches the log.
  private func logCaptureConfiguration(
    session: AVAudioSession, input: AVAudioInputNode, inputFormat: AVAudioFormat
  ) {
    let route = session.currentRoute.inputs.first
    let polar = route?.selectedDataSource?.selectedPolarPattern?.rawValue ?? "n/a"
    let dataSource = route?.selectedDataSource?.dataSourceName ?? "n/a"
    print(
      """
      [LT-NATIVE] AUDIO_SESSION category=\(session.category.rawValue) \
      mode=\(session.mode.rawValue) \
      route=\(route?.portType.rawValue ?? "none") dataSource=\(dataSource) \
      polarPattern=\(polar) \
      voiceProcessing=\(input.isVoiceProcessingEnabled) \
      hwSampleRate=\(session.sampleRate) tapSampleRate=\(inputFormat.sampleRate) \
      tapChannels=\(inputFormat.channelCount) \
      inputGain=\(session.inputGain) gainSettable=\(session.isInputGainSettable) \
      ioBuffer=\(session.ioBufferDuration)
      """
    )
  }

  /// Registered exactly once — `start` runs again on every recovery, and
  /// duplicate observers would multiply every interruption into several
  /// restarts.
  private func registerObservers(session: AVAudioSession) {
    guard !observersRegistered else { return }
    observersRegistered = true
    // A phone call or Siri taking the microphone must flip the UI to
    // "Not Listening" — the app never pretends to listen when it can't.
    NotificationCenter.default.addObserver(
      self, selector: #selector(handleInterruption(_:)),
      name: AVAudioSession.interruptionNotification, object: session)
    // Background listening spans headphone plugs, Bluetooth connects and
    // speaker switches; a route change reconfigures the engine, so the tap has
    // to be rebuilt or capture silently goes dead while still "listening".
    NotificationCenter.default.addObserver(
      self, selector: #selector(handleRouteChange(_:)),
      name: AVAudioSession.routeChangeNotification, object: session)
    NotificationCenter.default.addObserver(
      self, selector: #selector(handleEngineConfigurationChange(_:)),
      name: .AVAudioEngineConfigurationChange, object: engine)
  }

  @objc private func handleInterruption(_ notification: Notification) {
    guard isRunning,
      let info = notification.userInfo,
      let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
      let type = AVAudioSession.InterruptionType(rawValue: typeValue)
    else { return }

    // A call or Siri took the microphone. Report the loss and stay stopped:
    // resuming on `.ended` would turn the microphone back on without the user
    // asking, and listening may only ever begin from an explicit action.
    guard type == .began else { return }
    stop(notify: "mic_lost")
  }

  /// Headphones in/out, Bluetooth connect, speaker switch. The engine's input
  /// format can change with the route, so rebuild the tap around it — the
  /// session is NOT interrupted here, the microphone stays on and the UI keeps
  /// showing it. Without this, background listening survives the route change
  /// in name only: the tap stops delivering buffers and nothing is heard.
  @objc private func handleRouteChange(_ notification: Notification) {
    guard let info = notification.userInfo,
      let reasonValue = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
      let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue)
    else { return }
    switch reason {
    case .newDeviceAvailable, .oldDeviceUnavailable, .routeConfigurationChange,
      .override:
      restartOnMain()
    default:
      break
    }
  }

  /// iOS reconfigured the engine (often alongside a route change). Without
  /// rebuilding, the installed tap stops delivering buffers and the session
  /// looks healthy while hearing nothing.
  @objc private func handleEngineConfigurationChange(_ notification: Notification) {
    restartOnMain()
  }

  /// Both notifications can arrive on an arbitrary thread; engine work belongs
  /// on the main thread.
  private func restartOnMain() {
    DispatchQueue.main.async { [weak self] in
      guard let self, self.isRunning else { return }
      try? self.restart()
    }
  }

  /// Rebuilds capture around the CURRENT hardware format, keeping the session
  /// running. Never reports a stop: this is recovery, not an interruption.
  private func restart() throws {
    guard isRunning, let sampleRate = targetFormat?.sampleRate else { return }
    stopEngineOnly()
    try start(sampleRate: sampleRate)
  }

  /// Tears the engine down without emitting a "stopped" event to Dart.
  private func stopEngineOnly() {
    guard isRunning else { return }
    isRunning = false
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()
    converter = nil
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
    NotificationCenter.default.removeObserver(self)
    observersRegistered = false
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    if let reason, let sink = eventSink {
      DispatchQueue.main.async {
        sink(["event": "stopped", "reason": reason])
      }
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Streamed PCM playback (Gemini's translated speech, 24 kHz mono PCM16)
//
// Joins the capture manager's .playAndRecord session. Emits
// {"active": true/false} on its event channel as the queue starts draining /
// runs dry — Dart uses that as ground truth for the half-duplex microphone
// gate (mic chunks are dropped while the device is speaking).
// ─────────────────────────────────────────────────────────────────────────────

final class AudioPlaybackManager: NSObject, FlutterStreamHandler {
  private let engine = AVAudioEngine()
  private let player = AVAudioPlayerNode()
  private var format: AVAudioFormat?
  private var eventSink: FlutterEventSink?
  private var pendingBuffers = 0
  private var isActive = false
  private var isStarted = false

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
    guard !isStarted else { return }
    guard
      let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)
    else {
      throw NSError(
        domain: "AudioPlayback", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Playback format not available"])
    }
    self.format = format
    if engine.attachedNodes.contains(player) == false {
      engine.attach(player)
    }
    engine.connect(player, to: engine.mainMixerNode, format: format)
    engine.prepare()
    try engine.start()
    player.play()
    isStarted = true
  }

  /// Converts an interleaved PCM16 chunk to Float32 and schedules it.
  func enqueue(pcm16 data: Data) {
    guard isStarted, let format else { return }
    let sampleCount = data.count / 2
    guard sampleCount > 0,
      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleCount))
    else { return }
    buffer.frameLength = AVAudioFrameCount(sampleCount)
    guard let channel = buffer.floatChannelData?[0] else { return }
    data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
      let samples = raw.bindMemory(to: Int16.self)
      for i in 0..<sampleCount {
        channel[i] = Float(Int16(littleEndian: samples[i])) / 32768.0
      }
    }
    setPending(delta: +1)
    player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
      DispatchQueue.main.async { self?.setPending(delta: -1) }
    }
  }

  func stop() {
    guard isStarted else { return }
    isStarted = false
    // player.stop() flushes queued buffers; their completions fire and drive
    // pendingBuffers back down, but force the "not speaking" event now so the
    // Dart gate opens immediately.
    player.stop()
    engine.stop()
    format = nil
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.pendingBuffers = 0
      self.updateActive(false)
    }
  }

  private func setPending(delta: Int) {
    if Thread.isMainThread {
      applyPending(delta: delta)
    } else {
      DispatchQueue.main.async { [weak self] in self?.applyPending(delta: delta) }
    }
  }

  private func applyPending(delta: Int) {
    pendingBuffers = max(0, pendingBuffers + delta)
    updateActive(pendingBuffers > 0)
  }

  private func updateActive(_ active: Bool) {
    guard active != isActive else { return }
    isActive = active
    eventSink?(["active": active])
  }
}
