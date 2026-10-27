import React, { useState } from "react";
import { X } from "lucide-react";
import type { MeetingRecord, MeetingSegment } from "../api/parityTypes";

interface NoticeBubbleProps {
  notice?: string | null;
  isError?: boolean;
  shortMeeting?: MeetingRecord | null;
  onDismissNotice: () => void;
  onInspectNotice?: () => void;
  onResolveShortMeeting: (action: "summarize" | "keep" | "delete") => void;
}

export const NoticeBubble: React.FC<NoticeBubbleProps> = ({
  notice,
  isError = false,
  shortMeeting,
  onDismissNotice,
  onInspectNotice,
  onResolveShortMeeting
}) => {
  const [hoveredButton, setHoveredButton] = useState<string | null>(null);
  const [dismissHover, setDismissHover] = useState(false);

  if (shortMeeting) {
    const wordCount = shortMeeting.segments.reduce(
      (acc: number, s: MeetingSegment) =>
        acc + s.text.trim().split(/\s+/).filter(Boolean).length,
      0
    );
    return (
      <div
        style={{
          background: "var(--os-flowbar)",
          border: "1px solid var(--os-flowbar-line)",
          borderRadius: 12,
          padding: "9px 11px",
          color: "var(--os-flowbar-ink)",
          boxShadow: "var(--os-flowbar-shadow)",
          display: "flex",
          flexDirection: "column",
          gap: 6,
          maxWidth: 280,
          pointerEvents: "auto"
        }}
      >
        <div style={{ display: "flex", alignItems: "center", gap: 6 }}>
          <span
            style={{
              width: 6,
              height: 6,
              borderRadius: "50%",
              background: "var(--os-flowbar-accent)",
              flexShrink: 0
            }}
          />
          <span style={{ fontSize: 11.5, fontWeight: 500 }}>
            {wordCount === 0
              ? "That meeting had almost no speech."
              : `That meeting was very short (${wordCount} words).`}
          </span>
        </div>
        <span style={{ fontSize: 11, color: "var(--os-flowbar-ink-muted)" }}>
          Started by mistake? Summarize only if you need it.
        </span>
        <div style={{ display: "flex", gap: 6, marginTop: 2 }}>
          <button
            onClick={() => onResolveShortMeeting("summarize")}
            onMouseEnter={() => setHoveredButton("summarize")}
            onMouseLeave={() => setHoveredButton(null)}
            style={{
              background: "var(--os-flowbar-accent)",
              color: "var(--os-flowbar)",
              border: "none",
              borderRadius: 999,
              padding: "3px 9px",
              fontSize: 11,
              fontWeight: 600,
              cursor: "pointer",
              opacity: hoveredButton === "summarize" ? 0.9 : 1,
              transition: "opacity 0.12s ease"
            }}
          >
            Summarize
          </button>
          <button
            onClick={() => onResolveShortMeeting("keep")}
            onMouseEnter={() => setHoveredButton("keep")}
            onMouseLeave={() => setHoveredButton(null)}
            style={{
              background:
                hoveredButton === "keep"
                  ? "var(--os-flowbar-hover)"
                  : "var(--os-flowbar-surface)",
              color: "var(--os-flowbar-ink)",
              border: "none",
              borderRadius: 999,
              padding: "3px 9px",
              fontSize: 11,
              fontWeight: 500,
              cursor: "pointer",
              transition: "background 0.12s ease"
            }}
          >
            Keep
          </button>
          <button
            onClick={() => onResolveShortMeeting("delete")}
            onMouseEnter={() => setHoveredButton("delete")}
            onMouseLeave={() => setHoveredButton(null)}
            style={{
              background:
                hoveredButton === "delete"
                  ? "var(--os-flowbar-active)"
                  : "var(--os-flowbar-recording-soft)",
              color: "var(--os-flowbar-recording)",
              border: "none",
              borderRadius: 999,
              padding: "3px 9px",
              fontSize: 11,
              fontWeight: 500,
              cursor: "pointer",
              transition: "background 0.12s ease"
            }}
          >
            Delete
          </button>
        </div>
      </div>
    );
  }

  if (notice) {
    return (
      <div
        onClick={onInspectNotice}
        role={onInspectNotice ? "button" : "status"}
        tabIndex={onInspectNotice ? 0 : undefined}
        onKeyDown={event => {
          if (onInspectNotice && (event.key === "Enter" || event.key === " ")) { event.preventDefault(); onInspectNotice(); }
        }}
        style={{
          background: "var(--os-flowbar)",
          border: "1px solid var(--os-flowbar-line)",
          borderRadius: 11,
          padding: "7px 10px",
          color: "var(--os-flowbar-ink)",
          boxShadow: "var(--os-flowbar-shadow)",
          display: "flex",
          alignItems: "center",
          gap: 8,
          maxWidth: 280,
          cursor: onInspectNotice ? "pointer" : "default",
          pointerEvents: "auto"
        }}
      >
        <span
          style={{
            width: 6,
            height: 6,
            borderRadius: "50%",
            background: isError ? "var(--os-flowbar-accent)" : "var(--os-flowbar-success)",
            flexShrink: 0
          }}
        />
        <span
          title={notice}
          style={{
            fontSize: 11.5,
            fontWeight: 500,
            lineHeight: 1.35,
            // Wrap instead of cutting the message off; macOS allows two lines, Windows messages run longer.
            display: "-webkit-box",
            WebkitBoxOrient: "vertical",
            WebkitLineClamp: 3,
            overflow: "hidden",
            overflowWrap: "anywhere",
            flex: 1
          }}
        >
          {notice}
        </span>
        <button
          onClick={(e) => {
            e.stopPropagation();
            onDismissNotice();
          }}
          onKeyDown={event => event.stopPropagation()}
          aria-label="Dismiss notice"
          title="Dismiss"
          onMouseEnter={() => setDismissHover(true)}
          onMouseLeave={() => setDismissHover(false)}
          style={{
            background: dismissHover ? "var(--os-flowbar-hover)" : "transparent",
            border: "none",
            borderRadius: 4,
            color: dismissHover ? "var(--os-flowbar-ink)" : "var(--os-flowbar-ink-faint)",
            cursor: "pointer",
            padding: 2,
            display: "flex",
            alignItems: "center",
            transition: "all 0.12s ease"
          }}
        >
          <X size={12} />
        </button>
      </div>
    );
  }

  return null;
};
