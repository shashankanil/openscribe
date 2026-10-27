import React, { useEffect, useRef, useState } from "react";

export type FlowbarMotion = "still" | "live" | "flowing";

interface FlowbarSquiggleProps {
  level?: number; // 0..1, already mapped by the native meter
  motion?: FlowbarMotion;
  color?: string;
  width?: number;
  height?: number;
  vertical?: boolean;
}

const lineWidth = 2;

/** The logo wave (WhisperlightWave in FlowTheme.swift). */
export function logoWavePath(x: number, y: number, width: number, height: number): string {
  const mid = y + height / 2, quarter = width * 0.25, top = y, bottom = y + height;
  let path = `M ${x} ${mid}`;
  for (let i = 0; i < 4; i++) {
    const edge = i % 2 === 0 ? top : bottom;
    path += ` C ${x + quarter * (i + 0.34)} ${edge} ${x + quarter * (i + 0.66)} ${edge} ${x + quarter * (i + 1)} ${mid}`;
  }
  return path;
}

/** Per-frame smoothing for the live line, ported from VoiceFollower in OverlayPanel.swift. */
export class VoiceFollower {
  static ripple = 0.28;
  phase = 0;
  private current = 0;
  private last: number | null = null;
  private history: { time: number; level: number }[] = [];
  step(target: number, time: number): number {
    const delta = Math.min(0.1, Math.max(0, time - (this.last ?? time)));
    this.last = time;
    // Perceptual boost so normal speech fills the pill, not just shouting.
    const boosted = Math.min(1, Math.pow(Math.max(0, target), 0.55) * 1.5);
    const rate = boosted > this.current ? 30 : 7;
    this.current += (boosted - this.current) * Math.min(1, rate * delta);
    this.phase += delta * (1.2 + 7 * this.current);
    this.history.push({ time, level: this.current });
    while (this.history.length > 1 && time - this.history[0].time > VoiceFollower.ripple + 0.1) this.history.shift();
    return this.current;
  }
  /** The level `delay` seconds ago, interpolated between frames. */
  level(delay: number): number {
    const newest = this.history.at(-1);
    if (!newest) return this.current;
    const when = newest.time - delay;
    let index = -1;
    for (let i = this.history.length - 1; i >= 0; i--) if (this.history[i].time <= when) { index = i; break; }
    if (index < 0) return this.history[0].level;
    if (index + 1 >= this.history.length) return this.history[index].level;
    const a = this.history[index], b = this.history[index + 1];
    const t = b.time > a.time ? (when - a.time) / (b.time - a.time) : 0;
    return a.level + (b.level - a.level) * t;
  }
}

/** The voice line: height follows the voice, and louder moments ripple outward from the center. */
export function livePath(width: number, height: number, phase: number, amplitude: (delay: number) => number): string {
  const half = Math.max(1, height / 2 - 1), steps = Math.max(16, Math.floor(width / 1.5));
  let path = "";
  for (let step = 0; step <= steps; step++) {
    const x = step / steps;
    const envelope = Math.pow(Math.sin(Math.PI * x), 0.9);
    const level = amplitude(Math.abs(x - 0.5) * 2 * VoiceFollower.ripple);
    const amp = half * (0.1 + 0.9 * Math.min(1, level));
    const y = height / 2 - amp * envelope * Math.sin(2 * Math.PI * 3.5 * x - phase);
    path += `${step === 0 ? "M" : " L"} ${(x * width).toFixed(2)} ${y.toFixed(2)}`;
  }
  return path;
}

/** Visible [from, to] pieces of the comet that sweeps along the wave while work is in progress. */
export function cometSlices(time: number): { from: number; to: number; opacity: number }[] {
  const t = (time / 1.5) % 1;
  const eased = t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2;
  const tail = 0.42, head = eased * (1 + tail), slices = 5;
  const out: { from: number; to: number; opacity: number }[] = [];
  for (let slice = slices - 1; slice >= 0; slice--) {
    const to = head - tail * slice / slices, from = to - tail / slices - 0.01;
    if (to <= 0 || from >= 1) continue;
    out.push({ from: Math.max(0, from), to: Math.min(1, to), opacity: Math.pow(1 - slice / slices, 1.6) });
  }
  return out;
}

export const FlowbarSquiggle: React.FC<FlowbarSquiggleProps> = ({
  level = 0,
  motion = "still",
  color = "var(--os-flowbar-ink)",
  width = 40,
  height = 16,
  vertical = false
}) => {
  const target = useRef(level); target.current = level;
  const follower = useRef(new VoiceFollower());
  const [time, setTime] = useState(0);
  useEffect(() => {
    if (motion === "still") return;
    let frame = 0;
    const tick = (now: number) => {
      const seconds = now / 1000;
      if (motion === "live") follower.current.step(target.current, seconds);
      setTime(seconds);
      frame = requestAnimationFrame(tick);
    };
    frame = requestAnimationFrame(tick);
    return () => cancelAnimationFrame(frame);
  }, [motion]);

  const stroke = { stroke: color, strokeWidth: lineWidth, strokeLinecap: "round" as const, strokeLinejoin: "round" as const, fill: "none" };
  const inset = lineWidth / 2;
  const wave = logoWavePath(inset, inset + 1, width - lineWidth, height - lineWidth - 2);
  return (
    <svg width={vertical ? height : width} height={vertical ? width : height} viewBox={`0 0 ${vertical ? height : width} ${vertical ? width : height}`} style={{ display: "block", overflow: "visible" }} aria-hidden="true">
      <g transform={vertical ? `translate(${height}, 0) rotate(90)` : undefined}>
      {motion === "still" && <path d={wave} {...stroke} />}
      {motion === "live" && <path d={livePath(width, height, follower.current.phase, delay => follower.current.level(delay))} {...stroke} />}
      {motion === "flowing" && <>
        <path d={wave} {...stroke} strokeOpacity={0.2} />
        {cometSlices(time).map(({ from, to, opacity }, index) => (
          <path key={index} d={wave} {...stroke} strokeOpacity={opacity} pathLength={1}
            strokeDasharray={`${to - from} 2`} strokeDashoffset={-from} />
        ))}
      </>}
      </g>
    </svg>
  );
};
