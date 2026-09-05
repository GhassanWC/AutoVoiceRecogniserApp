import { describe, expect, it } from 'vitest';
import {
  TranslationDelta,
  TranslationJobFailure,
  TranslationJobSuccess,
  TranslationQueue,
} from '../src/modules/realtime/translation_queue';
import {
  TranslationProvider,
  TranslationProviderError,
  TranslationRequest,
  TranslationResult,
} from '../src/providers/translation';

const FAST_RETRIES = { retryDelaysMs: [5, 5, 5] };

function request(text: string): TranslationRequest {
  return { text, sourceLanguage: 'en', targetLanguage: 'ar' };
}

class ScriptedProvider implements TranslationProvider {
  readonly name = 'scripted';
  calls = 0;

  /** Each entry is an error to throw; when the script runs out, succeed. */
  constructor(private readonly failures: Array<Error> = []) {}

  async translate(req: TranslationRequest): Promise<TranslationResult> {
    const call = this.calls++;
    const failure = this.failures[call];
    if (failure) throw failure;
    return { translatedText: `[ar] ${req.text}` };
  }
}

function collect(): {
  successes: TranslationJobSuccess[];
  failures: TranslationJobFailure[];
  onSuccess: (r: TranslationJobSuccess) => void;
  onFailure: (f: TranslationJobFailure) => void;
} {
  const successes: TranslationJobSuccess[] = [];
  const failures: TranslationJobFailure[] = [];
  return {
    successes,
    failures,
    onSuccess: (r) => successes.push(r),
    onFailure: (f) => failures.push(f),
  };
}

describe('TranslationQueue', () => {
  it('translates jobs and reports success with attempt count', async () => {
    const sink = collect();
    const queue = new TranslationQueue(new ScriptedProvider(), sink.onSuccess, sink.onFailure, FAST_RETRIES);
    queue.enqueue({ messageId: 'm1', request: request('Hello there') });
    await queue.drain();

    expect(sink.successes).toEqual([
      expect.objectContaining({ messageId: 'm1', translatedText: '[ar] Hello there', attempts: 1 }),
    ]);
    expect(sink.failures).toHaveLength(0);
  });

  it('limits concurrency to the configured maximum', async () => {
    let active = 0;
    let maxActive = 0;
    const provider: TranslationProvider = {
      name: 'slow',
      async translate(req) {
        active += 1;
        maxActive = Math.max(maxActive, active);
        await new Promise((resolve) => setTimeout(resolve, 25));
        active -= 1;
        return { translatedText: `[ar] ${req.text}` };
      },
    };
    const sink = collect();
    const queue = new TranslationQueue(provider, sink.onSuccess, sink.onFailure, {
      concurrency: 2,
      ...FAST_RETRIES,
    });
    for (let i = 0; i < 6; i++) {
      queue.enqueue({ messageId: `m${i}`, request: request(`text ${i}`) });
    }
    await queue.drain();

    expect(maxActive).toBe(2);
    expect(sink.successes).toHaveLength(6);
  });

  it.each([408, 429, 500, 502, 503, 504])('retries HTTP %d and succeeds', async (status) => {
    const provider = new ScriptedProvider([
      new TranslationProviderError(`Translation provider error (${status})`, true, status),
    ]);
    const sink = collect();
    const queue = new TranslationQueue(provider, sink.onSuccess, sink.onFailure, FAST_RETRIES);
    queue.enqueue({ messageId: 'm1', request: request('Where is the hotel?') });
    await queue.drain();

    expect(sink.failures).toHaveLength(0);
    expect(sink.successes[0]).toMatchObject({ attempts: 2, translatedText: '[ar] Where is the hotel?' });
  });

  it('retries network-style errors (unknown error shapes count as transient)', async () => {
    const provider = new ScriptedProvider([
      new TranslationProviderError('Translation network error: socket hang up', true),
      new Error('fetch failed: ECONNRESET'), // not a TranslationProviderError
    ]);
    const sink = collect();
    const queue = new TranslationQueue(provider, sink.onSuccess, sink.onFailure, FAST_RETRIES);
    queue.enqueue({ messageId: 'm1', request: request('Hola hermano') });
    await queue.drain();

    expect(sink.failures).toHaveLength(0);
    expect(sink.successes[0]).toMatchObject({ attempts: 3 });
  });

  it('gives up after retries are exhausted', async () => {
    const always500 = () =>
      new TranslationProviderError('Translation provider error (500)', true, 500);
    const provider = new ScriptedProvider([always500(), always500(), always500(), always500()]);
    const sink = collect();
    const queue = new TranslationQueue(provider, sink.onSuccess, sink.onFailure, FAST_RETRIES);
    queue.enqueue({ messageId: 'm1', request: request('Bonjour') });
    await queue.drain();

    expect(sink.successes).toHaveLength(0);
    expect(sink.failures[0]).toMatchObject({
      messageId: 'm1',
      attempts: 4, // 1 first try + 3 retries
      retriesExhausted: true,
      lastStatus: 500,
    });
    expect(provider.calls).toBe(4);
  });

  it('does not retry permanent auth/configuration errors', async () => {
    const provider = new ScriptedProvider([
      new TranslationProviderError('Translation provider error (401)', false, 401),
    ]);
    const sink = collect();
    const queue = new TranslationQueue(provider, sink.onSuccess, sink.onFailure, FAST_RETRIES);
    queue.enqueue({ messageId: 'm1', request: request('Guten Tag') });
    await queue.drain();

    expect(provider.calls).toBe(1); // exactly one attempt
    expect(sink.failures[0]).toMatchObject({ attempts: 1, retriesExhausted: false, lastStatus: 401 });
  });

  it('forwards streaming deltas and resets partial output on retry', async () => {
    let call = 0;
    const provider: TranslationProvider = {
      name: 'streaming',
      async translate() {
        throw new Error('translateStream should be preferred');
      },
      async translateStream(req, onDelta) {
        call += 1;
        onDelta('صباح ');
        if (call === 1) {
          // Dies after emitting a partial chunk — the retry must start over.
          throw new TranslationProviderError('Translation stream interrupted: reset', true);
        }
        onDelta('الخير');
        return { translatedText: 'صباح الخير', sourceLanguage: 'en' };
      },
    };
    const sink = collect();
    const deltas: TranslationDelta[] = [];
    const queue = new TranslationQueue(
      provider,
      sink.onSuccess,
      sink.onFailure,
      FAST_RETRIES,
      (delta) => deltas.push(delta),
    );
    queue.enqueue({ messageId: 'm1', request: request('Good morning.') });
    await queue.drain();

    expect(deltas.map((d) => [d.delta, d.reset])).toEqual([
      ['صباح ', false], // attempt 1 partial
      ['صباح ', true], // attempt 2 starts over → reset replaces the partial
      ['الخير', false],
    ]);
    expect(sink.successes[0]).toMatchObject({
      translatedText: 'صباح الخير',
      sourceLanguage: 'en',
      attempts: 2,
    });
  });

  it('rejects new jobs after close but finishes in-flight ones', async () => {
    const sink = collect();
    const queue = new TranslationQueue(new ScriptedProvider(), sink.onSuccess, sink.onFailure, FAST_RETRIES);
    queue.enqueue({ messageId: 'm1', request: request('one') });
    queue.close();
    queue.enqueue({ messageId: 'm2', request: request('two') });
    await queue.drain();

    expect(sink.successes.map((s) => s.messageId)).toEqual(['m1']);
  });
});
