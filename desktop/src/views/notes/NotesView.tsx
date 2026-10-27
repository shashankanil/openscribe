import React, { useEffect, useMemo, useRef, useState } from "react";
import {
  Calendar as CalendarIcon,
  ChevronRight,
  FileText,
  Pin,
  Plus,
  Search,
  Trash2
} from "lucide-react";
import { deleteNote, saveNote } from "../../api/parity";
import type { VoiceNote } from "../../api/parityTypes";
import { DayNoteView } from "./DayNoteView";
import { localDay } from "../../core/dailyNotes";
import { reportUiError } from "../../workspaceEvents";
import { exportText } from "./exportText";
import { TeachCorrection } from "./TeachCorrection";
import { LibraryContextMenu } from "./LibraryContextMenu";
import { editNoteText, noteListing, notePreview, noteText, noteTitle, visibleCaptures } from "./libraryHelpers";
import { ConfirmDialog } from "../ConfirmDialog";
import { isSyntheticDayId, selectedDayNote } from "./dayNoteHelpers";
import { matchNotesShortcut } from '../../core/inAppShortcuts';

interface NotesViewProps {
  notes: VoiceNote[];
  selectedId?: string;
  onSelectNote: (id: string) => void;
  onUpdateNotes: (notes: VoiceNote[]) => void;
  onRefreshNotes: () => Promise<void>;
  onOpenMeeting?: (meetingId: string) => void;
  onStartDictation?: () => void;
  onStartMeeting?: () => void;
  active?: boolean;
}

export const NotesView: React.FC<NotesViewProps> = ({
  notes,
  selectedId,
  onSelectNote,
  onUpdateNotes,
  onRefreshNotes,
  onOpenMeeting,
  onStartDictation,
  onStartMeeting,
  active = true
}) => {
  const [search, setSearch] = useState("");
  const searchInput = useRef<HTMLInputElement>(null);
  const [limit, setLimit] = useState(60);
  const [originalId, setOriginalId] = useState<string | null>(null);
  const [teach, setTeach] = useState(false);
  const [pendingDelete, setPendingDelete] = useState<string | null>(null);
  const [filter, setFilter] = useState<"all" | "daily" | "written">("all");
  const [drafts, setDrafts] = useState<Record<string, VoiceNote>>({});
  const [saveStatuses, setSaveStatuses] = useState<Record<string, string>>({});
  const versions = useRef(new Map<string, number>());
  const setNoteStatus = (id: string, status: string) => setSaveStatuses(current => ({ ...current, [id]: status }));
  const pending = useRef(new Map<string, VoiceNote>());
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const writes = useRef<Promise<unknown>>(Promise.resolve());
  const refresh = useRef(onRefreshNotes); refresh.current = onRefreshNotes;
  const allNotes = [...notes.map(note => drafts[note.id] ?? note), ...Object.values(drafts).filter(note => !notes.some(existing => existing.id === note.id))];
  const flush = () => {
    const edits = [...pending.current.values()].map(note => ({ note, version: versions.current.get(note.id) })); pending.current.clear();
    for (const { note, version } of edits) {
      writes.current = writes.current.catch(() => undefined).then(async () => {
        await saveNote(note);
        await refresh.current();
        if (versions.current.get(note.id) === version) setNoteStatus(note.id, "Saved");
        setDrafts(current => {
          if (current[note.id] !== note) return current;
          const next = { ...current }; delete next[note.id]; return next;
        });
      }).catch(error => { setNoteStatus(note.id, "Could not save. Your draft is still here; edit or retry."); reportUiError(error); });
    }
  };
  useEffect(() => () => { if (timer.current) clearTimeout(timer.current); flush(); }, []);

  const todayStr = localDay(new Date());

  // Find or craft today's note
  const todayNote = useMemo(() => {
    return (
      notes.find((n) => localDay(n.createdAt) === todayStr && n.captures != null) ?? {
        id: "today-placeholder",
        createdAt: new Date().toISOString().replace(/\.\d{3}Z$/, "Z"),
        title: "Today",
        rawText: "",
        cleanedText: "",
        duration: 0,
        isPinned: false,
        tags: [],
        source: "Dictation",
        captures: []
      }
    );
  }, [notes, todayStr]);

  const listing = noteListing(allNotes, { search, filter, todayId: todayNote.id, limit });
  useEffect(() => setLimit(60), [search, filter]);

  const selectedNote = useMemo(() => {
    const dayNote = selectedDayNote(allNotes, selectedId);
    if (dayNote) return dayNote;
    if (!selectedId || selectedId === "today-placeholder" || selectedId === todayNote.id) {
      return todayNote;
    }
    return allNotes.find((n) => n.id === selectedId) ?? todayNote;
  }, [notes, drafts, selectedId, todayNote]);

  const handleUpdateNote = async (updated: VoiceNote) => {
    if (isSyntheticDayId(updated.id)) throw new Error("Add an entry before changing this day's saved note.");
    await saveNote(updated);
    await onRefreshNotes();
  };
  const handleEdit = (updated: VoiceNote) => {
    versions.current.set(updated.id, (versions.current.get(updated.id) ?? 0) + 1);
    setDrafts(current => ({ ...current, [updated.id]: updated }));
    if (!notes.some(note => note.id === updated.id) && !noteText(updated).trim() && (!updated.title.trim() || updated.title === "Untitled note")) {
      pending.current.delete(updated.id); setNoteStatus(updated.id, "Draft · type to save"); return;
    }
    setNoteStatus(updated.id, "Saving…");
    pending.current.set(updated.id, updated);
    if (timer.current) clearTimeout(timer.current);
    timer.current = setTimeout(flush, 400);
  };

  const handleDelete = async (id: string) => {
    if (isSyntheticDayId(id)) return;
    try {
      pending.current.delete(id);
      await writes.current;
      await deleteNote(id);
      pending.current.delete(id);
      setDrafts(current => { const next = { ...current }; delete next[id]; return next; });
      await onRefreshNotes();
      onSelectNote("today-placeholder");
    } catch (error) {
      reportUiError(error);
    }
  };

  const handleCreateWrittenNote = () => {
    const newNote: VoiceNote = {
      id: crypto.randomUUID().toUpperCase(),
      createdAt: new Date().toISOString().replace(/\.\d{3}Z$/, "Z"),
      title: "Untitled note",
      rawText: "",
      cleanedText: "",
      duration: 0,
      isPinned: false,
      tags: [],
      source: "Note"
    };
    setDrafts(current => ({ ...current, [newNote.id]: newNote }));
    onSelectNote(newNote.id);
    setNoteStatus(newNote.id, "Draft · type to save");
  };

  const isSelectedToday =
    selectedNote.id === "today-placeholder" ||
    (selectedNote.captures != null && localDay(selectedNote.createdAt) === todayStr);

  useEffect(() => {
    if (!active) return;
    const handler = (event: KeyboardEvent) => {
      const action = matchNotesShortcut(event, { isNotesVisible: active });
      if (!action) return;
      event.preventDefault();
      switch (action.type) {
        case 'newNote':
          handleCreateWrittenNote();
          break;
        case 'searchNotes':
          searchInput.current?.focus();
          searchInput.current?.select();
          break;
        case 'todayNote':
          onSelectNote(todayNote.id);
          break;
      }
    };
    window.addEventListener('keydown', handler);
    return () => window.removeEventListener('keydown', handler);
  }, [active, todayNote.id, onSelectNote]);

  return (
    <div style={{ display: "flex", width: "100%", height: "100%", overflow: "hidden" }}>
      {teach && <TeachCorrection onClose={() => setTeach(false)} />}
      {pendingDelete && <ConfirmDialog title="Delete this note?" confirmLabel="Delete" onCancel={() => setPendingDelete(null)} onConfirm={() => { const id = pendingDelete; setPendingDelete(null); void handleDelete(id); }}>This cannot be undone. Linked meetings are kept in Meetings.</ConfirmDialog>}
      {/* Sidebar Library */}
      <div
        className="library-pane"
        style={{
          width: 280, flexShrink: 0,
          borderRight: "1px solid var(--os-line)",
          display: "flex",
          flexDirection: "column",
          background: "var(--os-background)"
        }}
      >
        <div
          style={{
            display: "flex",
            alignItems: "center",
            justifyContent: "space-between",
            padding: "20px 16px 12px"
          }}
        >
          <h2 style={{ fontSize: 20, fontWeight: 700, margin: 0, letterSpacing: "-0.03em" }}>
            Notes
          </h2>
          <button
            onClick={handleCreateWrittenNote}
            title="New note"
            style={{
              background: "var(--os-surface)",
              border: "1px solid var(--os-line)",
              borderRadius: 6,
              padding: "4px 8px",
              cursor: "pointer",
              display: "flex",
              alignItems: "center",
              gap: 4,
              fontSize: 12,
              fontWeight: 500
            }}
          >
            <Plus size={13} /> New note
          </button>
        </div>

        {/* Search */}
        <div style={{ padding: "0 16px 10px" }}>
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
              ref={searchInput}
              type="text"
              value={search}
              onChange={(e) => setSearch(e.target.value)}
              placeholder="Search notes and screenshots"
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

        {/* Filter Tabs */}
        <div
          style={{
            display: "flex",
            gap: 6,
            padding: "0 16px 12px",
            borderBottom: "1px solid var(--os-line)"
          }}
        >
          {(["all", "daily", "written"] as const).map((t) => (
            <button
              key={t}
              onClick={() => setFilter(t)}
              style={{
                background: filter === t ? "var(--os-accent)" : "transparent",
                color: filter === t ? "var(--os-surface)" : "var(--os-ink-muted)",
                border: "none",
                borderRadius: 999,
                padding: "3px 10px",
                fontSize: 11.5,
                fontWeight: 500,
                cursor: "pointer",
                textTransform: "capitalize"
              }}
            >
              {t === "daily" ? "Days" : t}
            </button>
          ))}
        </div>

        {/* Notes List */}
        <div style={{ flex: 1, minWidth: 0, minHeight: 0, overflowY: "auto", padding: "8px" }}>
          {/* Always show Today at top when appropriate */}
          {filter !== "written" && !search && (
            <button
              aria-pressed={isSelectedToday}
              onClick={() => onSelectNote(todayNote.id)}
              style={{
                width: "100%",
                display: "flex",
                flexDirection: "column",
                gap: 3,
                padding: "10px 12px",
                borderRadius: 8,
                background: isSelectedToday ? "var(--os-surface-hover)" : "transparent",
                border: "none",
                textAlign: "left",
                cursor: "pointer",
                marginBottom: 4
              }}
            >
              <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between" }}>
                <span style={{ fontSize: 13, fontWeight: 600, color: "var(--os-ink)" }}>
                  Today
                </span>
                <span
                  style={{
                    fontSize: 10,
                    fontWeight: 700,
                    background: "var(--os-accent)",
                    color: "var(--os-primary-text)",
                    borderRadius: 4,
                    padding: "1px 5px"
                  }}
                >
                  TODAY
                </span>
              </div>
              <span style={{ fontSize: 11.5, color: "var(--os-ink-muted)" }}>
                {visibleCaptures(todayNote).length} entries
              </span>
            </button>
          )}

          {listing.total === 0 && (search.trim() || filter === "written") && (
            <p className="list-empty" role="status">{search.trim() ? "No matching notes" : "No written notes yet"}</p>
          )}
          {listing.rows.map(({ note: n, group }, index) => {
            if (n.id === todayNote.id && filter !== "written" && !search) return null;
            const isSelected = selectedNote.id === n.id;
            const isDaily = n.captures != null;
            const dateStr = new Date(n.createdAt).toLocaleDateString(undefined, {
              month: "short",
              day: "numeric"
            });

            return (
              <React.Fragment key={n.id}>
              {(index === 0 || listing.rows[index - 1].group !== group) && <div style={{ padding: "12px 12px 6px", color: "var(--os-ink-muted)", fontSize: 11 }}>{group}</div>}
              <LibraryContextMenu actions={[
                { label: "Copy", run: () => { void navigator.clipboard.writeText(noteText(n)).catch(reportUiError); } },
                { label: n.isPinned ? "Unpin" : "Pin", run: () => { void handleUpdateNote({ ...n, isPinned: !n.isPinned }).catch(reportUiError); } },
                { label: "Delete…", run: () => setPendingDelete(n.id) }
              ]}>
              <button
                aria-pressed={isSelected}
                onClick={() => onSelectNote(n.id)}
                style={{
                  width: "100%",
                  display: "flex",
                  flexDirection: "column",
                  gap: 3,
                  padding: "10px 12px",
                  borderRadius: 8,
                  background: isSelected ? "var(--os-surface-hover)" : "transparent",
                  border: "none",
                  textAlign: "left",
                  cursor: "pointer",
                  marginBottom: 4
                }}
              >
                <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between" }}>
                  <span
                    style={{
                      fontSize: 13,
                      fontWeight: 600,
                      color: "var(--os-ink)",
                      overflow: "hidden",
                      textOverflow: "ellipsis",
                      whiteSpace: "nowrap",
                      minWidth: 0
                    }}
                  >
                    {isDaily ? new Date(n.createdAt).toLocaleDateString(undefined, { weekday: "long", month: "short", day: "numeric" }) : noteTitle(n)}
                  </span>
                  {n.isPinned && <Pin size={11} color="var(--os-accent)" fill="var(--os-accent)" />}
                </div>
                <span style={{ fontSize: 12, color: "var(--os-ink-muted)", display: "-webkit-box", WebkitLineClamp: 2, WebkitBoxOrient: "vertical", overflow: "hidden" }}>{notePreview(n) || "Start writing…"}</span>
                <div style={{ display: "flex", alignItems: "center", gap: 6, fontSize: 11.5, color: "var(--os-ink-muted)" }}>
                  <span>{dateStr}</span>
                  <span>·</span>
                  <span>{isDaily ? `${visibleCaptures(n).length} entries` : "Written"}</span>
                </div>
              </button>
              </LibraryContextMenu></React.Fragment>
            );
          })}
          {listing.total > limit && <button onClick={() => setLimit(current => current + 60)}>Show older notes</button>}
        </div>
      </div>

      {/* Main Note Pane */}
      <div className="detail-pane" style={{ flex: 1, minWidth: 0, minHeight: 0, height: "100%", overflow: "hidden" }}>
        {selectedNote.captures != null ? (
          <DayNoteView
            key={selectedNote.id}
            note={selectedNote}
            isToday={isSelectedToday}
            onUpdate={handleUpdateNote}
            onRefresh={onRefreshNotes}
            onDeleteNote={setPendingDelete}
            onOpenMeeting={onOpenMeeting}
            onStartDictation={onStartDictation}
            onStartMeeting={onStartMeeting}
          />
        ) : (
          <div style={{ display: "flex", flexDirection: "column", height: "100%", padding: "28px 36px" }}>
            <div className="ui-toolbar" style={{ display: "flex", justifyContent: "space-between", marginBottom: 16 }}>
              <input
                type="text"
                value={selectedNote.title}
                onChange={(e) =>
                  handleEdit({ ...selectedNote, title: e.target.value })
                }
                aria-label="Note title"
                placeholder="Note title"
                style={{
                  fontSize: 24,
                  fontWeight: 700,
                  border: "none",
                  outline: "none",
                  background: "transparent",
                  color: "var(--os-ink)",
                  flex: 1, minWidth: 0
                }}
              />
              <button
                aria-label="Delete note"
                onClick={() => setPendingDelete(selectedNote.id)}
                style={{
                  background: "transparent",
                  border: "none",
                  color: "color-mix(in srgb, var(--os-recording) 72%, var(--os-ink))",
                  cursor: "pointer"
                }}
              >
                <Trash2 size={16} />
              </button>
            </div>
            <div className="ui-toolbar" style={{ display: "flex", flexWrap: "wrap", gap: 12, marginBottom: 16 }}>
              <button onClick={() => handleEdit({ ...selectedNote, isPinned: !selectedNote.isPinned })}>{selectedNote.isPinned ? "Unpin" : "Pin"}</button>
              <button onClick={() => { void navigator.clipboard.writeText(originalId === selectedNote.id ? selectedNote.rawText : noteText(selectedNote)).catch(reportUiError); }}>Copy</button>
              <button onClick={() => { void exportText(originalId === selectedNote.id ? selectedNote.rawText : noteText(selectedNote), noteTitle(selectedNote), "txt").catch(reportUiError); }}>Export as text…</button>
              <button onClick={() => setTeach(true)}>Teach a correction…</button>
              {(originalId === selectedNote.id || selectedNote.rawText && selectedNote.rawText !== noteText(selectedNote)) && <button aria-pressed={originalId === selectedNote.id} onClick={() => setOriginalId(originalId === selectedNote.id ? null : selectedNote.id)}>{originalId === selectedNote.id ? "Note" : "Original"}</button>}
            </div>
            {originalId === selectedNote.id && <small>Original transcript · read only</small>}
            <textarea
              readOnly={originalId === selectedNote.id}
              aria-label={originalId === selectedNote.id ? "Original transcript" : "Note text"}
              value={originalId === selectedNote.id ? selectedNote.rawText : noteText(selectedNote)}
              onChange={(e) =>
                handleEdit(editNoteText(selectedNote, e.target.value))
              }
              placeholder="Write your note here…"
              style={{
                flex: 1, minWidth: 0, minHeight: 0,
                border: "none",
                outline: "none",
                background: "transparent",
                resize: "none",
                fontSize: 15,
                lineHeight: 1.6,
                color: "var(--os-ink)",
                fontFamily: "inherit"
              }}
            />
            <small style={{ color: "var(--os-ink-muted)" }} role="status">{saveStatuses[selectedNote.id] || "Saved"}</small>
            <small style={{ color: "var(--os-ink-muted)" }}>{noteText(selectedNote).split(/\s+/).filter(Boolean).length} words</small>
            {drafts[selectedNote.id] && <button onClick={() => { pending.current.set(selectedNote.id, selectedNote); flush(); }}>Save now / retry</button>}
          </div>
        )}
      </div>
    </div>
  );
};
