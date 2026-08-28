import { env } from '../../config/env';
import { currentMonth, getStore } from '../../storage';
import { log } from '../../utils/logger';

/**
 * Cost control: only processed speech counts against the monthly allowance —
 * silence never reaches the server (client-side VAD), so listening time with
 * nobody talking is free for the user and for us.
 */

export async function recordProcessedSpeech(
  userId: string,
  speechSeconds: number,
  translatedCharacters: number,
): Promise<void> {
  await getStore().addUsage(userId, currentMonth(), speechSeconds, translatedCharacters);
  log.debug('usage recorded', { userId, speechSeconds, translatedCharacters });
}

export async function hasRemainingAllowance(userId: string): Promise<boolean> {
  if (env.FREE_MONTHLY_MINUTES <= 0) return true; // unlimited
  const usage = await getStore().getUsage(userId, currentMonth());
  return usage.speechSeconds < env.FREE_MONTHLY_MINUTES * 60;
}
