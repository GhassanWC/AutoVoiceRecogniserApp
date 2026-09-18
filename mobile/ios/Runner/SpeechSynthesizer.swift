import AVFoundation
import Flutter

/// Reads a finalized translation aloud with the system voice.
///
/// Deliberately does NOT touch the AVAudioSession: while a translation session
/// is running, AudioCaptureManager owns the session (.playAndRecord with
/// .measurement, .defaultToSpeaker) and reconfiguring it here would disturb
/// live capture. AVSpeechSynthesizer plays into whatever session is already
/// active, which is exactly what we want.
///
/// Emits {"speaking": true/false} so Dart can quiet the microphone uplink for
/// the duration and reopen it the instant speech ends.
final class SpeechSynthesizer: NSObject, FlutterStreamHandler,
  AVSpeechSynthesizerDelegate
{
  private let synthesizer = AVSpeechSynthesizer()
  private var eventSink: FlutterEventSink?
  private var preparedVoice: AVSpeechSynthesisVoice?

  override init() {
    super.init()
    synthesizer.delegate = self
  }

  // MARK: - FlutterStreamHandler

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

  // MARK: - Speaking

  /// Resolves (and caches) the voice for `languageCode` ahead of the first
  /// tap. AVSpeechSynthesizer itself needs no warming, but looking the voice
  /// up here keeps the first speak() off the voice-catalog path.
  func prepare(languageCode: String) {
    preparedVoice = Self.voice(for: languageCode)
  }

  /// Speaks `text` in `languageCode` (BCP-47). Returns false when the device
  /// has no voice for that language, so the UI can say so instead of appearing
  /// to do nothing.
  func speak(text: String, languageCode: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return false }
    // Use the warmed voice when it matches, otherwise resolve now.
    let voice: AVSpeechSynthesisVoice
    if let prepared = preparedVoice,
      prepared.language.caseInsensitiveCompare(languageCode) == .orderedSame
    {
      voice = prepared
    } else if let resolved = Self.voice(for: languageCode) {
      voice = resolved
      preparedVoice = resolved
    } else {
      return false
    }

    // A new tap replaces whatever is being said rather than queueing behind it.
    if synthesizer.isSpeaking {
      synthesizer.stopSpeaking(at: .immediate)
    }
    let utterance = AVSpeechUtterance(string: trimmed)
    utterance.voice = voice
    utterance.rate = AVSpeechUtteranceDefaultSpeechRate
    synthesizer.speak(utterance)
    return true
  }

  func stop() {
    guard synthesizer.isSpeaking else { return }
    synthesizer.stopSpeaking(at: .immediate)
  }

  /// Exact match first ("pt-BR"), then any installed voice for the primary
  /// subtag ("pt"), so a catalog code still speaks on a device that only has a
  /// regional variant installed.
  private static func voice(for languageCode: String) -> AVSpeechSynthesisVoice? {
    if let exact = AVSpeechSynthesisVoice(language: languageCode) {
      return exact
    }
    let primary = languageCode.split(separator: "-").first.map(String.init)
      ?? languageCode
    if let match = AVSpeechSynthesisVoice.speechVoices().first(where: {
      $0.language.lowercased().hasPrefix(primary.lowercased())
    }) {
      return match
    }
    return AVSpeechSynthesisVoice(language: primary)
  }

  // MARK: - AVSpeechSynthesizerDelegate

  func speechSynthesizer(
    _ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance
  ) {
    send(speaking: true)
  }

  func speechSynthesizer(
    _ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance
  ) {
    send(speaking: false)
  }

  func speechSynthesizer(
    _ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance
  ) {
    send(speaking: false)
  }

  private func send(speaking: Bool) {
    guard let sink = eventSink else { return }
    DispatchQueue.main.async { sink(["speaking": speaking]) }
  }
}
