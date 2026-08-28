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
}

export interface TranslationProvider {
  readonly name: string;
  translate(request: TranslationRequest): Promise<TranslationResult>;
}
