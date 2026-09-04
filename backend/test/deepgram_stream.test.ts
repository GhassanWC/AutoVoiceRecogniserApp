import { describe, expect, it } from 'vitest';
import { gatedLanguage } from '../src/modules/realtime/live_session';
import {
  DeepgramWord,
  NOVA3_MULTI_LANGUAGES,
  utterancesFromWords,
} from '../src/providers/speech/deepgram_stream';

function word(overrides: Partial<DeepgramWord> & { word: string }): DeepgramWord {
  return { start: 0, end: 0.5, confidence: 0.95, speaker: 0, language: 'en', ...overrides };
}

function speakerIds(): (n: number) => string {
  const seen = new Map<number, string>();
  return (n) => {
    let id = seen.get(n);
    if (!id) {
      id = `speaker_${seen.size + 1}`;
      seen.set(n, id);
    }
    return id;
  };
}

describe('utterancesFromWords', () => {
  it('builds one utterance from one speaker with the dominant language', () => {
    const utterances = utterancesFromWords(
      [
        word({ word: 'hola', punctuated_word: 'Hola', language: 'es', start: 0, end: 0.4 }),
        word({ word: 'hermano', punctuated_word: 'hermano,', language: 'es', start: 0.4, end: 0.9 }),
        word({ word: 'cómo', language: 'es', start: 0.9, end: 1.2 }),
        word({ word: 'estás', punctuated_word: 'estás?', language: 'es', start: 1.2, end: 1.6 }),
      ],
      speakerIds(),
    );

    expect(utterances).toHaveLength(1);
    expect(utterances[0]).toMatchObject({
      text: 'Hola hermano, cómo estás?',
      language: 'es',
      speakerId: 'speaker_1',
      startMs: 0,
      endMs: 1600,
    });
    expect(utterances[0]!.languageConfidence).toBeGreaterThan(0.9);
    expect(utterances[0]!.transcriptionConfidence).toBeCloseTo(0.95);
  });

  it('splits on provider speaker changes and keeps provider speaker identity', () => {
    const utterances = utterancesFromWords(
      [
        word({ word: 'hello', speaker: 0, language: 'en' }),
        word({ word: 'there', speaker: 0, language: 'en' }),
        word({ word: 'bonjour', speaker: 1, language: 'fr' }),
        word({ word: 'monsieur', speaker: 1, language: 'fr' }),
        word({ word: 'thanks', speaker: 0, language: 'en' }),
      ],
      speakerIds(),
    );

    expect(utterances.map((u) => u.speakerId)).toEqual(['speaker_1', 'speaker_2', 'speaker_1']);
    expect(utterances.map((u) => u.language)).toEqual(['en', 'fr', 'en']);
  });

  it('handles language switching across utterances of the same stream', () => {
    const feed = (language: string, text: string): string => {
      const utterances = utterancesFromWords(
        text.split(' ').map((w) => word({ word: w, language })),
        speakerIds(),
      );
      return utterances[0]!.language;
    };
    // Switching between languages of the documented language=multi set in one
    // session, no reconfiguration involved.
    expect(feed('en', 'good morning everyone')).toBe('en');
    expect(feed('es', 'buenos días a todos')).toBe('es');
    expect(feed('fr', 'bonjour tout le monde')).toBe('fr');
    expect(feed('de', 'guten morgen zusammen')).toBe('de');
  });

  it('documents the nova-3 language=multi limitation explicitly', () => {
    // Deepgram's nova-3 multilingual stream currently code-switches between
    // exactly these languages; this test exists to force a deliberate update
    // (list + gate) if the assumption ever changes.
    expect([...NOVA3_MULTI_LANGUAGES].sort()).toEqual(
      ['de', 'en', 'es', 'fr', 'hi', 'it', 'ja', 'nl', 'pt', 'ru'].sort(),
    );
  });

  it('reports "und" for word tags outside the documented language=multi set', () => {
    // Arabic (like Thai or Chinese) is NOT documented for nova-3 language=multi
    // code-switching — never surface it as a confident language claim.
    const utterances = utterancesFromWords(
      'صباح الخير جميعا'.split(' ').map((w) => word({ word: w, language: 'ar' })),
      speakerIds(),
    );
    expect(utterances[0]!.language).toBe('und');
    expect(utterances[0]!.languageConfidence).toBe(0);
    // The transcript itself is still delivered — only the language claim is withheld.
    expect(utterances[0]!.text).toBe('صباح الخير جميعا');
  });

  it('normalizes BCP-47 codes and mixed-language runs to the majority language', () => {
    const utterances = utterancesFromWords(
      [
        word({ word: 'let’s', language: 'en-US' }),
        word({ word: 'go', language: 'en-US' }),
        word({ word: 'mañana', language: 'es' }),
      ],
      speakerIds(),
    );
    expect(utterances[0]!.language).toBe('en');
    expect(utterances[0]!.languageConfidence).toBeLessThan(0.7); // 2/3 share
  });

  it('returns null speaker when the provider did not diarize', () => {
    const utterances = utterancesFromWords(
      [word({ word: 'hello', speaker: undefined })],
      speakerIds(),
    );
    expect(utterances[0]!.speakerId).toBeNull();
  });

  it('produces nothing from empty word lists', () => {
    expect(utterancesFromWords([], speakerIds())).toEqual([]);
  });
});

describe('gatedLanguage (short ambiguous utterances)', () => {
  it('refuses to assign a language to a short utterance with weak confidence', () => {
    expect(gatedLanguage('yes', 'en', 0.5)).toBe('und');
    expect(gatedLanguage('okay', 'en', 0.6)).toBe('und');
    expect(gatedLanguage('hello', 'en', 0.79)).toBe('und');
  });

  it('keeps the language for a short utterance with strong confidence', () => {
    expect(gatedLanguage('yes', 'en', 0.92)).toBe('en');
  });

  it('keeps the language for longer utterances even at moderate confidence', () => {
    expect(gatedLanguage('where is the train station', 'en', 0.6)).toBe('en');
  });
});
