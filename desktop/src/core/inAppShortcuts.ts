export type WorkspaceSectionTarget = 'notes' | 'meetings' | 'calendar';

export type WorkspaceAction =
  | { type: 'navigate'; section: WorkspaceSectionTarget }
  | { type: 'openSettings' };

export type NotesAction =
  | { type: 'newNote' }
  | { type: 'searchNotes' }
  | { type: 'todayNote' };

export type InAppAction = WorkspaceAction | NotesAction;

export interface KeyboardShortcutEvent {
  key: string;
  code?: string;
  ctrlKey?: boolean;
  metaKey?: boolean;
  altKey?: boolean;
  shiftKey?: boolean;
  target?: unknown;
}

export interface ShortcutContext {
  modalOpen?: boolean;
  isNotesVisible?: boolean;
  activeSection?: 'notes' | 'meetings' | 'calendar' | 'settings';
}

/**
 * Returns true if an element is an editable target (input, textarea, contenteditable)
 * where ordinary text typing occurs.
 */
export function isEditableElement(target: unknown): boolean {
  if (!target || typeof target !== 'object') return false;
  const el = target as {
    tagName?: string;
    isContentEditable?: boolean;
    type?: string;
    closest?: (selector: string) => unknown;
  };
  const tag = el.tagName?.toUpperCase();
  if (tag === 'TEXTAREA') return true;
  if (tag === 'INPUT') {
    const type = (el.type || '').toLowerCase();
    if (['button', 'checkbox', 'radio', 'submit', 'reset', 'image', 'file', 'range', 'color'].includes(type)) {
      return false;
    }
    return true;
  }
  if (el.isContentEditable) return true;
  if (typeof el.closest === 'function') {
    try {
      if (el.closest('[contenteditable]')) {
        const ce = el.closest('[contenteditable]') as { getAttribute?: (attr: string) => string | null };
        const val = ce.getAttribute ? ce.getAttribute('contenteditable') : null;
        if (val !== 'false') return true;
      }
    } catch {
      // ignore
    }
  }
  return false;
}

export function isUserTyping(event: KeyboardShortcutEvent): boolean {
  if (isEditableElement(event.target)) return true;
  if (typeof document !== 'undefined' && document.activeElement && isEditableElement(document.activeElement)) {
    return true;
  }
  return false;
}

export function isModalActive(context?: { modalOpen?: boolean }): boolean {
  if (context?.modalOpen != null) return context.modalOpen;
  if (typeof document !== 'undefined') {
    return Boolean(document.querySelector('[aria-modal], dialog[open]'));
  }
  return false;
}

function hasPrimaryModifier(event: KeyboardShortcutEvent): boolean {
  const hasMod = Boolean(event.ctrlKey || event.metaKey);
  const noExtra = !event.altKey && !event.shiftKey;
  return hasMod && noExtra;
}

/**
 * Resolves workspace navigation shortcuts:
 * - Ctrl+1: Notes (Sources/OpenScribe/MainWorkspaceView.swift:197)
 * - Ctrl+2: Meetings (Sources/OpenScribe/MainWorkspaceView.swift:197)
 * - Ctrl+3: Calendar (Sources/OpenScribe/MainWorkspaceView.swift:197)
 * - Ctrl+,: Settings (Sources/OpenScribe/OpenScribeApp.swift:12)
 */
export function matchWorkspaceShortcut(
  event: KeyboardShortcutEvent,
  context?: { modalOpen?: boolean }
): WorkspaceAction | null {
  if (!hasPrimaryModifier(event)) return null;
  if (isModalActive(context)) return null;
  if (isUserTyping(event)) return null;

  const key = event.key;
  const code = event.code;

  if (key === '1' || code === 'Digit1' || code === 'Numpad1') {
    return { type: 'navigate', section: 'notes' };
  }
  if (key === '2' || code === 'Digit2' || code === 'Numpad2') {
    return { type: 'navigate', section: 'meetings' };
  }
  if (key === '3' || code === 'Digit3' || code === 'Numpad3') {
    return { type: 'navigate', section: 'calendar' };
  }
  if (key === ',' || code === 'Comma') {
    return { type: 'openSettings' };
  }

  return null;
}

/**
 * Resolves in-notes shortcuts:
 * - Ctrl+N: New note (Sources/OpenScribe/NotesView.swift:158)
 * - Ctrl+F: Search notes (Sources/OpenScribe/NotesView.swift:159) - allowed even while typing in an input
 * - Ctrl+T: Today (Sources/OpenScribe/NotesView.swift:160)
 */
export function matchNotesShortcut(
  event: KeyboardShortcutEvent,
  context?: { modalOpen?: boolean; isNotesVisible?: boolean }
): NotesAction | null {
  if (context?.isNotesVisible === false) return null;
  if (!hasPrimaryModifier(event)) return null;
  if (isModalActive(context)) return null;

  const key = event.key?.toLowerCase();
  const code = event.code;

  if (key === 'f' || code === 'KeyF') {
    return { type: 'searchNotes' };
  }

  if (isUserTyping(event)) return null;

  if (key === 'n' || code === 'KeyN') {
    return { type: 'newNote' };
  }
  if (key === 't' || code === 'KeyT') {
    return { type: 'todayNote' };
  }

  return null;
}
