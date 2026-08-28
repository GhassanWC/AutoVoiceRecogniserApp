import { log } from '../../utils/logger';
import { TranslationProvider, TranslationRequest, TranslationResult } from './types';

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
    const source =
      request.sourceLanguage && request.sourceLanguage !== 'und'
        ? `The speaker is probably speaking "${request.sourceLanguage}", but trust the text itself if it disagrees.`
        : 'Detect the source language yourself.';

    const contextLines = (request.context ?? [])
      .map((turn) => `- (${turn.sourceLanguage}) ${turn.originalText}`)
      .join('\n');

    const system = [
      `You translate live conversation snippets into the language with ISO 639-1 code "${request.targetLanguage}".`,
      source,
      'Translate meaning, not word-for-word. Keep the register (casual stays casual).',
      'Sentences may mix languages; translate all of it into the target language.',
      'Do not translate personal names. Keep numbers, currencies and dates accurate.',
      'Output ONLY the translation — no quotes, no explanations, no source text.',
      contextLines
        ? `Recent conversation, for resolving references only (do not re-translate it):\n${contextLines}`
        : '',
    ]
      .filter(Boolean)
      .join('\n');

    const started = Date.now();
    const response = await fetch('https://api.openai.com/v1/chat/completions', {
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
    });

    if (!response.ok) {
      const body = await response.text().catch(() => '');
      log.error('openai translation failed', { status: response.status, bodyLength: body.length });
      throw new Error(`Translation provider error (${response.status})`);
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

    if (!translatedText) throw new Error('Translation provider returned an empty result');
    return { translatedText };
  }
}
