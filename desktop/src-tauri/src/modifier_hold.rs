//! A modifier key held on its own, Windows' counterpart to the macOS Globe key.
//!
//! RegisterHotKey cannot bind a bare modifier, so a low-level keyboard hook watches Right Ctrl.
//! The key is never swallowed: it still works as Ctrl in other apps. Pressing another key while
//! it is held turns the press into an ordinary Ctrl combination and cancels what it started.

/// The accelerator stored in settings for the modifier-only shortcut.
pub const RIGHT_CTRL: &str = "RightCtrl";

/// What the hook reports for the bound action.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum HoldEvent {
    Pressed,
    Released,
    /// Another key joined the press, so it was a Ctrl shortcut rather than dictation.
    Cancelled,
}

/// Turns raw key transitions into hold events. Kept free of Win32 so it can be tested.
#[derive(Default)]
pub struct HoldTracker {
    down: bool,
    combined: bool,
}
impl HoldTracker {
    fn begin_combination(&mut self) {
        self.down = true;
        self.combined = true;
    }
    pub fn key(&mut self, is_hold_key: bool, pressed: bool) -> Option<HoldEvent> {
        if is_hold_key {
            if pressed && !self.down {
                self.down = true;
                self.combined = false;
                return Some(HoldEvent::Pressed);
            }
            if !pressed && self.down {
                self.down = false;
                return (!self.combined).then_some(HoldEvent::Released);
            }
            return None;
        }
        if pressed && self.down && !self.combined {
            self.combined = true;
            return Some(HoldEvent::Cancelled);
        }
        None
    }
}

#[cfg(windows)]
mod imp {
    use super::{HoldEvent, HoldTracker};
    use std::sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Mutex,
    };
    use windows::Win32::{
        Foundation::{HINSTANCE, LPARAM, LRESULT, WPARAM},
        System::{LibraryLoader::GetModuleHandleW, Threading::GetCurrentThreadId},
        UI::WindowsAndMessaging::{
            CallNextHookEx, DispatchMessageW, GetMessageW, PeekMessageW, PostThreadMessageW,
            SetWindowsHookExW, TranslateMessage, UnhookWindowsHookEx, HC_ACTION, KBDLLHOOKSTRUCT,
            LLKHF_INJECTED, MSG, PM_NOREMOVE, WH_KEYBOARD_LL, WM_KEYDOWN, WM_QUIT, WM_SYSKEYDOWN,
            WM_USER,
        },
    };

    const VK_RCONTROL: u32 = 0xA3;

    type Sink = std::sync::Arc<dyn Fn(HoldEvent) + Send + Sync>;
    struct Active {
        sender: std::sync::mpsc::Sender<HoldEvent>,
        enabled: Arc<AtomicBool>,
        tracker: HoldTracker,
        other_keys: std::collections::HashSet<u32>,
    }
    static ACTIVE: Mutex<Option<Active>> = Mutex::new(None);
    static THREAD: Mutex<Option<u32>> = Mutex::new(None);

    unsafe extern "system" fn hook(code: i32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
        if code == HC_ACTION as i32 {
            // SAFETY: for WH_KEYBOARD_LL with HC_ACTION, lparam points to a KBDLLHOOKSTRUCT.
            let info = unsafe { &*(lparam.0 as *const KBDLLHOOKSTRUCT) };
            // Keys OpenScribe types itself, like the paste shortcut, are not the user's hand.
            if info.flags.0 & LLKHF_INJECTED.0 == 0 {
                let pressed = matches!(wparam.0 as u32, WM_KEYDOWN | WM_SYSKEYDOWN);
                // The sink runs after ACTIVE is released: it takes the shortcut lock, and
                // the shortcut code takes ACTIVE (through stop) while holding that lock.
                let fired = ACTIVE.lock().ok().and_then(|mut active| {
                    let active = active.as_mut()?;
                    if info.vkCode != VK_RCONTROL {
                        if pressed {
                            active.other_keys.insert(info.vkCode);
                        } else {
                            active.other_keys.remove(&info.vkCode);
                        }
                    } else if pressed && !active.other_keys.is_empty() {
                        active.tracker.begin_combination();
                        return None;
                    }
                    let event = active.tracker.key(info.vkCode == VK_RCONTROL, pressed)?;
                    Some((active.sender.clone(), event))
                });
                if let Some((sender, event)) = fired {
                    // Keep the low-level hook responsive even while settings owns its lock.
                    let _ = sender.send(event);
                }
            }
        }
        unsafe { CallNextHookEx(None, code, wparam, lparam) }
    }

    pub fn start(sink: Sink) -> Result<(), String> {
        let (sender, receiver) = std::sync::mpsc::channel();
        let enabled = Arc::new(AtomicBool::new(true));
        let mut active = ACTIVE.lock().map_err(|_| "Keyboard hook is unavailable.")?;
        if let Some(previous) = active.take() {
            previous.enabled.store(false, Ordering::SeqCst);
        }
        *active = Some(Active {
            sender,
            enabled: enabled.clone(),
            tracker: HoldTracker::default(),
            other_keys: std::collections::HashSet::new(),
        });
        drop(active);
        std::thread::spawn(move || {
            while let Ok(event) = receiver.recv() {
                if enabled.load(Ordering::SeqCst) {
                    sink(event);
                }
            }
        });
        let mut thread = THREAD.lock().map_err(|_| "Keyboard hook is unavailable.")?;
        if thread.is_some() {
            return Ok(());
        }
        let (ready_tx, ready_rx) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            let mut msg = MSG::default();
            // Creates this thread's message queue so stop() can post WM_QUIT to it.
            let _ = unsafe { PeekMessageW(&mut msg, None, WM_USER, WM_USER, PM_NOREMOVE) };
            let module = unsafe { GetModuleHandleW(None) }
                .ok()
                .map(|m| HINSTANCE(m.0));
            let installed = unsafe { SetWindowsHookExW(WH_KEYBOARD_LL, Some(hook), module, 0) };
            let hook = match installed {
                Ok(hook) => hook,
                Err(error) => {
                    let _ = ready_tx.send(Err(error.to_string()));
                    return;
                }
            };
            let _ = ready_tx.send(Ok(unsafe { GetCurrentThreadId() }));
            while unsafe { GetMessageW(&mut msg, None, 0, 0) }.0 > 0 {
                unsafe {
                    let _ = TranslateMessage(&msg);
                    DispatchMessageW(&msg);
                }
            }
            let _ = unsafe { UnhookWindowsHookEx(hook) };
        });
        match ready_rx.recv() {
            Ok(Ok(id)) => {
                *thread = Some(id);
                Ok(())
            }
            Ok(Err(error)) => Err(format!("Right Ctrl could not be watched: {error}")),
            Err(_) => Err("Right Ctrl could not be watched.".into()),
        }
    }

    pub fn stop() {
        if let Ok(mut active) = ACTIVE.lock() {
            if let Some(previous) = active.take() {
                previous.enabled.store(false, Ordering::SeqCst);
            }
        }
        if let Some(id) = THREAD.lock().ok().and_then(|mut thread| thread.take()) {
            let _ = unsafe { PostThreadMessageW(id, WM_QUIT, WPARAM(0), LPARAM(0)) };
        }
    }
}

#[cfg(windows)]
pub use imp::{start, stop};

#[cfg(not(windows))]
pub fn start(_: std::sync::Arc<dyn Fn(HoldEvent) + Send + Sync>) -> Result<(), String> {
    Err("Right Ctrl is only available on Windows.".into())
}
#[cfg(not(windows))]
pub fn stop() {}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn a_lone_hold_presses_and_releases_but_a_ctrl_combination_cancels() {
        let mut keys = HoldTracker::default();
        assert_eq!(keys.key(true, true), Some(HoldEvent::Pressed));
        assert_eq!(keys.key(true, true), None, "auto-repeat");
        assert_eq!(keys.key(true, false), Some(HoldEvent::Released));
        assert_eq!(keys.key(false, true), None, "other keys alone");
        assert_eq!(keys.key(true, true), Some(HoldEvent::Pressed));
        assert_eq!(keys.key(false, true), Some(HoldEvent::Cancelled));
        assert_eq!(keys.key(false, true), None);
        assert_eq!(keys.key(true, false), None);
        assert_eq!(keys.key(true, true), Some(HoldEvent::Pressed));
    }
    #[test]
    fn an_existing_combination_does_not_start_or_finish_dictation() {
        let mut keys = HoldTracker::default();
        keys.begin_combination();
        assert_eq!(keys.key(true, true), None);
        assert_eq!(keys.key(true, false), None);
        assert_eq!(keys.key(true, true), Some(HoldEvent::Pressed));
    }
}
