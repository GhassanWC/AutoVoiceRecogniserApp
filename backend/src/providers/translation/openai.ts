import { log } from '../../utils/logger';
import {
  isRetryableStatus,
  TranslationProvider,
  TranslationProviderError,
  TranslationRequest,
  TranslationResult,
} from './types';

/** A hung request must fail fast so the retry ladder can take over. */
const REQUEST_TIMEOUT_MS = 20_000;

/**
 * LLM-based translation. An LLM handles slang, code-switching ("Habibi, let's
 * go mañana") and conversational context better than literal MT engines.
 */
export class OpenAITranslationProvider implements TranslationProvider {
  readonly name = 'openai';

  constructor(
    private readonly apiKey: string,
    private readonly model: string = 'gpt-4o-mini',
  ) {
    if (!apiKey) throw new Error('TRANSLATION_API_KEY is required for the openai translation provider');
  }

  async translate(request: TranslationRequest): Promise<TranslationResult> {
    const contextLines = (request.context ?? [])
      .map((turn) => `- (${turn.sourceLanguage}) ${turn.originalText}`)
      .join('\n');

    const system = [
      `You translate live conversation snippets into the language with ISO 639-1 code "${request.targetLanguage}".`,
      // Upstream language labels can be wrong, so they are deliberately not
      // passed here — the text itself is the only trustworthy signal.
      'Detect the input language yourself from the text.',
      'Translate meaning, not word-for-word. Keep the register (casual stays casual).',
      'Sentences may mix languages; translate all of it into the target language.',
      'If the text is already entirely in the target language, return it unchanged, phrased naturally.',
      'Do not translate personal names or brand names unless a well-known localized form exists.',
      'Keep numbers, place names, currencies and dates accurate.',
      'Output ONLY the translation — no quotes, no explanations, no source text.',
      contextLines
        ? `Recent conversation, for resolving references only (do not re-translate it):\n${contextLines}`
        : '',
    ]
      .filter(Boolean)
      .join('\n');

    const started = Date.now();
    let response: Response;
    try {
      response = await fetch('https://api.openai.com/v1/chat/completions', {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${this.apiKey}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          model: this.model,
          temperature: 0.2,
          messages: [
            { role: 'system', content: system },
            { role: 'user', content: request.text },
          ],
        }),
        signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
      });
    } catch (error) {
      // fetch only throws for network-level problems (DNS, connection reset,
      // abort/timeout) — all transient, all worth retrying.
      const reason = error instanceof Error ? error.message : String(error);
      log.warn('openai translation network error', { reason });
      throw new TranslationProviderError(`Translation network error: ${reason}`, true);
    }

    if (!response.ok) {
      const body = await response.text().catch(() => '');
      const retryable = isRetryableStatus(response.status);
      log.error('openai translation failed', {
        status: response.status,
        retryable,
        bodyLength: body.length,
      });
      throw new TranslationProviderError(
        `Translation provider error (${response.status})`,
        retryable,
        response.status,
      );
    }

    const json = (await response.json()) as {
      choices?: Array<{ message?: { content?: string } }>;
    };
    const translatedText = json.choices?.[0]?.message?.content?.trim() ?? '';
    log.debug('openai translation ok', {
      latencyMs: Date.now() - started,
      inputLength: request.text.length,
      outputLength: translatedText.length,
    });

    if (!translatedText) {
      throw new TranslationProviderError('Translation provider returned an empty result', true);
    }
    return { translatedText };
  }
}
