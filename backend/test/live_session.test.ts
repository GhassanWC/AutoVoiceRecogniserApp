import { beforeEach, describe, expect, it } from 'vitest';
import { LiveSession } from '../src/modules/realtime/live_session';
import { ServerMessage, TranslationMessagePayload } from '../src/modules/realtime/protocol';
import { HeuristicDiarizationProvider } from '../src/providers/diarization/heuristic';
import { MockSpeechProvider } from '../src/providers/speech/mock';
import {
  StreamingSpeechProvider,
  StreamingSpeechSession,
  StreamingUtterance,
} from '../src/providers/speech/types';
import { MockTranslationProvider } from '../src/providers/translation/mock';
import { setStore } from '../src/storage';
import { MemoryStore } from '../src/storage/memory';

const SEGMENT_ID = '123e4567-e89b-42d3-a456-426614174000';
const SAMPLE_RATE = 16000;

function oneSecondPcm(): Buffer {
  return Buffer.alloc(SAMPLE_RATE * 2); // 1s of silence samples (mock ignores content)
}

describe('LiveSession pipeline', () => {
  let sent: ServerMessage[];
  let session: LiveSession;

  beforeEach(() => {
    setStore(new MemoryStore());
    sent = [];
    session = new LiveSession({
      userId: 'user_test',
      speech: new MockSpeechProvider(),
      translation: new MockTranslationProvider(),
      diarization: new HeuristicDiarizationProvider(),
      send: (message) => sent.push(message),
    });
  });

  async function startSession(): Promise<void> {
    await session.handleSessionStart({
      type: 'session_start',
      targetLanguage: 'ar',
      saveHistory: false,
    });
  }

  function streamSegment(segmentId: string = SEGMENT_ID): void {
    session.handleSegmentStart({
      type: 'segment_start',
      segmentId,
      sampleRate: SAMPLE_RATE,
      channels: 1,
      encoding: 'pcm16',
    });
    session.handleAudioFrame({ segmentId, sequence: 0, pcm: oneSecondPcm() });
    session.handleSegmentEnd(segmentId);
  }

  it('produces a translation for a streamed segment', async () => {
    await startSession();
    expect(sent[0]).toMatchObject({ type: 'session_started', targetLanguage: 'ar' });

    streamSegment();
    await session.handleSessionStop(); // waits for the processing queue

    const translation = sent.find((m) => m.type === 'translation');
    expect(translation).toBeDefined();
    expect(translation).toMatchObject({
      sourceLanguage: 'es',
      translatedText: 'مرحباً يا أخي، كيف حالك؟',
      speakerLabel: 'Speaker 1',
    });

    const ended = sent.find((m) => m.type === 'session_ended');
    expect(ended).toMatchObject({ translationCount: 1 });
  });

  it('ignores duplicate segment ids (reconnect protection)', async () => {
    await startSession();
    streamSegment();
    streamSegment(); // same id resent after a reconnect
    await session.handleSessionStop();

    const translations = sent.filter((m) => m.type === 'translation');
    expect(translations).toHaveLength(1);
  });

  it('drops segments that are too short instead of translating noise', async () => {
    await startSession();
    session.handleSegmentStart({
      type: 'segment_start',
      segmentId: SEGMENT_ID,
      sampleRate: SAMPLE_RATE,
      channels: 1,
      encoding: 'pcm16',
    });
    session.handleAudioFrame({ segmentId: SEGMENT_ID, sequence: 0, pcm: Buffer.alloc(800) });
    session.handleSegmentEnd(SEGMENT_ID);
    await session.handleSessionStop();

    expect(sent.find((m) => m.type === 'segment_dropped')).toMatchObject({ reason: 'too_short' });
    expect(sent.find((m) => m.type === 'translation')).toBeUndefined();
  });

  it('honors the client VAD marking a segment as discarded (duration 0)', async () => {
    await startSession();
    session.handleSegmentStart({
      type: 'segment_start',
      segmentId: SEGMENT_ID,
      sampleRate: SAMPLE_RATE,
      channels: 1,
      encoding: 'pcm16',
    });
    session.handleAudioFrame({ segmentId: SEGMENT_ID, sequence: 0, pcm: oneSecondPcm() });
    session.handleSegmentEnd(SEGMENT_ID, 0);
    await session.handleSessionStop();

    expect(sent.find((m) => m.type === 'segment_dropped')).toMatchObject({
      reason: 'discarded_by_client',
    });
    expect(sent.find((m) => m.type === 'translation')).toBeUndefined();
  });

  it('drops a segment when audio frames go missing', async () => {
    await startSession();
    session.handleSegmentStart({
      type: 'segment_start',
      segmentId: SEGMENT_ID,
      sampleRate: SAMPLE_RATE,
      channels: 1,
      encoding: 'pcm16',
    });
    session.handleAudioFrame({ segmentId: SEGMENT_ID, sequence: 0, pcm: oneSecondPcm() });
    session.handleAudioFrame({ segmentId: SEGMENT_ID, sequence: 2, pcm: oneSecondPcm() }); // gap
    await session.handleSessionStop();

    expect(sent.find((m) => m.type === 'segment_dropped')).toMatchObject({ reason: 'audio_gap' });
  });

  it('refuses audio before session_start', () => {
    session.handleSegmentStart({
      type: 'segment_start',
      segmentId: SEGMENT_ID,
      sampleRate: SAMPLE_RATE,
      channels: 1,
      encoding: 'pcm16',
    });
    expect(sent.find((m) => m.type === 'error')).toMatchObject({ code: 'no_session' });
  });

  it('persists messages when saveHistory is on', async () => {
    const store = new MemoryStore();
    setStore(store);
    await session.handleSessionStart({
      type: 'session_start',
      targetLanguage: 'ar',
      saveHistory: true,
    });
    streamSegment();
    await session.handleSessionStop();

    const sessions = await store.getSessionsForUser('user_test');
    expect(sessions).toHaveLength(1);
    const messages = await store.getMessagesForSession(sessions[0]!.id);
    expect(messages).toHaveLength(1);
    expect(messages[0]!.translatedText).toBe('مرحباً يا أخي، كيف حالك؟');
  });
});

// ── Streaming pipeline (Deepgram-style provider) ──────────────────────────────

class FakeStreamingSession implements StreamingSpeechSession {
  audioBytes = 0;
  finalizeCount = 0;
  closed = false;

  private utteranceHandler: (utterance: StreamingUtterance) => void = () => undefined;
  private finalizedHandler: (hadSpeech: boolean) => void = () => undefined;
  private errorHandler: (error: Error) => void = () => undefined;

  sendAudio(pcm: Buffer): void {
    this.audioBytes += pcm.length;
  }
  finalize(): void {
    this.finalizeCount += 1;
  }
  async close(): Promise<void> {
    this.closed = true;
  }
  onUtterance(handler: (utterance: StreamingUtterance) => void): void {
    this.utteranceHandler = handler;
  }
  onFinalized(handler: (hadSpeech: boolean) => void): void {
    this.finalizedHandler = handler;
  }
  onError(handler: (error: Error) => void): void {
    this.errorHandler = handler;
  }

  emitUtterance(partial: Partial<StreamingUtterance> & { text: string }): void {
    this.utteranceHandler({
      language: 'en',
      languageConfidence: 0.95,
      transcriptionConfidence: 0.94,
      speakerId: 'speaker_1',
      startMs: 0,
      endMs: 1000,
      ...partial,
    });
  }
  emitFinalized(hadSpeech: boolean): void {
    this.finalizedHandler(hadSpeech);
  }
  emitError(message: string): void {
    this.errorHandler(new Error(message));
  }
}

class FakeStreamingProvider implements StreamingSpeechProvider {
  readonly name = 'fake-stream';
  readonly sessions: FakeStreamingSession[] = [];

  createSession(): StreamingSpeechSession {
    const session = new FakeStreamingSession();
    this.sessions.push(session);
    return session;
  }
}

describe('LiveSession streaming pipeline', () => {
  let sent: ServerMessage[];
  let session: LiveSession;
  let streaming: FakeStreamingProvider;

  beforeEach(async () => {
    setStore(new MemoryStore());
    // Bind the array itself (not the reassignable variable) so a translation
    // finishing late in one test can never leak into the next test's list.
    const messages: ServerMessage[] = [];
    sent = messages;
    streaming = new FakeStreamingProvider();
    session = new LiveSession({
      userId: 'user_test',
      speech: new MockSpeechProvider(),
      streamingSpeech: streaming,
      translation: new MockTranslationProvider(),
      diarization: new HeuristicDiarizationProvider(),
      send: (message) => messages.push(message),
    });
    await session.handleSessionStart({
      type: 'session_start',
      targetLanguage: 'ar',
      saveHistory: false,
    });
  });

  function segmentId(n: number): string {
    return `123e4567-e89b-42d3-a456-42661417400${n}`;
  }

  function streamSegment(id: string): void {
    session.handleSegmentStart({
      type: 'segment_start',
      segmentId: id,
      sampleRate: SAMPLE_RATE,
      channels: 1,
      encoding: 'pcm16',
    });
    session.handleAudioFrame({ segmentId: id, sequence: 0, pcm: oneSecondPcm() });
    session.handleSegmentEnd(id, 1000);
  }

  function translations(): TranslationMessagePayload[] {
    return sent.filter((m): m is TranslationMessagePayload => m.type === 'translation');
  }

  async function settle(expectedTranslations = 1): Promise<void> {
    // Wait until the internal processing queue delivered the expected results
    // (the translation mock has latency), with a hard cap as a safety net.
    const deadline = Date.now() + 3000;
    while (translations().length < expectedTranslations && Date.now() < deadline) {
      await new Promise((resolve) => setTimeout(resolve, 25));
    }
  }

  it('forwards all segment audio into one provider stream and finalizes per segment', async () => {
    streamSegment(segmentId(1));
    streamSegment(segmentId(2));

    expect(streaming.sessions).toHaveLength(1); // one stream for the whole session
    const stream = streaming.sessions[0]!;
    expect(stream.audioBytes).toBe(2 * SAMPLE_RATE * 2); // VAD pre-roll → hangover, all preserved
    expect(stream.finalizeCount).toBe(2);
  });

  it('translates English to Arabic', async () => {
    streamSegment(segmentId(1));
    streaming.sessions[0]!.emitUtterance({ text: 'Good morning everyone', language: 'en' });
    streaming.sessions[0]!.emitFinalized(true);
    await settle();

    expect(translations()[0]).toMatchObject({
      sourceLanguage: 'en',
      originalText: 'Good morning everyone',
      translatedText: '[ar] Good morning everyone',
      targetLanguage: 'ar',
      transcriptionConfidence: 0.94,
      segmentId: segmentId(1),
    });
  });

  it('translates Spanish to Arabic', async () => {
    streamSegment(segmentId(1));
    streaming.sessions[0]!.emitUtterance({
      text: 'Hola hermano, ¿cómo estás?',
      language: 'es',
      languageConfidence: 0.97,
    });
    streaming.sessions[0]!.emitFinalized(true);
    await settle();

    expect(translations()[0]).toMatchObject({
      sourceLanguage: 'es',
      translatedText: 'مرحباً يا أخي، كيف حالك؟',
    });
  });

  it('translates French to Arabic', async () => {
    streamSegment(segmentId(1));
    streaming.sessions[0]!.emitUtterance({
      text: "Où est l'hôtel?",
      language: 'fr',
      languageConfidence: 0.96,
    });
    streaming.sessions[0]!.emitFinalized(true);
    await settle();

    expect(translations()[0]).toMatchObject({
      sourceLanguage: 'fr',
      translatedText: 'أين الفندق؟',
    });
  });

  it('handles English then Spanish then French on the same stream without reconnecting', async () => {
    const stream = () => streaming.sessions[0]!;
    streamSegment(segmentId(1));
    stream().emitUtterance({ text: 'Good morning everyone', language: 'en' });
    stream().emitFinalized(true);
    streamSegment(segmentId(2));
    stream().emitUtterance({ text: 'Buenos días a todos amigos', language: 'es' });
    stream().emitFinalized(true);
    streamSegment(segmentId(3));
    stream().emitUtterance({ text: 'Bonjour tout le monde', language: 'fr' });
    stream().emitFinalized(true);
    await settle(3);

    expect(streaming.sessions).toHaveLength(1); // never reconnected or reconfigured
    expect(translations().map((t) => t.sourceLanguage)).toEqual(['en', 'es', 'fr']);
  });

  it('keeps the provider speaker id when the same speaker talks twice', async () => {
    streamSegment(segmentId(1));
    streaming.sessions[0]!.emitUtterance({ text: 'First sentence here', speakerId: 'speaker_1' });
    streaming.sessions[0]!.emitFinalized(true);
    streamSegment(segmentId(2));
    streaming.sessions[0]!.emitUtterance({ text: 'Second sentence here', speakerId: 'speaker_1' });
    streaming.sessions[0]!.emitFinalized(true);
    await settle(2);

    expect(translations().map((t) => t.speakerId)).toEqual(['speaker_1', 'speaker_1']);
    expect(translations().map((t) => t.speakerLabel)).toEqual(['Speaker 1', 'Speaker 1']);
  });

  it('preserves distinct provider speaker ids for two speakers, even in one language', async () => {
    streamSegment(segmentId(1));
    streaming.sessions[0]!.emitUtterance({
      text: 'How are you today',
      language: 'en',
      speakerId: 'speaker_1',
    });
    streaming.sessions[0]!.emitUtterance({
      text: 'I am doing fine',
      language: 'en',
      speakerId: 'speaker_2',
    });
    streaming.sessions[0]!.emitFinalized(true);
    await settle(2);

    expect(translations().map((t) => t.speakerId)).toEqual(['speaker_1', 'speaker_2']);
    expect(translations().map((t) => t.speakerLabel)).toEqual(['Speaker 1', 'Speaker 2']);
  });

  it('reports "und" instead of guessing a language for short low-confidence utterances', async () => {
    streamSegment(segmentId(1));
    streaming.sessions[0]!.emitUtterance({
      text: 'yes',
      language: 'en',
      languageConfidence: 0.55,
    });
    streaming.sessions[0]!.emitFinalized(true);
    await settle();

    const translation = translations()[0]!;
    expect(translation.sourceLanguage).toBe('und');
    expect(translation.diagnostics?.detectedLanguage).toBe('en'); // raw value still visible to devs
  });

  it('drops a finalized segment that produced no speech', async () => {
    streamSegment(segmentId(1));
    streaming.sessions[0]!.emitFinalized(false);
    await new Promise((resolve) => setTimeout(resolve, 50));

    expect(sent.find((m) => m.type === 'segment_dropped')).toMatchObject({
      segmentId: segmentId(1),
      reason: 'no_speech',
    });
    expect(translations()).toHaveLength(0);
  });

  it('falls back to batch recognition when the stream errors', async () => {
    streamSegment(segmentId(1));
    streaming.sessions[0]!.emitError('boom');

    // Next segment goes through the batch pipeline (MockSpeechProvider).
    streamSegment(segmentId(2));
    await session.handleSessionStop();

    expect(streaming.sessions).toHaveLength(1); // no second stream attempt
    const translation = translations()[0];
    expect(translation).toBeDefined();
    expect(translation!.diagnostics?.sttProvider).toBe('mock');
  });

  it('closes the provider stream when the session stops', async () => {
    streamSegment(segmentId(1));
    streaming.sessions[0]!.emitUtterance({ text: 'Good morning everyone' });
    streaming.sessions[0]!.emitFinalized(true);
    await session.handleSessionStop();

    expect(streaming.sessions[0]!.closed).toBe(true);
    expect(sent.find((m) => m.type === 'session_ended')).toBeDefined();
  });
});
