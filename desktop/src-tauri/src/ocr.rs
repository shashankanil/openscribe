//! Text recognition for a saved screenshot.
//!
//! Windows uses `Windows.Media.Ocr`: PNG bytes become a `SoftwareBitmap`, then
//! `OcrEngine::TryCreateFromUserProfileLanguages`. Lines are joined with
//! newline characters, matching `ScreenshotCapture.recognizeText`. Other
//! platforms return [`UNSUPPORTED_PLATFORM`].

use std::path::Path;
use tauri::Emitter;

pub const UNSUPPORTED_PLATFORM: &str = "Windows OCR is not supported on this platform.";

/// Join OCR lines the way Swift joins Vision candidates. Blank recognition
/// (no lines, or only whitespace) is `None`, so the capture is left unchanged.
pub fn join_ocr_lines<I, S>(lines: I) -> Option<String>
where
    I: IntoIterator<Item = S>,
    S: AsRef<str>,
{
    let mut text = String::new();
    for line in lines {
        if !text.is_empty() {
            text.push('\n');
        }
        text.push_str(line.as_ref());
    }
    if text.trim().is_empty() {
        None
    } else {
        Some(text)
    }
}

/// Largest size that still fits inside `max_edge` on both sides.
pub fn fitted_size(width: u32, height: u32, max_edge: u32) -> (u32, u32) {
    if max_edge == 0 || width == 0 || height == 0 || (width <= max_edge && height <= max_edge) {
        return (width, height);
    }
    let long_edge = u64::from(width.max(height));
    let width = (u64::from(width) * u64::from(max_edge) / long_edge).max(1);
    let height = (u64::from(height) * u64::from(max_edge) / long_edge).max(1);
    (width as u32, height as u32)
}

pub fn recognize_path(path: &Path) -> Result<Option<String>, String> {
    let bytes = std::fs::read(path)
        .map_err(|_| "OpenScribe couldn't read the screenshot for text recognition.".to_string())?;
    recognize_png(&bytes)
}

pub fn recognize_png(png: &[u8]) -> Result<Option<String>, String> {
    #[cfg(windows)]
    {
        recognize_png_windows(png)
    }
    #[cfg(not(windows))]
    {
        let _ = png;
        Err(UNSUPPORTED_PLATFORM.to_string())
    }
}

pub fn spawn_after_save(app: tauri::AppHandle, capture_id: String, path: std::path::PathBuf) {
    // The PNG is already saved. Failure here reports `capture://error` and
    // leaves that file in place.
    tauri::async_runtime::spawn_blocking(move || match recognize_path(&path) {
        Ok(Some(text)) => {
            let note_id = match crate::storage_hooks::set_recognized_text(&app, &capture_id, &text)
            {
                Ok(note_id) => note_id,
                Err(error) => {
                    emit_ocr_error(&app, error);
                    return;
                }
            };
            let _ = app.emit(
                "capture://ocr",
                OcrEvent {
                    capture_id,
                    note_id,
                },
            );
        }
        Ok(None) => {}
        Err(error) => emit_ocr_error(&app, error),
    });
}

fn emit_ocr_error(app: &tauri::AppHandle, message: String) {
    let _ = app.emit("capture://error", message);
}

#[derive(Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
struct OcrEvent {
    capture_id: String,
    note_id: Option<String>,
}

#[cfg(windows)]
fn recognize_png_windows(png: &[u8]) -> Result<Option<String>, String> {
    use windows::Graphics::Imaging::{
        BitmapAlphaMode, BitmapDecoder, BitmapPixelFormat, SoftwareBitmap,
    };
    use windows::Media::Ocr::OcrEngine;
    use windows::Storage::Streams::{DataWriter, InMemoryRandomAccessStream};

    let engine = OcrEngine::TryCreateFromUserProfileLanguages().map_err(|_| {
        "Windows OCR isn’t available. Add a language with optical character recognition in Windows Settings.".to_string()
    })?;
    let max_edge = OcrEngine::MaxImageDimension().unwrap_or(4096);
    let png = png_within_edge(png, max_edge)?;

    let stream = InMemoryRandomAccessStream::new().map_err(ocr_failed)?;
    let writer = DataWriter::CreateDataWriter(&stream).map_err(ocr_failed)?;
    writer.WriteBytes(&png).map_err(ocr_failed)?;
    writer
        .StoreAsync()
        .map_err(ocr_failed)?
        .join()
        .map_err(ocr_failed)?;
    writer.DetachStream().map_err(ocr_failed)?;
    stream.Seek(0).map_err(ocr_failed)?;

    let decoder = BitmapDecoder::CreateAsync(&stream)
        .map_err(ocr_failed)?
        .join()
        .map_err(ocr_failed)?;
    let decoded = decoder
        .GetSoftwareBitmapAsync()
        .map_err(ocr_failed)?
        .join()
        .map_err(ocr_failed)?;
    let bitmap = SoftwareBitmap::ConvertWithAlpha(
        &decoded,
        BitmapPixelFormat::Bgra8,
        BitmapAlphaMode::Premultiplied,
    )
    .unwrap_or(decoded);
    let result = engine
        .RecognizeAsync(&bitmap)
        .map_err(ocr_failed)?
        .join()
        .map_err(ocr_failed)?;
    let lines = result.Lines().map_err(ocr_failed)?;
    let count = lines.Size().map_err(ocr_failed)?;
    let mut collected = Vec::with_capacity(count as usize);
    for index in 0..count {
        let line = lines.GetAt(index).map_err(ocr_failed)?;
        collected.push(line.Text().map_err(ocr_failed)?.to_string());
    }
    Ok(join_ocr_lines(collected))
}

#[cfg(windows)]
fn png_within_edge(png: &[u8], max_edge: u32) -> Result<Vec<u8>, String> {
    let image = image::load_from_memory(png)
        .map_err(|_| "OpenScribe couldn't read the screenshot for text recognition.".to_string())?;
    let (width, height) = fitted_size(image.width(), image.height(), max_edge);
    if (width, height) == (image.width(), image.height()) {
        return Ok(png.to_vec());
    }
    let image = image.resize_exact(width, height, image::imageops::FilterType::Triangle);
    let mut bytes = Vec::new();
    image
        .write_to(
            &mut std::io::Cursor::new(&mut bytes),
            image::ImageFormat::Png,
        )
        .map_err(|_| {
            "OpenScribe couldn't prepare the screenshot for text recognition.".to_string()
        })?;
    Ok(bytes)
}

#[cfg(windows)]
fn ocr_failed(error: impl std::fmt::Display) -> String {
    let detail = error.to_string();
    if detail.chars().count() > 160 {
        "Windows OCR couldn’t read that screenshot.".into()
    } else {
        format!("Windows OCR couldn’t read that screenshot. {detail}")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lines_join_with_newline_and_blank_recognition_is_absent() {
        assert_eq!(
            join_ocr_lines(["Agenda", "Ship the notes"]),
            Some("Agenda\nShip the notes".to_string())
        );
        assert_eq!(join_ocr_lines(Vec::<&str>::new()), None);
        assert_eq!(join_ocr_lines(["", "   "]), None);
    }

    #[test]
    fn fitted_size_keeps_small_images_and_scales_the_long_edge() {
        assert_eq!(fitted_size(100, 40, 4096), (100, 40));
        assert_eq!(fitted_size(4000, 2000, 2000), (2000, 1000));
        assert_eq!(fitted_size(3000, 2000, 2600), (2600, 1733));
        assert_eq!(fitted_size(0, 10, 100), (0, 10));
    }

    #[test]
    fn unsupported_message_names_the_platform() {
        assert_eq!(
            UNSUPPORTED_PLATFORM,
            "Windows OCR is not supported on this platform."
        );
    }

    #[cfg(not(windows))]
    #[test]
    fn recognize_png_reports_that_windows_ocr_is_unavailable() {
        let error = recognize_png(&[]).unwrap_err();
        assert_eq!(error, UNSUPPORTED_PLATFORM);
    }

    /// Run with `OCR_SMOKE_PNG=<png with text> OCR_SMOKE_EXPECT=<a word in it>
    /// cargo test -- --ignored ocr_smoke`. Block shapes drawn in code aren't
    /// reliable glyphs for Windows OCR, so this uses a real text image.
    #[cfg(windows)]
    #[test]
    #[ignore = "needs a text PNG, the Windows OCR language pack and a desktop session"]
    fn ocr_smoke_text_png() {
        let path = std::env::var("OCR_SMOKE_PNG").expect("OCR_SMOKE_PNG");
        let expected = std::env::var("OCR_SMOKE_EXPECT").expect("OCR_SMOKE_EXPECT");
        let text = recognize_path(Path::new(&path))
            .expect("ocr pipeline")
            .expect("expected recognized text");
        assert!(text.contains(&expected), "recognized text was {text:?}");
    }
}
