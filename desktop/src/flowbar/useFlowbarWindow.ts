import { useEffect, useRef, useState } from "react";
import { PhysicalPosition, PhysicalSize } from "@tauri-apps/api/dpi";
import { availableMonitors, cursorPosition, getCurrentWindow, type Monitor, type Window } from "@tauri-apps/api/window";
import type { ParitySettings } from "../api/parityTypes";
import { reportUiError, sendIntent } from "../workspaceEvents";
import { companionOrigin, detectDock, displayAt, draggedAnchor, flowbarFrame, restoreAnchor, snapPoint, visibleArea, type Point, type Size, type FlowbarDock } from "./placement";

/** Keep a stable anchor while modes animate and companions expand the native window. */
export function useFlowbarWindow(settings: ParitySettings | null, length: number, companion: Size | null) {
  const [dock, setDock] = useState<FlowbarDock>("none");
  const [frame, setFrame] = useState(() => flowbarFrame({ x: 100, y: 100 }, "none", length, null, { x: 0, y: 0, width: 1920, height: 1080 }));
  const anchor = useRef<Point | null>(null);
  const monitorRef = useRef<Monitor | null>(null);
  const dockRef = useRef<FlowbarDock>("none");
  const settingsRef = useRef(settings); settingsRef.current = settings;
  const layoutRef = useRef({ length, companion }); layoutRef.current = { length, companion };
  const cleanupDrag = useRef<() => void>(() => undefined);
  const dragging = useRef(false);
  const suppressClick = useRef(false);
  const placementKey = JSON.stringify([settings?.flowbarPlacement, settings?.overlayPosition]);
  // Serialize mutations so an older resize cannot overtake a newer drag/layout.
  const mutations = useRef<Promise<unknown>>(Promise.resolve());
  const position = (monitor: Monitor, point: Point, nextDock = dockRef.current, nativeLength = layoutRef.current.length) => {
    const next = flowbarFrame(point, nextDock, nativeLength, layoutRef.current.companion, visibleArea(monitor));
    mutations.current = mutations.current.catch(() => undefined).then(async () => {
      const win = getCurrentWindow(), scale = monitor.scaleFactor;
      // Move before sizing: Windows may apply a DPI resize while crossing displays.
      await win.setPosition(new PhysicalPosition(Math.round(next.x * scale), Math.round(next.y * scale)));
      await win.setSize(new PhysicalSize(Math.round(next.width * scale), Math.round(next.height * scale)));
      setFrame(next);
    });
    return mutations.current;
  };
  const changeDock = (next: FlowbarDock) => { dockRef.current = next; setDock(next); };

  useEffect(() => {
    if (!settings) return;
    let disposed = false, topology = "";
    const restore = async () => {
      const monitors = await availableMonitors();
      const signature = JSON.stringify(monitors);
      if (disposed || dragging.current || signature === topology) return;
      const current = settingsRef.current;
      if (!current) return;
      const cursor = await cursorPosition();
      if (disposed) return;
      const monitor = monitors.find(m => m.name === current.flowbarPlacement?.screen) ?? displayAt(monitors, cursor) ?? monitors[0];
      if (!monitor) return;
      topology = signature;
      monitorRef.current = monitor;
      const restored = restoreAnchor(current.flowbarPlacement, current.overlayPosition, visibleArea(monitor));
      anchor.current = restored.anchor; changeDock(restored.dock);
      await position(monitor, restored.anchor, restored.dock);
    };
    void restore().catch(reportUiError);
    // Re-clamp on taskbar, DPI or display changes, including removal of the saved screen.
    const timer = setInterval(() => { void restore().catch(reportUiError); }, 2000);
    return () => { disposed = true; clearInterval(timer); };
  }, [placementKey, !!settings]);

  const nativeLength = useRef(length);
  useEffect(() => {
    const apply = () => {
      nativeLength.current = length;
      if (!dragging.current && anchor.current && monitorRef.current) void position(monitorRef.current, anchor.current).catch(reportUiError);
    };
    // SwiftUI lets the pill finish shrinking before shrinking its NSPanel (320 ms).
    if (length < nativeLength.current && !companion) {
      const timer = setTimeout(apply, 320);
      return () => clearTimeout(timer);
    }
    apply();
  }, [length, companion?.width, companion?.height, dock]);
  useEffect(() => () => cleanupDrag.current(), []);

  const onPointerDown = (event: React.PointerEvent<HTMLElement>) => {
    if (event.button !== 0 || dragging.current) return;
    cleanupDrag.current(); suppressClick.current = false;
    const element = event.currentTarget, pointerId = event.pointerId;
    const start = { x: event.screenX, y: event.screenY };
    const initialAnchor = anchor.current, initialMonitor = monitorRef.current;
    if (!initialAnchor || !initialMonitor) return;
    let ended = false, moved = false, cancelled = false;
    let pending = Promise.resolve();
    const origin = cursorPosition().catch(error => {
      reportUiError(error);
      return new PhysicalPosition(initialAnchor.x * initialMonitor.scaleFactor, initialAnchor.y * initialMonitor.scaleFactor);
    });
    const move = (e: PointerEvent) => {
      if (e.pointerId !== pointerId || ended) return;
      if (!moved && Math.hypot(e.screenX - start.x, e.screenY - start.y) < 3) return;
      if (!moved) {
        moved = true; dragging.current = true; suppressClick.current = true;
        element.setPointerCapture(pointerId);
      }
      const sample = cursorPosition().catch(error => { reportUiError(error); return null; });
      pending = pending.then(async () => {
        if (cancelled) return;
        const [cursor, first, monitors] = await Promise.all([sample, origin, availableMonitors()]);
        if (cancelled || !cursor) return;
        const monitor = displayAt(monitors, cursor) ?? monitorRef.current ?? initialMonitor;
        const scale = monitor.scaleFactor;
        const point = draggedAnchor(initialAnchor, first, initialMonitor.scaleFactor, cursor, scale);
        const nextDock = detectDock({ x: cursor.x / scale, y: cursor.y / scale }, visibleArea(monitor));
        anchor.current = point; monitorRef.current = monitor; changeDock(nextDock);
        await position(monitor, point, nextDock);
      }).catch(reportUiError);
    };
    const cleanup = () => {
      window.removeEventListener("pointermove", move); window.removeEventListener("pointerup", finish); window.removeEventListener("pointercancel", finish);
      if (element.hasPointerCapture(pointerId)) element.releasePointerCapture(pointerId);
    };
    const finish = (e: PointerEvent) => {
      if (e.pointerId !== pointerId) return;
      ended = true; cleanup();
      void pending.then(async () => {
        if (cancelled || !moved || !anchor.current || !monitorRef.current) return;
        const monitor = monitorRef.current, visible = visibleArea(monitor), nextDock = dockRef.current;
        const snapped = snapPoint(anchor.current, visible, nextDock);
        anchor.current = snapped;
        await position(monitor, snapped);
        await sendIntent({ action: "placement", placement: { screen: monitor.name ?? undefined,
          x: (snapped.x - visible.x) / visible.width, y: (snapped.y - visible.y) / visible.height, edge: nextDock === "none" ? null : nextDock } });
      }).catch(reportUiError).finally(() => { dragging.current = false; });
    };
    window.addEventListener("pointermove", move); window.addEventListener("pointerup", finish); window.addEventListener("pointercancel", finish);
    cleanupDrag.current = () => { cancelled = true; ended = true; dragging.current = false; cleanup(); };
  };
  const onClickCapture = (event: React.MouseEvent) => {
    if (suppressClick.current) { event.preventDefault(); event.stopPropagation(); suppressClick.current = false; }
  };
  const placeCompanionWindow = async (win: Window) => {
    const monitor = monitorRef.current, point = anchor.current;
    if (!monitor || !point) return;
    const size = (await win.outerSize()).toLogical(await win.scaleFactor());
    const visible = visibleArea(monitor), scale = monitor.scaleFactor;
    const fitted = { width: Math.min(size.width, visible.width - 12), height: Math.min(size.height, visible.height - 12) };
    const origin = companionOrigin(point, dockRef.current, fitted, 4, visible);
    await win.setPosition(new PhysicalPosition(Math.round(origin.x * scale), Math.round(origin.y * scale)));
    await win.setSize(new PhysicalSize(Math.round(fitted.width * scale), Math.round(fitted.height * scale)));
  };
  return { dock, ...frame, onPointerDown, onClickCapture, placeCompanionWindow };
}
