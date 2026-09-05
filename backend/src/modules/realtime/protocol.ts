import { z } from 'zod';

/**
 * Live-translation WebSocket protocol.
 *
 * Text frames carry JSON control/result messages.
 * Binary frames carry audio and have this layout (little-endian):
 *
 *   [0]        uint8   protocol version (currently 1)
 *   [1..36]    ascii   segment id (uuid v4, 36 chars)
 *   [37..40]   uint32  chunk sequence number within the segment, starting at 0
 *   [41..]     bytes   PCM 16-bit LE mono samples
 *
 * The client only streams audio while its local voice-activity detector says
 * someone is speaking, so silence never leaves the phone.
 */

export const BINARY_HEADER_BYTES = 41;
export const PROTOCOL_VERSION = 1;

// ── Client → server ───────────────────────────────────────────────────────────

export const sessionStartSchema = z.object({
  type: z.literal('session_start'),
  targetLanguage: z.string().min(2).max(8),
  saveHistory: z.boolean().optional().default(false),
});

export const segmentStartSchema = z.object({
  type: z.literal('segment_start'),
  segmentId: z.string().uuid(),
  sampleRate: z.number().int().min(8000).max(48000),
  channels: z.literal(1),
  encoding: z.literal('pcm16'),
});

export const segmentEndSchema = z.object({
  type: z.literal('segment_end'),
  segmentId: z.string().uuid(),
  durationMs: z.number().int().nonnegative(),
});

export const sessionStopSchema = z.object({
  type: z.literal('session_stop'),
});

/** User pressed Retry on a message whose translation failed. */
export const retryTranslationSchema = z.object({
  type: z.literal('retry_translation'),
  messageId: z.string().min(1).max(64),
});

export const pingSchema = z.object({
  type: z.literal('ping'),
  t: z.number().optional(),
});

export const clientMessageSchema = z.discriminatedUnion('type', [
  sessionStartSchema,
  segmentStartSchema,
  segmentEndSchema,
  sessionStopSchema,
  retryTranslationSchema,
  pingSchema,
]);

export type ClientMessage = z.infer<typeof clientMessageSchema>;
export type SessionStartMessage = z.infer<typeof sessionStartSchema>;
export type SegmentStartMessage = z.infer<typeof segmentStartSchema>;

// ── Server → client ───────────────────────────────────────────────────────────

export type SegmentState = 'hearing' | 'transcribing' | 'translating';

/** Extra per-utterance detail, shown only in the client's developer mode. */
export interface TranslationDiagnostics {
  /** Speech provider that produced the transcript, e.g. "deepgram". */
  sttProvider: string;
  /** Language code exactly as the provider reported it, before gating. */
  detectedLanguage: string;
  /** Duration of the recognized audio, milliseconds (0 when unknown). */
  audioMs: number;
  /** Translation request latency, milliseconds. 0 when translation was skipped. */
  translateLatencyMs: number;
}

export interface TranslationMessagePayload {
  type: 'translation';
  id: string;
  segmentId: string;
  speakerId: string | null;
  /** e.g. "Speaker 1"; null when diarization confidence is too low. */
  speakerLabel: string | null;
  sourceLanguage: string;
  /** 0..1; below ~0.5 the client shows "Language detected automatically". */
  languageConfidence: number;
  /** 0..1 provider confidence in the transcript itself (0 when unknown). */
  transcriptionConfidence: number;
  originalText: string;
  translatedText: string;
  targetLanguage: string;
  timestamp: string;
  diagnostics?: TranslationDiagnostics;
}

/**
 * A finalized transcript, sent the moment STT delivers it — before (and
 * regardless of whether) translation succeeds. The client shows the message
 * immediately with a "Translating…" placeholder; `translation_complete` /
 * `translation_failed` later update the SAME message via `messageId`.
 * A transcript is never lost because translation failed.
 */
export interface TranscriptFinalPayload {
  type: 'transcript_final';
  messageId: string;
  segmentId: string;
  speakerId: string | null;
  speakerLabel: string | null;
  /** Metadata only — translation runs even when this is "und". */
  sourceLanguage: string;
  languageConfidence: number;
  transcriptionConfidence: number;
  originalText: string;
  targetLanguage: string;
  translationStatus: 'pending';
  timestamp: string;
  diagnostics?: TranslationDiagnostics;
}

export interface TranslationCompletePayload {
  type: 'translation_complete';
  messageId: string;
  translatedText: string;
  targetLanguage: string;
  /**
   * Authoritative source language, detected by the TRANSLATOR from the text.
   * Replaces the provisional label from transcript_final when present.
   */
  sourceLanguage?: string;
}

/** Sent only after every retry failed; the client offers a Retry action. */
export interface TranslationFailedPayload {
  type: 'translation_failed';
  messageId: string;
  /** Real provider failure detail for developer diagnostics (never a secret). */
  reason?: string;
  status?: number;
}

export type ServerMessage =
  | { type: 'session_started'; sessionId: string; targetLanguage: string }
  | { type: 'status'; segmentId: string; state: SegmentState }
  | {
      type: 'partial_transcription';
      segmentId: string;
      speakerId: string | null;
      language: string | null;
      text: string;
    }
  | TranslationMessagePayload
  | TranscriptFinalPayload
  | TranslationCompletePayload
  | TranslationFailedPayload
  | { type: 'segment_dropped'; segmentId: string; reason: string }
  | { type: 'limit_reached'; message: string }
  | { type: 'error'; code: string; message: string; recoverable: boolean }
  | {
      type: 'session_ended';
      sessionId: string;
      translationCount: number;
      durationSeconds: number;
    }
  | { type: 'pong'; t?: number };

// ── Binary frame parsing ──────────────────────────────────────────────────────

export interface AudioFrame {
  segmentId: string;
  sequence: number;
  pcm: Buffer;
}

export function parseAudioFrame(data: Buffer): AudioFrame | null {
  if (data.length <= BINARY_HEADER_BYTES) return null;
  if (data.readUInt8(0) !== PROTOCOL_VERSION) return null;
  const segmentId = data.subarray(1, 37).toString('ascii');
  // Cheap uuid shape check — full validation happened at segment_start.
  if (segmentId[8] !== '-' || segmentId[13] !== '-') return null;
  const sequence = data.readUInt32LE(37);
  return { segmentId, sequence, pcm: data.subarray(BINARY_HEADER_BYTES) };
}

export function encodeAudioFrame(segmentId: string, sequence: number, pcm: Buffer): Buffer {
  const header = Buffer.alloc(BINARY_HEADER_BYTES);
  header.writeUInt8(PROTOCOL_VERSION, 0);
  header.write(segmentId, 1, 36, 'ascii');
  header.writeUInt32LE(sequence, 37);
  return Buffer.concat([header, pcm]);
}
