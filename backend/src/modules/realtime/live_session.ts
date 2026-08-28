import { env } from '../../config/env';
import { SpeakerDiarizationProvider } from '../../providers/diarization';
import { SpeechRecognitionProvider } from '../../providers/speech';
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
  translation: TranslationProvider;
  diarization: SpeakerDiarizationProvider;
  send: (message: ServerMessage) => void;
}

const CONTEXT_WINDOW_TURNS = 6;
const MIN_SEGMENT_MS = 250;

/**
 * One WebSocket connection = at most one live listening session.
 *
 * Pipeline per finished segment:
 *   buffered PCM → WAV → speech recognition (auto language detection)
 *   → speaker assignment → translation → result event → optional history.
 *
 * The audio buffer is released as soon as transcription completes; raw audio
 * is never written to disk or to the database (docs/PRIVACY.md).
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

  constructor(private readonly deps: LiveSessionDeps) {}

  get isStarted(): boolean {
    return this.sessionId !== null;
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
    this.deps.send({ type: 'status', segmentId: message.segmentId, state: 'hearing' });
  }

  handleAudioFrame(frame: AudioFrame): void {
    const segment = this.segment;
    if (!segment || segment.id !== frame.segmentId) return; // stale frame after drop/reconnect
    if (frame.sequence < segment.nextSequence) return; // duplicate (client retry)
    if (frame.sequence > segment.nextSequence) {
      // Lost data inside a segment makes the transcript unreliable — drop it.
      this.deps.send({ type: 'segment_dropped', segmentId: segment.id, reason: 'audio_gap' });
      this.segment = null;
      return;
    }
    segment.nextSequence += 1;

    const maxBytes = env.MAX_SEGMENT_SECONDS * segment.sampleRate * 2;
    if (segment.byteLength + frame.pcm.length > maxBytes) {
      this.deps.send({ type: 'segment_dropped', segmentId: segment.id, reason: 'too_long' });
      this.segment = null;
      return;
    }
    segment.chunks.push(frame.pcm);
    segment.byteLength += frame.pcm.length;
  }

  handleSegmentEnd(segmentId: string, clientDurationMs?: number): void {
    if (!this.requireSession()) return;
    const segment = this.segment;
    if (!segment || segment.id !== segmentId) return;
    this.segment = null;

    if (this.processedSegmentIds.has(segmentId)) return; // reconnect duplicate
    this.processedSegmentIds.add(segmentId);

    // The client's VAD marks discarded blips with duration 0 — trust it and
    // skip the (paid) recognition call entirely.
    if (clientDurationMs === 0) {
      this.deps.send({ type: 'segment_dropped', segmentId, reason: 'discarded_by_client' });
      return;
    }

    const pcm = Buffer.concat(segment.chunks);
    segment.chunks = []; // release references early
    const durationMs = pcmDurationMs(pcm.length, { sampleRate: segment.sampleRate, channels: 1 });
    if (durationMs < MIN_SEGMENT_MS) {
      this.deps.send({ type: 'segment_dropped', segmentId, reason: 'too_short' });
      return;
    }

    // Process sequentially so results (and translation context) stay in order.
    this.queue = this.queue.then(() =>
      this.processSegment(segment, pcm, durationMs).catch((error) => {
        log.error('segment processing failed', {
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

    const startedProcessing = Date.now();
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
    this.deps.send({ type: 'status', segmentId: segment.id, state: 'translating' });

    let translatedText: string;
    if (transcript.language === this.targetLanguage) {
      translatedText = transcript.text; // already in the user's language
    } else {
      const result = await this.deps.translation.translate({
        text: transcript.text,
        sourceLanguage: transcript.language,
        targetLanguage: this.targetLanguage,
        context: this.context,
      });
      translatedText = result.translatedText;
    }

    if (this.closed || !this.sessionId) return;

    const payload: TranslationMessagePayload = {
      type: 'translation',
      id: newId('msg'),
      segmentId: segment.id,
      speakerId: speaker.speakerId,
      speakerLabel: speaker.speakerLabel,
      sourceLanguage: transcript.language,
      languageConfidence: transcript.languageConfidence,
      originalText: transcript.text,
      translatedText,
      targetLanguage: this.targetLanguage,
      timestamp: new Date().toISOString(),
    };
    this.deps.send(payload);
    this.translationCount += 1;

    this.context.push({
      sourceLanguage: transcript.language,
      originalText: transcript.text,
      translatedText,
    });
    if (this.context.length > CONTEXT_WINDOW_TURNS) this.context.shift();

    if (this.saveHistory && this.sessionPersisted) {
      await getStore().addMessage({
        id: payload.id,
        sessionId: this.sessionId,
        speakerId: speaker.speakerId,
        speakerLabel: speaker.speakerLabel,
        sourceLanguage: transcript.language,
        languageConfidence: transcript.languageConfidence,
        originalText: transcript.text,
        translatedText,
        createdAt: payload.timestamp,
      });
    }

    await recordProcessedSpeech(this.deps.userId, durationMs / 1000, translatedText.length);
    log.info('segment translated', {
      sessionId: this.sessionId,
      segmentId: segment.id,
      audioMs: durationMs,
      pipelineMs: Date.now() - startedProcessing,
      sourceLanguage: transcript.language,
      speakerId: speaker.speakerId,
    });
  }

  async handleSessionStop(): Promise<void> {
    if (!this.sessionId) return;
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
  }

  /** Socket closed — finalize the session record, drop all buffers. */
  async dispose(): Promise<void> {
    this.closed = true;
    this.segment = null;
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
