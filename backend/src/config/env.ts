import dotenv from 'dotenv';
import { z } from 'zod';

dotenv.config();

const schema = z.object({
  PORT: z.coerce.number().int().positive().default(8080),
  JWT_SECRET: z.string().min(1).default('change-me-in-production'),
  LOG_LEVEL: z.enum(['debug', 'info', 'warn', 'error']).default('info'),

  DATABASE_URL: z.string().url().optional(),

  SPEECH_PROVIDER: z.enum(['mock', 'openai', 'deepgram']).default('mock'),
  SPEECH_API_KEY: z.string().optional().default(''),
  SPEECH_MODEL: z.string().optional().default(''),

  TRANSLATION_PROVIDER: z.enum(['mock', 'openai', 'google']).default('mock'),
  TRANSLATION_API_KEY: z.string().optional().default(''),
  TRANSLATION_MODEL: z.string().optional().default(''),

  DIARIZATION_PROVIDER: z.enum(['heuristic', 'none']).default('heuristic'),

  MAX_SESSION_MINUTES: z.coerce.number().positive().default(120),
  FREE_MONTHLY_MINUTES: z.coerce.number().min(0).default(60),
  MAX_SEGMENT_SECONDS: z.coerce.number().positive().default(30),
});

const parsed = schema.safeParse(process.env);
if (!parsed.success) {
  // eslint-disable-next-line no-console
  console.error('Invalid environment configuration:', parsed.error.flatten().fieldErrors);
  process.exit(1);
}

export const env = parsed.data;

export const isProduction = process.env.NODE_ENV === 'production';

if (isProduction && env.JWT_SECRET === 'change-me-in-production') {
  // eslint-disable-next-line no-console
  console.error('Refusing to start in production with the default JWT_SECRET.');
  process.exit(1);
}
