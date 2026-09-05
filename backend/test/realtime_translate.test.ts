import { beforeEach, describe, expect, it } from 'vitest';
import { LiveSession } from '../src/modules/realtime/live_session';
import {
  ServerMessage,
  TranscriptFinalPayload,
  TranslationCompletePayload,
  TranslationDeltaPayload,
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
  RealtimeTranslationProvider,
  RealtimeTranslationSession,
  TranslationUtteranceAssembler,
} from '../src/providers/translation/openai_realtime_translate';
import { setStore } from '../src/storage';
import { MemoryStore } from '../src/storage/memory';

describe('TranslationUtteranceAssembler', () => {
  it('groups deltas into one utterance and finalizes after the gap', () => {
    const assembler = new TranslationUtteranceAssembler(900);
    const first = assembler.addOutputDelta('مرح', 1000);
    expect(first).toEqual({ utteranceId: 'utterance_1', isFirst: true });
    expect(assembler.addOutputDelta('باً', 1200)).toEqual({
      utteranceId: 'utterance_1',
      isFirst: false,
    });
    assembler.addInputDelta('Hel');
    assembler.addInputDelta('lo');

    expect(assembler.flushIfIdle(1500)).toBeNull(); // gap not elapsed
    expect(assembler.flushIfIdle(2200)).toEqual({
      utteranceId: 'utterance_1',
      translatedText: 'مرحباً',
      sourceText: 'Hello',
    });
    expect(assembler.activeUtteranceId).toBeNull();
  });

  it('starts a new utterance id after a finalized one', () => {
    const assembler = new TranslationUtteranceAssembler(900);
    assembler.addOutputDelta('مرحباً', 0);
    assembler.flushIfIdle(1000);
    expect(assembler.addOutputDelta('صباح', 5000).utteranceId).toBe('utterance_2');
  });

  it('force-flush finalizes immediately and drops empty utterances', () => {
    const assembler = new TranslationUtteranceAssembler(900);
    assembler.addOutputDelta('  ', 0);
    expect(assembler.flushIfIdle(1, true)).toBeNull(); // whitespace-only → dropped
    assembler.addOutputDelta('أهلاً', 10);
    expect(assembler.flushIfIdle(11, true)?.translatedText).toBe('أهلاً');
  });
});

// ── LiveSession with the primary realtime-translate path ──────────────────────

class FakeTranslateSession implements RealtimeTranslationSession {
  audioBytes = 0;
  closed = false;
  private deltaHandler: (utteranceId: string, delta: string) => void = () => undefined;
  private finalHandler: (id: string, text: string, source: string) => void = () => undefined;
  private errorHandler: (error: Error) => void = () => undefined;
  private boundaryHandler: (boundary: 'started' | 'stopped') => void = () => undefined;

  sendAudio(pcm: Buffer): void {
    this.audioBytes += pcm.length;
  }
  async close(): Promise<void> {
    this.closed = true;
  }
  onDelta(handler: (utteranceId: string, delta: string) => void): void {
    this.deltaHandler = handler;
  }
  onUtteranceFinal(handler: (id: string, text: string, source: string) => void): void {
    this.finalHandler = handler;
  }
  onError(handler: (error: Error) => void): void {
    this.errorHandler = handler;
  }
  onSpeechBoundary(handler: (boundary: 'started' | 'stopped') => void): void {
    this.boundaryHandler = handler;
  }

  emitDelta(utteranceId: string, delta: string): void {
    this.deltaHandler(utteranceId, delta);
  }
  emitSpeechBoundary(boundary: 'started' | 'stopped'): void {
    this.boundaryHandler(boundary);
  }
  emitFinal(utteranceId: string, text: string, source: string): void {
    this.finalHandler(utteranceId, text, source);
  }
  emitError(message: string): void {
    this.errorHandler(new Error(message));
  }
}

class FakeTranslateProvider implements RealtimeTranslationProvider {
  readonly name = 'fake-translate';
  readonly sessions: FakeTranslateSession[] = [];
  readonly options: Array<{ sampleRate: number; targetLanguage: string }> = [];

  createSession(options: { sampleRate: number; targetLanguage: string }): RealtimeTranslationSession {
    this.options.push(options);
    const session = new FakeTranslateSession();
    this.sessions.push(session);
    return session;
  }
}

class FallbackSttSession implements StreamingSpeechSession {
  audioBytes = 0;
  private utteranceHandler: (utterance: StreamingUtterance) => void = () => undefined;

  sendAudio(pcm: Buffer): void {
    this.audioBytes += pcm.length;
  }
  finalize(): void {}
  async close(): Promise<void> {}
  onUtterance(handler: (utterance: StreamingUtterance) => void): void {
    this.utteranceHandler = handler;
  }
  onFinalized(): void {}
  onError(): void {}

  emitUtterance(text: string): void {
    this.utteranceHandler({
      text,
      language: 'und',
      languageConfidence: 0,
      transcriptionConfidence: 0.9,
      speakerId: null,
      startMs: 0,
      endMs: 1000,
    });
  }
}

class FallbackSttProvider implements StreamingSpeechProvider {
  readonly name = 'fallback-stt';
  readonly sessions: FallbackSttSession[] = [];
  get created(): number {
    return this.sessions.length;
  }
  createSession(): StreamingSpeechSession {
    const session = new FallbackSttSession();
    this.sessions.push(session);
    return session;
  }
}

/** 100 ms @16 kHz square-wave frame; RMS = amplitude / 32768. */
function toneFrame(amplitude: number): Buffer {
  const pcm = Buffer.alloc(3200);
  for (let i = 0; i < 1600; i++) pcm.writeInt16LE(amplitude, i * 2);
  return pcm;
}
const loudFrame = () => toneFrame(8000); // near-field speech, RMS ≈ 0.244
const distantFrame = () => toneFrame(131); // TV/distant speech, RMS ≈ 0.004
const roomToneFrame = () => toneFrame(49); // quiet room, RMS ≈ 0.0015
const silentFrame = () => Buffer.alloc(3200);

describe('LiveSession primary realtime-translate path', () => {
  const STREAM_ID = '123e4567-e89b-42d3-a456-426614174099';
  let sent: ServerMessage[];
  let session: LiveSession;
  let translate: FakeTranslateProvider;
  let fallback: FallbackSttProvider;

  beforeEach(async () => {
    setStore(new MemoryStore());
    const messages: ServerMessage[] = [];
    sent = messages;
    translate = new FakeTranslateProvider();
    fallback = new FallbackSttProvider();
    session = new LiveSession({
      userId: 'user_test',
      speech: new MockSpeechProvider(),
      streamingSpeech: fallback,
      translation: new MockTranslationProvider(),
      realtimeTranslation: translate,
      diarization: new HeuristicDiarizationProvider(),
      send: (message) => messages.push(message),
      translationQueueOptions: { retryDelaysMs: [5, 5, 5] },
    });
    await session.handleSessionStart({
      type: 'session_start',
      targetLanguage: 'ar',
      saveHistory: false,
    });
    session.handleStreamStart({
      type: 'stream_start',
      streamId: STREAM_ID,
      sampleRate: 16000,
      channels: 1,
      encoding: 'pcm16',
    });
  });

  function transcripts(): TranscriptFinalPayload[] {
    return sent.filter((m): m is TranscriptFinalPayload => m.type === 'transcript_final');
  }
  function deltas(): TranslationDeltaPayload[] {
    return sent.filter((m): m is TranslationDeltaPayload => m.type === 'translation_delta');
  }
  function completions(): TranslationCompletePayload[] {
    return sent.filter((m): m is TranslationCompletePayload => m.type === 'translation_complete');
  }

  it('prefers realtime-translate over the STT fallback and passes the target language', () => {
    expect(translate.sessions).toHaveLength(1);
    expect(translate.options[0]).toEqual({ sampleRate: 16000, targetLanguage: 'ar' });
    expect(fallback.created).toBe(0); // fallback untouched while primary works
  });

  it('forwards all continuous audio into the translate session', () => {
    for (let i = 0; i < 5; i++) {
      session.handleAudioFrame({ segmentId: STREAM_ID, sequence: i, pcm: Buffer.alloc(3200) });
    }
    expect(translate.sessions[0]!.audioBytes).toBe(5 * 3200);
  });

  it('creates one bubble per utterance: transcript_final, streamed deltas, then final', () => {
    const stream = translate.sessions[0]!;
    stream.emitDelta('utterance_1', 'مرح');
    stream.emitDelta('utterance_1', 'باً');
    stream.emitFinal('utterance_1', 'مرحباً', 'Hello');

    expect(transcripts()).toHaveLength(1); // one bubble, created on first delta
    const messageId = transcripts()[0]!.messageId;
    expect(transcripts()[0]).toMatchObject({
      segmentId: STREAM_ID,
      originalText: '',
      translationStatus: 'pending',
      speakerId: null, // diarization is out of the primary MVP path
    });
    expect(deltas().map((d) => [d.messageId, d.delta])).toEqual([
      [messageId, 'مرح'],
      [messageId, 'باً'],
    ]);
    expect(completions()[0]).toMatchObject({
      messageId,
      translatedText: 'مرحباً',
      originalText: 'Hello', // source transcript fills in at finalization
      targetLanguage: 'ar',
    });
    // Order: bubble → deltas → final.
    expect(sent.indexOf(transcripts()[0]!)).toBeLessThan(sent.indexOf(deltas()[0]!));
    expect(sent.indexOf(deltas()[1]!)).toBeLessThan(sent.indexOf(completions()[0]!));
  });

  it('keeps separate utterances in separate bubbles with distinct messageIds', () => {
    const stream = translate.sessions[0]!;
    stream.emitDelta('utterance_1', 'مرحباً');
    stream.emitFinal('utterance_1', 'مرحباً', 'Hello');
    stream.emitDelta('utterance_2', 'صباح الخير');
    stream.emitFinal('utterance_2', 'صباح الخير', 'Good morning');

    expect(transcripts()).toHaveLength(2);
    expect(new Set(transcripts().map((t) => t.messageId)).size).toBe(2);
    expect(completions().map((c) => c.translatedText)).toEqual(['مرحباً', 'صباح الخير']);
    expect(sent.find((m) => m.type === 'session_ended')).toBeUndefined();
  });

  it('falls back to the STT + text-translation pipeline after repeated errors', async () => {
    // 1 initial session + 3 reopen attempts, then permanent failure.
    for (let i = 0; i < 4; i++) {
      translate.sessions[i]!.emitError('boom');
      await new Promise((resolve) => setTimeout(resolve, 600));
    }
    expect(translate.sessions).toHaveLength(4);
    expect(fallback.created).toBe(1); // fallback STT stream opened
    // Audio now flows to the fallback, not a dead translate session.
    session.handleAudioFrame({ segmentId: STREAM_ID, sequence: 0, pcm: Buffer.alloc(3200) });
    expect(sent.find((m) => m.type === 'error')).toBeUndefined(); // seamless switch
  });

  // ── Utterance-based failover ────────────────────────────────────────────────

  /** Speak a short phrase (500 ms) and let it end (700 ms of silence). */
  function speakShortPhrase(startSeq = 0): void {
    let seq = startSeq;
    for (let i = 0; i < 5; i++) {
      session.handleAudioFrame({ segmentId: STREAM_ID, sequence: seq++, pcm: loudFrame() });
    }
    for (let i = 0; i < 7; i++) {
      session.handleAudioFrame({ segmentId: STREAM_ID, sequence: seq++, pcm: silentFrame() });
    }
  }

  it('short phrase with no direct translation delta → fallback fires on the same messageId', async () => {
    speakShortPhrase(); // "Hello" — well under 4 s; failover must not need more

    // Deadline (~1.4 s after speech end) passes with zero direct output.
    await new Promise((resolve) => setTimeout(resolve, 1700));

    expect(fallback.created).toBe(1); // fallback STT stream opened
    expect(translate.sessions[0]!.closed).toBe(true); // defective session dropped
    // The buffered utterance (pre-roll + speech + silence) was replayed,
    // plus trailing silence so the fallback endpoints it immediately.
    expect(fallback.sessions[0]!.audioBytes).toBeGreaterThan(5 * 3200);
    expect(sent.find((m) => m.type === 'error')).toBeUndefined(); // invisible switch

    // The fallback transcribes the replayed utterance → same-bubble flow.
    fallback.sessions[0]!.emitUtterance('Hello');
    const deadline = Date.now() + 3000;
    while (completions().length < 1 && Date.now() < deadline) {
      await new Promise((resolve) => setTimeout(resolve, 10));
    }
    expect(transcripts()).toHaveLength(1); // ONE bubble, not a duplicate
    expect(completions()[0]!.messageId).toBe(transcripts()[0]!.messageId);
    expect(completions()[0]!.translatedText).toContain('Hello'); // mock: "[ar] Hello"

    // Live audio now flows into the fallback stream.
    const bytesBefore = fallback.sessions[0]!.audioBytes;
    session.handleAudioFrame({ segmentId: STREAM_ID, sequence: 99, pcm: loudFrame() });
    expect(fallback.sessions[0]!.audioBytes).toBe(bytesBefore + 3200);
  });

  it('direct translation arriving in time disarms the failover', async () => {
    // Deltas stream while the phrase is still being spoken.
    for (let i = 0; i < 3; i++) {
      session.handleAudioFrame({ segmentId: STREAM_ID, sequence: i, pcm: loudFrame() });
    }
    translate.sessions[0]!.emitDelta('utterance_1', 'مرحباً');
    for (let i = 3; i < 5; i++) {
      session.handleAudioFrame({ segmentId: STREAM_ID, sequence: i, pcm: loudFrame() });
    }
    for (let i = 5; i < 12; i++) {
      session.handleAudioFrame({ segmentId: STREAM_ID, sequence: i, pcm: silentFrame() });
    }
    await new Promise((resolve) => setTimeout(resolve, 1700));

    expect(fallback.created).toBe(0); // no failover
    expect(translate.sessions).toHaveLength(1);
    expect(translate.sessions[0]!.closed).toBe(false); // healthy session kept
    expect(transcripts()).toHaveLength(1); // the direct bubble
  });

  it('a direct delta within the deadline claims the reserved messageId', async () => {
    speakShortPhrase();
    // Direct output arrives late but INSIDE the 1.4 s window.
    await new Promise((resolve) => setTimeout(resolve, 300));
    translate.sessions[0]!.emitDelta('utterance_1', 'مرحباً');
    translate.sessions[0]!.emitFinal('utterance_1', 'مرحباً', 'Hello');
    await new Promise((resolve) => setTimeout(resolve, 1500));

    expect(fallback.created).toBe(0); // deadline was disarmed
    expect(transcripts()).toHaveLength(1);
    expect(completions()[0]!.messageId).toBe(transcripts()[0]!.messageId);
  });

  it('distant/TV-level speech (RMS ≈ 0.004 over a quiet floor) arms failover', async () => {
    // Quiet room first so the adaptive floor settles near 0.0015 — with the
    // old fixed 0.01 threshold this speech would have been invisible.
    let seq = 0;
    for (let i = 0; i < 20; i++) {
      session.handleAudioFrame({ segmentId: STREAM_ID, sequence: seq++, pcm: roomToneFrame() });
    }
    for (let i = 0; i < 5; i++) {
      session.handleAudioFrame({ segmentId: STREAM_ID, sequence: seq++, pcm: distantFrame() });
    }
    for (let i = 0; i < 7; i++) {
      session.handleAudioFrame({ segmentId: STREAM_ID, sequence: seq++, pcm: roomToneFrame() });
    }
    await new Promise((resolve) => setTimeout(resolve, 1700));

    expect(fallback.created).toBe(1); // low-volume speech still protected
    expect(translate.sessions[0]!.closed).toBe(true);
  });

  it('quiet room noise alone never arms failover', async () => {
    for (let i = 0; i < 40; i++) {
      session.handleAudioFrame({ segmentId: STREAM_ID, sequence: i, pcm: roomToneFrame() });
    }
    await new Promise((resolve) => setTimeout(resolve, 1700));

    expect(fallback.created).toBe(0);
    expect(translate.sessions[0]!.closed).toBe(false);
  });

  it('provider speech_started/stopped events own the boundary when available', async () => {
    const stream = translate.sessions[0]!;
    stream.emitSpeechBoundary('started');
    let seq = 0;
    for (let i = 0; i < 5; i++) {
      session.handleAudioFrame({ segmentId: STREAM_ID, sequence: seq++, pcm: loudFrame() });
    }
    for (let i = 0; i < 7; i++) {
      session.handleAudioFrame({ segmentId: STREAM_ID, sequence: seq++, pcm: silentFrame() });
    }
    // Energy-detected "end" is suppressed while provider events are active —
    // nothing arms until the provider says the utterance stopped.
    await new Promise((resolve) => setTimeout(resolve, 1600));
    expect(fallback.created).toBe(0);

    stream.emitSpeechBoundary('stopped'); // still no delta → deadline arms
    await new Promise((resolve) => setTimeout(resolve, 1700));
    expect(fallback.created).toBe(1);
    expect(translate.sessions[0]!.closed).toBe(true);
  });

  it('late direct output after failover never creates a duplicate', async () => {
    speakShortPhrase();
    await new Promise((resolve) => setTimeout(resolve, 1700)); // failover fired
    fallback.sessions[0]!.emitUtterance('Hello');
    const deadline = Date.now() + 3000;
    while (completions().length < 1 && Date.now() < deadline) {
      await new Promise((resolve) => setTimeout(resolve, 10));
    }

    // The defective session's output finally shows up — must be ignored.
    translate.sessions[0]!.emitDelta('utterance_1', 'مرحباً');
    translate.sessions[0]!.emitFinal('utterance_1', 'مرحباً', 'Hello');
    await new Promise((resolve) => setTimeout(resolve, 50));

    expect(transcripts()).toHaveLength(1); // still one bubble
    expect(completions()).toHaveLength(1); // still one final translation
    expect(deltas()).toHaveLength(0); // no stray streamed deltas either
  });

  it('closes the translate session on stop', async () => {
    const stream = translate.sessions[0]!;
    stream.emitDelta('utterance_1', 'مرحباً');
    stream.emitFinal('utterance_1', 'مرحباً', 'Hello');
    await session.handleSessionStop();

    expect(stream.closed).toBe(true);
    expect(sent.find((m) => m.type === 'session_ended')).toMatchObject({ translationCount: 1 });
  });
});
