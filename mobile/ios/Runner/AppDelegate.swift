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
      default:
        result(FlutterMethodNotImplemented)
      }
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
    // .measurement keeps system voice processing minimal; the backend's
    // speech provider handles the rest. playAndRecord so TTS can speak
    // translations while listening (Earphone Mode).
    try session.setCategory(
      .playAndRecord, mode: .measurement, options: [.allowBluetooth, .defaultToSpeaker])
    try session.setActive(true)

    let input = engine.inputNode
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
