import { describe, expect, it } from 'vitest';
import { HeuristicDiarizationProvider } from '../src/providers/diarization/heuristic';

describe('HeuristicDiarizationProvider', () => {
  it('gives each new language its own speaker and reuses it when they return', async () => {
    const diarizer = new HeuristicDiarizationProvider();
    const spanish1 = await diarizer.assignSpeaker({
      startedAtMs: 0,
      durationMs: 2000,
      language: 'es',
      languageConfidence: 0.95,
    });
    const english = await diarizer.assignSpeaker({
      startedAtMs: 3000,
      durationMs: 2000,
      language: 'en',
      languageConfidence: 0.95,
    });
    const spanish2 = await diarizer.assignSpeaker({
      startedAtMs: 20_000,
      durationMs: 2000,
      language: 'es',
      languageConfidence: 0.95,
    });

    expect(spanish1.speakerId).toBe('speaker_1');
    expect(english.speakerId).toBe('speaker_2');
    expect(spanish2.speakerId).toBe('speaker_1'); // same voice profile heuristic: same language
    expect(spanish1.speakerLabel).toBe('Speaker 1');
  });

  it('treats quick same-language continuation as the same speaker', async () => {
    const diarizer = new HeuristicDiarizationProvider();
    const first = await diarizer.assignSpeaker({
      startedAtMs: 0,
      durationMs: 1500,
      language: 'en',
      languageConfidence: 0.9,
    });
    const second = await diarizer.assignSpeaker({
      startedAtMs: 2500,
      durationMs: 1500,
      language: 'en',
      languageConfidence: 0.9,
    });
    expect(second.speakerId).toBe(first.speakerId);
  });

  it('falls back to the generic speaker when language confidence is low', async () => {
    const diarizer = new HeuristicDiarizationProvider();
    const result = await diarizer.assignSpeaker({
      startedAtMs: 0,
      durationMs: 1000,
      language: 'und',
      languageConfidence: 0,
    });
    expect(result.speakerId).toBeNull();
    expect(result.speakerLabel).toBeNull();
  });
});
