import { beforeEach, describe, expect, it } from 'vitest';
import { LiveSession } from '../src/modules/realtime/live_session';
import {
  ServerMessage,
  TranscriptFinalPayload,
  TranslationCompletePayload,
} from '../src/modules/realtime/protocol';
import { HeuristicDiarizationProvider } from '../src/providers/diarization/heuristic';
import { MockSpeechProvider } from '../src/providers/speech/mock';
import {
  StreamingSpeechProvider,
  StreamingSpeechSession,
  StreamingUtterance,
} from '../src/providers/speech/types';
import { MockTranslationProvider } from '../src/providers/translation/mock';
import {
  TranslationProvider,
  TranslationProviderError,
  TranslationRequest,
  TranslationResult,
} from '../src/providers/translation';
import { setStore } from '../src/storage';
import { MemoryStore } from '../src/storage/memory';

const SEGMENT_ID = '123e4567-e89b-42d3-a456-426614174000';
const SAMPLE_RATE = 16000;
const FAST_RETRIES = { translationQueueOptions: { retryDelaysMs: [5, 5, 5] } };

function oneSecondPcm(): Buffer {
  return Buffer.alloc(SAMPLE_RATE * 2); // 1s of silence samples (mock ignores content)
}

/** Translation provider that fails a scripted number of times, then succeeds. */
class FlakyTranslationProvider implements TranslationProvider {
  readonly name = 'flaky';
  calls = 0;
  requests: TranslationRequest[] = [];

  constructor(private readonly failures: Error[] = []) {}

  async translate(request: TranslationRequest): Promise<TranslationResult> {
    this.requests.push(request);
    const failure = this.failures[this.calls++];
    if (failure) throw failure;
    return { translatedText: `[${request.targetLanguage}] ${request.text}` };
  }
}

describe('LiveSession pipeline (batch fallback)', () => {
  let sent: ServerMessage[];
  let session: LiveSession;

  beforeEach(() => {
    setStore(new MemoryStore());
    const messages: ServerMessage[] = [];
    sent = messages;
    session = new LiveSession({
      userId: 'user_test',
      speech: new MockSpeechProvider(),
      translation: new MockTranslationProvider(),
      diarization: new HeuristicDiarizationProvider(),
      send: (message) => messages.push(message),
      ...FAST_RETRIES,
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

  function transcripts(): TranscriptFinalPayload[] {
    return sent.filter((m): m is TranscriptFinalPayload => m.type === 'transcript_final');
  }

  function completions(): TranslationCompletePayload[] {
    return sent.filter((m): m is TranslationCompletePayload => m.type === 'translation_complete');
  }

  it('sends the transcript first, then completes the translation on the same messageId', async () => {
    await startSession();
    expect(sent[0]).toMatchObject({ type: 'session_started', targetLanguage: 'ar' });

    streamSegment();
    await session.handleSessionStop(); // waits for recognition + translations

    expect(transcripts()).toHaveLength(1);
    const transcript = transcripts()[0]!;
    expect(transcript).toMatchObject({
      sourceLanguage: 'es',
      originalText: 'Hola hermano, ¿cómo estás?',
      speakerLabel: 'Speaker 1',
      translationStatus: 'pending',
    });

    const completion = completions()[0];
    expect(completion).toMatchObject({
      messageId: transcript.messageId,
      translatedText: 'مرحباً يا أخي، كيف حالك؟',
    });
    // Transcript always precedes its completion.
    expect(sent.indexOf(transcript)).toBeLessThan(sent.indexOf(completion!));

    expect(sent.find((m) => m.type === 'session_ended')).toMatchObject({ translationCount: 1 });
  });

  it('ignores duplicate segment ids (reconnect protection)', async () => {
    await startSession();
    streamSegment();
    streamSegment(); // same id resent after a reconnect
    await session.handleSessionStop();

    expect(transcripts()).toHaveLength(1);
    expect(completions()).toHaveLength(1);
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
    expect(transcripts()).toHaveLength(0);
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
    expect(transcripts()).toHaveLength(0);
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
    await new Promise((resolve) => setTimeout(resolve, 20)); // fire-and-forget write

    const sessions = await store.getSessionsForUser('user_test');
    expect(sessions).toHaveLength(1);
    const messages = await store.getMessagesForSession(sessions[0]!.id);
    expect(messages).toHaveLength(1);
    expect(messages[0]!.translatedText).toBe('مرحباً يا أخي، كيف حالك؟');
    expect(messages[0]!.speakerLabel).toBe('Speaker 1');
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
  let translation: FlakyTranslationProvider;

  function makeSession(failures: Error[] = []): Promise<void> {
    setStore(new MemoryStore());
    const messages: ServerMessage[] = [];
    sent = messages;
    streaming = new FakeStreamingProvider();
    translation = new FlakyTranslationProvider(failures);
    session = new LiveSession({
      userId: 'user_test',
      speech: new MockSpeechProvider(),
      streamingSpeech: streaming,
      translation,
      diarization: new HeuristicDiarizationProvider(),
      send: (message) => messages.push(message),
      ...FAST_RETRIES,
    });
    return session.handleSessionStart({
      type: 'session_start',
      targetLanguage: 'ar',
      saveHistory: false,
    });
  }

  beforeEach(() => makeSession());

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

  function transcripts(): TranscriptFinalPayload[] {
    return sent.filter((m): m is TranscriptFinalPayload => m.type === 'transcript_final');
  }

  function completions(): TranslationCompletePayload[] {
    return sent.filter((m): m is TranslationCompletePayload => m.type === 'translation_complete');
  }

  async function settle(expectedCompletions = 1): Promise<void> {
    const deadline = Date.now() + 3000;
    while (completions().length < expectedCompletions && Date.now() < deadline) {
      await new Promise((resolve) => setTimeout(resolve, 10));
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

  it('emits the transcript immediately, then the Arabic translation for English speech', async () => {
    streamSegment(segmentId(1));
    streaming.sessions[0]!.emitUtterance({ text: 'Where is the hotel?', language: 'en' });
    streaming.sessions[0]!.emitFinalized(true);

    // Transcript is visible before any translation work finished.
    expect(transcripts()[0]).toMatchObject({
      originalText: 'Where is the hotel?',
      sourceLanguage: 'en',
      translationStatus: 'pending',
      speakerId: 'speaker_1',
      segmentId: segmentId(1),
    });

    await settle();
    expect(completions()[0]).toMatchObject({
      messageId: transcripts()[0]!.messageId,
      translatedText: '[ar] Where is the hotel?',
      targetLanguage: 'ar',
    });
  });

  it('handles English then Spanish then French on the same stream without reconnecting', async () => {
    const stream = () => streaming.sessions[0]!;
    streamSegment(segmentId(1));
    stream().emitUtterance({ text: 'Where is the hotel?', language: 'en' });
    stream().emitFinalized(true);
    streamSegment(segmentId(2));
    stream().emitUtterance({ text: 'Hola hermano amigo mío.', language: 'es' });
    stream().emitFinalized(true);
    streamSegment(segmentId(3));
    stream().emitUtterance({ text: 'Nous devons partir maintenant.', language: 'fr' });
    stream().emitFinalized(true);
    await settle(3);

    expect(streaming.sessions).toHaveLength(1); // never reconnected or reconfigured
    expect(transcripts().map((t) => t.sourceLanguage)).toEqual(['en', 'es', 'fr']);
    expect(completions().map((c) => c.translatedText)).toEqual([
      '[ar] Where is the hotel?',
      '[ar] Hola hermano amigo mío.',
      '[ar] Nous devons partir maintenant.',
    ]);
  });

  it('ALWAYS translates when the language is unknown — sourceLanguage is metadata only', async () => {
    streamSegment(segmentId(1));
    streaming.sessions[0]!.emitUtterance({
      text: 'Hola hermano', // 2 words + weak confidence → displayed as "und"
      language: 'es',
      languageConfidence: 0.55,
    });
    streaming.sessions[0]!.emitFinalized(true);
    await settle();

    expect(transcripts()[0]!.sourceLanguage).toBe('und');
    expect(completions()[0]).toMatchObject({ translatedText: '[ar] Hola hermano' });
    // The translator was really called, with "und" passed through.
    expect(translation.requests[0]).toMatchObject({ text: 'Hola hermano', sourceLanguage: 'und' });
  });

  it('still translates when the detected language equals the target (detection can be wrong)', async () => {
    // English speech misclassified as Arabic, user target Arabic: skipping
    // translation here would display untranslated English. The translator must
    // always be called; it detects the real language from the text itself.
    translation.translate = async (request) => {
      expect(request.targetLanguage).toBe('ar');
      return { translatedText: 'أين الفندق؟' };
    };

    streamSegment(segmentId(1));
    streaming.sessions[0]!.emitUtterance({
      text: 'Where is the hotel?',
      language: 'ar', // wrong label from the provider
      languageConfidence: 0.9,
    });
    streaming.sessions[0]!.emitFinalized(true);
    await settle();

    expect(transcripts()[0]).toMatchObject({
      sourceLanguage: 'ar',
      originalText: 'Where is the hotel?',
    });
    expect(completions()[0]).toMatchObject({
      messageId: transcripts()[0]!.messageId,
      translatedText: 'أين الفندق؟',
    });
  });

  it('recovers from a transient translation failure without telling the user', async () => {
    await makeSession([
      new TranslationProviderError('Translation provider error (503)', true, 503),
      new TranslationProviderError('Translation network error: reset', true),
    ]);
    streamSegment(segmentId(1));
    streaming.sessions[0]!.emitUtterance({ text: 'Where is the hotel?' });
    streaming.sessions[0]!.emitFinalized(true);
    await settle();

    expect(translation.calls).toBe(3); // two failures + the success
    expect(completions()[0]).toMatchObject({ translatedText: '[ar] Where is the hotel?' });
    // No user-facing failure of any kind during retries.
    expect(sent.find((m) => m.type === 'translation_failed')).toBeUndefined();
    expect(sent.find((m) => m.type === 'error')).toBeUndefined();
  });

  it('sends translation_failed (transcript preserved) only after retries are exhausted', async () => {
    const fail503 = () => new TranslationProviderError('Translation provider error (503)', true, 503);
    await makeSession([fail503(), fail503(), fail503(), fail503()]);
    streamSegment(segmentId(1));
    streaming.sessions[0]!.emitUtterance({ text: 'Where is the hotel?' });
    streaming.sessions[0]!.emitFinalized(true);

    const deadline = Date.now() + 3000;
    while (!sent.some((m) => m.type === 'translation_failed') && Date.now() < deadline) {
      await new Promise((resolve) => setTimeout(resolve, 10));
    }

    expect(translation.calls).toBe(4);
    expect(sent.find((m) => m.type === 'translation_failed')).toMatchObject({
      messageId: transcripts()[0]!.messageId,
    });
    // The transcript event was sent and is never retracted; no generic error.
    expect(transcripts()).toHaveLength(1);
    expect(sent.find((m) => m.type === 'error')).toBeUndefined();
  });

  it('retry_translation resubmits the same text and updates the same messageId', async () => {
    await makeSession([
      new TranslationProviderError('Translation provider error (401)', false, 401), // fails fast
    ]);
    streamSegment(segmentId(1));
    streaming.sessions[0]!.emitUtterance({ text: 'Where is the hotel?' });
    streaming.sessions[0]!.emitFinalized(true);

    const deadline = Date.now() + 3000;
    while (!sent.some((m) => m.type === 'translation_failed') && Date.now() < deadline) {
      await new Promise((resolve) => setTimeout(resolve, 10));
    }
    const messageId = transcripts()[0]!.messageId;

    session.handleRetryTranslation(messageId);
    await settle();

    expect(completions()[0]).toMatchObject({
      messageId,
      translatedText: '[ar] Where is the hotel?',
    });
    expect(transcripts()).toHaveLength(1); // still one message, updated in place
    expect(translation.requests.at(-1)).toMatchObject({ text: 'Where is the hotel?' });
  });

  it('a duplicate retry for a completed message re-sends the result, never re-translates', async () => {
    streamSegment(segmentId(1));
    streaming.sessions[0]!.emitUtterance({ text: 'Where is the hotel?' });
    streaming.sessions[0]!.emitFinalized(true);
    await settle();
    const callsAfterFirst = translation.calls;
    const messageId = transcripts()[0]!.messageId;

    session.handleRetryTranslation(messageId); // e.g. resent after a reconnect
    await settle(2);

    expect(translation.calls).toBe(callsAfterFirst); // no second API call
    expect(completions()).toHaveLength(2);
    expect(completions()[1]).toMatchObject({ messageId, translatedText: '[ar] Where is the hotel?' });
  });

  it('keeps accepting speech while earlier utterances are still translating', async () => {
    await makeSession();
    let release!: () => void;
    const gate = new Promise<void>((resolve) => (release = resolve));
    translation.translate = async (request) => {
      if (request.text === 'First utterance blocked') await gate;
      return { translatedText: `[ar] ${request.text}` };
    };

    streamSegment(segmentId(1));
    streaming.sessions[0]!.emitUtterance({ text: 'First utterance blocked' });
    streaming.sessions[0]!.emitFinalized(true);
    streamSegment(segmentId(2));
    streaming.sessions[0]!.emitUtterance({ text: 'Second utterance flows' });
    streaming.sessions[0]!.emitFinalized(true);
    await settle(1); // the second utterance completes while the first is stuck

    expect(transcripts().map((t) => t.originalText)).toEqual([
      'First utterance blocked',
      'Second utterance flows',
    ]);
    expect(completions()[0]).toMatchObject({ translatedText: '[ar] Second utterance flows' });

    release();
    await settle(2);
    expect(completions()).toHaveLength(2);
  });

  it('keeps the provider speaker id when the same speaker talks twice', async () => {
    streamSegment(segmentId(1));
    streaming.sessions[0]!.emitUtterance({ text: 'First sentence here', speakerId: 'speaker_1' });
    streaming.sessions[0]!.emitFinalized(true);
    streamSegment(segmentId(2));
    streaming.sessions[0]!.emitUtterance({ text: 'Second sentence here', speakerId: 'speaker_1' });
    streaming.sessions[0]!.emitFinalized(true);
    await settle(2);

    expect(transcripts().map((t) => t.speakerId)).toEqual(['speaker_1', 'speaker_1']);
    expect(transcripts().map((t) => t.speakerLabel)).toEqual(['Speaker 1', 'Speaker 1']);
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

    expect(transcripts().map((t) => t.speakerId)).toEqual(['speaker_1', 'speaker_2']);
    expect(transcripts().map((t) => t.speakerLabel)).toEqual(['Speaker 1', 'Speaker 2']);
  });

  it('drops a finalized segment that produced no speech', async () => {
    streamSegment(segmentId(1));
    streaming.sessions[0]!.emitFinalized(false);
    await new Promise((resolve) => setTimeout(resolve, 20));

    expect(sent.find((m) => m.type === 'segment_dropped')).toMatchObject({
      segmentId: segmentId(1),
      reason: 'no_speech',
    });
    expect(transcripts()).toHaveLength(0);
  });

  it('falls back to batch recognition when the stream errors', async () => {
    streamSegment(segmentId(1));
    streaming.sessions[0]!.emitError('boom');

    // Next segment goes through the batch pipeline (MockSpeechProvider).
    streamSegment(segmentId(2));
    await session.handleSessionStop();

    expect(streaming.sessions).toHaveLength(1); // no second stream attempt
    expect(transcripts()[0]?.diagnostics?.sttProvider).toBe('mock');
    expect(completions()).toHaveLength(1);
  });

  it('closes the provider stream when the session stops', async () => {
    streamSegment(segmentId(1));
    streaming.sessions[0]!.emitUtterance({ text: 'Where is the hotel?' });
    streaming.sessions[0]!.emitFinalized(true);
    await session.handleSessionStop();

    expect(streaming.sessions[0]!.closed).toBe(true);
    expect(sent.find((m) => m.type === 'session_ended')).toMatchObject({ translationCount: 1 });
  });
});
