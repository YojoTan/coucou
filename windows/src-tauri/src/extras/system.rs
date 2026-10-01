// The PC pill (macOS: the Mac pill, SystemMochi) — read locally every 5 s while
// the pill is on: CPU (GetSystemTimes deltas), battery (GetSystemPowerStatus),
// free space on the system drive (GetDiskFreeSpaceExW), and whether a build is
// running (the ToolHelp snapshot "jump" already takes). Nothing leaves the PC.

use std::sync::Mutex;
use std::time::Duration;

use serde::Serialize;
use tauri::{AppHandle, Emitter};

pub const TASK_ID: &str = "integration_system";

/// Processes that mean "something is building". `node.exe` is left out: what
/// it runs (tsc, vite, webpack…) is only in its command line, which another
/// process's memory would have to be read for.
const BUILDERS: &[&str] = &[
    "msbuild.exe", "cl.exe", "link.exe", "cargo.exe", "rustc.exe", "dotnet.exe", "go.exe", "gradle.exe",
    "clang.exe", "ninja.exe", "make.exe", "esbuild.exe",
];

#[derive(Serialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Snapshot {
    pub cpu: u32,
    /// None on a desktop PC (no battery).
    pub battery: Option<u32>,
    pub charging: bool,
    pub disk_free_gb: f64,
    pub disk_free_percent: f64,
    pub building: Option<String>,
}

static PREVIOUS: Mutex<Option<(u64, u64)>> = Mutex::new(None);

fn filetime(f: windows::Win32::Foundation::FILETIME) -> u64 {
    ((f.dwHighDateTime as u64) << 32) | f.dwLowDateTime as u64
}

/// All cores, since the last reading (0 on the first).
fn cpu() -> u32 {
    use windows::Win32::Foundation::FILETIME;
    let (mut idle, mut kernel, mut user) = (FILETIME::default(), FILETIME::default(), FILETIME::default());
    if unsafe { windows::Win32::System::Threading::GetSystemTimes(Some(&mut idle), Some(&mut kernel), Some(&mut user)) }.is_err() {
        return 0;
    }
    // Kernel time includes the idle time.
    let (idle, busy_and_idle) = (filetime(idle), filetime(kernel) + filetime(user));
    let mut previous = PREVIOUS.lock().unwrap();
    let usage = previous.map_or(0, |(pi, pt)| {
        let (di, dt) = (idle.saturating_sub(pi), busy_and_idle.saturating_sub(pt));
        if dt == 0 { 0 } else { ((dt.saturating_sub(di)) as f64 / dt as f64 * 100.0).round() as u32 }
    });
    *previous = Some((idle, busy_and_idle));
    usage.min(100)
}

fn battery() -> (Option<u32>, bool) {
    use windows::Win32::System::Power::{GetSystemPowerStatus, SYSTEM_POWER_STATUS};
    let mut s = SYSTEM_POWER_STATUS::default();
    if unsafe { GetSystemPowerStatus(&mut s) }.is_err() {
        return (None, true);
    }
    // 128: no system battery; 255: unknown.
    let level = (s.BatteryFlag & 128 == 0 && s.BatteryLifePercent <= 100).then_some(s.BatteryLifePercent as u32);
    (level, s.ACLineStatus == 1 || level.is_none())
}

fn disk() -> (f64, f64) {
    use windows::core::HSTRING;
    use windows::Win32::Storage::FileSystem::GetDiskFreeSpaceExW;
    let drive = std::env::var("SystemDrive").unwrap_or_else(|_| "C:".into());
    let root = HSTRING::from(format!("{drive}\\"));
    let (mut free, mut total) = (0u64, 0u64);
    if unsafe { GetDiskFreeSpaceExW(&root, Some(&mut free), Some(&mut total), None) }.is_err() || total == 0 {
        return (0.0, 100.0);
    }
    (free as f64 / 1e9, free as f64 / total as f64 * 100.0)
}

/// The first builder running, without ".exe".
fn building() -> Option<String> {
    let running = crate::jump::process_names();
    BUILDERS.iter().find(|b| running.contains(**b)).map(|b| b.trim_end_matches(".exe").to_string())
}

pub fn snapshot() -> Snapshot {
    let (battery, charging) = battery();
    let (disk_free_gb, disk_free_percent) = disk();
    Snapshot { cpu: cpu(), battery, charging, disk_free_gb, disk_free_percent, building: building() }
}

pub fn start(app: AppHandle) {
    std::thread::spawn(move || {
        std::thread::sleep(Duration::from_secs(2));
        loop {
            if super::pill_on(&app, TASK_ID) {
                let _ = app.emit("extras-system", snapshot());
            } else {
                // The next reading starts a fresh CPU delta.
                *PREVIOUS.lock().unwrap() = None;
            }
            std::thread::sleep(Duration::from_secs(5));
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_reading_has_sane_numbers() {
        let _ = snapshot();
        std::thread::sleep(Duration::from_millis(200));
        let s = snapshot();
        assert!(s.cpu <= 100);
        assert!((0.0..=100.0).contains(&s.disk_free_percent));
        assert!(s.disk_free_gb > 0.0, "the system drive has some room");
        assert!(s.battery.is_none_or(|b| b <= 100));
    }
}
