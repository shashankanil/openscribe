import { describe, it, expect } from 'vitest';
import {
  matchWorkspaceShortcut,
  matchNotesShortcut,
  isEditableElement,
  isUserTyping,
} from './inAppShortcuts';

describe('in-app keyboard shortcuts', () => {
  describe('workspace navigation shortcuts (Ctrl+1, Ctrl+2, Ctrl+3, Ctrl+,)', () => {
    it('matches Ctrl+1 to navigate to notes (MainWorkspaceView.swift:197)', () => {
      const action = matchWorkspaceShortcut({ key: '1', ctrlKey: true, altKey: false, shiftKey: false });
      expect(action).toEqual({ type: 'navigate', section: 'notes' });
    });

    it('matches Ctrl+2 to navigate to meetings (MainWorkspaceView.swift:197)', () => {
      const action = matchWorkspaceShortcut({ key: '2', ctrlKey: true, altKey: false, shiftKey: false });
      expect(action).toEqual({ type: 'navigate', section: 'meetings' });
    });

    it('matches Ctrl+3 to navigate to calendar (MainWorkspaceView.swift:197)', () => {
      const action = matchWorkspaceShortcut({ key: '3', ctrlKey: true, altKey: false, shiftKey: false });
      expect(action).toEqual({ type: 'navigate', section: 'calendar' });
    });

    it('matches Ctrl+, to open settings (OpenScribeApp.swift:12)', () => {
      const action = matchWorkspaceShortcut({ key: ',', ctrlKey: true, altKey: false, shiftKey: false });
      expect(action).toEqual({ type: 'openSettings' });
    });

    it('supports code fallbacks (Digit1, Digit2, Digit3, Comma)', () => {
      expect(matchWorkspaceShortcut({ key: 'Unidentified', code: 'Digit1', ctrlKey: true, altKey: false, shiftKey: false })).toEqual({ type: 'navigate', section: 'notes' });
      expect(matchWorkspaceShortcut({ key: 'Unidentified', code: 'Digit2', ctrlKey: true, altKey: false, shiftKey: false })).toEqual({ type: 'navigate', section: 'meetings' });
      expect(matchWorkspaceShortcut({ key: 'Unidentified', code: 'Digit3', ctrlKey: true, altKey: false, shiftKey: false })).toEqual({ type: 'navigate', section: 'calendar' });
      expect(matchWorkspaceShortcut({ key: 'Unidentified', code: 'Comma', ctrlKey: true, altKey: false, shiftKey: false })).toEqual({ type: 'openSettings' });
    });

    it('supports Cmd key on macOS (metaKey)', () => {
      const action = matchWorkspaceShortcut({ key: '1', metaKey: true, ctrlKey: false, altKey: false, shiftKey: false });
      expect(action).toEqual({ type: 'navigate', section: 'notes' });
    });

    it('ignores events without Ctrl/Cmd', () => {
      expect(matchWorkspaceShortcut({ key: '1', ctrlKey: false, altKey: false, shiftKey: false })).toBeNull();
      expect(matchWorkspaceShortcut({ key: '2', ctrlKey: false, altKey: false, shiftKey: false })).toBeNull();
      expect(matchWorkspaceShortcut({ key: '3', ctrlKey: false, altKey: false, shiftKey: false })).toBeNull();
      expect(matchWorkspaceShortcut({ key: ',', ctrlKey: false, altKey: false, shiftKey: false })).toBeNull();
    });

    it('ignores events with Alt or Shift modifier', () => {
      expect(matchWorkspaceShortcut({ key: '1', ctrlKey: true, altKey: true, shiftKey: false })).toBeNull();
      expect(matchWorkspaceShortcut({ key: '1', ctrlKey: true, altKey: false, shiftKey: true })).toBeNull();
    });

    it('does not fire when modal is active', () => {
      const action = matchWorkspaceShortcut({ key: '1', ctrlKey: true, altKey: false, shiftKey: false }, { modalOpen: true });
      expect(action).toBeNull();
    });

    it('does not fire while typing in an input, textarea or contenteditable', () => {
      const inputTarget = { tagName: 'INPUT', type: 'text' };
      const textareaTarget = { tagName: 'TEXTAREA' };
      const editableTarget = { isContentEditable: true };

      expect(matchWorkspaceShortcut({ key: '1', ctrlKey: true, altKey: false, shiftKey: false, target: inputTarget })).toBeNull();
      expect(matchWorkspaceShortcut({ key: '2', ctrlKey: true, altKey: false, shiftKey: false, target: textareaTarget })).toBeNull();
      expect(matchWorkspaceShortcut({ key: '3', ctrlKey: true, altKey: false, shiftKey: false, target: editableTarget })).toBeNull();
      expect(matchWorkspaceShortcut({ key: ',', ctrlKey: true, altKey: false, shiftKey: false, target: textareaTarget })).toBeNull();
    });
  });

  describe('in-notes shortcuts (Ctrl+N, Ctrl+F, Ctrl+T)', () => {
    it('matches Ctrl+N to create a new note (NotesView.swift:158)', () => {
      const action = matchNotesShortcut({ key: 'n', ctrlKey: true, altKey: false, shiftKey: false });
      expect(action).toEqual({ type: 'newNote' });
    });

    it('matches Ctrl+F to search notes (NotesView.swift:159)', () => {
      const action = matchNotesShortcut({ key: 'f', ctrlKey: true, altKey: false, shiftKey: false });
      expect(action).toEqual({ type: 'searchNotes' });
    });

    it('matches Ctrl+T to open today note (NotesView.swift:160)', () => {
      const action = matchNotesShortcut({ key: 't', ctrlKey: true, altKey: false, shiftKey: false });
      expect(action).toEqual({ type: 'todayNote' });
    });

    it('allows Ctrl+F even while typing in an input, textarea or contenteditable', () => {
      const inputTarget = { tagName: 'INPUT', type: 'text' };
      const textareaTarget = { tagName: 'TEXTAREA' };
      const editableTarget = { isContentEditable: true };

      expect(matchNotesShortcut({ key: 'f', ctrlKey: true, altKey: false, shiftKey: false, target: inputTarget })).toEqual({ type: 'searchNotes' });
      expect(matchNotesShortcut({ key: 'f', ctrlKey: true, altKey: false, shiftKey: false, target: textareaTarget })).toEqual({ type: 'searchNotes' });
      expect(matchNotesShortcut({ key: 'f', ctrlKey: true, altKey: false, shiftKey: false, target: editableTarget })).toEqual({ type: 'searchNotes' });
    });

    it('blocks Ctrl+N and Ctrl+T while typing in an editable element', () => {
      const textareaTarget = { tagName: 'TEXTAREA' };
      expect(matchNotesShortcut({ key: 'n', ctrlKey: true, altKey: false, shiftKey: false, target: textareaTarget })).toBeNull();
      expect(matchNotesShortcut({ key: 't', ctrlKey: true, altKey: false, shiftKey: false, target: textareaTarget })).toBeNull();
    });

    it('does not fire notes shortcuts when isNotesVisible is false', () => {
      expect(matchNotesShortcut({ key: 'n', ctrlKey: true, altKey: false, shiftKey: false }, { isNotesVisible: false })).toBeNull();
      expect(matchNotesShortcut({ key: 'f', ctrlKey: true, altKey: false, shiftKey: false }, { isNotesVisible: false })).toBeNull();
      expect(matchNotesShortcut({ key: 't', ctrlKey: true, altKey: false, shiftKey: false }, { isNotesVisible: false })).toBeNull();
    });

    it('does not fire when modal is active', () => {
      expect(matchNotesShortcut({ key: 'n', ctrlKey: true, altKey: false, shiftKey: false }, { modalOpen: true })).toBeNull();
      expect(matchNotesShortcut({ key: 'f', ctrlKey: true, altKey: false, shiftKey: false }, { modalOpen: true })).toBeNull();
    });
  });

  describe('isEditableElement & isUserTyping', () => {
    it('identifies text inputs, textareas and contenteditable elements', () => {
      expect(isEditableElement({ tagName: 'INPUT', type: 'text' })).toBe(true);
      expect(isEditableElement({ tagName: 'INPUT', type: 'search' })).toBe(true);
      expect(isEditableElement({ tagName: 'INPUT' })).toBe(true);
      expect(isEditableElement({ tagName: 'TEXTAREA' })).toBe(true);
      expect(isEditableElement({ isContentEditable: true })).toBe(true);
    });

    it('rejects non-typing elements', () => {
      expect(isEditableElement({ tagName: 'INPUT', type: 'checkbox' })).toBe(false);
      expect(isEditableElement({ tagName: 'INPUT', type: 'button' })).toBe(false);
      expect(isEditableElement({ tagName: 'BUTTON' })).toBe(false);
      expect(isEditableElement({ tagName: 'DIV' })).toBe(false);
      expect(isEditableElement(null)).toBe(false);
    });

    it('detects user typing from event target', () => {
      expect(isUserTyping({ key: 'a', target: { tagName: 'TEXTAREA' } })).toBe(true);
      expect(isUserTyping({ key: 'a', target: { tagName: 'DIV' } })).toBe(false);
    });
  });
});
