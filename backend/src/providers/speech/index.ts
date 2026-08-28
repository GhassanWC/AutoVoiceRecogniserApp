import { env } from '../../config/env';
import { DeepgramSpeechProvider } from './deepgram';
import { MockSpeechProvider } from './mock';
import { OpenAISpeechProvider } from './openai';
import { SpeechRecognitionProvider } from './types';

export * from './types';

export function createSpeechProvider(): SpeechRecognitionProvider {
  switch (env.SPEECH_PROVIDER) {
    case 'openai':
      return new OpenAISpeechProvider(env.SPEECH_API_KEY, env.SPEECH_MODEL || 'whisper-1');
    case 'deepgram':
      return new DeepgramSpeechProvider(env.SPEECH_API_KEY, env.SPEECH_MODEL || 'nova-2');
    case 'mock':
    default:
      return new MockSpeechProvider();
  }
}
