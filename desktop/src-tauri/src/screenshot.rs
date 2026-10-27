//! Screen, window, and area screenshots.
//!
//! Images are captured with `xcap` and written to
//! `<app_data_dir>/Attachments/Screenshot-<UPPERCASE-UUID>.png`. The capture
//! record matches Swift's `NoteCapture` for a screenshot: empty title and
//! text, `kind` `"screenshot"`, and `createdAt` as ISO-8601 UTC without
//! fractional seconds. `sourceApplication` is the captured window's exe name
//! when the process can be resolved.
//!
//! Capture sound is part of the contract. Swift plays the shutter only when
//! `settings.interactionSounds` is on. This module does not play one: the
//! storage owner can call a preference-aware Windows `MessageBeep` once that
//! setting is available.

use crate::region_select::{self, PhysicalRect};
use image::RgbaImage;
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use tauri::{AppHandle, Manager};
use uuid::Uuid;

static CAPTURE_BUSY: AtomicBool = AtomicBool::new(false);

struct CaptureGuard;

impl Drop for CaptureGuard {
    fn drop(&mut self) {
        CAPTURE_BUSY.store(false, Ordering::Release);
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ScreenshotKind {
    Area,
    Window,
    Screen,
}

impl ScreenshotKind {
    pub fn parse(value: &str) -> Result<Self, String> {
        match value {
            "area" => Ok(Self::Area),
            "window" => Ok(Self::Window),
            "screen" => Ok(Self::Screen),
            _ => Err("Choose area, window, or screen.".into()),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NoteCapture {
    pub id: String,
    pub created_at: String,
    /// Swift stores an empty title; the notes UI labels the row "Screenshot".
    pub title: String,
    pub raw_text: String,
    pub text: String,
    pub duration: f64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub source_application: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub source_bundle_identifier: Option<String>,
    pub kind: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub attachment: Option<String>,
    #[serde(rename = "meetingID", skip_serializing_if = "Option::is_none")]
    pub meeting_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub recognized_text: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub superseded: Option<bool>,
}

impl NoteCapture {
    pub fn screenshot(
        created_at: String,
        attachment: String,
        source_application: Option<String>,
        source_bundle_identifier: Option<String>,
    ) -> Self {
        Self {
            id: uppercase_uuid(),
            created_at,
            title: String::new(),
            raw_text: String::new(),
            text: String::new(),
            duration: 0.0,
            source_application,
            source_bundle_identifier,
            kind: "screenshot".to_string(),
            attachment: Some(attachment),
            meeting_id: None,
            recognized_text: None,
            superseded: None,
        }
    }
}

#[derive(Debug, Clone)]
pub struct CapturedScreenshot {
    pub capture: NoteCapture,
    pub path: PathBuf,
}

pub fn uppercase_uuid() -> String {
    Uuid::new_v4().to_string().to_ascii_uppercase()
}

pub fn screenshot_file_name(uuid: &str) -> String {
    format!("Screenshot-{uuid}.png")
}

pub fn new_screenshot_file_name() -> String {
    screenshot_file_name(&uppercase_uuid())
}

/// ISO-8601 UTC with no fractional seconds (`2026-10-19T10:58:15Z`).
pub fn format_unix_seconds(unix_secs: i64) -> String {
    let days = unix_secs.div_euclid(86_400);
    let tod = unix_secs.rem_euclid(86_400) as u32;
    let hour = tod / 3600;
    let minute = (tod % 3600) / 60;
    let second = tod % 60;
    let (year, month, day) = civil_from_days(days);
    format!("{year:04}-{month:02}-{day:02}T{hour:02}:{minute:02}:{second:02}Z")
}

pub fn now_iso() -> String {
    let secs = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_secs() as i64)
        .unwrap_or(0);
    format_unix_seconds(secs)
}

/// Howard Hinnant's `civil_from_days`. `days` is the Unix day count.
fn civil_from_days(days: i64) -> (i32, u32, u32) {
    let z = days + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 }.div_euclid(146_097);
    let doe = (z - era * 146_097) as u64;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let year = yoe as i64 + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = if month <= 2 { year + 1 } else { year };
    (year as i32, month as u32, day as u32)
}

pub fn contains_point(x: i32, y: i32, left: i32, top: i32, width: u32, height: u32) -> bool {
    let x = i64::from(x);
    let y = i64::from(y);
    let left = i64::from(left);
    let top = i64::from(top);
    let right = left + i64::from(width);
    let bottom = top + i64::from(height);
    x >= left && y >= top && x < right && y < bottom
}

/// Capture `kind` and return the note row plus the PNG path.
/// `Ok(None)` means the user cancelled the area selector.
pub async fn capture(
    app: &AppHandle,
    kind: ScreenshotKind,
) -> Result<Option<CapturedScreenshot>, String> {
    if CAPTURE_BUSY.swap(true, Ordering::AcqRel) {
        return Err("A screenshot is already in progress.".into());
    }
    let _guard = CaptureGuard;
    match kind {
        ScreenshotKind::Screen => capture_screen(app).await.map(Some),
        ScreenshotKind::Window => capture_window(app).await.map(Some),
        ScreenshotKind::Area => capture_area(app).await,
    }
}

#[tauri::command]
pub async fn take_screenshot(app: AppHandle, kind: String) -> Result<Option<NoteCapture>, String> {
    let kind = ScreenshotKind::parse(&kind)?;
    let meeting_id = crate::storage_hooks::active_meeting_id(&app);
    let Some(shot) = capture(&app, kind).await? else {
        return Ok(None);
    };
    let mut capture = shot.capture;
    capture.meeting_id = meeting_id.clone();
    match crate::storage_hooks::add_screenshot_capture(&app, capture, meeting_id) {
        Ok(saved) => {
            crate::ocr::spawn_after_save(app, saved.id.clone(), shot.path);
            Ok(Some(saved))
        }
        Err(error) => {
            let _ = std::fs::remove_file(shot.path);
            Err(error)
        }
    }
}

async fn capture_screen(app: &AppHandle) -> Result<CapturedScreenshot, String> {
    let display = display_under_cursor()?;
    let restore = hide_flowbar(app);
    settle_overlay().await;
    let image = grab_monitor(display.id).await;
    if restore {
        show_flowbar(app);
    }
    let image = image?;
    persist(app, image, None)
}

async fn capture_window(app: &AppHandle) -> Result<CapturedScreenshot, String> {
    let (x, y) = cursor_position()?;
    let target = window_under_point(x, y)?;
    let window_id = target.id().map_err(|error| screenshot_failed(&error))?;
    let source = source_of(&target);
    let image = grab_window(window_id).await?;
    persist(app, image, Some(source))
}

async fn capture_area(app: &AppHandle) -> Result<Option<CapturedScreenshot>, String> {
    let display = display_under_cursor()?;
    let restore = hide_flowbar(app);
    let selected =
        region_select::select_on_monitor(app, display.x, display.y, display.width, display.height)
            .await;
    let selected = match selected {
        Ok(rect) => rect,
        Err(error) => {
            if restore {
                show_flowbar(app);
            }
            return Err(error);
        }
    };
    let Some(rect) = selected else {
        if restore {
            show_flowbar(app);
        }
        return Ok(None);
    };
    settle_overlay().await;
    let image = grab_region(display.id, rect).await;
    if restore {
        show_flowbar(app);
    }
    let image = image?;
    let source = source_at(
        display.x + rect.x as i32 + rect.width as i32 / 2,
        display.y + rect.y as i32 + rect.height as i32 / 2,
    );
    persist(app, image, source).map(Some)
}

struct Display {
    id: u32,
    x: i32,
    y: i32,
    width: u32,
    height: u32,
}

struct WindowSource {
    application: Option<String>,
    bundle: Option<String>,
}

fn display_under_cursor() -> Result<Display, String> {
    let (x, y) = cursor_position()?;
    let monitor =
        xcap::Monitor::from_point(x, y).map_err(|_| "No display under the pointer.".to_string())?;
    Ok(Display {
        id: monitor.id().map_err(|error| screenshot_failed(&error))?,
        x: monitor.x().map_err(|error| screenshot_failed(&error))?,
        y: monitor.y().map_err(|error| screenshot_failed(&error))?,
        width: monitor.width().map_err(|error| screenshot_failed(&error))?,
        height: monitor
            .height()
            .map_err(|error| screenshot_failed(&error))?,
    })
}

fn window_under_point(x: i32, y: i32) -> Result<xcap::Window, String> {
    let our_pid = std::process::id();
    let windows = xcap::Window::all().map_err(|error| screenshot_failed(&error))?;
    let mut best: Option<(i32, xcap::Window)> = None;
    for window in windows {
        if window.is_minimized().unwrap_or(true) {
            continue;
        }
        if window.pid().ok() == Some(our_pid) {
            continue;
        }
        let Ok(left) = window.x() else { continue };
        let Ok(top) = window.y() else { continue };
        let Ok(width) = window.width() else { continue };
        let Ok(height) = window.height() else {
            continue;
        };
        if width == 0 || height == 0 || !contains_point(x, y, left, top, width, height) {
            continue;
        }
        // xcap 0.9.8: a larger `z` is closer to the user. Windows `EnumWindows`
        // is top-to-bottom and the first HWND receives `len - 1`. macOS
        // `CGWindowListCopyWindowInfo` is top-to-bottom with the same
        // countdown. Linux reads `_NET_CLIENT_LIST_STACKING` (bottom-to-top)
        // and reverses it before that countdown.
        let z = window.z().unwrap_or(i32::MIN);
        let replace = best
            .as_ref()
            .is_none_or(|(best_z, _)| z_is_above(z, *best_z));
        if replace {
            best = Some((z, window));
        }
    }
    best.map(|(_, window)| window)
        .ok_or_else(|| "No window under the pointer.".to_string())
}

/// `candidate` is above `other` when its xcap z is greater.
fn z_is_above(candidate: i32, other: i32) -> bool {
    candidate > other
}

fn source_at(x: i32, y: i32) -> Option<WindowSource> {
    window_under_point(x, y)
        .ok()
        .map(|window| source_of(&window))
}

fn source_of(window: &xcap::Window) -> WindowSource {
    if let Ok(pid) = window.pid() {
        if let Some((name, path)) = process_executable(pid) {
            return WindowSource {
                application: Some(name),
                bundle: Some(path),
            };
        }
    }
    WindowSource {
        application: window.app_name().ok().filter(|name| !name.is_empty()),
        bundle: None,
    }
}

fn persist(
    app: &AppHandle,
    image: RgbaImage,
    source: Option<WindowSource>,
) -> Result<CapturedScreenshot, String> {
    let file_name = new_screenshot_file_name();
    let directory = attachments_dir(app)?;
    let path = directory.join(&file_name);
    if let Err(error) = image.save(&path) {
        let _ = std::fs::remove_file(&path);
        return Err(screenshot_failed(&error));
    }
    let source = source.unwrap_or(WindowSource {
        application: None,
        bundle: None,
    });
    let capture = NoteCapture::screenshot(now_iso(), file_name, source.application, source.bundle);
    Ok(CapturedScreenshot { capture, path })
}

fn attachments_dir(app: &AppHandle) -> Result<PathBuf, String> {
    let directory = app
        .path()
        .app_data_dir()
        .map_err(|_| "OpenScribe couldn't find its notes folder.".to_string())?
        .join("Attachments");
    std::fs::create_dir_all(&directory)
        .map_err(|_| "OpenScribe couldn't create the attachments folder.".to_string())?;
    Ok(directory)
}

fn hide_flowbar(app: &AppHandle) -> bool {
    let Some(window) = app.get_webview_window("flowbar") else {
        return false;
    };
    let visible = window.is_visible().unwrap_or(false);
    if visible {
        let _ = window.hide();
    }
    visible
}

fn show_flowbar(app: &AppHandle) {
    if let Some(window) = app.get_webview_window("flowbar") {
        let _ = window.show();
    }
}

async fn settle_overlay() {
    let _ = tauri::async_runtime::spawn_blocking(|| {
        std::thread::sleep(std::time::Duration::from_millis(120));
    })
    .await;
}

async fn grab_monitor(monitor_id: u32) -> Result<RgbaImage, String> {
    let joined = tauri::async_runtime::spawn_blocking(move || {
        let monitor = monitor_by_id(monitor_id)?;
        monitor
            .capture_image()
            .map_err(|error| screenshot_failed(&error))
    })
    .await
    .map_err(|_| "The screenshot was interrupted.".to_string())?;
    joined
}

async fn grab_region(monitor_id: u32, region: PhysicalRect) -> Result<RgbaImage, String> {
    let joined = tauri::async_runtime::spawn_blocking(move || {
        let monitor = monitor_by_id(monitor_id)?;
        monitor
            .capture_region(region.x, region.y, region.width, region.height)
            .map_err(|error| screenshot_failed(&error))
    })
    .await
    .map_err(|_| "The screenshot was interrupted.".to_string())?;
    joined
}

async fn grab_window(window_id: u32) -> Result<RgbaImage, String> {
    let joined = tauri::async_runtime::spawn_blocking(move || {
        let windows = xcap::Window::all().map_err(|error| screenshot_failed(&error))?;
        let window = windows
            .into_iter()
            .find(|window| window.id().ok() == Some(window_id))
            .ok_or_else(|| "No window under the pointer.".to_string())?;
        window
            .capture_image()
            .map_err(|error| screenshot_failed(&error))
    })
    .await
    .map_err(|_| "The screenshot was interrupted.".to_string())?;
    joined
}

fn monitor_by_id(monitor_id: u32) -> Result<xcap::Monitor, String> {
    xcap::Monitor::all()
        .map_err(|error| screenshot_failed(&error))?
        .into_iter()
        .find(|monitor| monitor.id().ok() == Some(monitor_id))
        .ok_or_else(|| "No display under the pointer.".to_string())
}

fn screenshot_failed(detail: &impl std::fmt::Display) -> String {
    let detail = detail.to_string().replace('\n', " ");
    if detail.is_empty() || detail.chars().count() > 160 {
        "The screenshot couldn’t be taken.".into()
    } else {
        format!("The screenshot couldn’t be taken. {detail}")
    }
}

#[cfg(windows)]
fn cursor_position() -> Result<(i32, i32), String> {
    use windows::Win32::Foundation::POINT;
    use windows::Win32::UI::WindowsAndMessaging::GetCursorPos;
    let mut point = POINT::default();
    unsafe { GetCursorPos(&mut point) }
        .map_err(|_| "OpenScribe couldn't read the pointer position.".to_string())?;
    Ok((point.x, point.y))
}

#[cfg(not(windows))]
fn cursor_position() -> Result<(i32, i32), String> {
    Err("Taking a screenshot from the pointer is not supported on this platform.".into())
}

#[cfg(windows)]
fn process_executable(pid: u32) -> Option<(String, String)> {
    use windows::Win32::Foundation::CloseHandle;
    use windows::Win32::System::Threading::{
        OpenProcess, QueryFullProcessImageNameW, PROCESS_NAME_WIN32,
        PROCESS_QUERY_LIMITED_INFORMATION,
    };
    if pid == 0 {
        return None;
    }
    let handle = unsafe { OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid) }.ok()?;
    struct CloseOnDrop(windows::Win32::Foundation::HANDLE);
    impl Drop for CloseOnDrop {
        fn drop(&mut self) {
            unsafe {
                let _ = CloseHandle(self.0);
            }
        }
    }
    let handle = CloseOnDrop(handle);
    let mut buffer = vec![0u16; 32_768];
    let mut length = buffer.len() as u32;
    unsafe {
        QueryFullProcessImageNameW(
            handle.0,
            PROCESS_NAME_WIN32,
            windows::core::PWSTR(buffer.as_mut_ptr()),
            &mut length,
        )
    }
    .ok()?;
    let path = String::from_utf16_lossy(&buffer[..length as usize]);
    let name = Path::new(&path)
        .file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .filter(|name| !name.is_empty())?;
    Some((name, path))
}

#[cfg(not(windows))]
fn process_executable(_pid: u32) -> Option<(String, String)> {
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn screenshot_names_use_an_uppercase_uuid() {
        let name = new_screenshot_file_name();
        let uuid = name
            .strip_prefix("Screenshot-")
            .and_then(|rest| rest.strip_suffix(".png"))
            .expect("prefix and suffix");
        assert_eq!(uuid, uuid.to_ascii_uppercase());
        assert!(uuid.contains('-'));
        assert!(!uuid.chars().any(|character| character.is_ascii_lowercase()));
        Uuid::parse_str(uuid).expect("uuid");
        assert_eq!(
            screenshot_file_name("E621E1F8-C36C-495A-93FC-0C247A3E6E5F"),
            "Screenshot-E621E1F8-C36C-495A-93FC-0C247A3E6E5F.png"
        );
    }

    #[test]
    fn iso_8601_has_no_fractional_seconds() {
        assert_eq!(format_unix_seconds(0), "1970-01-01T00:00:00Z");
        assert_eq!(format_unix_seconds(978_307_200), "2001-01-01T00:00:00Z");
        assert_eq!(format_unix_seconds(1_000_000_000), "2001-09-09T01:46:40Z");
        assert_eq!(format_unix_seconds(1_582_934_400), "2020-02-29T00:00:00Z");
        assert_eq!(format_unix_seconds(-1), "1969-12-31T23:59:59Z");
        let now = now_iso();
        assert_eq!(now.len(), 20);
        assert!(now.ends_with('Z'));
        assert!(!now.contains('.'));
    }

    #[test]
    fn kind_parser_accepts_only_the_three_capture_modes() {
        assert_eq!(ScreenshotKind::parse("area").unwrap(), ScreenshotKind::Area);
        assert_eq!(
            ScreenshotKind::parse("window").unwrap(),
            ScreenshotKind::Window
        );
        assert_eq!(
            ScreenshotKind::parse("screen").unwrap(),
            ScreenshotKind::Screen
        );
        assert_eq!(
            ScreenshotKind::parse("desktop").unwrap_err(),
            "Choose area, window, or screen."
        );
    }

    #[test]
    fn note_capture_matches_the_swift_screenshot_shape() {
        let capture = NoteCapture::screenshot(
            "2026-10-19T10:58:15Z".into(),
            "Screenshot-E621E1F8-C36C-495A-93FC-0C247A3E6E5F.png".into(),
            Some("chrome.exe".into()),
            Some(r"C:\Program Files\Google\Chrome\Application\chrome.exe".into()),
        );
        let json = serde_json::to_value(&capture).unwrap();
        assert_eq!(json["kind"], "screenshot");
        assert_eq!(json["title"], "");
        assert_eq!(json["rawText"], "");
        assert_eq!(json["text"], "");
        assert_eq!(json["duration"], 0.0);
        assert_eq!(json["createdAt"], "2026-10-19T10:58:15Z");
        assert_eq!(
            json["attachment"],
            "Screenshot-E621E1F8-C36C-495A-93FC-0C247A3E6E5F.png"
        );
        assert_eq!(json["sourceApplication"], "chrome.exe");
        assert_eq!(
            json["sourceBundleIdentifier"],
            r"C:\Program Files\Google\Chrome\Application\chrome.exe"
        );
        assert!(json.get("meetingID").is_none());
        assert!(json.get("meetingId").is_none());
        assert!(json.get("recognizedText").is_none());
        assert!(json.get("superseded").is_none());
        assert_eq!(
            json["id"].as_str().unwrap(),
            json["id"].as_str().unwrap().to_ascii_uppercase()
        );

        let mut linked = capture.clone();
        linked.meeting_id = Some("E621E1F8-C36C-495A-93FC-0C247A3E6E5F".into());
        let linked = serde_json::to_value(&linked).unwrap();
        assert_eq!(linked["meetingID"], "E621E1F8-C36C-495A-93FC-0C247A3E6E5F");
    }

    #[test]
    fn larger_xcap_z_is_the_topmost_window() {
        assert!(z_is_above(5, 1));
        assert!(!z_is_above(1, 5));
        assert!(!z_is_above(3, 3));
    }

    #[test]
    fn hit_test_includes_the_origin_and_excludes_the_far_edge() {
        assert!(contains_point(0, 0, 0, 0, 10, 10));
        assert!(!contains_point(10, 0, 0, 0, 10, 10));
        assert!(contains_point(-5, -5, -10, -10, 10, 10));
        assert!(!contains_point(0, 0, -10, -10, 10, 10));
    }
}
