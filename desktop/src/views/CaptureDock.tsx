import { useEffect, useState } from "react";
import { Mic, Pause, Play, ScanLine, Sparkles, Square, SquarePen, Users, X } from "lucide-react";
import { parityEvents } from "../api/parity";
import type { MeetingRecord } from "../api/parityTypes";
import type { DictationPhase } from "../dictation";
import { FlowbarSquiggle } from "../flowbar/FlowbarSquiggle";
import { mainController } from "../mainController";
import { ListenerScope } from "../listeners";

const clock = (seconds: number) => `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, "0")}`;

/** The always-available capture controls at the foot of the sidebar. Mirrors CaptureDock in MainWorkspaceView.swift. */
export function CaptureDock({ phase, meeting, hint, needsSetup, onSetup }: { phase: DictationPhase; meeting: MeetingRecord | null; hint: string | null; needsSetup: boolean; onSetup: () => void }) {
  const [level, setLevel] = useState(0), [seconds, setSeconds] = useState(0);
  useEffect(() => {
    const scope = new ListenerScope();
    scope.add(parityEvents.onDictationLevel(({ level }) => setLevel(level)), mainController.error);
    scope.add(parityEvents.onMeetingLevel(({ level }) => setLevel(level)), mainController.error);
    return () => scope.dispose();
  }, []);
  useEffect(() => {
    if (phase !== "recording") { setSeconds(0); return; }
    const start = Date.now(); const timer = window.setInterval(() => setSeconds(Math.floor((Date.now() - start) / 1000)), 250);
    return () => clearInterval(timer);
  }, [phase]);
  const recording = phase === "recording" || meeting?.status === "recording";
  const cancel = () => { void mainController.dictation.finish(true); };
  const meter = (paused: boolean, time: string | null) => <div className="capture-dock-meter">
    {paused ? <Pause size={10} fill="currentColor" style={{ color: "var(--os-warning)" }} /> : <span className="capture-dock-dot" />}
    <FlowbarSquiggle width={112} height={18} level={level} motion={paused ? "still" : "live"} color="var(--os-recording)" />
    {time && <span className="capture-dock-time">{time}</span>}
  </div>;

  let body;
  if (meeting) {
    const paused = meeting.status === "paused";
    body = <>
      {meter(paused, null)}
      <div className="capture-dock-row">
        <button className="os-button small full" onClick={() => { void mainController.intent({ action: "open", section: "meetings", meetingId: meeting.id }); }}><SquarePen size={13} />Notes</button>
        <button className="os-button small" title={paused ? "Resume" : "Pause"} aria-label={paused ? "Resume" : "Pause"} onClick={() => { void mainController.intent({ action: "pauseMeeting" }); }}>{paused ? <Play size={13} /> : <Pause size={13} />}</button>
        <button className="os-button primary small full" onClick={() => { void mainController.intent({ action: "meeting" }); }}><Square size={11} fill="currentColor" />Stop</button>
      </div>
    </>;
  } else if (phase === "recording") {
    body = <>
      {meter(false, clock(seconds))}
      <div className="capture-dock-row">
        <button className="os-button primary full" onClick={() => { void mainController.intent({ action: "dictate" }); }}><Square size={11} fill="currentColor" />Stop &amp; save</button>
        <button className="os-button" title="Cancel recording" aria-label="Cancel recording" onClick={cancel}><X size={14} /></button>
      </div>
    </>;
  } else if (phase !== "idle") {
    body = <div className="capture-dock-meter">
      <FlowbarSquiggle width={36} height={16} motion="flowing" color="var(--os-accent)" />
      <span className="capture-dock-status">{phase === "cleaning" ? "Polishing…" : phase === "starting" ? "Starting…" : "Transcribing…"}</span>
      <button className="os-button small" title="Cancel" aria-label="Cancel" onClick={cancel}><X size={13} /></button>
    </div>;
  } else {
    body = <>
      {needsSetup && <button className="os-button small full capture-dock-setup" onClick={onSetup}><Sparkles size={13} />Finish setup</button>}
      <button className="os-button primary full" title="Saves to today’s note. Use the shortcut to dictate into any app." onClick={() => { void mainController.intent({ action: "dictate" }); }}>
        <Mic size={14} /><span style={{ flex: 1, textAlign: "left" }}>Dictate</span>{hint && <span className="capture-dock-hint">{hint}</span>}
      </button>
      <div className="capture-dock-row">
        <button className="os-button small full" onClick={() => { void mainController.intent({ action: "meeting" }); }}><Users size={13} />Meeting</button>
        <button className="os-button small" title="Screenshot to today’s note" aria-label="Screenshot" onClick={() => { void mainController.intent({ action: "screenshot", kind: "area" }); }}><ScanLine size={14} /></button>
      </div>
    </>;
  }
  return <section aria-label="Capture" className={`capture-dock${recording ? " recording" : ""}`}>{body}</section>;
}
