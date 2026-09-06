import { env } from '../../config/env';
import { SpeakerDiarizationProvider } from '../../providers/diarization';
import {
  SpeechRecognitionProvider,
  StreamingSpeechProvider,
  StreamingSpeechSession,
  StreamingUtterance,
} from '../../providers/speech';
import {
  ConversationTurn,
  RealtimeTranslationProvider,
  RealtimeTranslationSession,
  TranslationProvider,
  TranslationRequest,
} from '../../providers/translation';
import { getStore } from '../../storage';
import { pcm16Rms, pcm16ToWav, pcmDurationMs } from '../../utils/audio';
import { newId, newUuid } from '../../utils/ids';
import { log } from '../../utils/logger';
import { hasRemainingAllowance, recordProcessedSpeech } from '../usage/usage.service';
import {
  AudioFrame,
  SegmentStartMessage,
  ServerMessage,
  SessionStartMessage,
  StreamStartMessage,
  TranscriptFinalPayload,
  TranslationLatency,
} from './protocol';
import {
  TranslationDelta,
  TranslationJobFailure,
  TranslationJobSuccess,
  TranslationQueue,
  TranslationQueueOptions,
} from './translation_queue';

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
  /**
   * PRIMARY live path (gpt-realtime-translate): speech in → translated text
   * deltas out on one socket. When null or failed, continuous sessions fall
   * back to streamingSpeech + the text translation queue.
   */
  realtimeTranslation?: RealtimeTranslationProvider | null;
  diarization: SpeakerDiarizationProvider;
  send: (message: ServerMessage) => void;
  /** Test hook: shorter retry delays / different concurrency. */
  translationQueueOptions?: TranslationQueueOptions;
}

const CONTEXT_WINDOW_TURNS = 6;
const MIN_SEGMENT_MS = 250;

/** How many finished messages stay retryable / dedupe-able per session. */
const MESSAGE_REGISTRY_LIMIT = 200;

/**
 * Short utterances ("yes", "okay", "hello") exist near-identically in many
 * languages — never claim a language for them unless the provider was
 * genuinely confident, otherwise the UI shows a wrong flag.
 * This gates the DISPLAYED language only; translation always runs.
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

/** Everything transcript emission needs, regardless of which pipeline ran STT. */
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
  /** Wall-clock ms when the provider VAD heard speech end (latency anchor). */
  speechEndAtMs?: number;
}

interface RegisteredMessage {
  request: TranslationRequest;
  status: 'pending' | 'done' | 'failed';
  translatedText?: string;
  originalText: string;
  audioMs: number;
  speakerId: string | null;
  speakerLabel: string | null;
  languageConfidence: number;
  /** Language the translator detected; set on completion. */
  resolvedLanguage?: string;
  speechEndAtMs?: number;
  firstDeltaLatencyMs?: number;
}

/**
 * One WebSocket connection = at most one live listening session.
 *
 * Streaming pipeline (Deepgram): all segment audio is forwarded into a single
 * provider stream for the whole session; the stream NEVER waits on
 * translation. Each finalized utterance is sent to the client immediately as
 * `transcript_final` (so a transcript is never lost), then translated through
 * a bounded-concurrency retry queue; `translation_complete` /
 * `translation_failed` update the same messageId later. `sourceLanguage` is
 * metadata only — a transcript is ALWAYS translated, "und" included.
 *
 * Batch pipeline (fallback for providers without streaming, and when the
 * stream fails mid-session): buffered PCM → WAV → per-segment recognition →
 * heuristic speaker assignment → the same transcript/translation flow.
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
  private sttQueue: Promise<void> = Promise.resolve();
  private closed = false;

  private stream: StreamingSpeechSession | null = null;
  private streamFailed = false;
  /** Segment ids whose Finalize we are still waiting on, oldest first. */
  private pendingFinalizeSegments: string[] = [];
  private lastSegmentId: string | null = null;

  /** Continuous-streaming mode (live subtitles): the active stream id. */
  private continuousStreamId: string | null = null;
  private continuousSampleRate = 16000;
  private streamReopenAttempts = 0;
  private audioFramesReceived = 0;

  /** Primary realtime-translation session state. */
  private translateSession: RealtimeTranslationSession | null = null;
  private translateFailed = false;
  private translateReopenAttempts = 0;
  /** provider utteranceId → messageId, plus when the utterance began. */
  private readonly utteranceMessages = new Map<string, { messageId: string; startedAt: number }>();

  /**
   * Utterance-based failover: the translate endpoint occasionally returns
   * sessions that accept audio yet never emit a translation. A light
   * server-side energy tracker detects when an utterance ENDS; if the direct
   * path produced no delta within FAILOVER_DEADLINE_MS of speech end, that
   * SAME utterance (kept in a short in-memory buffer, never persisted) is
   * replayed through the verified STT + text-translation fallback under the
   * SAME messageId, and the rest of the session stays on the fallback. Short
   * phrases ("Hello") trigger this exactly like long ones.
   */
  private static readonly UTTERANCE_START_MS = 150;
  private static readonly UTTERANCE_END_SILENCE_MS = 600;
  private static readonly MIN_UTTERANCE_SPEECH_MS = 300;
  private static readonly FAILOVER_DEADLINE_MS = 1400;
  private static readonly FAILOVER_PREROLL_MS = 1000;
  private static readonly FAILOVER_BUFFER_CAP_MS = 20_000;

  /**
   * The energy detector is ADAPTIVE, not a fixed threshold: distant/TV speech
   * can be clearly audible well below a near-field level, and this detector
   * only decides when to ARM the failover deadline (never whether audio is
   * uploaded), so it is deliberately more sensitive than the phone's old VAD.
   * speechThreshold = max(0.0035, noiseFloor × 2), with a lower release
   * threshold for hysteresis so speech does not flicker on/off; the floor
   * follows quiet audio and rises only glacially during speech.
   */
  private static readonly FAILOVER_MIN_THRESHOLD = 0.0035;
  private static readonly FAILOVER_MIN_RELEASE = 0.0025;
  private static readonly FAILOVER_FLOOR_MIN = 0.0012;
  private static readonly FAILOVER_FLOOR_MAX = 0.02;

  private failoverNoiseFloor = 0.002;
  private speechActive = false;
  private utterSpeechMs = 0;
  private utterSilentMs = 0;
  private deltaSinceUtteranceStart = false;
  /**
   * When the provider emits speech_started/speech_stopped events, those are
   * the PRIMARY utterance-boundary signal and the energy detector becomes a
   * backup (it keeps maintaining the replay buffer and noise floor).
   */
  private providerBoundaries = false;
  /** Rolling pre-roll + current-utterance audio, ONLY for failover replay. */
  private recentAudio: Array<{ pcm: Buffer; ms: number }> = [];
  private recentAudioMs = 0;
  private pendingCheck: { messageId: string; audio: Buffer; timer: NodeJS.Timeout } | null = null;
  /** Consumed by the first fallback utterance after a failover. */
  private failoverMessageId: string | null = null;

  /** speech_end → first-delta / final latency samples for p50/p95 logging. */
  private readonly latencySamples: Array<{ firstDeltaMs?: number; finalMs: number }> = [];

  private translations: TranslationQueue;
  /** messageId → job info, for retries and duplicate protection. */
  private messages = new Map<string, RegisteredMessage>();

  constructor(private readonly deps: LiveSessionDeps) {
    this.translations = new TranslationQueue(
      deps.translation,
      (result) => this.handleTranslationSuccess(result),
      (failure) => this.handleTranslationFailure(failure),
      deps.translationQueueOptions,
      (delta) => this.handleTranslationDelta(delta),
    );
  }

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

  /**
   * Continuous-streaming mode: from here on the client sends ALL microphone
   * audio and the speech provider's server VAD cuts utterances. This is the
   * live-subtitle path — a local VAD never again decides which room speech
   * is "worth" uploading.
   */
  handleStreamStart(message: StreamStartMessage): void {
    if (!this.requireSession()) return;
    const translateAvailable = Boolean(this.deps.realtimeTranslation) && !this.translateFailed;
    if (!translateAvailable && !this.streamingEnabled) {
      this.deps.send({
        type: 'error',
        code: 'streaming_unsupported',
        message: 'Live streaming is not available with the configured providers.',
        recoverable: false,
      });
      return;
    }
    this.continuousStreamId = message.streamId;
    this.continuousSampleRate = message.sampleRate;
    this.streamReopenAttempts = 0;
    if (translateAvailable) {
      // PRIMARY: speech → translated text on one socket (gpt-realtime-translate).
      if (!this.translateSession) this.openTranslateSession(message.sampleRate);
    } else if (!this.stream) {
      // FALLBACK: realtime transcription + text translation queue.
      this.openStream(message.sampleRate, true);
    }
    this.deps.send({ type: 'status', segmentId: message.streamId, state: 'hearing' });
  }

  handleAudioFrame(frame: AudioFrame): void {
    // Continuous mode: forward straight to the provider, nothing else gates it.
    if (this.continuousStreamId && frame.segmentId === this.continuousStreamId) {
      if (Date.now() - this.startedAt > env.MAX_SESSION_MINUTES * 60_000) {
        this.deps.send({
          type: 'limit_reached',
          message: 'This listening session reached its maximum length. Please start again.',
        });
        this.continuousStreamId = null;
        return;
      }
      if (this.audioFramesReceived === 0) {
        log.info('[2] BACKEND_AUDIO_RECEIVED (first frame)', { streamId: frame.segmentId });
      } else if (this.audioFramesReceived % 100 === 0) {
        log.info('[2] BACKEND_AUDIO_RECEIVED', { frames: this.audioFramesReceived });
      }
      this.audioFramesReceived += 1;
      if (this.translateSession) {
        this.translateSession.sendAudio(frame.pcm);
        this.trackUtteranceForFailover(frame.pcm);
      } else {
        this.stream?.sendAudio(frame.pcm);
      }
      return;
    }

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

    // STT stays sequential so transcripts appear in spoken order; translation
    // does NOT run inside this chain (it goes through the TranslationQueue).
    this.sttQueue = this.sttQueue.then(() =>
      this.processSegment(segment, pcm, durationMs).catch((error) => {
        log.error('segment recognition failed', {
          sessionId: this.sessionId,
          segmentId,
          message: error instanceof Error ? error.message : String(error),
        });
        this.deps.send({
          type: 'error',
          code: 'recognition_failed',
          message: 'Speech recognition hiccuped — please keep talking.',
          recoverable: true,
        });
      }),
    );
  }

  // ── Primary live path: gpt-realtime-translate ──────────────────────────────

  private openTranslateSession(sampleRate: number): void {
    const provider = this.deps.realtimeTranslation;
    if (!provider) return;
    try {
      const session = provider.createSession({
        sampleRate,
        targetLanguage: this.targetLanguage,
      });
      session.onDelta((utteranceId, delta) => this.handleTranslateDelta(utteranceId, delta));
      session.onUtteranceFinal((utteranceId, translatedText, sourceText) =>
        this.handleTranslateFinal(utteranceId, translatedText, sourceText),
      );
      session.onError((error) => this.handleTranslateError(error));
      session.onSpeechBoundary?.((boundary) => this.handleProviderSpeechBoundary(boundary));
      this.translateSession = session;
      this.speechActive = false;
      this.utterSpeechMs = 0;
      this.utterSilentMs = 0;
      // A reopened session may not emit VAD events — energy backup re-arms.
      this.providerBoundaries = false;
    } catch (error) {
      this.translateFailed = true;
      log.error('failed to open realtime translation session, using fallback', {
        sessionId: this.sessionId,
        message: error instanceof Error ? error.message : String(error),
      });
      this.openStream(sampleRate, true);
    }
  }

  /**
   * Energy tracker on the audio forwarded to the direct-translate session.
   * Detects utterance boundaries; at each utterance end with NO delta seen,
   * arms the failover deadline with a snapshot of that utterance's audio.
   */
  private trackUtteranceForFailover(pcm: Buffer): void {
    const frameMs = pcmDurationMs(pcm.length, {
      sampleRate: this.continuousSampleRate,
      channels: 1,
    });
    this.recentAudio.push({ pcm, ms: frameMs });
    this.recentAudioMs += frameMs;
    while (
      this.recentAudioMs > LiveSession.FAILOVER_BUFFER_CAP_MS &&
      this.recentAudio.length > 1
    ) {
      this.recentAudioMs -= this.recentAudio.shift()!.ms;
    }

    const rms = pcm16Rms(pcm);
    // Hysteresis: opening an utterance needs the onset threshold; staying in
    // one only needs the lower release threshold, so quiet trailing syllables
    // and natural level dips do not flicker speech off.
    const onset = Math.max(
      LiveSession.FAILOVER_MIN_THRESHOLD,
      this.failoverNoiseFloor * 2,
    );
    const release = Math.max(
      LiveSession.FAILOVER_MIN_RELEASE,
      this.failoverNoiseFloor * 1.4,
    );
    const isSpeech = rms >= (this.speechActive ? release : onset);

    // Noise-floor adaptation: follow drops quickly, converge onto steady
    // sub-threshold ambience, and rise only glacially while sound is above
    // the threshold — sustained distant speech must never become "noise".
    if (rms < this.failoverNoiseFloor) {
      this.failoverNoiseFloor = this.failoverNoiseFloor * 0.9 + rms * 0.1;
    } else if (!this.speechActive && rms < onset) {
      this.failoverNoiseFloor = this.failoverNoiseFloor * 0.995 + rms * 0.005;
    } else {
      this.failoverNoiseFloor = Math.min(
        this.failoverNoiseFloor * 1.0002,
        LiveSession.FAILOVER_FLOOR_MAX,
      );
    }
    this.failoverNoiseFloor = Math.max(this.failoverNoiseFloor, LiveSession.FAILOVER_FLOOR_MIN);

    // Boundary decisions belong to the provider's VAD events when the
    // session emits them; the energy path below is the backup.
    if (this.providerBoundaries) return;

    if (isSpeech) {
      this.utterSilentMs = 0;
      this.utterSpeechMs += frameMs;
      if (!this.speechActive && this.utterSpeechMs >= LiveSession.UTTERANCE_START_MS) {
        this.speechActive = true;
        this.deltaSinceUtteranceStart = false;
        // Keep only ~1 s of pre-roll behind the utterance start.
        const keepMs = LiveSession.FAILOVER_PREROLL_MS + this.utterSpeechMs;
        while (this.recentAudioMs > keepMs && this.recentAudio.length > 1) {
          this.recentAudioMs -= this.recentAudio.shift()!.ms;
        }
      }
      return;
    }

    this.utterSilentMs += frameMs;
    if (!this.speechActive) {
      this.utterSpeechMs = 0;
      return;
    }
    if (this.utterSilentMs >= LiveSession.UTTERANCE_END_SILENCE_MS) {
      const speechMs = this.utterSpeechMs;
      this.speechActive = false;
      this.utterSpeechMs = 0;
      if (speechMs >= LiveSession.MIN_UTTERANCE_SPEECH_MS) {
        this.armFailoverCheck();
      }
    }
  }

  /** Provider VAD events (primary boundary signal when the endpoint sends them). */
  private handleProviderSpeechBoundary(boundary: 'started' | 'stopped'): void {
    if (this.closed || !this.sessionId || !this.continuousStreamId) return;
    this.providerBoundaries = true;
    if (boundary === 'started') {
      this.deltaSinceUtteranceStart = false;
      this.speechActive = true;
      return;
    }
    this.speechActive = false;
    this.armFailoverCheck();
  }

  /** Utterance just ended with no direct output yet → start the deadline. */
  private armFailoverCheck(): void {
    if (this.deltaSinceUtteranceStart || this.pendingCheck) return;
    const messageId = newId('msg');
    const audio = Buffer.concat(this.recentAudio.map((entry) => entry.pcm));
    const timer = setTimeout(() => this.failoverUtterance(), LiveSession.FAILOVER_DEADLINE_MS);
    timer.unref?.();
    this.pendingCheck = { messageId, audio, timer };
  }

  /** The armed deadline passed with no direct output — switch to the fallback. */
  private failoverUtterance(): void {
    const pending = this.pendingCheck;
    this.pendingCheck = null;
    if (!pending || this.closed || !this.sessionId || !this.continuousStreamId) return;

    log.warn(
      '[FAILOVER] direct translate produced no output for a finished utterance — switching this session to the STT fallback',
      { sessionId: this.sessionId, messageId: pending.messageId, audioBytes: pending.audio.length },
    );
    this.translateFailed = true;
    const defective = this.translateSession;
    this.translateSession = null;
    if (defective) void defective.close().catch(() => undefined);
    this.recentAudio = [];
    this.recentAudioMs = 0;
    this.speechActive = false;

    if (!this.streamingEnabled) {
      this.continuousStreamId = null;
      this.deps.send({
        type: 'error',
        code: 'stream_interrupted',
        message: 'Live translation is unavailable right now. Please stop and start again.',
        recoverable: false,
      });
      return;
    }
    if (!this.stream) this.openStream(this.continuousSampleRate, true);
    if (!this.stream) return;

    // Replay the SAME utterance (plus trailing silence so the fallback's
    // server VAD endpoints it immediately); its transcript will reuse the
    // reserved messageId, so the user sees one bubble, no duplicates. Live
    // audio keeps flowing into this stream from here on.
    this.failoverMessageId = pending.messageId;
    this.stream.sendAudio(pending.audio);
    this.stream.sendAudio(Buffer.alloc((this.continuousSampleRate * 2 * 800) / 1000));
  }

  /** Direct output within the deadline claims the reserved messageId. */
  private consumePendingMessageId(): string | null {
    const pending = this.pendingCheck;
    if (!pending) return null;
    clearTimeout(pending.timer);
    this.pendingCheck = null;
    return pending.messageId;
  }

  /** First delta of an utterance creates the bubble; every delta streams into it. */
  private handleTranslateDelta(utteranceId: string, delta: string): void {
    if (this.closed || !this.sessionId) return;
    // A late delta from a session already failed over must not resurrect it —
    // the fallback owns this utterance now (no duplicate bubbles).
    if (this.translateFailed) return;
    log.info('[3] OPENAI_TRANSLATION_DELTA', { utteranceId, delta });
    this.deltaSinceUtteranceStart = true;
    let mapping = this.utteranceMessages.get(utteranceId);
    if (!mapping) {
      const messageId = this.consumePendingMessageId() ?? newId('msg');
      mapping = { messageId, startedAt: Date.now() };
      this.utteranceMessages.set(utteranceId, mapping);
      this.registerMessage(messageId, {
        request: { text: '', sourceLanguage: 'und', targetLanguage: this.targetLanguage },
        status: 'pending',
        originalText: '',
        audioMs: 0,
        speakerId: null, // diarization is out of the primary MVP path
        speakerLabel: null,
        languageConfidence: 0,
      });
      // Explicit bubble announcement BEFORE the first delta, so the client
      // always has a message to stream into; the source transcript (when
      // available) arrives with translation_complete.
      log.info('[4] WS_SENT_TO_MOBILE translation_started', { messageId });
      this.deps.send({
        type: 'translation_started',
        messageId,
        segmentId: this.continuousStreamId ?? newUuid(),
        speakerId: null,
        speakerLabel: null,
        sourceLanguage: 'und',
        targetLanguage: this.targetLanguage,
        timestamp: new Date().toISOString(),
      });
    }
    log.info('[5] WS_SENT_TO_MOBILE translation_delta', {
      messageId: mapping.messageId,
      delta,
    });
    this.deps.send({ type: 'translation_delta', messageId: mapping.messageId, delta });
  }

  private handleTranslateFinal(
    utteranceId: string,
    translatedText: string,
    sourceText: string,
  ): void {
    if (this.closed || !this.sessionId) return;
    if (this.translateFailed) return; // late output after failover — ignore
    const mapping = this.utteranceMessages.get(utteranceId);
    if (!mapping) return;
    this.utteranceMessages.delete(utteranceId);

    const entry = this.messages.get(mapping.messageId);
    if (entry) {
      entry.status = 'done';
      entry.translatedText = translatedText;
      entry.originalText = sourceText;
      entry.request.text = sourceText; // a manual Retry can re-run as text translation
    }

    this.deps.send({
      type: 'translation_complete',
      messageId: mapping.messageId,
      translatedText,
      targetLanguage: this.targetLanguage,
      sourceLanguage: 'und', // the translate model does not report it per utterance
      originalText: sourceText || undefined,
    });
    this.translationCount += 1;

    this.context.push({ sourceLanguage: 'und', originalText: sourceText, translatedText });
    if (this.context.length > CONTEXT_WINDOW_TURNS) this.context.shift();

    if (this.saveHistory && this.sessionPersisted) {
      void getStore()
        .addMessage({
          id: mapping.messageId,
          sessionId: this.sessionId,
          speakerId: null,
          speakerLabel: null,
          sourceLanguage: 'und',
          languageConfidence: 0,
          originalText: sourceText,
          translatedText,
          createdAt: new Date().toISOString(),
        })
        .catch(() => undefined);
    }

    // Meter the utterance's rough speech time (wall clock, capped) + output.
    const speechSeconds = Math.min(30, (Date.now() - mapping.startedAt) / 1000);
    void recordProcessedSpeech(this.deps.userId, speechSeconds, translatedText.length).catch(
      () => undefined,
    );
    void hasRemainingAllowance(this.deps.userId).then((allowed) => {
      if (!allowed && this.continuousStreamId && this.sessionId && !this.closed) {
        this.continuousStreamId = null;
        this.deps.send({
          type: 'limit_reached',
          message: 'You have used all of your free translation minutes for this month.',
        });
      }
    });

    log.info('utterance translated (realtime-translate)', {
      sessionId: this.sessionId,
      messageId: mapping.messageId,
      utteranceMs: Date.now() - mapping.startedAt,
      outputLength: translatedText.length,
    });
  }

  private handleTranslateError(error: Error): void {
    this.translateSession = null;
    if (this.closed || !this.sessionId || !this.continuousStreamId) return;

    if (this.translateReopenAttempts < 3) {
      this.translateReopenAttempts += 1;
      log.warn('realtime translation session failed, reopening', {
        sessionId: this.sessionId,
        attempt: this.translateReopenAttempts,
        message: error.message,
      });
      setTimeout(() => {
        if (
          !this.closed &&
          this.sessionId &&
          this.continuousStreamId &&
          !this.translateSession &&
          !this.translateFailed // an utterance failover may have won meanwhile
        ) {
          this.openTranslateSession(this.continuousSampleRate);
        }
      }, 500).unref?.();
      return;
    }

    // Primary path is gone for this session — switch to the fallback
    // (realtime transcription + text translation queue) transparently.
    log.error('realtime translation failed permanently, switching to fallback pipeline', {
      sessionId: this.sessionId,
      message: error.message,
    });
    this.translateFailed = true;
    if (this.streamingEnabled && !this.stream) {
      this.openStream(this.continuousSampleRate, true);
    } else if (!this.streamingEnabled) {
      this.continuousStreamId = null;
      this.deps.send({
        type: 'error',
        code: 'stream_interrupted',
        message: 'Live translation is unavailable right now. Please stop and start again.',
        recoverable: false,
      });
    }
  }

  // ── Fallback streaming pipeline (STT → text translation) ───────────────────

  private openStream(sampleRate: number, serverTurnDetection = false): void {
    const provider = this.deps.streamingSpeech;
    if (!provider) return;
    try {
      const stream = provider.createSession({ sampleRate, serverTurnDetection });
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

    const segmentId =
      this.continuousStreamId ??
      this.pendingFinalizeSegments[0] ??
      this.lastSegmentId ??
      newUuid();
    const speakerId = utterance.speakerId;
    const speakerNumber = speakerId?.match(/(\d+)$/)?.[1];

    this.emitTranscript({
      segmentId,
      text: utterance.text,
      language: gatedLanguage(utterance.text, utterance.language, utterance.languageConfidence),
      languageConfidence: utterance.languageConfidence,
      transcriptionConfidence: utterance.transcriptionConfidence,
      speakerId,
      speakerLabel: speakerNumber ? `Speaker ${speakerNumber}` : null,
      audioMs: Math.max(0, utterance.endMs - utterance.startMs),
      sttProvider: providerName,
      speechEndAtMs: utterance.speechEndAtMs,
    });
  }

  private handleStreamFinalized(hadSpeech: boolean): void {
    const segmentId = this.pendingFinalizeSegments.shift();
    if (!hadSpeech && segmentId) {
      this.deps.send({ type: 'segment_dropped', segmentId, reason: 'no_speech' });
    }
  }

  private handleStreamError(error: Error): void {
    this.stream = null;
    this.pendingFinalizeSegments = [];

    // Continuous mode has no client segments to fall back on — reopen the
    // provider stream instead (a moment of audio is lost, the session lives).
    if (this.continuousStreamId && !this.closed && this.sessionId) {
      if (this.streamReopenAttempts < 3) {
        this.streamReopenAttempts += 1;
        log.warn('speech stream failed in continuous mode, reopening', {
          sessionId: this.sessionId,
          attempt: this.streamReopenAttempts,
          message: error.message,
        });
        setTimeout(() => {
          if (!this.closed && this.sessionId && this.continuousStreamId && !this.stream) {
            this.openStream(this.continuousSampleRate, true);
          }
        }, 500).unref?.();
        return;
      }
      log.error('speech stream failed permanently in continuous mode', {
        sessionId: this.sessionId,
        message: error.message,
      });
      this.continuousStreamId = null;
      this.streamFailed = true;
      this.deps.send({
        type: 'error',
        code: 'stream_interrupted',
        message: 'Live recognition is unavailable right now. Please stop and start again.',
        recoverable: false,
      });
      return;
    }

    log.warn('speech stream failed, falling back to batch recognition', {
      sessionId: this.sessionId,
      message: error.message,
    });
    this.streamFailed = true;
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

    this.emitTranscript({
      segmentId: segment.id,
      text: transcript.text,
      language: gatedLanguage(transcript.text, transcript.language, transcript.languageConfidence),
      languageConfidence: transcript.languageConfidence,
      transcriptionConfidence: transcript.transcriptionConfidence,
      speakerId: speaker.speakerId,
      speakerLabel: speaker.speakerLabel,
      audioMs: durationMs,
      sttProvider: this.deps.speech.name,
    });

    await recordProcessedSpeech(this.deps.userId, durationMs / 1000, 0);
  }

  // ── Transcript-first delivery + queued translation ──────────────────────────

  /**
   * Send the transcript to the client immediately, then queue the translation.
   * `language` is metadata only: every non-empty transcript is translated,
   * including "und" — the translator detects the language itself in that case.
   */
  private emitTranscript(recognized: RecognizedUtterance): void {
    if (this.closed || !this.sessionId) return;

    // A failover reserved this id for the replayed utterance — same bubble,
    // no duplicate. Consumed exactly once.
    const messageId = this.failoverMessageId ?? newId('msg');
    this.failoverMessageId = null;
    const payload: TranscriptFinalPayload = {
      type: 'transcript_final',
      messageId,
      segmentId: recognized.segmentId,
      speakerId: recognized.speakerId,
      speakerLabel: recognized.speakerLabel,
      sourceLanguage: recognized.language,
      languageConfidence: recognized.languageConfidence,
      transcriptionConfidence: recognized.transcriptionConfidence,
      originalText: recognized.text,
      targetLanguage: this.targetLanguage,
      translationStatus: 'pending',
      timestamp: new Date().toISOString(),
      diagnostics: {
        sttProvider: recognized.sttProvider,
        detectedLanguage: recognized.language,
        audioMs: recognized.audioMs,
        translateLatencyMs: 0,
      },
    };
    this.deps.send(payload);

    const request: TranslationRequest = {
      text: recognized.text,
      sourceLanguage: recognized.language,
      targetLanguage: this.targetLanguage,
      context: [...this.context],
    };
    this.registerMessage(messageId, {
      request,
      status: 'pending',
      originalText: recognized.text,
      audioMs: recognized.audioMs,
      speakerId: recognized.speakerId,
      speakerLabel: recognized.speakerLabel,
      languageConfidence: recognized.languageConfidence,
      speechEndAtMs: recognized.speechEndAtMs,
    });

    if (this.continuousStreamId && recognized.segmentId === this.continuousStreamId) {
      // Continuous mode meters RECOGNIZED speech, not raw stream time —
      // an empty room costs the user nothing. Also the cheapest place to
      // notice an exhausted allowance and end the stream.
      void recordProcessedSpeech(
        this.deps.userId,
        Math.max(recognized.audioMs, 500) / 1000,
        0,
      ).catch(() => undefined);
      void hasRemainingAllowance(this.deps.userId).then((allowed) => {
        if (!allowed && this.continuousStreamId && this.sessionId && !this.closed) {
          this.continuousStreamId = null;
          this.deps.send({
            type: 'limit_reached',
            message: 'You have used all of your free translation minutes for this month.',
          });
        }
      });
    }

    // No same-language skip on purpose: language detection can be wrong, and
    // skipping on a wrong label would leave foreign speech untranslated. The
    // translator detects the input language itself and returns text already in
    // the target language naturally unchanged.
    this.translations.enqueue({ messageId, request });
  }

  /** Forward streamed translation chunks to the client the moment they exist. */
  private handleTranslationDelta(delta: TranslationDelta): void {
    if (this.closed || !this.sessionId) return;
    const entry = this.messages.get(delta.messageId);
    if (!entry || entry.status !== 'pending') return;
    if (entry.firstDeltaLatencyMs === undefined && entry.speechEndAtMs !== undefined) {
      entry.firstDeltaLatencyMs = Math.max(0, Date.now() - entry.speechEndAtMs);
    }
    this.deps.send({
      type: 'translation_delta',
      messageId: delta.messageId,
      delta: delta.delta,
      ...(delta.reset ? { reset: true } : {}),
    });
  }

  private handleTranslationSuccess(result: TranslationJobSuccess): void {
    const entry = this.messages.get(result.messageId);
    if (!entry || this.closed || !this.sessionId) return;
    if (entry.status === 'done') return; // duplicate completion (e.g. double retry)
    entry.status = 'done';
    entry.translatedText = result.translatedText;
    // The translator read the actual text, so its language verdict outranks
    // the speech provider's provisional label.
    const sourceLanguage = result.sourceLanguage ?? entry.request.sourceLanguage;
    entry.resolvedLanguage = sourceLanguage;

    let latency: TranslationLatency | undefined;
    if (entry.speechEndAtMs !== undefined) {
      latency = {
        speechEndToFirstDeltaMs: entry.firstDeltaLatencyMs,
        speechEndToFinalMs: Math.max(0, Date.now() - entry.speechEndAtMs),
      };
      this.recordLatency(latency);
    }

    this.deps.send({
      type: 'translation_complete',
      messageId: result.messageId,
      translatedText: result.translatedText,
      targetLanguage: this.targetLanguage,
      sourceLanguage,
      latency,
    });
    this.translationCount += 1;

    this.context.push({
      sourceLanguage,
      originalText: entry.originalText,
      translatedText: result.translatedText,
    });
    if (this.context.length > CONTEXT_WINDOW_TURNS) this.context.shift();

    if (this.saveHistory && this.sessionPersisted) {
      void getStore()
        .addMessage({
          id: result.messageId,
          sessionId: this.sessionId,
          speakerId: entry.speakerId,
          speakerLabel: entry.speakerLabel,
          sourceLanguage: entry.resolvedLanguage ?? entry.request.sourceLanguage,
          languageConfidence: entry.languageConfidence,
          originalText: entry.originalText,
          translatedText: result.translatedText,
          createdAt: new Date().toISOString(),
        })
        .catch(() => undefined);
    }

    // Characters are metered here; speech seconds were metered at segment end.
    void recordProcessedSpeech(this.deps.userId, 0, result.translatedText.length).catch(
      () => undefined,
    );

    log.info('translation complete', {
      sessionId: this.sessionId,
      messageId: result.messageId,
      attempts: result.attempts,
      latencyMs: result.latencyMs,
      sourceLanguage: entry.request.sourceLanguage,
      outputLength: result.translatedText.length,
    });
  }

  private handleTranslationFailure(failure: TranslationJobFailure): void {
    const entry = this.messages.get(failure.messageId);
    if (entry) entry.status = 'failed';
    log.error('translation failed permanently', {
      sessionId: this.sessionId,
      messageId: failure.messageId,
      attempts: failure.attempts,
      retriesExhausted: failure.retriesExhausted,
      lastStatus: failure.lastStatus,
      lastError: failure.lastError,
    });
    if (this.closed || !this.sessionId) return;
    // The transcript stays on screen; the client shows a Retry action and the
    // real failure reason reaches developer diagnostics (never a secret).
    this.deps.send({
      type: 'translation_failed',
      messageId: failure.messageId,
      reason: failure.lastError,
      status: failure.lastStatus,
    });
  }

  /** Client pressed Retry: resubmit the SAME text — no audio is re-recorded. */
  handleRetryTranslation(messageId: string): void {
    if (!this.requireSession()) return;
    const entry = this.messages.get(messageId);
    if (!entry) return; // unknown or evicted — nothing safe to do
    if (entry.status === 'pending') return; // already in flight
    if (entry.status === 'done') {
      // Idempotent: the earlier result may have been lost to a reconnect.
      this.deps.send({
        type: 'translation_complete',
        messageId,
        translatedText: entry.translatedText ?? '',
        targetLanguage: this.targetLanguage,
        sourceLanguage: entry.resolvedLanguage,
      });
      return;
    }
    entry.status = 'pending';
    this.translations.enqueue({ messageId, request: entry.request });
  }

  /** Track speech_end→translation latencies; log p50/p95 every 10 utterances. */
  private recordLatency(latency: TranslationLatency): void {
    if (latency.speechEndToFinalMs === undefined) return;
    this.latencySamples.push({
      firstDeltaMs: latency.speechEndToFirstDeltaMs,
      finalMs: latency.speechEndToFinalMs,
    });
    log.info('utterance latency', {
      sessionId: this.sessionId,
      speechEndToFirstDeltaMs: latency.speechEndToFirstDeltaMs,
      speechEndToFinalMs: latency.speechEndToFinalMs,
    });
    if (this.latencySamples.length % 10 === 0) {
      const percentile = (values: number[], p: number): number => {
        const sorted = [...values].sort((a, b) => a - b);
        return sorted[Math.min(sorted.length - 1, Math.floor((p / 100) * sorted.length))]!;
      };
      const firstDeltas = this.latencySamples
        .map((s) => s.firstDeltaMs)
        .filter((v): v is number => v !== undefined);
      const finals = this.latencySamples.map((s) => s.finalMs);
      log.info('latency percentiles', {
        sessionId: this.sessionId,
        samples: this.latencySamples.length,
        firstDeltaP50: firstDeltas.length ? percentile(firstDeltas, 50) : undefined,
        firstDeltaP95: firstDeltas.length ? percentile(firstDeltas, 95) : undefined,
        finalP50: percentile(finals, 50),
        finalP95: percentile(finals, 95),
      });
    }
  }

  private registerMessage(messageId: string, entry: RegisteredMessage): void {
    this.messages.set(messageId, entry);
    if (this.messages.size > MESSAGE_REGISTRY_LIMIT) {
      const oldest = this.messages.keys().next().value;
      if (oldest) this.messages.delete(oldest);
    }
  }

  async handleSessionStop(): Promise<void> {
    if (!this.sessionId) return;
    if (this.translateSession) {
      // Graceful close flushes any pending translated output server-side.
      await this.translateSession.close().catch(() => undefined);
      this.translateSession = null;
    }
    if (this.stream) {
      // Flush whatever the provider is still holding, give its results a
      // moment to arrive, then let in-flight work finish.
      this.stream.finalize();
      await new Promise((resolve) => setTimeout(resolve, 500));
      await this.stream.close().catch(() => undefined);
      this.stream = null;
    }
    // Let in-flight recognition and translations finish so results aren't lost.
    await this.sttQueue;
    await this.translations.drain();
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
    this.continuousStreamId = null;
    this.streamReopenAttempts = 0;
    this.translateFailed = false;
    this.translateReopenAttempts = 0;
    this.utteranceMessages.clear();
    if (this.pendingCheck) clearTimeout(this.pendingCheck.timer);
    this.pendingCheck = null;
    this.failoverMessageId = null;
    this.recentAudio = [];
    this.recentAudioMs = 0;
    this.speechActive = false;
    this.providerBoundaries = false;
    this.failoverNoiseFloor = 0.002;
  }

  /** Socket closed — finalize the session record, drop all buffers. */
  async dispose(): Promise<void> {
    this.closed = true;
    this.segment = null;
    this.translations.close();
    if (this.pendingCheck) clearTimeout(this.pendingCheck.timer);
    this.pendingCheck = null;
    this.recentAudio = [];
    this.recentAudioMs = 0;
    if (this.translateSession) {
      await this.translateSession.close().catch(() => undefined);
      this.translateSession = null;
    }
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
