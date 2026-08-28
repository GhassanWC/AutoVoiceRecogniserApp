import { env } from '../../config/env';
import { GoogleTranslationProvider } from './google';
import { MockTranslationProvider } from './mock';
import { OpenAITranslationProvider } from './openai';
import { TranslationProvider } from './types';

export * from './types';

export function createTranslationProvider(): TranslationProvider {
  switch (env.TRANSLATION_PROVIDER) {
    case 'openai':
      return new OpenAITranslationProvider(env.TRANSLATION_API_KEY, env.TRANSLATION_MODEL || 'gpt-4o-mini');
    case 'google':
      return new GoogleTranslationProvider(env.TRANSLATION_API_KEY);
    case 'mock':
    default:
      return new MockTranslationProvider();
  }
}
