import { SegmentInfo, SpeakerAssignment, SpeakerDiarizationProvider } from './types';

interface KnownSpeaker {
  id: string;
  label: string;
  language: string;
  lastHeardMs: number;
}

/**
 * Phase-1 speaker guessing without any voice-print ML, using two observable
 * signals: which language a segment is in, and how much time passed since a
 * speaker last talked. In multilingual conversations (the app's core scenario)
 * language is a strong speaker cue; for same-language turn-taking this will
 * often merge speakers, which the product spec accepts — a wrong speaker label
 * must never block translation, and the UI can always fall back to "Speaker".
 *
 * One instance per listening session (it is stateful).
 */
export class HeuristicDiarizationProvider implements SpeakerDiarizationProvider {
  readonly name = 'heuristic';

  private speakers: KnownSpeaker[] = [];
  private lastSpeaker: KnownSpeaker | null = null;

  /** Gap below which we assume the same person kept talking. */
  private static readonly CONTINUATION_GAP_MS = 4000;
  private static readonly MAX_SPEAKERS = 8;

  async assignSpeaker(segment: SegmentInfo): Promise<SpeakerAssignment> {
    // Too unsure about the language to use it as a cue → generic label.
    if (segment.language === 'und' || segment.languageConfidence < 0.4) {
      return { speakerId: null, speakerLabel: null };
    }

    const gapMs = this.lastSpeaker ? segment.startedAtMs - this.lastSpeaker.lastHeardMs : Infinity;

    // Same language as whoever spoke moments ago → same speaker.
    if (
      this.lastSpeaker &&
      this.lastSpeaker.language === segment.language &&
      gapMs < HeuristicDiarizationProvider.CONTINUATION_GAP_MS
    ) {
      return this.touch(this.lastSpeaker, segment);
    }

    // A known speaker of this language coming back into the conversation.
    const returning = this.speakers.find((s) => s.language === segment.language);
    if (returning) {
      return this.touch(returning, segment);
    }

    if (this.speakers.length >= HeuristicDiarizationProvider.MAX_SPEAKERS) {
      return { speakerId: null, speakerLabel: null };
    }

    const speaker: KnownSpeaker = {
      id: `speaker_${this.speakers.length + 1}`,
      label: `Speaker ${this.speakers.length + 1}`,
      language: segment.language,
      lastHeardMs: segment.startedAtMs + segment.durationMs,
    };
    this.speakers.push(speaker);
    this.lastSpeaker = speaker;
    return { speakerId: speaker.id, speakerLabel: speaker.label };
  }

  private touch(speaker: KnownSpeaker, segment: SegmentInfo): SpeakerAssignment {
    speaker.lastHeardMs = segment.startedAtMs + segment.durationMs;
    speaker.language = segment.language;
    this.lastSpeaker = speaker;
    return { speakerId: speaker.id, speakerLabel: speaker.label };
  }
}

/** Always returns the generic speaker; used when diarization is disabled. */
export class NoneDiarizationProvider implements SpeakerDiarizationProvider {
  readonly name = 'none';
  async assignSpeaker(): Promise<SpeakerAssignment> {
    return { speakerId: null, speakerLabel: null };
  }
}
