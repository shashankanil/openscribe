//! Keep the workspace reachable while its close button hides it for capture.
use tauri::{menu::MenuBuilder, tray::TrayIconBuilder, Emitter, Manager};

pub fn install(app: &tauri::AppHandle) -> tauri::Result<()> {
    let menu = MenuBuilder::new(app)
        .text("workspace", "Open OpenScribe")
        .text("flowbar", "Show Flowbar")
        .separator()
        .text("dictate", "Start / finish dictation")
        .text("cancelDictation", "Cancel dictation")
        .text("meeting", "Start / finish meeting")
        .text("pauseMeeting", "Pause / resume meeting")
        .text("pasteLast", "Paste last text")
        .separator()
        .text("area", "Capture area")
        .text("window", "Capture window")
        .text("screen", "Capture screen")
        .separator()
        .text("settings", "Settings…")
        .text("shortcuts", "Edit shortcuts…")
        .separator()
        .text("quit", "Quit OpenScribe")
        .build()?;
    let icon = app.default_window_icon().cloned().unwrap_or_else(|| {
        let mut rgba = vec![0_u8; 16 * 16 * 4];
        for y in 2..14 {
            for x in 2..14 {
                let pixel = (y * 16 + x) * 4;
                rgba[pixel..pixel + 4].copy_from_slice(&[37, 99, 235, 255]);
                if (7..9).contains(&x) && (4..12).contains(&y) {
                    rgba[pixel..pixel + 4].copy_from_slice(&[255, 255, 255, 255]);
                }
            }
        }
        tauri::image::Image::new_owned(rgba, 16, 16)
    });
    TrayIconBuilder::with_id("openscribe")
        .icon(icon)
        .tooltip("OpenScribe 0.5")
        .menu(&menu)
        .show_menu_on_left_click(true)
        .on_menu_event(|app, event| match event.id().as_ref() {
            "workspace" | "flowbar" => {
                let label = if event.id().as_ref() == "workspace" {
                    "main"
                } else {
                    "flowbar"
                };
                if let Some(window) = app.get_webview_window(label) {
                    let _ = window.show();
                    if label == "main" {
                        let _ = window.set_focus();
                    }
                }
            }
            "quit" => {
                let meeting_busy = crate::meetings::capture_status(app)
                    .map(|(active, busy)| active.is_some() || busy)
                    .unwrap_or(true);
                if crate::integration::dictation_busy(app) || meeting_busy {
                    if let Some(window) = app.get_webview_window("main") {
                        let _ = window.show();
                        let _ = window.set_focus();
                    }
                    let _ = app.emit(
                        "app://error",
                        "Finish the active capture or processing before quitting OpenScribe.",
                    );
                } else {
                    app.exit(0);
                }
            }
            "dictate" | "cancelDictation" | "meeting" | "pauseMeeting" | "pasteLast" => {
                let _ = app.emit_to(
                    "main",
                    "workspace://intent",
                    serde_json::json!({"action": event.id().as_ref()}),
                );
            }
            "area" | "window" | "screen" => {
                let _ = app.emit_to(
                    "main",
                    "workspace://intent",
                    serde_json::json!({"action":"screenshot", "kind":event.id().as_ref()}),
                );
            }
            "settings" | "shortcuts" => {
                let section = if event.id().as_ref() == "shortcuts" {
                    "shortcuts"
                } else {
                    "general"
                };
                let _ = app.emit_to(
                    "main",
                    "workspace://intent",
                    serde_json::json!({"action":"settings", "section":section}),
                );
            }
            _ => {}
        })
        .build(app)?;
    Ok(())
}
