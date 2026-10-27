export type CaptureKind = "dictation" | "screenshot" | "meeting" | "text";
export interface NoteCapture {
  id: string; createdAt: string; title: string; rawText: string; text: string; duration: number;
  sourceApplication?: string | null; sourceBundleIdentifier?: string | null;
  kind?: CaptureKind | null; attachment?: string | null; meetingID?: string | null;
  recognizedText?: string | null; superseded?: boolean | null;
}
export interface VoiceNote {
  id: string; createdAt: string; title: string; rawText: string; cleanedText: string;
  editedText?: string | null; duration: number; isPinned: boolean; tags: string[]; source: string;
  sourceApplication?: string | null; sourceBundleIdentifier?: string | null;
  captures?: NoteCapture[] | null;
}
