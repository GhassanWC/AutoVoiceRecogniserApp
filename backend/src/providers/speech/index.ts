import { env } from '../../config/env';
import { DeepgramSpeechProvider } from './deepgram';
import { DeepgramStreamingSpeechProvider } from './deepgram_stream';
import { MockSpeechProvider } from './mock';
import { OpenAISpeechProvider } from './openai';
import { SpeechRecognitionProvider, StreamingSpeechProvider } from './types';

export * from './types';

export function createSpeechProvider(): SpeechRecognitionProvider {
  switch (env.SPEECH_PROVIDER) {
    case 'openai':
      return new OpenAISpeechProvider(env.SPEECH_API_KEY, env.SPEECH_MODEL || 'whisper-1');
    case 'deepgram':
      return new DeepgramSpeechProvider(env.SPEECH_API_KEY, env.SPEECH_MODEL || 'nova-3');
    case 'mock':
    default:
      return new MockSpeechProvider();
  }
}

/**
 * The streaming recognizer for live sessions, or null when the configured
 * provider has no streaming mode — LiveSession then falls back to the
 * per-segment batch pipeline above.
 */
export function createStreamingSpeechProvider(): StreamingSpeechProvider | null {
  switch (env.SPEECH_PROVIDER) {
    case 'deepgram':
      return new DeepgramStreamingSpeechProvider(env.SPEECH_API_KEY, env.SPEECH_MODEL || 'nova-3');
    default:
      return null;
  }
}
