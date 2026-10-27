/** Short, softly enveloped cues, independent of the system alert sound. Mirrors CaptureSounds.swift. */
export type CaptureCue = "start" | "stop";

const RATE = 44_100;
const COUNT = 3_528; // 80 ms
const VOLUME = 0.18;

/** The macOS cue: a sine sweep under a sin² envelope, at the same level as its 16-bit samples. */
export function cueSamples(cue: CaptureCue): Float32Array<ArrayBuffer> {
  const frequency = 740;
  const ending = cue === "start" ? 940 : 540;
  const samples = new Float32Array(COUNT);
  let phase = 0;
  for (let index = 0; index < COUNT; index++) {
    const progress = index / (COUNT - 1);
    phase += 2 * Math.PI * (frequency + (ending - frequency) * progress) / RATE;
    samples[index] = Math.sin(phase) * Math.sin(Math.PI * progress) ** 2 * (12_000 / 32_767);
  }
  return samples;
}

export class CaptureSounds {
  private context?: AudioContext;
  private buffers = new Map<CaptureCue, AudioBuffer>();
  private playing?: AudioBufferSourceNode;

  play(cue: CaptureCue) {
    try {
      const context = this.context ??= new AudioContext();
      void context.resume().catch(() => undefined);
      let buffer = this.buffers.get(cue);
      if (!buffer) {
        buffer = context.createBuffer(1, COUNT, RATE);
        buffer.copyToChannel(cueSamples(cue), 0);
        this.buffers.set(cue, buffer);
      }
      // As on macOS, a new cue cuts off the previous one.
      try { this.playing?.stop(); } catch { /* already finished */ }
      const source = context.createBufferSource();
      const gain = context.createGain();
      gain.gain.value = VOLUME;
      source.buffer = buffer;
      source.connect(gain).connect(context.destination);
      source.start();
      this.playing = source;
    } catch {
      // A missing audio output must never interrupt a recording.
    }
  }
}
