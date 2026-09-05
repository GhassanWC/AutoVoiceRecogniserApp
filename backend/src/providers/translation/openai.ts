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
 * Parse the model's structured reply. Exported for unit tests.
 * Tolerates code fences and stray text around the JSON object; an unusable
 * reply throws a retryable error (the next attempt usually returns valid JSON).
 */
export function parseTranslationResponse(content: string): {
  sourceLanguage: string;
  translatedText: string;
} {
  const match = content.match(/\{[\s\S]*\}/);
  if (match) {
    try {
      const parsed = JSON.parse(match[0]) as { sourceLanguage?: unknown; translatedText?: unknown };
      const translatedText =
        typeof parsed.translatedText === 'string' ? parsed.translatedText.trim() : '';
      if (translatedText) {
        const rawLanguage =
          typeof parsed.sourceLanguage === 'string' ? parsed.sourceLanguage.trim().toLowerCase() : '';
        const sourceLanguage = /^[a-z]{2,3}$/.test(rawLanguage) ? rawLanguage : 'und';
        return { sourceLanguage, translatedText };
      }
    } catch {
      // fall through to the error below
    }
  }
  throw new TranslationProviderError('Translation provider returned an unparseable result', true);
}

/**
 * LLM-based translation AND authoritative language detection. The speech
 * provider does not decide the source language — this model reads the actual
 * text and returns {sourceLanguage, translatedText} as structured JSON. An
 * LLM also handles slang and code-switching ("Habibi, let's go mañana")
 * better than literal MT engines.
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
      'You are the translation engine of a live conversation translator.',
      `Target language: ISO 639-1 code "${request.targetLanguage}".`,
      // Upstream language labels can be wrong, so they are deliberately not
      // passed here — the text itself is the only trustworthy signal.
      'Detect the input language yourself from the text.',
      'Reply with ONLY a JSON object, no other text:',
      '{"sourceLanguage": "<ISO 639-1 code of the input language, or \\"und\\" if genuinely unsure>", "translatedText": "<the translation>"}',
      'Translation rules:',
      '- Translate meaning naturally, not word-for-word. Keep the register (casual stays casual).',
      '- Sentences may mix languages; translate all of it into the target language.',
      '- If the text is already entirely in the target language, return it unchanged, phrased naturally.',
      '- Do not translate personal names or brand names unless a well-known localized form exists.',
      '- Keep numbers, place names, currencies and dates accurate.',
      '- Even when sourceLanguage is "und", translatedText must still contain the translation.',
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
          response_format: { type: 'json_object' },
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
      // Surface OpenAI's own error type/message (never contains the key) so
      // "why is every translation failing" is answerable from the logs.
      const body = await response.text().catch(() => '');
      let detail = '';
      try {
        const parsed = JSON.parse(body) as { error?: { type?: string; code?: string; message?: string } };
        detail = [parsed.error?.type, parsed.error?.code, parsed.error?.message]
          .filter(Boolean)
          .join(' / ');
      } catch {
        detail = body.slice(0, 200);
      }
      const retryable = isRetryableStatus(response.status);
      log.error('openai translation failed', { status: response.status, retryable, detail });
      throw new TranslationProviderError(
        `Translation provider error (HTTP ${response.status}${detail ? `: ${detail}` : ''})`,
        retryable,
        response.status,
      );
    }

    const json = (await response.json()) as {
      choices?: Array<{ message?: { content?: string } }>;
    };
    const content = json.choices?.[0]?.message?.content ?? '';
    const parsed = parseTranslationResponse(content);
    log.debug('openai translation ok', {
      latencyMs: Date.now() - started,
      inputLength: request.text.length,
      outputLength: parsed.translatedText.length,
      sourceLanguage: parsed.sourceLanguage,
    });
    return parsed;
  }
}
