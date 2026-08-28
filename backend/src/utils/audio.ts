/**
 * Audio helpers. The mobile client streams raw PCM 16-bit little-endian mono.
 * Speech providers generally want a WAV container, so we wrap segments here.
 */

export interface PcmFormat {
  sampleRate: number;
  channels: number;
}

/** Wrap raw PCM16LE samples in a WAV (RIFF) header. */
export function pcm16ToWav(pcm: Buffer, format: PcmFormat): Buffer {
  const { sampleRate, channels } = format;
  const byteRate = sampleRate * channels * 2;
  const blockAlign = channels * 2;
  const header = Buffer.alloc(44);

  header.write('RIFF', 0, 'ascii');
  header.writeUInt32LE(36 + pcm.length, 4);
  header.write('WAVE', 8, 'ascii');
  header.write('fmt ', 12, 'ascii');
  header.writeUInt32LE(16, 16); // fmt chunk size
  header.writeUInt16LE(1, 20); // PCM
  header.writeUInt16LE(channels, 22);
  header.writeUInt32LE(sampleRate, 24);
  header.writeUInt32LE(byteRate, 28);
  header.writeUInt16LE(blockAlign, 32);
  header.writeUInt16LE(16, 34); // bits per sample
  header.write('data', 36, 'ascii');
  header.writeUInt32LE(pcm.length, 40);

  return Buffer.concat([header, pcm]);
}

export function pcmDurationMs(pcmBytes: number, format: PcmFormat): number {
  const bytesPerSecond = format.sampleRate * format.channels * 2;
  return Math.round((pcmBytes / bytesPerSecond) * 1000);
}

/** Root-mean-square level of a PCM16LE buffer, 0..1. Used for sanity checks. */
export function pcm16Rms(pcm: Buffer): number {
  const samples = Math.floor(pcm.length / 2);
  if (samples === 0) return 0;
  let sumSquares = 0;
  for (let i = 0; i < samples; i++) {
    const s = pcm.readInt16LE(i * 2) / 32768;
    sumSquares += s * s;
  }
  return Math.sqrt(sumSquares / samples);
}
