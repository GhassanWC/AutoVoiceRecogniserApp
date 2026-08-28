import { describe, expect, it } from 'vitest';
import { pcm16Rms, pcm16ToWav, pcmDurationMs } from '../src/utils/audio';

describe('audio utils', () => {
  it('builds a valid WAV header', () => {
    const pcm = Buffer.alloc(32000); // 1 second @ 16kHz mono
    const wav = pcm16ToWav(pcm, { sampleRate: 16000, channels: 1 });
    expect(wav.length).toBe(44 + 32000);
    expect(wav.subarray(0, 4).toString('ascii')).toBe('RIFF');
    expect(wav.subarray(8, 12).toString('ascii')).toBe('WAVE');
    expect(wav.readUInt32LE(24)).toBe(16000); // sample rate
    expect(wav.readUInt16LE(22)).toBe(1); // channels
    expect(wav.readUInt32LE(40)).toBe(32000); // data size
  });

  it('computes duration from byte length', () => {
    expect(pcmDurationMs(32000, { sampleRate: 16000, channels: 1 })).toBe(1000);
    expect(pcmDurationMs(16000, { sampleRate: 16000, channels: 1 })).toBe(500);
  });

  it('computes RMS of silence as zero', () => {
    expect(pcm16Rms(Buffer.alloc(1000))).toBe(0);
  });
});
