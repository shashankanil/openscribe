import React, { useEffect, useId, useRef } from "react";
import { createPortal } from "react-dom";
export const settingsBox: React.CSSProperties = { background: "var(--os-surface)", border: "1px solid var(--os-line)", borderRadius: 12, padding: 20, display: "flex", flexDirection: "column", gap: 14 };
export const settingsField: React.CSSProperties = { display: "flex", flexDirection: "column", gap: 6, fontSize: 13 };
export function SettingsDialog({ title, children, onClose, busy = false }: { title: string; children: React.ReactNode; onClose: () => void; busy?: boolean }) {
  const ref = useRef<HTMLDialogElement>(null);
  const id = useId();
  useEffect(() => { const previous = document.activeElement as HTMLElement | null; ref.current?.showModal(); return () => { ref.current?.close(); previous?.focus(); }; }, []);
  return createPortal(<dialog ref={ref} className="modal" aria-labelledby={id} onCancel={event => { event.preventDefault(); if (!busy) onClose(); }} style={{ position: "fixed", inset: 0, margin: "auto", background: "var(--os-background)", color: "var(--os-ink)", border: "1px solid var(--os-line)", borderRadius: 16, padding: 24, width: "min(580px, 90vw)", maxHeight: "85vh", overflow: "auto" }}>
    <h2 id={id} style={{ marginTop: 0 }}>{title}</h2>{children}
  </dialog>, document.body);
}
