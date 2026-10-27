import React, { useEffect, useRef, useState } from "react";

export interface LibraryAction { label: string; run: () => void; disabled?: boolean }
export function LibraryContextMenu({ children, actions }: { children: React.ReactNode; actions: LibraryAction[] }) {
  const [position, setPosition] = useState<{ x: number; y: number } | null>(null);
  const menu = useRef<HTMLDivElement>(null);
  useEffect(() => { if (position) menu.current?.querySelector<HTMLButtonElement>("button")?.focus(); }, [position]);
  return <div onContextMenu={event => { event.preventDefault(); setPosition({ x: Math.min(event.clientX, window.innerWidth - 230), y: Math.min(event.clientY, window.innerHeight - actions.length * 36 - 16) }); }}>
    {children}
    {position && <div ref={menu} role="menu" aria-label="Actions" onBlur={event => { if (!event.currentTarget.contains(event.relatedTarget)) setPosition(null); }} onKeyDown={event => { if (event.key === "Escape") { event.stopPropagation(); setPosition(null); } }} style={{ position: "fixed", left: position.x, top: Math.max(8, position.y), zIndex: 100, padding: 6, minWidth: 210, background: "var(--os-surface)", border: "1px solid var(--os-line)", borderRadius: 8, boxShadow: "var(--os-shadow)" }}>
      {actions.map(action => <button key={action.label} role="menuitem" disabled={action.disabled} onClick={() => { setPosition(null); action.run(); }} style={{ display: "block", width: "100%", textAlign: "left", background: "transparent", color: "var(--os-ink)", border: 0, padding: 8 }}>{action.label}</button>)}
    </div>}
  </div>;
}
