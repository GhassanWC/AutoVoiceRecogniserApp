import { describe, expect, it } from 'vitest';
import {
  clientMessageSchema,
  encodeAudioFrame,
  parseAudioFrame,
} from '../src/modules/realtime/protocol';

const SEGMENT_ID = '123e4567-e89b-42d3-a456-426614174000';

describe('binary audio frames', () => {
  it('round-trips segment id, sequence and payload', () => {
    const pcm = Buffer.from([1, 2, 3, 4, 5, 6]);
    const frame = encodeAudioFrame(SEGMENT_ID, 7, pcm);
    const parsed = parseAudioFrame(frame);
    expect(parsed).not.toBeNull();
    expect(parsed!.segmentId).toBe(SEGMENT_ID);
    expect(parsed!.sequence).toBe(7);
    expect(Buffer.compare(parsed!.pcm, pcm)).toBe(0);
  });

  it('rejects frames with an unknown protocol version', () => {
    const frame = encodeAudioFrame(SEGMENT_ID, 0, Buffer.from([1, 2]));
    frame.writeUInt8(99, 0);
    expect(parseAudioFrame(frame)).toBeNull();
  });

  it('rejects frames that are too short to contain audio', () => {
    expect(parseAudioFrame(Buffer.alloc(10))).toBeNull();
  });
});

describe('client control messages', () => {
  it('accepts a valid session_start', () => {
    const result = clientMessageSchema.safeParse({
      type: 'session_start',
      targetLanguage: 'ar',
      saveHistory: true,
    });
    expect(result.success).toBe(true);
  });

  it('defaults saveHistory to false (privacy default)', () => {
    const result = clientMessageSchema.parse({ type: 'session_start', targetLanguage: 'ar' });
    expect(result).toMatchObject({ saveHistory: false });
  });

  it('rejects a segment_start with a non-uuid id', () => {
    const result = clientMessageSchema.safeParse({
      type: 'segment_start',
      segmentId: 'not-a-uuid',
      sampleRate: 16000,
      channels: 1,
      encoding: 'pcm16',
    });
    expect(result.success).toBe(false);
  });
});
