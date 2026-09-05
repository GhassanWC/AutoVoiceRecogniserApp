export interface ConversationTurn {
  sourceLanguage: string;
  originalText: string;
  translatedText: string;
}

export interface TranslationRequest {
  text: string;
  /** ISO 639-1 source code, or "und" when detection confidence was too low. */
  sourceLanguage: string;
  targetLanguage: string;
  /**
   * A small rolling window of recent turns (oldest first) so pronouns and
   * references ("Where is it?") translate correctly. Never the full history.
   */
  context?: ConversationTurn[];
}

export interface TranslationResult {
  translatedText: string;
  /**
   * ISO 639-1 code the TRANSLATOR detected from the text itself ("und" when
   * unsure). When present this is the authoritative source language — speech
   * providers' language labels are only provisional metadata.
   */
  sourceLanguage?: string;
}

/**
 * Thrown by providers so callers can tell transient failures (worth retrying:
 * network errors, timeouts, 408/429/5xx) from permanent ones (bad API key,
 * malformed request) without parsing error messages.
 */
export class TranslationProviderError extends Error {
  constructor(
    message: string,
    readonly retryable: boolean,
    readonly status?: number,
  ) {
    super(message);
    this.name = 'TranslationProviderError';
  }
}

const RETRYABLE_STATUSES = new Set([408, 429, 500, 502, 503, 504]);

export function isRetryableStatus(status: number): boolean {
  return RETRYABLE_STATUSES.has(status);
}

export interface TranslationProvider {
  readonly name: string;
  translate(request: TranslationRequest): Promise<TranslationResult>;
}
