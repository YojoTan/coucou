// Custom Mochis' commands (CustomMochiRunner on macOS): each one the user typed
// in Settings › Extras runs every N seconds while its pill is on, in `cmd /C`,
// killed after 30 s with everything it started. The first line of its output
// is the news; an "ok:" / "working:" / "warning:" / "error:" prefix sets the
// mood, else the exit code does (ExtrasParse.commandOutput).
//
// Only the settings window can save a command (lib.rs, save_settings): the
// island renders outside text and must never be able to plant one.

use std::collections::{HashMap, HashSet};
use std::io::Read;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use serde::Serialize;
use tauri::{AppHandle, Emitter, Manager};

use super::CustomMochi;

const TIMEOUT: Duration = Duration::from_secs(30);
const MAX_OUTPUT: u64 = 4096;
const CREATE_NO_WINDOW: u32 = 0x0800_0000;

static RUNNING: Mutex<Option<HashSet<String>>> = Mutex::new(None);
static LAST_RUN: Mutex<Option<HashMap<String, Instant>>> = Mutex::new(None);

/// News for a custom Mochi, from its command or the local URL.
#[derive(Serialize, Clone, Debug, PartialEq)]
pub struct Push {
    pub id: String,
    pub text: String,
    /// idle | ok | working | warning | error
    pub state: String,
}

fn customs(app: &AppHandle) -> (Vec<CustomMochi>, Vec<String>) {
    app.try_state::<crate::Shared>()
        .map(|s| {
            let s = s.settings.lock().unwrap();
            (s.custom_mochis.clone(), s.active_integrations.clone())
        })
        .unwrap_or_default()
}

/// The user's own command, verbatim, in cmd.exe; (output, exit code).
fn shell(command: &str) -> (String, i32) {
    use std::os::windows::process::CommandExt;
    use std::process::{Command, Stdio};
    let cmd = std::env::var_os("ComSpec").unwrap_or_else(|| "cmd.exe".into());
    // /S: cmd strips the outer quotes and runs the rest exactly as typed.
    let mut child = match Command::new(cmd)
        .raw_arg(format!("/D /S /C \"{command}\""))
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .creation_flags(CREATE_NO_WINDOW)
        .spawn()
    {
        Ok(c) => c,
        Err(e) => return (e.to_string(), 127),
    };
    let job = crate::cli_chat::Job::new();
    if let Some(job) = &job {
        job.adopt(&child);
    }
    let drain = |pipe: Option<Box<dyn Read + Send>>| {
        std::thread::spawn(move || {
            let mut kept = Vec::new();
            if let Some(mut p) = pipe {
                let _ = p.by_ref().take(MAX_OUTPUT).read_to_end(&mut kept);
                // Keep reading so the command never blocks on a full pipe.
                let _ = std::io::copy(&mut p, &mut std::io::sink());
            }
            kept
        })
    };
    let out = drain(child.stdout.take().map(|p| Box::new(p) as Box<dyn Read + Send>));
    let err = drain(child.stderr.take().map(|p| Box::new(p) as Box<dyn Read + Send>));
    let started = Instant::now();
    let code = loop {
        match child.try_wait() {
            Ok(Some(status)) => break status.code().unwrap_or(1),
            Ok(None) if started.elapsed() < TIMEOUT => std::thread::sleep(Duration::from_millis(100)),
            _ => {
                // Closing the job ends the whole tree; the child itself too.
                drop(job);
                let _ = child.kill();
                let _ = child.wait();
                return ("timed out after 30 s".into(), 124);
            }
        }
    };
    drop(job);
    let mut bytes = out.join().unwrap_or_default();
    bytes.extend(err.join().unwrap_or_default());
    bytes.truncate(MAX_OUTPUT as usize);
    (String::from_utf8_lossy(&bytes).to_string(), code)
}

fn run(app: &AppHandle, m: &CustomMochi) -> bool {
    if m.command.is_empty() {
        return false;
    }
    {
        let mut running = RUNNING.lock().unwrap();
        if !running.get_or_insert_with(HashSet::new).insert(m.id.clone()) {
            return false;
        }
    }
    LAST_RUN.lock().unwrap().get_or_insert_with(HashMap::new).insert(m.id.clone(), Instant::now());
    let (app, id, command) = (app.clone(), m.id.clone(), m.command.clone());
    std::thread::spawn(move || {
        let (output, code) = shell(&command);
        let (text, mood) = super::command_output(&output, code);
        RUNNING.lock().unwrap().get_or_insert_with(HashSet::new).remove(&id);
        let _ = app.emit("custom-mochi", Push { id, text: text.chars().take(140).collect(), state: mood.into() });
    });
    true
}

/// "Run now" on the card: that Mochi's command, unless it is already running.
pub fn run_now(app: &AppHandle, id: &str) -> bool {
    let (list, _) = customs(app);
    list.iter().find(|m| m.id == id).is_some_and(|m| run(app, m))
}

pub fn start(app: AppHandle) {
    std::thread::spawn(move || {
        std::thread::sleep(Duration::from_secs(2));
        loop {
            let (list, active) = customs(&app);
            let on: Vec<&CustomMochi> = list.iter().filter(|m| !m.command.is_empty() && active.contains(&m.id)).collect();
            for m in &on {
                let due = LAST_RUN
                    .lock()
                    .unwrap()
                    .get_or_insert_with(HashMap::new)
                    .get(&m.id)
                    .is_none_or(|at| at.elapsed() >= Duration::from_secs(m.interval.max(5) as u64));
                if due {
                    run(&app, m);
                }
            }
            // Nothing to run: look again in a while, not every second.
            std::thread::sleep(Duration::from_secs(if on.is_empty() { 5 } else { 1 }));
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn commands_run_in_cmd_with_their_exit_code() {
        let (out, code) = shell("echo working: deploying & exit /b 3");
        assert_eq!(code, 3);
        assert_eq!(super::super::command_output(&out, code), ("deploying".into(), "working"));
        let (out, code) = shell("echo \"quoted & fine\"");
        assert_eq!(code, 0);
        assert!(out.contains("\"quoted & fine\""), "the command runs as typed: {out}");
    }
}
