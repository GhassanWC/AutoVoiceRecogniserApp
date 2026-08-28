import { env } from '../../config/env';
import { HeuristicDiarizationProvider, NoneDiarizationProvider } from './heuristic';
import { SpeakerDiarizationProvider } from './types';

export * from './types';

/** Diarizers are stateful per session — create a fresh one for each session. */
export function createDiarizationProvider(): SpeakerDiarizationProvider {
  switch (env.DIARIZATION_PROVIDER) {
    case 'none':
      return new NoneDiarizationProvider();
    case 'heuristic':
    default:
      return new HeuristicDiarizationProvider();
  }
}
