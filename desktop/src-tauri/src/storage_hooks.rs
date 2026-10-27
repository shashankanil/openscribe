//! Screenshot writes use the same locked, atomic profile as notes and meetings.
use crate::{notes, screenshot::NoteCapture, storage};
use tauri::{Emitter, Manager};

pub fn active_meeting_id(app: &tauri::AppHandle) -> Option<String> {
    crate::meetings::active_meeting_id(app)
}

fn shared_capture(capture: &NoteCapture) -> Result<notes::NoteCapture, String> {
    serde_json::to_value(capture)
        .and_then(serde_json::from_value)
        .map_err(|_| "The screenshot could not be added to your notes.".into())
}

pub fn add_screenshot_capture(
    app: &tauri::AppHandle,
    mut capture: NoteCapture,
    meeting_id: Option<String>,
) -> Result<NoteCapture, String> {
    capture.meeting_id = meeting_id;
    let shared = shared_capture(&capture)?;
    let sounds = storage::with_profile(app, &app.state::<storage::ProfileState>(), |store| {
        store.add_capture(shared)?;
        Ok(store.settings.flag("interactionSounds"))
    })?;
    let _ = app.emit("capture://added", &capture);
    if sounds {
        capture_sound();
    }
    Ok(capture)
}

pub fn set_recognized_text(
    app: &tauri::AppHandle,
    capture_id: &str,
    text: &str,
) -> Result<Option<String>, String> {
    let id = capture_id.parse()?;
    storage::with_profile(app, &app.state::<storage::ProfileState>(), |store| {
        persist_recognized_text(store, id, text)
    })
}

fn persist_recognized_text(
    store: &mut storage::ProfileStore,
    id: crate::apple_time::Id,
    text: &str,
) -> Result<Option<String>, String> {
    let mut notes = store.notes.clone();
    let Some(note) = notes.iter_mut().find(|note| {
        note.captures
            .iter()
            .flatten()
            .any(|capture| capture.id == id)
    }) else {
        return Ok(None);
    };
    let mut capture = note
        .captures
        .iter()
        .flatten()
        .find(|capture| capture.id == id)
        .cloned()
        .expect("located capture");
    capture.recognized_text = Some(text.into());
    note.update_capture(capture);
    let note_id = note.id.to_string();
    store.save_notes(notes)?;
    Ok(Some(note_id))
}

#[cfg(windows)]
fn capture_sound() {
    #[link(name = "user32")]
    extern "system" {
        fn MessageBeep(kind: u32) -> i32;
    }
    // A standard non-blocking Windows notification, only after the capture saves.
    unsafe {
        MessageBeep(0x40);
    }
}
#[cfg(not(windows))]
fn capture_sound() {}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn late_ocr_keeps_newer_edits_and_never_recreates_deleted_captures() {
        let dir = tempfile::tempdir().unwrap();
        let mut store = storage::ProfileStore::open(dir.path().into());
        let capture = notes::NoteCapture {
            kind: Some(notes::CaptureKind::Screenshot),
            ..Default::default()
        };
        let id = capture.id;
        let note = store.add_capture(capture).unwrap();
        let mut edited = store.notes.clone();
        edited[0].edited_text = Some("A newer editor revision".into());
        edited[0]
            .extra
            .insert("futureField".into(), serde_json::json!(42));
        store.save_notes(edited).unwrap();
        assert_eq!(
            persist_recognized_text(&mut store, id, "Recognized slide text").unwrap(),
            Some(note.id.to_string())
        );
        assert_eq!(
            store.notes[0].edited_text.as_deref(),
            Some("A newer editor revision")
        );
        assert_eq!(store.notes[0].extra["futureField"], 42);
        assert_eq!(
            store.notes[0].captures.as_ref().unwrap()[0]
                .recognized_text
                .as_deref(),
            Some("Recognized slide text")
        );
        store.save_notes(vec![]).unwrap();
        assert_eq!(
            persist_recognized_text(&mut store, id, "Late result").unwrap(),
            None
        );
        assert!(store.notes.is_empty());
    }
    #[test]
    fn screenshot_bridge_preserves_mac_keys_and_shared_dates() {
        let mut capture = NoteCapture::screenshot(
            "2026-10-19T10:58:15Z".into(),
            "Screenshot-TEST.png".into(),
            Some("app.exe".into()),
            None,
        );
        capture.meeting_id = Some(crate::apple_time::Id::default().to_string());
        let shared = shared_capture(&capture).unwrap();
        assert_eq!(shared.entry_kind(), notes::CaptureKind::Screenshot);
        assert_eq!(
            shared.meeting_id.unwrap().to_string(),
            capture.meeting_id.unwrap()
        );
        assert_eq!(shared.attachment, capture.attachment);
        assert_eq!(shared.source_application, capture.source_application);
        assert_eq!(
            serde_json::to_value(shared).unwrap()["createdAt"],
            "2026-10-19T10:58:15Z"
        );
    }
}
