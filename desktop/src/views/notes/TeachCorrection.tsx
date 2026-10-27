import React, { useEffect, useRef, useState } from "react";
import { emitTo, listen } from "@tauri-apps/api/event";
import { reportUiError } from "../../workspaceEvents";
import { requestCorrectionSave, type CorrectionResult } from "./correctionRequest";

export function TeachCorrection({ onClose }: { onClose: () => void }) {
  const dialog = useRef<HTMLDialogElement>(null);
  const [heard, setHeard] = useState("");
  const [replacement, setReplacement] = useState("");
  const [busy, setBusy] = useState(false);
  const [failure, setFailure] = useState("");
  const pending = useRef<AbortController | null>(null);
  useEffect(() => {
    dialog.current?.showModal();
    return () => { pending.current?.abort(); dialog.current?.close(); };
  }, []);
  const close = () => { pending.current?.abort(); onClose(); };
  const teach = async (event: React.FormEvent) => {
    event.preventDefault();
    if (!heard.trim() || !replacement.trim() || busy) return;
    const controller = new AbortController();
    pending.current = controller;
    setFailure("");
    setBusy(true);
    try {
      await requestCorrectionSave({ requestId: crypto.randomUUID(), heard: heard.trim(), replacement: replacement.trim() }, {
        subscribe: handler => listen<CorrectionResult>("workspace://correction-result", event => handler(event.payload)),
        send: request => emitTo("main", "workspace://teach-correction", request)
      }, controller.signal);
      if (!controller.signal.aborted) onClose();
    } catch (error) {
      if (!controller.signal.aborted) { setFailure(String(error)); reportUiError(error); }
    } finally {
      if (pending.current === controller) pending.current = null;
      if (!controller.signal.aborted) setBusy(false);
    }
  };
  return <dialog ref={dialog} aria-modal="true" aria-label="Teach a correction" onCancel={close} style={{ width: 450, maxWidth: "90vw", border: "1px solid var(--os-line)", borderRadius: 14, padding: 24, background: "var(--os-background)", color: "var(--os-ink)" }}>
    <form onSubmit={event => { void teach(event); }}>
      <h2>Teach a correction</h2>
      <p>Use this replacement when this phrase is heard again.</p>
      <p><label>Heard <input autoFocus required disabled={busy} value={heard} onChange={event => setHeard(event.target.value)} /></label></p>
      <p><label>Replacement <input required disabled={busy} value={replacement} onChange={event => setReplacement(event.target.value)} /></label></p>
      {failure && <p role="alert">{failure}</p>}
      <button type="button" onClick={close}>Cancel</button>{" "}
      <button disabled={busy || !heard.trim() || !replacement.trim()} type="submit">{busy ? "Saving…" : "Teach correction"}</button>
    </form>
  </dialog>;
}
