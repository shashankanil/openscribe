import { describe, expect, it } from "vitest";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { cometSlices, FlowbarSquiggle, livePath, logoWavePath, VoiceFollower } from "./FlowbarSquiggle";

describe("Flowbar squiggle", () => {
  it("rotates the wave within a swapped SVG viewport when docked, without clipping its length", () => {
    const markup = renderToStaticMarkup(createElement(FlowbarSquiggle, { width: 64, height: 20, vertical: true }));
    expect(markup).toContain('width="20" height="64" viewBox="0 0 20 64"');
    expect(markup).toContain('transform="translate(20, 0) rotate(90)"');
    expect(markup).toContain('aria-hidden="true"');
  });
  it("draws the logo wave across the full width", () => {
    const path = logoWavePath(0, 0, 40, 16);
    expect(path.startsWith("M 0 8")).toBe(true);
    expect(path.endsWith("40 8")).toBe(true);
    expect(path.match(/C /g)).toHaveLength(4);
  });

  it("follows the voice: rises quickly while speaking, settles when quiet", () => {
    const voice = new VoiceFollower();
    let level = 0;
    for (let frame = 0; frame <= 12; frame++) level = voice.step(0.5, frame / 60);
    expect(level).toBeGreaterThan(0.7);
    for (let frame = 13; frame <= 120; frame++) level = voice.step(0, frame / 60);
    expect(level).toBeLessThan(0.05);
  });

  it("makes a taller line for a louder voice", () => {
    const span = (path: string) => { const ys = [...path.matchAll(/[ML] [\d.]+ ([\d.-]+)/g)].map(m => Number(m[1])); return Math.max(...ys) - Math.min(...ys); };
    expect(span(livePath(42, 18, 1, () => 1))).toBeGreaterThan(span(livePath(42, 18, 1, () => 0)) * 4);
  });

  it("sweeps the comet along the wave over each 1.5 s cycle", () => {
    expect(cometSlices(0)).toEqual([]);
    const middle = cometSlices(0.75);
    expect(middle.length).toBeGreaterThan(0);
    for (const slice of middle) { expect(slice.from).toBeGreaterThanOrEqual(0); expect(slice.to).toBeLessThanOrEqual(1); }
    expect(Math.max(...middle.map(slice => slice.opacity))).toBe(1);
  });
});
