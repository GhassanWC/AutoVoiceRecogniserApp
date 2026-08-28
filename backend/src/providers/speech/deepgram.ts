import { log } from '../../utils/logger';
import { SpeechRecognitionProvider, TranscriptionRequest, TranscriptionResult } from './types';

interface DeepgramResponse {
  results?: {
    channels?: Array<{
      detected_language?: string;
      language_confidence?: number;
      alternatives?: Array<{ transcript?: string; confidence?: number }>;
    }>;
  };
}

/**
 * Deepgram pre-recorded transcription with automatic language detection
 * (detect_language=true). Fast enough for short segments to feel live.
 */
export class DeepgramSpeechProvider implements SpeechRecognitionProvider {
  readonly name = 'deepgram';

  constructor(
    private readonly apiKey: string,
    private readonly model: string = 'nova-2',
  ) {
    if (!apiKey) throw new Error('SPEECH_API_KEY is required for the deepgram speech provider');
  }

  async transcribe(request: TranscriptionRequest): Promise<TranscriptionResult> {
    const url = new URL('https://api.deepgram.com/v1/listen');
    url.searchParams.set('model', this.model);
    url.searchParams.set('detect_language', 'true');
    url.searchParams.set('smart_format', 'true');

    const started = Date.now();
    const response = await fetch(url, {
      method: 'POST',
      headers: {
        Authorization: `Token ${this.apiKey}`,
        'Content-Type': 'audio/wav',
      },
      body: new Uint8Array(request.wav),
    });

    if (!response.ok) {
      const body = await response.text().catch(() => '');
      log.error('deepgram transcription failed', { status: response.status, bodyLength: body.length });
      throw new Error(`Speech provider error (${response.status})`);
    }

    const json = (await response.json()) as DeepgramResponse;
    const channel = json.results?.channels?.[0];
    const alternative = channel?.alternatives?.[0];

    log.debug('deepgram transcription ok', {
      latencyMs: Date.now() - started,
      audioMs: request.durationMs,
      language: channel?.detected_language,
      textLength: (alternative?.transcript ?? '').length,
    });

    return {
      text: (alternative?.transcript ?? '').trim(),
      language: channel?.detected_language ?? 'und',
      languageConfidence: channel?.language_confidence ?? 0,
      transcriptionConfidence: alternative?.confidence ?? 0,
    };
  }
}
