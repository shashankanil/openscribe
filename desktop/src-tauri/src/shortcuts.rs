use crate::modifier_hold::{self, HoldEvent, RIGHT_CTRL};
use serde::{Deserialize, Serialize};
use std::{
    collections::{BTreeMap, HashSet},
    sync::Mutex,
};
use tauri::{Emitter, Manager};
use tauri_plugin_global_shortcut::{Code, GlobalShortcutExt, Modifiers, Shortcut, ShortcutState};

pub const ACTIONS: [&str; 7] = [
    "dictate",
    "holdToTalk",
    "meeting",
    "screenshotArea",
    "screenshotWindow",
    "screenshotScreen",
    "pasteLast",
];
#[derive(Clone, Debug, Deserialize)]
pub struct Binding {
    pub accelerator: String,
    #[serde(default)]
    pub display: String,
}
pub type Bindings = BTreeMap<String, Binding>;
#[derive(Default)]
pub struct ShortcutManager(Mutex<Registration>);
#[derive(Default)]
struct Registration {
    bindings: Bindings,
    suspended: bool,
    pressed: HashSet<String>,
    /// Actions whose keys another app already holds; the rest stay registered, as on macOS.
    failures: Vec<String>,
    /// Escape is claimed only while dictating so it keeps working everywhere else.
    escape: bool,
}
#[derive(Clone, Serialize)]
struct ActionEvent {
    action: String,
    state: &'static str,
}
fn parse(accelerator: &str) -> Result<Shortcut, String> {
    let shortcut: Shortcut = accelerator
        .parse()
        .map_err(|_| "Choose a valid shortcut with modifiers and one key.".to_string())?;
    if shortcut.mods.is_empty() || shortcut.mods.contains(Modifiers::SUPER) {
        return Err(
            "Choose Ctrl, Alt or Shift with one key; Windows-key combinations are reserved.".into(),
        );
    }
    for reserved in [
        "Alt+Space",
        "Alt+F4",
        "Alt+Tab",
        "Ctrl+Alt+Delete",
        "Ctrl+Escape",
        "Ctrl+Shift+Escape",
    ] {
        if reserved
            .parse::<Shortcut>()
            .is_ok_and(|s| s.id() == shortcut.id())
        {
            return Err("This shortcut is reserved by Windows.".into());
        }
    }
    Ok(shortcut)
}
/// Like Globe on macOS, Right Ctrl alone can only start dictation, which acts on press and release.
fn holds(action: &str) -> bool {
    action == "dictate" || action == "holdToTalk"
}
pub fn validate(bindings: &Bindings) -> Result<(), String> {
    let mut ids = HashSet::new();
    let mut right_ctrl = false;
    for (action, binding) in bindings {
        if !ACTIONS.contains(&action.as_str()) {
            return Err("Unknown shortcut action.".into());
        }
        if binding.accelerator == RIGHT_CTRL {
            if !holds(action) {
                return Err("Right Ctrl on its own can only be used for dictation.".into());
            }
            if std::mem::replace(&mut right_ctrl, true) {
                return Err("Two actions use the same shortcut.".into());
            }
            continue;
        }
        if !ids.insert(parse(&binding.accelerator)?.id()) {
            return Err("Two actions use the same shortcut.".into());
        }
    }
    Ok(())
}
/// Registers every binding it can and returns the actions that could not be registered.
fn install(app: &tauri::AppHandle, bindings: &Bindings) -> Vec<String> {
    let mut failures = Vec::new();
    for (action, binding) in bindings {
        if binding.accelerator == RIGHT_CTRL {
            if install_hold(app, action).is_err() {
                failures.push(action.clone());
            }
            continue;
        }
        let Ok(shortcut) = parse(&binding.accelerator) else {
            failures.push(action.clone());
            continue;
        };
        let name = action.clone();
        let registered = app
            .global_shortcut()
            .on_shortcut(shortcut, move |app, _, event| {
                let state = app.state::<ShortcutManager>();
                let Ok(mut registration) = state.0.lock() else {
                    return;
                };
                if registration.suspended {
                    return;
                }
                let pressed = event.state() == ShortcutState::Pressed;
                let changed = if pressed {
                    registration.pressed.insert(name.clone())
                } else {
                    registration.pressed.remove(&name)
                };
                if changed {
                    let _ = app.emit(
                        "shortcut://action",
                        ActionEvent {
                            action: name.clone(),
                            state: if pressed { "pressed" } else { "released" },
                        },
                    );
                }
            })
            .is_ok();
        if !registered {
            failures.push(action.clone());
        }
    }
    failures
}
/// Watches Right Ctrl for the action and reports it like a registered shortcut.
fn install_hold(app: &tauri::AppHandle, action: &str) -> Result<(), String> {
    let app = app.clone();
    let action = action.to_string();
    modifier_hold::start(std::sync::Arc::new(move |event| {
        let state = app.state::<ShortcutManager>();
        let Ok(mut registration) = state.0.lock() else {
            return;
        };
        if registration.suspended
            || !registration
                .bindings
                .get(&action)
                .is_some_and(|binding| binding.accelerator == RIGHT_CTRL)
        {
            return;
        }
        let name = match event {
            HoldEvent::Pressed => {
                registration.pressed.insert(action.clone());
                "pressed"
            }
            HoldEvent::Released => {
                registration.pressed.remove(&action);
                "released"
            }
            HoldEvent::Cancelled => {
                registration.pressed.remove(&action);
                "cancelled"
            }
        };
        let _ = app.emit(
            "shortcut://action",
            ActionEvent {
                action: action.clone(),
                state: name,
            },
        );
    }))
}
/// Releases every registered key, including the Right Ctrl watcher.
fn deactivate(app: &tauri::AppHandle) -> Result<(), String> {
    modifier_hold::stop();
    app.global_shortcut()
        .unregister_all()
        .map_err(|_| "Could not release the previous shortcuts.".to_string())
}
fn escape_shortcut() -> Shortcut {
    Shortcut::new(None, Code::Escape)
}
fn install_escape(app: &tauri::AppHandle) -> Result<(), String> {
    app.global_shortcut()
        .on_shortcut(escape_shortcut(), |app, _, event| {
            if event.state() != ShortcutState::Pressed {
                return;
            }
            let suspended = app
                .state::<ShortcutManager>()
                .0
                .lock()
                .map(|registration| registration.suspended)
                .unwrap_or(true);
            if !suspended {
                let _ = app.emit("shortcut://escape", ());
            }
        })
        .map_err(|_| "Escape could not be claimed to cancel dictation.".to_string())
}
/// Installs the bindings and, while dictating, Escape. Records which actions failed.
fn activate(app: &tauri::AppHandle, registration: &mut Registration) {
    registration.failures = install(app, &registration.bindings);
    if registration.escape {
        let _ = install_escape(app);
    }
}
fn release_pressed(app: &tauri::AppHandle, registration: &mut Registration) {
    for action in registration.pressed.drain() {
        let _ = app.emit(
            "shortcut://action",
            ActionEvent {
                action,
                state: "released",
            },
        );
    }
}
/// Returns the actions that could not be registered because another app holds their keys.
#[tauri::command]
pub fn register_shortcuts(
    app: tauri::AppHandle,
    state: tauri::State<ShortcutManager>,
    bindings: Bindings,
) -> Result<Vec<String>, String> {
    validate(&bindings)?;
    let mut registration = state.0.lock().map_err(|_| "Shortcut settings are busy.")?;
    registration.bindings = bindings;
    if registration.suspended {
        return Ok(registration.failures.clone());
    }
    deactivate(&app)?;
    release_pressed(&app, &mut registration);
    activate(&app, &mut registration);
    Ok(registration.failures.clone())
}
#[tauri::command]
pub fn suspend_shortcuts(
    app: tauri::AppHandle,
    state: tauri::State<ShortcutManager>,
    suspended: bool,
) -> Result<Vec<String>, String> {
    let mut registration = state.0.lock().map_err(|_| "Shortcut settings are busy.")?;
    if registration.suspended != suspended {
        if suspended {
            deactivate(&app).map_err(|_| "Could not suspend shortcuts.")?;
            release_pressed(&app, &mut registration);
        } else {
            activate(&app, &mut registration);
        }
        registration.suspended = suspended;
    }
    Ok(registration.failures.clone())
}
/// As on macOS, Escape cancels a dictation and is held only while one is recording.
#[tauri::command]
pub fn set_escape_active(
    app: tauri::AppHandle,
    state: tauri::State<ShortcutManager>,
    active: bool,
) -> Result<(), String> {
    let mut registration = state.0.lock().map_err(|_| "Shortcut settings are busy.")?;
    if registration.escape == active {
        return Ok(());
    }
    registration.escape = active;
    if registration.suspended {
        return Ok(());
    }
    if active {
        install_escape(&app)
    } else {
        app.global_shortcut()
            .unregister(escape_shortcut())
            .map_err(|_| "Could not release Escape.".to_string())
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    fn bindings(pairs: &[(&str, &str)]) -> Bindings {
        pairs
            .iter()
            .map(|(a, k)| {
                (
                    a.to_string(),
                    Binding {
                        accelerator: k.to_string(),
                        display: k.to_string(),
                    },
                )
            })
            .collect()
    }
    #[test]
    fn detects_conflicts_and_reserved_keys() {
        assert!(validate(&bindings(&[
            ("dictate", "Ctrl+Alt+Space"),
            ("meeting", "Alt+Control+Space")
        ]))
        .is_err());
        for key in [
            "Alt+Space",
            "Super+M",
            "A",
            "Ctrl+Alt+Delete",
            "Alt+F4",
            "Ctrl+Shift+Escape",
        ] {
            assert!(validate(&bindings(&[("dictate", key)])).is_err(), "{key}");
        }
        assert!(validate(&bindings(&[("missing", "Ctrl+Alt+M")])).is_err());
    }
    #[test]
    fn all_actions_have_distinct_windows_defaults() {
        assert!(validate(&bindings(&[
            ("dictate", "Ctrl+Alt+Space"),
            ("holdToTalk", "Ctrl+Alt+H"),
            ("meeting", "Ctrl+Alt+M"),
            ("screenshotArea", "Ctrl+Alt+4"),
            ("screenshotWindow", "Ctrl+Alt+5"),
            ("screenshotScreen", "Ctrl+Alt+3"),
            ("pasteLast", "Ctrl+Alt+V")
        ]))
        .is_ok());
    }
    #[test]
    fn right_ctrl_alone_is_only_for_dictation() {
        assert!(validate(&bindings(&[("holdToTalk", "RightCtrl")])).is_ok());
        assert!(validate(&bindings(&[("dictate", "RightCtrl")])).is_ok());
        assert!(validate(&bindings(&[("meeting", "RightCtrl")])).is_err());
        assert!(validate(&bindings(&[
            ("dictate", "RightCtrl"),
            ("holdToTalk", "RightCtrl")
        ]))
        .is_err());
    }
    #[test]
    fn cleared_actions_are_allowed() {
        assert!(validate(&bindings(&[("dictate", "Ctrl+Alt+Space")])).is_ok());
        assert!(validate(&Bindings::new()).is_ok());
    }
}
