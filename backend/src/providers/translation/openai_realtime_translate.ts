import { WebSocket } from 'ws';
import { resamplePcm16 } from '../../utils/audio';
import { log } from '../../utils/logger';

/**
 * OpenAI gpt-realtime-translate — the PRIMARY live translation path.
 *
 * One WebSocket per listening session to the dedicated realtime translation
 * endpoint. Spoken input in any supported language goes in continuously
 * (no segmenting, no commits); translated TEXT deltas come back while the
 * speaker is still talking. Only the target language is configured — source
 * language detection is automatic, and there is no per-utterance
 * transcription→translation round trip.
 *
 * Utterance boundaries: the endpooint streams one continuous transcript, so
 * this session groups output deltas into bubbles itself — a pause of
 * UTTERANCE_GAP_MS with no new translated text finalizes the current
 * utterance, and the next delta starts a new one. Any *.done/*.completed
 * transcript event the server may emit finalizes immediately.
 */

const DEFAULT_TRANSLATE_URL = 'wss://api.openai.com/v1/realtime/translations';
const REALTIME_SAMPLE_RATE = 24_000;
/** No new translated text for this long → the utterance (bubble) is done. */
const UTTERANCE_GAP_MS = 900;

export interface RealtimeTranslationSession {
  sendAudio(pcm: Buffer): void;
  close(): Promise<void>;
  onDelta(handler: (utteranceId: string, delta: string) => void): void;
  onUtteranceFinal(
    handler: (utteranceId: string, translatedText: string, sourceText: string) => void,
  ): void;
  onError(handler: (error: Error) => void): void;
}

export interface RealtimeTranslationProvider {
  readonly name: string;
  createSession(options: { sampleRate: number; targetLanguage: string }): RealtimeTranslationSession;
}

/**
 * Groups a continuous translated-transcript stream into utterances. Pure and
 * clock-injected so the gap logic is unit-testable without sockets/timers.
 */
export class TranslationUtteranceAssembler {
  private utteranceCounter = 0;
  private currentId: string | null = null;
  private translated = '';
  private source = '';
  private lastDeltaAt = 0;

  constructor(private readonly gapMs: number = UTTERANCE_GAP_MS) {}

  get activeUtteranceId(): string | null {
    return this.currentId;
  }

  /** Returns the utterance id this delta belongs to (created on demand). */
  addOutputDelta(delta: string, nowMs: number): { utteranceId: string; isFirst: boolean } {
    const isFirst = this.currentId === null;
    if (this.currentId === null) {
      this.utteranceCounter += 1;
      this.currentId = `utterance_${this.utteranceCounter}`;
      this.translated = '';
      this.source = '';
    }
    this.translated += delta;
    this.lastDeltaAt = nowMs;
    return { utteranceId: this.currentId, isFirst };
  }

  /** Source-language transcript deltas ride along for the "original" line. */
  addInputDelta(delta: string): void {
    this.source += delta;
  }

  /**
   * Finalize when the gap elapsed (or force=true, e.g. stream closing or a
   * server-side done event). Returns the finished utterance or null.
   */
  flushIfIdle(
    nowMs: number,
    force = false,
  ): { utteranceId: string; translatedText: string; sourceText: string } | null {
    if (this.currentId === null) return null;
    if (!force && nowMs - this.lastDeltaAt < this.gapMs) return null;
    const finished = {
      utteranceId: this.currentId,
      translatedText: this.translated.trim(),
      sourceText: this.source.trim(),
    };
    this.currentId = null;
    this.translated = '';
    this.source = '';
    return finished.translatedText ? finished : null;
  }
}

interface TranslateEvent {
  type?: string;
  delta?: string;
  /** Position on the server's input-audio timeline, when provided. */
  elapsed_ms?: number;
  error?: { type?: string; code?: string; message?: string };
}

class OpenAIRealtimeTranslateSession implements RealtimeTranslationSession {
  private ws: WebSocket;
  private open = false;
  private closed = false;
  private readonly sendQueue: string[] = [];
  private readonly assembler = new TranslationUtteranceAssembler();
  private gapTimer: NodeJS.Timeout | null = null;

  private deltaHandler: (utteranceId: string, delta: string) => void = () => undefined;
  private finalHandler: (utteranceId: string, translatedText: string, sourceText: string) => void =
    () => undefined;
  private errorHandler: (error: Error) => void = () => undefined;

  constructor(
    apiKey: string,
    model: string,
    private readonly targetLanguage: string,
    private readonly inputSampleRate: number,
    baseUrl: string = DEFAULT_TRANSLATE_URL,
  ) {
    const url = new URL(baseUrl);
    url.searchParams.set('model', model);
    this.ws = new WebSocket(url, {
      headers: { Authorization: `Bearer ${apiKey}` },
    });
    this.ws.on('open', () => this.handleOpen());
    this.ws.on('message', (data: Buffer) => this.handleMessage(data));
    this.ws.on('close', (code: number) => this.handleClose(code));
    this.ws.on('error', (error: Error) => {
      log.error('[OPENAI ERROR] translate socket', { message: error.message });
      if (!this.closed) this.errorHandler(new Error('Translation stream error'));
    });
  }

  onDelta(handler: (utteranceId: string, delta: string) => void): void {
    this.deltaHandler = handler;
  }

  onUtteranceFinal(
    handler: (utteranceId: string, translatedText: string, sourceText: string) => void,
  ): void {
    this.finalHandler = handler;
  }

  onError(handler: (error: Error) => void): void {
    this.errorHandler = handler;
  }

  sendAudio(pcm: Buffer): void {
    if (this.closed) return;
    const resampled = resamplePcm16(pcm, this.inputSampleRate, REALTIME_SAMPLE_RATE);
    this.sendJson({
      type: 'session.input_audio_buffer.append',
      audio: resampled.toString('base64'),
    });
  }

  async close(): Promise<void> {
    if (this.closed) return;
    this.closed = true;
    if (this.gapTimer) clearTimeout(this.gapTimer);
    this.flush(true);
    if (this.open) {
      try {
        // Graceful close lets pending translated output drain server-side,
        // but we do not wait for session.closed — the session is over.
        this.ws.send(JSON.stringify({ type: 'session.close' }));
      } catch {
        // socket already down
      }
    }
    this.ws.close();
  }

  private sendJson(payload: Record<string, unknown>): void {
    const raw = JSON.stringify(payload);
    if (!this.open) {
      this.sendQueue.push(raw);
      return;
    }
    this.ws.send(raw);
  }

  private handleOpen(): void {
    if (this.closed) {
      this.ws.close();
      return;
    }
    // Only the target language is configured; source detection is automatic.
    // Audio stays queued until the server ACKNOWLEDGES the update
    // (session.updated) — appending audio while the language change is still
    // being applied races the server into a state where translated
    // transcript deltas never arrive.
    this.ws.send(
      JSON.stringify({
        type: 'session.update',
        session: { audio: { output: { language: this.targetLanguage } } },
      }),
    );
  }

  private handleSessionReady(): void {
    if (this.open || this.closed) return;
    this.open = true;
    for (const raw of this.sendQueue) this.ws.send(raw);
    this.sendQueue.length = 0;
  }

  private handleMessage(data: Buffer): void {
    if (this.closed) return;
    let event: TranslateEvent;
    try {
      event = JSON.parse(data.toString('utf8')) as TranslateEvent;
    } catch {
      return;
    }
    const type = event.type ?? 'unknown';
    log.debug('[OPENAI raw]', { type, elapsedMs: event.elapsed_ms });

    // REQUIRED diagnostics: every server event type is visible (deltas at
    // debug so info-level logs stay readable; first delta of each utterance
    // and everything else at info). Never audio payloads, never keys.
    if (type.includes('error') || event.error) {
      log.error('[OPENAI ERROR]', {
        type,
        code: event.error?.code,
        errorType: event.error?.type,
        message: event.error?.message,
      });
      this.errorHandler(
        new Error(`Realtime translation error: ${event.error?.message ?? type}`),
      );
      return;
    }

    switch (type) {
      case 'session.updated':
        log.info('[OPENAI] session.updated');
        this.handleSessionReady();
        break;
      case 'session.output_transcript.delta': {
        const delta = event.delta ?? '';
        if (!delta) break;
        const { utteranceId, isFirst } = this.assembler.addOutputDelta(delta, Date.now());
        if (isFirst) {
          log.info('[OPENAI] translation delta (utterance start)', { utteranceId });
        } else {
          log.debug('[OPENAI] translation delta');
        }
        this.deltaHandler(utteranceId, delta);
        this.armGapTimer();
        break;
      }
      case 'session.input_transcript.delta':
        log.debug('[OPENAI] source transcript delta');
        this.assembler.addInputDelta(event.delta ?? '');
        break;
      case 'session.output_audio.delta':
        log.debug('[OPENAI] translated audio delta (ignored — text-only MVP)');
        break;
      default:
        log.info(`[OPENAI] ${type}`);
        // Any explicit end-of-transcript signal finalizes right away.
        if (/output_transcript\.(done|completed)/.test(type)) this.flush(true);
        if (type === 'session.closed') this.flush(true);
        break;
    }
  }

  private armGapTimer(): void {
    if (this.gapTimer) clearTimeout(this.gapTimer);
    this.gapTimer = setTimeout(() => this.flush(false), UTTERANCE_GAP_MS);
    this.gapTimer.unref?.();
  }

  private flush(force: boolean): void {
    const finished = this.assembler.flushIfIdle(Date.now(), force);
    if (finished) {
      log.info('[OPENAI] translation done', {
        utteranceId: finished.utteranceId,
        outputLength: finished.translatedText.length,
      });
      this.finalHandler(finished.utteranceId, finished.translatedText, finished.sourceText);
    }
  }

  private handleClose(code: number): void {
    if (this.gapTimer) clearTimeout(this.gapTimer);
    if (this.closed) return;
    this.closed = true;
    this.flush(true);
    log.warn('[OPENAI] translate socket closed unexpectedly', { code });
    this.errorHandler(new Error(`Translation stream closed (${code})`));
  }
}

export class OpenAIRealtimeTranslationProvider implements RealtimeTranslationProvider {
  readonly name = 'openai-realtime-translate';

  constructor(
    private readonly apiKey: string,
    private readonly model: string = 'gpt-realtime-translate',
    private readonly baseUrl: string = DEFAULT_TRANSLATE_URL,
  ) {
    if (!apiKey) {
      throw new Error('TRANSLATION_API_KEY is required for the openai realtime translation provider');
    }
  }

  createSession(options: {
    sampleRate: number;
    targetLanguage: string;
  }): RealtimeTranslationSession {
    return new OpenAIRealtimeTranslateSession(
      this.apiKey,
      this.model,
      options.targetLanguage,
      options.sampleRate,
      this.baseUrl,
    );
  }
}
