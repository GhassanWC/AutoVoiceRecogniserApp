import { WebSocket } from 'ws';
import { resamplePcm16 } from '../../utils/audio';
import { log } from '../../utils/logger';
import { StreamingSpeechProvider, StreamingSpeechSession, StreamingUtterance } from './types';

/**
 * OpenAI realtime transcription (production MVP speech path).
 *
 * One WebSocket per listening session:
 *   - model gpt-4o-transcribe-diarize — multilingual transcription with
 *     speaker diarization; NO input language is configured, the model
 *     transcribes whatever language it hears (Arabic, Thai, … included — there
 *     is deliberately no source-language allowlist on this path);
 *   - noise_reduction far_field — this product listens to a room (people at a
 *     distance, TV audio), not someone speaking into the handset;
 *   - server turn detection is DISABLED: the phone's VAD segments speech, and
 *     each client segment end commits the audio buffer, which finalizes one
 *     transcription — the exact Finalize semantics LiveSession expects.
 *
 * Language identification is intentionally NOT this provider's job: every
 * utterance reports language "und" and the translation stage (which sees the
 * actual text) is the authoritative language detector.
 */

const REALTIME_URL = 'wss://api.openai.com/v1/realtime?intent=transcription';
const REALTIME_SAMPLE_RATE = 24_000;
/** OpenAI rejects commits of less than ~100 ms of audio; stay safely above. */
const MIN_COMMIT_BYTES = (REALTIME_SAMPLE_RATE * 2 * 200) / 1000;

export interface RealtimeSegment {
  itemId: string;
  /** Provider speaker label (e.g. "A", "spk_0"); undefined when not diarized. */
  speaker?: string;
  text: string;
  startMs: number;
  endMs: number;
}

/**
 * Group a completed item's diarized segments into utterances, splitting on
 * speaker changes; without segments, the plain transcript becomes one
 * utterance with no speaker. Pure, for unit tests.
 */
export function utterancesFromRealtime(
  segments: RealtimeSegment[],
  fallbackTranscript: string,
  speakerIdFor: (providerSpeaker: string) => string,
): StreamingUtterance[] {
  const base = {
    language: 'und', // the translation stage detects the language from text
    languageConfidence: 0,
    transcriptionConfidence: 0,
  };

  if (segments.length === 0) {
    const text = fallbackTranscript.trim();
    if (!text) return [];
    return [{ ...base, text, speakerId: null, startMs: 0, endMs: 0 }];
  }

  const utterances: StreamingUtterance[] = [];
  let run: RealtimeSegment[] = [];
  const flush = (): void => {
    if (run.length === 0) return;
    const text = run
      .map((s) => s.text)
      .join(' ')
      .replace(/\s+/g, ' ')
      .trim();
    if (text) {
      const speaker = run[0]!.speaker;
      utterances.push({
        ...base,
        text,
        speakerId: speaker === undefined ? null : speakerIdFor(speaker),
        startMs: run[0]!.startMs,
        endMs: run[run.length - 1]!.endMs,
      });
    }
    run = [];
  };
  for (const segment of segments) {
    if (run.length > 0 && segment.speaker !== run[run.length - 1]!.speaker) flush();
    run.push(segment);
  }
  flush();
  return utterances;
}

interface RealtimeEvent {
  type?: string;
  item_id?: string;
  transcript?: string;
  text?: string;
  speaker?: string;
  start?: number;
  end?: number;
  error?: { type?: string; code?: string; message?: string };
}

class OpenAIRealtimeSession implements StreamingSpeechSession {
  private ws: WebSocket;
  private open = false;
  private closed = false;
  private readonly sendQueue: string[] = [];

  /** Diarized segment events buffered until their item completes. */
  private segments: RealtimeSegment[] = [];
  private bytesSinceCommit = 0;
  private readonly speakerIds = new Map<string, string>();

  private utteranceHandler: (utterance: StreamingUtterance) => void = () => undefined;
  private finalizedHandler: (hadSpeech: boolean) => void = () => undefined;
  private errorHandler: (error: Error) => void = () => undefined;

  constructor(
    apiKey: string,
    private readonly model: string,
    private readonly inputSampleRate: number,
    baseUrl: string = REALTIME_URL,
  ) {
    this.ws = new WebSocket(baseUrl, {
      headers: { Authorization: `Bearer ${apiKey}`, 'OpenAI-Beta': 'realtime=v1' },
    });
    this.ws.on('open', () => this.handleOpen());
    this.ws.on('message', (data: Buffer) => this.handleMessage(data));
    this.ws.on('close', (code: number) => this.handleClose(code));
    this.ws.on('error', (error: Error) => {
      log.warn('openai realtime socket error', { message: error.message });
      if (!this.closed) this.errorHandler(new Error('Speech stream error'));
    });
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
    const resampled = resamplePcm16(pcm, this.inputSampleRate, REALTIME_SAMPLE_RATE);
    this.bytesSinceCommit += resampled.length;
    this.sendJson({ type: 'input_audio_buffer.append', audio: resampled.toString('base64') });
  }

  finalize(): void {
    if (this.closed) return;
    if (this.bytesSinceCommit < MIN_COMMIT_BYTES) {
      // Too little audio to commit (OpenAI rejects near-empty buffers) — the
      // segment finalizes locally as "no speech" so the client UI moves on.
      this.finalizedHandler(false);
      return;
    }
    this.bytesSinceCommit = 0;
    this.sendJson({ type: 'input_audio_buffer.commit' });
  }

  async close(): Promise<void> {
    if (this.closed) return;
    this.closed = true;
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
    // Configuration first, then any queued audio. No input language is set —
    // the model transcribes the language it hears, per utterance.
    this.ws.send(
      JSON.stringify({
        type: 'transcription_session.update',
        session: {
          input_audio_format: 'pcm16',
          input_audio_transcription: { model: this.model },
          input_audio_noise_reduction: { type: 'far_field' },
          turn_detection: null, // the phone's VAD owns segmentation
        },
      }),
    );
    this.open = true;
    for (const raw of this.sendQueue) this.ws.send(raw);
    this.sendQueue.length = 0;
  }

  private handleMessage(data: Buffer): void {
    if (this.closed) return;
    let event: RealtimeEvent;
    try {
      event = JSON.parse(data.toString('utf8')) as RealtimeEvent;
    } catch {
      return;
    }

    switch (event.type) {
      case 'conversation.item.input_audio_transcription.segment':
        this.segments.push({
          itemId: event.item_id ?? '',
          speaker: event.speaker,
          text: event.text ?? '',
          startMs: Math.round((event.start ?? 0) * 1000),
          endMs: Math.round((event.end ?? 0) * 1000),
        });
        break;

      case 'conversation.item.input_audio_transcription.completed': {
        const itemSegments = this.segments.filter(
          (s) => !event.item_id || s.itemId === event.item_id,
        );
        this.segments = this.segments.filter((s) => event.item_id && s.itemId !== event.item_id);
        const utterances = utterancesFromRealtime(
          itemSegments,
          event.transcript ?? '',
          (speaker) => {
            let id = this.speakerIds.get(speaker);
            if (!id) {
              id = `speaker_${this.speakerIds.size + 1}`;
              this.speakerIds.set(speaker, id);
            }
            return id;
          },
        );
        for (const utterance of utterances) this.utteranceHandler(utterance);
        this.finalizedHandler(utterances.length > 0);
        break;
      }

      case 'conversation.item.input_audio_transcription.failed':
        log.warn('openai realtime transcription item failed', {
          message: event.error?.message,
        });
        this.finalizedHandler(false);
        break;

      case 'error':
        // Some errors are per-request (e.g. a rejected commit) — log them and
        // keep the session; the socket-level close handler covers fatal ones.
        log.warn('openai realtime error event', {
          code: event.error?.code,
          message: event.error?.message,
        });
        break;

      default:
        break; // deltas, commit acks, session acks — not needed
    }
  }

  private handleClose(code: number): void {
    if (this.closed) return;
    this.closed = true;
    log.warn('openai realtime socket closed unexpectedly', { code });
    this.errorHandler(new Error(`Speech stream closed (${code})`));
  }
}

export class OpenAIRealtimeSpeechProvider implements StreamingSpeechProvider {
  readonly name = 'openai-realtime';

  constructor(
    private readonly apiKey: string,
    private readonly model: string = 'gpt-4o-transcribe-diarize',
    private readonly baseUrl: string = REALTIME_URL,
  ) {
    if (!apiKey) throw new Error('SPEECH_API_KEY is required for the openai speech provider');
  }

  createSession(options: { sampleRate: number }): StreamingSpeechSession {
    return new OpenAIRealtimeSession(this.apiKey, this.model, options.sampleRate, this.baseUrl);
  }
}
