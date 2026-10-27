//! Windows counterparts for setup, source-app styles, startup and user-selected exports.
use cpal::traits::{DeviceTrait, HostTrait};
use serde::Serialize;
use std::path::PathBuf;
use tauri::Manager;

#[derive(Clone, Debug, Serialize)]
pub struct SourceApp {
    pub id: String,
    pub name: String,
    pub path: String,
}

#[cfg(windows)]
fn process_app(pid: u32) -> Option<SourceApp> {
    use windows::Win32::{
        Foundation::CloseHandle,
        System::Threading::{
            OpenProcess, QueryFullProcessImageNameW, PROCESS_NAME_WIN32,
            PROCESS_QUERY_LIMITED_INFORMATION,
        },
    };
    if pid == 0 || pid == std::process::id() {
        return None;
    }
    unsafe {
        let process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid).ok()?;
        let mut path = vec![0_u16; 32768];
        let mut length = path.len() as u32;
        let result = QueryFullProcessImageNameW(
            process,
            PROCESS_NAME_WIN32,
            windows::core::PWSTR(path.as_mut_ptr()),
            &mut length,
        );
        let _ = CloseHandle(process);
        result.ok()?;
        let path = String::from_utf16_lossy(&path[..length as usize]);
        let name = std::path::Path::new(&path)
            .file_stem()?
            .to_string_lossy()
            .into_owned();
        Some(SourceApp {
            id: path.to_lowercase(),
            name,
            path,
        })
    }
}

#[tauri::command]
pub fn get_foreground_app() -> Option<SourceApp> {
    #[cfg(windows)]
    {
        use windows::Win32::UI::WindowsAndMessaging::{
            GetForegroundWindow, GetWindowThreadProcessId,
        };
        let mut pid = 0;
        unsafe {
            GetWindowThreadProcessId(GetForegroundWindow(), Some(&mut pid));
        }
        process_app(pid)
    }
    #[cfg(not(windows))]
    {
        None
    }
}

#[tauri::command]
pub fn list_source_apps() -> Result<Vec<SourceApp>, String> {
    #[cfg(windows)]
    {
        use windows::{
            core::BOOL,
            Win32::{
                Foundation::{HWND, LPARAM},
                UI::WindowsAndMessaging::{EnumWindows, GetWindowThreadProcessId, IsWindowVisible},
            },
        };
        unsafe extern "system" fn collect(hwnd: HWND, data: LPARAM) -> BOOL {
            if unsafe { IsWindowVisible(hwnd) }.as_bool() {
                let mut pid = 0;
                unsafe {
                    GetWindowThreadProcessId(hwnd, Some(&mut pid));
                }
                if let Some(app) = process_app(pid) {
                    let apps = unsafe { &mut *(data.0 as *mut Vec<SourceApp>) };
                    if !apps.iter().any(|existing| existing.id == app.id) {
                        apps.push(app);
                    }
                }
            }
            BOOL(1)
        }
        let mut apps = Vec::<SourceApp>::new();
        unsafe { EnumWindows(Some(collect), LPARAM(&mut apps as *mut _ as isize)) }
            .map_err(|e| e.to_string())?;
        apps.sort_by_key(|app| app.name.to_lowercase());
        Ok(apps)
    }
    #[cfg(not(windows))]
    {
        Err("Application selection is available on Windows.".into())
    }
}

#[derive(Serialize)]
pub struct AccessStatus {
    ready: bool,
    detail: String,
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CaptureReadiness {
    microphone: AccessStatus,
    system_audio: AccessStatus,
    paste: AccessStatus,
    calendar: AccessStatus,
}
fn status(result: Result<(), String>, success: &str) -> AccessStatus {
    match result {
        Ok(()) => AccessStatus {
            ready: true,
            detail: success.into(),
        },
        Err(detail) => AccessStatus {
            ready: false,
            detail,
        },
    }
}
fn audio_ready(system: bool, selected: &str) -> Result<(), String> {
    let host = cpal::default_host();
    let device = if selected.is_empty() {
        if system {
            host.default_output_device()
        } else {
            host.default_input_device()
        }
    } else if system {
        host.output_devices()
            .map_err(|e| e.to_string())?
            .find(|d| d.name().ok().as_deref() == Some(selected))
    } else {
        host.input_devices()
            .map_err(|e| e.to_string())?
            .find(|d| d.name().ok().as_deref() == Some(selected))
    }
    .ok_or_else(|| {
        if system {
            "No system-audio output device is available."
        } else {
            "No microphone is available. Check Windows microphone access and the selected device."
        }
        .to_string()
    })?;
    let config = if system {
        device.default_output_config()
    } else {
        device.default_input_config()
    }
    .map_err(|e| e.to_string())?;
    // Initializing a client checks device/privacy access without playing or recording samples.
    let _probe = device
        .build_input_stream_raw(
            &config.config(),
            config.sample_format(),
            |_, _| {},
            |_| {},
            None,
        )
        .map_err(|e| e.to_string())?;
    Ok(())
}
#[tauri::command]
pub fn capture_readiness(app: tauri::AppHandle) -> Result<CaptureReadiness, String> {
    let settings =
        crate::storage::with_profile(&app, &app.state::<crate::storage::ProfileState>(), |s| {
            Ok(s.settings.clone())
        })?;
    Ok(CaptureReadiness {
        microphone: status(audio_ready(false, settings.string("microphoneDeviceUID")), "Microphone access is available."),
        system_audio: status(if cfg!(windows) { audio_ready(true, settings.string("systemAudioDeviceId")) } else { Err("System audio capture requires Windows.".into()) }, "WASAPI system-audio access is available."),
        paste: status(if cfg!(windows) { Ok(()) } else { Err("Check your desktop's input permissions.".into()) }, "Windows paste is available. Apps running as administrator may block input from OpenScribe."),
        calendar: status(if settings.0.get("calendarSources").and_then(|v| v.as_array()).is_some_and(|v| !v.is_empty()) { Ok(()) } else { Err("Add an ICS URL or file in Calendar settings. Windows does not require macOS Calendar permission.".into()) }, "Calendar sources are configured; refresh Calendar to verify access."),
    })
}

#[tauri::command]
pub fn open_windows_settings(section: String) -> Result<(), String> {
    let uri = match section.as_str() {
        "microphone" => "ms-settings:privacy-microphone",
        "sound" => "ms-settings:sound",
        _ => return Err("Unknown Windows settings page.".into()),
    };
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        std::process::Command::new("explorer.exe")
            .arg(uri)
            .creation_flags(0x08000000)
            .spawn()
            .map_err(|e| e.to_string())?;
        Ok(())
    }
    #[cfg(not(windows))]
    {
        let _ = uri;
        Err("Windows settings are not available on this platform.".into())
    }
}

#[cfg(windows)]
mod startup {
    use windows::{
        core::{w, PCWSTR},
        Win32::{Foundation::ERROR_FILE_NOT_FOUND, System::Registry::*},
    };
    const RUN: PCWSTR = w!("Software\\Microsoft\\Windows\\CurrentVersion\\Run");
    pub fn get() -> Result<bool, String> {
        let mut bytes = 0;
        let result = unsafe {
            RegGetValueW(
                HKEY_CURRENT_USER,
                RUN,
                w!("OpenScribe"),
                RRF_RT_REG_SZ,
                None,
                None,
                Some(&mut bytes),
            )
        };
        if result == ERROR_FILE_NOT_FOUND {
            return Ok(false);
        }
        result.ok().map_err(|e| e.to_string())?;
        Ok(bytes > 2)
    }
    pub fn set(enabled: bool) -> Result<(), String> {
        let mut key = HKEY::default();
        unsafe {
            RegCreateKeyExW(
                HKEY_CURRENT_USER,
                RUN,
                None,
                PCWSTR::null(),
                REG_OPTION_NON_VOLATILE,
                KEY_SET_VALUE,
                None,
                &mut key,
                None,
            )
        }
        .ok()
        .map_err(|e| e.to_string())?;
        let result = if enabled {
            let exe = std::env::current_exe().map_err(|e| e.to_string());
            match exe {
                Ok(exe) => {
                    let value: Vec<u16> = format!("\"{}\"", exe.display())
                        .encode_utf16()
                        .chain(Some(0))
                        .collect();
                    let bytes: Vec<u8> = value.iter().flat_map(|c| c.to_le_bytes()).collect();
                    unsafe { RegSetValueExW(key, w!("OpenScribe"), None, REG_SZ, Some(&bytes)) }
                        .ok()
                        .map_err(|e| e.to_string())
                }
                Err(e) => Err(e),
            }
        } else {
            let result = unsafe { RegDeleteValueW(key, w!("OpenScribe")) };
            if result == ERROR_FILE_NOT_FOUND {
                Ok(())
            } else {
                result.ok().map_err(|e| e.to_string())
            }
        };
        let _ = unsafe { RegCloseKey(key) };
        result
    }
}
#[tauri::command]
pub fn get_launch_at_login() -> Result<bool, String> {
    #[cfg(windows)]
    {
        startup::get()
    }
    #[cfg(not(windows))]
    {
        Err("Launch at login is not supported on this platform.".into())
    }
}
#[tauri::command]
pub fn set_launch_at_login(enabled: bool) -> Result<(), String> {
    #[cfg(windows)]
    {
        startup::set(enabled)
    }
    #[cfg(not(windows))]
    {
        let _ = enabled;
        Err("Launch at login is not supported on this platform.".into())
    }
}

#[tauri::command]
pub fn export_text_file(path: String, text: String) -> Result<(), String> {
    let path = PathBuf::from(path);
    if !matches!(
        path.extension().and_then(|v| v.to_str()),
        Some("txt" | "md")
    ) {
        return Err("Choose a .txt or .md file.".into());
    }
    let parent = path.parent().ok_or("Choose an export folder.")?;
    let mut file = tempfile::NamedTempFile::new_in(parent).map_err(|e| e.to_string())?;
    use std::io::Write;
    file.write_all(text.as_bytes())
        .and_then(|_| file.as_file().sync_all())
        .map_err(|e| e.to_string())?;
    file.persist(&path).map_err(|e| e.to_string())?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn exports_only_text_files_and_replaces_complete_contents() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("note.md");
        export_text_file(path.to_string_lossy().into(), "First".into()).unwrap();
        export_text_file(path.to_string_lossy().into(), "Replacement".into()).unwrap();
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "Replacement");
        assert!(export_text_file(
            dir.path().join("program.exe").to_string_lossy().into(),
            "text".into()
        )
        .is_err());
    }
}
