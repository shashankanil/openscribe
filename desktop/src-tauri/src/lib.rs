mod audio;
mod credentials;
mod platform;
mod provider;

use serde::Serialize;
use std::path::PathBuf;
use tauri::{Emitter, Manager};

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct RecordingResult {
    path: String,
    duration: f64,
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
    let root = app
        .path()
        .app_data_dir()
        .map_err(|error| error.to_string())?
        .join("Recordings");
    audio::start(&state, device_id, root).map(|path| path.to_string_lossy().to_string())
}

#[tauri::command]
fn stop_recording(state: tauri::State<audio::RecorderState>) -> Result<RecordingResult, String> {
    let (path, duration) = audio::stop(&state)?;
    Ok(RecordingResult {
        path: path.to_string_lossy().to_string(),
        duration,
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

#[tauri::command]
fn remove_credential(account: String) -> Result<(), String> {
    credentials::remove(&account)
}

#[tauri::command]
async fn transcribe_recording(
    path: String,
    config: provider::ProviderConfig,
) -> Result<provider::ProviderResult, String> {
    provider::transcribe(&PathBuf::from(path), &config).await
}

#[tauri::command]
async fn clean_transcript(
    text: String,
    config: provider::ProviderConfig,
    instruction: String,
) -> Result<provider::ProviderResult, String> {
    provider::clean(&text, &config, &instruction).await
}

#[tauri::command]
fn paste_keystroke() -> Result<(), String> {
    platform::paste_keystroke()
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .manage(audio::RecorderState::default())
        .plugin(tauri_plugin_store::Builder::default().build())
        .plugin(tauri_plugin_clipboard_manager::init())
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_global_shortcut::Builder::new().build())
        .setup(|app| {
            if let Some(window) = app.get_webview_window("main") {
                let _ = window.emit("openscribe-ready", ());
            }
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            list_audio_inputs,
            start_recording,
            stop_recording,
            delete_recording,
            save_credential,
            has_credential,
            remove_credential,
            transcribe_recording,
            clean_transcript,
            paste_keystroke
        ])
        .run(tauri::generate_context!())
        .expect("error while running OpenScribe");
}
