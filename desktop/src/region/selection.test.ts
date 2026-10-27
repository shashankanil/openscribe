import { describe, expect, it } from "vitest";
import { isDrag, selectionRect } from "./selection";

describe("area selection", () => {
  it("normalizes a drag in any direction", () => {
    expect(selectionRect({ x: 40, y: 80 }, { x: 10, y: 20 })).toEqual({
      x: 10,
      y: 20,
      width: 30,
      height: 60
    });
  });

  it("treats a click as too small to capture", () => {
    const click = selectionRect({ x: 5, y: 5 }, { x: 6, y: 5 });
    expect(isDrag(click)).toBe(false);
    expect(isDrag(selectionRect({ x: 0, y: 0 }, { x: 12, y: 8 }))).toBe(true);
  });
});
