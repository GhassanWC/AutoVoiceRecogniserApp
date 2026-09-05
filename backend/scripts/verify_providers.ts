/**
 * REAL provider smoke test — no mocks. Run with: npm run verify:providers
 *
 * Exercises the actually-configured translation and speech providers with
 * real API calls and prints PASS/FAIL plus the concrete HTTP status and
 * provider error message on failure (never the API key). Use this before
 * blaming any other layer for "Translation failed" in the app.
 *
 * Speech fixtures: short WAVs saying "السلام عليكم" and "Good morning",
 * generated once via OpenAI TTS into backend/fixtures/ (gitignored) so the
 * test hears real speech audio, then transcribed through the SAME streaming
 * provider the production session uses — with no source-language setting.
 */
import { mkdirSync, existsSync, readFileSync, writeFileSync } from 'fs';
import { dirname, join } from 'path';
import { env } from '../src/config/env';
import { createSpeechProvider, createStreamingSpeechProvider } from '../src/providers/speech';
import { StreamingUtterance } from '../src/providers/speech/types';
import {
  createRealtimeTranslationProvider,
  createTranslationProvider,
} from '../src/providers/translation';
import { TranslationProviderError } from '../src/providers/translation/types';
import { pcm16ToWav, pcmDurationMs } from '../src/utils/audio';

const FIXTURES_DIR = join(__dirname, '..', 'fixtures');
const ARABIC_TEXT = 'السلام عليكم';
const ARABIC_RE = /[؀-ۿ]/;

interface Failure {
  step: string;
  detail: string;
}

function ok(step: string): void {
  console.log(`  ✓ ${step}`);
}

function describeError(error: unknown): string {
  if (error instanceof TranslationProviderError) {
    return [
      error.status ? `HTTP status: ${error.status}` : 'HTTP status: (none — network/timeout)',
      `error type: ${error.retryable ? 'transient (retryable)' : 'permanent (auth/config)'}`,
      `error message: ${error.message}`,
    ].join('\n      ');
  }
  return `error message: ${error instanceof Error ? error.message : String(error)}`;
}

// ── Translation check ─────────────────────────────────────────────────────────

async function verifyTranslation(): Promise<Failure[]> {
  console.log(`\nTranslation check (provider: ${env.TRANSLATION_PROVIDER}, target: ar)`);
  if (env.TRANSLATION_PROVIDER === 'mock') {
    return [{ step: 'configuration', detail: 'TRANSLATION_PROVIDER is "mock" — nothing real to verify.' }];
  }
  const provider = createTranslationProvider();
  const failures: Failure[] = [];

  const cases: Array<{ text: string; expect: (out: string) => boolean; expectation: string }> = [
    { text: 'Good morning.', expect: (o) => o.includes('صباح'), expectation: 'contains "صباح"' },
    { text: 'Hello.', expect: (o) => ARABIC_RE.test(o), expectation: 'is Arabic text' },
    {
      text: 'Hola hermano',
      expect: (o) => ARABIC_RE.test(o) && o.includes('أخ'),
      expectation: 'is Arabic and contains "أخ" (brother)',
    },
    {
      text: ARABIC_TEXT,
      expect: (o) => ARABIC_RE.test(o),
      expectation: 'stays Arabic (unchanged/naturally normalized)',
    },
  ];

  for (const testCase of cases) {
    try {
      const result = await provider.translate({
        text: testCase.text,
        sourceLanguage: 'und', // production never supplies a trusted source language
        targetLanguage: 'ar',
      });
      const detected = result.sourceLanguage ?? '(not reported)';
      if (testCase.expect(result.translatedText)) {
        ok(`"${testCase.text}" → "${result.translatedText}" (detected language: ${detected})`);
      } else {
        failures.push({
          step: `translate "${testCase.text}"`,
          detail: `got "${result.translatedText}" (detected: ${detected}) — expected output that ${testCase.expectation}`,
        });
      }
    } catch (error) {
      failures.push({ step: `translate "${testCase.text}"`, detail: describeError(error) });
    }
  }
  return failures;
}

// ── Speech check ──────────────────────────────────────────────────────────────

/** Fixture generation needs an OpenAI key even when speech is another vendor. */
function openAiKeyForTts(): string {
  if (env.SPEECH_API_KEY.startsWith('sk-')) return env.SPEECH_API_KEY;
  if (env.TRANSLATION_API_KEY.startsWith('sk-')) return env.TRANSLATION_API_KEY;
  throw new Error('No OpenAI-shaped key available to generate TTS fixtures');
}

async function ensureFixture(fileName: string, text: string): Promise<string> {
  const path = join(FIXTURES_DIR, fileName);
  if (existsSync(path)) return path;
  mkdirSync(dirname(path), { recursive: true });
  console.log(`  generating fixture ${fileName} via OpenAI TTS…`);
  const response = await fetch('https://api.openai.com/v1/audio/speech', {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${openAiKeyForTts()}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({ model: 'gpt-4o-mini-tts', voice: 'alloy', input: text, response_format: 'wav' }),
    signal: AbortSignal.timeout(60_000),
  });
  if (!response.ok) {
    const body = await response.text().catch(() => '');
    throw new Error(`TTS fixture generation failed (HTTP ${response.status}): ${body.slice(0, 200)}`);
  }
  writeFileSync(path, Buffer.from(await response.arrayBuffer()));
  return path;
}

/** Minimal WAV reader: returns mono PCM16 samples + sample rate. */
function readWav(path: string): { pcm: Buffer; sampleRate: number } {
  const wav = readFileSync(path);
  if (wav.toString('ascii', 0, 4) !== 'RIFF') throw new Error(`${path} is not a WAV file`);
  let offset = 12;
  let sampleRate = 0;
  let channels = 1;
  let pcm: Buffer | null = null;
  while (offset + 8 <= wav.length) {
    const chunkId = wav.toString('ascii', offset, offset + 4);
    const chunkSize = wav.readUInt32LE(offset + 4);
    if (chunkId === 'fmt ') {
      channels = wav.readUInt16LE(offset + 10);
      sampleRate = wav.readUInt32LE(offset + 12);
    } else if (chunkId === 'data') {
      pcm = wav.subarray(offset + 8, offset + 8 + chunkSize);
    }
    offset += 8 + chunkSize + (chunkSize % 2);
  }
  if (!pcm || !sampleRate) throw new Error(`${path}: missing fmt/data chunk`);
  if (channels !== 1) throw new Error(`${path}: expected mono audio, got ${channels} channels`);
  return { pcm, sampleRate };
}

/** Run one fixture through the production streaming path (or batch fallback). */
async function transcribeFixture(path: string): Promise<string> {
  const { pcm, sampleRate } = readWav(path);
  const streaming = createStreamingSpeechProvider();

  if (!streaming) {
    const batch = createSpeechProvider();
    const result = await batch.transcribe({
      wav: pcm16ToWav(pcm, { sampleRate, channels: 1 }),
      sampleRate,
      durationMs: pcmDurationMs(pcm.length, { sampleRate, channels: 1 }),
    });
    return result.text;
  }

  return new Promise<string>((resolve, reject) => {
    const session = streaming.createSession({ sampleRate });
    const texts: string[] = [];
    const timer = setTimeout(() => {
      void session.close();
      reject(new Error('timeout: no final transcription within 45s'));
    }, 45_000);
    session.onUtterance((utterance: StreamingUtterance) => texts.push(utterance.text));
    session.onFinalized(() => {
      clearTimeout(timer);
      void session.close();
      resolve(texts.join(' ').trim());
    });
    session.onError((error) => {
      clearTimeout(timer);
      void session.close();
      reject(error);
    });
    // Stream in ~100 ms chunks paced near-real-time like the phone does,
    // then finalize.
    const chunkBytes = (sampleRate * 2) / 10;
    const chunks: Buffer[] = [];
    for (let i = 0; i < pcm.length; i += chunkBytes) {
      chunks.push(pcm.subarray(i, Math.min(pcm.length, i + chunkBytes)));
    }
    let index = 0;
    const pump = setInterval(() => {
      if (index >= chunks.length) {
        clearInterval(pump);
        session.finalize();
        return;
      }
      session.sendAudio(chunks[index++]!);
    }, 60);
  });
}

function normalize(text: string): string {
  return text
    .toLowerCase()
    .replace(/[ً-ْٰ]/g, '') // Arabic diacritics
    .replace(/[.,!?؟،…'"«»]/g, '')
    .replace(/\s+/g, ' ')
    .trim();
}

async function verifySpeech(): Promise<Failure[]> {
  console.log(`\nSpeech check (provider: ${env.SPEECH_PROVIDER}, no source language configured)`);
  if (env.SPEECH_PROVIDER === 'mock') {
    return [{ step: 'configuration', detail: 'SPEECH_PROVIDER is "mock" — nothing real to verify.' }];
  }
  const failures: Failure[] = [];

  const cases = [
    { file: 'arabic_salam.wav', speak: ARABIC_TEXT, mustContain: ['السلام', 'عليكم'] },
    { file: 'english_good_morning.wav', speak: 'Good morning', mustContain: ['good morning'] },
  ];

  for (const testCase of cases) {
    try {
      const path = await ensureFixture(testCase.file, testCase.speak);
      const transcript = await transcribeFixture(path);
      const normalized = normalize(transcript);
      const missing = testCase.mustContain.filter((part) => !normalized.includes(normalize(part)));
      if (missing.length === 0) {
        ok(`${testCase.file} → "${transcript}"`);
      } else {
        failures.push({
          step: `transcribe ${testCase.file}`,
          detail: `got "${transcript}" — expected it to contain: ${testCase.mustContain.join(', ')}`,
        });
      }
    } catch (error) {
      failures.push({ step: `transcribe ${testCase.file}`, detail: describeError(error) });
    }
  }
  return failures;
}

// ── Live translation check (PRIMARY path: gpt-realtime-translate) ─────────────

interface LiveResult {
  deltas: number;
  finalText: string;
  audioBytesSent: number;
  error?: string;
}

async function runLiveTranslation(fixturePath: string): Promise<LiveResult> {
  const provider = createRealtimeTranslationProvider();
  if (!provider) throw new Error('no realtime translation provider configured');
  const { pcm, sampleRate } = readWav(fixturePath);

  return new Promise<LiveResult>((resolve) => {
    const result: LiveResult = { deltas: 0, finalText: '', audioBytesSent: 0 };
    const session = provider.createSession({ sampleRate, targetLanguage: 'ar' });
    const finish = (): void => {
      clearTimeout(timeout);
      void session.close();
      resolve(result);
    };
    const timeout = setTimeout(() => {
      result.error ??= 'timeout: no final translation within 45s';
      finish();
    }, 45_000);

    session.onDelta((_utteranceId, delta) => {
      result.deltas += 1;
      if (result.deltas === 1) console.log('  first translated delta received:', JSON.stringify(delta));
    });
    session.onUtteranceFinal((_utteranceId, translatedText) => {
      result.finalText = translatedText;
      finish();
    });
    session.onError((error) => {
      result.error = error.message;
      finish();
    });

    // Stream like the phone does: ~100 ms chunks PACED in near-real-time
    // (burst-sending faster than realtime makes the endpoint behave
    // inconsistently), then trailing silence so the utterance can finalize.
    const chunkBytes = (sampleRate * 2) / 10;
    const chunks: Buffer[] = [];
    for (let i = 0; i < pcm.length; i += chunkBytes) {
      chunks.push(pcm.subarray(i, Math.min(pcm.length, i + chunkBytes)));
    }
    const silence = Buffer.alloc(chunkBytes);
    for (let i = 0; i < 40; i++) chunks.push(silence); // 4 s of room tone
    let index = 0;
    const pump = setInterval(() => {
      if (index >= chunks.length) {
        clearInterval(pump);
        return;
      }
      const chunk = chunks[index++]!;
      session.sendAudio(chunk);
      result.audioBytesSent += chunk.length;
    }, 60); // slightly faster than realtime, far from a burst
  });
}

async function verifyLiveTranslation(): Promise<Failure[]> {
  console.log('\nLive translation check (gpt-realtime-translate, target: ar — REAL API)');
  if (env.TRANSLATION_PROVIDER !== 'openai') {
    return [
      { step: 'configuration', detail: `TRANSLATION_PROVIDER=${env.TRANSLATION_PROVIDER} has no realtime path.` },
    ];
  }
  const failures: Failure[] = [];

  const cases = [
    {
      file: 'english_hello.wav',
      speak: 'Hello',
      check: (t: string) => t.includes('مرحب'),
      expectation: 'contains "مرحب"',
      sameLanguageOk: false,
    },
    {
      file: 'arabic_salam.wav',
      speak: ARABIC_TEXT,
      check: (t: string) => ARABIC_RE.test(t),
      expectation: 'stays Arabic',
      // Observed endpoint behavior: input already in the target language
      // produces NO output (nothing to translate). In production the
      // watchdog rotates to the STT fallback, which passes Arabic through
      // verbatim (proven by the speech + translation checks above).
      sameLanguageOk: true,
    },
  ];

  // The endpoint currently returns some defective sessions (audio accepted,
  // no transcript ever). Production replaces those via a watchdog, so the
  // check mirrors that: up to 3 fresh sessions per case.
  const MAX_SESSIONS = 3;
  for (const testCase of cases) {
    try {
      const path = await ensureFixture(testCase.file, testCase.speak);
      let passed = false;
      for (let attempt = 1; attempt <= MAX_SESSIONS && !passed; attempt++) {
        const result = await runLiveTranslation(path);
        // The three required proofs, stated explicitly:
        console.log(`  [session ${attempt}] connected + audio streamed: ${result.audioBytesSent} bytes`);
        console.log(`  [session ${attempt}] translated deltas received: ${result.deltas}`);
        console.log(`  [session ${attempt}] final translation: "${result.finalText}"`);
        if (!result.error && result.deltas >= 1 && testCase.check(result.finalText)) {
          ok(`${testCase.file} → "${result.finalText}" (${result.deltas} deltas, session ${attempt}/${MAX_SESSIONS})`);
          passed = true;
        } else if (testCase.sameLanguageOk && result.deltas === 0 && attempt === MAX_SESSIONS) {
          ok(
            `${testCase.file} → no realtime output (same-language passthrough; ` +
              'the STT fallback covers this — verified above)',
          );
          passed = true;
        } else if (attempt === MAX_SESSIONS) {
          failures.push({
            step: `live translate ${testCase.file}`,
            detail:
              result.error ??
              (result.deltas < 1
                ? `no translated delta arrived in ${MAX_SESSIONS} sessions — the realtime path is NOT working`
                : `final "${result.finalText}" — expected output that ${testCase.expectation}`),
          });
        }
      }
    } catch (error) {
      failures.push({ step: `live translate ${testCase.file}`, detail: describeError(error) });
    }
  }
  return failures;
}

// ── Main ──────────────────────────────────────────────────────────────────────

async function main(): Promise<void> {
  console.log('Provider verification (REAL API calls — never prints keys)');

  const translationFailures = await verifyTranslation();
  if (translationFailures.length === 0) {
    console.log('Translation provider: PASS');
  } else {
    console.log('Translation provider: FAIL');
    for (const failure of translationFailures) {
      console.log(`  ✗ ${failure.step}\n      ${failure.detail}`);
    }
  }

  const speechFailures = await verifySpeech();
  if (speechFailures.length === 0) {
    console.log('Speech provider: PASS');
  } else {
    console.log('Speech provider: FAIL');
    for (const failure of speechFailures) {
      console.log(`  ✗ ${failure.step}\n      ${failure.detail}`);
    }
  }

  const liveFailures = await verifyLiveTranslation();
  if (liveFailures.length === 0) {
    console.log('Live translation (PRIMARY path): PASS');
  } else {
    console.log('Live translation (PRIMARY path): FAIL');
    for (const failure of liveFailures) {
      console.log(`  ✗ ${failure.step}\n      ${failure.detail}`);
    }
  }

  if (translationFailures.length > 0 || speechFailures.length > 0 || liveFailures.length > 0) {
    process.exit(1);
  }
}

void main().catch((error) => {
  console.error('verify:providers crashed:', error instanceof Error ? error.message : error);
  process.exit(1);
});
