// Orca integration — the Windows side of upstream PR #33 (macOS OrcaService).
//
// Orca (the coding-agent orchestrator) runs a local runtime that its own CLI
// talks to over a named pipe: newline-delimited JSON-RPC, authenticated with
// the authToken in %APPDATA%\orca\orca-runtime.json. Every 5 s Coucou asks it
// for `worktree.ps` and shows the worktrees in an Orca pill: one that starts
// waiting for a permission gets an alert, one that finishes gets a ✓.
//
// Read-only on purpose: approving happens in Orca ("Open Orca" brings it up),
// because answering a terminal agent remotely is exactly the kind of thing
// that must not happen behind the user's back.
//
// The token is only ever sent to a pipe served by a process of this same user
// (GetNamedPipeServerProcessId + token SID): a pipe name can be squatted by any
// account, and Orca's token would let that account drive Orca.

use std::collections::HashMap;
use std::io::{Read, Write};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{mpsc, Mutex};
use std::time::Duration;

use serde::Serialize;
use serde_json::{json, Value};

const QUERY_TIMEOUT: Duration = Duration::from_secs(4);
const MAX_REPLY: usize = 4 * 1024 * 1024;

#[derive(Serialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Worktree {
    pub id: String,
    pub name: String,
    pub repo: String,
    /// working | permission | done | active | inactive
    pub status: String,
    pub agent: String,
    pub prompt: String,
    pub tool: String,
    pub last_message: String,
}

fn runtime_path() -> Option<PathBuf> {
    std::env::var_os("APPDATA").map(|a| PathBuf::from(a).join("orca").join("orca-runtime.json"))
}

fn text(v: &Value, key: &str) -> String {
    v.get(key).and_then(Value::as_str).unwrap_or_default().to_string()
}

fn one_line(s: &str, max: usize) -> String {
    let flat = s.split_whitespace().collect::<Vec<_>>().join(" ");
    flat.chars().take(max).collect()
}

/// Rows out of a `worktree.ps` result, active ones first.
fn parse_rows(result: &Value) -> Vec<Worktree> {
    let mut rows: Vec<Worktree> = result
        .get("worktrees")
        .and_then(Value::as_array)
        .map(|list| {
            list.iter()
                .filter(|w| !w.get("isArchived").and_then(Value::as_bool).unwrap_or(false))
                .filter_map(|w| {
                    let id = text(w, "worktreeId");
                    if id.is_empty() {
                        return None;
                    }
                    let agents = w.get("agents").and_then(Value::as_array).cloned().unwrap_or_default();
                    // The agent worth showing: one that is blocked, waiting or working.
                    let agent = agents
                        .iter()
                        .find(|a| matches!(a.get("state").and_then(Value::as_str), Some("blocked" | "waiting" | "working")))
                        .or_else(|| agents.first())
                        .cloned()
                        .unwrap_or(Value::Null);
                    let mut name = text(w, "displayName");
                    if name.is_empty() {
                        name = text(w, "branch");
                    }
                    let prompt = Some(text(&agent, "prompt"))
                        .filter(|p| !p.is_empty())
                        .unwrap_or_else(|| text(&agent, "taskTitle"));
                    Some(Worktree {
                        id,
                        name,
                        repo: text(w, "repo"),
                        status: text(w, "status"),
                        agent: text(&agent, "agentType"),
                        prompt: one_line(&prompt, 160),
                        tool: one_line(&text(&agent, "toolName"), 60),
                        last_message: one_line(&text(&agent, "lastAssistantMessage"), 200),
                    })
                })
                .collect()
        })
        .unwrap_or_default();
    let rank = |s: &str| match s {
        "permission" => 0,
        "working" => 1,
        "done" => 2,
        "active" => 3,
        _ => 4,
    };
    rows.sort_by_key(|r| rank(&r.status));
    rows
}

/// One `worktree.ps` round trip. Blocking; run it off the async runtime.
fn query_blocking() -> Result<Vec<Worktree>, String> {
    let path = runtime_path().ok_or("no APPDATA")?;
    let meta: Value = serde_json::from_slice(&std::fs::read(&path).map_err(|_| "Orca isn't running on this PC.")?)
        .map_err(|_| "Orca's runtime file can't be read.")?;
    let token = meta.get("authToken").and_then(Value::as_str).ok_or("Orca's runtime file has no token.")?;
    let pipe = meta
        .get("transports")
        .and_then(Value::as_array)
        .and_then(|t| t.iter().find(|x| x.get("kind").and_then(Value::as_str) == Some("named-pipe")))
        .and_then(|x| x.get("endpoint"))
        .and_then(Value::as_str)
        .ok_or("Orca has no local pipe.")?;
    if !pipe.starts_with(r"\\.\pipe\") {
        return Err("Orca's pipe address looks wrong.".into());
    }

    let mut file = std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .open(pipe)
        .map_err(|_| "Orca isn't running on this PC.".to_string())?;
    {
        use std::os::windows::io::AsRawHandle;
        let handle = windows::Win32::Foundation::HANDLE(file.as_raw_handle());
        if !crate::win_user::pipe_server_is_same_user(handle) {
            return Err("Orca's pipe isn't served by your account — Coucou won't send it the token.".into());
        }
    }
    let request = json!({ "id": "coucou-ps", "authToken": token, "method": "worktree.ps", "params": { "limit": 50 } });
    let mut line = request.to_string();
    line.push('\n');
    file.write_all(line.as_bytes()).map_err(|e| e.to_string())?;

    let mut buf = Vec::new();
    let mut chunk = [0u8; 16 * 1024];
    loop {
        let n = file.read(&mut chunk).map_err(|e| e.to_string())?;
        if n == 0 {
            break;
        }
        buf.extend_from_slice(&chunk[..n]);
        if buf.contains(&b'\n') || buf.len() > MAX_REPLY {
            break;
        }
    }
    let end = buf.iter().position(|b| *b == b'\n').unwrap_or(buf.len());
    let reply: Value = serde_json::from_slice(&buf[..end]).map_err(|_| "Orca sent something unexpected.")?;
    if reply.get("ok").and_then(Value::as_bool) != Some(true) {
        let why = reply
            .get("error")
            .and_then(|e| e.get("message").and_then(Value::as_str).or_else(|| e.as_str()))
            .unwrap_or("request refused");
        return Err(format!("Orca: {why}"));
    }
    Ok(parse_rows(reply.get("result").unwrap_or(&Value::Null)))
}

static IN_FLIGHT: AtomicBool = AtomicBool::new(false);

/// `worktree.ps` under a deadline: a hung runtime never stalls the poller, and
/// at most one query is ever outstanding.
pub async fn query() -> Result<Vec<Worktree>, String> {
    if IN_FLIGHT.swap(true, Ordering::AcqRel) {
        return Err("Orca is slow to answer.".into());
    }
    let (tx, rx) = mpsc::channel();
    std::thread::spawn(move || {
        let _ = tx.send(query_blocking());
        IN_FLIGHT.store(false, Ordering::Release);
    });
    tauri::async_runtime::spawn_blocking(move || rx.recv_timeout(QUERY_TIMEOUT))
        .await
        .map_err(|e| e.to_string())?
        .unwrap_or_else(|_| Err("Orca is slow to answer.".into()))
}

/// What changed since the last poll: worktrees that started waiting for a
/// permission, and ones that finished. The first poll is a baseline.
pub struct Changes {
    pub attention: Vec<Worktree>,
    pub finished: Vec<Worktree>,
}

static SEEN: Mutex<Option<HashMap<String, String>>> = Mutex::new(None);

pub fn diff(rows: &[Worktree]) -> Changes {
    let mut seen = SEEN.lock().unwrap();
    let first = seen.is_none();
    let previous = seen.take().unwrap_or_default();
    let mut changes = Changes { attention: vec![], finished: vec![] };
    if !first {
        for r in rows {
            let before = previous.get(&r.id).map(String::as_str).unwrap_or("");
            if r.status == "permission" && before != "permission" {
                changes.attention.push(r.clone());
            } else if r.status == "done" && before == "working" {
                changes.finished.push(r.clone());
            }
        }
    }
    *seen = Some(rows.iter().map(|r| (r.id.clone(), r.status.clone())).collect());
    changes
}

/// "Open Orca": `orca open` launches or focuses the app. No shell involved.
pub fn open_app() -> bool {
    use std::os::windows::process::CommandExt;
    let exe = crate::find_on_path("orca").or_else(|| {
        let p = PathBuf::from(std::env::var_os("LOCALAPPDATA")?)
            .join("Programs")
            .join("orca")
            .join("resources")
            .join("bin")
            .join("orca.exe");
        p.is_file().then_some(p)
    });
    match exe {
        Some(exe) => std::process::Command::new(exe)
            .arg("open")
            .creation_flags(0x0800_0000)
            .spawn()
            .is_ok(),
        None => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn w(id: &str, status: &str) -> Value {
        json!({ "worktreeId": id, "displayName": id, "status": status, "repo": "r",
                "agents": [{ "agentType": "claude", "state": "working", "prompt": "fix   the\nbug", "toolName": "Bash" }] })
    }

    /// Asks the Orca running on this PC (read-only `worktree.ps`). `--ignored`.
    #[test]
    #[ignore]
    fn live_orca_answers_worktree_ps() {
        let rows = tauri::async_runtime::block_on(query()).expect("Orca reachable");
        println!("{} worktrees; statuses: {:?}", rows.len(), rows.iter().map(|r| r.status.as_str()).collect::<Vec<_>>());
    }

    #[test]
    fn rows_are_parsed_active_first_and_archived_skipped() {
        let mut archived = w("old", "done");
        archived["isArchived"] = json!(true);
        let rows = parse_rows(&json!({ "worktrees": [w("a", "inactive"), w("b", "permission"), archived, w("c", "working")] }));
        let ids: Vec<&str> = rows.iter().map(|r| r.id.as_str()).collect();
        assert_eq!(ids, ["b", "c", "a"]);
        assert_eq!(rows[0].prompt, "fix the bug");
        assert_eq!(rows[0].agent, "claude");
    }

    #[test]
    fn the_first_poll_is_a_baseline_then_transitions_alert() {
        *SEEN.lock().unwrap() = None;
        let row = |id: &str, s: &str| Worktree {
            id: id.into(), name: id.into(), repo: String::new(), status: s.into(),
            agent: String::new(), prompt: String::new(), tool: String::new(), last_message: String::new(),
        };
        assert!(diff(&[row("a", "permission")]).attention.is_empty(), "baseline");
        let c = diff(&[row("a", "permission"), row("b", "working")]);
        assert!(c.attention.is_empty(), "still waiting is not news");
        let c = diff(&[row("a", "working"), row("b", "done")]);
        assert_eq!(c.finished.len(), 1);
        let c = diff(&[row("a", "permission"), row("b", "done")]);
        assert_eq!(c.attention.len(), 1);
    }
}
