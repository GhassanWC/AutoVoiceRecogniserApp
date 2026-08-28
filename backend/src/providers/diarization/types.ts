export interface SegmentInfo {
  /** Milliseconds since session start when the segment began. */
  startedAtMs: number;
  durationMs: number;
  language: string;
  languageConfidence: number;
}

export interface SpeakerAssignment {
  /** Stable per-session id, e.g. "speaker_1"; null when too uncertain. */
  speakerId: string | null;
  /** Display label, e.g. "Speaker 1"; null → UI falls back to plain "Speaker". */
  speakerLabel: string | null;
}

/**
 * Assigns a speaker to each finished segment. Wrong guesses must never block
 * translation — implementations return null instead of throwing when unsure.
 */
export interface SpeakerDiarizationProvider {
  readonly name: string;
  assignSpeaker(segment: SegmentInfo): Promise<SpeakerAssignment>;
}
