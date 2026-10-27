//! Backend wiring. Calendar callbacks never read or lock CalendarState.
use crate::{audio, calendar, dictionary, meetings, provider, storage};
use std::sync::{
    atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering},
    Arc, Mutex, MutexGuard,
};
use std::time::{Duration, Instant};
use tauri::Manager;

#[derive(Default)]
pub struct ActivityState {
    starts: Mutex<()>,
    dictation_ui: AtomicBool,
    dictation_work: Arc<AtomicUsize>,
    cancel_generation: AtomicU64,
    cancel: tokio::sync::Notify,
}
impl ActivityState {
    pub fn generation(&self) -> u64 {
        self.cancel_generation.load(Ordering::SeqCst)
    }
    pub async fn cancelled(&self, generation: u64) {
        loop {
            let notified = self.cancel.notified();
            tokio::pin!(notified);
            notified.as_mut().enable();
            if self.generation() != generation {
                return;
            }
            notified.await;
        }
    }
    pub fn start_gate(&self) -> Result<MutexGuard<'_, ()>, String> {
        self.starts
            .lock()
            .map_err(|_| "Capture is unavailable.".into())
    }
    fn busy(&self) -> bool {
        self.dictation_ui.load(Ordering::SeqCst) || self.dictation_work.load(Ordering::SeqCst) != 0
    }
    fn work(&self) -> DictationWork {
        self.dictation_work.fetch_add(1, Ordering::SeqCst);
        DictationWork(self.dictation_work.clone())
    }
}
#[tauri::command]
pub fn cancel_dictation_work(app: tauri::AppHandle) {
    let state = app.state::<ActivityState>();
    state.cancel_generation.fetch_add(1, Ordering::SeqCst);
    state.cancel.notify_waiters();
}
pub struct DictationWork(Arc<AtomicUsize>);
impl Drop for DictationWork {
    fn drop(&mut self) {
        self.0.fetch_sub(1, Ordering::SeqCst);
    }
}
pub fn dictation_work(app: &tauri::AppHandle) -> Result<DictationWork, String> {
    let state = app.state::<ActivityState>();
    let _start = state.start_gate()?;
    let (id, busy) = meetings::capture_status(app)?;
    if id.is_some() || busy {
        return Err("Finish the meeting before processing dictation.".into());
    }
    Ok(state.work())
}
pub fn dictation_busy(app: &tauri::AppHandle) -> bool {
    app.state::<ActivityState>().busy() || audio::is_busy(&app.state::<audio::RecorderState>())
}
/// Main brackets its entire startup/record/transcribe/dictionary/cleanup/save
/// sequence, clearing in finally. Actual recorder and backend work also veto starts.
#[tauri::command]
pub fn set_dictation_busy(app: tauri::AppHandle, busy: bool) -> Result<(), String> {
    let state = app.state::<ActivityState>();
    let _start = state.start_gate()?;
    if busy {
        let (id, meeting_busy) = meetings::capture_status(&app)?;
        if id.is_some() || meeting_busy {
            return Err("Finish the meeting before starting dictation.".into());
        }
    }
    state.dictation_ui.store(busy, Ordering::SeqCst);
    Ok(())
}

fn dictionary_settings(settings: &storage::AppSettings) -> dictionary::DictionarySettings {
    // Read the authoritative typed profile, including Swift defaults. Invalid
    // dictionary array entries are skipped rather than disabling all settings.
    dictionary::DictionarySettings {
        custom_vocabulary: settings
            .0
            .get("customVocabulary")
            .and_then(|v| v.as_array())
            .into_iter()
            .flatten()
            .filter_map(|v| v.as_str().map(str::to_owned))
            .collect(),
        correction_rules: settings
            .0
            .get("correctionRules")
            .and_then(|v| v.as_array())
            .into_iter()
            .flatten()
            .filter_map(|v| serde_json::from_value(v.clone()).ok())
            .collect(),
        speech_hints: settings.flag("speechHints"),
        spoken_corrections: settings.flag("spokenCorrections"),
        learn_spelled_words: settings.flag("learnSpelledWords"),
        correction_model: settings.string("correctionModel").into(),
        language_model_provider: settings.string("languageModelProvider").into(),
        language_model_base_url: settings.string("languageModelBaseURL").into(),
        language_model: settings.string("languageModel").into(),
    }
}
fn speech_hints(settings: &storage::AppSettings) -> provider::SpeechHints {
    hints_for_provider(
        settings,
        settings.string("speechProvider"),
        settings.string("speechModel"),
    )
}
pub fn hints_for_provider(
    settings: &storage::AppSettings,
    provider: &str,
    model: &str,
) -> provider::SpeechHints {
    dictionary::for_settings(&dictionary_settings(settings), provider, model)
}
fn transcript_filter(text: &str, settings: &storage::AppSettings) -> String {
    dictionary::apply_local(text, &dictionary_settings(settings))
}

#[tauri::command]
pub async fn apply_dictionary(
    app: tauri::AppHandle,
    text: String,
    settings: dictionary::DictionarySettings,
) -> Result<dictionary::Outcome, String> {
    let _work = dictation_work(&app)?;
    let state = app.state::<ActivityState>();
    let generation = state.generation();
    tokio::select! {
        result = dictionary::apply_dictionary(text, settings) => result,
        () = state.cancelled(generation) => Err("Dictation cancelled.".into()),
    }
}

struct Readiness {
    checked: Instant,
    microphone: String,
    system_audio: String,
    ready: bool,
}
struct MeetingCapture {
    app: tauri::AppHandle,
    readiness: Mutex<Option<Readiness>>,
}
impl MeetingCapture {
    fn ready(&self, force: bool) -> bool {
        let Ok(settings) =
            storage::with_profile(&self.app, &self.app.state::<storage::ProfileState>(), |s| {
                Ok(s.settings.clone())
            })
        else {
            return false;
        };
        let Ok(mut cache) = self.readiness.lock() else {
            return false;
        };
        let microphone = settings.string("microphoneDeviceUID");
        let system_audio = settings.string("systemAudioDeviceId");
        if !force {
            if let Some(value) = cache.as_ref().filter(|v| {
                v.checked.elapsed() < Duration::from_secs(30)
                    && v.microphone == microphone
                    && v.system_audio == system_audio
            }) {
                return value.ready;
            }
        }
        let ready = audio::calendar_capture_ready(microphone, system_audio).is_ok();
        *cache = Some(Readiness {
            checked: Instant::now(),
            microphone: microphone.into(),
            system_audio: system_audio.into(),
            ready,
        });
        ready
    }
}
impl calendar::CalendarCapture for MeetingCapture {
    fn status(&self) -> calendar::CaptureStatus {
        let dictation_busy = dictation_busy(&self.app);
        let Ok((id, meeting_busy)) = meetings::capture_status(&self.app) else {
            return calendar::CaptureStatus {
                dictation_busy: true,
                meeting_busy: true,
                ..Default::default()
            };
        };
        let session_active = session_active();
        let unattended_ready =
            session_active && !dictation_busy && !meeting_busy && id.is_none() && self.ready(false);
        calendar::CaptureStatus {
            active_id: id.map(|id| id.to_string()),
            dictation_busy,
            meeting_busy,
            unattended_ready,
            session_active,
        }
    }
    fn start(&self, request: calendar::CalendarStart) -> Result<String, String> {
        if !session_active() {
            return Err(
                "Calendar recording skipped: the Windows session is locked or inactive.".into(),
            );
        }
        // Recheck current devices/permissions even if the countdown used a cached
        // readiness result. No access request or permissive fallback occurs.
        if !self.ready(true) {
            return Err("Calendar recording skipped. Enable Windows microphone access and check microphone/system audio devices.".into());
        }
        let record = meetings::start_meeting(
            self.app.clone(),
            request.title,
            request.microphone,
            request.system_audio,
            request.summarize_on_stop,
            request.live_transcription,
        )?;
        Ok(record.id.to_string())
    }
    fn finish(&self, summarize: Option<bool>) -> Result<(), String> {
        meetings::finish_in_background(self.app.clone(), summarize)
    }
}

pub fn install(app: &tauri::AppHandle) -> Result<(), String> {
    install_transcript_hooks();
    calendar::set_capture_adapter(
        app,
        Arc::new(MeetingCapture {
            app: app.clone(),
            readiness: Mutex::new(None),
        }),
    )
}
fn install_transcript_hooks() {
    let _ = provider::SPEECH_HINT_FACTORY.set(speech_hints);
    let _ = provider::TRANSCRIPT_FILTER.set(transcript_filter);
}

/// Both the process's WTS session and its current input desktop must be usable.
/// Locked/secure desktops, disconnected RDP sessions and API failures fail closed.
/// During sleep no ticks run; calendar's >10s stall check cancels old countdowns.
#[cfg(windows)]
fn session_active() -> bool {
    use std::{ffi::c_void, ptr};
    #[link(name = "wtsapi32")]
    extern "system" {
        fn WTSQuerySessionInformationW(
            server: *mut c_void,
            session: u32,
            class: i32,
            buffer: *mut *mut c_void,
            bytes: *mut u32,
        ) -> i32;
        fn WTSFreeMemory(buffer: *mut c_void);
    }
    #[link(name = "user32")]
    extern "system" {
        fn OpenInputDesktop(flags: u32, inherit: i32, access: u32) -> *mut c_void;
        fn GetUserObjectInformationW(
            handle: *mut c_void,
            index: i32,
            info: *mut c_void,
            size: u32,
            needed: *mut u32,
        ) -> i32;
        fn CloseDesktop(desktop: *mut c_void) -> i32;
    }
    // SAFETY: OS-owned buffers are length-checked, read once and always freed.
    // The desktop handle is closed after querying a bounded UTF-16 name buffer.
    unsafe {
        let mut buffer = ptr::null_mut();
        let mut bytes = 0;
        let queried =
            WTSQuerySessionInformationW(ptr::null_mut(), u32::MAX, 8, &mut buffer, &mut bytes);
        let active = queried != 0
            && !buffer.is_null()
            && bytes >= std::mem::size_of::<i32>() as u32
            && ptr::read_unaligned(buffer.cast::<i32>()) == 0;
        if !buffer.is_null() {
            WTSFreeMemory(buffer);
        }
        if !active {
            return false;
        }
        let desktop = OpenInputDesktop(0, 0, 1); // DESKTOP_READOBJECTS
        if desktop.is_null() {
            return false;
        }
        let mut name = [0_u16; 256];
        let mut needed = 0;
        let queried = GetUserObjectInformationW(
            desktop,
            2,
            name.as_mut_ptr().cast(),
            std::mem::size_of_val(&name) as u32,
            &mut needed,
        );
        CloseDesktop(desktop);
        let end = name.iter().position(|c| *c == 0).unwrap_or(name.len());
        queried != 0 && String::from_utf16_lossy(&name[..end]).eq_ignore_ascii_case("Default")
    }
}
#[cfg(not(windows))]
fn session_active() -> bool {
    false
}

#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test]
    async fn cancellation_wakes_pending_work_and_is_not_inherited_by_new_work() {
        let state = ActivityState::default();
        let generation = state.generation();
        state.cancel_generation.fetch_add(1, Ordering::SeqCst);
        state.cancel.notify_waiters();
        tokio::time::timeout(Duration::from_millis(100), state.cancelled(generation))
            .await
            .unwrap();
        assert!(tokio::time::timeout(
            Duration::from_millis(10),
            state.cancelled(state.generation())
        )
        .await
        .is_err());
    }
    use serde_json::json;
    #[test]
    fn setup_installs_the_provider_hooks_idempotently() {
        install_transcript_hooks();
        install_transcript_hooks();
        let settings: storage::AppSettings = serde_json::from_value(json!({"customVocabulary":["Qdrant"], "correctionRules":[{"heard":"old", "replacement":"new"}]})).unwrap();
        assert_eq!(
            provider::hints_for_settings(&settings),
            Some(speech_hints(&settings))
        );
        assert_eq!(
            provider::TRANSCRIPT_FILTER.get().unwrap()("old", &settings),
            "new"
        );
    }
    #[test]
    fn authoritative_settings_feed_shared_hints_and_keep_all_provider_fields() {
        let settings: storage::AppSettings = serde_json::from_value(json!({"speechProvider":"mistral", "customVocabulary":["Qdrant", 7], "correctionRules":[{"heard":"open scribe", "replacement":"OpenScribe"}, {"invalid":true}], "spokenCorrections":false, "learnSpelledWords":false, "correctionModel":"corrections", "languageModelProvider":"custom", "languageModelBaseURL":"http://localhost/v1", "languageModel":"writing"})).unwrap();
        let dictionary = dictionary_settings(&settings);
        assert!(!dictionary.spoken_corrections);
        assert!(!dictionary.learn_spelled_words);
        assert_eq!(dictionary.correction_model, "corrections");
        assert_eq!(dictionary.language_model_provider, "custom");
        assert_eq!(dictionary.language_model_base_url, "http://localhost/v1");
        assert_eq!(dictionary.language_model, "writing");
        assert_eq!(
            speech_hints(&settings),
            provider::SpeechHints {
                prompt: Some("Qdrant,OpenScribe".into()),
                terms: vec!["Qdrant".into(), "OpenScribe".into()]
            }
        );
    }
    #[test]
    fn local_meeting_filter_never_classifies_and_is_independent_of_hints_toggle() {
        let settings: storage::AppSettings = serde_json::from_value(json!({"customVocabulary":["Qdrant"], "correctionRules":[{"heard":"open scribe", "replacement":"OpenScribe"}], "speechHints":false, "spokenCorrections":true})).unwrap();
        assert_eq!(speech_hints(&settings), provider::SpeechHints::default());
        assert_eq!(
            transcript_filter(
                "open scribe uses Q drant Friday, no wait, Thursday",
                &settings
            ),
            "OpenScribe uses Q drant Friday, no wait, Thursday"
        );
        assert_eq!(
            transcript_filter(
                "open scribe uses Qd rant Friday, no wait, Thursday",
                &settings
            ),
            "OpenScribe uses Qdrant Friday, no wait, Thursday"
        );
    }
    #[test]
    fn dictation_lifecycle_and_nested_backend_work_release_independently() {
        let state = ActivityState::default();
        assert!(!state.busy());
        state.dictation_ui.store(true, Ordering::SeqCst);
        let first = state.work();
        let second = state.work();
        state.dictation_ui.store(false, Ordering::SeqCst);
        drop(first);
        assert!(state.busy());
        drop(second);
        assert!(!state.busy());
        let gate = state.start_gate().unwrap();
        assert!(state.starts.try_lock().is_err());
        drop(gate);
        assert!(state.starts.try_lock().is_ok());
    }
}
