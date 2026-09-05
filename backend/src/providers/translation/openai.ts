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
 * Incremental parser for the streaming reply protocol: the model's FIRST line
 * is the ISO 639-1 language code it detected, everything after the first
 * newline is the translation itself. push() returns only display-text deltas
 * (never the language prefix), so the UI can render chunks as they arrive.
 * Exported for unit tests.
 */
export function createLanguagePrefixParser(): {
  push: (chunk: string) => string;
  language: () => string;
  text: () => string;
} {
  let prefix = '';
  let prefixDone = false;
  let text = '';
  return {
    push(chunk: string): string {
      if (prefixDone) {
        text += chunk;
        return chunk;
      }
      const newline = chunk.indexOf('\n');
      if (newline < 0) {
        prefix += chunk;
        return '';
      }
      prefix += chunk.slice(0, newline);
      prefixDone = true;
      const rest = chunk.slice(newline + 1);
      text += rest;
      return rest;
    },
    language(): string {
      const cleaned = prefix.trim().toLowerCase().replace(/[^a-z]/g, '');
      return /^[a-z]{2,3}$/.test(cleaned) ? cleaned : 'und';
    },
    text(): string {
      // A reply with no newline at all is treated as translation-only.
      return (prefixDone ? text : prefix).trim();
    },
  };
}

/**
 * LLM-based translation AND authoritative language detection. The speech
 * provider does not decide the source language — this model reads the actual
 * text and returns {sourceLanguage, translatedText} as structured JSON (batch)
 * or a language-prefix stream (translateStream). An LLM also handles slang
 * and code-switching ("Habibi, let's go mañana") better than literal MT
 * engines.
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

  /**
   * Streaming translation for live subtitles: display-text chunks reach
   * onDelta the moment the model emits them. Reply protocol: first line is
   * the detected ISO 639-1 code (kept out of the deltas), the rest is ONLY
   * the translation.
   */
  async translateStream(
    request: TranslationRequest,
    onDelta: (delta: string) => void,
  ): Promise<TranslationResult> {
    const contextLines = (request.context ?? [])
      .map((turn) => `- (${turn.sourceLanguage}) ${turn.originalText}`)
      .join('\n');

    const system = [
      'You are the translation engine of a live conversation translator.',
      `Target language: ISO 639-1 code "${request.targetLanguage}".`,
      'Detect the input language yourself from the text.',
      'Reply in EXACTLY this format:',
      'Line 1: the ISO 639-1 code of the input language (or und if genuinely unsure).',
      'From line 2: ONLY the translation — no quotes, no explanations, no source text.',
      'Translation rules:',
      '- Translate meaning naturally, not word-for-word. Keep the register (casual stays casual).',
      '- Sentences may mix languages; translate all of it into the target language.',
      '- If the text is already entirely in the target language, return it unchanged, phrased naturally.',
      '- Do not translate personal names or brand names unless a well-known localized form exists.',
      '- Keep numbers, place names, currencies and dates accurate.',
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
          stream: true,
          messages: [
            { role: 'system', content: system },
            { role: 'user', content: request.text },
          ],
        }),
        signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
      });
    } catch (error) {
      const reason = error instanceof Error ? error.message : String(error);
      log.warn('openai translation network error', { reason });
      throw new TranslationProviderError(`Translation network error: ${reason}`, true);
    }

    if (!response.ok || !response.body) {
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

    const parser = createLanguagePrefixParser();
    let firstDeltaMs: number | null = null;
    let buffered = '';
    try {
      const decoder = new TextDecoder();
      for await (const chunk of response.body as unknown as AsyncIterable<Uint8Array>) {
        buffered += decoder.decode(chunk, { stream: true });
        let newline = buffered.indexOf('\n');
        while (newline >= 0) {
          const line = buffered.slice(0, newline).trim();
          buffered = buffered.slice(newline + 1);
          newline = buffered.indexOf('\n');
          if (!line.startsWith('data:')) continue;
          const payload = line.slice(5).trim();
          if (payload === '[DONE]') continue;
          let parsed: { choices?: Array<{ delta?: { content?: string } }> };
          try {
            parsed = JSON.parse(payload) as typeof parsed;
          } catch {
            continue;
          }
          const content = parsed.choices?.[0]?.delta?.content;
          if (!content) continue;
          const display = parser.push(content);
          if (display) {
            if (firstDeltaMs === null) firstDeltaMs = Date.now() - started;
            onDelta(display);
          }
        }
      }
    } catch (error) {
      // A stream that dies mid-response is a transient network problem.
      const reason = error instanceof Error ? error.message : String(error);
      log.warn('openai translation stream interrupted', { reason });
      throw new TranslationProviderError(`Translation stream interrupted: ${reason}`, true);
    }

    const translatedText = parser.text();
    if (!translatedText) {
      throw new TranslationProviderError('Translation provider returned an empty result', true);
    }
    log.debug('openai streaming translation ok', {
      latencyMs: Date.now() - started,
      firstDeltaMs,
      inputLength: request.text.length,
      outputLength: translatedText.length,
      sourceLanguage: parser.language(),
    });
    return { translatedText, sourceLanguage: parser.language() };
  }
}
