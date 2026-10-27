import React, { useCallback, useEffect, useState, useSyncExternalStore } from "react";
import { Window } from "@tauri-apps/api/window";
import { AlertTriangle, CalendarDays, Command, FileAudio, Library, ListPlus, LockKeyhole, Network, ShieldCheck, SlidersHorizontal, Users, X } from "lucide-react";
import { mainController } from "./mainController";
import { dictationHint } from "./core/shortcuts";
import { MeetingsView } from "./views/meetings/MeetingsView";
import { NotesView } from "./views/notes/NotesView";
import { CaptureDock } from "./views/CaptureDock";
import { OnboardingView } from "./views/OnboardingView";
import { SettingsDialog } from "./views/settings/SettingsDialog";
import { writeText } from "@tauri-apps/plugin-clipboard-manager";
import type { SettingsSection } from "./views/settings/SettingsView";
import { SettingsView } from "./views/settings/SettingsView";
import type { ParitySettings } from "./api/parityTypes";
import { useAppliedTheme } from "./theme";
import { ConfirmDialog } from "./views/ConfirmDialog";
import { matchWorkspaceShortcut } from './core/inAppShortcuts';
export { defaultParitySettings } from "./settings";

export default function App() {
  const { settings, notes, meetings, calendarEvents, recoveries, inputs, loaded, storageError, notice, phase, startPrompt, endPrompt, navigation, shortcutFailures, noticeDetails } = useSyncExternalStore(mainController.subscribe, mainController.snapshot);
  const activeMeetingId = mainController.activeMeeting?.id ?? null;
  // As on macOS, the hint names the dictation key only while it is actually registered.
  const hint = dictationHint(settings.shortcuts ?? {}, shortcutFailures);
  const [section, setSection] = useState<"notes" | "meetings" | "calendar" | "settings">("notes");
  const [settingsSection, setSettingsSection] = useState<SettingsSection>("general");
  useEffect(() => {
    const handler = (event: KeyboardEvent) => {
      const action = matchWorkspaceShortcut(event);
      if (!action) return;
      event.preventDefault();
      if (action.type === 'navigate') {
        setSection(action.section);
      } else if (action.type === 'openSettings') {
        setSettingsSection('general');
        setSection('settings');
      }
    };
    window.addEventListener('keydown', handler);
    return () => window.removeEventListener('keydown', handler);
  }, []);
  const [setup, setSetup] = useState(false);
  const [detailCopied, setDetailCopied] = useState(false);
  const [selectedNoteId, setSelectedNoteId] = useState("today-placeholder");
  const [selectedMeetingId, setSelectedMeetingId] = useState<string>();
  const [confirmDiscardAll, setConfirmDiscardAll] = useState(false);
  const [now, setNow] = useState(Date.now());
  const autoStartCountdown = startPrompt?.automatic ? Math.max(0, Math.ceil((Date.parse(startPrompt.deadline) - now) / 1000)) : null;
  const endCountdown = endPrompt?.automatic ? Math.max(0, Math.ceil((Date.parse(endPrompt.deadline) - now) / 1000)) : null;
  useEffect(() => { void mainController.initialize(); }, []);
  useEffect(() => {
    if (navigation) { setSection(navigation.section); if (navigation.meetingId) setSelectedMeetingId(navigation.meetingId); if (navigation.noteId) setSelectedNoteId(navigation.noteId); if (navigation.settingsSection) setSettingsSection(navigation.settingsSection); }
  }, [navigation]);
  useAppliedTheme(settings.theme);
  useEffect(() => {
    if (!startPrompt && !endPrompt) return;
    setNow(Date.now());
    const timer = window.setInterval(() => setNow(Date.now()), 250);
    return () => window.clearInterval(timer);
  }, [startPrompt, endPrompt]);
  useEffect(() => {
    const handleKey = (event: KeyboardEvent) => { if (event.key === "Escape") void mainController.dictation.finish(true); if (event.ctrlKey && !event.altKey && ["1", "2", "3"].includes(event.key)) { event.preventDefault(); setSection(({ "1": "notes", "2": "meetings", "3": "calendar" } as const)[event.key as "1" | "2" | "3"]); } };
    window.addEventListener("keydown", handleKey);
    return () => window.removeEventListener("keydown", handleKey);
  }, []);
  const handleUpdateSettings = useCallback((updated: ParitySettings) => mainController.updateSettings(updated), []);
  const handleCalendarStartDecision = (decision: "start" | "skip") => { if (startPrompt) void mainController.decide(startPrompt, decision).catch(mainController.error); };
  const handleCalendarEndDecision = (decision: "finish" | "extend") => { if (endPrompt) void mainController.decide(endPrompt, decision).catch(mainController.error); };
  const handleStartDictation = () => { void mainController.intent({ action: "dictate" }); };
  const handleStartMeetingFromDock = () => {
    if (activeMeetingId) { setSection("meetings"); setSelectedMeetingId(activeMeetingId); }
    else void mainController.intent({ action: "meeting" });
  };
  const handleRevealFlowbar = async () => {
    try { const flowbar = await Window.getByLabel("flowbar"); await flowbar?.show(); }
    catch (error) { mainController.error(error); }
  };
  const setNotes = mainController.setNotes;
  const setMeetings = mainController.setMeetings;

  if (!loaded) {
    return (
      <div
        style={{
          display: "flex",
          alignItems: "center",
          justifyContent: "center",
          height: "100vh",
          background: "var(--os-background)",
          color: "var(--os-ink-muted)",
          fontFamily: "inherit"
        }}
      >
        <span>Opening your workspace…</span>
      </div>
    );
  }

  return (
    <div
      className="workspace-shell"
      style={{
        display: "flex",
        width: "100vw",
        height: "100vh",
        background: "var(--os-background)",
        color: "var(--os-ink)",
        overflow: "hidden"
      }}
    >
      {setup && <div style={{ position: "fixed", inset: 0, zIndex: 100 }}><OnboardingView settings={settings} onUpdateSettings={updated => mainController.updateSettings(updated)} phase={phase} transcript={notes[0]?.cleanedText} captureHint={notice ?? undefined} onLater={() => setSetup(false)} onComplete={async () => { await mainController.updateSettings({ ...settings, hasCompletedSetup: true }); setSetup(false); }} /></div>}
      {noticeDetails && <SettingsDialog title="Notice details" onClose={mainController.closeNoticeDetails}><pre style={{ whiteSpace: "pre-wrap", overflowWrap: "anywhere" }}>{notice ?? storageError ?? "No current notice."}</pre><div style={{ display: "flex", gap: 8 }}><button onClick={() => { void writeText(notice ?? storageError ?? "").then(() => setDetailCopied(true)).catch(mainController.error); }}>{detailCopied ? "Copied" : "Copy details"}</button><button onClick={() => { mainController.closeNoticeDetails(); setSection("settings"); setSettingsSection("providers"); }}>Settings</button><button onClick={mainController.closeNoticeDetails}>Done</button></div></SettingsDialog>}
      {/* Main Sidebar */}
      <aside
        className="workspace-sidebar"
        style={{
          width: 210, flexShrink: 0, overflowY: "auto",
          borderRight: "1px solid var(--os-line)",
          display: "flex",
          flexDirection: "column",
          padding: "24px 14px 16px",
          background: "var(--os-background)"
        }}
      >
        {/* Brand */}
        <div style={{ display: "flex", alignItems: "center", gap: 10, marginBottom: 26, paddingLeft: 6 }}>
          <div
            style={{
              width: 26,
              height: 26,
              borderRadius: 7,
              background: "var(--os-accent)",
              display: "flex",
              alignItems: "center",
              justifyContent: "center",
              color: "var(--os-primary-text)",
              fontWeight: 700,
              fontSize: 14
            }}
          >
            OS
          </div>
          <div>
            <strong style={{ fontSize: 14, display: "block", letterSpacing: "-0.02em" }}>
              OpenScribe
            </strong>
            <span style={{ fontSize: 9.5, fontWeight: 600, letterSpacing: "0.06em", color: "var(--os-ink-muted)" }}>
              VOICE WORKSPACE
            </span>
          </div>
        </div>

        {/* Section Links */}
        <div style={{ fontSize: 10, fontWeight: 700, letterSpacing: "0.08em", color: "var(--os-ink-muted)", marginBottom: 8, paddingLeft: 6 }}>
          LIBRARY
        </div>
        <nav style={{ display: "flex", flexDirection: "column", gap: 3 }}>
          <button
            aria-current={section === "notes" ? "page" : undefined}
            onClick={() => setSection("notes")}
            style={{
              display: "flex",
              alignItems: "center",
              justifyContent: "space-between",
              padding: "7px 10px",
              borderRadius: 7,
              border: "none",
              background: section === "notes" ? "var(--os-surface-hover)" : "transparent",
              color: section === "notes" ? "color-mix(in srgb, var(--os-accent) 90%, var(--os-ink))" : "inherit",
              cursor: "pointer",
              fontSize: 13,
              fontWeight: section === "notes" ? 600 : 500
            }}
          >
            <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
              <Library size={16} />
              <span>Notes</span>
            </div>
            <span style={{ fontSize: 11, color: "var(--os-ink-muted)" }}>{notes.length}</span>
          </button>

          <button
            aria-current={section === "meetings" ? "page" : undefined}
            onClick={() => setSection("meetings")}
            style={{
              display: "flex",
              alignItems: "center",
              justifyContent: "space-between",
              padding: "7px 10px",
              borderRadius: 7,
              border: "none",
              background: section === "meetings" ? "var(--os-surface-hover)" : "transparent",
              color: section === "meetings" ? "color-mix(in srgb, var(--os-accent) 90%, var(--os-ink))" : "inherit",
              cursor: "pointer",
              fontSize: 13,
              fontWeight: section === "meetings" ? 600 : 500
            }}
          >
            <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
              <Users size={16} />
              <span>Meetings</span>
            </div>
            <span style={{ fontSize: 11, color: "var(--os-ink-muted)" }}>{meetings.length}</span>
          </button>

          <button
            aria-current={section === "calendar" ? "page" : undefined}
            onClick={() => setSection("calendar")}
            style={{
              display: "flex",
              alignItems: "center",
              justifyContent: "space-between",
              padding: "7px 10px",
              borderRadius: 7,
              border: "none",
              background: section === "calendar" ? "var(--os-surface-hover)" : "transparent",
              color: section === "calendar" ? "color-mix(in srgb, var(--os-accent) 90%, var(--os-ink))" : "inherit",
              cursor: "pointer",
              fontSize: 13,
              fontWeight: section === "calendar" ? 600 : 500
            }}
          >
            <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
              <CalendarDays size={16} />
              <span>Calendar</span>
            </div>
            <span style={{ fontSize: 11, color: "var(--os-ink-muted)" }}>{calendarEvents.length}</span>
          </button>
        </nav>

        <div style={{ fontSize: 10, color: "var(--os-ink-muted)", margin: "10px 6px 6px" }}>SETTINGS</div>
        <nav aria-label="Settings" style={{ display: "grid", gap: 2 }}>
          {([ ["general", "General", SlidersHorizontal], ["shortcuts", "Shortcuts", Command], ["providers", "API & Models", Network], ["personalize", "Personalization", ListPlus], ["privacy", "Privacy", LockKeyhole], ["permissions", "Permissions", ShieldCheck] ] as const).map(([id, label, Icon]) => { const current = section === "settings" && settingsSection === id; return <button key={id} aria-current={current ? "page" : undefined} onClick={() => { setSettingsSection(id); setSection("settings"); }} style={{ display: "flex", alignItems: "center", gap: 8, textAlign: "left", padding: "7px 10px", border: "none", borderRadius: 7, fontSize: 13, fontWeight: current ? 600 : 500, color: current ? "color-mix(in srgb, var(--os-accent) 90%, var(--os-ink))" : "inherit", background: current ? "var(--os-surface-hover)" : "transparent" }}><Icon size={16} />{label}</button>; })}
        </nav>
        <div style={{ flex: 1, minHeight: 12 }} />
        <CaptureDock phase={phase} meeting={mainController.activeMeeting} hint={hint} needsSetup={!settings.hasCompletedSetup} onSetup={() => setSetup(true)} />
      </aside>

      {/* Main Workspace Column */}
      <main style={{ flex: 1, minWidth: 0, minHeight: 0, display: "flex", flexDirection: "column", height: "100%", overflow: "hidden" }}>
        <div className="workspace-banners">
          {notice && <div className="workspace-banner" role="alert" style={{ padding: "10px 24px", background: "var(--os-recording-soft)", color: "var(--os-ink)", display: "flex", gap: 12 }}><span style={{ flex: 1 }}>{notice}</span><button onClick={() => { void mainController.intent({ action: "inspectNotice" }); }}>Details</button><button onClick={mainController.clearNotice} aria-label="Dismiss notice"><X size={14} /></button></div>}
          {/* Global Storage Error Banner */}
          {storageError && (
            <div
              className="workspace-banner"
              style={{
                background: "var(--os-recording-soft)",
                borderBottom: "1px solid var(--os-line)",
                padding: "10px 24px",
                display: "flex",
                alignItems: "center",
                justifyContent: "space-between"
              }}
            >
              <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
                <AlertTriangle size={16} color="var(--os-recording)" />
                <strong style={{ fontSize: 12.5, color: "var(--os-ink)" }}>
                  Check your local history: {storageError}
                </strong>
              </div>
              <button
                aria-label="Dismiss storage error"
                onClick={mainController.clearStorageError}
                style={{ background: "transparent", border: "none", cursor: "pointer", color: "var(--os-ink)" }}
              >
                <X size={14} />
              </button>
            </div>
          )}

          {/* Failed-Recording Banner with Discard All and Retry */}
          {recoveries.length > 0 && (
            <div
              className="workspace-banner"
              style={{
                background: "var(--os-warning-soft)",
                borderBottom: "1px solid var(--os-line)",
                padding: "10px 24px",
                display: "flex",
                alignItems: "center",
                justifyContent: "space-between"
              }}
            >
              <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
                <FileAudio size={16} color="var(--os-warning)" />
                <strong style={{ fontSize: 12.5, color: "var(--os-ink)" }}>
                  {recoveries.length > 1
                    ? `${recoveries.length} recordings weren’t transcribed`
                    : "A recording wasn’t transcribed"}
                </strong>
                <span style={{ fontSize: 12, color: "var(--os-ink)" }}>
                  Audio is saved on this device.
                </span>
              </div>

              <div style={{ display: "flex", gap: 8 }}>
                <button
                  onClick={() => setConfirmDiscardAll(true)}
                  style={{
                    background: "transparent",
                    border: "none",
                    color: "var(--os-ink)",
                    fontSize: 12,
                    cursor: "pointer"
                  }}
                >
                  {recoveries.length > 1 ? "Discard all" : "Discard"}
                </button>
                <button
                  disabled={phase !== "idle"}
                  onClick={() => { void mainController.dictation.retry(); }}
                  style={{
                    background: "var(--os-accent)",
                    color: "var(--os-primary-text)",
                    border: "none",
                    borderRadius: 6,
                    padding: "4px 10px",
                    fontSize: 12,
                    fontWeight: 600,
                    cursor: "pointer"
                  }}
                >
                  Retry
                </button>
              </div>
            </div>
          )}

          {/* Confirmation modal for Discard All */}
          {confirmDiscardAll && (
            <ConfirmDialog
              title={`Discard ${recoveries.length} recordings?`}
              confirmLabel={recoveries.length > 1 ? "Discard all" : "Discard"}
              onCancel={() => setConfirmDiscardAll(false)}
              onConfirm={() => { void mainController.dictation.discard(); setConfirmDiscardAll(false); }}
            >
              Their audio is deleted from this device. Notes and meetings you already have are not affected.
            </ConfirmDialog>
          )}

          {/* Calendar Start Prompt Dialog */}
          {startPrompt && (
            <div
              className="workspace-banner"
              style={{
                background: "var(--os-accent-soft)",
                borderBottom: "1px solid var(--os-line)",
                padding: "12px 24px",
                display: "flex",
                alignItems: "center",
                justifyContent: "space-between"
              }}
            >
              <div>
                <strong style={{ fontSize: 13, color: "color-mix(in srgb, var(--os-accent) 90%, var(--os-ink))" }}>
                  Do you want to record: {startPrompt.event.title ?? "Upcoming Meeting"}?
                </strong>
                {autoStartCountdown != null && (
                  <span style={{ fontSize: 12, color: "color-mix(in srgb, var(--os-accent) 90%, var(--os-ink))", display: "block" }}>
                    Auto-starting in {autoStartCountdown}s…
                  </span>
                )}
              </div>
              <div style={{ display: "flex", gap: 8 }}>
                <button
                  onClick={() => handleCalendarStartDecision("start")}
                  style={{
                    background: "var(--os-accent)",
                    color: "var(--os-primary-text)",
                    border: "none",
                    borderRadius: 6,
                    padding: "5px 12px",
                    fontSize: 12,
                    fontWeight: 600,
                    cursor: "pointer"
                  }}
                >
                  Record meeting
                </button>
                <button
                  onClick={() => handleCalendarStartDecision("skip")}
                  style={{
                    background: "var(--os-surface)",
                    border: "1px solid var(--os-line)",
                    color: "color-mix(in srgb, var(--os-accent) 90%, var(--os-ink))",
                    borderRadius: 6,
                    padding: "5px 12px",
                    fontSize: 12,
                    cursor: "pointer"
                  }}
                >
                  Skip
                </button>
              </div>
            </div>
          )}

          {/* Calendar End Prompt Dialog */}
          {endPrompt && (
            <div
              className="workspace-banner"
              style={{
                background: "var(--os-accent-soft)",
                borderBottom: "1px solid var(--os-line)",
                padding: "12px 24px",
                display: "flex",
                alignItems: "center",
                justifyContent: "space-between"
              }}
            >
              <strong style={{ fontSize: 13, color: "color-mix(in srgb, var(--os-accent) 90%, var(--os-ink))" }}>
                Meeting scheduled to end: {endPrompt.event.title ?? "Meeting"}
              </strong>
              <div style={{ display: "flex", gap: 8 }}>
                <button
                  onClick={() => handleCalendarEndDecision("finish")}
                  style={{
                    background: "var(--os-accent)",
                    color: "var(--os-primary-text)",
                    border: "none",
                    borderRadius: 6,
                    padding: "5px 12px",
                    fontSize: 12,
                    fontWeight: 600,
                    cursor: "pointer"
                  }}
                >
                  Finish meeting{endCountdown != null ? ` (${endCountdown}s)` : ""}
                </button>
                <button
                  onClick={() => handleCalendarEndDecision("extend")}
                  style={{
                    background: "var(--os-surface)",
                    border: "1px solid var(--os-line)",
                    color: "color-mix(in srgb, var(--os-accent) 90%, var(--os-ink))",
                    borderRadius: 6,
                    padding: "5px 12px",
                    fontSize: 12,
                    cursor: "pointer"
                  }}
                >
                  Extend 15 min
                </button>
              </div>
            </div>
          )}

        </div>

        {/* Active Section View */}
        <div style={{ flex: 1, minWidth: 0, minHeight: 0, overflow: 'hidden', display: 'grid', gridTemplateRows: '1fr', gridTemplateColumns: '1fr', position: 'relative' }}>
          <div style={{ gridArea: '1 / 1 / 2 / 2', width: '100%', height: '100%', overflow: 'hidden', display: section === 'notes' ? 'block' : 'none' }}>
            <NotesView
              active={section === 'notes'}
              notes={notes}
              selectedId={selectedNoteId}
              onSelectNote={setSelectedNoteId}
              onUpdateNotes={setNotes}
              onRefreshNotes={() => mainController.refreshNotes()}
              onOpenMeeting={(meetingId) => {
                setSection('meetings');
                setSelectedMeetingId(meetingId);
              }}
              onStartDictation={handleStartDictation}
              onStartMeeting={handleStartMeetingFromDock}
            />
          </div>

          <div style={{ gridArea: '1 / 1 / 2 / 2', width: '100%', height: '100%', overflow: 'hidden', display: section === 'meetings' ? 'block' : 'none' }}>
            <MeetingsView
              meetings={meetings}
              activeMeetingId={activeMeetingId}
              selectedId={selectedMeetingId}
              settings={settings}
              onSelectMeeting={setSelectedMeetingId}
              onUpdateMeetings={setMeetings}
              onUpdateSettings={handleUpdateSettings}
            />
          </div>

          <div style={{ gridArea: '1 / 1 / 2 / 2', width: '100%', height: '100%', overflow: 'hidden', display: section === 'calendar' ? 'block' : 'none' }}>
            <SettingsView
              key='calendar'
              initialSection='calendar'
              inputs={inputs}
              settings={settings}
              calendarEvents={calendarEvents}
              onUpdateSettings={handleUpdateSettings}
              onRefreshCalendar={() => { void mainController.refreshCalendar().catch(mainController.error); }}
              onRevealFlowbar={handleRevealFlowbar}
            />
          </div>

          <div style={{ gridArea: '1 / 1 / 2 / 2', width: '100%', height: '100%', overflow: 'hidden', display: section === 'settings' ? 'block' : 'none' }}>
            <SettingsView
              key='settings'
              hideNavigation
              selectedSection={settingsSection}
              onSectionChange={next => { if (next === 'calendar') setSection('calendar'); else setSettingsSection(next); }}
              notesCount={notes.length}
              meetingsCount={meetings.length}
              inputs={inputs}
              settings={settings}
              calendarEvents={calendarEvents}
              onUpdateSettings={handleUpdateSettings}
              onRefreshCalendar={() => { void mainController.refreshCalendar().catch(mainController.error); }}
              onClearNotesHistory={() => { void mainController.clearNotes().catch(mainController.error); }}
              onRevealFlowbar={handleRevealFlowbar}
            />
          </div>
        </div>
      </main>
    </div>
  );
}
