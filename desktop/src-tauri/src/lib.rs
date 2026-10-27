#![recursion_limit = "256"]

pub mod apple_time;
mod audio;
pub mod calendar;
mod credentials;
mod desktop_integration;
pub mod dictionary;
pub mod integration;
pub mod meeting_audio;
pub mod meetings;
mod migrate;
mod modifier_hold;
pub mod notes;
pub mod ocr;
mod platform;
pub mod provider;
mod realtime;
pub mod region_select;
pub mod screenshot;
pub mod shortcuts;
pub mod storage;
mod storage_hooks;
pub mod summary;
mod tray;

use serde::Serialize;
use std::path::PathBuf;
use tauri::{Emitter, Manager};

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct RecordingResult {
    path: String,
    duration: f64,
    transcript: Option<String>,
}

#[tauri::command]
fn list_audio_inputs() -> Result<Vec<audio::AudioInput>, String> {
    audio::inputs()
}

#[tauri::command]
fn start_recording(
    app: tauri::AppHandle,
    state: tauri::State<audio::RecorderState>,
    device_id: Option<String>,
) -> Result<String, String> {
    let activity = app.state::<integration::ActivityState>();
    let _start = activity.start_gate()?;
    let (id, busy) = meetings::capture_status(&app)?;
    if id.is_some() || busy {
        return Err("Finish the meeting before starting dictation.".into());
    }
    let root = app
        .path()
        .app_data_dir()
        .map_err(|error| error.to_string())?
        .join("Recordings");
    audio::start(&state, device_id, root, app.clone())
        .map(|path| path.to_string_lossy().to_string())
}

#[tauri::command]
async fn stop_recording(
    app: tauri::AppHandle,
    cancel: Option<bool>,
) -> Result<RecordingResult, String> {
    let recorder_app = app.clone();
    let (path, duration, live) = tauri::async_runtime::spawn_blocking(move || {
        audio::stop(&recorder_app.state::<audio::RecorderState>())
    })
    .await
    .map_err(|_| "The recorder stopped unexpectedly.".to_string())??;
    let transcript = match live {
        Some(live) => live.finish(cancel.unwrap_or(false)).await,
        None => None,
    };
    Ok(RecordingResult {
        path: path.to_string_lossy().to_string(),
        duration,
        transcript,
    })
}

#[tauri::command]
fn delete_recording(app: tauri::AppHandle, path: String) -> Result<(), String> {
    let recordings = app
        .path()
        .app_data_dir()
        .map_err(|error| error.to_string())?
        .join("Recordings");
    let target = PathBuf::from(path);
    let recordings = recordings
        .canonicalize()
        .map_err(|error| error.to_string())?;
    let target = target.canonicalize().map_err(|error| error.to_string())?;
    if !target.starts_with(&recordings) {
        return Err("OpenScribe can only remove its own recordings.".into());
    }
    std::fs::remove_file(target).map_err(|error| error.to_string())
}

#[tauri::command]
fn save_credential(account: String, secret: String) -> Result<(), String> {
    credentials::save(&account, &secret)
}

#[tauri::command]
fn has_credential(account: String) -> Result<bool, String> {
    credentials::read(&account).map(|value| value.is_some())
}

/// Reuses one saved key for another scope without the secret ever reaching the webview.
#[tauri::command]
fn copy_credential(from: String, to: String) -> Result<(), String> {
    credentials::copy(&from, &to)
}

#[tauri::command]
fn remove_credential(account: String) -> Result<(), String> {
    credentials::remove(&account)
}

#[tauri::command]
async fn transcribe_recording(
    app: tauri::AppHandle,
    path: String,
    config: provider::ProviderConfig,
    hints: Option<provider::SpeechHints>,
) -> Result<provider::ProviderResult, String> {
    let _work = integration::dictation_work(&app)?;
    let hints = match hints {
        Some(hints) => Some(hints),
        None => storage::with_profile(&app, &app.state::<storage::ProfileState>(), |s| {
            // The command's provider/model may come from a recovery job snapshot.
            Ok(Some(integration::hints_for_provider(
                &s.settings,
                &config.provider,
                &config.model,
            )))
        })?,
    };
    let state = app.state::<integration::ActivityState>();
    let generation = state.generation();
    let path = PathBuf::from(path);
    tokio::select! {
        result = provider::transcribe(&path, &config, hints.as_ref()) => result,
        () = state.cancelled(generation) => Err("Dictation cancelled.".into()),
    }
}

#[tauri::command]
async fn clean_transcript(
    app: tauri::AppHandle,
    text: String,
    config: provider::ProviderConfig,
    instruction: String,
) -> Result<provider::ProviderResult, String> {
    let _work = integration::dictation_work(&app)?;
    let state = app.state::<integration::ActivityState>();
    let generation = state.generation();
    tokio::select! {
        result = provider::clean(&text, &config, &instruction) => result,
        () = state.cancelled(generation) => Err("Dictation cancelled.".into()),
    }
}

#[tauri::command]
fn paste_keystroke() -> Result<(), String> {
    platform::paste_keystroke()
}

/// Pastes dictated text into the focused app and gives the clipboard back afterwards.
#[tauri::command]
async fn paste_text(app: tauri::AppHandle, text: String) -> Result<(), String> {
    #[cfg(windows)]
    {
        let _ = app;
        tauri::async_runtime::spawn_blocking(move || platform::paste_text(&text))
            .await
            .map_err(|error| error.to_string())?
    }
    #[cfg(not(windows))]
    {
        use tauri_plugin_clipboard_manager::ClipboardExt;
        app.clipboard()
            .write_text(text)
            .map_err(|error| error.to_string())?;
        platform::paste_keystroke()
    }
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .manage(audio::RecorderState::default())
        .manage(storage::ProfileState::default())
        .manage(meetings::MeetingState::default())
        .manage(shortcuts::ShortcutManager::default())
        .manage(calendar::CalendarState::default())
        .manage(integration::ActivityState::default())
        .plugin(tauri_plugin_store::Builder::default().build())
        .plugin(tauri_plugin_clipboard_manager::init())
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_global_shortcut::Builder::new().build())
        .setup(|app| {
            integration::install(app.handle()).map_err(std::io::Error::other)?;
            tray::install(app.handle())?;
            calendar::boot(app.handle().clone());
            if let Some(window) = app.get_webview_window("main") {
                let _ = window.emit("openscribe-ready", ());
            }
            Ok(())
        })
        .on_window_event(|window, event| {
            if let tauri::WindowEvent::CloseRequested { api, .. } = event {
                if matches!(window.label(), "main" | "meeting-notes") {
                    api.prevent_close();
                    let _ = window.hide();
                }
            }
        })
        .invoke_handler(tauri::generate_handler![
            list_audio_inputs,
            desktop_integration::get_foreground_app,
            desktop_integration::list_source_apps,
            desktop_integration::capture_readiness,
            desktop_integration::open_windows_settings,
            desktop_integration::get_launch_at_login,
            desktop_integration::set_launch_at_login,
            desktop_integration::export_text_file,
            start_recording,
            stop_recording,
            delete_recording,
            save_credential,
            has_credential,
            copy_credential,
            remove_credential,
            transcribe_recording,
            clean_transcript,
            paste_keystroke,
            paste_text,
            storage::load_profile,
            storage::save_settings,
            storage::save_note,
            storage::delete_note,
            storage::add_capture,
            storage::update_capture,
            storage::remove_capture,
            storage::attachment_path,
            meetings::list_meetings,
            meetings::start_meeting,
            meetings::pause_meeting,
            meetings::resume_meeting,
            meetings::finish_meeting,
            meetings::process_meeting,
            meetings::summarize_short_meeting,
            meetings::skip_summary,
            meetings::retry_live_transcription,
            meetings::cancel_processing,
            meetings::update_meeting,
            meetings::delete_meeting,
            meetings::export_meeting_markdown,
            meetings::meeting_audio_path,
            meetings::list_meeting_audio_chunks,
            integration::apply_dictionary,
            integration::set_dictation_busy,
            integration::cancel_dictation_work,
            shortcuts::register_shortcuts,
            shortcuts::suspend_shortcuts,
            shortcuts::set_escape_active,
            calendar::calendar_refresh,
            calendar::calendar_decision,
            screenshot::take_screenshot,
            region_select::complete_region_select,
            region_select::cancel_region_select
        ])
        .run(tauri::generate_context!())
        .expect("error while running OpenScribe");
}
