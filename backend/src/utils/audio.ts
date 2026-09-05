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

/**
 * Linear-interpolation resampler for PCM16LE mono. Quality is fine for speech
 * (16 kHz mic audio → the 24 kHz OpenAI realtime input format); not meant for
 * music. Returns the input unchanged when the rates already match.
 */
export function resamplePcm16(pcm: Buffer, fromRate: number, toRate: number): Buffer {
  if (fromRate === toRate || pcm.length < 4) return pcm;
  const inSamples = Math.floor(pcm.length / 2);
  const outSamples = Math.max(1, Math.round((inSamples * toRate) / fromRate));
  const out = Buffer.alloc(outSamples * 2);
  const step = (inSamples - 1) / Math.max(1, outSamples - 1);
  for (let i = 0; i < outSamples; i++) {
    const position = i * step;
    const index = Math.floor(position);
    const fraction = position - index;
    const a = pcm.readInt16LE(index * 2);
    const b = index + 1 < inSamples ? pcm.readInt16LE((index + 1) * 2) : a;
    out.writeInt16LE(Math.round(a + (b - a) * fraction), i * 2);
  }
  return out;
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
