import React, { useEffect, useMemo, useRef, useState } from "react";
import {
  AlertCircle,
  AlertTriangle,
  ArrowRight,
  CheckCircle2,
  ChevronDown,
  Copy,
  ExternalLink,
  FileAudio,
  FileDown,
  FileText,
  Mic,
  MoreVertical,
  Pause,
  Play,
  Plus,
  RotateCw,
  Search,
  Sparkles,
  Speaker,
  Square,
  Trash2,
  Users,
  Volume2
} from "lucide-react";
import {
  cancelProcessing,
  deleteMeeting,
  exportMeetingMarkdown,
  finishMeeting,
  meetingAudioPath,
  pauseMeeting,
  processMeeting,
  resumeMeeting,
  retryLiveTranscription,
  skipSummary,
  startMeeting,
  summarizeShortMeeting,
  updateMeeting
} from "../../api/parity";
import type {
  MeetingRecord,
  MeetingSegment,
  ParitySettings,
  SummaryPoint
} from "../../api/parityTypes";
import {
  formatDuration,
  formatTimestamp,
  groupTranscriptPassages,
  mapCitations
} from "./transcriptHelpers";

import { reportUiError, sendIntent } from "../../workspaceEvents";
import { MeetingRecordings } from "./MeetingRecordings";
import { ConfirmDialog } from "../ConfirmDialog";
import { emitTo } from "@tauri-apps/api/event";
import { parityEvents } from "../../api/parity";
import { exportText } from "../notes/exportText";
import { AudioTrackDialog } from "./AudioTrackDialog";
import { withMeetingDraft } from "./meetingEditorHelpers";
import { SegmentAudio } from "./SegmentAudio";

interface MeetingsViewProps {
  meetings: MeetingRecord[];
  activeMeetingId?: string | null;
  selectedId?: string;
  settings: ParitySettings;
  onSelectMeeting: (id: string) => void;
  onUpdateMeetings: (meetings: MeetingRecord[]) => void;
  onUpdateSettings?: (settings: ParitySettings) => void;
}

export const MeetingsView: React.FC<MeetingsViewProps> = ({
  meetings,
  activeMeetingId,
  selectedId,
  settings,
  onSelectMeeting,
  onUpdateMeetings,
  onUpdateSettings
}) => {
  const [search, setSearch] = useState("");
  const [tab, setTab] = useState<"summary" | "transcript" | "notes">("notes");
  const [showAudio, setShowAudio] = useState(false);
  const [exportMenu, setExportMenu] = useState(false);
  const [audioSegmentId, setAudioSegmentId] = useState<string | null>(null);
  const [level, setLevel] = useState(0);
  const [liveProgress, setLiveProgress] = useState<Record<string, string>>({});
  const [saveStatus, setSaveStatus] = useState("");
  const [transcriptSearch, setTranscriptSearch] = useState("");
  const [trackFilter, setTrackFilter] = useState<"all" | "microphone" | "system">("all");
  const [startDropdown, setStartDropdown] = useState(false);
  const [confirmDiscardAll, setConfirmDiscardAll] = useState(false);
  const [pendingDelete, setPendingDelete] = useState<string | null>(null);
  const citationTarget = useRef<HTMLDivElement>(null);
  const [highlightedSegmentId, setHighlightedSegmentId] = useState<string | null>(null);

  const [drafts, setDrafts] = useState<Record<string, MeetingRecord>>({});
  const edits = useRef(new Map<string, MeetingRecord>());
  const saveTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const saveQueue = useRef<Promise<unknown>>(Promise.resolve());
  const refresh = useRef(onUpdateMeetings); refresh.current = onUpdateMeetings;
  const flushEdits = () => {
    const pending = [...edits.current.values()]; edits.current.clear();
    for (const record of pending) saveQueue.current = saveQueue.current.catch(() => undefined).then(async () => {
      await updateMeeting(record); refresh.current([]); setSaveStatus("Saved");
      setDrafts(current => { if (current[record.id] !== record) return current; const next = { ...current }; delete next[record.id]; return next; });
    }).catch(error => { setSaveStatus("Could not save. Your draft is kept here; edit or Retry save."); reportUiError(error); });
  };
  const editRecord = (record: MeetingRecord) => {
    setSaveStatus("Saving…");
    setDrafts(current => ({ ...current, [record.id]: record })); edits.current.set(record.id, record);
    if (saveTimer.current) clearTimeout(saveTimer.current); saveTimer.current = setTimeout(flushEdits, 400);
  };
  useEffect(() => () => { if (saveTimer.current) clearTimeout(saveTimer.current); flushEdits(); }, []);
  const run = (operation: Promise<unknown>) => { void operation.catch(reportUiError); };
  useEffect(() => {
    const levels = parityEvents.onMeetingLevel(value => setLevel(Math.max(0, Math.min(1, value.level))));
    const progress = parityEvents.onMeetingProgress(value => setLiveProgress(current => ({ ...current, [value.id]: value.message })));
    void levels.catch(reportUiError); void progress.catch(reportUiError);
    return () => { void levels.then(stop => stop()).catch(reportUiError); void progress.then(stop => stop()).catch(reportUiError); };
  }, [activeMeetingId]);
  const recoverableMeetings = meetings.filter(record => record.status === "failed" || record.status === "interrupted");

  // Group meetings by date
  const groupedMeetings = useMemo(() => {
    const q = search.trim().toLowerCase();
    const filtered = meetings.filter((m) => {
      if (!q) return true;
      return (
        m.title.toLowerCase().includes(q) ||
        (m.userNotes ?? "").toLowerCase().includes(q) ||
        m.segments.some((s) => s.text.toLowerCase().includes(q))
      );
    });

    const groups: Record<string, MeetingRecord[]> = {};
    const now = new Date();
    const todayStr = now.toDateString();
    const yesterday = new Date(now);
    yesterday.setDate(now.getDate() - 1);
    const yesterdayStr = yesterday.toDateString();

    filtered.forEach((m) => {
      const ts = (m.createdAt + 978307200) * 1000;
      const d = new Date(ts);
      let label: string;
      if (d.toDateString() === todayStr) {
        label = "Today";
      } else if (d.toDateString() === yesterdayStr) {
        label = "Yesterday";
      } else {
        label = d.toLocaleDateString(undefined, { month: "long", year: "numeric" });
      }
      if (!groups[label]) groups[label] = [];
      groups[label].push(m);
    });

    return groups;
  }, [meetings, search]);

  const selectedRecord = useMemo(() => {
    if (selectedId) {
      const record = meetings.find((m) => m.id === selectedId) ?? meetings[0]; return record ? withMeetingDraft(record, drafts[record.id]) : null;
    }
    return meetings[0] ? withMeetingDraft(meetings[0], drafts[meetings[0].id]) : null;
  }, [meetings, selectedId, drafts]);

  const passages = useMemo(() => {
    if (!selectedRecord) return [];
    return groupTranscriptPassages(
      selectedRecord.segments,
      trackFilter === "all" ? undefined : trackFilter
    ).filter((p) => {
      if (!transcriptSearch.trim()) return true;
      return p.text.toLowerCase().includes(transcriptSearch.toLowerCase());
    });
  }, [selectedRecord, trackFilter, transcriptSearch]);

  const handleStartMeeting = () => { setStartDropdown(false); run(sendIntent({ action: "meeting" })); };
  const handleFinish = () => { run(sendIntent({ action: "meeting" })); };
  const handlePauseResume = () => { run(sendIntent({ action: "pauseMeeting" })); };
  const handleDelete = async (id: string) => {
    try {
      edits.current.delete(id); await saveQueue.current;
      await deleteMeeting(id); onUpdateMeetings(meetings.filter(record => record.id !== id));
      if (selectedRecord?.id === id) onSelectMeeting("");
    } catch (error) { reportUiError(error); }
  };
  const handleExportMarkdown = async () => {
    if (!selectedRecord) return;
    try { const md = await currentMarkdown(); await navigator.clipboard.writeText(md); }
    catch (error) { reportUiError(error); }
  };
  const currentMarkdown = async () => {
    if (!selectedRecord) throw new Error("Select a meeting first.");
    flushEdits(); await saveQueue.current;
    // A failed debounce save keeps a draft. Export must retry that write and fail visibly if it cannot persist.
    if (drafts[selectedRecord.id]) await updateMeeting(selectedRecord);
    return exportMeetingMarkdown(selectedRecord.id);
  };

  const jumpToCitation = (sourceId: string) => {
    setTranscriptSearch("");
    setTrackFilter("all");
    setTab("transcript");
    setHighlightedSegmentId(sourceId);
    setAudioSegmentId(sourceId);
  };

  useEffect(() => {
    if (!highlightedSegmentId) return;
    citationTarget.current?.scrollIntoView({ block: "center", behavior: "smooth" });
    const timer = window.setTimeout(() => setHighlightedSegmentId(null), 3000);
    return () => window.clearTimeout(timer);
  }, [highlightedSegmentId]);

  useEffect(() => {
    setTranscriptSearch(""); setTrackFilter("all"); setHighlightedSegmentId(null); setAudioSegmentId(null); setShowAudio(false);
    setTab(selectedRecord?.id === activeMeetingId ? "notes" : selectedRecord?.summary ? "summary" : selectedRecord?.userNotes || !selectedRecord?.segments.length ? "notes" : "transcript");
  }, [selectedRecord?.id]);
  const isActive = selectedRecord?.id === activeMeetingId;
  const isProcessing = selectedRecord?.status === "transcribing" || selectedRecord?.status === "summarizing";

  return (
    <div style={{ display: "flex", width: "100%", height: "100%", overflow: "hidden" }}>
      {pendingDelete && <ConfirmDialog title="Delete this meeting?" confirmLabel="Delete" onCancel={() => setPendingDelete(null)} onConfirm={() => { const id = pendingDelete; setPendingDelete(null); void handleDelete(id); }}>The recording and transcript will be permanently deleted.</ConfirmDialog>}
      {/* Left Sidebar List */}
      <div
        className="library-pane"
        style={{
          width: 290, flexShrink: 0,
          borderRight: "1px solid var(--os-line)",
          display: "flex",
          flexDirection: "column",
          background: "var(--os-background)"
        }}
      >
        {/* Header */}
        <div
          style={{
            display: "flex",
            alignItems: "center",
            justifyContent: "space-between",
            padding: "20px 16px 12px"
          }}
        >
          <h2 style={{ fontSize: 20, fontWeight: 700, margin: 0, letterSpacing: "-0.03em" }}>
            Meetings
          </h2>
          <div style={{ position: "relative" }} onBlur={event => { if (!event.currentTarget.contains(event.relatedTarget)) setStartDropdown(false); }} onKeyDown={event => { if (event.key === "Escape") { event.stopPropagation(); setStartDropdown(false); } }}>
            <button disabled={!!activeMeetingId || (!settings.meetingMicrophone && !settings.meetingSystemAudio)} onClick={handleStartMeeting} style={{ background: "var(--os-accent)", color: "var(--os-primary-text)", border: 0, borderRadius: 6, padding: "5px 10px" }}>Start</button>
            <button
              aria-expanded={startDropdown}
              onClick={() => setStartDropdown((p) => !p)}
              style={{
                background: "var(--os-accent)",
                color: "var(--os-primary-text)",
                border: "none",
                borderRadius: 6,
                padding: "5px 10px",
                cursor: "pointer",
                display: "flex",
                alignItems: "center",
                gap: 4,
                fontSize: 12,
                fontWeight: 600
              }}
            >
              <ChevronDown size={12} aria-label="Meeting recording preferences" />
            </button>

            {startDropdown && (
              <div
                style={{
                  position: "absolute",
                  top: 32,
                  right: 0,
                  background: "var(--os-surface)",
                  border: "1px solid var(--os-line)",
                  borderRadius: 8,
                  padding: 8,
                  width: 220, flexShrink: 0,
                  zIndex: 60,
                  boxShadow: "var(--os-shadow)",
                  display: "flex",
                  flexDirection: "column",
                  gap: 6
                }}
              >
                <div style={{ fontSize: 11, fontWeight: 600, color: "var(--os-ink-muted)", padding: "2px 4px" }}>
                  RECORDING SOURCES
                </div>
                <label style={{ display: "flex", alignItems: "center", gap: 6, fontSize: 12, cursor: "pointer" }}>
                  <input
                    type="checkbox"
                    disabled={settings.meetingMicrophone && !settings.meetingSystemAudio}
                    checked={settings.meetingMicrophone}
                    onChange={(e) =>
                      onUpdateSettings?.({ ...settings, meetingMicrophone: e.target.checked })
                    }
                  />
                  Microphone
                </label>
                <label style={{ display: "flex", alignItems: "center", gap: 6, fontSize: 12, cursor: "pointer" }}>
                  <input
                    type="checkbox"
                    disabled={settings.meetingSystemAudio && !settings.meetingMicrophone}
                    checked={settings.meetingSystemAudio}
                    onChange={(e) =>
                      onUpdateSettings?.({ ...settings, meetingSystemAudio: e.target.checked })
                    }
                  />
                  System audio
                </label>
                <div style={{ height: 1, background: "var(--os-line)", margin: "4px 0" }} />
                <label style={{ display: "flex", alignItems: "center", gap: 6, fontSize: 12, cursor: "pointer" }}>
                  <input
                    type="checkbox"
                    checked={settings.meetingLiveTranscription}
                    onChange={(e) =>
                      onUpdateSettings?.({ ...settings, meetingLiveTranscription: e.target.checked })
                    }
                  />
                  Live transcript
                </label>
                <label style={{ display: "flex", alignItems: "center", gap: 6, fontSize: 12, cursor: "pointer" }}>
                  <input
                    type="checkbox"
                    checked={settings.meetingSummarize}
                    onChange={(e) =>
                      onUpdateSettings?.({ ...settings, meetingSummarize: e.target.checked })
                    }
                  />
                  Transcribe & summarize on stop
                </label>
                <button
                  disabled={!!activeMeetingId || (!settings.meetingMicrophone && !settings.meetingSystemAudio)}
                  onClick={handleStartMeeting}
                  style={{
                    background: "var(--os-accent)",
                    color: "var(--os-primary-text)",
                    border: "none",
                    borderRadius: 6,
                    padding: "6px",
                    fontSize: 12,
                    fontWeight: 600,
                    marginTop: 4,
                    cursor: "pointer"
                  }}
                >
                  Start now
                </button>
              </div>
            )}
          </div>
        </div>

        {/* Search */}
        <div style={{ padding: "0 16px 12px" }}>
          <div
            style={{
              display: "flex",
              alignItems: "center",
              gap: 8,
              background: "var(--os-surface)",
              border: "1px solid var(--os-line)",
              borderRadius: 8,
              padding: "6px 10px"
            }}
          >
            <Search size={14} color="var(--os-ink-muted)" />
            <input
              type="text"
              value={search}
              onChange={(e) => setSearch(e.target.value)}
              placeholder="Search meetings"
              style={{
                border: "none",
                outline: "none",
                background: "transparent",
                fontSize: 12.5,
                width: "100%"
              }}
            />
          </div>
        </div>

        {/* Groups */}
        <div style={{ flex: 1, minWidth: 0, minHeight: 0, overflowY: "auto", padding: "0 8px 16px" }}>
          {Object.keys(groupedMeetings).length === 0 && <p className="list-empty" role="status">{search.trim() ? "No matching meetings" : "No meetings yet"}</p>}
          {Object.entries(groupedMeetings).map(([groupTitle, list]) => (
            <div key={groupTitle} style={{ marginBottom: 12 }}>
              <div
                style={{
                  fontSize: 10.5,
                  fontWeight: 700,
                  letterSpacing: "0.06em",
                  color: "var(--os-ink-muted)",
                  textTransform: "uppercase",
                  padding: "6px 8px 4px"
                }}
              >
                {groupTitle}
              </div>
              {list.map((m) => {
                const isSelected = selectedRecord?.id === m.id;
                const isRec = m.status === "recording" || m.status === "paused";
                return (
                  <button
                    key={m.id}
                    aria-pressed={isSelected}
                    onClick={() => onSelectMeeting(m.id)}
                    style={{
                      width: "100%",
                      display: "flex",
                      flexDirection: "column",
                      gap: 4,
                      padding: "10px 12px",
                      borderRadius: 8,
                      background: isSelected ? "var(--os-surface-hover)" : "transparent",
                      border: "none",
                      textAlign: "left",
                      cursor: "pointer",
                      marginBottom: 3
                    }}
                  >
                    <div style={{ display: "flex", alignItems: "center", gap: 6 }}>
                      {isRec && (
                        <span
                          style={{
                            width: 7,
                            height: 7,
                            borderRadius: "50%",
                            background: m.status === "paused" ? "var(--os-warning)" : "var(--os-recording)"
                          }}
                        />
                      )}
                      <span
                        style={{
                          fontSize: 13,
                          fontWeight: 600,
                          color: "var(--os-ink)",
                          overflow: "hidden",
                          textOverflow: "ellipsis",
                          whiteSpace: "nowrap",
                      minWidth: 0,
                          flex: 1
                        }}
                      >
                        {m.title || "Untitled meeting"}
                      </span>
                    </div>

                    <div style={{ display: "flex", alignItems: "center", gap: 6, fontSize: 11, color: "var(--os-ink-muted)" }}>
                      <span>{formatDuration(m.duration)}</span>
                      <span>·</span>
                      <span
                        style={{
                          textTransform: "capitalize",
                          color: m.status === "ready" ? "color-mix(in srgb, var(--os-success) 60%, var(--os-ink))" : m.status === "failed" ? "color-mix(in srgb, var(--os-recording) 72%, var(--os-ink))" : "var(--os-ink-muted)"
                        }}
                      >
                        {m.status}
                      </span>
                    </div>
                    <span style={{ color: "var(--os-ink-muted)", fontSize: 12, overflow: "hidden", display: "-webkit-box", WebkitLineClamp: 2, WebkitBoxOrient: "vertical" }}>{(m.summary?.overview[0]?.text || m.userNotes || m.segments[0]?.text || "").slice(0, 280)}</span>
                  </button>
                );
              })}
            </div>
          ))}
        </div>
      </div>

      {/* Right Detail Pane */}
      <div className="detail-pane" style={{ flex: 1, minWidth: 0, minHeight: 0, display: "flex", flexDirection: "column", height: "100%", overflow: "hidden" }}>
        {selectedRecord ? (
          <>
            {showAudio && <AudioTrackDialog record={selectedRecord} busy={isActive || isProcessing} onEdit={editRecord} onClose={() => { flushEdits(); setShowAudio(false); }} />}
            {/* Detail Toolbar */}
            <div
              className="ui-toolbar"
              style={{
                display: "flex",
                alignItems: "center",
                justifyContent: "space-between",
                padding: "14px 28px",
                borderBottom: "1px solid var(--os-line)",
                background: "var(--os-background)"
              }}
            >
              <div style={{ display: "flex", flexWrap: "wrap", alignItems: "center", gap: 8 }}>
                <button onClick={() => { run(emitTo("main", "workspace://open-day", { meetingId: selectedRecord.id, createdAt: selectedRecord.createdAt })); }}>Open day note</button>
                <button onClick={() => setShowAudio(true)}>Audio &amp; track names…</button>
                <div style={{ position: "relative" }} onBlur={event => { if (!event.currentTarget.contains(event.relatedTarget)) setExportMenu(false); }}>
                  <button aria-expanded={exportMenu} onClick={() => setExportMenu(value => !value)}>Export ▾</button>
                  {exportMenu && <div style={{ position: "absolute", right: 0, top: 30, zIndex: 60, padding: 8, background: "var(--os-surface)", border: "1px solid var(--os-line)", borderRadius: 8, minWidth: 190 }}>
                    <button className="menu-item" onClick={() => { setExportMenu(false); run((async () => { const text = await currentMarkdown(); await exportText(text, selectedRecord.title, "md"); })()); }}>Export as Markdown…</button>
                    <button className="menu-item" onClick={() => { setExportMenu(false); void handleExportMarkdown(); }}>Copy Markdown</button>
                  </div>}
                </div>
                <input
                  type="text"
                  aria-label="Meeting title"
                  value={selectedRecord.title}
                  onChange={(e) => {
                    const updated = { ...selectedRecord, title: e.target.value };
                    editRecord(updated);
                  }}
                  style={{
                    fontSize: 20,
                    fontWeight: 700,
                    border: "none",
                    outline: "none",
                    background: "transparent",
                    color: "var(--os-ink)",
                    maxWidth: 360
                  }}
                />
              </div>

              <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
                <button
                  onClick={handleExportMarkdown}
                  title="Copy as Markdown"
                  style={{
                    background: "var(--os-surface)",
                    border: "1px solid var(--os-line)",
                    borderRadius: 6,
                    padding: "5px 10px",
                    cursor: "pointer",
                    display: "flex",
                    alignItems: "center",
                    gap: 5,
                    fontSize: 12,
                    color: "var(--os-ink)"
                  }}
                >
                  <Copy size={13} /> Copy Markdown
                </button>
                <button
                  disabled={isActive || isProcessing}
                  onClick={() => setPendingDelete(selectedRecord.id)}
                  title="Delete meeting"
                  style={{
                    background: "transparent",
                    border: "1px solid var(--os-line)",
                    borderRadius: 6,
                    padding: "5px 8px",
                    cursor: "pointer",
                    color: "color-mix(in srgb, var(--os-recording) 72%, var(--os-ink))"
                  }}
                >
                  <Trash2 size={13} />
                </button>
              </div>
            </div>

            {/* State Strip / Banners */}
            <div className="meeting-banners" style={{ padding: "12px 28px 0" }}>
              {isActive && (
                <div
                  style={{
                    display: "flex",
                    alignItems: "center",
                    justifyContent: "space-between",
                    background: "var(--os-recording-soft)",
                    border: "1px solid var(--os-line)",
                    borderRadius: 10,
                    padding: "10px 14px",
                    marginBottom: 12
                  }}
                >
                  <div style={{ display: "flex", alignItems: "center", gap: 10 }}>
                    <span
                      style={{
                        width: 9,
                        height: 9,
                        borderRadius: "50%",
                        background: selectedRecord.status === "paused" ? "var(--os-warning)" : "var(--os-recording)"
                      }}
                    />
                    <div>
                      <strong style={{ fontSize: 13, color: "var(--os-ink)" }}>
                        {selectedRecord.status === "paused" ? "Meeting Paused" : "Meeting Recording Active"}
                      </strong>
                      <span style={{ fontSize: 11.5, color: "var(--os-ink-muted)", display: "block" }}>
                        {formatDuration(selectedRecord.duration)} · {selectedRecord.liveTranscription ? "Live transcript · saved audio sections" : "Transcription on stop"}
                      </span>
                    </div>
                  </div>
                  <meter min={0} max={1} value={selectedRecord.status === "paused" ? 0 : level} aria-label="Meeting audio level" style={{ width: 90 }} />

                  <div style={{ display: "flex", gap: 8 }}>
                    <button
                      onClick={handlePauseResume}
                      style={{
                        background: "var(--os-surface)",
                        border: "1px solid var(--os-line)",
                        borderRadius: 6,
                        padding: "5px 12px",
                        fontSize: 12,
                        cursor: "pointer",
                        display: "flex",
                        alignItems: "center",
                        gap: 4
                      }}
                    >
                      {selectedRecord.status === "paused" ? <Play size={12} /> : <Pause size={12} />}
                      {selectedRecord.status === "paused" ? "Resume" : "Pause"}
                    </button>
                    <button
                      onClick={handleFinish}
                      style={{
                        background: "color-mix(in srgb, var(--os-recording) 78%, var(--os-ink))",
                        color: "var(--os-primary-text)",
                        border: "none",
                        borderRadius: 6,
                        padding: "5px 14px",
                        fontSize: 12,
                        fontWeight: 600,
                        cursor: "pointer",
                        display: "flex",
                        alignItems: "center",
                        gap: 4
                      }}
                    >
                      <Square size={10} fill="var(--os-primary-text)" /> Stop & save
                    </button>
                  </div>
                </div>
              )}
              {(isActive || isProcessing) && <p role="status">{liveProgress[selectedRecord.id] || (isProcessing ? selectedRecord.status === "summarizing" ? "Creating summary…" : "Transcribing saved audio…" : "")}</p>}
              {isActive && selectedRecord.lastError && <div role="alert"><p>{selectedRecord.lastError}</p><button onClick={() => run(retryLiveTranscription())}>Retry live transcript</button></div>}
              {saveStatus && <p role="status">{saveStatus} {drafts[selectedRecord.id] && <button onClick={() => { editRecord(selectedRecord); flushEdits(); }}>Retry save</button>}</p>}
              {audioSegmentId && <SegmentAudio key={`${selectedRecord.id}/${audioSegmentId}`} record={selectedRecord} segmentId={audioSegmentId} />}

              {/* Short Meeting Confirmation Prompt */}
              {selectedRecord.summaryNeedsConfirmation && (
                <div
                  style={{
                    background: "var(--os-warning-soft)",
                    border: "1px solid var(--os-line)",
                    borderRadius: 10,
                    padding: "12px 16px",
                    display: "flex",
                    alignItems: "center",
                    justifyContent: "space-between",
                    marginBottom: 12
                  }}
                >
                  <div>
                    <strong style={{ fontSize: 13, color: "var(--os-ink)" }}>
                      Very short meeting
                    </strong>
                    <span style={{ fontSize: 12, color: "var(--os-ink)", display: "block" }}>
                      Only {selectedRecord.segments.map(segment => segment.text).join(" ").split(/\s+/).filter(Boolean).length} words were transcribed, so it wasn’t summarized automatically. Was it started by mistake?
                    </span>
                  </div>

                  <div style={{ display: "flex", gap: 8 }}>
                    <button
                      disabled={isActive || isProcessing}
                      onClick={async () => {
                        try { await summarizeShortMeeting(selectedRecord.id); onUpdateMeetings([]); }
                        catch (error) { reportUiError(error); }
                      }}
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
                      Summarize anyway
                    </button>
                    <button
                      disabled={isActive || isProcessing}
                      onClick={async () => {
                        try { await skipSummary(selectedRecord.id); onUpdateMeetings([]); }
                        catch (error) { reportUiError(error); }
                      }}
                      style={{
                        background: "var(--os-surface)",
                        border: "1px solid var(--os-warning)",
                        color: "var(--os-ink)",
                        borderRadius: 6,
                        padding: "5px 12px",
                        fontSize: 12,
                        fontWeight: 500,
                        cursor: "pointer"
                      }}
                    >
                      Keep transcript only
                    </button>
                    <button
                      onClick={() => setPendingDelete(selectedRecord.id)}
                      style={{
                        background: "transparent",
                        border: "none",
                        color: "color-mix(in srgb, var(--os-recording) 72%, var(--os-ink))",
                        fontSize: 12,
                        cursor: "pointer"
                      }}
                    >
                      Delete
                    </button>
                  </div>
                </div>
              )}

              {/* Error Banner */}
              {selectedRecord.lastError && !isActive && (
                <div
                  style={{
                    background: "var(--os-recording-soft)",
                    border: "1px solid var(--os-line)",
                    borderRadius: 10,
                    padding: "10px 14px",
                    marginBottom: 12,
                    display: "flex",
                    alignItems: "center",
                    justifyContent: "space-between"
                  }}
                >
                  <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
                    <AlertCircle size={16} color="var(--os-recording)" />
                    <span style={{ fontSize: 12.5, color: "var(--os-ink)" }}>
                      {selectedRecord.lastError}
                    </span>
                  </div>
                  <div style={{ display: "flex", gap: 8 }}>
                    <button
                      onClick={() => run(processMeeting(selectedRecord.id))}
                      style={{
                        background: "color-mix(in srgb, var(--os-recording) 78%, var(--os-ink))",
                        color: "var(--os-primary-text)",
                        border: "none",
                        borderRadius: 6,
                        padding: "4px 10px",
                        fontSize: 11.5,
                        fontWeight: 500,
                        cursor: "pointer"
                      }}
                    >
                      Try again
                    </button>
                  </div>
                </div>
              )}

              {selectedRecord.recoveryNotice && <p role="status" style={{ margin: 12, padding: 12, color: "var(--os-ink)", background: "var(--os-warning-soft)" }}>{selectedRecord.recoveryNotice}</p>}
              {recoverableMeetings.length > 0 && <div className="workspace-banner" role="status" style={{ padding: 12, background: "var(--os-warning-soft)" }}>
                {recoverableMeetings.length} meetings need attention. <button className="quiet" onClick={() => setConfirmDiscardAll(true)}>Discard all</button>
              </div>}
              {confirmDiscardAll && <ConfirmDialog title="Discard failed meetings?" confirmLabel="Discard all" onCancel={() => setConfirmDiscardAll(false)} onConfirm={() => {
                setConfirmDiscardAll(false);
                run((async () => { try { for (const record of recoverableMeetings) await deleteMeeting(record.id); } finally { onUpdateMeetings([]); } })());
              }}>Failed and interrupted meetings and their recordings will be permanently deleted.</ConfirmDialog>}
              {(selectedRecord.status === "transcribing" || selectedRecord.status === "summarizing") && <button className="quiet" onClick={() => run(cancelProcessing())}>Cancel processing</button>}
            </div>

            {/* Tabs */}
            <div
              className="meeting-tabs"
              style={{
                display: "flex",
                gap: 20,
                padding: "8px 28px",
                borderBottom: "1px solid var(--os-line)",
                fontSize: 13,
                fontWeight: 500
              }}
            >
              <button
                onClick={() => setTab("notes")}
                style={{
                  background: "transparent",
                  border: "none",
                  borderBottom: tab === "notes" ? "2px solid var(--os-accent)" : "2px solid transparent",
                  color: tab === "notes" ? "color-mix(in srgb, var(--os-accent) 90%, var(--os-ink))" : "var(--os-ink-muted)",
                  padding: "6px 2px",
                  cursor: "pointer",
                  fontWeight: tab === "notes" ? 600 : 500
                }}
              >
                My notes
              </button>
              <button
                onClick={() => setTab("summary")}
                style={{
                  background: "transparent",
                  border: "none",
                  borderBottom: tab === "summary" ? "2px solid var(--os-accent)" : "2px solid transparent",
                  color: tab === "summary" ? "color-mix(in srgb, var(--os-accent) 90%, var(--os-ink))" : "var(--os-ink-muted)",
                  padding: "6px 2px",
                  cursor: "pointer",
                  fontWeight: tab === "summary" ? 600 : 500
                }}
              >
                Summary
              </button>
              <button
                onClick={() => setTab("transcript")}
                style={{
                  background: "transparent",
                  border: "none",
                  borderBottom: tab === "transcript" ? "2px solid var(--os-accent)" : "2px solid transparent",
                  color: tab === "transcript" ? "color-mix(in srgb, var(--os-accent) 90%, var(--os-ink))" : "var(--os-ink-muted)",
                  padding: "6px 2px",
                  cursor: "pointer",
                  fontWeight: tab === "transcript" ? 600 : 500
                }}
              >
                Transcript ({selectedRecord.segments.length})
              </button>

            </div>

            {/* Tab Contents */}
            <div style={{ flex: 1, minWidth: 0, minHeight: 0, overflowY: "auto", padding: "20px 28px" }}>
              {tab === "summary" && (
                <div>
                  {selectedRecord.summary ? (
                    <div style={{ display: "flex", flexDirection: "column", gap: 24 }}>
                      {/* Overview / Key points */}
                      <div>
                        <h3 style={{ fontSize: 11, fontWeight: 700, letterSpacing: "0.08em", color: "var(--os-ink-muted)", textTransform: "uppercase", margin: "0 0 10px" }}>
                          Key Points
                        </h3>
                        <div style={{ display: "flex", flexDirection: "column", gap: 10 }}>
                          {selectedRecord.summary.overview.map((pt, i) => (
                            <div key={i} style={{ display: "flex", gap: 10, alignItems: "flex-start" }}>
                              <span style={{ width: 6, height: 6, borderRadius: "50%", background: "var(--os-accent)", marginTop: 7, flexShrink: 0 }} />
                              <div style={{ flex: 1 }}>
                                <p style={{ margin: "0 0 4px", fontSize: 14, lineHeight: 1.5 }}>
                                  {pt.text}
                                </p>
                                <div style={{ display: "flex", gap: 4, flexWrap: "wrap" }}>
                                  {mapCitations(pt.sources, selectedRecord, passages).map((cite) => (
                                    <button
                                      key={cite.sourceId}
                                      onClick={() => jumpToCitation(cite.sourceId)}
                                      style={{
                                        background: "var(--os-accent-soft)",
                                        color: "color-mix(in srgb, var(--os-accent) 90%, var(--os-ink))",
                                        border: "none",
                                        borderRadius: 4,
                                        padding: "1px 6px",
                                        fontSize: 11,
                                        fontFamily: "monospace",
                                        cursor: "pointer"
                                      }}
                                    >
                                      {cite.timestamp}
                                    </button>
                                  ))}
                                </div>
                              </div>
                            </div>
                          ))}
                        </div>
                      </div>

                      {/* Decisions */}
                      <div>
                        <h3 style={{ fontSize: 11, fontWeight: 700, letterSpacing: "0.08em", color: "var(--os-ink-muted)", textTransform: "uppercase", margin: "0 0 10px" }}>
                          Decisions
                        </h3>
                        <div style={{ display: "flex", flexDirection: "column", gap: 10 }}>
                          {selectedRecord.summary.decisions.length === 0 ? (
                            <span style={{ fontSize: 13, color: "var(--os-ink-muted)", fontStyle: "italic" }}>None identified.</span>
                          ) : (
                            selectedRecord.summary.decisions.map((pt, i) => (
                              <div key={i} style={{ display: "flex", gap: 10, alignItems: "flex-start" }}>
                                <span style={{ width: 6, height: 6, borderRadius: "50%", background: "var(--os-success)", marginTop: 7, flexShrink: 0 }} />
                                <div style={{ flex: 1 }}>
                                  <p style={{ margin: "0 0 4px", fontSize: 14, lineHeight: 1.5 }}>
                                    {pt.text}
                                  </p>
                                  <div style={{ display: "flex", gap: 4 }}>
                                    {mapCitations(pt.sources, selectedRecord, passages).map((cite) => (
                                      <button
                                        key={cite.sourceId}
                                        onClick={() => jumpToCitation(cite.sourceId)}
                                        style={{
                                          background: "var(--os-success-soft)",
                                          color: "color-mix(in srgb, var(--os-success) 60%, var(--os-ink))",
                                          border: "none",
                                          borderRadius: 4,
                                          padding: "1px 6px",
                                          fontSize: 11,
                                          fontFamily: "monospace",
                                          cursor: "pointer"
                                        }}
                                      >
                                        {cite.timestamp}
                                      </button>
                                    ))}
                                  </div>
                                </div>
                              </div>
                            ))
                          )}
                        </div>
                      </div>

                      {/* Action items */}
                      <div>
                        <h3 style={{ fontSize: 11, fontWeight: 700, letterSpacing: "0.08em", color: "var(--os-ink-muted)", textTransform: "uppercase", margin: "0 0 10px" }}>
                          Action Items
                        </h3>
                        <div style={{ display: "flex", flexDirection: "column", gap: 10 }}>
                          {selectedRecord.summary.actions.length === 0 ? (
                            <span style={{ fontSize: 13, color: "var(--os-ink-muted)", fontStyle: "italic" }}>None identified.</span>
                          ) : (
                            selectedRecord.summary.actions.map((pt, i) => (
                              <div key={i} style={{ display: "flex", gap: 10, alignItems: "flex-start" }}>
                                <input type="checkbox" style={{ marginTop: 4 }} />
                                <div style={{ flex: 1 }}>
                                  <p style={{ margin: "0 0 4px", fontSize: 14, lineHeight: 1.5 }}>
                                    {pt.text}
                                  </p>
                                  <div style={{ display: "flex", gap: 4 }}>
                                    {mapCitations(pt.sources, selectedRecord, passages).map((cite) => (
                                      <button
                                        key={cite.sourceId}
                                        onClick={() => jumpToCitation(cite.sourceId)}
                                        style={{
                                          background: "var(--os-accent-soft)",
                                          color: "color-mix(in srgb, var(--os-accent) 90%, var(--os-ink))",
                                          border: "none",
                                          borderRadius: 4,
                                          padding: "1px 6px",
                                          fontSize: 11,
                                          fontFamily: "monospace",
                                          cursor: "pointer"
                                        }}
                                      >
                                        {cite.timestamp}
                                      </button>
                                    ))}
                                  </div>
                                </div>
                              </div>
                            ))
                          )}
                        </div>
                      </div>
                    </div>
                  ) : (
                    <div style={{ textAlign: "center", padding: "40px 20px", color: "var(--os-ink-muted)" }}>
                      <Sparkles size={32} color="var(--os-accent)" style={{ marginBottom: 12 }} />
                      <h3 style={{ fontSize: 16, margin: "0 0 6px" }}>No summary yet</h3>
                      <p style={{ fontSize: 13, maxWidth: 360, margin: "0 auto 16px" }}>
                        {selectedRecord.segments.length === 0
                          ? "This meeting has not been transcribed yet."
                          : "Transcribe and summarize to extract key points and action items."}
                      </p>
                      <button
                        disabled={isActive || isProcessing}
                        onClick={() => run(processMeeting(selectedRecord.id))}
                        style={{
                          background: "var(--os-accent)",
                          color: "var(--os-primary-text)",
                          border: "none",
                          borderRadius: 6,
                          padding: "6px 16px",
                          fontSize: 13,
                          fontWeight: 600,
                          cursor: "pointer"
                        }}
                      >
                        {isProcessing ? "Processing…" : isActive ? "Recording in progress" : "Create summary"}
                      </button>
                    </div>
                  )}
                </div>
              )}

              {tab === "transcript" && (
                <div>
                  {/* Search and Track Filter Bar */}
                  <div style={{ display: "flex", flexWrap: "wrap", gap: 12, marginBottom: 16 }}>
                    <input
                      type="text"
                      value={transcriptSearch}
                      onChange={(e) => setTranscriptSearch(e.target.value)}
                      placeholder="Search this transcript"
                      style={{
                        flex: 1, minWidth: 0, minHeight: 0,
                        padding: "6px 12px",
                        borderRadius: 6,
                        border: "1px solid var(--os-line)",
                        fontSize: 13
                      }}
                    />
                    <select
                      value={trackFilter}
                      onChange={(e) => setTrackFilter(e.target.value as "all" | "microphone" | "system")}
                      style={{
                        padding: "6px 10px",
                        borderRadius: 6,
                        border: "1px solid var(--os-line)",
                        fontSize: 12.5,
                        background: "var(--os-surface)"
                      }}
                    >
                      <option value="all">All audio</option>
                      <option value="microphone">{selectedRecord.microphoneLabel || "Microphone"}</option>
                      <option value="system">{selectedRecord.systemLabel || "System audio"}</option>
                    </select>
                  </div>

                  {/* Passages List */}
                  <div style={{ display: "flex", flexDirection: "column", gap: 16 }}>
                    {passages.length === 0 ? (
                      <p style={{ color: "var(--os-ink-muted)", fontSize: 13.5, fontStyle: "italic" }}>
                        {isActive ? selectedRecord.liveTranscription ? "Text appears here as each saved section of audio is ready." : "The transcript is created when you stop." : "No transcript passages available."}
                      </p>
                    ) : (
                      passages.map((p) => {
                        const isMic = p.track === "microphone";
                        const isHighlighted = p.segmentIDs.includes(highlightedSegmentId ?? "");
                        return (
                          <div
                            key={p.id}
                            ref={isHighlighted ? citationTarget : undefined}
                            style={{
                              display: "flex",
                              flexDirection: "column",
                              gap: 4,
                              background: isHighlighted ? "var(--os-warning-soft)" : "transparent",
                              padding: isHighlighted ? "6px 8px" : "0",
                              borderRadius: 6,
                              transition: "background 0.3s ease"
                            }}
                          >
                            <div style={{ display: "flex", alignItems: "center", gap: 6 }}>
                              <span
                                style={{
                                  fontSize: 11,
                                  fontWeight: 600,
                                  color: isMic ? "color-mix(in srgb, var(--os-accent) 90%, var(--os-ink))" : "color-mix(in srgb, var(--os-success) 60%, var(--os-ink))"
                                }}
                              >
                                {isMic
                                  ? selectedRecord.microphoneLabel ?? "Microphone"
                                  : selectedRecord.systemLabel ?? "System audio"}
                              </span>
                              <span style={{ fontSize: 11, fontFamily: "monospace", color: "var(--os-ink-muted)" }}>
                                {formatTimestamp(p.start)}
                              </span>
                              <button aria-label={`Play passage at ${formatTimestamp(p.start)}`} onClick={() => setAudioSegmentId(p.segmentIDs[0])}><Play size={12} /> Play</button>
                            </div>
                            <p style={{ margin: 0, fontSize: 14, lineHeight: 1.55 }}>
                              {p.text}
                            </p>
                          </div>
                        );
                      })
                    )}
                  </div>
                </div>
              )}

              {tab === "notes" && (
                <textarea
                  value={selectedRecord.userNotes ?? ""}
                  onChange={(e) => {
                    const updated = { ...selectedRecord, userNotes: e.target.value };
                    editRecord(updated);
                  }}
                  placeholder="Jot down notes about this meeting…"
                  style={{
                    width: "100%",
                    height: "100%",
                    minHeight: 300,
                    border: "none",
                    outline: "none",
                    background: "transparent",
                    resize: "none",
                    fontSize: 14.5,
                    lineHeight: 1.6,
                    fontFamily: "inherit"
                  }}
                />
              )}
            </div>
          </>
        ) : (
          <div style={{ display: "flex", alignItems: "center", justifyContent: "center", height: "100%", color: "var(--os-ink-muted)" }}>
            Select a meeting or start a new recording
          </div>
        )}
      </div>
    </div>
  );
};
