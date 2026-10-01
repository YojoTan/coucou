// Orca integration — the Windows side of upstream PR #33 and of the macOS
// OrcaPoller (PR #1).
//
// Orca (the coding-agent orchestrator) runs a local runtime that its own CLI
// talks to over a named pipe: newline-delimited JSON-RPC, authenticated with
// the authToken in %APPDATA%\orca\orca-runtime.json. Every 5 s, while the Orca
// pill is on, Coucou asks it for `worktree.ps` and shows the worktrees in an
// Orca pill: one that starts waiting for a permission gets an alert, one that
// finishes gets a ✓ (the island skips both when Coucou's own hooks already
// report an agent in that worktree).
//
// Permissions are answered in Orca, never from here: a row click focuses the
// agent's terminal there, ± opens the worktree's changes in Orca's editor.
// Orchestration questions and decision gates are the one thing answered from
// the island: they wait on the Run's coordinator, and the answer goes out
// through Orca's own CLI as that coordinator — only on a click, and only for a
// question or gate Coucou itself just read from Orca (the webview names it by
// id; everything else comes from here).
//
// The token is only ever sent to a pipe served by a process of this same user
// (GetNamedPipeServerProcessId + token SID): a pipe name can be squatted by any
// account, and Orca's token would let that account drive Orca.

use std::collections::{HashMap, HashSet};
use std::io::{Read, Write};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{mpsc, Mutex};
use std::time::Duration;

use serde::Serialize;
use serde_json::{json, Value};

/// One poll: `worktree.ps`, then the Runs, their inbox and their gates.
const QUERY_TIMEOUT: Duration = Duration::from_secs(8);
/// One round trip on the pipe.
const RPC_TIMEOUT: Duration = Duration::from_secs(4);
/// The CLI answering a question or opening the diff.
const CLI_TIMEOUT: Duration = Duration::from_secs(30);
const MAX_REPLY: usize = 4 * 1024 * 1024;
const MAX_ANSWER: usize = 4000;
const CREATE_NO_WINDOW: u32 = 0x0800_0000;

#[derive(Serialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Worktree {
    pub id: String,
    pub name: String,
    pub repo: String,
    /// Where the worktree lives, for the "no double alerts" check.
    pub path: String,
    /// working | permission | done | active | inactive
    pub status: String,
    pub agent: String,
    /// "<tabId>:<leafId>" of the agent's terminal pane.
    #[serde(skip)]
    pub pane_key: String,
    pub prompt: String,
    pub tool: String,
    pub last_message: String,
}

/// A question a worker asked its Run, or a pending decision gate.
#[derive(Serialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Ask {
    pub id: String,
    /// "question" | "gate"
    pub kind: &'static str,
    pub run_id: String,
    /// The Run's coordinator handle, answered as.
    #[serde(skip)]
    pub coordinator: Option<String>,
    pub text: String,
    pub options: Vec<String>,
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
                        path: text(w, "path"),
                        status: text(w, "status"),
                        agent: text(&agent, "agentType"),
                        pane_key: text(&agent, "paneKey"),
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

/// The live (non-legacy) Runs and their coordinators, from `orchestration.runList`.
fn live_runs(result: &Value) -> Vec<(String, Option<String>)> {
    result
        .get("runs")
        .and_then(Value::as_array)
        .map(|runs| {
            runs.iter()
                .filter(|r| {
                    let legacy = r.get("legacy");
                    legacy.and_then(Value::as_i64).unwrap_or(0) == 0 && !legacy.and_then(Value::as_bool).unwrap_or(false)
                })
                .filter_map(|r| {
                    let id = text(r, "id");
                    let coordinator = Some(text(r, "coordinator_handle")).filter(|c| !c.is_empty());
                    (!id.is_empty()).then_some((id, coordinator))
                })
                .collect()
        })
        .unwrap_or_default()
}

/// Unanswered questions of the live Runs: an answered one has a later message in its thread.
fn parse_questions(inbox: &Value, runs: &[(String, Option<String>)]) -> Vec<Ask> {
    let messages = inbox.get("messages").and_then(Value::as_array).cloned().unwrap_or_default();
    let threaded: HashSet<String> = messages
        .iter()
        .filter_map(|m| {
            let thread = text(m, "thread_id");
            (!thread.is_empty() && thread != text(m, "id")).then_some(thread)
        })
        .collect();
    let coordinators: HashMap<&str, &Option<String>> = runs.iter().map(|(id, c)| (id.as_str(), c)).collect();
    messages
        .iter()
        .filter(|m| m.get("type").and_then(Value::as_str) == Some("question"))
        .filter_map(|m| {
            let id = text(m, "id");
            let run = text(m, "run_id");
            if id.is_empty() || threaded.contains(&id) {
                return None;
            }
            let coordinator = (*coordinators.get(run.as_str())?).clone();
            // The options travel in the payload, as JSON text.
            let payload: Value = m
                .get("payload")
                .and_then(Value::as_str)
                .and_then(|p| serde_json::from_str(p).ok())
                .or_else(|| m.get("payload").filter(|p| p.is_object()).cloned())
                .unwrap_or(Value::Null);
            Some(Ask {
                id,
                kind: "question",
                run_id: run,
                coordinator,
                text: one_line(&text(m, "body"), 300),
                options: options(payload.get("options")),
            })
        })
        .collect()
}

/// Pending gates of one Run, from `orchestration.gateList`.
fn parse_gates(result: &Value, run: &str, coordinator: &Option<String>) -> Vec<Ask> {
    result
        .get("gates")
        .and_then(Value::as_array)
        .map(|gates| {
            gates
                .iter()
                .filter_map(|g| {
                    let id = text(g, "id");
                    (!id.is_empty()).then(|| Ask {
                        id,
                        kind: "gate",
                        run_id: run.to_string(),
                        coordinator: coordinator.clone(),
                        text: one_line(&text(g, "question"), 300),
                        options: options(g.get("options")),
                    })
                })
                .collect()
        })
        .unwrap_or_default()
}

/// Options arrive as an array or as the JSON text of one.
fn options(v: Option<&Value>) -> Vec<String> {
    let parsed;
    let list = match v {
        Some(Value::Array(a)) => a,
        Some(Value::String(s)) => match serde_json::from_str::<Value>(s) {
            Ok(Value::Array(a)) => {
                parsed = a;
                &parsed
            }
            _ => return vec![],
        },
        _ => return vec![],
    };
    list.iter().filter_map(Value::as_str).map(|s| one_line(s, 80)).filter(|s| !s.is_empty()).take(4).collect()
}

// ── The runtime's pipe ────────────────────────────────────────────────────────

struct Runtime {
    token: String,
    pipe: String,
}

fn runtime() -> Result<Runtime, String> {
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
    Ok(Runtime { token: token.to_string(), pipe: pipe.to_string() })
}

/// One JSON-RPC round trip; the `result`. Blocking: run it off the async runtime.
fn rpc_blocking(rt: &Runtime, method: &str, params: Value) -> Result<Value, String> {
    let mut file = std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .open(&rt.pipe)
        .map_err(|_| "Orca isn't running on this PC.".to_string())?;
    {
        use std::os::windows::io::AsRawHandle;
        let handle = windows::Win32::Foundation::HANDLE(file.as_raw_handle());
        if !crate::win_user::pipe_server_is_same_user(handle) {
            return Err("Orca's pipe isn't served by your account — Coucou won't send it the token.".into());
        }
    }
    let request = json!({ "id": format!("coucou-{method}"), "authToken": rt.token, "method": method, "params": params });
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
    Ok(reply.get("result").cloned().unwrap_or(Value::Null))
}

/// Blocking work under a deadline, on its own thread: a hung pipe never stalls the caller.
fn with_deadline<T: Send + 'static>(deadline: Duration, work: impl FnOnce() -> Result<T, String> + Send + 'static) -> Result<T, String> {
    let (tx, rx) = mpsc::channel();
    std::thread::spawn(move || {
        let _ = tx.send(work());
    });
    rx.recv_timeout(deadline).unwrap_or_else(|_| Err("Orca is slow to answer.".into()))
}

fn rpc(method: &'static str, params: Value) -> Result<Value, String> {
    with_deadline(RPC_TIMEOUT, move || rpc_blocking(&runtime()?, method, params))
}

/// Unanswered worker questions and pending gates, across the live Runs.
fn query_asks(rt: &Runtime) -> Vec<Ask> {
    let runs = rpc_blocking(rt, "orchestration.runList", json!({})).map(|r| live_runs(&r)).unwrap_or_default();
    if runs.is_empty() {
        return vec![];
    }
    // The inbox window is the last 100 messages.
    let inbox = rpc_blocking(rt, "orchestration.inbox", json!({ "limit": 100 })).unwrap_or(Value::Null);
    let mut asks = parse_questions(&inbox, &runs);
    for (run, coordinator) in &runs {
        if let Ok(g) = rpc_blocking(rt, "orchestration.gateList", json!({ "run": run, "status": "pending" })) {
            asks.extend(parse_gates(&g, run, coordinator));
        }
    }
    asks
}

static IN_FLIGHT: AtomicBool = AtomicBool::new(false);

/// What the last poll saw: the actions below only act on these.
static LAST: Mutex<(Vec<Worktree>, Vec<Ask>)> = Mutex::new((Vec::new(), Vec::new()));

/// One poll under a deadline: a hung runtime never stalls the poller, and at
/// most one poll is ever outstanding.
pub async fn query() -> Result<(Vec<Worktree>, Vec<Ask>), String> {
    if IN_FLIGHT.swap(true, Ordering::AcqRel) {
        return Err("Orca is slow to answer.".into());
    }
    let (tx, rx) = mpsc::channel();
    std::thread::spawn(move || {
        let result = runtime().and_then(|rt| {
            let rows = parse_rows(&rpc_blocking(&rt, "worktree.ps", json!({ "limit": 50 }))?);
            let asks = query_asks(&rt);
            Ok((rows, asks))
        });
        let _ = tx.send(result);
        IN_FLIGHT.store(false, Ordering::Release);
    });
    let result = tauri::async_runtime::spawn_blocking(move || rx.recv_timeout(QUERY_TIMEOUT))
        .await
        .map_err(|e| e.to_string())?
        .unwrap_or_else(|_| Err("Orca is slow to answer.".into()));
    if let Ok((rows, asks)) = &result {
        *LAST.lock().unwrap() = (rows.clone(), asks.clone());
    }
    result
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

// ── Actions (all on a click) ──────────────────────────────────────────────────

/// Orca's native CLI launcher. Never `orca.cmd`: cmd.exe reparses its
/// arguments, and Orca's own shim refuses message bodies for that reason.
fn cli_exe() -> Option<PathBuf> {
    let on_path = std::env::var_os("PATH").and_then(|dirs| {
        std::env::split_paths(&dirs).map(|d| d.join("orca.exe")).find(|p| p.is_file())
    });
    on_path.or_else(|| {
        let p = PathBuf::from(std::env::var_os("LOCALAPPDATA")?)
            .join("Programs")
            .join("orca")
            .join("resources")
            .join("bin")
            .join("orca.exe");
        p.is_file().then_some(p)
    })
}

/// "Open Orca": `orca open` launches or focuses the app. No shell involved.
pub fn open_app() -> bool {
    use std::os::windows::process::CommandExt;
    match cli_exe() {
        Some(exe) => std::process::Command::new(exe).arg("open").creation_flags(CREATE_NO_WINDOW).spawn().is_ok(),
        None => false,
    }
}

/// Runs the CLI with --json; Ok on `"ok": true`, else Orca's message.
fn cli(args: Vec<String>) -> Result<(), String> {
    use std::os::windows::process::CommandExt;
    use std::process::{Command, Stdio};
    let exe = cli_exe().ok_or("Orca's command-line tool wasn't found.")?;
    let mut child = Command::new(exe)
        .args(&args)
        .arg("--json")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .creation_flags(CREATE_NO_WINDOW)
        .spawn()
        .map_err(|e| e.to_string())?;
    let drain = |pipe: Option<Box<dyn Read + Send>>| {
        std::thread::spawn(move || {
            let mut kept = Vec::new();
            if let Some(mut p) = pipe {
                let _ = p.by_ref().take(MAX_REPLY as u64).read_to_end(&mut kept);
            }
            kept
        })
    };
    let stdout = drain(child.stdout.take().map(|p| Box::new(p) as Box<dyn Read + Send>));
    let stderr = drain(child.stderr.take().map(|p| Box::new(p) as Box<dyn Read + Send>));
    let started = std::time::Instant::now();
    loop {
        match child.try_wait() {
            Ok(Some(_)) => break,
            Ok(None) if started.elapsed() < CLI_TIMEOUT => std::thread::sleep(Duration::from_millis(50)),
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                return Err("Orca is slow to answer.".into());
            }
        }
    }
    let (out, err) = (stdout.join().unwrap_or_default(), stderr.join().unwrap_or_default());
    let parse = |b: &[u8]| serde_json::from_slice::<Value>(b.trim_ascii()).ok();
    let reply = parse(&out).or_else(|| parse(&err));
    if reply.as_ref().and_then(|r| r.get("ok")).and_then(Value::as_bool) == Some(true) {
        return Ok(());
    }
    let message = reply
        .as_ref()
        .and_then(|r| r.get("error"))
        .and_then(|e| e.get("message").and_then(Value::as_str).or_else(|| e.as_str()))
        .map(str::to_string)
        .unwrap_or_else(|| String::from_utf8_lossy(if err.is_empty() { &out } else { &err }).to_string());
    Err(one_line(&message, 200))
}

fn known_worktree(id: &str) -> Option<Worktree> {
    LAST.lock().unwrap().0.iter().find(|w| w.id == id).cloned()
}

/// The terminal handle of a worktree's agent pane, out of `terminal.list`.
fn terminal_for(list: &Value, w: &Worktree) -> Option<String> {
    let terminals = list.get("terminals").and_then(Value::as_array)?;
    let in_tree: Vec<&Value> = terminals.iter().filter(|t| text(t, "worktreeId") == w.id).collect();
    let leaf = w.pane_key.rsplit(':').next().unwrap_or_default();
    let pick = in_tree.iter().find(|t| !leaf.is_empty() && text(t, "leafId") == leaf).or_else(|| in_tree.first())?;
    Some(text(pick, "handle")).filter(|h| !h.is_empty())
}

/// Row click: Orca to the front, on the agent's terminal when it can be found.
pub fn focus(id: &str) -> bool {
    let Some(w) = known_worktree(id) else { return false };
    open_app();
    std::thread::spawn(move || {
        let Ok(list) = rpc("terminal.list", json!({})) else { return };
        if let Some(handle) = terminal_for(&list, &w) {
            let _ = rpc("terminal.focus", json!({ "terminal": handle, "navigation": "host" }));
        }
    });
    true
}

/// ±: the worktree's git changes, as diffs in Orca's editor.
pub fn open_changes(id: &str) -> Result<(), String> {
    let w = known_worktree(id).ok_or("That worktree is gone.")?;
    open_app();
    cli(vec!["file".into(), "open-changed".into(), "--mode".into(), "diff".into(), "--worktree".into(), format!("id:{}", w.id)])
}

/// Answers a question (`reply`) or resolves a gate as the Run's coordinator.
pub fn answer(id: &str, text: &str) -> Result<(), String> {
    let ask = LAST.lock().unwrap().1.iter().find(|a| a.id == id).cloned().ok_or("That question was answered elsewhere.")?;
    let text = text.trim();
    if text.is_empty() || text.chars().count() > MAX_ANSWER {
        return Err("The answer is empty or too long.".into());
    }
    if !ask.options.is_empty() && !ask.options.iter().any(|o| o == text) {
        return Err("That isn't one of the choices.".into());
    }
    let mut args: Vec<String> = match ask.kind {
        "gate" => vec!["orchestration".into(), "gate-resolve".into(), "--id".into(), ask.id.clone(), "--resolution".into(), text.into()],
        _ => vec![
            "orchestration".into(), "reply".into(), "--id".into(), ask.id.clone(), "--body".into(), text.into(), "--run".into(), ask.run_id.clone(),
        ],
    };
    if let Some(c) = &ask.coordinator {
        args.extend(["--from".into(), c.clone()]);
    }
    cli(args)?;
    LAST.lock().unwrap().1.retain(|a| a.id != ask.id);
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn w(id: &str, status: &str) -> Value {
        json!({ "worktreeId": id, "displayName": id, "status": status, "repo": "r", "path": "C:/src/r",
                "agents": [{ "agentType": "claude", "state": "working", "prompt": "fix   the\nbug", "toolName": "Bash",
                             "paneKey": "tab-1:leaf-2", "taskTitle": null }] })
    }

    /// Asks the Orca running on this PC (read-only `worktree.ps` and the Runs). `--ignored`.
    #[test]
    #[ignore]
    fn live_orca_answers_worktree_ps() {
        let (rows, asks) = tauri::async_runtime::block_on(query()).expect("Orca reachable");
        println!("{} worktrees; statuses: {:?}; {} asks", rows.len(), rows.iter().map(|r| r.status.as_str()).collect::<Vec<_>>(), asks.len());
        let list = rpc("terminal.list", json!({})).expect("terminal.list");
        for r in &rows {
            println!("{} → terminal {:?}", r.name, terminal_for(&list, r).is_some());
        }
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
        assert_eq!(rows[0].pane_key, "tab-1:leaf-2");
        assert_eq!(rows[0].path, "C:/src/r");
    }

    #[test]
    fn the_first_poll_is_a_baseline_then_transitions_alert() {
        *SEEN.lock().unwrap() = None;
        let row = |id: &str, s: &str| Worktree {
            id: id.into(), name: id.into(), repo: String::new(), path: String::new(), status: s.into(),
            agent: String::new(), pane_key: String::new(), prompt: String::new(), tool: String::new(), last_message: String::new(),
        };
        assert!(diff(&[row("a", "permission")]).attention.is_empty(), "baseline");
        let c = diff(&[row("a", "permission"), row("b", "working")]);
        assert!(c.attention.is_empty(), "still waiting is not news");
        let c = diff(&[row("a", "working"), row("b", "done")]);
        assert_eq!(c.finished.len(), 1);
        let c = diff(&[row("a", "permission"), row("b", "done")]);
        assert_eq!(c.attention.len(), 1);
    }

    #[test]
    fn questions_and_gates_of_live_runs_only() {
        let runs = live_runs(&json!({ "runs": [
            { "id": "run_legacy_local", "coordinator_handle": null, "legacy": 1 },
            { "id": "r1", "coordinator_handle": "term_coord", "legacy": 0 },
        ] }));
        assert_eq!(runs, vec![("r1".to_string(), Some("term_coord".to_string()))]);

        let inbox = json!({ "messages": [
            { "id": "q1", "type": "question", "run_id": "r1", "body": "Which   db?", "payload": "{\"options\":[\"pg\",\"sqlite\"]}" },
            { "id": "q2", "type": "question", "run_id": "r1", "body": "answered", "thread_id": "q2" },
            { "id": "a2", "type": "status", "run_id": "r1", "body": "ok", "thread_id": "q2" },
            { "id": "q3", "type": "question", "run_id": "run_legacy_local", "body": "old" },
            { "id": "q4", "type": "question", "run_id": "r1", "body": "free text?" },
        ] });
        let asks = parse_questions(&inbox, &runs);
        let ids: Vec<&str> = asks.iter().map(|a| a.id.as_str()).collect();
        assert_eq!(ids, ["q1", "q4"], "answered and legacy questions are skipped");
        assert_eq!(asks[0].text, "Which db?");
        assert_eq!(asks[0].options, ["pg", "sqlite"]);
        assert_eq!(asks[0].coordinator.as_deref(), Some("term_coord"));
        assert!(asks[1].options.is_empty());

        let gates = parse_gates(&json!({ "gates": [{ "id": "g1", "question": "Ship it?", "options": "[\"yes\",\"no\"]" }] }), "r1", &runs[0].1);
        assert_eq!(gates[0].kind, "gate");
        assert_eq!(gates[0].options, ["yes", "no"]);
    }

    #[test]
    fn a_row_click_finds_the_agents_own_pane() {
        let mut row = parse_rows(&json!({ "worktrees": [w("wt", "working")] })).remove(0);
        let list = json!({ "terminals": [
            { "handle": "term_other", "worktreeId": "elsewhere", "leafId": "leaf-2" },
            { "handle": "term_first", "worktreeId": "wt", "leafId": "leaf-1" },
            { "handle": "term_agent", "worktreeId": "wt", "leafId": "leaf-2" },
        ] });
        assert_eq!(terminal_for(&list, &row).as_deref(), Some("term_agent"));
        row.pane_key = String::new();
        assert_eq!(terminal_for(&list, &row).as_deref(), Some("term_first"), "else the worktree's first terminal");
    }

    #[test]
    fn answers_go_only_to_known_asks_and_choices() {
        *LAST.lock().unwrap() = (vec![], vec![Ask {
            id: "g1".into(), kind: "gate", run_id: "r1".into(), coordinator: None, text: "Ship?".into(), options: vec!["yes".into(), "no".into()],
        }]);
        assert!(answer("nope", "yes").unwrap_err().contains("answered elsewhere"));
        assert!(answer("g1", "maybe").unwrap_err().contains("choices"));
        assert!(answer("g1", "   ").unwrap_err().contains("empty"));
        assert!(open_changes("unknown").is_err());
        assert!(!focus("unknown"));
    }
}
