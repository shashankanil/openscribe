export type FlowbarDock = "none" | "left" | "right";

export interface ScreenRect {
  x: number;
  y: number;
  width: number;
  height: number;
}

export interface Point {
  x: number;
  y: number;
}

export interface FlowbarPlacementSettings {
  screen?: string;
  x: number; // normalized 0..1
  y: number; // normalized 0..1
  edge?: "left" | "right" | null;
}

export const FlowbarLayout = {
  pillHeight: 32,
  inset: 10,
  edgeMargin: 14,
  edgeGap: 22,
  dockGap: 3,
  dockReach: 70,
  maxWidth: 150
} as const;

export function detectDock(point: Point, visible: ScreenRect): FlowbarDock {
  const minX = visible.x;
  const maxX = visible.x + visible.width;
  if (point.x - minX < FlowbarLayout.dockReach) {
    return "left";
  }
  if (maxX - point.x < FlowbarLayout.dockReach) {
    return "right";
  }
  return "none";
}

export function snapPoint(
  point: Point,
  visible: ScreenRect,
  dock: FlowbarDock
): Point {
  const minX = visible.x;
  const maxX = visible.x + visible.width;
  const minY = visible.y;
  const maxY = visible.y + visible.height;

  const halfLength = FlowbarLayout.maxWidth / 2 + FlowbarLayout.edgeMargin; // 75 + 14 = 89
  const halfThickness = FlowbarLayout.pillHeight / 2 + FlowbarLayout.edgeMargin; // 16 + 14 = 30

  if (dock === "left" || dock === "right") {
    const x =
      dock === "left"
        ? minX + FlowbarLayout.dockGap + FlowbarLayout.pillHeight / 2
        : maxX - FlowbarLayout.dockGap - FlowbarLayout.pillHeight / 2;
    const y = Math.min(Math.max(point.y, minY + halfLength), maxY - halfLength);
    return { x: Math.round(x), y: Math.round(y) };
  }

  // dock === "none"
  let x = Math.min(Math.max(point.x, minX + halfLength), maxX - halfLength);
  let y = Math.min(Math.max(point.y, minY + halfThickness), maxY - halfThickness);

  // Snap to center horizontal line
  const midX = minX + visible.width / 2;
  if (Math.abs(x - midX) < 28) {
    x = midX;
  }

  // Snap to top or bottom edge
  const half = FlowbarLayout.pillHeight / 2;
  if (y - half - minY < 40) {
    y = minY + FlowbarLayout.edgeGap + half;
  } else if (maxY - (y + half) < 40) {
    y = maxY - FlowbarLayout.edgeGap - half;
  }

  return { x: Math.round(x), y: Math.round(y) };
}

export function companionOrigin(
  beside: Point,
  dock: FlowbarDock,
  size: { width: number; height: number },
  gap: number,
  visible: ScreenRect
): Point {
  const half = FlowbarLayout.pillHeight / 2;
  let ox: number;
  let oy: number;

  const minX = visible.x;
  const maxX = visible.x + visible.width;
  const minY = visible.y;
  const maxY = visible.y + visible.height;

  switch (dock) {
    case "left":
      ox = beside.x + half + gap;
      oy = beside.y - size.height / 2;
      break;
    case "right":
      ox = beside.x - half - gap - size.width;
      oy = beside.y - size.height / 2;
      break;
    case "none": {
      const aboveFits = beside.y - half - gap - size.height > minY;
      ox = beside.x - size.width / 2;
      oy = aboveFits ? beside.y - half - gap - size.height : beside.y + half + gap;
      break;
    }
  }

  // Keep bubble inside visible bounds
  ox = Math.min(Math.max(ox, minX + 6), maxX - size.width - 6);
  oy = Math.min(Math.max(oy, minY + 6), maxY - size.height - 6);

  return { x: Math.round(ox), y: Math.round(oy) };
}

export function restoreAnchor(
  placement: FlowbarPlacementSettings | null | undefined,
  overlayPosition: string | undefined,
  visible: ScreenRect
): { anchor: Point; dock: FlowbarDock } {
  if (placement && Number.isFinite(placement.x) && Number.isFinite(placement.y)) {
    const dock = (placement.edge === "left" || placement.edge === "right") ? placement.edge : "none";
    const raw = {
      x: visible.x + placement.x * visible.width,
      y: visible.y + placement.y * visible.height
    };
    return {
      anchor: snapPoint(raw, visible, dock),
      dock
    };
  }

  const halfLength = FlowbarLayout.maxWidth / 2 + FlowbarLayout.edgeMargin + 10;
  const bottom = visible.y + visible.height - FlowbarLayout.edgeGap - FlowbarLayout.pillHeight / 2;
  const top = visible.y + FlowbarLayout.edgeGap + FlowbarLayout.pillHeight / 2;
  const midX = visible.x + visible.width / 2;

  let anchor: Point;
  switch (overlayPosition) {
    case "bottom-left":
      anchor = { x: visible.x + halfLength, y: bottom };
      break;
    case "bottom-right":
      anchor = { x: visible.x + visible.width - halfLength, y: bottom };
      break;
    case "top-center":
      anchor = { x: midX, y: top };
      break;
    case "top-right":
      anchor = { x: visible.x + visible.width - halfLength, y: top };
      break;
    default:
      anchor = { x: midX, y: bottom };
      break;
  }

  return {
    anchor: snapPoint(anchor, visible, "none"),
    dock: "none"
  };
}

export interface Size { width: number; height: number }

/** A docked sliver hugs the same edge as the full-height pill. */
export function pillAnchor(anchor: Point, dock: FlowbarDock, thickness: number): Point {
  const offset = (FlowbarLayout.pillHeight - thickness) / 2;
  return { x: anchor.x + (dock === "left" ? -offset : dock === "right" ? offset : 0), y: anchor.y };
}

/** Fit one transparent native window around the pill and its companion, inside the work area. */
export function flowbarFrame(anchor: Point, dock: FlowbarDock, length: number, companion: Size | null, visible: ScreenRect) {
  const width = dock === "none" ? length + 20 : 52;
  const height = dock === "none" ? 52 : length + 20;
  const bubble = companion ? companionOrigin(anchor, dock, companion, 4, visible) : null;
  const left = Math.min(anchor.x - width / 2, bubble?.x ?? Infinity);
  const top = Math.min(anchor.y - height / 2, bubble?.y ?? Infinity);
  const right = Math.max(anchor.x + width / 2, bubble ? bubble.x + companion!.width : -Infinity);
  const bottom = Math.max(anchor.y + height / 2, bubble ? bubble.y + companion!.height : -Infinity);
  const w = Math.min(visible.width, Math.ceil(right - left));
  const h = Math.min(visible.height, Math.ceil(bottom - top));
  const x = Math.round(Math.max(visible.x, Math.min(left, visible.x + visible.width - w)));
  const y = Math.round(Math.max(visible.y, Math.min(top, visible.y + visible.height - h)));
  return {
    x, y, width: w, height: h,
    pillCenter: { x: anchor.x - x, y: anchor.y - y },
    companion: bubble ? { x: bubble.x - x, y: bubble.y - y } : null
  };
}

export interface DisplayGeometry { position: Point; size: Size; scaleFactor: number; workArea: { position: Point; size: Size } }

/** Use physical desktop coordinates until a monitor is selected; DPI scales differ between displays. */
export function displayAt<T extends DisplayGeometry>(displays: T[], point: Point): T | undefined {
  return displays.find(m => point.x >= m.position.x && point.x < m.position.x + m.size.width &&
    point.y >= m.position.y && point.y < m.position.y + m.size.height);
}

export function visibleArea(monitor: DisplayGeometry): ScreenRect {
  return { x: monitor.workArea.position.x / monitor.scaleFactor, y: monitor.workArea.position.y / monitor.scaleFactor,
    width: monitor.workArea.size.width / monitor.scaleFactor, height: monitor.workArea.size.height / monitor.scaleFactor };
}

/** Preserve the grab offset in logical pixels when crossing between different display DPIs. */
export function draggedAnchor(initial: Point, firstCursor: Point, initialScale: number, cursor: Point, scale: number): Point {
  return { x: cursor.x / scale - (firstCursor.x / initialScale - initial.x),
    y: cursor.y / scale - (firstCursor.y / initialScale - initial.y) };
}
