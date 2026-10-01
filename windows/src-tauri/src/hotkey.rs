// Global shortcut that opens Mochi's chat from anywhere — the Windows side of
// the macOS hotkey (AppState.hotkeyFlags/hotkeyCode). Plain Win32
// RegisterHotKey on a dedicated thread with its own message loop: no plugin,
// no hook into every keystroke — Windows only ever tells us about this one
// combination.

use std::sync::mpsc;
use std::sync::Mutex;
use std::time::Duration;

use tauri::{AppHandle, Emitter};
use windows::Win32::Foundation::{LPARAM, WPARAM};
use windows::Win32::System::Threading::GetCurrentThreadId;
use windows::Win32::UI::Input::KeyboardAndMouse::{
    RegisterHotKey, UnregisterHotKey, HOT_KEY_MODIFIERS, MOD_ALT, MOD_CONTROL, MOD_NOREPEAT, MOD_SHIFT,
};
use windows::Win32::UI::WindowsAndMessaging::{GetMessageW, PostThreadMessageW, MSG, WM_HOTKEY, WM_QUIT};

use crate::island::WINDOW_LABEL;
use crate::log;

const HOTKEY_ID: i32 = 0xC0C0;

/// The combinations offered in Settings. Kept to a short list that does not
/// collide with Windows itself (Alt+Space is the window menu, Win+… is the shell).
pub const CHOICES: &[(&str, &str)] = &[
    ("off", "Off"),
    ("ctrl+alt+space", "Ctrl + Alt + Space"),
    ("ctrl+shift+space", "Ctrl + Shift + Space"),
    ("ctrl+alt+m", "Ctrl + Alt + M"),
];

/// The listener thread currently registered, so a new choice can replace it.
static LISTENER: Mutex<Option<u32>> = Mutex::new(None);

fn parse(spec: &str) -> Option<(HOT_KEY_MODIFIERS, u32)> {
    const VK_SPACE: u32 = 0x20;
    const VK_M: u32 = 0x4D;
    match spec {
        "ctrl+alt+space" => Some((MOD_CONTROL | MOD_ALT, VK_SPACE)),
        "ctrl+shift+space" => Some((MOD_CONTROL | MOD_SHIFT, VK_SPACE)),
        "ctrl+alt+m" => Some((MOD_CONTROL | MOD_ALT, VK_M)),
        _ => None,
    }
}

fn stop() {
    if let Some(thread) = LISTENER.lock().unwrap().take() {
        unsafe {
            let _ = PostThreadMessageW(thread, WM_QUIT, WPARAM(0), LPARAM(0));
        }
    }
}

/// Registers `spec` (or nothing, for "off"), replacing any previous shortcut.
/// Fails when another program already owns the combination.
pub fn apply(app: &AppHandle, spec: &str) -> Result<(), String> {
    stop();
    let Some((mods, vk)) = parse(spec) else { return Ok(()) };

    let (tx, rx) = mpsc::channel::<Result<u32, String>>();
    let app = app.clone();
    let label = spec.to_string();
    std::thread::spawn(move || unsafe {
        if RegisterHotKey(None, HOTKEY_ID, mods | MOD_NOREPEAT, vk).is_err() {
            let _ = tx.send(Err(format!("{label} is already used by another program.")));
            return;
        }
        let _ = tx.send(Ok(GetCurrentThreadId()));
        let mut msg = MSG::default();
        // GetMessageW returns 0 on WM_QUIT and -1 on error; both end the loop.
        while GetMessageW(&mut msg, None, 0, 0).0 > 0 {
            if msg.message == WM_HOTKEY && msg.wParam.0 as i32 == HOTKEY_ID {
                let _ = app.emit_to(WINDOW_LABEL, "hotkey", ());
            }
        }
        let _ = UnregisterHotKey(None, HOTKEY_ID);
    });

    match rx.recv_timeout(Duration::from_secs(2)) {
        Ok(Ok(thread)) => {
            *LISTENER.lock().unwrap() = Some(thread);
            log::line(format!("hotkey {spec} registered"));
            Ok(())
        }
        Ok(Err(err)) => {
            log::line(format!("hotkey: {err}"));
            Err(err)
        }
        Err(_) => Err("The shortcut could not be registered.".into()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_offered_choice_parses_and_off_registers_nothing() {
        for (id, _) in CHOICES {
            assert_eq!(parse(id).is_some(), *id != "off", "{id}");
        }
        assert!(parse("alt+space").is_none(), "the window menu shortcut is never taken");
    }
}
