import { env } from '../../config/env';
import { DeepgramSpeechProvider } from './deepgram';
import { DeepgramStreamingSpeechProvider } from './deepgram_stream';
import { MockSpeechProvider } from './mock';
import { OpenAISpeechProvider } from './openai';
import { OpenAIRealtimeSpeechProvider } from './openai_realtime';
import { SpeechRecognitionProvider, StreamingSpeechProvider } from './types';

export * from './types';

/** Batch (per-segment WAV) recognizer — the fallback path. */
export function createSpeechProvider(): SpeechRecognitionProvider {
  switch (env.SPEECH_PROVIDER) {
    case 'openai':
      // whisper-1 for the batch fallback regardless of SPEECH_MODEL: that env
      // var selects the realtime model, which is not a /audio/transcriptions
      // batch model.
      return new OpenAISpeechProvider(env.SPEECH_API_KEY, 'whisper-1');
    case 'deepgram':
      return new DeepgramSpeechProvider(env.SPEECH_API_KEY, 'nova-3');
    case 'mock':
    default:
      return new MockSpeechProvider();
  }
}

/**
 * The streaming recognizer for live sessions — the PRODUCTION path — or null
 * when the configured provider has no streaming mode (LiveSession then uses
 * the per-segment batch pipeline above).
 *
 * Production MVP: openai (gpt-4o-transcribe-diarize realtime, far-field noise
 * reduction, no source-language configuration). Deepgram remains available
 * behind the same abstraction but is not required.
 */
export function createStreamingSpeechProvider(): StreamingSpeechProvider | null {
  switch (env.SPEECH_PROVIDER) {
    case 'openai':
      return new OpenAIRealtimeSpeechProvider(
        env.SPEECH_API_KEY,
        env.SPEECH_MODEL || 'gpt-4o-transcribe-diarize',
      );
    case 'deepgram':
      return new DeepgramStreamingSpeechProvider(env.SPEECH_API_KEY, env.SPEECH_MODEL || 'nova-3');
    default:
      return null;
  }
}
