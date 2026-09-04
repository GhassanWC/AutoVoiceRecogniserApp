import { env } from '../../config/env';
import { SpeakerDiarizationProvider } from '../../providers/diarization';
import {
  SpeechRecognitionProvider,
  StreamingSpeechProvider,
  StreamingSpeechSession,
  StreamingUtterance,
} from '../../providers/speech';
import { ConversationTurn, TranslationProvider } from '../../providers/translation';
import { getStore } from '../../storage';
import { pcm16ToWav, pcmDurationMs } from '../../utils/audio';
import { newId, newUuid } from '../../utils/ids';
import { log } from '../../utils/logger';
import { hasRemainingAllowance, recordProcessedSpeech } from '../usage/usage.service';
import {
  AudioFrame,
  SegmentStartMessage,
  ServerMessage,
  SessionStartMessage,
  TranslationMessagePayload,
} from './protocol';

interface ActiveSegment {
  id: string;
  sampleRate: number;
  chunks: Buffer[];
  byteLength: number;
  nextSequence: number;
  startedAtMs: number;
}

export interface LiveSessionDeps {
  userId: string;
  speech: SpeechRecognitionProvider;
  /** Streaming recognizer; null → per-segment batch pipeline via `speech`. */
  streamingSpeech?: StreamingSpeechProvider | null;
  translation: TranslationProvider;
  diarization: SpeakerDiarizationProvider;
  send: (message: ServerMessage) => void;
}

const CONTEXT_WINDOW_TURNS = 6;
const MIN_SEGMENT_MS = 250;

/**
 * Short utterances ("yes", "okay", "hello") exist near-identically in many
 * languages — never claim a language for them unless the provider was
 * genuinely confident, otherwise the UI shows a wrong flag.
 */
const SHORT_UTTERANCE_MAX_WORDS = 2;
const SHORT_UTTERANCE_MIN_LANGUAGE_CONFIDENCE = 0.8;

export function gatedLanguage(text: string, language: string, languageConfidence: number): string {
  const wordCount = text.trim().split(/\s+/).filter(Boolean).length;
  if (
    wordCount <= SHORT_UTTERANCE_MAX_WORDS &&
    languageConfidence < SHORT_UTTERANCE_MIN_LANGUAGE_CONFIDENCE
  ) {
    return 'und';
  }
  return language;
}

/** Everything translateAndEmit needs, regardless of which pipeline ran STT. */
interface RecognizedUtterance {
  segmentId: string;
  text: string;
  language: string;
  languageConfidence: number;
  transcriptionConfidence: number;
  speakerId: string | null;
  speakerLabel: string | null;
  audioMs: number;
  sttProvider: string;
}

/**
 * One WebSocket connection = at most one live listening session.
 *
 * Streaming pipeline (Deepgram): all segment audio is forwarded into a single
 * provider stream for the whole session, so multilingual language detection
 * and speaker diarization work across the entire conversation. Segment ends
 * force a provider flush; finalized utterances are translated and emitted.
 * Speaker ids come from the provider verbatim — never re-derived here.
 *
 * Batch pipeline (fallback for providers without streaming, and when the
 * stream fails mid-session): buffered PCM → WAV → per-segment recognition
 * → heuristic speaker assignment → translation.
 *
 * The audio buffer is released as soon as recognition has it; raw audio is
 * never written to disk or to the database (docs/PRIVACY.md).
 */
export class LiveSession {
  private sessionId: string | null = null;
  private targetLanguage = 'en';
  private saveHistory = false;
  private sessionPersisted = false;
  private startedAt = 0;
  private translationCount = 0;
  private segment: ActiveSegment | null = null;
  private processedSegmentIds = new Set<string>();
  private context: ConversationTurn[] = [];
  private queue: Promise<void> = Promise.resolve();
  private closed = false;

  private stream: StreamingSpeechSession | null = null;
  private streamFailed = false;
  /** Segment ids whose Finalize we are still waiting on, oldest first. */
  private pendingFinalizeSegments: string[] = [];
  private lastSegmentId: string | null = null;

  constructor(private readonly deps: LiveSessionDeps) {}

  get isStarted(): boolean {
    return this.sessionId !== null;
  }

  private get streamingEnabled(): boolean {
    return Boolean(this.deps.streamingSpeech) && !this.streamFailed;
  }

  async handleSessionStart(message: SessionStartMessage): Promise<void> {
    if (this.sessionId) {
      this.deps.send({
        type: 'error',
        code: 'session_already_started',
        message: 'A session is already running on this connection.',
        recoverable: true,
      });
      return;
    }
    if (!(await hasRemainingAllowance(this.deps.userId))) {
      this.deps.send({
        type: 'limit_reached',
        message: 'You have used all of your free translation minutes for this month.',
      });
      return;
    }

    this.sessionId = newId('session');
    this.targetLanguage = message.targetLanguage;
    this.saveHistory = message.saveHistory;
    this.startedAt = Date.now();

    if (this.saveHistory) {
      await getStore().createSession({
        id: this.sessionId,
        userId: this.deps.userId,
        targetLanguage: this.targetLanguage,
        startedAt: new Date(this.startedAt).toISOString(),
        endedAt: null,
        translationCount: 0,
      });
      this.sessionPersisted = true;
    }

    log.info('session started', {
      sessionId: this.sessionId,
      userId: this.deps.userId,
      targetLanguage: this.targetLanguage,
      saveHistory: this.saveHistory,
      streaming: this.streamingEnabled,
    });
    this.deps.send({
      type: 'session_started',
      sessionId: this.sessionId,
      targetLanguage: this.targetLanguage,
    });
  }

  handleSegmentStart(message: SegmentStartMessage): void {
    if (!this.requireSession()) return;

    if (Date.now() - this.startedAt > env.MAX_SESSION_MINUTES * 60_000) {
      this.deps.send({
        type: 'limit_reached',
        message: 'This listening session reached its maximum length. Please start again.',
      });
      return;
    }

    if (this.segment) {
      // The client should always close a segment before opening the next one;
      // if it did not (e.g. after a hiccup), drop the unfinished one.
      this.deps.send({
        type: 'segment_dropped',
        segmentId: this.segment.id,
        reason: 'superseded',
      });
    }

    this.segment = {
      id: message.segmentId,
      sampleRate: message.sampleRate,
      chunks: [],
      byteLength: 0,
      nextSequence: 0,
      startedAtMs: Date.now() - this.startedAt,
    };
    this.lastSegmentId = message.segmentId;

    if (this.streamingEnabled && !this.stream) {
      this.openStream(message.sampleRate);
    }
    this.deps.send({ type: 'status', segmentId: message.segmentId, state: 'hearing' });
  }

  handleAudioFrame(frame: AudioFrame): void {
    const segment = this.segment;
    if (!segment || segment.id !== frame.segmentId) return; // stale frame after drop/reconnect
    if (frame.sequence < segment.nextSequence) return; // duplicate (client retry)
    if (frame.sequence > segment.nextSequence) {
      if (this.stream) {
        // Audio already sent upstream can't be unsent; keep going with a gap —
        // the transcript may lose a word, which beats dropping the utterance.
        log.warn('audio gap inside streamed segment', {
          segmentId: segment.id,
          expected: segment.nextSequence,
          got: frame.sequence,
        });
        segment.nextSequence = frame.sequence;
      } else {
        // Lost data inside a buffered segment makes the transcript unreliable.
        this.deps.send({ type: 'segment_dropped', segmentId: segment.id, reason: 'audio_gap' });
        this.segment = null;
        return;
      }
    }
    segment.nextSequence += 1;

    const maxBytes = env.MAX_SEGMENT_SECONDS * segment.sampleRate * 2;
    if (segment.byteLength + frame.pcm.length > maxBytes) {
      this.deps.send({ type: 'segment_dropped', segmentId: segment.id, reason: 'too_long' });
      this.segment = null;
      return;
    }
    segment.byteLength += frame.pcm.length;
    if (this.stream) {
      this.stream.sendAudio(frame.pcm);
    } else {
      segment.chunks.push(frame.pcm);
    }
  }

  handleSegmentEnd(segmentId: string, clientDurationMs?: number): void {
    if (!this.requireSession()) return;
    const segment = this.segment;
    if (!segment || segment.id !== segmentId) return;
    this.segment = null;

    if (this.processedSegmentIds.has(segmentId)) return; // reconnect duplicate
    this.processedSegmentIds.add(segmentId);

    const durationMs = pcmDurationMs(segment.byteLength, {
      sampleRate: segment.sampleRate,
      channels: 1,
    });

    if (this.stream) {
      // Streaming path: the audio is already at the provider; force a flush so
      // the utterance finalizes now instead of on the provider's endpointer.
      this.pendingFinalizeSegments.push(segmentId);
      this.stream.finalize();
      this.deps.send({ type: 'status', segmentId, state: 'transcribing' });
      if (durationMs > 0) {
        void recordProcessedSpeech(this.deps.userId, durationMs / 1000, 0).catch(() => undefined);
      }
      return;
    }

    // ── Batch path ────────────────────────────────────────────────────────────

    // The client's VAD marks discarded blips with duration 0 — trust it and
    // skip the (paid) recognition call entirely.
    if (clientDurationMs === 0) {
      this.deps.send({ type: 'segment_dropped', segmentId, reason: 'discarded_by_client' });
      return;
    }

    const pcm = Buffer.concat(segment.chunks);
    segment.chunks = []; // release references early
    if (durationMs < MIN_SEGMENT_MS) {
      this.deps.send({ type: 'segment_dropped', segmentId, reason: 'too_short' });
      return;
    }

    // Process sequentially so results (and translation context) stay in order.
    this.enqueue(() => this.processSegment(segment, pcm, durationMs), segmentId);
  }

  // ── Streaming pipeline ──────────────────────────────────────────────────────

  private openStream(sampleRate: number): void {
    const provider = this.deps.streamingSpeech;
    if (!provider) return;
    try {
      const stream = provider.createSession({ sampleRate });
      stream.onUtterance((utterance) => this.handleStreamUtterance(provider.name, utterance));
      stream.onFinalized((hadSpeech) => this.handleStreamFinalized(hadSpeech));
      stream.onError((error) => this.handleStreamError(error));
      this.stream = stream;
    } catch (error) {
      this.streamFailed = true;
      log.error('failed to open speech stream, falling back to batch', {
        sessionId: this.sessionId,
        message: error instanceof Error ? error.message : String(error),
      });
    }
  }

  private handleStreamUtterance(providerName: string, utterance: StreamingUtterance): void {
    if (this.closed || !this.sessionId) return;
    if (!utterance.text) return;

    const segmentId = this.pendingFinalizeSegments[0] ?? this.lastSegmentId ?? newUuid();
    const speakerId = utterance.speakerId;
    const speakerNumber = speakerId?.match(/(\d+)$/)?.[1];

    const recognized: RecognizedUtterance = {
      segmentId,
      text: utterance.text,
      language: gatedLanguage(utterance.text, utterance.language, utterance.languageConfidence),
      languageConfidence: utterance.languageConfidence,
      transcriptionConfidence: utterance.transcriptionConfidence,
      speakerId,
      speakerLabel: speakerNumber ? `Speaker ${speakerNumber}` : null,
      audioMs: Math.max(0, utterance.endMs - utterance.startMs),
      sttProvider: providerName,
    };
    this.enqueue(() => this.translateAndEmit(recognized, utterance.language), segmentId);
  }

  private handleStreamFinalized(hadSpeech: boolean): void {
    const segmentId = this.pendingFinalizeSegments.shift();
    if (!hadSpeech && segmentId) {
      this.deps.send({ type: 'segment_dropped', segmentId, reason: 'no_speech' });
    }
  }

  private handleStreamError(error: Error): void {
    log.warn('speech stream failed, falling back to batch recognition', {
      sessionId: this.sessionId,
      message: error.message,
    });
    this.stream = null;
    this.streamFailed = true;
    this.pendingFinalizeSegments = [];
    // Audio already forwarded for the current segment is gone; drop it so the
    // client's UI does not wait forever, then continue via the batch path.
    if (this.segment) {
      this.deps.send({ type: 'segment_dropped', segmentId: this.segment.id, reason: 'stream_error' });
      this.segment = null;
    }
    if (this.sessionId) {
      this.deps.send({
        type: 'error',
        code: 'stream_interrupted',
        message: 'Live recognition hiccuped — continuing automatically.',
        recoverable: true,
      });
    }
  }

  // ── Batch pipeline ──────────────────────────────────────────────────────────

  private async processSegment(
    segment: ActiveSegment,
    pcm: Buffer,
    durationMs: number,
  ): Promise<void> {
    if (this.closed || !this.sessionId) return;

    if (!(await hasRemainingAllowance(this.deps.userId))) {
      this.deps.send({
        type: 'limit_reached',
        message: 'You have used all of your free translation minutes for this month.',
      });
      return;
    }

    this.deps.send({ type: 'status', segmentId: segment.id, state: 'transcribing' });

    const wav = pcm16ToWav(pcm, { sampleRate: segment.sampleRate, channels: 1 });
    const transcript = await this.deps.speech.transcribe({
      wav,
      sampleRate: segment.sampleRate,
      durationMs,
    });
    // Raw audio is no longer needed from this point on; buffers go out of
    // scope here and are garbage-collected — nothing is persisted.

    if (this.closed) return;
    if (!transcript.text) {
      this.deps.send({ type: 'segment_dropped', segmentId: segment.id, reason: 'no_speech' });
      return;
    }

    const speaker = await this.deps.diarization.assignSpeaker({
      startedAtMs: segment.startedAtMs,
      durationMs,
      language: transcript.language,
      languageConfidence: transcript.languageConfidence,
    });

    this.deps.send({
      type: 'partial_transcription',
      segmentId: segment.id,
      speakerId: speaker.speakerId,
      language: transcript.language === 'und' ? null : transcript.language,
      text: transcript.text,
    });

    await this.translateAndEmit(
      {
        segmentId: segment.id,
        text: transcript.text,
        language: gatedLanguage(transcript.text, transcript.language, transcript.languageConfidence),
        languageConfidence: transcript.languageConfidence,
        transcriptionConfidence: transcript.transcriptionConfidence,
        speakerId: speaker.speakerId,
        speakerLabel: speaker.speakerLabel,
        audioMs: durationMs,
        sttProvider: this.deps.speech.name,
      },
      transcript.language,
    );

    await recordProcessedSpeech(this.deps.userId, durationMs / 1000, 0);
  }

  // ── Shared translate + emit ─────────────────────────────────────────────────

  private async translateAndEmit(
    recognized: RecognizedUtterance,
    detectedLanguage: string,
  ): Promise<void> {
    if (this.closed || !this.sessionId) return;

    this.deps.send({ type: 'status', segmentId: recognized.segmentId, state: 'translating' });

    const translateStarted = Date.now();
    let translatedText: string;
    let translateLatencyMs = 0;
    if (recognized.language === this.targetLanguage) {
      translatedText = recognized.text; // already in the user's language
    } else {
      const result = await this.deps.translation.translate({
        text: recognized.text,
        sourceLanguage: recognized.language,
        targetLanguage: this.targetLanguage,
        context: this.context,
      });
      translatedText = result.translatedText;
      translateLatencyMs = Date.now() - translateStarted;
    }

    if (this.closed || !this.sessionId) return;

    const payload: TranslationMessagePayload = {
      type: 'translation',
      id: newId('msg'),
      segmentId: recognized.segmentId,
      speakerId: recognized.speakerId,
      speakerLabel: recognized.speakerLabel,
      sourceLanguage: recognized.language,
      languageConfidence: recognized.languageConfidence,
      transcriptionConfidence: recognized.transcriptionConfidence,
      originalText: recognized.text,
      translatedText,
      targetLanguage: this.targetLanguage,
      timestamp: new Date().toISOString(),
      diagnostics: {
        sttProvider: recognized.sttProvider,
        detectedLanguage,
        audioMs: recognized.audioMs,
        translateLatencyMs,
      },
    };
    this.deps.send(payload);
    this.translationCount += 1;

    this.context.push({
      sourceLanguage: recognized.language,
      originalText: recognized.text,
      translatedText,
    });
    if (this.context.length > CONTEXT_WINDOW_TURNS) this.context.shift();

    if (this.saveHistory && this.sessionPersisted) {
      await getStore().addMessage({
        id: payload.id,
        sessionId: this.sessionId,
        speakerId: recognized.speakerId,
        speakerLabel: recognized.speakerLabel,
        sourceLanguage: recognized.language,
        languageConfidence: recognized.languageConfidence,
        originalText: recognized.text,
        translatedText,
        createdAt: payload.timestamp,
      });
    }

    // Speech seconds are metered at segment end; characters are metered here.
    await recordProcessedSpeech(this.deps.userId, 0, translatedText.length).catch(() => undefined);

    log.info('utterance translated', {
      sessionId: this.sessionId,
      segmentId: recognized.segmentId,
      sttProvider: recognized.sttProvider,
      audioMs: recognized.audioMs,
      sourceLanguage: recognized.language,
      detectedLanguage,
      languageConfidence: recognized.languageConfidence,
      transcriptionConfidence: recognized.transcriptionConfidence,
      speakerId: recognized.speakerId,
      translateLatencyMs,
    });
  }

  private enqueue(work: () => Promise<void>, segmentId: string): void {
    this.queue = this.queue.then(() =>
      work().catch((error) => {
        log.error('utterance processing failed', {
          sessionId: this.sessionId,
          segmentId,
          message: error instanceof Error ? error.message : String(error),
        });
        this.deps.send({
          type: 'error',
          code: 'processing_failed',
          message: 'Translation is temporarily unavailable. Please try again.',
          recoverable: true,
        });
      }),
    );
  }

  async handleSessionStop(): Promise<void> {
    if (!this.sessionId) return;
    if (this.stream) {
      // Flush whatever the provider is still holding, give its results a
      // moment to arrive, then let in-flight translations finish.
      this.stream.finalize();
      await new Promise((resolve) => setTimeout(resolve, 500));
      await this.stream.close().catch(() => undefined);
      this.stream = null;
    }
    // Let in-flight segments finish so their results are not lost.
    await this.queue;
    const sessionId = this.sessionId;
    const durationSeconds = Math.round((Date.now() - this.startedAt) / 1000);

    if (this.sessionPersisted) {
      await getStore().endSession(sessionId, new Date().toISOString(), this.translationCount);
    }
    log.info('session stopped', {
      sessionId,
      durationSeconds,
      translationCount: this.translationCount,
    });
    this.deps.send({
      type: 'session_ended',
      sessionId,
      translationCount: this.translationCount,
      durationSeconds,
    });

    this.sessionId = null;
    this.segment = null;
    this.context = [];
    this.translationCount = 0;
    this.processedSegmentIds.clear();
    this.pendingFinalizeSegments = [];
    this.streamFailed = false;
  }

  /** Socket closed — finalize the session record, drop all buffers. */
  async dispose(): Promise<void> {
    this.closed = true;
    this.segment = null;
    if (this.stream) {
      await this.stream.close().catch(() => undefined);
      this.stream = null;
    }
    if (this.sessionId && this.sessionPersisted) {
      await getStore()
        .endSession(this.sessionId, new Date().toISOString(), this.translationCount)
        .catch(() => undefined);
    }
    this.sessionId = null;
  }

  private requireSession(): boolean {
    if (this.sessionId) return true;
    this.deps.send({
      type: 'error',
      code: 'no_session',
      message: 'Send session_start before streaming audio.',
      recoverable: true,
    });
    return false;
  }
}

export function newSegmentId(): string {
  return newUuid();
}
