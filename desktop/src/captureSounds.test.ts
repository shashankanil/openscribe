import { describe, expect, it } from "vitest";
import { cueSamples } from "./captureSounds";

describe("capture cues", () => {
  it("match the macOS 80 ms enveloped sweep", () => {
    for (const cue of ["start", "stop"] as const) {
      const samples = cueSamples(cue);
      expect(samples.length).toBe(3_528);
      expect(samples[0]).toBe(0);
      expect(Math.abs(samples[samples.length - 1])).toBeLessThan(1e-6);
      expect(Math.max(...samples.map(Math.abs))).toBeLessThanOrEqual(12_000 / 32_767);
    }
    expect(cueSamples("start")).not.toEqual(cueSamples("stop"));
  });
});
