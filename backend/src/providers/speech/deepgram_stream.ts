import { WebSocket } from 'ws';
import { log } from '../../utils/logger';
import { StreamingSpeechProvider, StreamingSpeechSession, StreamingUtterance } from './types';

/**
 * Deepgram live streaming transcription.
 *
 * One WebSocket per listening session, opened with:
 *   - model=nova-3 + language=multi → multilingual code-switching recognition;
 *     the same stream handles switches between the supported languages (see
 *     NOVA3_MULTI_LANGUAGES) without any reconfiguration, and every word
 *     carries the language it was spoken in.
 *   - diarize_model=latest → streaming speaker diarization; every word carries
 *     the provider's speaker index, which we map 0→speaker_1, 1→speaker_2, …
 *     in order of first appearance and keep stable for the whole session.
 *
 * The client's VAD keeps silence off the wire, so between segments we send
 * KeepAlive frames; on each client segment end we send Finalize so Deepgram
 * flushes a final result immediately instead of waiting for its endpointer.
 */

const DEFAULT_LIVE_URL = 'wss://api.deepgram.com/v1/listen';
const KEEPALIVE_INTERVAL_MS = 5_000;

/**
 * Languages nova-3 currently code-switches between on a language=multi
 * stream. This is a provider limitation, kept explicit on purpose: a word
 * tagged with anything outside this set is not a documented capability of the
 * stream, so its utterance reports "und" rather than a language claim we
 * cannot back. Update this list (only) when Deepgram's documentation expands
 * multilingual support.
 */
export const NOVA3_MULTI_LANGUAGES: ReadonlySet<string> = new Set([
  'en', // English
  'es', // Spanish
  'fr', // French
  'de', // German
  'hi', // Hindi
  'ru', // Russian
  'pt', // Portuguese
  'ja', // Japanese
  'it', // Italian
  'nl', // Dutch
]);

export interface DeepgramWord {
  word: string;
  punctuated_word?: string;
  start: number;
  end: number;
  confidence: number;
  speaker?: number;
  /** BCP-47 / ISO 639-1 code, present with language=multi. */
  language?: string;
}

interface DeepgramLiveResult {
  type?: string;
  is_final?: boolean;
  speech_final?: boolean;
  from_finalize?: boolean;
  channel?: {
    alternatives?: Array<{
      transcript?: string;
      confidence?: number;
      languages?: string[];
      words?: DeepgramWord[];
    }>;
  };
}

/**
 * Turn one contiguous run of final words into utterances, splitting on
 * provider speaker changes. Pure so it can be unit-tested without a socket.
 *
 * Language and confidence per utterance:
 *   - language: the language the majority of words are tagged with,
 *   - languageConfidence: (majority share) × (mean word confidence) — a one-
 *     word "yes" can be acoustically confident yet still carries the risk that
 *     many languages share it, so the caller applies a stricter floor to very
 *     short utterances before trusting the code.
 */
export function utterancesFromWords(
  words: DeepgramWord[],
  speakerIdFor: (providerSpeaker: number) => string,
): StreamingUtterance[] {
  const utterances: StreamingUtterance[] = [];
  let run: DeepgramWord[] = [];

  const flushRun = (): void => {
    if (run.length === 0) return;
    const text = run
      .map((w) => w.punctuated_word ?? w.word)
      .join(' ')
      .trim();
    if (text) {
      const byLanguage = new Map<string, number>();
      let confidenceSum = 0;
      for (const w of run) {
        confidenceSum += w.confidence;
        if (w.language) byLanguage.set(w.language, (byLanguage.get(w.language) ?? 0) + 1);
      }
      let language = 'und';
      let dominantCount = 0;
      for (const [code, count] of byLanguage) {
        if (count > dominantCount) {
          language = code.split('-')[0]!.toLowerCase();
          dominantCount = count;
        }
      }
      // A tag outside the documented language=multi set is not a capability
      // we can vouch for — report "und" instead of an unverifiable claim.
      if (language !== 'und' && !NOVA3_MULTI_LANGUAGES.has(language)) {
        language = 'und';
        dominantCount = 0;
      }
      const meanConfidence = confidenceSum / run.length;
      const dominantShare = language === 'und' ? 0 : dominantCount / run.length;
      const speaker = run[0]!.speaker;
      utterances.push({
        text,
        language,
        languageConfidence: dominantShare * meanConfidence,
        transcriptionConfidence: meanConfidence,
        speakerId: speaker === undefined ? null : speakerIdFor(speaker),
        startMs: Math.round(run[0]!.start * 1000),
        endMs: Math.round(run[run.length - 1]!.end * 1000),
      });
    }
    run = [];
  };

  for (const word of words) {
    if (run.length > 0 && word.speaker !== run[run.length - 1]!.speaker) flushRun();
    run.push(word);
  }
  flushRun();
  return utterances;
}

class DeepgramLiveSession implements StreamingSpeechSession {
  private ws: WebSocket;
  private open = false;
  private closed = false;
  private readonly sendQueue: Buffer[] = [];
  private pendingFinalizes = 0;
  private keepalive: NodeJS.Timeout;
  private lastAudioSentAt = 0;

  /** Words from is_final results, held until speech_final / Finalize. */
  private finalWords: DeepgramWord[] = [];
  /** Whether the current flush cycle produced any speech. */
  private sawSpeechSinceFinalize = false;

  private readonly speakerIds = new Map<number, string>();

  private utteranceHandler: (utterance: StreamingUtterance) => void = () => undefined;
  private finalizedHandler: (hadSpeech: boolean) => void = () => undefined;
  private errorHandler: (error: Error) => void = () => undefined;

  constructor(
    apiKey: string,
    model: string,
    baseUrl: string,
    private readonly sampleRate: number,
  ) {
    const url = new URL(baseUrl);
    url.searchParams.set('model', model);
    url.searchParams.set('language', 'multi');
    // Current Deepgram guidance for streaming diarization; deliberately not
    // combined with the legacy diarize=true flag.
    url.searchParams.set('diarize_model', 'latest');
    url.searchParams.set('smart_format', 'true');
    url.searchParams.set('encoding', 'linear16');
    url.searchParams.set('sample_rate', String(sampleRate));
    url.searchParams.set('channels', '1');
    // language=multi needs interim results enabled; we only act on finals.
    url.searchParams.set('interim_results', 'true');
    url.searchParams.set('endpointing', '400');

    this.ws = new WebSocket(url, { headers: { Authorization: `Token ${apiKey}` } });
    this.ws.on('open', () => this.handleOpen());
    this.ws.on('message', (data: Buffer) => this.handleMessage(data));
    this.ws.on('close', (code: number) => this.handleClose(code));
    this.ws.on('error', (error: Error) => {
      log.warn('deepgram live socket error', { message: error.message });
      if (!this.closed) this.errorHandler(new Error('Speech stream error'));
    });

    // Silence stays on the phone, so the socket may be audio-idle for long
    // stretches — KeepAlive stops Deepgram's 10s no-audio timeout.
    this.keepalive = setInterval(() => {
      if (this.open && !this.closed && Date.now() - this.lastAudioSentAt > KEEPALIVE_INTERVAL_MS) {
        this.ws.send(JSON.stringify({ type: 'KeepAlive' }));
      }
    }, KEEPALIVE_INTERVAL_MS);
    this.keepalive.unref?.();
  }

  onUtterance(handler: (utterance: StreamingUtterance) => void): void {
    this.utteranceHandler = handler;
  }

  onFinalized(handler: (hadSpeech: boolean) => void): void {
    this.finalizedHandler = handler;
  }

  onError(handler: (error: Error) => void): void {
    this.errorHandler = handler;
  }

  sendAudio(pcm: Buffer): void {
    if (this.closed) return;
    if (!this.open) {
      this.sendQueue.push(pcm);
      return;
    }
    this.lastAudioSentAt = Date.now();
    this.ws.send(pcm);
  }

  finalize(): void {
    if (this.closed) return;
    this.pendingFinalizes += 1;
    if (this.open) this.ws.send(JSON.stringify({ type: 'Finalize' }));
  }

  async close(): Promise<void> {
    if (this.closed) return;
    this.closed = true;
    clearInterval(this.keepalive);
    if (this.open) {
      try {
        this.ws.send(JSON.stringify({ type: 'CloseStream' }));
      } catch {
        // socket already going down — nothing to flush
      }
    }
    this.ws.close();
  }

  private handleOpen(): void {
    this.open = true;
    if (this.closed) {
      this.ws.close();
      return;
    }
    for (const pcm of this.sendQueue) {
      this.lastAudioSentAt = Date.now();
      this.ws.send(pcm);
    }
    this.sendQueue.length = 0;
    for (let i = 0; i < this.pendingFinalizes; i++) {
      this.ws.send(JSON.stringify({ type: 'Finalize' }));
    }
  }

  private handleMessage(data: Buffer): void {
    if (this.closed) return;
    let parsed: DeepgramLiveResult;
    try {
      parsed = JSON.parse(data.toString('utf8')) as DeepgramLiveResult;
    } catch {
      return;
    }
    if (parsed.type !== 'Results') return;

    const alternative = parsed.channel?.alternatives?.[0];
    if (parsed.is_final && alternative?.words?.length) {
      this.finalWords.push(...alternative.words);
    }

    // An utterance is complete on Deepgram's own endpointing (speech_final)
    // or when we forced a flush at a client segment boundary (from_finalize).
    if (parsed.speech_final || parsed.from_finalize) {
      this.flushUtterances();
    }
    if (parsed.from_finalize) {
      this.pendingFinalizes = Math.max(0, this.pendingFinalizes - 1);
      this.finalizedHandler(this.sawSpeechSinceFinalize);
      this.sawSpeechSinceFinalize = false;
    }
  }

  private flushUtterances(): void {
    const words = this.finalWords;
    this.finalWords = [];
    const utterances = utterancesFromWords(words, (speaker) => {
      let id = this.speakerIds.get(speaker);
      if (!id) {
        id = `speaker_${this.speakerIds.size + 1}`;
        this.speakerIds.set(speaker, id);
      }
      return id;
    });
    for (const utterance of utterances) {
      this.sawSpeechSinceFinalize = true;
      this.utteranceHandler(utterance);
    }
  }

  private handleClose(code: number): void {
    clearInterval(this.keepalive);
    if (this.closed) return;
    this.closed = true;
    log.warn('deepgram live socket closed unexpectedly', { code });
    this.errorHandler(new Error(`Speech stream closed (${code})`));
  }
}

export class DeepgramStreamingSpeechProvider implements StreamingSpeechProvider {
  readonly name = 'deepgram';

  constructor(
    private readonly apiKey: string,
    private readonly model: string = 'nova-3',
    private readonly baseUrl: string = DEFAULT_LIVE_URL,
  ) {
    if (!apiKey) throw new Error('SPEECH_API_KEY is required for the deepgram speech provider');
  }

  createSession(options: { sampleRate: number }): StreamingSpeechSession {
    return new DeepgramLiveSession(this.apiKey, this.model, this.baseUrl, options.sampleRate);
  }
}
