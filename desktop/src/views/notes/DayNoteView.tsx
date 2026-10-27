import React, { useEffect, useMemo, useState } from "react";
import { convertFileSrc } from "@tauri-apps/api/core";
import {
  Calendar as CalendarIcon,
  Camera,
  Check,
  ChevronDown,
  ChevronRight,
  Clock,
  Copy,
  ExternalLink,
  FileText,
  Mic,
  Pin,
  Plus,
  Trash2,
  Users
} from "lucide-react";
import {
  addCapture,
  attachmentPath,
  deleteNote,
  removeCapture,
  saveNote,
  takeScreenshot,
  updateCapture,
  exportMeetingMarkdown
} from "../../api/parity";
import type {
  NoteCapture,
  NoteCaptureKind,
  VoiceNote
} from "../../api/parityTypes";
import { formatDuration } from "../meetings/transcriptHelpers";
import { reportUiError, sendIntent } from "../../workspaceEvents";
import { dayMarkdown as markdownForDay } from "./dayMarkdown";
import { captureDateForDay, isSyntheticDayId } from "./dayNoteHelpers";
import { exportText } from "./exportText";
import { EntryTextEditor } from "./EntryTextEditor";
import { MeetingEntryCard } from "./MeetingEntryCard";
import { LibraryContextMenu } from "./LibraryContextMenu";
import { ConfirmDialog } from "../ConfirmDialog";
import { openPath, revealItemInDir } from "@tauri-apps/plugin-opener";
import { writeImage } from "@tauri-apps/plugin-clipboard-manager";

interface DayNoteViewProps {
  note: VoiceNote;
  isToday: boolean;
  onUpdate: (updated: VoiceNote) => Promise<void>;
  onRefresh: () => Promise<void>;
  onDeleteNote: (id: string) => void;
  onOpenMeeting?: (meetingId: string) => void;
  onStartDictation?: () => void;
  onStartMeeting?: () => void;
}

export const DayNoteView: React.FC<DayNoteViewProps> = ({
  note,
  isToday,
  onUpdate,
  onRefresh,
  onDeleteNote,
  onOpenMeeting,
  onStartDictation,
  onStartMeeting
}) => {
  const [composer, setComposer] = useState("");
  const [screenshotUrls, setScreenshotUrls] = useState<Record<string, string>>({});
  const [expandedOcr, setExpandedOcr] = useState<Record<string, boolean>>({});
  const [showOriginal, setShowOriginal] = useState<Record<string, boolean>>({});
  const [screenshotDropdown, setScreenshotDropdown] = useState(false);

  const [adding, setAdding] = useState(false);
  const [pendingDelete, setPendingDelete] = useState<string | null>(null);
  const [attachmentErrors, setAttachmentErrors] = useState<Record<string, boolean>>({});
  const captures = useMemo(() => (note.captures ?? []).filter(capture => !capture.superseded), [note.captures]);
  const syntheticDay = isSyntheticDayId(note.id);

  useEffect(() => {
    // Resolve attachment paths
    captures.forEach((c) => {
      if (c.attachment && !screenshotUrls[c.attachment]) {
        attachmentPath(c.attachment)
          .then((p) => {
            setScreenshotUrls((prev) => ({
              ...prev,
              [c.attachment!]: convertFileSrc(p)
            }));
          })
          .catch(() => setAttachmentErrors(previous => ({ ...previous, [c.attachment!]: true })));
      }
    });
  }, [captures]);

  const handleAddThought = async (e: React.FormEvent) => {
    e.preventDefault();
    const text = composer.trim();
    if (!text || adding) return;
    setAdding(true);

    const newCapture: NoteCapture = {
      id: crypto.randomUUID().toUpperCase(),
      createdAt: captureDateForDay(note.createdAt),
      title: "Written note",
      rawText: text,
      text: text,
      duration: 0,
      kind: "text"
    };

    try {
      await addCapture(newCapture);
      await onRefresh();
      setComposer("");
    } catch (error) {
      reportUiError(error);
    } finally { setAdding(false); }
  };

  const handleTakeScreenshot = async (kind: "area" | "window" | "screen") => {
    setScreenshotDropdown(false);
    try {
      await sendIntent({ action: "screenshot", kind });
    } catch (err) {
      reportUiError(err);
    }
  };

  const handleDeleteEntry = async (captureId: string) => {
    try {
      await removeCapture(captureId, note.id);
      await onRefresh();
    } catch (error) {
      reportUiError(error);
    }
  };

  const handleTogglePin = async () => {
    if (syntheticDay) return;
    const updated = { ...note, isPinned: !note.isPinned };
    try { await onUpdate(updated); } catch (error) { reportUiError(error); }
  };

  const dayMarkdown = () => markdownForDay(note);
  const handleCopyMarkdown = () => { void navigator.clipboard.writeText(dayMarkdown()).catch(reportUiError); };
  const imageAction = async (entry: NoteCapture, action: "open" | "reveal" | "copy") => {
    try {
      if (!entry.attachment) throw new Error("This screenshot has no saved image attachment.");
      const path = await attachmentPath(entry.attachment);
      if (action === "open") await openPath(path);
      else if (action === "reveal") await revealItemInDir(path);
      else await writeImage(path);
    } catch (error) { reportUiError(error); }
  };
  const copyEntry = async (entry: NoteCapture, original: boolean) => {
    try {
      if (entry.kind === "screenshot") { await imageAction(entry, "copy"); return; }
      const text = entry.kind === "meeting" && entry.meetingID ? await exportMeetingMarkdown(entry.meetingID) : original ? entry.rawText : entry.text;
      await navigator.clipboard.writeText(text);
    } catch (error) { reportUiError(error); }
  };

  const dateObj = new Date(note.createdAt);
  const formattedDate = dateObj.toLocaleDateString(undefined, {
    weekday: "long",
    month: "long",
    day: "numeric"
  });

  const dictationCount = captures.filter((c) => c.kind === "dictation").length;
  const screenshotCount = captures.filter((c) => c.kind === "screenshot").length;
  const meetingCount = captures.filter((c) => c.kind === "meeting").length;
  const textCount = captures.filter(c => c.kind === "text").length;

  return (
    <div className="day-note" style={{ display: "flex", flexDirection: "column", height: "100%", overflowY: "auto", padding: "28px 36px" }}>
      {pendingDelete && <ConfirmDialog title="Delete this entry?" confirmLabel="Delete" onCancel={() => setPendingDelete(null)} onConfirm={() => { const id = pendingDelete; setPendingDelete(null); void handleDeleteEntry(id); }}>This cannot be undone. Linked meetings are kept in Meetings.</ConfirmDialog>}
      {/* Top Toolbar */}
      <div className="ui-toolbar" style={{ display: "flex", alignItems: "center", justifyContent: "space-between", marginBottom: 20 }}>
        <div style={{ fontSize: 12, color: "var(--os-ink-muted)" }}>
          {[
            textCount ? `${textCount} written entr${textCount === 1 ? "y" : "ies"}` : null,
            dictationCount ? `${dictationCount} dictation${dictationCount > 1 ? "s" : ""}` : null,
            screenshotCount ? `${screenshotCount} screenshot${screenshotCount > 1 ? "s" : ""}` : null,
            meetingCount ? `${meetingCount} meeting${meetingCount > 1 ? "s" : ""}` : null
          ].filter(Boolean).join(" · ") || "Empty day"}
        </div>

        <div style={{ display: "flex", gap: 8 }}>
          <button onClick={() => { void exportText(dayMarkdown(), formattedDate, "md").catch(reportUiError); }}>Export as Markdown…</button>
          <button
            disabled={syntheticDay}
            onClick={handleTogglePin}
            title={note.isPinned ? "Unpin day" : "Pin day"}
            style={{
              background: "transparent",
              border: "1px solid var(--os-line)",
              borderRadius: 6,
              padding: "5px 8px",
              cursor: "pointer",
              color: note.isPinned ? "color-mix(in srgb, var(--os-accent) 90%, var(--os-ink))" : "var(--os-ink-muted)",
              display: "flex",
              alignItems: "center"
            }}
          >
            <Pin size={14} fill={note.isPinned ? "var(--os-accent)" : "none"} />
          </button>
          <button
            onClick={handleCopyMarkdown}
            title="Copy day as Markdown"
            style={{
              background: "transparent",
              border: "1px solid var(--os-line)",
              borderRadius: 6,
              padding: "5px 8px",
              cursor: "pointer",
              color: "var(--os-ink-muted)",
              display: "flex",
              alignItems: "center",
              gap: 4,
              fontSize: 12
            }}
          >
            <Copy size={13} /> Copy
          </button>
          <button
            disabled={syntheticDay}
            onClick={() => { if (!syntheticDay) onDeleteNote(note.id); }}
            title="Delete this day"
            style={{
              background: "transparent",
              border: "1px solid var(--os-line)",
              borderRadius: 6,
              padding: "5px 8px",
              cursor: "pointer",
              color: "color-mix(in srgb, var(--os-recording) 72%, var(--os-ink))",
              display: "flex",
              alignItems: "center"
            }}
          >
            <Trash2 size={13} />
          </button>
        </div>
      </div>

      {/* Date Header */}
      <div style={{ marginBottom: 24 }}>
        <div style={{ fontSize: 11, fontWeight: 700, letterSpacing: "0.08em", color: "color-mix(in srgb, var(--os-accent) 90%, var(--os-ink))", textTransform: "uppercase" }}>
          {isToday ? "TODAY" : dateObj.getFullYear()}
        </div>
        <h1 style={{ fontSize: 28, fontWeight: 700, margin: "4px 0 0", letterSpacing: "-0.03em" }}>
          {formattedDate}
        </h1>
      </div>

      {/* Quick Action Bar (if today) */}
      {isToday && (
        <div style={{ display: "flex", flexWrap: "wrap", gap: 10, marginBottom: 28, position: "relative" }}>
          <button
            onClick={onStartDictation}
            style={{
              display: "flex",
              alignItems: "center",
              gap: 6,
              background: "var(--os-surface)",
              border: "1px solid var(--os-line)",
              borderRadius: 8,
              padding: "6px 14px",
              fontSize: 13,
              fontWeight: 500,
              cursor: "pointer",
              boxShadow: "var(--os-shadow)"
            }}
          >
            <Mic size={14} color="var(--os-accent)" /> Dictate
          </button>

          <button
            onClick={onStartMeeting}
            style={{
              display: "flex",
              alignItems: "center",
              gap: 6,
              background: "var(--os-surface)",
              border: "1px solid var(--os-line)",
              borderRadius: 8,
              padding: "6px 14px",
              fontSize: 13,
              fontWeight: 500,
              cursor: "pointer",
              boxShadow: "var(--os-shadow)"
            }}
          >
            <Users size={14} color="var(--os-recording)" /> Meeting
          </button>

          <div style={{ position: "relative", display: "flex" }} onBlur={event => { if (!event.currentTarget.contains(event.relatedTarget)) setScreenshotDropdown(false); }} onKeyDown={event => { if (event.key === "Escape") { event.stopPropagation(); setScreenshotDropdown(false); } }}>
            <button onClick={() => { void handleTakeScreenshot("area"); }} style={{ padding: "6px 14px", border: "1px solid var(--os-line)", background: "var(--os-surface)", color: "var(--os-ink)", borderRadius: 8 }}>Screenshot</button>
            <button
              aria-expanded={screenshotDropdown}
              onClick={() => setScreenshotDropdown((prev) => !prev)}
              style={{
                display: "flex",
                alignItems: "center",
                gap: 6,
                background: "var(--os-surface)",
                border: "1px solid var(--os-line)",
                borderRadius: 8,
                padding: "6px 14px",
                fontSize: 13,
                fontWeight: 500,
                cursor: "pointer",
                boxShadow: "var(--os-shadow)"
              }}
            >
              <ChevronDown size={12} aria-label="Screenshot options" />
            </button>

            {screenshotDropdown && (
              <div
                className="capture-menu"
                style={{
                  position: "absolute",
                  top: 36,
                  left: 0,
                  background: "var(--os-surface)",
                  border: "1px solid var(--os-line)",
                  borderRadius: 8,
                  padding: 4,
                  display: "flex",
                  flexDirection: "column",
                  gap: 2,
                  width: 160,
                  zIndex: 50,
                  boxShadow: "var(--os-shadow)"
                }}
              >
                <button
                  onClick={() => handleTakeScreenshot("area")}
                  style={{
                    background: "transparent",
                    border: "none",
                    padding: "6px 10px",
                    textAlign: "left",
                    fontSize: 12,
                    cursor: "pointer",
                    borderRadius: 4
                  }}
                >
                  Area screenshot
                </button>
                <button
                  onClick={() => handleTakeScreenshot("window")}
                  style={{
                    background: "transparent",
                    border: "none",
                    padding: "6px 10px",
                    textAlign: "left",
                    fontSize: 12,
                    cursor: "pointer",
                    borderRadius: 4
                  }}
                >
                  Window screenshot
                </button>
                <button
                  onClick={() => handleTakeScreenshot("screen")}
                  style={{
                    background: "transparent",
                    border: "none",
                    padding: "6px 10px",
                    textAlign: "left",
                    fontSize: 12,
                    cursor: "pointer",
                    borderRadius: 4
                  }}
                >
                  Screen screenshot
                </button>
              </div>
            )}
          </div>
        </div>
      )}

      {/* Timeline Entries */}
      <div style={{ display: "flex", flexDirection: "column", gap: 20, marginBottom: 30 }}>
        {captures.length === 0 ? (
          <div style={{ color: "var(--os-ink-muted)", fontSize: 13.5, fontStyle: "italic", padding: "12px 0" }}>
            {isToday
              ? "Your day starts here. Dictations, screenshots, and meetings land here as they happen."
              : "Nothing was captured this day."}
          </div>
        ) : (
          captures.map((entry, index) => {
            const timeStr = new Date(entry.createdAt).toLocaleTimeString([], {
              hour: "2-digit",
              minute: "2-digit"
            });
            const hasRawDiff = entry.rawText && entry.rawText !== entry.text;
            const showingRaw = showOriginal[entry.id];

            return (
              <LibraryContextMenu key={entry.id} actions={[
                { label: "Copy", run: () => { void copyEntry(entry, !!showingRaw); } },
                ...(entry.kind === "screenshot" ? [
                  { label: "Open in image viewer", run: () => { void imageAction(entry, "open"); } },
                  { label: "Show in Explorer", run: () => { void imageAction(entry, "reveal"); } },
                  { label: "Copy text in image", disabled: !entry.recognizedText, run: () => { void navigator.clipboard.writeText(entry.recognizedText ?? "").catch(reportUiError); } }
                ] : []),
                ...(entry.meetingID ? [{ label: "Open meeting", run: () => onOpenMeeting?.(entry.meetingID!) }] : []),
                { label: "Delete entry…", run: () => setPendingDelete(entry.id) }
              ]}>
              <div
                style={{
                  display: "flex",
                  gap: 16,
                  alignItems: "flex-start",
                  position: "relative"
                }}
              >
                {/* Time column */}
                <div
                  style={{
                    width: 52, flexShrink: 0,
                    textAlign: "right",
                    fontSize: 11,
                    fontFamily: "monospace",
                    color: "var(--os-ink-muted)",
                    paddingTop: 3
                  }}
                >
                  {timeStr}
                </div>

                {/* Bullet Icon */}
                <div
                  style={{
                    width: 24,
                    height: 24,
                    borderRadius: "50%",
                    background:
                      entry.kind === "meeting"
                        ? "var(--os-recording-soft)"
                        : "var(--os-accent-soft)",
                    color: entry.kind === "meeting" ? "color-mix(in srgb, var(--os-recording) 72%, var(--os-ink))" : "color-mix(in srgb, var(--os-accent) 90%, var(--os-ink))",
                    display: "flex",
                    alignItems: "center",
                    justifyContent: "center",
                    flexShrink: 0
                  }}
                >
                  {entry.kind === "dictation" && <Mic size={12} />}
                  {entry.kind === "screenshot" && <Camera size={12} />}
                  {entry.kind === "meeting" && <Users size={12} />}
                  {entry.kind === "text" && <FileText size={12} />}
                </div>

                {/* Entry Content */}
                <div className="timeline-content" style={{ flex: 1, minWidth: 0, minHeight: 0, display: "flex", flexDirection: "column", gap: 6 }}>
                  {entry.kind === "screenshot" ? (
                    <div>
                      {entry.attachment && screenshotUrls[entry.attachment] && !attachmentErrors[entry.attachment] && (
                        <img
                          className="timeline-image"
                          onDoubleClick={() => { void imageAction(entry, "open"); }}
                          onError={() => setAttachmentErrors(previous => ({ ...previous, [entry.attachment!]: true }))}
                          src={screenshotUrls[entry.attachment]}
                          alt="Screenshot capture"
                          style={{
                            maxWidth: 360,
                            maxHeight: 220,
                            borderRadius: 8,
                            border: "1px solid var(--os-line)",
                            display: "block",
                            marginBottom: 6
                          }}
                        />
                      )}
                      {(!entry.attachment || attachmentErrors[entry.attachment]) && <p role="status">Screenshot image unavailable.{entry.recognizedText ? " Saved image text is still available below." : ""}</p>}
                      {entry.recognizedText && (
                        <div style={{ marginTop: 4 }}>
                          <button
                            onClick={() =>
                              setExpandedOcr((prev) => ({
                                ...prev,
                                [entry.id]: !prev[entry.id]
                              }))
                            }
                            style={{
                              background: "transparent",
                              border: "none",
                              fontSize: 11.5,
                              color: "color-mix(in srgb, var(--os-accent) 90%, var(--os-ink))",
                              cursor: "pointer",
                              padding: 0,
                              display: "flex",
                              alignItems: "center",
                              gap: 3
                            }}
                          >
                            <ChevronRight
                              size={12}
                              style={{
                                transform: expandedOcr[entry.id] ? "rotate(90deg)" : "none"
                              }}
                            />
                            {expandedOcr[entry.id] ? "Hide image text" : "Searchable text in image"}
                          </button>
                          {expandedOcr[entry.id] && (
                            <p
                              style={{
                                fontSize: 12.5,
                                background: "var(--os-surface-muted)",
                                padding: "8px 10px",
                                borderRadius: 6,
                                marginTop: 4,
                                color: "var(--os-ink-muted)"
                              }}
                            >
                              {entry.recognizedText}
                            </p>
                          )}
                        </div>
                      )}
                    </div>
                  ) : entry.kind === "meeting" ? (
                    <MeetingEntryCard entry={entry} onOpen={onOpenMeeting} />
                  ) : (
                    <div style={{ fontSize: 14.5, lineHeight: 1.6, color: "var(--os-ink)" }}>
                      {showingRaw ? <div style={{ whiteSpace: "pre-wrap" }}>{entry.rawText}</div> : <EntryTextEditor entry={entry} noteId={note.id} onRefresh={onRefresh} />}
                    </div>
                  )}
                  {/* Metadata & Actions */}
                  <div
                    style={{
                      display: "flex",
                      alignItems: "center",
                      gap: 10, flexWrap: "wrap",
                      fontSize: 11,
                      color: "var(--os-ink-muted)"
                    }}
                  >
                    <span>
                      {entry.sourceApplication
                        ? `${entry.sourceApplication} · `
                        : ""}
                      {entry.kind === "dictation" && entry.duration > 0
                        ? formatDuration(entry.duration)
                        : entry.kind}
                    </span>

                    {hasRawDiff && (
                      <button
                        onClick={() =>
                          setShowOriginal((prev) => ({
                            ...prev,
                            [entry.id]: !prev[entry.id]
                          }))
                        }
                        style={{
                          background: "transparent",
                          border: "none",
                          color: "color-mix(in srgb, var(--os-accent) 90%, var(--os-ink))",
                          cursor: "pointer",
                          padding: 0,
                          fontSize: 11
                        }}
                      >
                        {showingRaw ? "Show edited" : "Show original"}
                      </button>
                    )}

                    <button
                      onClick={() => { void copyEntry(entry, !!showingRaw); }}
                      title="Copy text"
                      style={{
                        background: "transparent",
                        border: "none",
                        color: "var(--os-ink-muted)",
                        cursor: "pointer",
                        padding: 0
                      }}
                    >
                      <Copy size={11} />
                    </button>

                    <button
                      onClick={() => setPendingDelete(entry.id)}
                      title="Delete entry"
                      style={{
                        background: "transparent",
                        border: "none",
                        color: "color-mix(in srgb, var(--os-recording) 72%, var(--os-ink))",
                        cursor: "pointer",
                        padding: 0
                      }}
                    >
                      <Trash2 size={11} />
                    </button>
                  </div>
                </div>
              </div>
              </LibraryContextMenu>
            );
          })
        )}
      </div>

      {/* Composer at Bottom */}
      <form onSubmit={handleAddThought} style={{ display: "flex", gap: 10, marginTop: "auto" }}>
        <input
          type="text"
          value={composer}
          onChange={(e) => setComposer(e.target.value)}
          placeholder={isToday ? "Write a thought… (Press Enter to add)" : "Add to this day…"}
          style={{
            flex: 1, minWidth: 0, minHeight: 0,
            padding: "10px 14px",
            borderRadius: 8,
            border: "none",
            background: "transparent",
            fontSize: 14,
            outline: "none"
          }}
        />
        <button
          type="submit"
          disabled={!composer.trim() || adding}
          style={{
            background: "var(--os-accent)",
            color: "var(--os-primary-text)",
            border: "none",
            borderRadius: 8,
            padding: "0 16px",
            fontSize: 13,
            fontWeight: 600,
            cursor: "pointer",
            opacity: composer.trim() ? 1 : 0.5
          }}
        >
          {adding ? "Adding…" : "Add"}
        </button>
      </form>
    </div>
  );
};
