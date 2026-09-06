import express from 'express';
import { createServer } from 'http';
import { env } from './config/env';
import { errorHandler } from './middleware/error';
import { rateLimit } from './middleware/rateLimit';
import { authRouter } from './modules/auth/auth.router';
import { attachRealtimeServer } from './modules/realtime/realtime.server';
import { translationRouter } from './modules/sessions/sessions.router';
import { usersRouter } from './modules/users/users.router';
import { createSpeechProvider, createStreamingSpeechProvider } from './providers/speech';
import {
  createRealtimeTranslationProvider,
  createTranslationProvider,
} from './providers/translation';
import {
  createMetadataTranscriber,
  createModelLanguageDetector,
} from './utils/language_detect';
import { log } from './utils/logger';

const app = express();
app.disable('x-powered-by');
app.use(express.json({ limit: '64kb' }));

app.get('/health', (_req, res) => {
  res.json({ ok: true, uptime: process.uptime() });
});

app.use('/auth', rateLimit(30, 60_000), authRouter);
app.use('/user', rateLimit(120, 60_000), usersRouter);
app.use('/translation', rateLimit(120, 60_000), translationRouter);

app.use(errorHandler);

const httpServer = createServer(app);

const speech = createSpeechProvider();
const streamingSpeech = createStreamingSpeechProvider();
const translation = createTranslationProvider();
const realtimeTranslation = createRealtimeTranslationProvider();
// Source-language LABEL metadata for Latin-script text (script analysis
// covers the rest) — a few tokens per utterance, never in the delta path.
const languageDetector =
  env.TRANSLATION_PROVIDER === 'openai' && env.TRANSLATION_API_KEY
    ? createModelLanguageDetector(env.TRANSLATION_API_KEY)
    : null;
// Audio-based language ID (gpt-4o-mini-transcribe on a ≤4 s snippet) for
// utterances where the realtime session omitted the source transcript.
const metadataTranscriber =
  env.TRANSLATION_PROVIDER === 'openai' && env.TRANSLATION_API_KEY
    ? createMetadataTranscriber(env.TRANSLATION_API_KEY)
    : null;
attachRealtimeServer(httpServer, {
  speech,
  streamingSpeech,
  translation,
  realtimeTranslation,
  languageDetector,
  metadataTranscriber,
});

httpServer.listen(env.PORT, () => {
  log.info('backend listening', {
    port: env.PORT,
    liveTranslation: realtimeTranslation
      ? realtimeTranslation.name
      : 'none (STT + text translation fallback)',
    speechProvider: speech.name,
    streamingSpeech: streamingSpeech ? streamingSpeech.name : 'none (batch per segment)',
    translationProvider: translation.name,
    diarization: env.DIARIZATION_PROVIDER,
  });
});
