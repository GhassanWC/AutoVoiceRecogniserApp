import { describe, expect, it } from 'vitest';
import {
  RealtimeSegment,
  utterancesFromRealtime,
} from '../src/providers/speech/openai_realtime';
import { parseTranslationResponse } from '../src/providers/translation/openai';
import { TranslationProviderError } from '../src/providers/translation/types';
import { resamplePcm16 } from '../src/utils/audio';

function speakerIds(): (s: string) => string {
  const seen = new Map<string, string>();
  return (s) => {
    let id = seen.get(s);
    if (!id) {
      id = `speaker_${seen.size + 1}`;
      seen.set(s, id);
    }
    return id;
  };
}

function segment(overrides: Partial<RealtimeSegment> & { text: string }): RealtimeSegment {
  return { itemId: 'item_1', speaker: 'A', startMs: 0, endMs: 500, ...overrides };
}

describe('utterancesFromRealtime', () => {
  it('groups diarized segments by speaker and maps labels to stable ids', () => {
    const utterances = utterancesFromRealtime(
      [
        segment({ text: 'How are', speaker: 'A', startMs: 0, endMs: 400 }),
        segment({ text: 'you today?', speaker: 'A', startMs: 400, endMs: 900 }),
        segment({ text: 'I am fine.', speaker: 'B', startMs: 1000, endMs: 1600 }),
        segment({ text: 'Great!', speaker: 'A', startMs: 1700, endMs: 2000 }),
      ],
      'How are you today? I am fine. Great!',
      speakerIds(),
    );

    expect(utterances.map((u) => u.text)).toEqual(['How are you today?', 'I am fine.', 'Great!']);
    expect(utterances.map((u) => u.speakerId)).toEqual(['speaker_1', 'speaker_2', 'speaker_1']);
    expect(utterances[0]).toMatchObject({ startMs: 0, endMs: 900 });
  });

  it('reports language "und" — language identification is the translator\'s job', () => {
    const utterances = utterancesFromRealtime(
      [segment({ text: 'السلام عليكم' })],
      'السلام عليكم',
      speakerIds(),
    );
    // Arabic (or any language) is never rejected or guessed at this stage.
    expect(utterances[0]).toMatchObject({ text: 'السلام عليكم', language: 'und' });
  });

  it('falls back to the plain transcript when no diarized segments arrived', () => {
    const utterances = utterancesFromRealtime([], 'Good morning.', speakerIds());
    expect(utterances).toEqual([
      expect.objectContaining({ text: 'Good morning.', speakerId: null, language: 'und' }),
    ]);
  });

  it('produces nothing for an empty transcript', () => {
    expect(utterancesFromRealtime([], '   ', speakerIds())).toEqual([]);
  });
});

describe('resamplePcm16', () => {
  it('upsamples 16 kHz to 24 kHz with a 3/2 sample count', () => {
    const input = Buffer.alloc(3200); // 100 ms @ 16 kHz
    for (let i = 0; i < 1600; i++) input.writeInt16LE(((i % 100) - 50) * 100, i * 2);
    const output = resamplePcm16(input, 16000, 24000);
    expect(output.length).toBe(4800); // 100 ms @ 24 kHz
    // Endpoints are preserved by linear interpolation.
    expect(output.readInt16LE(0)).toBe(input.readInt16LE(0));
    expect(output.readInt16LE(output.length - 2)).toBe(input.readInt16LE(input.length - 2));
  });

  it('returns the buffer unchanged when rates match', () => {
    const input = Buffer.from([1, 2, 3, 4]);
    expect(resamplePcm16(input, 24000, 24000)).toBe(input);
  });
});

describe('parseTranslationResponse', () => {
  it('parses the structured translation reply', () => {
    expect(
      parseTranslationResponse('{"sourceLanguage": "es", "translatedText": "مرحباً يا أخي"}'),
    ).toEqual({ sourceLanguage: 'es', translatedText: 'مرحباً يا أخي' });
  });

  it('tolerates code fences around the JSON', () => {
    const parsed = parseTranslationResponse(
      '```json\n{"sourceLanguage": "en", "translatedText": "صباح الخير."}\n```',
    );
    expect(parsed).toEqual({ sourceLanguage: 'en', translatedText: 'صباح الخير.' });
  });

  it('normalizes an unusable language claim to "und" but keeps the translation', () => {
    expect(
      parseTranslationResponse('{"sourceLanguage": "unknown!", "translatedText": "مرحبا"}'),
    ).toEqual({ sourceLanguage: 'und', translatedText: 'مرحبا' });
  });

  it('throws a retryable error for an unparseable reply', () => {
    expect(() => parseTranslationResponse('sorry, I cannot do that')).toThrowError(
      TranslationProviderError,
    );
    try {
      parseTranslationResponse('{"translatedText": ""}');
      expect.unreachable();
    } catch (error) {
      expect((error as TranslationProviderError).retryable).toBe(true);
    }
  });
});
