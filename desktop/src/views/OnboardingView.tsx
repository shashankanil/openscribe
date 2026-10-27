import React, { useCallback, useEffect, useReducer, useRef, useState } from "react";
import { listen } from "@tauri-apps/api/event";
import type { ParitySettings } from "../api/parityTypes";
import { native, speechAccount, writingAccount } from "../native";
import { sendIntent } from "../workspaceEvents";
import { ProviderConnectionCard } from "./settings/ProvidersSettings";
import { PermissionsView } from "./settings/PermissionsView";
import { settingsBox } from "./settings/SettingsDialog";
import { canPractice, settingsNative, type CaptureReadiness, type SaveSettings } from "./settings/settingsSupport";
import { initialPractice, practiceFeedback, practiceTranscript } from "./settings/practiceFeedback";
import { readSetupReadiness } from "./settings/setupReadiness";

export interface OnboardingViewProps {
  settings: ParitySettings;
  onUpdateSettings: SaveSettings;
  onComplete: () => void | Promise<void>;
  onLater: () => void | Promise<void>;
  phase?: string;
  transcript?: string;
  captureHint?: string;
}

export function OnboardingView({ settings, onUpdateSettings, onComplete, onLater, phase = "idle", transcript = "", captureHint = "" }: OnboardingViewProps) {
  const [step, setStep] = useState(0);
  const [keySaved, setKeySaved] = useState(false);
  const [readiness, setReadiness] = useState<CaptureReadiness | null>(null);
  const [error, setError] = useState("");
  const [working, setWorking] = useState(false);
  const [practice, dispatchPractice] = useReducer(practiceFeedback, initialPractice);
  const [feedbackReady, setFeedbackReady] = useState(false);
  const [login, setLogin] = useState<boolean | null>(null);
  const previousPhase = useRef(phase);
  const recording = phase === "recording";
  const captureBusy = !["idle", "error", "done"].includes(phase);

  const refreshKey = useCallback(async () => {
    try { setKeySaved(await native.hasCredential(speechAccount(settings))); }
    catch (failure) { setKeySaved(false); setError(String(failure)); }
  }, [settings.speechProvider, settings.speechBaseURL]);
  useEffect(() => { void refreshKey(); }, [refreshKey]);
  useEffect(() => {
    let active = true;
    void settingsNative.getLaunchAtLogin().then(value => { if (active) setLogin(value); }).catch(failure => { if (active) setError(String(failure)); });
    return () => { active = false; };
  }, []);

  const checkReadiness = useCallback(async () => {
    try {
      const result = await readSetupReadiness(settings.pasteIntoFocusedApp,
        () => native.hasCredential(speechAccount(settings)), settingsNative.captureReadiness);
      setKeySaved(result.hasKey); setReadiness(result.readiness);
      return result;
    } catch (failure) { setReadiness(null); throw failure; }
  }, [settings.speechProvider, settings.speechBaseURL, settings.pasteIntoFocusedApp]);

  // Access already refreshes on focus. Recheck on Try it too, after a device or privacy change.
  useEffect(() => {
    if (step !== 3) return;
    const refresh = () => { void checkReadiness().catch(failure => setError(String(failure))); };
    refresh();
    window.addEventListener("focus", refresh);
    return () => window.removeEventListener("focus", refresh);
  }, [step, checkReadiness]);

  useEffect(() => {
    if (step !== 3) return;
    let active = true;
    setFeedbackReady(false);
    let unlisten: (() => void) | undefined;
    // Only the controller's completed save can establish success; idle and dispatch cannot.
    void listen<{ message: string; id: string }>("workspace://confirmation", event => {
      if (active) dispatchPractice({ type: "confirmation", message: event.payload.message });
    }).then(stop => {
      if (!active) { stop(); return; }
      unlisten = stop; setFeedbackReady(true);
    }).catch(failure => { if (active) { setFeedbackReady(false); setError(String(failure)); } });
    return () => { active = false; unlisten?.(); };
  }, [step]);

  useEffect(() => {
    if (step === 3) {
      if (["idle", "error", "done"].includes(previousPhase.current) && ["starting", "recording"].includes(phase)) {
        dispatchPractice({ type: "request", transcript, hint: captureHint });
      }
      dispatchPractice({ type: "phase", phase, transcript, hint: captureHint });
    }
    previousPhase.current = phase;
  }, [phase, transcript, captureHint, step]);

  const run = async (action: () => void | Promise<void>) => {
    setWorking(true); setError("");
    try { await action(); }
    catch (failure) { setError(String(failure)); }
    finally { setWorking(false); }
  };
  const requireReadiness = async () => {
    const result = await checkReadiness();
    if (!result.hasKey) throw new Error("Connect a transcription provider or choose Set up later.");
    if (!result.ready) throw new Error("Check microphone and paste readiness, or use Notes only.");
  };
  const ready = canPractice(readiness, keySaved, settings.pasteIntoFocusedApp);
  const advance = () => { void run(async () => {
    if (step === 1) {
      const saved = await native.hasCredential(speechAccount(settings)); setKeySaved(saved);
      if (!saved) throw new Error("Connect a transcription provider or choose Set up later.");
      if (!await native.hasCredential(writingAccount(settings)) && settings.cleanupEnabled) await onUpdateSettings({ ...settings, cleanupEnabled: false });
    }
    if (step >= 2) await requireReadiness();
    if (step === 3) { if (login !== null) await settingsNative.setLaunchAtLogin(login); await onComplete(); }
    else setStep(value => value + 1);
  }); };
  const tryRecording = () => { void run(async () => {
    if (!recording) {
      dispatchPractice({ type: "request", transcript, hint: captureHint });
      try { await requireReadiness(); }
      catch (failure) { dispatchPractice({ type: "failure" }); throw failure; }
    }
    try { await sendIntent({ action: "dictate" }); }
    catch (failure) { dispatchPractice({ type: "failure" }); throw failure; }
  }); };
  const cancelRecording = () => { void run(async () => {
    dispatchPractice({ type: "cancel" });
    try { await sendIntent({ action: "cancelDictation" }); }
    catch (failure) { dispatchPractice({ type: "failure" }); throw failure; }
  }); };
  const savedTranscript = practiceTranscript(practice, transcript);

  return <main style={{ height: "100%", overflowY: "auto", background: "var(--os-background)", color: "var(--os-ink)", padding: 32 }}>
    <header style={{ display: "flex", justifyContent: "space-between", marginBottom: 28 }}>
      <strong>OpenScribe</strong><button disabled={working || captureBusy} onClick={() => { void run(onLater); }}>Set up later</button>
    </header>
    <section style={{ ...settingsBox, maxWidth: 720, margin: "0 auto", padding: 28 }}>
      <ol aria-label="Setup progress" style={{ display: "flex", justifyContent: "space-between", gap: 16 }}>
        {["Welcome", "Connect", "Access", "Try it"].map((title, index) => <li key={title} aria-current={index === step ? "step" : undefined} style={{ fontWeight: index === step ? 700 : 400 }}>{title}</li>)}
      </ol>
      {step === 0 && <>
        <h1>A thought. A breath.<br />The words are there.</h1>
        <p>Speak naturally. OpenScribe turns your voice into writing, right where you work.</p>
        <p>Use a shortcut to dictate, record meetings, and keep your notes locally. Bring your own provider keys.</p>
      </>}
      {step === 1 && <>
        <h1>Connect your voice</h1><p>Add a transcription provider to turn recordings into notes.</p>
        <ProviderConnectionCard purpose="speech" settings={settings} onUpdateSettings={onUpdateSettings} onCredentialChange={() => { void refreshKey(); }} />
        <p>Recordings go directly to your chosen provider. Writing cleanup is optional and can be configured later.</p>
        <small role="status">{keySaved ? "Transcription key saved" : "A transcription key is required to continue"}</small>
      </>}
      {step === 2 && <>
        <h1>A little access. A lot less typing.</h1><PermissionsView onReadinessChange={setReadiness} />
        {!readiness?.paste.ready && <button disabled={working} onClick={() => { void run(() => onUpdateSettings({ ...settings, pasteIntoFocusedApp: false })); }}>{settings.pasteIntoFocusedApp ? "Use Notes only for now" : "Notes-only mode selected"}</button>}
      </>}
      {step === 3 && <>
        <h1>Make your first note</h1><p>Try "This is my first note in OpenScribe." Successfully processed recordings appear in Notes.</p>
        <button disabled={working || (!recording && (captureBusy || !ready || !feedbackReady))} onClick={tryRecording}>{recording ? "Stop & save" : "Try a recording"}</button>
        {captureHint && <p role="status">{captureHint}</p>}
        {captureBusy && <button disabled={working} onClick={cancelRecording}>Cancel recording</button>}
        {practice.status === "saved" && <p role="status">Practice note saved.</p>}
        {practice.status === "cancelled" && !captureBusy && <p role="status">Practice cancelled. No saved result has been confirmed.</p>}
        {practice.status === "failed" && <p role="status">Practice reported a problem. Check the message and Notes before trying again.</p>}
        {practice.status === "ended" && <p role="status">Recording ended. Waiting for save confirmation.</p>}
        {savedTranscript && <p style={{ whiteSpace: "pre-wrap" }}>{savedTranscript}</p>}
        <p>{settings.shortcuts.dictate?.display ?? "Set a shortcut in Settings > Shortcuts"}. Tap to start and stop, or hold to talk.</p>
        {!ready && <button disabled={working} onClick={() => { void run(requireReadiness); }}>Recheck setup readiness</button>}
        {login !== null && <label><input type="checkbox" checked={login} disabled={working} onChange={event => setLogin(event.target.checked)} /> Launch OpenScribe when I log in</label>}
      </>}
      {error && <p role="alert">{error}</p>}
      <footer style={{ display: "flex", justifyContent: "space-between", gap: 12, marginTop: 16 }}>
        {step > 0 ? <button disabled={working || captureBusy} onClick={() => { setError(""); setStep(value => value - 1); }}>Back</button> : <span />}
        <div>
          {step === 3 && <button disabled={working || captureBusy} onClick={advance}>Skip practice</button>}{" "}
          <button disabled={working || captureBusy || (step === 1 && !keySaved) || (step >= 2 && !ready)} onClick={advance}>{working ? "Working..." : step === 0 ? "Let's get started" : step === 3 ? "Start using OpenScribe" : "Continue"}</button>
        </div>
      </footer>
    </section><p style={{ textAlign: "center", marginTop: 24 }}>Your voice. Your providers. Your Windows PC.</p>
  </main>;
}
