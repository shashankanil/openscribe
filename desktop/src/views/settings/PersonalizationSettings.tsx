import React, { useEffect, useState } from "react";
import { open } from "@tauri-apps/plugin-dialog";
import type { ParitySettings } from "../../api/parityTypes";
import { SettingsDialog, settingsBox as box, settingsField as field } from "./SettingsDialog";
import { settingsNative, speechHintDetail, tones, type SaveSettings, type SourceApp } from "./settingsSupport";
import { applyPersonalizationDraft, type PersonalizationDraft } from "./personalizationDraft";

export function PersonalizationSettings({ settings, onUpdateSettings }: { settings: ParitySettings; onUpdateSettings: SaveSettings }) {
  const [tab, setTab] = useState<"dictionary" | "snippets" | "smart" | "apps">("dictionary");
  const [draft, setDraft] = useState<PersonalizationDraft | null>(null);
  const [deleting, setDeleting] = useState<{ title: string; next: ParitySettings } | null>(null);
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);
  const edit = (kind: PersonalizationDraft["kind"], trigger = "", replacement = "", original?: string, tone = "natural") => { setError(""); setDraft({ kind, trigger, replacement, original, tone }); };
  const persist = async (next: ParitySettings, done?: () => void) => { setBusy(true); setError(""); try { await onUpdateSettings(next); done?.(); } catch (failure) { setError(String(failure)); } finally { setBusy(false); } };
  const remove = (title: string, next: ParitySettings) => { setError(""); setDeleting({ title, next }); };
  const hintDetail = speechHintDetail(settings.speechProvider, settings.speechModel);
  const toggle = (key: "speechHints" | "spokenCorrections" | "learnSpelledWords", title: string) => <label style={{ display: "flex", justifyContent: "space-between", gap: 20 }}>{title}<input type="checkbox" disabled={busy || (key === "speechHints" && !hintDetail) || (key === "learnSpelledWords" && !settings.spokenCorrections)} checked={settings[key]} onChange={event => { void persist({ ...settings, [key]: event.target.checked }); }} /></label>;
  return <div style={{ display: "flex", flexDirection: "column", gap: 20 }}>
    <div role="tablist" aria-label="Personalization" style={{ display: "flex", gap: 10 }}>{([ ["dictionary", "Dictionary"], ["snippets", "Snippets"], ["apps", "App styles"], ["smart", "Smart corrections"] ] as const).map(([id, title]) => <button key={id} role="tab" aria-selected={tab === id} onClick={() => setTab(id)}>{title}</button>)}</div>
    {tab === "dictionary" && <>
      <section style={box}><h3>Vocabulary</h3><p>{settings.customVocabulary.join(", ") || "Add names and terminology you want OpenScribe to recognize."}</p><button onClick={() => edit("vocabulary", "", settings.customVocabulary.join(", "))}>Edit vocabulary...</button></section>
      <button onClick={() => edit("correction")}>Add correction</button>
      {settings.correctionRules.length === 0 && <p>No corrections yet.</p>}
      {settings.correctionRules.map(rule => <section style={box} key={rule.id}><span>{rule.heard} &rarr; <strong>{rule.replacement}</strong></span><div><button onClick={() => edit("correction", rule.heard, rule.replacement, rule.id)}>Edit</button> <button onClick={() => remove(rule.heard, { ...settings, correctionRules: settings.correctionRules.filter(item => item.id !== rule.id) })}>Remove</button></div></section>)}
      <small>Corrections work even when cleanup is off. Vocabulary guides transcription and cleanup.</small>
    </>}
    {tab === "snippets" && <><p>A trigger must be the entire dictation. Snippets insert their exact text and skip cleanup.</p><button onClick={() => edit("snippet")}>Add snippet</button>{!settings.snippets.length && <p>No snippets yet.</p>}{settings.snippets.map(snippet => <section style={box} key={snippet.id}><strong>{snippet.trigger}</strong><p style={{ whiteSpace: "pre-wrap" }}>{snippet.replacement}</p><div><button onClick={() => edit("snippet", snippet.trigger, snippet.replacement, snippet.id)}>Edit</button> <button onClick={() => remove(snippet.trigger, { ...settings, snippets: settings.snippets.filter(item => item.id !== snippet.id) })}>Remove</button></div></section>)}</>}
    {tab === "apps" && <><p>App styles apply when cleanup is on, using the app where recording starts.</p><button onClick={() => edit("appStyle")}>Add app style</button>{!Object.keys(settings.appWritingTones).length && <p>No app styles yet.</p>}{Object.entries(settings.appWritingTones).sort(([a], [b]) => a.localeCompare(b)).map(([identity, tone]) => <section key={identity} style={box}><strong style={{ overflowWrap: "anywhere" }}>{identity}</strong><span>{tone}</span><div><button onClick={() => edit("appStyle", identity, "", identity, tone)}>Edit</button> <button onClick={() => { const next = { ...settings.appWritingTones }; delete next[identity]; remove(identity, { ...settings, appWritingTones: next }); }}>Remove</button></div></section>)}</>}
    {tab === "smart" && <section style={box}>
      {toggle("speechHints", "Send words to supported speech models")}<small>{hintDetail ?? "This speech model does not take word hints. Your dictionary is applied after transcription instead."}</small>
      {toggle("spokenCorrections", "Understand spoken corrections")}<small>Detect corrections such as "Friday, no wait, Thursday" and spelled names. A provider check changes only confident matches.</small>
      {toggle("learnSpelledWords", "Learn words you spell out")}
      <label style={field}>Correction model<input disabled={!settings.spokenCorrections || busy} defaultValue={settings.correctionModel} key={settings.correctionModel} onBlur={event => { if (event.target.value !== settings.correctionModel) void persist({ ...settings, correctionModel: event.target.value.trim() }); }} placeholder="Use the default correction model" /></label>
    </section>}
    {error && !draft && !deleting && <p role="alert">{error}</p>}
    {draft && <PersonalizationEditor draft={draft} setDraft={setDraft} busy={busy} error={error} onClose={() => setDraft(null)} onSave={() => { try { const next = applyPersonalizationDraft(settings, draft); void persist(next, () => setDraft(null)); } catch (failure) { setError(String(failure)); } }} />}
    {deleting && <SettingsDialog title="Remove this item?" busy={busy} onClose={() => setDeleting(null)}><p style={{ overflowWrap: "anywhere" }}>{deleting.title}</p><p>Future dictations will use your remaining preferences.</p><button disabled={busy} onClick={() => setDeleting(null)}>Cancel</button> <button disabled={busy} onClick={() => { void persist(deleting.next, () => setDeleting(null)); }}>{busy ? "Removing..." : "Remove"}</button>{error && <p role="alert">{error}</p>}</SettingsDialog>}
  </div>;
}
function PersonalizationEditor({ draft, setDraft, busy, error, onClose, onSave }: { draft: PersonalizationDraft; setDraft: (draft: PersonalizationDraft) => void; busy: boolean; error: string; onClose: () => void; onSave: () => void }) {
  const [apps, setApps] = useState<SourceApp[]>([]);
  const [appError, setAppError] = useState("");
  const refresh = async () => { try { setApps(await settingsNative.listSourceApps()); setAppError(""); } catch (failure) { setAppError(String(failure)); } };
  useEffect(() => { if (draft.kind === "appStyle") void refresh(); }, [draft.kind]);
  const choose = async () => { try { const path = await open({ multiple: false, directory: false, filters: [{ name: "Windows application", extensions: ["exe"] }] }); if (typeof path === "string") setDraft({ ...draft, trigger: path.toLowerCase() }); } catch (failure) { setAppError(String(failure)); } };
  return <SettingsDialog title={draft.kind === "vocabulary" ? "Your vocabulary" : `${draft.original ? "Edit" : "Add"} ${draft.kind === "appStyle" ? "app style" : draft.kind}`} busy={busy} onClose={onClose}><form onSubmit={event => { event.preventDefault(); onSave(); }}><fieldset disabled={busy} style={{ border: 0, padding: 0, display: "flex", flexDirection: "column", gap: 16 }}>
    {draft.kind === "vocabulary" ? <label style={field}>Separate names and terms with commas or new lines<textarea rows={6} value={draft.replacement} onChange={event => setDraft({ ...draft, replacement: event.target.value })} /></label> : draft.kind === "appStyle" ? <>
      <label style={field}>Running application<select value={apps.some(app => app.id.toLowerCase() === draft.trigger.toLowerCase()) ? draft.trigger.toLowerCase() : ""} onChange={event => { if (event.target.value) setDraft({ ...draft, trigger: event.target.value }); }}><option value="">Choose an app...</option>{apps.map(app => <option key={app.id} value={app.id.toLowerCase()}>{app.name} - {app.path}</option>)}</select></label>
      <div><button type="button" onClick={() => { void refresh(); }}>Refresh apps</button> <button type="button" onClick={() => { void choose(); }}>Choose executable...</button></div>
      <label style={field}>Executable path or identity<input required value={draft.trigger} onChange={event => setDraft({ ...draft, trigger: event.target.value })} placeholder="C:\\Apps\\Example.exe" /></label>
      <label style={field}>Writing tone<select value={draft.tone} onChange={event => setDraft({ ...draft, tone: event.target.value })}>{tones.map(tone => <option key={tone}>{tone}</option>)}</select></label>{appError && <p role="alert">{appError}</p>}
    </> : <><label style={field}>{draft.kind === "snippet" ? "When I say" : "Usually transcribed as"}<input required value={draft.trigger} onChange={event => setDraft({ ...draft, trigger: event.target.value })} /></label><label style={field}>{draft.kind === "snippet" ? "Insert this exact text" : "Replace with"}<textarea rows={draft.kind === "snippet" ? 6 : 2} required value={draft.replacement} onChange={event => setDraft({ ...draft, replacement: event.target.value })} /></label></>}
    <div style={{ display: "flex", justifyContent: "flex-end", gap: 8 }}><button type="button" onClick={onClose}>Cancel</button><button type="submit">{busy ? "Saving..." : "Save"}</button></div>
  </fieldset>{error && <p role="alert">{error}</p>}</form></SettingsDialog>;
}
