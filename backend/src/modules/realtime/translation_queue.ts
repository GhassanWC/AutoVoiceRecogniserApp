import {
  TranslationProvider,
  TranslationProviderError,
  TranslationRequest,
} from '../../providers/translation';
import { log } from '../../utils/logger';

/**
 * Reliable translation for one live session.
 *
 * The speech stream must never wait on OpenAI: every finalized transcript
 * becomes a job here and Deepgram keeps flowing. Jobs run with a small
 * concurrency limit (results are keyed by messageId, so out-of-order
 * completion is fine), and transient failures — network errors, timeouts,
 * 408/429/5xx — are retried with backoff before the job is declared failed.
 * Permanent errors (bad API key, malformed request) fail immediately: they
 * would fail identically on every retry.
 */

export interface TranslationJob {
  messageId: string;
  request: TranslationRequest;
}

export interface TranslationJobSuccess {
  messageId: string;
  translatedText: string;
  /** Language detected by the translator from the text; undefined if not reported. */
  sourceLanguage?: string;
  attempts: number;
  latencyMs: number;
}

export interface TranslationJobFailure {
  messageId: string;
  attempts: number;
  /** True when retries were exhausted; false for a permanent, non-retryable error. */
  retriesExhausted: boolean;
  lastError: string;
  lastStatus?: number;
}

export interface TranslationQueueOptions {
  concurrency?: number;
  /** Backoff before attempt 2, 3, 4… — also defines the max attempt count. */
  retryDelaysMs?: number[];
}

export interface TranslationDelta {
  messageId: string;
  delta: string;
  /**
   * true on the first delta of a RETRY attempt: earlier partial output from
   * the failed attempt must be discarded, not appended to.
   */
  reset: boolean;
  /** Milliseconds from job start to this delta (first delta ≙ first latency). */
  sinceJobStartMs: number;
}

const DEFAULT_CONCURRENCY = 2;
const DEFAULT_RETRY_DELAYS_MS = [300, 1_000, 2_000];

export class TranslationQueue {
  private readonly concurrency: number;
  private readonly retryDelaysMs: number[];
  private readonly waiting: TranslationJob[] = [];
  private active = 0;
  private closed = false;
  private idleResolvers: Array<() => void> = [];

  constructor(
    private readonly provider: TranslationProvider,
    private readonly onSuccess: (result: TranslationJobSuccess) => void,
    private readonly onFailure: (failure: TranslationJobFailure) => void,
    options: TranslationQueueOptions = {},
    private readonly onDelta?: (delta: TranslationDelta) => void,
  ) {
    this.concurrency = options.concurrency ?? DEFAULT_CONCURRENCY;
    this.retryDelaysMs = options.retryDelaysMs ?? DEFAULT_RETRY_DELAYS_MS;
  }

  get pendingCount(): number {
    return this.active + this.waiting.length;
  }

  enqueue(job: TranslationJob): void {
    if (this.closed) return;
    this.waiting.push(job);
    this.pump();
  }

  /** Resolves once every queued and in-flight job has finished. */
  drain(): Promise<void> {
    if (this.pendingCount === 0) return Promise.resolve();
    return new Promise((resolve) => this.idleResolvers.push(resolve));
  }

  /** Stop accepting jobs; in-flight jobs still complete and report. */
  close(): void {
    this.closed = true;
  }

  private pump(): void {
    while (this.active < this.concurrency && this.waiting.length > 0) {
      const job = this.waiting.shift()!;
      this.active += 1;
      void this.run(job).finally(() => {
        this.active -= 1;
        this.pump();
        if (this.pendingCount === 0) {
          const resolvers = this.idleResolvers;
          this.idleResolvers = [];
          for (const resolve of resolvers) resolve();
        }
      });
    }
  }

  private async run(job: TranslationJob): Promise<void> {
    const maxAttempts = this.retryDelaysMs.length + 1;
    const started = Date.now();

    let deltasSent = false;
    for (let attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        // Stream display text as it is produced when the provider supports it
        // (live subtitles); otherwise the plain call still works.
        let firstOfAttempt = true;
        const result = this.provider.translateStream
          ? await this.provider.translateStream(job.request, (delta) => {
              this.onDelta?.({
                messageId: job.messageId,
                delta,
                reset: firstOfAttempt && deltasSent,
                sinceJobStartMs: Date.now() - started,
              });
              firstOfAttempt = false;
              deltasSent = true;
            })
          : await this.provider.translate(job.request);
        this.onSuccess({
          messageId: job.messageId,
          translatedText: result.translatedText,
          sourceLanguage: result.sourceLanguage,
          attempts: attempt,
          latencyMs: Date.now() - started,
        });
        return;
      } catch (error) {
        const providerError = error instanceof TranslationProviderError ? error : null;
        // Unknown error shapes are treated as transient — losing a transcript
        // to a pessimistic classification is worse than one extra attempt.
        const retryable = providerError ? providerError.retryable : true;
        const status = providerError?.status;
        const message = error instanceof Error ? error.message : String(error);

        log.warn('translation attempt failed', {
          messageId: job.messageId,
          attempt,
          maxAttempts,
          status,
          retryable,
          message,
        });

        if (!retryable || attempt === maxAttempts) {
          this.onFailure({
            messageId: job.messageId,
            attempts: attempt,
            retriesExhausted: retryable,
            lastError: message,
            lastStatus: status,
          });
          return;
        }
        await sleep(this.retryDelaysMs[attempt - 1]!);
      }
    }
  }
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
