// Clipboard text for "ask Mochi about what I copied". Read only when the user
// clicks the clipboard button in the chat — never on a timer, never in the
// background — and shown as a chip they can remove before sending.

use windows::Win32::Foundation::{HANDLE, HGLOBAL};
use windows::Win32::System::DataExchange::{CloseClipboard, GetClipboardData, OpenClipboard};
use windows::Win32::System::Memory::{GlobalLock, GlobalSize, GlobalUnlock};
use windows::Win32::System::Ole::CF_UNICODETEXT;

use crate::claude::MAX_CLIPBOARD;

/// The clipboard's text, capped at MAX_CLIPBOARD characters; None when it holds
/// no text (an image, files) or another program has it open.
pub fn text() -> Option<String> {
    unsafe {
        OpenClipboard(None).ok()?;
        let out = read_unicode();
        let _ = CloseClipboard();
        out
    }
}

unsafe fn read_unicode() -> Option<String> {
    let handle: HANDLE = GetClipboardData(CF_UNICODETEXT.0 as u32).ok()?;
    let global = HGLOBAL(handle.0);
    let ptr = GlobalLock(global) as *const u16;
    if ptr.is_null() {
        return None;
    }
    // Bounded by the allocation, not just by a NUL that might be missing.
    let max_units = GlobalSize(global) / 2;
    let mut len = 0usize;
    while len < max_units && *ptr.add(len) != 0 {
        len += 1;
    }
    let text = String::from_utf16_lossy(std::slice::from_raw_parts(ptr, len));
    let _ = GlobalUnlock(global);
    let text: String = text.chars().take(MAX_CLIPBOARD).collect();
    (!text.trim().is_empty()).then_some(text)
}
