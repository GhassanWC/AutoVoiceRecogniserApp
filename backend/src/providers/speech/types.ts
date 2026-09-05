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

// ── Streaming recognition ─────────────────────────────────────────────────────

/** One finalized utterance from a streaming recognizer. */
export interface StreamingUtterance {
  text: string;
  /** ISO 639-1 code, or "und" when the provider could not tell. */
  language: string;
  /** 0..1 confidence in the language assignment (0 when unknown). */
  languageConfidence: number;
  /** 0..1 confidence in the transcription itself (0 when unknown). */
  transcriptionConfidence: number;
  /**
   * Provider-assigned speaker id ("speaker_1", …), stable for the lifetime of
   * the streaming session. null when the provider did not diarize the words.
   * Consumers must pass this through unchanged — never re-derive speakers.
   */
  speakerId: string | null;
  /** Utterance position on the provider's audio timeline, milliseconds. */
  startMs: number;
  endMs: number;
  /**
   * Wall-clock epoch ms when the provider's VAD detected end of speech for
   * this utterance (when known) — the anchor for latency measurement.
   */
  speechEndAtMs?: number;
}

export interface StreamingSessionOptions {
  sampleRate: number;
  /**
   * true → the PROVIDER's VAD decides utterance boundaries (continuous audio
   * flows in, low-latency turn detection cuts utterances). false/absent → the
   * caller segments audio and calls finalize() at each utterance end.
   */
  serverTurnDetection?: boolean;
}

/**
 * One live audio stream to a streaming recognizer. All audio of a listening
 * session goes through a single instance, so the provider can diarize and
 * detect language switches across the whole conversation without reconnecting.
 */
export interface StreamingSpeechSession {
  /** Feed PCM16LE mono audio at the sample rate given to createSession. */
  sendAudio(pcm: Buffer): void;
  /** Ask the provider to flush buffered audio into final results now. */
  finalize(): void;
  /** Close the stream; no callbacks fire afterwards. */
  close(): Promise<void>;
  onUtterance(handler: (utterance: StreamingUtterance) => void): void;
  /**
   * Fires once per finalize() after all its utterances were delivered, with
   * whether that flush produced any speech (false → the audio was noise).
   */
  onFinalized(handler: (hadSpeech: boolean) => void): void;
  onError(handler: (error: Error) => void): void;
}

export interface StreamingSpeechProvider {
  readonly name: string;
  createSession(options: StreamingSessionOptions): StreamingSpeechSession;
}
