//! The profile is authoritative; callers never acknowledge a save before it reaches disk.
use crate::{
    apple_time::Id,
    notes::{self, NoteCapture, VoiceNote},
};
use serde::{
    de::{DeserializeOwned, Error},
    Deserialize, Deserializer, Serialize,
};
use serde_json::{json, Value};
use std::{
    collections::{BTreeMap, HashSet},
    fs,
    io::Write,
    path::{Component, Path, PathBuf},
    sync::{Mutex, MutexGuard},
};
use tauri::Manager;

#[derive(Clone, Debug, Serialize, PartialEq)]
#[serde(transparent)]
pub struct AppSettings(pub BTreeMap<String, Value>);
impl Default for AppSettings {
    fn default() -> Self {
        Self(serde_json::from_value(json!({
            "speechProvider":"openRouter", "speechBaseURL":"https://openrouter.ai/api/v1", "speechModel":"mistralai/voxtral-mini-transcribe",
            "languageModelProvider":"openRouter", "languageModelBaseURL":"https://openrouter.ai/api/v1", "languageModel":"openai/gpt-5.6-luna",
            "writingTone":"natural", "customVocabulary":[], "correctionRules":[], "cleanupStrength":"clear", "speechHints":true,
            "spokenCorrections":true, "learnSpelledWords":true, "correctionModel":"", "dictationLiveTranscription":true, "meetingLiveTranscription":true,
            "calendarEnabled":false, "calendarExcludedTitles":[], "calendarAutoStart":true, "calendarMeetingsOnly":true, "calendarSummarize":true,
            "microphoneDeviceUID":"", "interactionSounds":true, "snippets":[], "appWritingTones":{}, "cleanupEnabled":true,
            "pasteIntoFocusedApp":true, "saveRawAudio":false, "showOverlayWhenIdle":false, "theme":"system",
            "meetingMicrophone":true, "meetingSystemAudio":true, "meetingSummarize":true,
            "shortcuts": {
                "dictate":{"accelerator":"Ctrl+Alt+Space","display":"Ctrl Alt Space"},
                "holdToTalk":{"accelerator":"Ctrl+Alt+H","display":"Ctrl Alt H"},
                "meeting":{"accelerator":"Ctrl+Alt+M","display":"Ctrl Alt M"},
                "screenshotArea":{"accelerator":"Ctrl+Alt+4","display":"Ctrl Alt 4"},
                "screenshotWindow":{"accelerator":"Ctrl+Alt+5","display":"Ctrl Alt 5"},
                "screenshotScreen":{"accelerator":"Ctrl+Alt+3","display":"Ctrl Alt 3"},
                "pasteLast":{"accelerator":"Ctrl+Alt+V","display":"Ctrl Alt V"}
            }, "systemAudioDeviceId":"", "calendarSources":[]
        })).expect("static defaults"))
    }
}
impl<'de> Deserialize<'de> for AppSettings {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        let incoming = BTreeMap::<String, Value>::deserialize(d)?;
        let supplied: HashSet<_> = incoming
            .iter()
            .filter(|(_, v)| !v.is_null())
            .map(|(k, _)| k.clone())
            .collect();
        let mut settings = Self::default();
        for (key, val) in incoming {
            if val.is_null() && settings.0.contains_key(&key) {
                continue;
            }
            if let Some(default) = settings.0.get(&key) {
                let matches = match default {
                    Value::String(_) => val.is_string(),
                    Value::Bool(_) => val.is_boolean(),
                    Value::Array(_) => val.is_array(),
                    Value::Object(_) => val.is_object(),
                    _ => true,
                };
                if !matches {
                    return Err(D::Error::custom(format!("Invalid setting: {key}")));
                }
            }
            let mut val = val;
            normalize_ids(&mut val);
            settings.0.insert(key, val);
        }
        // Provider-specific defaults, as in AppSettings.init(from:).
        for (provider_key, base_key, model_key, speech) in [
            ("speechProvider", "speechBaseURL", "speechModel", true),
            (
                "languageModelProvider",
                "languageModelBaseURL",
                "languageModel",
                false,
            ),
        ] {
            let provider = settings.string(provider_key).to_owned();
            let (base, model) = provider_defaults(&provider, speech);
            // A provided value wins; defaults are selected before merging below.
            if !supplied.contains(base_key) {
                settings.0.insert(base_key.into(), json!(base));
            }
            if !supplied.contains(model_key) {
                settings.0.insert(model_key.into(), json!(model));
            }
        }
        if settings.string("speechProvider") == "custom"
            && settings.string("speechBaseURL") == "https://example.com/v1"
            && settings.string("speechModel") == "whisper-1"
        {
            for key in ["speechProvider", "speechBaseURL", "speechModel"] {
                settings
                    .0
                    .insert(key.into(), Self::default().0[key].clone());
            }
        }
        if !["system", "light", "dark"].contains(&settings.string("theme")) {
            settings.0.insert("theme".into(), json!("system"));
        }
        Ok(settings)
    }
}
fn normalize_ids(value: &mut Value) {
    match value {
        Value::Object(map) => {
            for (key, value) in map {
                if key == "id" || key == "meetingID" {
                    if let Some(raw) = value.as_str() {
                        if let Ok(id) = raw.parse::<Id>() {
                            *value = json!(id);
                        }
                    }
                }
                normalize_ids(value);
            }
        }
        Value::Array(values) => {
            for value in values {
                normalize_ids(value);
            }
        }
        _ => {}
    }
}
fn provider_defaults(provider: &str, speech: bool) -> (&'static str, &'static str) {
    match (provider, speech) {
        ("openAI", true) => ("https://api.openai.com/v1", "gpt-4o-mini-transcribe"),
        ("openAI", false) => ("https://api.openai.com/v1", "gpt-5.6-luna"),
        ("groq", true) => ("https://api.groq.com/openai/v1", "whisper-large-v3-turbo"),
        ("groq", false) => ("https://api.groq.com/openai/v1", "llama-3.3-70b-versatile"),
        ("deepgram", _) => ("https://api.deepgram.com/v1", "nova-3"),
        ("assemblyAI", _) => ("https://api.assemblyai.com/v2", "best"),
        ("mistral", _) => (
            "https://api.mistral.ai/v1",
            "voxtral-mini-transcribe-realtime-2602",
        ),
        ("anthropic", _) => ("https://api.anthropic.com", "claude-3-5-haiku-latest"),
        ("google", _) => (
            "https://generativelanguage.googleapis.com",
            "gemini-3.5-flash-lite",
        ),
        ("custom", true) => ("https://example.com/v1", "whisper-1"),
        ("custom", false) => ("https://example.com/v1", "gpt-4o-mini"),
        (_, true) => (
            "https://openrouter.ai/api/v1",
            "mistralai/voxtral-mini-transcribe",
        ),
        (_, false) => ("https://openrouter.ai/api/v1", "openai/gpt-5.6-luna"),
    }
}
impl AppSettings {
    pub fn string(&self, key: &str) -> &str {
        self.0.get(key).and_then(Value::as_str).unwrap_or_default()
    }
    pub fn flag(&self, key: &str) -> bool {
        self.0.get(key).and_then(Value::as_bool).unwrap_or(false)
    }
    pub fn meeting_snapshot<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        let mut snapshot = BTreeMap::new();
        for key in [
            "speechProvider",
            "speechBaseURL",
            "speechModel",
            "languageModelProvider",
            "languageModelBaseURL",
            "languageModel",
            "customVocabulary",
            "correctionRules",
            "speechHints",
        ] {
            if let Some(value) = self.0.get(key) {
                snapshot.insert(key, value.clone());
            }
        }
        snapshot.insert("microphoneDeviceUID", json!(""));
        snapshot.serialize(serializer)
    }
    pub fn provider_config(&self, speech: bool) -> crate::provider::ProviderConfig {
        let (p, b, m, purpose) = if speech {
            ("speechProvider", "speechBaseURL", "speechModel", "speech")
        } else {
            (
                "languageModelProvider",
                "languageModelBaseURL",
                "languageModel",
                "writing",
            )
        };
        crate::provider::ProviderConfig {
            provider: self.string(p).into(),
            base_url: self.string(b).into(),
            model: self.string(m).into(),
            credential_account: format!("{purpose}:{}:{}", self.string(p), self.string(b)),
        }
    }
}

/// Serialize via Value so all object keys (including flattened unknowns) are sorted recursively.
pub fn atomic_json(path: &Path, value: &impl Serialize) -> Result<(), String> {
    let data = serde_json::to_vec_pretty(&serde_json::to_value(value).map_err(|e| e.to_string())?)
        .map_err(|e| e.to_string())?;
    atomic_bytes(path, &data)
}
pub fn atomic_bytes(path: &Path, data: &[u8]) -> Result<(), String> {
    let parent = path.parent().ok_or("Invalid profile path.")?;
    fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    let mut temp = tempfile::NamedTempFile::new_in(parent).map_err(|e| e.to_string())?;
    temp.write_all(data)
        .and_then(|_| temp.as_file().sync_all())
        .map_err(|e| e.to_string())?;
    temp.persist(path).map_err(|e| e.error.to_string())?;
    Ok(())
}
pub fn read_json<T: DeserializeOwned>(path: &Path) -> Result<T, String> {
    let data = fs::read(path).map_err(|e| e.to_string())?;
    serde_json::from_slice(&data).map_err(|e| {
        format!(
            "Unreadable {}: {e}",
            path.file_name().unwrap_or_default().to_string_lossy()
        )
    })
}
fn protected_load<T: DeserializeOwned + Default>(
    root: &Path,
    name: &str,
    blocked: &mut HashSet<String>,
    notices: &mut Vec<String>,
) -> T {
    let path = root.join(name);
    if !path.exists() {
        return T::default();
    }
    match read_json(&path) {
        Ok(value) => value,
        Err(error) => {
            let backup = root.join(format!(
                "{}-unreadable-{}.json",
                name.trim_end_matches(".json"),
                Id::default()
            ));
            match fs::read(&path).map_err(|e| e.to_string()).and_then(|data| atomic_bytes(&backup, &data)) {
                Ok(()) => notices.push(format!("Could not load {name}. The original file was preserved as {}. New changes will use a fresh file.", backup.file_name().unwrap_or_default().to_string_lossy())),
                Err(backup_error) => { blocked.insert(name.into()); notices.push(format!("Could not read or back up {name}. Saving to that file is blocked to protect your data. {error}; {backup_error}")); }
            }
            T::default()
        }
    }
}

pub struct ProfileStore {
    pub root: PathBuf,
    pub settings: AppSettings,
    pub notes: Vec<VoiceNote>,
    blocked: HashSet<String>,
    notices: Vec<String>,
}
#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Profile {
    pub settings: AppSettings,
    pub notes: Vec<VoiceNote>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub storage_error: Option<String>,
}
impl ProfileStore {
    pub fn open(root: PathBuf) -> Self {
        let mut notices = vec![];
        let mut blocked = HashSet::new();
        if let Err(error) = crate::migrate::legacy(&root) {
            notices.push(error);
            blocked.insert("notes.json".into());
            blocked.insert("settings.json".into());
        }
        let settings = protected_load(&root, "settings.json", &mut blocked, &mut notices);
        let notes = protected_load(&root, "notes.json", &mut blocked, &mut notices);
        let mut store = Self {
            root,
            settings,
            notes,
            blocked,
            notices,
        };
        for name in ["settings.json", "notes.json"] {
            if !store.root.join(name).exists() {
                let result = if name == "settings.json" {
                    store.write(name, &store.settings)
                } else {
                    store.write(name, &store.notes)
                };
                if let Err(e) = result {
                    store.notices.push(e);
                }
            }
        }
        if store
            .notes
            .iter()
            .any(|n| n.source == "Dictation" && n.captures.is_none())
        {
            store.transform_notes("daily-grouping", notes::group_existing_dictations);
        }
        if store
            .notes
            .iter()
            .any(|n| n.captures.is_some() && n.edited_text.is_some())
        {
            store.transform_notes("day-timeline", |n| {
                n.into_iter().map(VoiceNote::migrated_to_timeline).collect()
            });
        }
        store
    }
    fn transform_notes(
        &mut self,
        label: &str,
        transform: impl FnOnce(Vec<VoiceNote>) -> Vec<VoiceNote>,
    ) {
        if self.blocked.contains("notes.json") {
            return;
        }
        let backup = self
            .root
            .join(format!("notes-before-{label}-{}.json", Id::default()));
        if let Err(e) = fs::copy(self.root.join("notes.json"), backup) {
            self.blocked.insert("notes.json".into());
            self.notices.push(format!("Could not back up note history before updating day notes. Saving is blocked to protect the original data. {e}"));
            return;
        }
        let notes = transform(self.notes.clone());
        if let Err(e) = self.save_notes(notes) {
            self.notices.push(e);
        }
    }
    pub fn profile(&self) -> Profile {
        Profile {
            settings: self.settings.clone(),
            notes: self.notes.clone(),
            storage_error: if self.notices.is_empty() {
                None
            } else {
                Some(self.notices.join("\n\n"))
            },
        }
    }
    pub fn write(&self, name: &str, value: &impl Serialize) -> Result<(), String> {
        if self.blocked.contains(name) {
            return Err(format!(
                "Saving {name} is blocked to protect the original data. See the storage error."
            ));
        }
        atomic_json(&self.root.join(name), value)
            .map_err(|e| format!("Could not save {name}. Your changes have not been saved. {e}"))
    }
    pub fn save_notes(&mut self, notes: Vec<VoiceNote>) -> Result<(), String> {
        self.write("notes.json", &notes)?;
        self.notes = notes;
        Ok(())
    }
    pub fn add_capture(&mut self, capture: NoteCapture) -> Result<VoiceNote, String> {
        let mut notes = self.notes.clone();
        let note = notes::add_to_day(&mut notes, capture);
        self.save_notes(notes)?;
        Ok(note)
    }
    pub fn link_meeting(&mut self, record: &crate::meetings::MeetingRecord) -> Result<(), String> {
        if self
            .notes
            .iter()
            .flat_map(|n| n.captures.iter().flatten())
            .any(|c| {
                c.meeting_id == Some(record.id) && c.entry_kind() == notes::CaptureKind::Meeting
            })
        {
            return Ok(());
        }
        self.add_capture(NoteCapture {
            created_at: crate::apple_time::NoteDate(
                (record.created_at + crate::apple_time::APPLE_EPOCH).floor() as i64,
            ),
            title: record.title.clone(),
            kind: Some(notes::CaptureKind::Meeting),
            meeting_id: Some(record.id),
            ..NoteCapture::default()
        })?;
        Ok(())
    }
    pub fn remove_meeting_entries(&mut self, id: Id) -> Result<(), String> {
        let mut notes = self.notes.clone();
        for note in &mut notes {
            if let Some(captures) = &mut note.captures {
                captures.retain(|c| {
                    !(c.meeting_id == Some(id) && c.entry_kind() == notes::CaptureKind::Meeting)
                });
                for c in captures {
                    if c.meeting_id == Some(id) {
                        c.meeting_id = None;
                    }
                }
                note.recompute_from_captures();
            }
        }
        notes.retain(|n| n.captures.as_ref().is_none_or(|c| !c.is_empty()));
        self.save_notes(notes)
    }
}
#[derive(Default)]
pub struct ProfileState(Mutex<Option<ProfileStore>>);
pub fn profile_lock<'a>(
    app: &tauri::AppHandle,
    state: &'a ProfileState,
) -> Result<MutexGuard<'a, Option<ProfileStore>>, String> {
    let mut guard = state
        .0
        .lock()
        .map_err(|_| "Profile storage is unavailable.")?;
    if guard.is_none() {
        *guard = Some(ProfileStore::open(
            app.path().app_data_dir().map_err(|e| e.to_string())?,
        ));
    }
    Ok(guard)
}
pub fn with_profile<T>(
    app: &tauri::AppHandle,
    state: &ProfileState,
    operation: impl FnOnce(&mut ProfileStore) -> Result<T, String>,
) -> Result<T, String> {
    let mut guard = profile_lock(app, state)?;
    operation(guard.as_mut().expect("initialized profile"))
}
/// Reject lexical escapes and resolve existing parents, including Windows junctions/symlinks.
pub fn safe_path(base: &Path, relative: &str) -> Result<PathBuf, String> {
    if relative.is_empty()
        || relative.contains(['\\', ':'])
        || Path::new(relative)
            .components()
            .any(|c| !matches!(c, Component::Normal(_)))
    {
        return Err("Invalid file path.".into());
    }
    fs::create_dir_all(base).map_err(|e| e.to_string())?;
    let base = base.canonicalize().map_err(|e| e.to_string())?;
    let target = base.join(relative);
    let mut ancestor = target.as_path();
    while !ancestor.exists() {
        ancestor = ancestor.parent().ok_or("Invalid file path.")?;
    }
    if !ancestor
        .canonicalize()
        .map_err(|e| e.to_string())?
        .starts_with(&base)
    {
        return Err("The file path is outside the profile directory.".into());
    }
    Ok(target)
}
#[tauri::command]
pub fn load_profile(
    app: tauri::AppHandle,
    state: tauri::State<ProfileState>,
) -> Result<Profile, String> {
    with_profile(&app, &state, |s| Ok(s.profile()))
}
#[tauri::command]
pub fn save_settings(
    app: tauri::AppHandle,
    state: tauri::State<ProfileState>,
    mut settings: AppSettings,
) -> Result<(), String> {
    with_profile(&app, &state, |s| {
        for (key, value) in &s.settings.0 {
            settings
                .0
                .entry(key.clone())
                .or_insert_with(|| value.clone());
        }
        s.write("settings.json", &settings)?;
        s.settings = settings;
        Ok(())
    })
}
#[tauri::command]
pub fn save_note(
    app: tauri::AppHandle,
    state: tauri::State<ProfileState>,
    note: VoiceNote,
) -> Result<(), String> {
    with_profile(&app, &state, |s| {
        let mut notes = s.notes.clone();
        if let Some(i) = notes.iter().position(|n| n.id == note.id) {
            notes[i] = note.merging_new_captures(&notes[i]).migrated_to_timeline();
        } else if note.source == "Note" && note.has_content() {
            notes.insert(0, note);
        }
        s.save_notes(notes)
    })
}
fn delete_attachment(root: &Path, capture: &NoteCapture) {
    if let Some(name) = &capture.attachment {
        if let Ok(path) = attachment(root, name) {
            let _ = fs::remove_file(path);
        }
    }
}
fn attachment(root: &Path, name: &str) -> Result<PathBuf, String> {
    if Path::new(name).components().count() != 1 || name.contains('/') {
        return Err("Invalid attachment name.".into());
    }
    safe_path(&root.join("Attachments"), name)
}
#[tauri::command]
pub fn delete_note(
    app: tauri::AppHandle,
    state: tauri::State<ProfileState>,
    id: Id,
) -> Result<(), String> {
    with_profile(&app, &state, |s| {
        let old = s.notes.iter().find(|n| n.id == id).cloned();
        let notes = s.notes.iter().filter(|n| n.id != id).cloned().collect();
        s.save_notes(notes)?;
        if let Some(n) = old {
            for c in n.captures.iter().flatten() {
                delete_attachment(&s.root, c);
            }
        }
        Ok(())
    })
}
#[tauri::command]
pub fn add_capture(
    app: tauri::AppHandle,
    state: tauri::State<ProfileState>,
    capture: NoteCapture,
) -> Result<VoiceNote, String> {
    with_profile(&app, &state, |s| s.add_capture(capture))
}
#[tauri::command]
pub fn update_capture(
    app: tauri::AppHandle,
    state: tauri::State<ProfileState>,
    capture: NoteCapture,
    note_id: Id,
) -> Result<(), String> {
    with_profile(&app, &state, |s| {
        let mut notes = s.notes.clone();
        if let Some(n) = notes.iter_mut().find(|n| n.id == note_id) {
            n.update_capture(capture);
        }
        s.save_notes(notes)
    })
}
#[tauri::command]
pub fn remove_capture(
    app: tauri::AppHandle,
    state: tauri::State<ProfileState>,
    capture_id: Id,
    note_id: Id,
) -> Result<(), String> {
    with_profile(&app, &state, |s| {
        let mut notes = s.notes.clone();
        let mut removed = None;
        if let Some(n) = notes.iter_mut().find(|n| n.id == note_id) {
            removed = n
                .captures
                .iter()
                .flatten()
                .find(|c| c.id == capture_id)
                .cloned();
            n.remove_capture(capture_id);
        }
        notes.retain(|n| n.captures.as_ref().is_none_or(|c| !c.is_empty()));
        s.save_notes(notes)?;
        if let Some(c) = removed {
            delete_attachment(&s.root, &c);
        }
        Ok(())
    })
}
#[tauri::command]
pub fn attachment_path(
    app: tauri::AppHandle,
    state: tauri::State<ProfileState>,
    name: String,
) -> Result<String, String> {
    with_profile(&app, &state, |s| {
        attachment(&s.root, &name).map(|p| p.to_string_lossy().into())
    })
}

#[cfg(test)]
mod tests {
    #[test]
    fn economical_provider_defaults_fill_missing_models_without_overwriting_selections() {
        let settings: super::AppSettings = serde_json::from_value(serde_json::json!({"speechProvider":"google","languageModelProvider":"openAI"})).unwrap();
        assert_eq!(settings.string("speechModel"), "gemini-3.5-flash-lite");
        assert_eq!(settings.string("languageModel"), "gpt-5.6-luna");
        let custom: super::AppSettings = serde_json::from_value(serde_json::json!({"speechProvider":"openAI","speechModel":"gpt-4o-transcribe"})).unwrap();
        assert_eq!(custom.string("speechModel"), "gpt-4o-transcribe");
    }
    use super::*;
    #[test]
    fn meetings_link_once_into_daily_notes_and_deletion_keeps_screenshots() {
        let dir = tempfile::tempdir().unwrap();
        let mut store = ProfileStore::open(dir.path().into());
        let meeting = crate::meetings::MeetingRecord::default();
        store.link_meeting(&meeting).unwrap();
        store.link_meeting(&meeting).unwrap();
        assert_eq!(store.notes[0].captures.as_ref().unwrap().len(), 1);
        let screenshot = NoteCapture {
            created_at: store.notes[0].created_at,
            kind: Some(notes::CaptureKind::Screenshot),
            meeting_id: Some(meeting.id),
            attachment: Some(format!("Screenshot-{}.png", Id::default())),
            ..NoteCapture::default()
        };
        store.add_capture(screenshot.clone()).unwrap();
        store.remove_meeting_entries(meeting.id).unwrap();
        let captures = store.notes[0].captures.as_ref().unwrap();
        assert_eq!(captures.len(), 1);
        assert_eq!(captures[0].id, screenshot.id);
        assert_eq!(captures[0].meeting_id, None);
        assert_eq!(captures[0].attachment, screenshot.attachment);
    }
    #[test]
    fn defaults_and_snapshot_and_unknown_keys() {
        let s: AppSettings =
            serde_json::from_value(json!({"speechProvider":"groq", "future":42})).unwrap();
        assert_eq!(s.string("speechModel"), "whisper-large-v3-turbo");
        assert!(s.flag("speechHints"));
        assert_eq!(s.0["future"], 42);
        assert!(serde_json::from_value::<AppSettings>(json!({"speechHints":"bad"})).is_err());
        let defaults = AppSettings::default();
        let bindings: crate::shortcuts::Bindings =
            serde_json::from_value(defaults.0["shortcuts"].clone()).unwrap();
        assert_eq!(bindings.len(), 7);
        crate::shortcuts::validate(&bindings).unwrap();
        let disabled: AppSettings = serde_json::from_value(json!({"shortcuts":{}})).unwrap();
        assert_eq!(disabled.0["shortcuts"], json!({}));
    }
    #[test]
    fn unreadable_backup_and_blocked_writes() {
        let dir = tempfile::tempdir().unwrap();
        fs::write(dir.path().join("notes.json"), b"broken").unwrap();
        let store = ProfileStore::open(dir.path().into());
        assert!(store.profile().storage_error.is_some());
        let backup = fs::read_dir(dir.path())
            .unwrap()
            .flatten()
            .find(|e| {
                e.file_name()
                    .to_string_lossy()
                    .starts_with("notes-unreadable-")
            })
            .unwrap();
        assert_eq!(fs::read(backup.path()).unwrap(), b"broken");
        fs::remove_file(dir.path().join("notes.json")).unwrap();
        fs::create_dir(dir.path().join("notes.json")).unwrap();
        let mut blocked = ProfileStore::open(dir.path().into());
        assert!(blocked.save_notes(vec![]).unwrap_err().contains("blocked"));
        assert!(dir.path().join("notes.json").is_dir());
    }
    #[test]
    fn sorted_pretty_atomic_replacement_and_paths() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("x.json");
        atomic_json(&path, &json!({"z":1,"a":{"z":2,"a":3}})).unwrap();
        assert_eq!(
            fs::read_to_string(&path).unwrap(),
            "{\n  \"a\": {\n    \"a\": 3,\n    \"z\": 2\n  },\n  \"z\": 1\n}"
        );
        atomic_json(&path, &json!({"done":true})).unwrap();
        assert_eq!(read_json::<Value>(&path).unwrap(), json!({"done":true}));
        for escape in ["../x", "a/../../x", "C:/x", "a\\x", "/x"] {
            assert!(safe_path(dir.path(), escape).is_err());
        }
        assert!(attachment(dir.path(), "../x.png").is_err());
    }
}
