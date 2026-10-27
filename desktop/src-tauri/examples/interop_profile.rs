//! Generate a synthetic profile with the actual Rust writers for importer QA.
//! Usage: cargo run --example interop_profile -- <new-empty-directory>
use base64::Engine;
use openscribe_desktop_lib::{
    apple_time::Id,
    meetings::{MeetingRecord, MeetingStatus, MeetingStore},
    notes::{CaptureKind, NoteCapture},
    storage::ProfileStore,
};

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let root = std::path::PathBuf::from(
        std::env::args_os()
            .nth(1)
            .ok_or("Pass a new empty profile directory.")?,
    );
    if root.exists() && std::fs::read_dir(&root)?.next().is_some() {
        return Err("The fixture directory must be empty.".into());
    }
    std::fs::create_dir_all(&root)?;
    let mut profile = ProfileStore::open(root.clone());
    let mut meeting: MeetingRecord = serde_json::from_value(serde_json::json!({
        "id": Id::default(), "title": "Windows and macOS importer verification", "createdAt": 814190400.0,
        "duration": 92.0, "status": "ready", "userNotes": "Confirm the screenshot stays linked to this meeting.",
        "segments": [{"id":"fixture/microphone/chunk-00000.wav","track":"microphone","start":0.0,"duration":15.0,"text":"The field team approved the irrigation survey for Thursday."}],
        "summary":{"overview":[{"text":"Irrigation survey approved.","sources":["fixture/microphone/chunk-00000.wav"]}],"decisions":[],"actions":[]}
    }))?;
    meeting.status = MeetingStatus::Ready;
    let id = meeting.id;
    MeetingStore::open(root.join("Meetings")).save(meeting.clone())?;
    profile.link_meeting(&meeting)?;
    let filename = format!("Screenshot-{}.png", Id::default());
    std::fs::create_dir_all(root.join("Attachments"))?;
    std::fs::write(root.join("Attachments").join(&filename), base64::engine::general_purpose::STANDARD.decode("iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAIAAACQkWg2AAAAI0lEQVR4nGP8//8/AymAiSTVDKMaiANMRKqDg1ENxACSQwkAVW0DHeN02ZEAAAAASUVORK5CYII=")?)?;
    profile.add_capture(NoteCapture {
        kind: Some(CaptureKind::Screenshot),
        meeting_id: Some(id),
        attachment: Some(filename),
        recognized_text: Some("Survey plan: Thursday, irrigation review.".into()),
        ..NoteCapture::default()
    })?;
    // Personal dictation must remain outside the meeting import.
    profile.add_capture(NoteCapture {
        text: "PRIVATE DICTATION: must never appear in the meeting import".into(),
        ..NoteCapture::default()
    })?;
    println!("{}", root.display());
    Ok(())
}
