import { useEffect, useMemo, useRef, useState } from "react";
import { register, unregisterAll } from "@tauri-apps/plugin-global-shortcut";
import { writeText } from "@tauri-apps/plugin-clipboard-manager";
import {
  AudioLines, CalendarDays, Check, ChevronRight, CircleStop, Clipboard, FileAudio,
  KeyRound, Library, Mic, Moon, Plus, Search, Settings, Sparkles, Sun, Trash2, Users, X
} from "lucide-react";
import { cleanupInstructions, initialState, providerDefaults, providers } from "./defaults";
import { parseICS } from "./ics";
import { friendlyError, native, speechAccount, writingAccount } from "./native";
import { loadState, saveState } from "./storage";
import { applyCorrections, expandSnippet, noteTitle } from "./text";
import type { AppSettings, AudioInput, CalendarEvent, CapturePhase, Meeting, Note, PersistedState, RecoveryJob, Section } from "./types";

type RecordingIntent = { kind: "dictation" } | { kind: "meeting"; title: string; sourceLabel: string; summarize: boolean };

export default function App() {
  const [data, setData] = useState<PersistedState>(initialState);
  const [loaded, setLoaded] = useState(false);
  const [section, setSection] = useState<Section>("notes");
  const [onboarding, setOnboarding] = useState(false);
  const [phase, setPhase] = useState<CapturePhase>("idle");
  const [intent, setIntent] = useState<RecordingIntent>({ kind: "dictation" });
  const [notice, setNotice] = useState<{ summary: string; details: string }>();
  const [inputs, setInputs] = useState<AudioInput[]>([]);
  const [query, setQuery] = useState("");
  const [selectedNote, setSelectedNote] = useState<string>();
  const [selectedMeeting, setSelectedMeeting] = useState<string>();
  const toggleRef = useRef<() => void>(() => undefined);

  useEffect(() => {
    loadState().then((value) => {
      setData(value); setLoaded(true); setOnboarding(!value.setupCompleted);
      native.listInputs().then(setInputs).catch((error) => showError(error));
    });
  }, []);
  useEffect(() => { if (loaded) void saveState(data); }, [data, loaded]);
  useEffect(() => {
    if (!loaded) return;
    unregisterAll().then(() => register(data.settings.shortcut, ({ state }) => {
      if (state === "Pressed") toggleRef.current();
    })).catch((error) => showError(error));
    return () => { void unregisterAll(); };
  }, [loaded, data.settings.shortcut]);
  useEffect(() => { document.documentElement.dataset.theme = data.settings.theme; }, [data.settings.theme]);

  function showError(error: unknown) {
    setNotice({ summary: friendlyError(error), details: String(error) });
    window.setTimeout(() => setNotice(undefined), 6500);
  }

  async function toggleRecording(nextIntent: RecordingIntent = { kind: "dictation" }) {
    if (phase === "recording") return finishRecording();
    if (phase !== "idle") return;
    try {
      setIntent(nextIntent);
      const device = nextIntent.kind === "meeting" && nextIntent.sourceLabel === "System audio"
        ? data.settings.systemAudioDeviceId : data.settings.microphoneDeviceId;
      await native.startRecording(device);
      setPhase("recording");
    } catch (error) { setPhase("idle"); showError(error); }
  }
  toggleRef.current = () => void toggleRecording({ kind: "dictation" });

  async function finishRecording() {
    setPhase("transcribing");
    try {
      const recording = await native.stopRecording();
      const recovery: RecoveryJob = {
        id: crypto.randomUUID(), path: recording.path, duration: recording.duration,
        createdAt: new Date().toISOString(), kind: intent.kind,
        title: intent.kind === "meeting" ? intent.title : undefined,
        sourceLabel: intent.kind === "meeting" ? intent.sourceLabel : undefined,
        summarize: intent.kind === "meeting" ? intent.summarize : undefined
      };
      setData((current) => ({ ...current, recoveries: [recovery, ...(current.recoveries ?? [])] }));
      await processRecovery(recovery);
    } catch (error) { showError(error); }
    finally { setPhase("idle"); setIntent({ kind: "dictation" }); }
  }

  async function processRecovery(recovery: RecoveryJob) {
      const result = await native.transcribe(recovery.path, data.settings);
      const raw = result.text.trim();
      let polished = expandSnippet(raw, data.settings.snippets) ?? applyCorrections(raw, data.settings.corrections);
      if (data.settings.cleanupEnabled && !expandSnippet(raw, data.settings.snippets)) {
        setPhase("cleaning");
        const vocabulary = data.settings.customVocabulary.length ? ` Preserve these words exactly: ${data.settings.customVocabulary.join(", ")}.` : "";
        const tone = ` Keep the tone ${data.settings.writingTone}.`;
        try { polished = (await native.clean(polished, data.settings, cleanupInstructions[data.settings.cleanupStrength] + vocabulary + tone)).text; }
        catch (cleanupError) { setNotice({ summary: "Saved the transcript, but couldn’t polish it.", details: String(cleanupError) }); }
      }
      if (recovery.kind === "meeting") {
        let summary = "";
        if (recovery.summarize) {
          try { summary = (await native.clean(raw, data.settings, "Summarize this meeting into concise key points, decisions, and action items. Do not invent details.")).text; }
          catch (summaryError) { setNotice({ summary: "The meeting is saved, but the summary wasn’t created.", details: String(summaryError) }); }
        }
        const meeting: Meeting = { id: crypto.randomUUID(), createdAt: recovery.createdAt, title: recovery.title || "Untitled meeting", duration: recovery.duration, transcript: raw, summary, audioPath: recovery.path, sourceLabel: recovery.sourceLabel || "Microphone" };
        setData((current) => ({ ...current, meetings: [meeting, ...current.meetings], recoveries: (current.recoveries ?? []).filter((item) => item.id !== recovery.id) }));
        setSelectedMeeting(meeting.id); setSection("meetings");
      } else {
        const note: Note = { id: crypto.randomUUID(), createdAt: recovery.createdAt, title: noteTitle(polished), rawText: raw, cleanedText: polished, duration: recovery.duration, pinned: false, tags: [], audioPath: data.settings.saveRawAudio ? recovery.path : undefined };
        setData((current) => ({ ...current, notes: [note, ...current.notes], recoveries: (current.recoveries ?? []).filter((item) => item.id !== recovery.id) }));
        setSelectedNote(note.id); setSection("notes");
        if (!data.settings.saveRawAudio) await native.deleteRecording(recovery.path).catch((error) => setNotice({ summary: "The note is saved, but its temporary audio couldn’t be removed.", details: String(error) }));
        if (data.settings.pasteIntoFocusedApp && !onboarding) await native.paste(polished).catch((error) => setNotice({ summary: "Your note was saved, but it couldn’t be pasted.", details: String(error) }));
      }
  }

  async function retryRecovery(recovery: RecoveryJob) {
    if (phase !== "idle") return;
    setPhase("transcribing");
    try { await processRecovery(recovery); }
    catch (error) { showError(error); }
    finally { setPhase("idle"); }
  }

  async function discardRecovery(recovery: RecoveryJob) {
    try {
      await native.deleteRecording(recovery.path);
      setData((current) => ({ ...current, recoveries: (current.recoveries ?? []).filter((item) => item.id !== recovery.id) }));
    } catch (error) { showError(error); }
  }

  const updateSettings = (patch: Partial<AppSettings>) => setData((current) => ({ ...current, settings: { ...current.settings, ...patch } }));
  const completeSetup = () => { setData((current) => ({ ...current, setupCompleted: true })); setOnboarding(false); setSection("notes"); };

  if (!loaded) return <div className="boot"><WaveMark /><span>Opening your workspace…</span></div>;
  if (onboarding) return <Onboarding data={data} setData={setData} inputs={inputs} phase={phase} record={() => void toggleRecording()} finish={finishRecording} complete={completeSetup} close={() => setOnboarding(false)} showError={showError} />;

  return <div className="app-shell">
    <Sidebar section={section} setSection={setSection} phase={phase} ready={data.setupCompleted} record={() => void toggleRecording()} meetingActive={intent.kind === "meeting" && phase !== "idle"} openSetup={() => setOnboarding(true)} />
    <main>
      {(data.recoveries?.length ?? 0) > 0 && <div className="recovery-strip"><FileAudio/><div><strong>A recording still needs processing</strong><span>Your audio is safe on this device. Retry when your provider is available.</span></div><button onClick={() => void retryRecovery(data.recoveries[0])} disabled={phase !== "idle"}>Retry</button><button className="discard" onClick={() => void discardRecovery(data.recoveries[0])} disabled={phase !== "idle"}>Discard</button></div>}
      {section === "notes" && <NotesView notes={data.notes} query={query} setQuery={setQuery} selected={selectedNote} setSelected={setSelectedNote} update={(notes) => setData((current) => ({ ...current, notes }))} record={() => void toggleRecording()} phase={phase} />}
      {section === "meetings" && <MeetingsView meetings={data.meetings} inputs={inputs} settings={data.settings} selected={selectedMeeting} setSelected={setSelectedMeeting} start={(value) => void toggleRecording(value)} stop={() => void finishRecording()} phase={phase} update={(meetings) => setData((current) => ({ ...current, meetings }))} />}
      {section === "calendar" && <CalendarView events={data.calendar} update={(calendar) => setData((current) => ({ ...current, calendar }))} />}
      {section === "settings" && <SettingsView settings={data.settings} inputs={inputs} update={updateSettings} openSetup={() => setOnboarding(true)} showError={showError} />}
    </main>
    {notice && <button className="notice" onClick={() => alert(notice.details)}><span>{notice.summary}</span><small>Details</small></button>}
  </div>;
}

function WaveMark() { return <div className="wave-mark" aria-hidden="true"><i /><i /><i /><i /><i /></div>; }

function Sidebar({ section, setSection, phase, ready, record, meetingActive, openSetup }: { section: Section; setSection: (value: Section) => void; phase: CapturePhase; ready: boolean; record: () => void; meetingActive: boolean; openSetup: () => void }) {
  const destinations: [Section, string, typeof Library][] = [["notes", "Notes", Library], ["meetings", "Meetings", Users], ["calendar", "Calendar", CalendarDays]];
  return <aside className="sidebar">
    <div className="brand"><WaveMark /><div><strong>OpenScribe</strong><span>VOICE WORKSPACE</span></div></div>
    <p className="eyebrow">LIBRARY</p>
    <nav>{destinations.map(([id, label, Icon]) => <button className={section === id ? "active" : ""} onClick={() => setSection(id)} key={id}><Icon size={17}/>{label}</button>)}</nav>
    <div className="sidebar-spacer" />
    <button className={`settings-link ${section === "settings" ? "active" : ""}`} onClick={() => setSection("settings")}><Settings size={17}/>Settings</button>
    <div className="capture-card">
      {!ready ? <><strong>Ready when you are</strong><p>Connect a provider and choose an audio input.</p><button className="primary" onClick={openSetup}>Finish setup</button></> : <>
        <div className="capture-status"><span className={phase === "recording" ? "dot live" : "dot"}/><strong>{phase === "idle" ? "Dictation" : phase === "recording" ? "Listening" : phase === "transcribing" ? "Transcribing" : "Polishing"}</strong></div>
        <button className={`record-button ${phase === "recording" ? "stop" : ""}`} onClick={record} disabled={meetingActive || (phase !== "idle" && phase !== "recording")}>
          {phase === "recording" ? <CircleStop size={17}/> : <Mic size={17}/>} {phase === "recording" ? "Stop & save" : "Record a note"}
        </button><small>{meetingActive ? "Available after your meeting" : "Alt + Space to dictate anywhere"}</small>
      </>}
    </div>
  </aside>;
}

function PageHeader({ eyebrow, title, detail, action }: { eyebrow: string; title: string; detail: string; action?: React.ReactNode }) {
  return <header className="page-header"><div><span>{eyebrow}</span><h1>{title}</h1><p>{detail}</p></div>{action}</header>;
}

function NotesView({ notes, query, setQuery, selected, setSelected, update, record, phase }: { notes: Note[]; query: string; setQuery: (value: string) => void; selected?: string; setSelected: (value?: string) => void; update: (notes: Note[]) => void; record: () => void; phase: CapturePhase }) {
  const visible = notes.filter((note) => `${note.title} ${note.cleanedText} ${note.tags.join(" ")}`.toLowerCase().includes(query.toLowerCase()));
  const note = notes.find((item) => item.id === selected);
  if (note) return <NoteDetail note={note} close={() => setSelected(undefined)} update={(value) => update(notes.map((item) => item.id === value.id ? value : item))} remove={() => { if (note.audioPath) void native.deleteRecording(note.audioPath); update(notes.filter((item) => item.id !== note.id)); setSelected(undefined); }} />;
  return <section className="page"><PageHeader eyebrow="YOUR LIBRARY" title="Notes" detail="Every thought, searchable and safely stored on this device." action={<button className="quiet" onClick={() => {
    const value: Note = { id: crypto.randomUUID(), createdAt: new Date().toISOString(), title: "Untitled note", rawText: "", cleanedText: "", duration: 0, pinned: false, tags: [] };
    update([value, ...notes]); setSelected(value.id);
  }}><Plus size={16}/> New note</button>} />
    <div className="toolbar"><label className="search"><Search size={16}/><input value={query} onChange={(event) => setQuery(event.target.value)} placeholder="Search notes" /></label><span>{visible.length} notes</span></div>
    {visible.length ? <div className="note-grid">{visible.map((item) => <button className="note-card" key={item.id} onClick={() => setSelected(item.id)}><div className="note-card-top"><time>{formatDate(item.createdAt)}</time>{item.pinned && <span>PINNED</span>}</div><h3>{item.title}</h3><p>{item.cleanedText || item.rawText || "Empty note"}</p><div><span>{Math.round(item.duration)}s</span><ChevronRight size={16}/></div></button>)}</div> : <EmptyState icon={<AudioLines/>} title={query ? "No matching notes" : "Your first note starts here"} detail={query ? "Try another word or clear your search." : "Record a thought and its transcript will appear here."} action={<button className="primary" onClick={record} disabled={phase !== "idle"}><Mic size={16}/> Record a note</button>} />}
  </section>;
}

function NoteDetail({ note, close, update, remove }: { note: Note; close: () => void; update: (note: Note) => void; remove: () => void }) {
  return <section className="page detail-page"><button className="back" onClick={close}>← Back to notes</button><div className="detail-heading"><input className="title-input" value={note.title} onChange={(event) => update({ ...note, title: event.target.value })}/><div><button className="quiet" onClick={() => void writeText(note.cleanedText || note.rawText)}><Clipboard size={15}/> Copy</button><button className="danger" onClick={remove}><Trash2 size={15}/></button></div></div><p className="metadata">{formatDate(note.createdAt)} · {Math.round(note.duration)} seconds</p><textarea className="editor" value={note.cleanedText} onChange={(event) => update({ ...note, cleanedText: event.target.value })} placeholder="Write or dictate something…"/><label className="tag-line">Tags<input value={note.tags.join(", ")} onChange={(event) => update({ ...note, tags: event.target.value.split(",").map((tag) => tag.trim()).filter(Boolean) })}/></label></section>;
}

function MeetingsView({ meetings, inputs, settings, selected, setSelected, start, stop, phase, update }: { meetings: Meeting[]; inputs: AudioInput[]; settings: AppSettings; selected?: string; setSelected: (value?: string) => void; start: (intent: RecordingIntent) => void; stop: () => void; phase: CapturePhase; update: (meetings: Meeting[]) => void }) {
  const [setup, setSetup] = useState(false);
  const [title, setTitle] = useState("");
  const [source, setSource] = useState<"Microphone" | "System audio">("Microphone");
  const [summarize, setSummarize] = useState(true);
  const meeting = meetings.find((item) => item.id === selected);
  if (meeting) return <section className="page detail-page"><button className="back" onClick={() => setSelected(undefined)}>← Back to meetings</button><div className="detail-heading"><div><span className="pill"><FileAudio size={13}/>{meeting.sourceLabel}</span><h1>{meeting.title}</h1></div><button className="danger" onClick={() => { if (meeting.audioPath) void native.deleteRecording(meeting.audioPath); update(meetings.filter((item) => item.id !== meeting.id)); setSelected(undefined); }}><Trash2 size={15}/></button></div><p className="metadata">{formatDate(meeting.createdAt)} · {Math.round(meeting.duration)} seconds</p>{meeting.summary && <article className="summary"><span>MEETING BRIEF</span><h2>Summary</h2><p>{meeting.summary}</p></article>}<article className="transcript"><span>TRANSCRIPT</span><p>{meeting.transcript}</p></article></section>;
  return <section className="page"><PageHeader eyebrow="CONVERSATIONS" title="Meetings" detail="Capture a microphone or an OS loopback/monitor source, then turn it into durable notes." action={<button className="primary" onClick={() => setSetup(true)} disabled={phase !== "idle"}><Plus size={16}/> New meeting</button>} />
    {phase !== "idle" && <div className="active-strip"><span className="dot live"/><strong>{phase === "recording" ? "Meeting recording active" : "Processing meeting"}</strong><button onClick={stop} disabled={phase !== "recording"}>Stop & save</button></div>}
    {meetings.length ? <div className="meeting-list">{meetings.map((item) => <button key={item.id} onClick={() => setSelected(item.id)}><div className="meeting-icon"><Users/></div><div><h3>{item.title}</h3><p>{formatDate(item.createdAt)} · {item.sourceLabel}</p></div><span>{Math.round(item.duration / 60)} min</span><ChevronRight/></button>)}</div> : <EmptyState icon={<Users/>} title="No meetings yet" detail="Record a call or conversation after everyone knows recording is active." action={<button className="primary" onClick={() => setSetup(true)}>Start a meeting</button>} />}
    {setup && <div className="modal-backdrop"><div className="modal"><button className="modal-close" onClick={() => setSetup(false)}><X/></button><span className="eyebrow">NEW RECORDING</span><h2>Start a meeting</h2><label>Meeting title<input value={title} onChange={(event) => setTitle(event.target.value)} placeholder="Weekly planning" autoFocus/></label><fieldset><legend>Audio source</legend><button className={source === "Microphone" ? "choice selected" : "choice"} onClick={() => setSource("Microphone")}><Mic/><div><strong>Microphone</strong><span>{inputs.find((item) => item.id === settings.microphoneDeviceId)?.name ?? "System default"}</span></div>{source === "Microphone" && <Check/>}</button><button className={source === "System audio" ? "choice selected" : "choice"} onClick={() => setSource("System audio")} disabled={!settings.systemAudioDeviceId}><AudioLines/><div><strong>System audio</strong><span>{inputs.find((item) => item.id === settings.systemAudioDeviceId)?.name ?? "Choose a monitor source in Settings"}</span></div>{source === "System audio" && <Check/>}</button></fieldset><label className="toggle-row"><input type="checkbox" checked={summarize} onChange={(event) => setSummarize(event.target.checked)}/><span><strong>Transcribe and summarize after stopping</strong><small>Audio and transcript are sent to your configured providers.</small></span></label><p className="consent">Make sure participants know you’re recording.</p><button className="primary wide" onClick={() => { start({ kind: "meeting", title, sourceLabel: source, summarize }); setSetup(false); }}>Start meeting</button></div></div>}
  </section>;
}

function CalendarView({ events, update }: { events: CalendarEvent[]; update: (events: CalendarEvent[]) => void }) {
  const file = useRef<HTMLInputElement>(null);
  const upcoming = events.filter((event) => new Date(event.end) >= new Date()).slice(0, 40);
  async function importFile(value?: File) { if (!value) return; update([...parseICS(await value.text()), ...events].filter((item, index, all) => all.findIndex((other) => other.id === item.id) === index)); }
  return <section className="page"><input ref={file} hidden type="file" accept=".ics,text/calendar" onChange={(event) => void importFile(event.target.files?.[0])}/><PageHeader eyebrow="YOUR SCHEDULE" title="Calendar" detail="Import an ICS export from Outlook, Google Calendar, or your CalDAV service." action={<button className="quiet" onClick={() => file.current?.click()}>Import .ics</button>} />
    <div className="calendar-callout"><CalendarDays/><div><strong>Portable calendar support</strong><p>Windows and Linux do not share a safe EventKit equivalent. ICS import keeps calendar data local and provider-neutral.</p></div></div>
    {upcoming.length ? <div className="agenda">{upcoming.map((event) => <article key={event.id}><time><strong>{new Date(event.start).getDate()}</strong><span>{new Date(event.start).toLocaleString(undefined, { month: "short" }).toUpperCase()}</span></time><div><h3>{event.title}</h3><p>{new Date(event.start).toLocaleString()} {event.location ? `· ${event.location}` : ""}</p></div>{event.url && <a href={event.url} target="_blank" rel="noreferrer">Join</a>}<button className="icon-button" onClick={() => update(events.filter((item) => item.id !== event.id))}><X/></button></article>)}</div> : <EmptyState icon={<CalendarDays/>} title="Bring your calendar" detail="Export an .ics file from your calendar provider and import it here." action={<button className="primary" onClick={() => file.current?.click()}>Import calendar</button>} />}
  </section>;
}

function SettingsView({ settings, inputs, update, openSetup, showError }: { settings: AppSettings; inputs: AudioInput[]; update: (patch: Partial<AppSettings>) => void; openSetup: () => void; showError: (error: unknown) => void }) {
  const [tab, setTab] = useState<"general" | "speech" | "writing" | "personalize">("general");
  return <section className="page settings-page"><PageHeader eyebrow="PREFERENCES" title="Settings" detail="Your providers, audio routing, writing style, and privacy choices." action={<button className="quiet" onClick={openSetup}>Setup guide</button>} /><div className="tabs">{(["general","speech","writing","personalize"] as const).map((value) => <button className={tab === value ? "active" : ""} onClick={() => setTab(value)} key={value}>{value}</button>)}</div>
    {tab === "general" && <div className="settings-grid"><SettingsCard title="Appearance" icon={<Sun/>}><div className="segmented"><button className={settings.theme === "paper" ? "active" : ""} onClick={() => update({ theme: "paper" })}><Sun/> Paper</button><button className={settings.theme === "dark" ? "active" : ""} onClick={() => update({ theme: "dark" })}><Moon/> Dark</button></div></SettingsCard><SettingsCard title="Audio inputs" icon={<Mic/>}><Field label="Microphone"><select value={settings.microphoneDeviceId} onChange={(event) => update({ microphoneDeviceId: event.target.value })}><option value="">System default</option>{inputs.filter((item) => !item.likelySystemAudio).map((item) => <option key={item.id} value={item.id}>{item.name}</option>)}</select></Field><Field label="System audio / monitor"><select value={settings.systemAudioDeviceId} onChange={(event) => update({ systemAudioDeviceId: event.target.value })}><option value="">Not configured</option>{inputs.map((item) => <option key={item.id} value={item.id}>{item.name}{item.likelySystemAudio ? " · recommended" : ""}</option>)}</select></Field><p className="hint">On Windows enable Stereo Mix or a virtual loopback device. On Linux choose a PipeWire/Pulse monitor source.</p></SettingsCard><SettingsCard title="Shortcut & paste" icon={<KeyRound/>}><Field label="Global shortcut"><input value={settings.shortcut} onChange={(event) => update({ shortcut: event.target.value })}/></Field><Toggle checked={settings.pasteIntoFocusedApp} onChange={(value) => update({ pasteIntoFocusedApp: value })} title="Paste into the focused app" detail="Uses the clipboard briefly, then restores its previous text."/><Toggle checked={settings.saveRawAudio} onChange={(value) => update({ saveRawAudio: value })} title="Keep raw dictation audio" detail="Meeting audio is always retained until you delete the meeting."/></SettingsCard></div>}
    {tab === "speech" && <ProviderSettings purpose="speech" settings={settings} update={update} showError={showError}/>} 
    {tab === "writing" && <div className="settings-grid"><ProviderSettings purpose="writing" settings={settings} update={update} showError={showError}/><SettingsCard title="Cleanup" icon={<Sparkles/>}><Toggle checked={settings.cleanupEnabled} onChange={(value) => update({ cleanupEnabled: value })} title="Polish dictation" detail="Falls back to the raw transcript if writing cleanup fails."/><Field label="Strength"><select value={settings.cleanupStrength} onChange={(event) => update({ cleanupStrength: event.target.value as AppSettings["cleanupStrength"] })}><option value="light">Light</option><option value="clear">Clear</option><option value="concise">Concise</option></select></Field><Field label="Tone"><select value={settings.writingTone} onChange={(event) => update({ writingTone: event.target.value as AppSettings["writingTone"] })}><option value="natural">Natural</option><option value="casual">Casual</option><option value="formal">Formal</option></select></Field></SettingsCard></div>}
    {tab === "personalize" && <Personalize settings={settings} update={update}/>} 
  </section>;
}

function ProviderSettings({ purpose, settings, update, showError }: { purpose: "speech" | "writing"; settings: AppSettings; update: (patch: Partial<AppSettings>) => void; showError: (error: unknown) => void }) {
  const id = purpose === "speech" ? settings.speechProvider : settings.writingProvider;
  const baseUrl = purpose === "speech" ? settings.speechBaseUrl : settings.writingBaseUrl;
  const model = purpose === "speech" ? settings.speechModel : settings.writingModel;
  const [key, setKey] = useState(""); const [saved, setSaved] = useState(false);
  const account = purpose === "speech" ? speechAccount(settings) : writingAccount(settings);
  useEffect(() => { native.hasCredential(account).then(setSaved).catch(() => setSaved(false)); setKey(""); }, [account]);
  const allowed = providers.filter((provider) => purpose === "speech" ? provider.speechModel : provider.writingModel);
  function choose(next: string) { const defaults = providerDefaults(next, purpose); update(purpose === "speech" ? { speechProvider: next as AppSettings["speechProvider"], speechBaseUrl: defaults.baseUrl, speechModel: defaults.model } : { writingProvider: next as AppSettings["writingProvider"], writingBaseUrl: defaults.baseUrl, writingModel: defaults.model }); }
  return <SettingsCard title={purpose === "speech" ? "Transcription provider" : "Writing provider"} icon={purpose === "speech" ? <AudioLines/> : <Sparkles/>}><Field label="Provider"><select value={id} onChange={(event) => choose(event.target.value)}>{allowed.map((provider) => <option key={provider.id} value={provider.id}>{provider.title}</option>)}</select></Field><Field label="Model"><input value={model} onChange={(event) => update(purpose === "speech" ? { speechModel: event.target.value } : { writingModel: event.target.value })}/></Field><Field label="Base URL"><input value={baseUrl} onChange={(event) => update(purpose === "speech" ? { speechBaseUrl: event.target.value } : { writingBaseUrl: event.target.value })}/></Field><Field label="API key"><div className="key-field"><input type="password" value={key} placeholder={saved ? "Key saved in system credential store" : "Paste provider key"} onChange={(event) => setKey(event.target.value)}/><button onClick={() => native.saveCredential(account, key.trim()).then(() => { setSaved(true); setKey(""); }).catch(showError)} disabled={!key.trim()}>Save</button>{saved && <button className="danger" onClick={() => native.removeCredential(account).then(() => setSaved(false)).catch(showError)}>Remove</button>}</div></Field><p className="hint">Stored using Windows Credential Manager or the Linux Secret Service.</p></SettingsCard>;
}

function Personalize({ settings, update }: { settings: AppSettings; update: (patch: Partial<AppSettings>) => void }) {
  const [heard, setHeard] = useState(""); const [replacement, setReplacement] = useState("");
  const [trigger, setTrigger] = useState(""); const [expansion, setExpansion] = useState("");
  return <div className="settings-grid"><SettingsCard title="Vocabulary" icon={<Library/>}><textarea value={settings.customVocabulary.join("\n")} onChange={(event) => update({ customVocabulary: event.target.value.split("\n").map((value) => value.trim()).filter(Boolean) })} placeholder={'Names and terms, one per line\nOpenScribe\nPostgreSQL'}/></SettingsCard><SettingsCard title="Corrections" icon={<Sparkles/>}><div className="inline-add"><input placeholder="What was heard" value={heard} onChange={(event) => setHeard(event.target.value)}/><input placeholder="Replacement" value={replacement} onChange={(event) => setReplacement(event.target.value)}/><button onClick={() => { if (heard.trim() && replacement.trim()) update({ corrections: [...settings.corrections, { id: crypto.randomUUID(), heard, replacement }] }); setHeard(""); setReplacement(""); }}><Plus/></button></div>{settings.corrections.map((rule) => <div className="rule" key={rule.id}><span>{rule.heard}</span><ChevronRight/><strong>{rule.replacement}</strong><button onClick={() => update({ corrections: settings.corrections.filter((item) => item.id !== rule.id) })}><X/></button></div>)}</SettingsCard><SettingsCard title="Voice snippets" icon={<KeyRound/>}><div className="inline-add"><input placeholder="Spoken trigger" value={trigger} onChange={(event) => setTrigger(event.target.value)}/><input placeholder="Exact expansion" value={expansion} onChange={(event) => setExpansion(event.target.value)}/><button onClick={() => { if (trigger.trim() && expansion.trim()) update({ snippets: [...settings.snippets, { id: crypto.randomUUID(), trigger, replacement: expansion }] }); setTrigger(""); setExpansion(""); }}><Plus/></button></div>{settings.snippets.map((snippet) => <div className="rule" key={snippet.id}><span>{snippet.trigger}</span><ChevronRight/><strong>{snippet.replacement}</strong><button onClick={() => update({ snippets: settings.snippets.filter((item) => item.id !== snippet.id) })}><X/></button></div>)}</SettingsCard></div>;
}

function Onboarding({ data, setData, inputs, phase, record, finish, complete, close, showError }: { data: PersistedState; setData: React.Dispatch<React.SetStateAction<PersistedState>>; inputs: AudioInput[]; phase: CapturePhase; record: () => void; finish: () => void; complete: () => void; close: () => void; showError: (error: unknown) => void }) {
  const [step, setStep] = useState(0); const [key, setKey] = useState(""); const [keySaved, setKeySaved] = useState(false);
  const settings = data.settings; const account = speechAccount(settings);
  useEffect(() => { native.hasCredential(account).then(setKeySaved).catch(() => setKeySaved(false)); }, [account]);
  const update = (patch: Partial<AppSettings>) => setData((current) => ({ ...current, settings: { ...current.settings, ...patch } }));
  const choose = (id: string) => { const value = providerDefaults(id, "speech"); update({ speechProvider: id as AppSettings["speechProvider"], speechBaseUrl: value.baseUrl, speechModel: value.model }); setKeySaved(false); };
  async function connect() { try { if (!keySaved) { await native.saveCredential(account, key.trim()); setKeySaved(true); setKey(""); } setStep(1); } catch (error) { showError(error); } }
  return <div className="onboarding"><header><div className="brand"><WaveMark/><div><strong>OpenScribe</strong><span>WINDOWS + LINUX</span></div></div><button onClick={close}>Set up later</button></header><div className="setup-progress">{["Connect","Audio","Try it"].map((label, index) => <div className={step === index ? "active" : step > index ? "done" : ""} key={label}><span>{step > index ? <Check/> : index + 1}</span>{label}</div>)}</div><div className="setup-panel">
    {step === 0 && <><span className="eyebrow">YOUR PROVIDER</span><h1>Choose what hears you.</h1><p>OpenScribe uses your own transcription account. The key stays in your operating system’s credential store.</p><Field label="Transcription provider"><select value={settings.speechProvider} onChange={(event) => choose(event.target.value)}>{providers.filter((provider) => provider.speechModel).map((provider) => <option value={provider.id} key={provider.id}>{provider.title}</option>)}</select></Field><Field label="API key"><input type="password" value={key} onChange={(event) => setKey(event.target.value)} placeholder={keySaved ? "Key saved" : "Paste your provider key"}/></Field></>}
    {step === 1 && <><span className="eyebrow">AUDIO ROUTING</span><h1>Choose your microphone.</h1><p>You can add a Windows loopback or Linux monitor source later for meeting audio.</p><Field label="Microphone"><select value={settings.microphoneDeviceId} onChange={(event) => update({ microphoneDeviceId: event.target.value })}><option value="">System default</option>{inputs.map((input) => <option value={input.id} key={input.id}>{input.name}</option>)}</select></Field><div className="permission-note"><Mic/><div><strong>Microphone access</strong><p>Your operating system may ask the first time recording starts.</p></div></div></>}
    {step === 2 && <><span className="eyebrow">FIRST NOTE</span><h1>Try a sentence.</h1><p>Say “This is my first note in OpenScribe.” It will save to Notes and will not paste into another app during setup.</p><button className={`practice ${phase === "recording" ? "recording" : ""}`} onClick={phase === "recording" ? finish : record} disabled={phase !== "idle" && phase !== "recording"}>{phase === "recording" ? <CircleStop/> : <Mic/>}<span><strong>{phase === "recording" ? "Stop & save" : "Record a test note"}</strong><small>{phase === "idle" ? "Your audio stays local until transcription" : phase}</small></span></button></>}
  </div><footer>{step > 0 && <button onClick={() => setStep(step - 1)} disabled={phase !== "idle"}>Back</button>}<span/><button className="primary" onClick={step === 0 ? () => void connect() : step === 1 ? () => setStep(2) : complete} disabled={step === 0 && !keySaved && !key.trim()}>{step === 2 ? "Start using OpenScribe" : "Continue"}</button></footer></div>;
}

function SettingsCard({ title, icon, children }: { title: string; icon: React.ReactNode; children: React.ReactNode }) { return <article className="settings-card"><header>{icon}<h2>{title}</h2></header>{children}</article>; }
function Field({ label, children }: { label: string; children: React.ReactNode }) { return <label className="field"><span>{label}</span>{children}</label>; }
function Toggle({ checked, onChange, title, detail }: { checked: boolean; onChange: (value: boolean) => void; title: string; detail: string }) { return <label className="toggle-row"><input type="checkbox" checked={checked} onChange={(event) => onChange(event.target.checked)}/><span><strong>{title}</strong><small>{detail}</small></span></label>; }
function EmptyState({ icon, title, detail, action }: { icon: React.ReactNode; title: string; detail: string; action: React.ReactNode }) { return <div className="empty-state"><div>{icon}</div><h2>{title}</h2><p>{detail}</p>{action}</div>; }
function formatDate(value: string) { return new Date(value).toLocaleString(undefined, { month: "short", day: "numeric", year: "numeric", hour: "numeric", minute: "2-digit" }); }
