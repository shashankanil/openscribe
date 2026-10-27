import React, { useEffect, useLayoutEffect, useRef, useState } from "react";
import { emitTo, listen } from "@tauri-apps/api/event";
import { getCurrentWindow, Window } from "@tauri-apps/api/window";
import { Camera, Check, ChevronLeft, ChevronRight, FileText, Mic, Square, Users } from "lucide-react";
import { deleteMeeting, listMeetings, parityEvents, skipSummary, summarizeShortMeeting } from "../api/parity";
import type { MeetingRecord, ParitySettings, ShortcutAction } from "../api/parityTypes";
import { ListenerScope } from "../listeners";
import { reportUiError, sendIntent, type WorkspaceIntent, type WorkspaceStatus } from "../workspaceEvents";
import type { DictationPhase } from "../dictation";
import { useFlowbarWindow } from "./useFlowbarWindow";
import { FlowbarSquiggle } from "./FlowbarSquiggle";
import { NoticeBubble } from "./NoticeBubble";
import { confirmationFeedback, deriveMode, meetingHint, modeLength, positionPresets } from "./mode";
import { menuEntries } from "./menu";
import { pillAnchor } from "./placement";

export type { FlowbarMode } from "./mode";

const FlowbarIconButton: React.FC<React.ButtonHTMLAttributes<HTMLButtonElement> & { title: string }> = ({ title, children, style, ...props }) => (
  <button type="button" className="flowbar-icon" title={title} aria-label={title} {...props}
    style={{ background: "transparent", border: 0, borderRadius: 999, color: "inherit", padding: 4,
      display: "flex", alignItems: "center", justifyContent: "center", cursor: "pointer", font: "inherit", ...style }}>
    {children}
  </button>
);

const FlowbarMenuItem: React.FC<{
  onClick: () => void; children: React.ReactNode; destructive?: boolean; checked?: boolean; submenu?: boolean;
}> = ({ onClick, children, destructive, checked, submenu }) => (
  <button type="button" className="flowbar-menu-item" role={checked === undefined ? "menuitem" : "menuitemcheckbox"}
    aria-checked={checked} aria-haspopup={submenu ? "menu" : undefined} onClick={onClick}
    style={{ background: "transparent", border: 0, borderRadius: 6,
      color: destructive ? "var(--os-flowbar-recording)" : "var(--os-flowbar-ink)", padding: "6px 8px",
      display: "flex", alignItems: "center", gap: 6, cursor: "pointer", font: "inherit", fontSize: 12,
      fontWeight: 500, width: "100%", textAlign: "left" }}>
    {checked !== undefined && <span style={{ width: 12 }}>{checked && <Check size={12} aria-hidden="true" />}</span>}
    {children}{submenu && <ChevronRight size={12} aria-hidden="true" style={{ marginLeft: "auto" }} />}
  </button>
);

/** Area is the primary action; hold, right click or ArrowDown opens all screenshot kinds. */
function ScreenshotButton({ title, onCapture, onMenu }: { title: string; onCapture: () => void; onMenu: () => void }) {
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const held = useRef(false);
  const start = useRef({ x: 0, y: 0 });
  const clear = () => { if (timer.current) clearTimeout(timer.current); timer.current = null; };
  useEffect(() => clear, []);
  return <FlowbarIconButton title={title} aria-haspopup="menu"
    onPointerDown={event => {
      if (event.button !== 0) return;
      held.current = false; start.current = { x: event.screenX, y: event.screenY };
      clear(); timer.current = setTimeout(() => { held.current = true; onMenu(); }, 500);
    }}
    onPointerMove={event => { if (Math.hypot(event.screenX - start.current.x, event.screenY - start.current.y) >= 3) clear(); }}
    onPointerUp={clear} onPointerCancel={clear} onPointerLeave={clear}
    onContextMenu={event => { event.preventDefault(); event.stopPropagation(); clear(); onMenu(); }}
    onKeyDown={event => { if (event.key === "ArrowDown") { event.preventDefault(); onMenu(); } }}
    onClick={() => { clear(); if (held.current) held.current = false; else onCapture(); }}>
    <Camera size={13} aria-hidden="true" />
  </FlowbarIconButton>;
}

export const FlowbarApp: React.FC = () => {
  const [settings, setSettings] = useState<ParitySettings | null>(null);
  const [phase, setPhase] = useState<DictationPhase>("idle");
  const [hovering, setHovering] = useState(false);
  const [focused, setFocused] = useState(false);
  const [level, setLevel] = useState(0);
  const [activeMeeting, setActiveMeeting] = useState<MeetingRecord | null>(null);
  const [now, setNow] = useState(Date.now);
  const [processingMeeting, setProcessingMeeting] = useState(false);
  const [notice, setNotice] = useState<string | null>(null);
  const [currentTranscript, setCurrentTranscript] = useState("");
  const [captureHint, setCaptureHint] = useState("");
  const [confirmation, setConfirmation] = useState<string | null>(null);
  const [shortMeeting, setShortMeeting] = useState<MeetingRecord | null>(null);
  const [menu, setMenu] = useState<"main" | "position" | "screenshot" | null>(null);
  const hoverTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const confirmationTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const inMeeting = useRef(false); inMeeting.current = !!activeMeeting;
  const pill = useRef<HTMLDivElement>(null);
  const menuElement = useRef<HTMLDivElement>(null);
  const companionElement = useRef<HTMLDivElement>(null);
  const [companionSize, setCompanionSize] = useState({ width: 300, height: 100 });
  const expanded = hovering || focused || !!menu;
  const mode = deriveMode(phase, !!activeMeeting, processingMeeting, confirmation, expanded);
  const length = modeLength(mode, expanded), thickness = mode === "idle" ? 6 : 32;
  const showTranscript = phase !== "idle" && !!captureHint;
  const hasCompanion = !!notice || !!shortMeeting || !!menu || showTranscript;
  const { dock, pillCenter: center, companion, onPointerDown, onClickCapture, placeCompanionWindow, width: windowWidth, height: windowHeight } = useFlowbarWindow(settings, length, hasCompanion ? companionSize : null);
  const pillCenter = pillAnchor(center, dock, thickness);
  const vertical = dock !== "none";
  const pillWidth = vertical ? thickness : length, pillHeight = vertical ? length : thickness;
  const paused = activeMeeting?.status === "paused";
  const hint = (title: string, action: ShortcutAction) => settings?.shortcuts[action] ? `${title}  ${settings.shortcuts[action]!.display}` : title;
  const help = mode === "dictating" ? "Click to finish · Esc to cancel" : mode === "processing" ? `${phase === "cleaning" ? "Polishing" : phase === "starting" ? "Starting" : "Transcribing"}…`
    : mode === "meetingSaving" ? "Saving meeting…" : mode === "confirmation" ? confirmation ?? "Saved"
    : mode === "meeting" ? meetingHint(now / 1000 - 978307200 - (activeMeeting?.createdAt ?? 0), settings?.shortcuts.meeting?.display) : hint("Dictate · drag to move", "dictate");
  const clearHover = () => { if (hoverTimer.current) clearTimeout(hoverTimer.current); };
  const enter = () => { clearHover(); setHovering(true); };
  const leave = () => { clearHover(); hoverTimer.current = setTimeout(() => setHovering(false), 350); };

  useEffect(() => {
    if (!activeMeeting) return;
    setNow(Date.now());
    const timer = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(timer);
  }, [activeMeeting?.id]);
  useEffect(() => {
    const scope = new ListenerScope();
    let active = true, meetingRevision = 0;
    scope.add(listen<WorkspaceStatus>("workspace://status", event => {
      const status = event.payload;
      setSettings(status.settings); setPhase(status.phase); setActiveMeeting(status.activeMeeting);
      setProcessingMeeting(status.processingMeeting); setNotice(status.notice);
      setCurrentTranscript(status.currentTranscript ?? ""); setCaptureHint(status.captureHint ?? "");
      if (status.phase === "starting" || status.activeMeeting) setConfirmation(null);
    }).then(unlisten => { void emitTo("main", "workspace://request-state").catch(reportUiError); return unlisten; }), reportUiError);
    scope.add(listen<{ message: string }>("workspace://confirmation", event => {
      if (confirmationTimer.current) clearTimeout(confirmationTimer.current);
      const feedback = confirmationFeedback(event.payload.message, inMeeting.current);
      setConfirmation(feedback?.message ?? null);
      if (feedback) confirmationTimer.current = setTimeout(() => setConfirmation(null), feedback.duration);
    }), reportUiError);
    scope.add(parityEvents.onMeetingLevel(({ level }) => setLevel(level)), reportUiError);
    scope.add(parityEvents.onDictationLevel(({ level }) => setLevel(level)), reportUiError);
    scope.add(getCurrentWindow().onFocusChanged(({ payload }) => {
      if (!payload) { setMenu(null); setFocused(false); leave(); }
    }), reportUiError);
    const meetingListener = parityEvents.onMeetingChanged(record => {
      meetingRevision++;
      if (record.summaryNeedsConfirmation) setShortMeeting(record);
      else setShortMeeting(previous => previous?.id === record.id ? null : previous);
    });
    scope.add(meetingListener, reportUiError);
    // Subscribe first so bootstrap cannot overwrite a newer recording/confirmation event.
    void meetingListener.then(async () => {
      const revision = meetingRevision;
      const records = await listMeetings();
      if (active && revision === meetingRevision) setShortMeeting(records.find(record => record.summaryNeedsConfirmation) ?? null);
    }).catch(error => { if (active) reportUiError(error); });
    return () => { active = false; scope.dispose(); clearHover(); if (confirmationTimer.current) clearTimeout(confirmationTimer.current); };
  }, []);

  useLayoutEffect(() => {
    if (!hasCompanion || !companionElement.current) return;
    const element = companionElement.current;
    const measure = () => {
      const bounds = element.getBoundingClientRect();
      const next = { width: Math.ceil(bounds.width), height: Math.ceil(bounds.height) };
      setCompanionSize(previous => previous.width === next.width && previous.height === next.height ? previous : next);
    };
    measure();
    const observer = new ResizeObserver(measure);
    observer.observe(element); return () => observer.disconnect();
  }, [hasCompanion, menu, notice, shortMeeting, currentTranscript, captureHint]);
  useEffect(() => {
    if (menu) menuElement.current?.querySelector<HTMLButtonElement>("button")?.focus();
  }, [menu]);
  useEffect(() => {
    const handler = (event: KeyboardEvent) => {
      if (event.key !== "Escape") return;
      if (menu) { event.preventDefault(); setMenu(null); pill.current?.focus(); }
      else if (phase !== "idle") void sendIntent({ action: "cancelDictation" }).catch(reportUiError);
    };
    const outside = (event: PointerEvent) => {
      if (menu && !companionElement.current?.contains(event.target as Node) && !pill.current?.contains(event.target as Node)) setMenu(null);
    };
    window.addEventListener("keydown", handler); window.addEventListener("pointerdown", outside);
    return () => { window.removeEventListener("keydown", handler); window.removeEventListener("pointerdown", outside); };
  }, [menu, phase]);
  useEffect(() => {
    const win = getCurrentWindow();
    if (mode !== "idle" || hasCompanion || settings?.showOverlayWhenIdle) void win.show().catch(reportUiError);
    else if (settings) void win.hide().catch(reportUiError);
  }, [mode, hasCompanion, settings?.showOverlayWhenIdle]);

  const send = (intent: WorkspaceIntent) => { setMenu(null); void sendIntent(intent).catch(reportUiError); };
  const openMeetingNotes = async () => {
    setMenu(null);
    try {
      const win = await Window.getByLabel("meeting-notes");
      if (win) { await placeCompanionWindow(win); await win.show(); await win.setFocus(); }
    }
    catch (error) { reportUiError(error); }
  };
  const screenshot = (kind: "area" | "window" | "screen") => send({ action: "screenshot", kind });
  const resolveShort = async (action: "summarize" | "keep" | "delete") => {
    if (!shortMeeting) return;
    try {
      if (action === "summarize") await summarizeShortMeeting(shortMeeting.id);
      else if (action === "keep") await skipSummary(shortMeeting.id);
      else await deleteMeeting(shortMeeting.id);
      setShortMeeting(null); await emitTo("main", "workspace://refresh-meetings");
    } catch (error) { reportUiError(error); }
  };
  const menuKeys = (event: React.KeyboardEvent<HTMLDivElement>) => {
    const buttons = Array.from(event.currentTarget.querySelectorAll<HTMLButtonElement>("button"));
    const index = buttons.indexOf(document.activeElement as HTMLButtonElement);
    if (["ArrowDown", "ArrowUp", "Home", "End"].includes(event.key)) {
      event.preventDefault();
      const next = event.key === "Home" ? 0 : event.key === "End" ? buttons.length - 1 : (index + (event.key === "ArrowDown" ? 1 : -1) + buttons.length) % buttons.length;
      buttons[next]?.focus();
    } else if (event.key === "ArrowLeft" && menu === "position") { event.preventDefault(); setMenu("main"); }
    else if (event.key === "ArrowRight" && document.activeElement?.getAttribute("aria-haspopup") === "menu") { event.preventDefault(); setMenu("position"); }
    else if (event.key === "Tab") { setMenu(null); }
  };
  const camera = <ScreenshotButton title={hint(activeMeeting ? "Screenshot into this meeting · hold for more" : "Screenshot to today’s note · hold for more", "screenshotArea")}
    onCapture={() => screenshot("area")} onMenu={() => setMenu("screenshot")} />;

  return <div style={{ width: windowWidth, height: windowHeight, background: "transparent", fontFamily: "system-ui", position: "relative", overflow: "hidden" }}>
    {/* Catch hover around the tiny idle sliver, matching the padded NSPanel hit area. */}
    <div style={{ position: "absolute", left: Math.max(0, center.x - (vertical ? 26 : (length + 20) / 2)),
      top: Math.max(0, center.y - (vertical ? (length + 20) / 2 : 26)), width: vertical ? 52 : length + 20, height: vertical ? length + 20 : 52 }}
      onMouseEnter={enter} onMouseLeave={leave} />
    <div ref={pill} tabIndex={0} aria-label={`OpenScribe Flowbar. ${help}`} title={help}
      onPointerDown={onPointerDown} onClickCapture={onClickCapture}
      onMouseEnter={enter} onMouseLeave={leave}
      onFocus={() => setFocused(true)} onBlur={event => { if (!event.currentTarget.contains(event.relatedTarget)) setFocused(false); }}
      onKeyDown={event => {
        if (event.key === "ContextMenu" || (event.shiftKey && event.key === "F10")) { event.preventDefault(); setMenu("main"); }
      }}
      onContextMenu={event => { event.preventDefault(); setMenu(menu === "main" ? null : "main"); }}
      style={{ position: "absolute", left: pillCenter.x, top: pillCenter.y, transform: "translate(-50%, -50%)",
        width: pillWidth, height: pillHeight, borderRadius: 999, color: "var(--os-flowbar-ink)", touchAction: "none",
        background: mode === "idle" ? "var(--os-flowbar-idle-fill)" : "var(--os-flowbar)",
        border: mode === "idle" ? "0.5px solid var(--os-flowbar-idle-line)" : "1px solid var(--os-flowbar-line)",
        boxShadow: mode === "idle" ? undefined : "var(--os-flowbar-shadow)", display: "flex", flexDirection: vertical ? "column" : "row",
        alignItems: "center", justifyContent: "space-evenly", cursor: "grab", boxSizing: "border-box",
        transition: "width 300ms cubic-bezier(.2,.8,.2,1), height 300ms cubic-bezier(.2,.8,.2,1), background 150ms ease", overflow: "hidden" }}>
      {mode === "idle" && <FlowbarIconButton onClick={() => send({ action: "dictate" })} title="Start dictation" style={{ width: "100%", height: "100%", padding: 0 }} />}
      {mode === "idleExpanded" && <>
        <FlowbarIconButton onClick={() => send({ action: "dictate" })} title="Start dictation"><FlowbarSquiggle width={34} height={14} vertical={vertical} /></FlowbarIconButton>
        <FlowbarIconButton onClick={() => send({ action: "dictate" })} title={hint("Dictate", "dictate")}><Mic size={13} aria-hidden="true" /></FlowbarIconButton>
        <FlowbarIconButton onClick={() => send({ action: "meeting" })} title={hint("Start meeting", "meeting")}><Users size={13} aria-hidden="true" /></FlowbarIconButton>
        {camera}
      </>}
      {mode === "dictating" && <FlowbarIconButton onClick={() => send({ action: "dictate" })} title="Listening. Click to finish, or press Escape to cancel.">
        <FlowbarSquiggle width={64} height={20} level={level} motion="live" vertical={vertical} />
      </FlowbarIconButton>}
      {(mode === "processing" || mode === "meetingSaving") && <span role="status" aria-label={help}>
        <FlowbarSquiggle width={64} height={16} motion="flowing" color="var(--os-flowbar-accent)" vertical={vertical} />
      </span>}
      {mode === "confirmation" && <span role="status" aria-label={confirmation ?? "Saved"} title={confirmation ?? "Saved"}>
        <Check size={16} color="var(--os-flowbar-accent)" aria-hidden="true" />
      </span>}
      {mode === "meeting" && <>
        <FlowbarIconButton onClick={() => { void openMeetingNotes(); }} title={paused ? "Meeting paused. Open meeting notes." : "Recording meeting. Open meeting notes."} style={{ opacity: paused ? 0.4 : 1 }}>
          <FlowbarSquiggle width={expanded ? 34 : 40} height={18} level={level} motion={paused ? "still" : "live"} vertical={vertical} />
        </FlowbarIconButton>
        {expanded && <>
          <FlowbarIconButton onClick={() => { void openMeetingNotes(); }} title="Meeting notes"><FileText size={13} aria-hidden="true" /></FlowbarIconButton>
          {camera}
        </>}
        <FlowbarIconButton onClick={() => send({ action: "meeting" })} title="Stop meeting and save" style={{ color: "var(--os-flowbar-recording)", background: "var(--os-flowbar-recording-soft)", opacity: paused ? 0.6 : 1 }}>
          <Square size={8} fill="currentColor" aria-hidden="true" />
        </FlowbarIconButton>
      </>}
    </div>
    {hasCompanion && <div ref={companionElement} onMouseEnter={enter} onMouseLeave={leave}
      style={{ position: "absolute", left: companion?.x ?? 0, top: companion?.y ?? 0, width: menu ? 224 : 300,
        maxHeight: Math.max(80, window.screen.availHeight - 40), overflowY: "auto", zIndex: 30, display: "flex", flexDirection: "column", gap: 4, alignItems: "center" }}>
      {menu ? <div ref={menuElement} role="menu" aria-label={menu === "position" ? "Position" : menu === "screenshot" ? "Screenshot" : "Flowbar actions"} onKeyDown={menuKeys}
        style={{ background: "var(--os-flowbar)", color: "var(--os-flowbar-ink)", border: "1px solid var(--os-flowbar-line)", borderRadius: 10,
          padding: 6, display: "flex", flexDirection: "column", gap: 2, fontSize: 12, boxShadow: "var(--os-flowbar-shadow)", width: "100%" }}>
        {menu === "screenshot" ? (["area", "window", "screen"] as const).map(kind => <FlowbarMenuItem key={kind} onClick={() => screenshot(kind)}>
          {hint(kind === "area" ? "Area" : kind === "window" ? "Window" : "Full screen", kind === "area" ? "screenshotArea" : kind === "window" ? "screenshotWindow" : "screenshotScreen")}
        </FlowbarMenuItem>) : menu === "position" ? <>
          <FlowbarMenuItem onClick={() => setMenu("main")}><ChevronLeft size={12} aria-hidden="true" />Position</FlowbarMenuItem>
          {positionPresets.map(([title, value]) => <FlowbarMenuItem key={value} checked={!settings?.flowbarPlacement && settings?.overlayPosition === value}
            onClick={() => send({ action: "updatePreference", key: "overlayPosition", value })}>{title}</FlowbarMenuItem>)}
        </> : menuEntries(mode, paused, settings?.showOverlayWhenIdle ?? false).map(entry => !entry.label
          ? <div key={entry.id} role="separator" style={{ height: 1, background: "var(--os-flowbar-line)", margin: "3px 2px" }} />
          : <FlowbarMenuItem key={entry.id} checked={entry.checked} destructive={entry.destructive} submenu={entry.id === "position"}
            onClick={() => { if (entry.id === "position") setMenu("position"); else if (entry.id === "meeting-notes") void openMeetingNotes(); else if (entry.intent) send(entry.intent); }}>{entry.label}</FlowbarMenuItem>)}
      </div> : <><NoticeBubble notice={notice} isError shortMeeting={shortMeeting}
        onDismissNotice={() => send({ action: "dismissNotice" })} onInspectNotice={() => send({ action: "inspectNotice" })}
        onResolveShortMeeting={action => { void resolveShort(action); }} />
        {showTranscript && <div role="status" aria-live="polite" style={{ width: "100%", boxSizing: "border-box", padding: 12, borderRadius: 10, background: "var(--os-flowbar)", color: "var(--os-flowbar-ink)", border: "1px solid var(--os-flowbar-line)", boxShadow: "var(--os-flowbar-shadow)" }}>
          <div style={{ fontSize: 11, opacity: 0.7 }}>{captureHint}</div>
          {currentTranscript && <div style={{ marginTop: 6, fontSize: 13, lineHeight: 1.5, maxHeight: 150, overflowY: "auto", whiteSpace: "pre-wrap", overflowWrap: "anywhere" }}>{currentTranscript}</div>}
        </div>}</>}
    </div>}
  </div>;
};
