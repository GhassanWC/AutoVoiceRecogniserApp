import { beforeEach, describe, expect, it } from 'vitest';
import { LiveSession } from '../src/modules/realtime/live_session';
import { ServerMessage } from '../src/modules/realtime/protocol';
import { HeuristicDiarizationProvider } from '../src/providers/diarization/heuristic';
import { MockSpeechProvider } from '../src/providers/speech/mock';
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
