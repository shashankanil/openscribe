use enigo::{Direction, Enigo, Key, Keyboard, Settings};

pub fn paste_keystroke() -> Result<(), String> {
    let mut enigo = Enigo::new(&Settings::default()).map_err(|error| error.to_string())?;
    let modifier = if cfg!(target_os = "macos") {
        Key::Meta
    } else {
        Key::Control
    };
    enigo
        .key(modifier, Direction::Press)
        .map_err(|error| error.to_string())?;
    let result = enigo
        .key(Key::Unicode('v'), Direction::Click)
        .map_err(|error| error.to_string());
    let _ = enigo.key(modifier, Direction::Release);
    result
}

/// Formats that hold GDI handles or pointers into the copying app rather than plain memory.
/// Windows recreates the GDI ones from the memory formats it is given back.
#[cfg_attr(not(windows), allow(dead_code))]
fn restorable(format: u32, name: &str) -> bool {
    const GDI: [u32; 8] = [2, 3, 9, 14, 0x80, 0x82, 0x83, 0x8E];
    !GDI.contains(&format)
        && !(0x300..=0x3FF).contains(&format)
        && !matches!(name, "DataObject" | "Ole Private Data")
}

#[cfg(windows)]
mod clipboard {
    use super::restorable;
    use std::time::{Duration, Instant};
    use windows::core::PCWSTR;
    use windows::Win32::{
        Foundation::{GlobalFree, HANDLE, HGLOBAL},
        System::{
            DataExchange::{
                CloseClipboard, EmptyClipboard, EnumClipboardFormats, GetClipboardData,
                GetClipboardFormatNameW, GetClipboardSequenceNumber, OpenClipboard,
                RegisterClipboardFormatW, SetClipboardData,
            },
            Memory::{GlobalAlloc, GlobalLock, GlobalSize, GlobalUnlock, GMEM_MOVEABLE},
        },
        UI::Input::KeyboardAndMouse::{
            GetAsyncKeyState, SendInput, INPUT, INPUT_0, INPUT_KEYBOARD, KEYBDINPUT,
            KEYBD_EVENT_FLAGS, KEYEVENTF_KEYUP, VIRTUAL_KEY,
        },
    };

    const CF_UNICODETEXT: u32 = 13;
    /// Larger items (a huge image, say) are left out rather than held in memory twice.
    const MAX_ITEM_BYTES: usize = 256 * 1024 * 1024;

    /// Holds the clipboard open; another app may have it for a moment, so opening retries.
    struct Open;
    impl Open {
        fn new() -> Result<Self, String> {
            for _ in 0..25 {
                if unsafe { OpenClipboard(None) }.is_ok() {
                    return Ok(Open);
                }
                std::thread::sleep(Duration::from_millis(20));
            }
            Err("The clipboard could not be prepared for paste.".into())
        }
    }
    impl Drop for Open {
        fn drop(&mut self) {
            let _ = unsafe { CloseClipboard() };
        }
    }

    fn format_name(format: u32) -> String {
        let mut buffer = [0u16; 128];
        let length = unsafe { GetClipboardFormatNameW(format, &mut buffer) };
        String::from_utf16_lossy(&buffer[..length.max(0) as usize])
    }

    fn snapshot() -> Result<Vec<(u32, Vec<u8>)>, String> {
        let _open = Open::new()?;
        let mut items = Vec::new();
        let mut format = 0;
        loop {
            format = unsafe { EnumClipboardFormats(format) };
            if format == 0 {
                break;
            }
            if !restorable(format, &format_name(format)) {
                continue;
            }
            let Ok(handle) = (unsafe { GetClipboardData(format) }) else {
                continue;
            };
            let memory = HGLOBAL(handle.0);
            let size = unsafe { GlobalSize(memory) };
            if size == 0 || size > MAX_ITEM_BYTES {
                continue;
            }
            let pointer = unsafe { GlobalLock(memory) } as *const u8;
            if pointer.is_null() {
                continue;
            }
            // SAFETY: GlobalLock returned a pointer to `size` bytes, held until GlobalUnlock.
            let bytes = unsafe { std::slice::from_raw_parts(pointer, size) }.to_vec();
            let _ = unsafe { GlobalUnlock(memory) };
            items.push((format, bytes));
        }
        Ok(items)
    }

    fn put(format: u32, bytes: &[u8]) -> Result<(), String> {
        let memory = unsafe { GlobalAlloc(GMEM_MOVEABLE, bytes.len().max(1)) }
            .map_err(|_| "The clipboard could not be prepared for paste.".to_string())?;
        let pointer = unsafe { GlobalLock(memory) } as *mut u8;
        if pointer.is_null() {
            let _ = unsafe { GlobalFree(Some(memory)) };
            return Err("The clipboard could not be prepared for paste.".into());
        }
        // SAFETY: the allocation holds at least bytes.len() bytes and is locked.
        unsafe { std::ptr::copy_nonoverlapping(bytes.as_ptr(), pointer, bytes.len()) };
        let _ = unsafe { GlobalUnlock(memory) };
        // On success the clipboard owns the memory; otherwise it is still ours to free.
        if unsafe { SetClipboardData(format, Some(HANDLE(memory.0))) }.is_err() {
            let _ = unsafe { GlobalFree(Some(memory)) };
            return Err("The clipboard could not be prepared for paste.".into());
        }
        Ok(())
    }

    fn registered(name: &str) -> u32 {
        let wide: Vec<u16> = name.encode_utf16().chain(Some(0)).collect();
        unsafe { RegisterClipboardFormatW(PCWSTR(wide.as_ptr())) }
    }

    fn set_text(text: &str) -> Result<u32, String> {
        let _open = Open::new()?;
        unsafe { EmptyClipboard() }
            .map_err(|_| "The clipboard could not be prepared for paste.".to_string())?;
        let wide: Vec<u8> = text
            .encode_utf16()
            .chain(Some(0))
            .flat_map(u16::to_le_bytes)
            .collect();
        put(CF_UNICODETEXT, &wide)?;
        // Dictated text passes through the clipboard; keep it out of Win+V history and cloud sync.
        let never = 0u32.to_le_bytes();
        for name in [
            "ExcludeClipboardContentFromMonitorProcessing",
            "CanIncludeInClipboardHistory",
            "CanUploadToCloudClipboard",
        ] {
            let format = registered(name);
            if format != 0 {
                let _ = put(format, &never);
            }
        }
        Ok(unsafe { GetClipboardSequenceNumber() })
    }

    fn restore(items: &[(u32, Vec<u8>)]) {
        let Ok(_open) = Open::new() else { return };
        if unsafe { EmptyClipboard() }.is_err() {
            return;
        }
        for (format, bytes) in items {
            let _ = put(*format, bytes);
        }
    }

    fn key(code: u16, up: bool) -> INPUT {
        INPUT {
            r#type: INPUT_KEYBOARD,
            Anonymous: INPUT_0 {
                ki: KEYBDINPUT {
                    wVk: VIRTUAL_KEY(code),
                    wScan: 0,
                    dwFlags: if up { KEYEVENTF_KEYUP } else { KEYBD_EVENT_FLAGS(0) },
                    time: 0,
                    dwExtraInfo: 0,
                },
            },
        }
    }

    /// A shortcut's Alt, Shift or Win key still held would turn Ctrl+V into another command.
    fn wait_for_modifiers() {
        const ALT: i32 = 0x12;
        const SHIFT: i32 = 0x10;
        const LEFT_WIN: i32 = 0x5B;
        const RIGHT_WIN: i32 = 0x5C;
        let deadline = Instant::now() + Duration::from_millis(1500);
        while Instant::now() < deadline
            && [ALT, SHIFT, LEFT_WIN, RIGHT_WIN]
                .iter()
                .any(|&key| unsafe { GetAsyncKeyState(key) } < 0)
        {
            std::thread::sleep(Duration::from_millis(15));
        }
    }

    /// As TextInjector on macOS: the clipboard is borrowed for the paste and given back.
    pub fn paste_text(text: &str) -> Result<(), String> {
        if text.is_empty() {
            return Ok(());
        }
        let previous = snapshot().ok();
        let sequence = set_text(text)?;
        wait_for_modifiers();
        const CONTROL: u16 = 0x11;
        const V: u16 = 0x56; // The V key itself, whatever the keyboard layout.
        let inputs = [key(CONTROL, false), key(V, false), key(V, true), key(CONTROL, true)];
        let sent = unsafe { SendInput(&inputs, std::mem::size_of::<INPUT>() as i32) };
        // The target reads the clipboard after it handles the keystroke.
        std::thread::sleep(Duration::from_millis(600));
        // Something copied in the meantime belongs to the user and is kept.
        if let Some(previous) = previous {
            if unsafe { GetClipboardSequenceNumber() } == sequence {
                restore(&previous);
            }
        }
        if sent as usize != inputs.len() {
            return Err("Windows did not allow the paste keystroke.".into());
        }
        Ok(())
    }
}

#[cfg(windows)]
pub use clipboard::paste_text;

#[cfg(test)]
mod tests {
    use super::restorable;
    #[test]
    fn handle_and_pointer_formats_are_not_copied_back() {
        assert!(restorable(13, ""), "Unicode text");
        assert!(restorable(8, ""), "DIB image");
        assert!(restorable(15, ""), "files");
        assert!(restorable(0xC0F0, "HTML Format"));
        assert!(!restorable(2, ""), "GDI bitmap");
        assert!(!restorable(14, ""), "enhanced metafile");
        assert!(!restorable(0x300, ""), "GDI object range");
        assert!(!restorable(0xC100, "Ole Private Data"));
        assert!(!restorable(0xC101, "DataObject"));
    }
}
