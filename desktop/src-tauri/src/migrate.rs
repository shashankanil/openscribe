//! v0.4 migration writes notes last as its completion marker. Retrying cannot duplicate IDs.
use crate::{
    apple_time::{Id, NoteDate},
    meetings::{MeetingRecord, MeetingSegment, MeetingStatus},
    notes::{group_existing_dictations, VoiceNote},
    storage::{atomic_json, AppSettings},
};
use serde::Deserialize;
use serde_json::{json, Value};
use std::{collections::BTreeMap, fs, path::Path};

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct LegacyNote {
    id: Id,
    created_at: String,
    title: String,
    raw_text: String,
    cleaned_text: String,
    duration: f64,
    #[serde(default)]
    pinned: bool,
    #[serde(default)]
    tags: Vec<String>,
    #[serde(flatten)]
    extra: BTreeMap<String, Value>,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct LegacyMeeting {
    id: Id,
    created_at: String,
    title: String,
    duration: f64,
    transcript: String,
    summary: String,
    #[serde(default)]
    source_label: String,
    #[serde(flatten)]
    extra: BTreeMap<String, Value>,
}
#[derive(Default, Deserialize)]
#[serde(default)]
struct LegacyState {
    settings: BTreeMap<String, Value>,
    notes: Vec<LegacyNote>,
    meetings: Vec<LegacyMeeting>,
}
#[derive(Deserialize)]
struct LegacyStore {
    state: LegacyState,
}
fn legacy_datetime(raw: &str) -> Result<chrono::DateTime<chrono::FixedOffset>, String> {
    chrono::DateTime::parse_from_rfc3339(raw).map_err(|_| {
        "The legacy profile has an unreadable date. The original profile has been preserved.".into()
    })
}
fn legacy_date(raw: &str) -> Result<NoteDate, String> {
    legacy_datetime(raw).map(|date| NoteDate(date.timestamp()))
}
pub fn legacy(root: &Path) -> Result<(), String> {
    let source = root.join("openscribe.json");
    if !source.exists() || root.join("notes.json").exists() {
        return Ok(());
    }
    fs::create_dir_all(root).map_err(|e| e.to_string())?;
    fs::copy(
        &source,
        root.join(format!("openscribe-v0.4-backup-{}.json", Id::default())),
    )
    .map_err(|e| format!("Could not back up the legacy profile. Migration has not started: {e}"))?;
    let old: LegacyStore = crate::storage::read_json(&source)?;
    let mut map = old.state.settings;
    for (from, to) in [
        ("speechBaseUrl", "speechBaseURL"),
        ("writingProvider", "languageModelProvider"),
        ("writingBaseUrl", "languageModelBaseURL"),
        ("writingModel", "languageModel"),
        ("microphoneDeviceId", "microphoneDeviceUID"),
    ] {
        if let Some(value) = map.remove(from) {
            map.insert(to.into(), value);
        }
    }
    if let Some(value) = map.remove("corrections") {
        map.insert("correctionRules".into(), value);
    }
    if map.get("theme") == Some(&json!("paper")) {
        map.insert("theme".into(), json!("light"));
    }
    if let Some(shortcut) = map.remove("shortcut") {
        let bindings = json!({"dictate":{"accelerator":shortcut,"display":shortcut}});
        let valid = serde_json::from_value::<crate::shortcuts::Bindings>(bindings.clone())
            .is_ok_and(|bindings| crate::shortcuts::validate(&bindings).is_ok());
        if valid {
            map.insert("shortcuts".into(), bindings);
        } else {
            // v0.4 shipped Alt+Space, which Windows reserves for its window menu.
            // Keep the original preference alongside the untouched legacy backup.
            map.insert("legacyShortcut".into(), shortcut);
            map.insert(
                "shortcuts".into(),
                AppSettings::default().0["shortcuts"].clone(),
            );
        }
    }
    let settings: AppSettings = serde_json::from_value(json!(map))
        .map_err(|e| format!("Could not migrate legacy settings: {e}"))?;
    let mut notes = vec![];
    for n in old.state.notes {
        notes.push(VoiceNote {
            id: n.id,
            created_at: legacy_date(&n.created_at)?,
            title: n.title,
            raw_text: n.raw_text,
            cleaned_text: n.cleaned_text,
            duration: n.duration,
            is_pinned: n.pinned,
            tags: n.tags,
            extra: n.extra,
            ..VoiceNote::default()
        });
    }
    let notes: Vec<_> = group_existing_dictations(notes)
        .into_iter()
        .map(VoiceNote::migrated_to_timeline)
        .collect();
    let mut meetings = vec![];
    for m in old.state.meetings {
        let segments = vec![MeetingSegment {
            id: "legacy/transcript".into(),
            track: "microphone".into(),
            start: 0.0,
            duration: m.duration,
            text: m.transcript,
            ..MeetingSegment::default()
        }];
        meetings.push(MeetingRecord {
            id: m.id,
            created_at: legacy_datetime(&m.created_at)?.timestamp_millis() as f64 / 1000.0
                - crate::apple_time::APPLE_EPOCH,
            title: m.title,
            duration: m.duration,
            status: MeetingStatus::Ready,
            settings: settings.clone(),
            segments,
            user_notes: if m.summary.trim().is_empty() {
                None
            } else {
                Some(format!("## Previous summary\n\n{}", m.summary))
            },
            microphone_label: if m.source_label.is_empty() {
                "Microphone".into()
            } else {
                m.source_label
            },
            extra: m.extra,
            ..MeetingRecord::default()
        });
    }
    for meeting in meetings {
        let target = root
            .join("Meetings")
            .join(meeting.id.to_string())
            .join("meeting.json");
        // Do not overwrite a meeting edited between an interrupted migration and its retry.
        if !target.exists() {
            atomic_json(&target, &meeting)?;
        }
    }
    if !root.join("settings.json").exists() {
        atomic_json(&root.join("settings.json"), &settings)?;
    }
    atomic_json(&root.join("notes.json"), &notes)
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn reserved_legacy_shortcut_uses_windows_defaults_without_losing_original() {
        let dir = tempfile::tempdir().unwrap();
        let legacy = r#"{"state":{"settings":{"shortcut":"Alt+Space"}}}"#;
        fs::write(dir.path().join("openscribe.json"), legacy).unwrap();
        let store = crate::storage::ProfileStore::open(dir.path().into());
        let settings = store.profile().settings;
        assert_eq!(settings.0["legacyShortcut"], "Alt+Space");
        assert_eq!(
            settings.0["shortcuts"]["dictate"]["accelerator"],
            "Ctrl+Alt+Space"
        );
        assert_eq!(
            fs::read_to_string(dir.path().join("openscribe.json")).unwrap(),
            legacy
        );
    }
    #[test]
    fn failed_legacy_backup_blocks_profile_writes_and_preserves_source() {
        let dir = tempfile::tempdir().unwrap();
        // A directory cannot be copied as a file, giving a deterministic backup failure.
        fs::create_dir(dir.path().join("openscribe.json")).unwrap();
        let mut store = crate::storage::ProfileStore::open(dir.path().into());
        assert!(store
            .profile()
            .storage_error
            .unwrap()
            .contains("Migration has not started"));
        assert!(store.save_notes(vec![]).unwrap_err().contains("blocked"));
        assert!(store
            .write("settings.json", &AppSettings::default())
            .is_err());
        assert!(!dir.path().join("notes.json").exists());
        assert!(dir.path().join("openscribe.json").is_dir());
    }
    #[test]
    fn hand_written_legacy_fixture_migrates_idempotently_without_moving_audio() {
        let root = tempfile::tempdir().unwrap();
        let fixture = r#"{"state":{"settings":{"speechProvider":"openAI","speechBaseUrl":"https://api.openai.com/v1","speechModel":"whisper-1","writingProvider":"groq","writingBaseUrl":"https://api.groq.com/openai/v1","writingModel":"llama","corrections":[{"id":"E621E1F8-C36C-495A-93FC-0C247A3E6E5F","heard":"mah","replacement":"Maha"}],"theme":"paper"},"notes":[{"id":"e621e1f8-c36c-495a-93fc-0c247a3e6e5f","createdAt":"2026-10-19T10:58:15.321Z","title":"Old title","rawText":"raw","cleanedText":"clean","duration":2,"pinned":true,"tags":["work"],"audioPath":"untouched.wav"}],"meetings":[{"id":"C621E1F8-C36C-495A-93FC-0C247A3E6E5F","createdAt":"2026-10-19T10:58:15.321Z","title":"Call","duration":5,"transcript":"Hello","summary":"Previous facts","audioPath":"untouched.wav","sourceLabel":"Mic"}]}}"#;
        fs::write(root.path().join("openscribe.json"), fixture).unwrap();
        fs::write(root.path().join("untouched.wav"), b"keep").unwrap();
        legacy(root.path()).unwrap();
        let settings: AppSettings =
            crate::storage::read_json(&root.path().join("settings.json")).unwrap();
        assert_eq!(settings.string("theme"), "light");
        assert_eq!(settings.string("languageModelProvider"), "groq");
        assert_eq!(settings.0["correctionRules"][0]["heard"], "mah");
        let notes: Vec<VoiceNote> =
            crate::storage::read_json(&root.path().join("notes.json")).unwrap();
        assert_eq!(notes[0].captures.as_ref().unwrap()[0].title, "Old title");
        assert!(notes[0].is_pinned);
        let path = root
            .path()
            .join("Meetings/C621E1F8-C36C-495A-93FC-0C247A3E6E5F/meeting.json");
        let meeting: MeetingRecord = crate::storage::read_json(&path).unwrap();
        assert_eq!(meeting.status, MeetingStatus::Ready);
        let expected = chrono::DateTime::parse_from_rfc3339("2026-10-19T10:58:15.321Z")
            .unwrap()
            .timestamp_millis() as f64
            / 1000.0
            - crate::apple_time::APPLE_EPOCH;
        assert_eq!(meeting.created_at, expected);
        assert_eq!(meeting.segments[0].id, "legacy/transcript");
        assert!(meeting.user_notes.unwrap().contains("## Previous summary"));
        assert_eq!(meeting.extra["audioPath"], "untouched.wav");
        assert_eq!(
            fs::read(root.path().join("untouched.wav")).unwrap(),
            b"keep"
        );
        let before = fs::read(root.path().join("notes.json")).unwrap();
        legacy(root.path()).unwrap();
        assert_eq!(fs::read(root.path().join("notes.json")).unwrap(), before);
        let backups: Vec<_> = fs::read_dir(root.path())
            .unwrap()
            .flatten()
            .filter(|e| {
                e.file_name()
                    .to_string_lossy()
                    .starts_with("openscribe-v0.4-backup-")
            })
            .collect();
        assert_eq!(backups.len(), 1);
        assert_eq!(fs::read_to_string(backups[0].path()).unwrap(), fixture);
    }
}
