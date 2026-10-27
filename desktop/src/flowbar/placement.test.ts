import { describe, expect, it } from "vitest";
import {
  FlowbarLayout,
  companionOrigin,
  detectDock,
  restoreAnchor,
  snapPoint,
  displayAt, draggedAnchor, flowbarFrame, pillAnchor, visibleArea,
  type ScreenRect
} from "./placement";

describe("Flowbar placement and snap math", () => {
  const visible: ScreenRect = {
    x: 0,
    y: 0,
    width: 1920,
    height: 1080
  };

  it("detects left and right docking within reach", () => {
    expect(detectDock({ x: 30, y: 500 }, visible)).toBe("left");
    expect(detectDock({ x: 69, y: 500 }, visible)).toBe("left");
    expect(detectDock({ x: 1900, y: 500 }, visible)).toBe("right");
    expect(detectDock({ x: 1855, y: 500 }, visible)).toBe("right");
    expect(detectDock({ x: 500, y: 500 }, visible)).toBe("none");
  });

  it("snaps point when docked left or right", () => {
    // Docked left: x = visible.x + dockGap(3) + pillHeight/2(16) = 19
    const left = snapPoint({ x: 10, y: 500 }, visible, "left");
    expect(left.x).toBe(19);
    expect(left.y).toBe(500);

    // Docked right: x = visible.x + 1920 - 19 = 1901
    const right = snapPoint({ x: 1910, y: 500 }, visible, "right");
    expect(right.x).toBe(1901);
    expect(right.y).toBe(500);

    // Clamps within vertical halfLength
    const clampedTop = snapPoint({ x: 10, y: 10 }, visible, "left");
    expect(clampedTop.y).toBe(FlowbarLayout.maxWidth / 2 + FlowbarLayout.edgeMargin); // 75 + 14 = 89
  });

  it("snaps to center line and edges when undocked", () => {
    // Near center (1920 / 2 = 960)
    const center = snapPoint({ x: 970, y: 500 }, visible, "none");
    expect(center.x).toBe(960);

    // Near bottom edge: snaps to 1080 - edgeGap(22) - pillHeight/2(16) = 1042
    const bottom = snapPoint({ x: 960, y: 1055 }, visible, "none");
    expect(bottom.y).toBe(1042);

    // Near top edge: snaps to 0 + edgeGap(22) + pillHeight/2(16) = 38
    const top = snapPoint({ x: 960, y: 25 }, visible, "none");
    expect(top.y).toBe(38);
  });

  it("places companion notice bubble beside or above/below pill", () => {
    const bubbleSize = { width: 200, height: 40 };

    // Docked left: bubble is to the right of anchor
    const besideLeft = companionOrigin({ x: 19, y: 500 }, "left", bubbleSize, 4, visible);
    expect(besideLeft.x).toBe(19 + 16 + 4); // 39
    expect(besideLeft.y).toBe(500 - 20); // 480

    // Docked right: bubble is to the left of anchor
    const besideRight = companionOrigin({ x: 1901, y: 500 }, "right", bubbleSize, 4, visible);
    expect(besideRight.x).toBe(1901 - 16 - 4 - 200); // 1681
    expect(besideRight.y).toBe(500 - 20); // 480

    // Undocked near bottom: bubble is placed above anchor
    const above = companionOrigin({ x: 960, y: 1042 }, "none", bubbleSize, 4, visible);
    expect(above.x).toBe(960 - 100);
    expect(above.y).toBe(1042 - 16 - 4 - 40); // 982
  });

  it("restores anchor from persisted placement or default position", () => {
    const fromPlacement = restoreAnchor(
      { screen: "Main", x: 0.5, y: 0.5, edge: null },
      undefined,
      visible
    );
    expect(fromPlacement.anchor.x).toBe(960);
    expect(fromPlacement.dock).toBe("none");

    const fromDefault = restoreAnchor(null, "bottom-center", visible);
    expect(fromDefault.anchor.x).toBe(960);
    expect(fromDefault.anchor.y).toBe(1042);
  });

  it("prefers a notice above the pill, and falls below it near the top", () => {
    expect(companionOrigin({ x: 960, y: 500 }, "none", { width: 200, height: 40 }, 4, visible).y).toBe(440);
    expect(companionOrigin({ x: 960, y: 38 }, "none", { width: 200, height: 40 }, 4, visible).y).toBe(58);
  });

  it("keeps both pill and companions inside taskbar-safe work areas without moving the anchor", () => {
    for (const work of [
      { x: 0, y: 0, width: 1920, height: 1032 }, // bottom taskbar
      { x: -1920, y: 48, width: 1920, height: 1032 }, // negative display + top taskbar
      { x: 64, y: 0, width: 1856, height: 1080 } // left taskbar
    ]) {
      for (const dock of ["none", "left", "right"] as const) {
        const anchor = snapPoint({ x: work.x + work.width / 2, y: work.y + work.height }, work, dock);
        for (const length of [34, 52, 84, 88, 140, 150]) {
          for (const size of [null, { width: 300, height: 110 }, { width: 224, height: 302 }]) {
            const frame = flowbarFrame(anchor, dock, length, size, work);
            expect(frame.x).toBeGreaterThanOrEqual(work.x);
            expect(frame.y).toBeGreaterThanOrEqual(work.y);
            expect(frame.x + frame.width).toBeLessThanOrEqual(work.x + work.width);
            expect(frame.y + frame.height).toBeLessThanOrEqual(work.y + work.height);
            expect({ x: frame.x + frame.pillCenter.x, y: frame.y + frame.pillCenter.y }).toEqual(anchor);
            if (size && frame.companion) {
              expect(frame.companion.x).toBeGreaterThanOrEqual(0);
              expect(frame.companion.y).toBeGreaterThanOrEqual(0);
              expect(frame.companion.x + size.width).toBeLessThanOrEqual(frame.width);
              expect(frame.companion.y + size.height).toBeLessThanOrEqual(frame.height);
            }
          }
        }
      }
    }
  });

  it("hugs the side with an idle sliver and keeps the full pill anchor when expanded", () => {
    expect(pillAnchor({ x: 19, y: 500 }, "left", 6).x - 3).toBe(3);
    expect(pillAnchor({ x: 1901, y: 500 }, "right", 6).x + 3).toBe(1917);
    expect(pillAnchor({ x: 19, y: 500 }, "left", 32)).toEqual({ x: 19, y: 500 });
  });

  it("selects a monitor in physical coordinates before applying its DPI and work area", () => {
    const monitors = [
      { position: { x: -2560, y: 0 }, size: { width: 2560, height: 1440 }, scaleFactor: 2,
        workArea: { position: { x: -2560, y: 0 }, size: { width: 2560, height: 1360 } } },
      { position: { x: 0, y: 0 }, size: { width: 1920, height: 1080 }, scaleFactor: 1,
        workArea: { position: { x: 0, y: 40 }, size: { width: 1920, height: 1040 } } }
    ];
    expect(displayAt(monitors, { x: -1, y: 300 })).toBe(monitors[0]);
    expect(displayAt(monitors, { x: 0, y: 300 })).toBe(monitors[1]);
    expect(displayAt(monitors, { x: 5000, y: 300 })).toBeUndefined();
    const work = visibleArea(monitors[0]);
    expect(work).toEqual({ x: -1280, y: 0, width: 1280, height: 680 });
    const original = { screen: "secondary", x: 0.7, y: 0.4, edge: "right" as const };
    const restored = restoreAnchor(original, undefined, work);
    expect(restored.dock).toBe("right");
    expect(restored.anchor).toEqual({ x: -19, y: 272 });
    const frame = flowbarFrame(restored.anchor, "right", 140, { width: 224, height: 302 }, work);
    expect(frame.x * 2).toBeGreaterThanOrEqual(-2560);
    expect((frame.x + frame.width) * 2).toBeLessThanOrEqual(0);
  });

  it("clamps stale placements and ignores non-finite saved coordinates", () => {
    expect(restoreAnchor({ x: NaN, y: Infinity }, "bottom-center", visible)).toEqual(restoreAnchor(null, "bottom-center", visible));
    expect(restoreAnchor({ x: -5, y: 8 }, undefined, visible).anchor).toEqual({ x: 89, y: 1042 });
  });

  it("preserves the grab offset across DPI boundaries and negative desktop origins", () => {
    // Grab 10 px right and 5 px below the anchor on the 100% display.
    expect(draggedAnchor({ x: 500, y: 500 }, { x: 510, y: 505 }, 1, { x: -1000, y: 800 }, 2)).toEqual({ x: -510, y: 395 });
    // Cross back from 200% without turning physical monitor origins into CSS offsets.
    expect(draggedAnchor({ x: -510, y: 395 }, { x: -1000, y: 800 }, 2, { x: 510, y: 505 }, 1)).toEqual({ x: 500, y: 500 });
  });
});
