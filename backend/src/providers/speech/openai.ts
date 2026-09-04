import { log } from '../../utils/logger';
import { SpeechRecognitionProvider, TranscriptionRequest, TranscriptionResult } from './types';

/**
 * OpenAI speech-to-text (Whisper family). Uses verbose_json so the detected
 * language comes back with the transcript; Whisper auto-detects the spoken
 * language per request, which is exactly the per-segment behavior we need.
 */

/** Whisper reports full language names; map the common ones to ISO 639-1. */
const LANGUAGE_NAME_TO_ISO: Record<string, string> = {
  english: 'en', spanish: 'es', french: 'fr', german: 'de', italian: 'it',
  portuguese: 'pt', dutch: 'nl', russian: 'ru', arabic: 'ar', hebrew: 'he',
  turkish: 'tr', persian: 'fa', urdu: 'ur', hindi: 'hi', bengali: 'bn',
  chinese: 'zh', japanese: 'ja', korean: 'ko', thai: 'th', vietnamese: 'vi',
  indonesian: 'id', malay: 'ms', tagalog: 'tl', swahili: 'sw', greek: 'el',
  polish: 'pl', czech: 'cs', slovak: 'sk', ukrainian: 'uk', romanian: 'ro',
  hungarian: 'hu', swedish: 'sv', norwegian: 'no', danish: 'da', finnish: 'fi',
};

function toIso(language: string): string {
  const lower = language.trim().toLowerCase();
  if (lower.length === 2) return lower;
  return LANGUAGE_NAME_TO_ISO[lower] ?? 'und';
}

export class OpenAISpeechProvider implements SpeechRecognitionProvider {
  readonly name = 'openai';

  constructor(
    private readonly apiKey: string,
    private readonly model: string = 'whisper-1',
  ) {
    if (!apiKey) throw new Error('SPEECH_API_KEY is required for the openai speech provider');
  }

  async transcribe(request: TranscriptionRequest): Promise<TranscriptionResult> {
    const form = new FormData();
    form.append('file', new Blob([new Uint8Array(request.wav)], { type: 'audio/wav' }), 'segment.wav');
    form.append('model', this.model);
    form.append('response_format', 'verbose_json');

    const started = Date.now();
    const response = await fetch('https://api.openai.com/v1/audio/transcriptions', {
      method: 'POST',
      headers: { Authorization: `Bearer ${this.apiKey}` },
      body: form,
    });

    if (!response.ok) {
      const body = await response.text().catch(() => '');
      log.error('openai transcription failed', { status: response.status, bodyLength: body.length });
      throw new Error(`Speech provider error (${response.status})`);
    }

    const json = (await response.json()) as { text?: string; language?: string };
    log.debug('openai transcription ok', {
      latencyMs: Date.now() - started,
      audioMs: request.durationMs,
      language: json.language,
      textLength: (json.text ?? '').length,
    });

    const text = (json.text ?? '').trim();
    // verbose_json does not expose numeric confidences; treat a non-empty
    // result as reasonably confident and let the UI soften the label. Very
    // short snippets ("yes", "okay") exist in many languages, so Whisper's
    // language guess for them is not trustworthy — report low confidence and
    // let the pipeline's short-utterance gate map it to "und".
    const shortSnippet = text.split(/\s+/).filter(Boolean).length <= 2;
    return {
      text,
      language: toIso(json.language ?? 'und'),
      languageConfidence: json.language ? (shortSnippet ? 0.5 : 0.85) : 0,
      transcriptionConfidence: text ? 0.85 : 0,
    };
  }
}
