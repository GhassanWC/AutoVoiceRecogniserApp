import { env } from '../../config/env';
import { GoogleTranslationProvider } from './google';
import { MockTranslationProvider } from './mock';
import { OpenAITranslationProvider } from './openai';
import {
  OpenAIRealtimeTranslationProvider,
  RealtimeTranslationProvider,
} from './openai_realtime_translate';
import { TranslationProvider } from './types';

export * from './types';
export type { RealtimeTranslationProvider, RealtimeTranslationSession } from './openai_realtime_translate';

/** Text translator — used by the fallback (STT → text translation) pipeline. */
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

/**
 * The PRIMARY live path: gpt-realtime-translate (speech in → translated text
 * deltas out, one socket per session, automatic source language). null when
 * the configured translation provider has no realtime mode — live sessions
 * then use the fallback STT → text-translation pipeline.
 */
export function createRealtimeTranslationProvider(): RealtimeTranslationProvider | null {
  switch (env.TRANSLATION_PROVIDER) {
    case 'openai':
      return new OpenAIRealtimeTranslationProvider(
        env.TRANSLATION_API_KEY,
        env.REALTIME_TRANSLATION_MODEL || 'gpt-realtime-translate',
      );
    default:
      return null;
  }
}
