import { log } from '../../utils/logger';
import { TranslationProvider, TranslationRequest, TranslationResult } from './types';

/** Google Cloud Translation v2 (API-key based). */
export class GoogleTranslationProvider implements TranslationProvider {
  readonly name = 'google';

  constructor(private readonly apiKey: string) {
    if (!apiKey) throw new Error('TRANSLATION_API_KEY is required for the google translation provider');
  }

  async translate(request: TranslationRequest): Promise<TranslationResult> {
    const url = new URL('https://translation.googleapis.com/language/translate/v2');
    url.searchParams.set('key', this.apiKey);

    const body: Record<string, string> = {
      q: request.text,
      target: request.targetLanguage,
      format: 'text',
    };
    if (request.sourceLanguage && request.sourceLanguage !== 'und') {
      body.source = request.sourceLanguage;
    }

    const started = Date.now();
    const response = await fetch(url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    });

    if (!response.ok) {
      const text = await response.text().catch(() => '');
      log.error('google translation failed', { status: response.status, bodyLength: text.length });
      throw new Error(`Translation provider error (${response.status})`);
    }

    const json = (await response.json()) as {
      data?: { translations?: Array<{ translatedText?: string }> };
    };
    const translatedText = json.data?.translations?.[0]?.translatedText ?? '';
    log.debug('google translation ok', {
      latencyMs: Date.now() - started,
      inputLength: request.text.length,
      outputLength: translatedText.length,
    });

    if (!translatedText) throw new Error('Translation provider returned an empty result');
    return { translatedText };
  }
}
