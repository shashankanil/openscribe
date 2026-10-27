//! Full-screen area selector for the monitor under the pointer.
//!
//! The overlay is sized in physical pixels. The page reports the drag in CSS
//! pixels plus the viewport, and [`map_drag`] converts that into physical
//! pixels relative to the monitor. That ratio is the DPI scale, including
//! fractional scales such as 1.25 and 1.5.
//!
//! Closing the overlay with Alt+F4 or the window Close button cancels only
//! the session that created it, so `select_on_monitor` cannot wait forever.
//! The webview stays transparent, content-protected, and hidden until the
//! page has painted, then hidden again before the capture runs.

use serde::Deserialize;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tauri::{
    window::Color, AppHandle, Manager, PhysicalPosition, PhysicalSize, WebviewUrl,
    WebviewWindowBuilder,
};

pub const REGION_WINDOW_LABEL: &str = "region-select";

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct LogicalRect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PhysicalRect {
    pub x: u32,
    pub y: u32,
    pub width: u32,
    pub height: u32,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct RegionDrag {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
    viewport_width: f64,
    viewport_height: f64,
    device_pixel_ratio: f64,
}

struct PendingSelect {
    session: u64,
    sender: tokio::sync::oneshot::Sender<Option<RegionDrag>>,
}

static REGION_WAIT: Mutex<Option<PendingSelect>> = Mutex::new(None);
static NEXT_SESSION: AtomicU64 = AtomicU64::new(1);
/// Session that currently owns the `region-select` window. `0` means none.
static OVERLAY_OWNER: AtomicU64 = AtomicU64::new(0);

fn wait_slot() -> std::sync::MutexGuard<'static, Option<PendingSelect>> {
    REGION_WAIT
        .lock()
        .unwrap_or_else(|error| error.into_inner())
}

fn next_session() -> u64 {
    NEXT_SESSION.fetch_add(1, Ordering::Relaxed)
}

fn owns_session(pending: Option<u64>, session: u64) -> bool {
    pending == Some(session)
}

/// Complete this session's wait with cancel. A close or destroy from an older
/// overlay cannot complete a newer selection, and a second send is a no-op.
fn cancel_overlay_session(session: u64) {
    let mut slot = wait_slot();
    if owns_session(slot.as_ref().map(|pending| pending.session), session) {
        if let Some(pending) = slot.take() {
            let _ = pending.sender.send(None);
        }
    }
}

fn hide_owned_overlay(app: &AppHandle, session: u64) {
    if OVERLAY_OWNER.load(Ordering::Acquire) != session {
        return;
    }
    if let Some(window) = app.get_webview_window(REGION_WINDOW_LABEL) {
        let _ = window.hide();
    }
}

fn dismiss_owned_overlay(app: &AppHandle, session: u64) {
    if OVERLAY_OWNER
        .compare_exchange(session, 0, Ordering::AcqRel, Ordering::Acquire)
        .is_err()
    {
        return;
    }
    if let Some(window) = app.get_webview_window(REGION_WINDOW_LABEL) {
        let _ = window.hide();
        let _ = window.destroy();
    }
}

fn hide_overlay_window(app: &AppHandle) {
    if let Some(window) = app.get_webview_window(REGION_WINDOW_LABEL) {
        let _ = window.hide();
    }
}

/// Map a CSS-pixel drag onto a monitor's physical pixels.
///
/// When the viewport is known, each axis is `monitor_pixels / viewport_css_pixels`.
/// That is the scale the webview is actually using, so a 1.25 or 1.5 display
/// lands on whole physical pixels. A drag under 2 CSS pixels is a click, not a
/// selection, and comes back as `None` (the same outcome as Escape).
pub fn map_drag(
    selection: LogicalRect,
    viewport_width: f64,
    viewport_height: f64,
    device_pixel_ratio: f64,
    monitor_width: u32,
    monitor_height: u32,
) -> Option<PhysicalRect> {
    if viewport_width >= 1.0 && viewport_height >= 1.0 {
        return map_selection_to_monitor(
            selection,
            viewport_width,
            viewport_height,
            monitor_width,
            monitor_height,
        );
    }
    let scale = if device_pixel_ratio.is_finite() && device_pixel_ratio > 0.0 {
        device_pixel_ratio
    } else {
        1.0
    };
    map_selection_to_monitor(
        LogicalRect {
            x: selection.x * scale,
            y: selection.y * scale,
            width: selection.width * scale,
            height: selection.height * scale,
        },
        f64::from(monitor_width),
        f64::from(monitor_height),
        monitor_width,
        monitor_height,
    )
}

fn map_selection_to_monitor(
    selection: LogicalRect,
    viewport_width: f64,
    viewport_height: f64,
    monitor_width: u32,
    monitor_height: u32,
) -> Option<PhysicalRect> {
    if !selection.x.is_finite()
        || !selection.y.is_finite()
        || !selection.width.is_finite()
        || !selection.height.is_finite()
        || selection.width < 2.0
        || selection.height < 2.0
        || viewport_width < 1.0
        || viewport_height < 1.0
        || monitor_width == 0
        || monitor_height == 0
    {
        return None;
    }
    let scale_x = f64::from(monitor_width) / viewport_width;
    let scale_y = f64::from(monitor_height) / viewport_height;
    if !scale_x.is_finite() || !scale_y.is_finite() || scale_x <= 0.0 || scale_y <= 0.0 {
        return None;
    }
    let (x, width) = clip_axis(selection.x, selection.width, scale_x, monitor_width)?;
    let (y, height) = clip_axis(selection.y, selection.height, scale_y, monitor_height)?;
    Some(PhysicalRect {
        x,
        y,
        width,
        height,
    })
}

fn clip_axis(origin: f64, length: f64, scale: f64, limit: u32) -> Option<(u32, u32)> {
    let mut start = origin * scale;
    let mut span = length * scale;
    if start < 0.0 {
        span += start;
        start = 0.0;
    }
    if span < 1.0 {
        return None;
    }
    let start = round_u32(start)?;
    let mut span = round_u32(span)?;
    if start >= limit {
        return None;
    }
    span = span.min(limit - start);
    if span == 0 {
        return None;
    }
    Some((start, span))
}

fn round_u32(value: f64) -> Option<u32> {
    if !value.is_finite() || value < 0.0 || value > f64::from(u32::MAX) {
        return None;
    }
    Some(value.round() as u32)
}

struct OverlayGuard {
    app: AppHandle,
    session: u64,
}

impl Drop for OverlayGuard {
    fn drop(&mut self) {
        cancel_overlay_session(self.session);
        dismiss_owned_overlay(&self.app, self.session);
    }
}

/// Show the selector on one monitor and wait for a drag or Escape.
///
/// `origin_x` / `origin_y` are the monitor's physical origin. The returned
/// rectangle is physical and relative to that monitor. `Ok(None)` means the
/// user cancelled.
pub async fn select_on_monitor(
    app: &AppHandle,
    origin_x: i32,
    origin_y: i32,
    width: u32,
    height: u32,
) -> Result<Option<PhysicalRect>, String> {
    if width == 0 || height == 0 {
        return Err("No display under the pointer.".into());
    }
    let session = next_session();
    let _guard = OverlayGuard {
        app: app.clone(),
        session,
    };
    let (tx, rx) = tokio::sync::oneshot::channel();
    {
        let mut slot = wait_slot();
        if let Some(previous) = slot.replace(PendingSelect {
            session,
            sender: tx,
        }) {
            let _ = previous.sender.send(None);
        }
    }

    let (ready_tx, ready_rx) = std::sync::mpsc::channel();
    let ready_slot = Arc::new(Mutex::new(Some(ready_tx)));
    let page_ready = Arc::clone(&ready_slot);
    if let Some(existing) = app.get_webview_window(REGION_WINDOW_LABEL) {
        let _ = existing.hide();
        let _ = existing.destroy();
    }
    let window = WebviewWindowBuilder::new(
        app,
        REGION_WINDOW_LABEL,
        WebviewUrl::App("region.html".into()),
    )
    .title("Select area")
    .transparent(true)
    .always_on_top(true)
    .decorations(false)
    .shadow(false)
    .skip_taskbar(true)
    .resizable(false)
    .maximizable(false)
    .minimizable(false)
    .focused(true)
    .visible(false)
    .content_protected(true)
    .accept_first_mouse(true)
    .disable_drag_drop_handler()
    .background_color(Color(0, 0, 0, 0))
    .on_page_load(move |_window, payload| {
        if payload.event() == tauri::webview::PageLoadEvent::Finished {
            if let Some(tx) = page_ready.lock().ok().and_then(|mut guard| guard.take()) {
                let _ = tx.send(());
            }
        }
    })
    .build()
    .map_err(|error| format!("OpenScribe couldn't open the area selector. {error}"))?;

    OVERLAY_OWNER.store(session, Ordering::Release);
    let app_for_close = app.clone();
    window.on_window_event(move |event| match event {
        tauri::WindowEvent::CloseRequested { api, .. } => {
            // Alt+F4 and the caption Close button. `prevent_close` keeps the
            // webview from tearing down into an opaque frame and from exiting
            // the process when this overlay is the last window. Hide now so
            // the sheet is gone before capture; destroy follows from the guard.
            api.prevent_close();
            hide_owned_overlay(&app_for_close, session);
            cancel_overlay_session(session);
        }
        tauri::WindowEvent::Destroyed => {
            cancel_overlay_session(session);
        }
        _ => {}
    });

    window
        .set_position(PhysicalPosition::new(origin_x, origin_y))
        .map_err(|error| format!("OpenScribe couldn't open the area selector. {error}"))?;
    window
        .set_size(PhysicalSize::new(width, height))
        .map_err(|error| format!("OpenScribe couldn't open the area selector. {error}"))?;
    let _ = window.set_content_protected(true);
    // Stay hidden until the page has painted. A transparent WebView2 is black
    // until the first composite, and that frame must not be shown or captured.
    let _ = tauri::async_runtime::spawn_blocking(move || {
        let _ = ready_rx.recv_timeout(Duration::from_secs(2));
    })
    .await;
    window
        .show()
        .map_err(|error| format!("OpenScribe couldn't open the area selector. {error}"))?;
    let _ = window.set_focus();

    let drag = rx.await.ok().flatten();
    let Some(drag) = drag else {
        return Ok(None);
    };
    Ok(map_drag(
        LogicalRect {
            x: drag.x,
            y: drag.y,
            width: drag.width,
            height: drag.height,
        },
        drag.viewport_width,
        drag.viewport_height,
        drag.device_pixel_ratio,
        width,
        height,
    ))
}

fn deliver(drag: Option<RegionDrag>) {
    if let Some(pending) = wait_slot().take() {
        let _ = pending.sender.send(drag);
    }
}

// Flat arguments are the `invoke` payload sent by `src/region/main.ts`.
#[allow(clippy::too_many_arguments)]
#[tauri::command]
pub fn complete_region_select(
    app: AppHandle,
    x: f64,
    y: f64,
    width: f64,
    height: f64,
    viewport_width: f64,
    viewport_height: f64,
    device_pixel_ratio: f64,
) {
    // Hide on the event loop, before the capture task resumes, so the dimmed
    // sheet is not part of the screenshot.
    hide_overlay_window(&app);
    deliver(Some(RegionDrag {
        x,
        y,
        width,
        height,
        viewport_width,
        viewport_height,
        device_pixel_ratio,
    }));
}

#[tauri::command]
pub fn cancel_region_select(app: AppHandle) {
    hide_overlay_window(&app);
    deliver(None);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fractional_scale_maps_css_pixels_to_physical_pixels() {
        let rect = map_drag(
            LogicalRect {
                x: 8.0,
                y: 16.0,
                width: 80.0,
                height: 40.0,
            },
            1600.0,
            1000.0,
            1.0,
            2000,
            1250,
        );
        assert_eq!(
            rect,
            Some(PhysicalRect {
                x: 10,
                y: 20,
                width: 100,
                height: 50,
            })
        );
    }

    #[test]
    fn one_and_a_half_scale_uses_the_viewport_ratio() {
        let rect = map_drag(
            LogicalRect {
                x: 10.0,
                y: 20.0,
                width: 100.0,
                height: 40.0,
            },
            1280.0,
            720.0,
            1.0,
            1920,
            1080,
        );
        assert_eq!(
            rect,
            Some(PhysicalRect {
                x: 15,
                y: 30,
                width: 150,
                height: 60,
            })
        );
    }

    #[test]
    fn a_click_is_a_cancel() {
        assert_eq!(
            map_drag(
                LogicalRect {
                    x: 4.0,
                    y: 4.0,
                    width: 1.0,
                    height: 8.0,
                },
                100.0,
                100.0,
                1.0,
                100,
                100,
            ),
            None
        );
    }

    #[test]
    fn selection_is_clamped_to_the_monitor() {
        assert_eq!(
            map_drag(
                LogicalRect {
                    x: 90.0,
                    y: 90.0,
                    width: 40.0,
                    height: 40.0,
                },
                100.0,
                100.0,
                1.0,
                100,
                100,
            ),
            Some(PhysicalRect {
                x: 90,
                y: 90,
                width: 10,
                height: 10,
            })
        );
    }

    #[test]
    fn negative_origin_is_clipped_before_scaling_the_span() {
        assert_eq!(
            map_drag(
                LogicalRect {
                    x: -10.0,
                    y: 5.0,
                    width: 30.0,
                    height: 10.0,
                },
                100.0,
                100.0,
                1.0,
                100,
                100,
            ),
            Some(PhysicalRect {
                x: 0,
                y: 5,
                width: 20,
                height: 10,
            })
        );
    }

    #[test]
    fn a_close_from_another_session_does_not_own_the_wait() {
        assert!(owns_session(Some(4), 4));
        assert!(!owns_session(Some(4), 5));
        assert!(!owns_session(None, 4));
    }

    #[test]
    fn device_pixel_ratio_is_the_fallback_when_the_viewport_is_missing() {
        assert_eq!(
            map_drag(
                LogicalRect {
                    x: 10.0,
                    y: 10.0,
                    width: 20.0,
                    height: 20.0,
                },
                0.0,
                0.0,
                2.0,
                1000,
                800,
            ),
            Some(PhysicalRect {
                x: 20,
                y: 20,
                width: 40,
                height: 40,
            })
        );
    }
}
