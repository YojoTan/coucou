// "Jump to terminal" — the Windows side of upstream PR #11 / the macOS jump.
//
// macOS can ask Terminal or iTerm for the tab behind a tty; Windows has no such
// API, but it has something better than guessing from window titles: the
// process tree. When a hook arrives, the relay that sent it is still connected,
// so its ancestors are known — claude.exe → the shell → whatever hosts the
// shell (Windows Terminal, VS Code, Orca, a classic console). The first of
// them that owns a visible window is the terminal the session runs in.
//
// The chain is computed here, from the pipe's client process id, never taken
// from the payload. Each entry keeps its exe name, so a reused pid can't make
// Coucou focus some unrelated window later.

use std::collections::HashMap;
use std::sync::Mutex;

use serde::{Deserialize, Serialize};
use windows::core::BOOL;
use windows::Win32::Foundation::{CloseHandle, HANDLE, HWND, LPARAM};
use windows::Win32::Graphics::Dwm::{DwmGetWindowAttribute, DWMWA_CLOAKED};
use windows::Win32::System::Diagnostics::ToolHelp::{
    CreateToolhelp32Snapshot, Process32FirstW, Process32NextW, PROCESSENTRY32W, TH32CS_SNAPPROCESS,
};
use windows::Win32::System::Pipes::GetNamedPipeClientProcessId;
use windows::Win32::UI::Input::KeyboardAndMouse::{
    SendInput, INPUT, INPUT_0, INPUT_KEYBOARD, KEYBDINPUT, KEYEVENTF_KEYUP, VK_MENU,
};
use windows::Win32::UI::WindowsAndMessaging::{
    EnumWindows, GetWindow, GetWindowTextW, GetWindowThreadProcessId, IsIconic, IsWindowVisible,
    SetForegroundWindow, ShowWindow, GW_OWNER, SW_RESTORE,
};

/// One ancestor of a session's relay: enough to find its window, and to tell
/// that the pid still belongs to the same program.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct HostProc {
    pub pid: u32,
    pub exe: String,
}

const MAX_DEPTH: usize = 12;
const MAX_CACHED: usize = 64;

/// Processes that are never "the terminal": walking past them means the chain
/// left the session (Explorer started the host, services started Explorer).
const STOP_AT: [&str; 4] = ["explorer.exe", "services.exe", "wininit.exe", "svchost.exe"];

/// pid → (parent pid, exe name), from one Toolhelp snapshot.
fn process_table() -> HashMap<u32, (u32, String)> {
    let mut table = HashMap::new();
    unsafe {
        let Ok(snap) = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0) else { return table };
        let mut entry = PROCESSENTRY32W { dwSize: std::mem::size_of::<PROCESSENTRY32W>() as u32, ..Default::default() };
        if Process32FirstW(snap, &mut entry).is_ok() {
            loop {
                let len = entry.szExeFile.iter().position(|c| *c == 0).unwrap_or(entry.szExeFile.len());
                let exe = String::from_utf16_lossy(&entry.szExeFile[..len]);
                table.insert(entry.th32ProcessID, (entry.th32ParentProcessID, exe));
                if Process32NextW(snap, &mut entry).is_err() {
                    break;
                }
            }
        }
        let _ = CloseHandle(snap);
    }
    table
}

/// Lower-case exe names of every running process (Discord running?).
pub fn process_names() -> std::collections::HashSet<String> {
    process_table().into_values().map(|(_, exe)| exe.to_lowercase()).collect()
}

/// The ancestors of `pid` (excluding it), nearest first.
fn ancestors_in(table: &HashMap<u32, (u32, String)>, pid: u32) -> Vec<HostProc> {
    let mut chain = Vec::new();
    let mut current = pid;
    let mut seen = vec![pid];
    while chain.len() < MAX_DEPTH {
        let Some((parent, _)) = table.get(&current) else { break };
        let parent = *parent;
        if parent == 0 || seen.contains(&parent) {
            break;
        }
        let Some((_, exe)) = table.get(&parent) else { break };
        if STOP_AT.iter().any(|s| exe.eq_ignore_ascii_case(s)) {
            break;
        }
        chain.push(HostProc { pid: parent, exe: exe.clone() });
        seen.push(parent);
        current = parent;
    }
    chain
}

static CACHE: Mutex<Vec<(String, Vec<HostProc>)>> = Mutex::new(Vec::new());

/// The process on the other end of a relay pipe.
pub fn client_pid(pipe: HANDLE) -> Option<u32> {
    let mut pid = 0u32;
    unsafe { GetNamedPipeClientProcessId(pipe, &mut pid).ok()? };
    (pid != 0).then_some(pid)
}

/// The host chain of relay `pid`, cached per session: a session's terminal
/// doesn't change, and a snapshot per tool call is waste. Blocking.
pub fn host_chain(pid: u32, session_id: &str) -> Option<Vec<HostProc>> {
    if !session_id.is_empty() {
        if let Some((_, chain)) = CACHE.lock().unwrap().iter().find(|(id, _)| id == session_id) {
            return Some(chain.clone());
        }
    }
    let chain = ancestors_in(&process_table(), pid);
    if chain.is_empty() {
        return None;
    }
    if !session_id.is_empty() {
        let mut cache = CACHE.lock().unwrap();
        if cache.len() >= MAX_CACHED {
            cache.remove(0);
        }
        cache.push((session_id.to_string(), chain.clone()));
    }
    Some(chain)
}

struct Search {
    pid: u32,
    found: Vec<(HWND, String)>,
}

fn is_cloaked(hwnd: HWND) -> bool {
    let mut cloaked = 0u32;
    unsafe {
        DwmGetWindowAttribute(hwnd, DWMWA_CLOAKED, (&mut cloaked as *mut u32).cast(), 4).is_ok() && cloaked != 0
    }
}

pub(crate) fn window_title(hwnd: HWND) -> String {
    let mut buf = [0u16; 512];
    let len = unsafe { GetWindowTextW(hwnd, &mut buf) };
    String::from_utf16_lossy(&buf[..len.max(0) as usize])
}

unsafe extern "system" fn collect(hwnd: HWND, lparam: LPARAM) -> BOOL {
    let search = unsafe { &mut *(lparam.0 as *mut Search) };
    let mut pid = 0u32;
    unsafe { GetWindowThreadProcessId(hwnd, Some(&mut pid)) };
    if pid != search.pid || !unsafe { IsWindowVisible(hwnd) }.as_bool() {
        return true.into();
    }
    // Top-level, unowned, on screen and named: what a person calls "the window".
    let owned = unsafe { GetWindow(hwnd, GW_OWNER) }.is_ok_and(|o| !o.0.is_null());
    let title = window_title(hwnd);
    if !owned && !title.trim().is_empty() && !is_cloaked(hwnd) {
        search.found.push((hwnd, title));
    }
    true.into()
}

/// Windows of `pid`, front to back (EnumWindows walks the z-order from the top).
fn windows_of(pid: u32) -> Vec<(HWND, String)> {
    let mut search = Search { pid, found: Vec::new() };
    unsafe {
        let _ = EnumWindows(Some(collect), LPARAM(&mut search as *mut Search as isize));
    }
    search.found
}

fn alt_tap() {
    let key = |up: bool| INPUT {
        r#type: INPUT_KEYBOARD,
        Anonymous: INPUT_0 {
            ki: KEYBDINPUT { wVk: VK_MENU, dwFlags: if up { KEYEVENTF_KEYUP } else { Default::default() }, ..Default::default() },
        },
    };
    unsafe { SendInput(&[key(false), key(true)], std::mem::size_of::<INPUT>() as i32) };
}

pub(crate) fn bring_to_front(hwnd: HWND) -> bool {
    unsafe {
        if IsIconic(hwnd).as_bool() {
            let _ = ShowWindow(hwnd, SW_RESTORE);
        }
        if SetForegroundWindow(hwnd).as_bool() {
            return true;
        }
        // Windows only lets the process that got the last input take the
        // foreground; the island is non-activating, so the click may not count.
        // A synthetic Alt tap is the documented-by-folklore way past that.
        alt_tap();
        SetForegroundWindow(hwnd).as_bool()
    }
}

/// Picks the window that hosts the session, nearest ancestor first; with
/// several (VS Code, one window per folder), the one naming the project wins.
fn pick(chain: &[HostProc], table: &HashMap<u32, (u32, String)>, folder: &str) -> Option<HWND> {
    let folder = folder.to_lowercase();
    for host in chain {
        // Still the same program behind that pid?
        match table.get(&host.pid) {
            Some((_, exe)) if exe.eq_ignore_ascii_case(&host.exe) => {}
            _ => continue,
        }
        let windows = windows_of(host.pid);
        if windows.is_empty() {
            continue;
        }
        let named = (!folder.is_empty())
            .then(|| windows.iter().find(|(_, t)| t.to_lowercase().contains(&folder)))
            .flatten();
        return Some(named.unwrap_or(&windows[0]).0);
    }
    None
}

/// Focuses the terminal behind a session. False: nothing to focus, so the
/// caller falls back to opening the folder.
pub fn focus(chain: &[HostProc], cwd: Option<&str>) -> bool {
    if chain.is_empty() {
        return false;
    }
    let folder = cwd
        .map(|c| c.trim_end_matches(['\\', '/']))
        .and_then(|c| c.rsplit(['\\', '/']).next())
        .unwrap_or_default();
    match pick(chain, &process_table(), folder) {
        Some(hwnd) => bring_to_front(hwnd),
        None => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_chain_walks_up_and_stops_at_explorer_or_a_loop() {
        let mut t = HashMap::new();
        t.insert(50, (40, "coucou-hook.exe".to_string()));
        t.insert(40, (30, "claude.exe".to_string()));
        t.insert(30, (20, "pwsh.exe".to_string()));
        t.insert(20, (10, "WindowsTerminal.exe".to_string()));
        t.insert(10, (1, "explorer.exe".to_string()));
        let chain = ancestors_in(&t, 50);
        let exes: Vec<&str> = chain.iter().map(|h| h.exe.as_str()).collect();
        assert_eq!(exes, ["claude.exe", "pwsh.exe", "WindowsTerminal.exe"]);

        let mut looped = HashMap::new();
        looped.insert(7, (8, "a.exe".to_string()));
        looped.insert(8, (7, "b.exe".to_string()));
        assert_eq!(ancestors_in(&looped, 7).len(), 1);
    }

    /// Which window would "jump" pick for this very process? Read-only. `--ignored`.
    #[test]
    #[ignore]
    fn live_host_window_of_this_process() {
        let table = process_table();
        let chain = ancestors_in(&table, std::process::id());
        println!("chain: {:?}", chain.iter().map(|h| h.exe.as_str()).collect::<Vec<_>>());
        let hwnd = pick(&chain, &table, "");
        println!("window: {:?}", hwnd.map(window_title));
    }

    #[test]
    fn a_reused_pid_is_not_focused() {
        let mut t = HashMap::new();
        t.insert(std::process::id(), (0, "not-the-terminal.exe".to_string()));
        let chain = [HostProc { pid: std::process::id(), exe: "WindowsTerminal.exe".into() }];
        assert!(pick(&chain, &t, "").is_none());
    }
}
