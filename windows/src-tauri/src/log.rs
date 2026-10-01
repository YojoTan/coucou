// Small append-only log at %LOCALAPPDATA%\Coucou\coucou.log — the Windows
// equivalent of nbLog() in HookServer.swift. Nothing leaves the machine.

use std::io::Write;

use windows::Win32::System::SystemInformation::GetLocalTime;

use crate::settings;

pub fn line(message: impl AsRef<str>) {
    let t = unsafe { GetLocalTime() };
    let stamp = format!(
        "{:04}-{:02}-{:02} {:02}:{:02}:{:02}",
        t.wYear, t.wMonth, t.wDay, t.wHour, t.wMinute, t.wSecond
    );
    let dir = settings::local_dir();
    if std::fs::create_dir_all(&dir).is_err() {
        return;
    }
    let path = dir.join("coucou.log");
    // Keep it from growing forever: start fresh past ~1 MB.
    if std::fs::metadata(&path).map(|m| m.len() > 1_000_000).unwrap_or(false) {
        let _ = std::fs::remove_file(&path);
    }
    if let Ok(mut file) = std::fs::OpenOptions::new().create(true).append(true).open(path) {
        let _ = writeln!(file, "{stamp} {}", one_line(message.as_ref()));
    }
}

/// Messages carry text from outside (hook event names, the island's own lines);
/// a newline in one must not be able to forge a whole log entry, such as a
/// decision that never happened. Control characters are escaped, and a line is
/// capped so a single event cannot fill the log.
fn one_line(message: &str) -> String {
    message
        .chars()
        .take(500)
        .flat_map(|c| if c.is_control() { c.escape_default().collect::<Vec<_>>() } else { vec![c] })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::one_line;

    #[test]
    fn a_message_can_never_start_a_second_log_line() {
        let forged = one_line("hook Stop\n2026-09-30 12:00:00 decision id=1-1 allow");
        assert!(!forged.contains('\n'));
        assert!(forged.contains("\\n"));
        assert!(one_line(&"x".repeat(10_000)).len() <= 500);
    }
}
