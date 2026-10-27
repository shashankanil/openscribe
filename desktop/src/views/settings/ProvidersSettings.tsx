import React, { useEffect, useState } from "react";
import { openUrl } from "@tauri-apps/plugin-opener";
import type { ParitySettings } from "../../api/parityTypes";
import { modelPresets, providerDefaults, providers } from "../../defaults";
import { native, speechAccount, writingAccount } from "../../native";
import type { AudioInput } from "../../types";
import { keyProviderMismatch } from "./providerKeys";
import { SettingsDialog, settingsBox as box, settingsField as field } from "./SettingsDialog";
import { cleanupDescriptions, connectionValidation, tones, type SaveSettings } from "./settingsSupport";

type Purpose = "speech" | "writing";
const keyLinks: Record<string, string> = { openRouter: "https://openrouter.ai/settings/keys", openAI: "https://platform.openai.com/api-keys", groq: "https://console.groq.com/keys", deepgram: "https://console.deepgram.com/", assemblyAI: "https://www.assemblyai.com/dashboard/", mistral: "https://console.mistral.ai/", anthropic: "https://console.anthropic.com/settings/keys", google: "https://aistudio.google.com/apikey" };
export function ProviderForm({ purpose, settings, onUpdateSettings, onSaved }: { purpose: Purpose; settings: ParitySettings; onUpdateSettings: SaveSettings; onSaved: () => void }) {
  const providerKey = purpose === "speech" ? "speechProvider" : "languageModelProvider";
  const urlKey = purpose === "speech" ? "speechBaseURL" : "languageModelBaseURL";
  const modelKey = purpose === "speech" ? "speechModel" : "languageModel";
  const [provider, setProvider] = useState(settings[providerKey]);
  const [baseURL, setBaseURL] = useState(settings[urlKey]);
  const [model, setModel] = useState(settings[modelKey]);
  const [customModel, setCustomModel] = useState(!modelPresets(settings[providerKey], purpose).some(preset => preset.id === settings[modelKey]));
  const presets = modelPresets(provider, purpose);
  const [secret, setSecret] = useState("");
  const [hasKey, setHasKey] = useState(false);
  const [checking, setChecking] = useState(true);
  const [reuse, setReuse] = useState(false);
  const [otherHasKey, setOtherHasKey] = useState(false);
  const [message, setMessage] = useState("");
  const [busy, setBusy] = useState(false);
  const current = { ...settings, [providerKey]: provider, [urlKey]: baseURL.trim(), [modelKey]: model.trim() };
  const account = purpose === "speech" ? speechAccount(current) : writingAccount(current);
  const otherAccount = purpose === "speech" ? writingAccount(settings) : speechAccount(settings);
  const sameEndpoint = otherAccount.slice(otherAccount.indexOf(":")) === account.slice(account.indexOf(":"));
  useEffect(() => {
    let active = true; setSecret(""); setHasKey(false); setOtherHasKey(false); setReuse(false); setChecking(true); setMessage("");
    void Promise.all([native.hasCredential(account), sameEndpoint ? native.hasCredential(otherAccount) : Promise.resolve(false)])
      .then(([saved, other]) => { if (active) { setHasKey(saved); setOtherHasKey(other); } })
      .catch(error => { if (active) setMessage(String(error)); }).finally(() => { if (active) setChecking(false); });
    return () => { active = false; };
  }, [account, otherAccount, sameEndpoint]);
  const save = async () => {
    const validation = connectionValidation(baseURL, model);
    if (validation) { setMessage(validation); return; }
    const mismatch = !reuse && secret.trim() ? keyProviderMismatch(provider, secret) : null;
    if (mismatch) { setMessage(mismatch); return; }
    if (!secret.trim() && !hasKey && !reuse) { setMessage("Save a key or reuse your other connection's key."); return; }
    setBusy(true); setMessage("");
    try {
      if (reuse) await native.copyCredential(otherAccount, account);
      else if (secret.trim()) await native.saveCredential(account, secret.trim());
      await onUpdateSettings(current);
      setSecret(""); onSaved();
    } catch (error) { setMessage(String(error)); }
    finally { setBusy(false); }
  };
  return <SettingsDialog title={purpose === "speech" ? "Transcription connection" : "Writing connection"} onClose={onSaved} busy={busy}>
    <form style={{ display: "flex", flexDirection: "column", gap: 16 }} onSubmit={event => { event.preventDefault(); void save(); }}>
      <fieldset disabled={busy} style={{ border: 0, padding: 0, display: "flex", flexDirection: "column", gap: 14 }}>
        <label style={field}>Provider<select value={provider} onChange={event => { const id = event.target.value; const defaults = providerDefaults(id, purpose); setProvider(id); setBaseURL(defaults.baseUrl); setModel(defaults.model); setCustomModel(id === "custom"); }}>
          {providers.filter(choice => purpose === "speech" ? choice.speechModel : choice.writingModel).map(choice => <option key={choice.id} value={choice.id}>{choice.title}</option>)}
        </select></label>
        <label style={field}>Base URL<input type="url" required value={baseURL} onChange={event => setBaseURL(event.target.value)} /></label>
        <label style={field}>Model<select value={customModel ? "custom" : model} onChange={event => { const value = event.target.value; setCustomModel(value === "custom"); if (value !== "custom") setModel(value); }}>
          {presets.map(preset => <option key={preset.id} value={preset.id}>{preset.label}</option>)}<option value="custom">Custom model…</option>
        </select></label>
        {customModel && <label style={field}>Custom model ID<input required value={model} onChange={event => setModel(event.target.value)} /></label>}
        {provider !== "custom" && <button type="button" onClick={() => { setModel(providerDefaults(provider, purpose).model); setCustomModel(false); }}>Use economical preset</button>}
        {provider === "google" && purpose === "speech" && <small>Gemini transcribes saved audio chunks; live partial text is unavailable. Your language and script are preserved.</small>}
        {(provider === "google" || provider === "openAI") && <small>Economical defaults are selected for new connections. No automatic upgrade to a more expensive model. Prices and model access depend on the provider and account.</small>}
        <span>{checking ? "Checking saved keys..." : hasKey ? "A key is saved for this connection." : "API key required"}</span>
        <label style={field}>API key<input type="password" autoComplete="off" disabled={reuse} value={secret} onChange={event => setSecret(event.target.value)} placeholder={hasKey ? "Replacement key (optional)" : "Enter your key"} /></label>
        {otherHasKey && <label><input type="checkbox" checked={reuse} onChange={event => setReuse(event.target.checked)} />{purpose === "speech" ? "Use my saved writing key" : "Use my saved transcription key"}</label>}
        {keyLinks[provider] && <button type="button" onClick={() => { void openUrl(keyLinks[provider]).catch(failure => setMessage(String(failure))); }}>Get a provider key</button>}
        <small>Keys stay in Windows Credential Manager. Provider access is checked when you use it.</small>
        <div style={{ display: "flex", gap: 8, justifyContent: "flex-end" }}><button type="button" onClick={onSaved}>Cancel</button><button type="submit" disabled={checking || busy}>{busy ? "Saving..." : "Save connection"}</button></div>
      </fieldset>
      {message && <p role="alert">{message}</p>}
    </form>
  </SettingsDialog>;
}

export function ProviderConnectionCard({ purpose, settings, onUpdateSettings, onCredentialChange }: { purpose: Purpose; settings: ParitySettings; onUpdateSettings: SaveSettings; onCredentialChange?: () => void }) {
  const [editor, setEditor] = useState(false);
  const [remove, setRemove] = useState(false);
  const [hasKey, setHasKey] = useState<boolean | null>(null);
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);
  const [revision, setRevision] = useState(0);
  const account = purpose === "speech" ? speechAccount(settings) : writingAccount(settings);
  const provider = purpose === "speech" ? settings.speechProvider : settings.languageModelProvider;
  useEffect(() => { let active = true; setHasKey(null); setError(""); void native.hasCredential(account).then(value => { if (active) setHasKey(value); }).catch(failure => { if (active) setError(String(failure)); }); return () => { active = false; }; }, [account, revision]);
  const refreshed = () => { setEditor(false); setRevision(value => value + 1); onCredentialChange?.(); };
  return <section style={box}>
    <small>{purpose === "speech" ? "Transcription" : "Writing & summaries"}</small>
    <h3 style={{ margin: 0 }}>{providers.find(item => item.id === provider)?.title ?? provider}</h3>
    <span role="status">{hasKey === null ? error ? "Saved key status unavailable" : "Checking saved key..." : hasKey ? "API key saved" : "API key required"}</span>
    <small>MODEL</small><code>{purpose === "speech" ? settings.speechModel : settings.languageModel}</code>
    <div style={{ display: "flex", gap: 10 }}><button onClick={() => setEditor(true)}>{hasKey ? "Configure..." : "Connect provider..."}</button>{hasKey && <button onClick={() => setRemove(true)}>Remove API key...</button>}</div>
    {error && <p role="alert">{error}</p>}
    {editor && <ProviderForm purpose={purpose} settings={settings} onUpdateSettings={onUpdateSettings} onSaved={refreshed} />}
    {remove && <SettingsDialog title="Remove this API key?" busy={busy} onClose={() => setRemove(false)}><p>{purpose === "speech" ? "Transcription" : "Writing cleanup and meeting summaries"} will need a key before it can run again.</p><button disabled={busy} onClick={() => setRemove(false)}>Cancel</button> <button disabled={busy} onClick={() => { setBusy(true); void native.removeCredential(account).then(() => { setRemove(false); setHasKey(false); setError(""); onCredentialChange?.(); }).catch(failure => setError(String(failure))).finally(() => setBusy(false)); }}>Remove key</button>{error && <p role="alert">{error}</p>}</SettingsDialog>}
  </section>;
}
export function ProvidersSettings({ settings, onUpdateSettings }: { settings: ParitySettings; inputs?: AudioInput[]; onUpdateSettings: SaveSettings }) {
  const [error, setError] = useState("");
  const update = (next: ParitySettings) => { void Promise.resolve().then(() => onUpdateSettings(next)).then(() => setError("")).catch(failure => setError(String(failure))); };
  const toggle = (key: "meetingMicrophone" | "meetingSystemAudio" | "meetingSummarize" | "meetingLiveTranscription" | "dictationLiveTranscription" | "cleanupEnabled" | "saveRawAudio", title: string) => <label style={{ display: "flex", justifyContent: "space-between" }} key={key}>{title}<input type="checkbox" checked={settings[key]} onChange={event => update({ ...settings, [key]: event.target.checked })} /></label>;
  return <div style={{ display: "flex", flexDirection: "column", gap: 20 }}>
    <ProviderConnectionCard purpose="speech" settings={settings} onUpdateSettings={onUpdateSettings} />
    <ProviderConnectionCard purpose="writing" settings={settings} onUpdateSettings={onUpdateSettings} />
    <small>Each connection has its own model. Connections to the same provider and endpoint can reuse a saved key.</small>
    <section style={box}><h3>Transcription behavior</h3>{toggle("dictationLiveTranscription", "Live dictation transcription")}<small>{settings.dictationLiveTranscription ? "Audio is transcribed while recording." : "Audio is sent after you stop recording."}</small></section>
    <section style={box}><h3>Writing cleanup</h3>{toggle("cleanupEnabled", "Polish my transcripts")}
      <fieldset disabled={!settings.cleanupEnabled} style={{ border: 0, padding: 0 }}><legend>Cleanup strength</legend><div role="group" aria-label="Cleanup strength" style={{ display: "flex", gap: 8 }}>{(["light", "clear", "concise"] as const).map(strength => <button key={strength} aria-pressed={settings.cleanupStrength === strength} onClick={() => update({ ...settings, cleanupStrength: strength })}>{strength[0].toUpperCase() + strength.slice(1)}</button>)}</div><p>{cleanupDescriptions[settings.cleanupStrength]}</p>
      <label style={field}>Default tone<select value={settings.writingTone} onChange={event => update({ ...settings, writingTone: event.target.value as ParitySettings["writingTone"] })}>{tones.map(tone => <option key={tone}>{tone}</option>)}</select></label><small>Override this for individual apps in Personalization.</small></fieldset>
    </section>
    <section style={box}><h3>Meeting recording</h3>{toggle("meetingMicrophone", "Include microphone")}{toggle("meetingSystemAudio", "Include system audio")}{toggle("meetingSummarize", "Summarize on stop")}{toggle("meetingLiveTranscription", "Transcribe chunks while recording")}</section>
    {error && <p role="alert">{error}</p>}
  </div>;
}
