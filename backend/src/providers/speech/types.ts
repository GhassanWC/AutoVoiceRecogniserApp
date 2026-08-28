export interface TranscriptionRequest {
  /** Complete WAV file (16-bit PCM) for one speech segment. */
  wav: Buffer;
  sampleRate: number;
  durationMs: number;
}

export interface TranscriptionResult {
  /** Recognized text; empty string when the provider heard no speech. */
  text: string;
  /** ISO 639-1 code detected by the provider, e.g. "en", "es", "ar". */
  language: string;
  /** 0..1 confidence in the language detection (0 when unknown). */
  languageConfidence: number;
  /** 0..1 confidence in the transcription itself (0 when unknown). */
  transcriptionConfidence: number;
}

/**
 * A speech-to-text provider. Implementations must auto-detect the spoken
 * language per segment — the app never asks the user for a source language.
 */
export interface SpeechRecognitionProvider {
  readonly name: string;
  transcribe(request: TranscriptionRequest): Promise<TranscriptionResult>;
}
