// Chat through an AI CLI the user already has installed and logged into —
// Claude Code (its subscription login), Codex, Gemini CLI or opencode — instead
// of an Anthropic API key. The idea comes from upstream PR #12 (macOS) and
// PR #19 (opencode on Windows); the Codex flags follow PR #23. This version is
// stricter than all three, because a chat box must never become an agent that
// edits files or runs commands:
//
//   * runs happen in %LOCALAPPDATA%\Coucou\chat, never in a user project;
//   * Claude Code gets only Read, WebSearch and WebFetch (`--tools` removes
//     every other tool, `--allowedTools` pre-approves those three);
//   * Codex runs ephemeral, read-only, with shell, browser, MCP and plugins off;
//   * the prompt goes in on stdin wherever the CLI accepts it, so it can never
//     be read as a flag;
//   * every run is in a Job Object: a timeout kills the whole process tree;
//   * COUCOU_INTERNAL=1 tells coucou-hook to ignore the run, so Mochi's own
//     chat never shows up as a Claude Code session or asks itself for approval.

use std::collections::HashMap;
use std::io::{Read, Write};
use std::os::windows::io::AsRawHandle;
use std::os::windows::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use serde::Serialize;
use serde_json::Value;
use windows::core::PCWSTR;
use windows::Win32::Foundation::{CloseHandle, HANDLE};
use windows::Win32::System::JobObjects::{
    AssignProcessToJobObject, CreateJobObjectW, JobObjectExtendedLimitInformation,
    SetInformationJobObject, TerminateJobObject, JOBOBJECT_EXTENDED_LIMIT_INFORMATION,
    JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
};

use crate::claude::{ChatContext, ChatReply};

/// Set on every chat run; coucou-hook exits at once when it sees it.
pub const ENV_INTERNAL: &str = "COUCOU_INTERNAL";

const CREATE_NO_WINDOW: u32 = 0x0800_0000;
const RUN_TIMEOUT: Duration = Duration::from_secs(180);
const VERSION_TIMEOUT: Duration = Duration::from_secs(8);
/// Output beyond this is read and thrown away, so a runaway CLI cannot fill memory.
const MAX_OUTPUT: usize = 4 * 1024 * 1024;
/// Engines without their own session store replay this much history.
const MAX_HISTORY_CHARS: usize = 60_000;
const MAX_INLINE_TEXT: u64 = 200_000;

const PERSONA: &str = "You are Mochi, a small assistant living at the top of the user's screen. \
Answer in the user's language, clearly and completely. \
Plain text only: no markdown (no **, no #, no bullet dashes), just line breaks. \
Never create, edit or delete files, and never run commands.";

#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug)]
pub enum Engine {
    Claude,
    Codex,
    Gemini,
    Opencode,
}

impl Engine {
    pub const ALL: [Engine; 4] = [Engine::Claude, Engine::Codex, Engine::Gemini, Engine::Opencode];

    pub fn id(self) -> &'static str {
        match self {
            Engine::Claude => "claude",
            Engine::Codex => "codex",
            Engine::Gemini => "gemini",
            Engine::Opencode => "opencode",
        }
    }

    pub fn from_id(id: &str) -> Option<Engine> {
        Engine::ALL.into_iter().find(|e| e.id() == id)
    }

    pub fn label(self) -> &'static str {
        match self {
            Engine::Claude => "Claude Code",
            Engine::Codex => "Codex",
            Engine::Gemini => "Gemini CLI",
            Engine::Opencode => "opencode",
        }
    }

    /// Only Claude Code has been run end to end on Windows for this build.
    pub fn experimental(self) -> bool {
        !matches!(self, Engine::Claude)
    }
}

#[derive(Serialize, Clone, Debug)]
#[serde(rename_all = "camelCase")]
pub struct EngineInfo {
    pub id: String,
    pub label: String,
    pub installed: bool,
    pub path: Option<String>,
    pub version: Option<String>,
    pub experimental: bool,
}

/// Where the CLI lives: PATH first, then the usual per-user install folders
/// (an app started from the Start menu may not have the shell's PATH).
pub fn locate(engine: Engine) -> Option<PathBuf> {
    if let Some(p) = crate::find_on_path(engine.id()) {
        return Some(p);
    }
    let home = std::env::var_os("USERPROFILE").map(PathBuf::from)?;
    let appdata = std::env::var_os("APPDATA").map(PathBuf::from);
    let name = engine.id();
    let mut candidates = vec![
        home.join(".local").join("bin").join(format!("{name}.exe")),
        home.join(".bun").join("bin").join(format!("{name}.exe")),
        home.join("scoop").join("shims").join(format!("{name}.exe")),
        home.join(format!(".{name}")).join("bin").join(format!("{name}.exe")),
    ];
    if let Some(appdata) = appdata {
        candidates.push(appdata.join("npm").join(format!("{name}.cmd")));
    }
    candidates.into_iter().find(|p| p.is_file())
}

/// Every supported CLI, installed or not, with its version. Blocking.
pub fn detect() -> Vec<EngineInfo> {
    Engine::ALL
        .into_iter()
        .map(|engine| {
            let path = locate(engine);
            let version = path.as_deref().and_then(|exe| {
                let out = run(exe, &["--version".to_string()], &std::env::temp_dir(), None, VERSION_TIMEOUT).ok()?;
                out.stdout
                    .lines()
                    .map(str::trim)
                    .find(|l| !l.is_empty())
                    .map(|l| l.chars().take(60).collect())
            });
            EngineInfo {
                id: engine.id().into(),
                label: engine.label().into(),
                installed: path.is_some(),
                path: path.map(|p| p.to_string_lossy().to_string()),
                version,
                experimental: engine.experimental(),
            }
        })
        .collect()
}

// ── Conversation state ────────────────────────────────────────────────────────

#[derive(Default)]
pub struct CliChat {
    inner: Mutex<Conversation>,
}

#[derive(Default)]
struct Conversation {
    engine: Option<Engine>,
    /// Claude Code keeps its own session; follow-ups resume it.
    claude_session: Option<String>,
    /// The others get the conversation replayed: (user, assistant) turns.
    turns: Vec<(String, String)>,
    busy: bool,
}

impl CliChat {
    pub fn reset(&self) {
        let mut c = self.inner.lock().unwrap();
        let busy = c.busy;
        *c = Conversation::default();
        c.busy = busy;
    }
}

/// One chat turn through `engine`. `model` is optional: empty means the CLI's own default.
pub async fn send(
    chat: &CliChat,
    engine: Engine,
    model: &str,
    query: String,
    context: Option<ChatContext>,
) -> Result<ChatReply, String> {
    let exe = locate(engine).ok_or_else(|| {
        format!("{} isn't installed. Pick another engine in Settings → Chat.", engine.label())
    })?;

    let (resume, turns, first) = {
        let mut c = chat.inner.lock().unwrap();
        if c.busy {
            return Err("Still answering the previous message…".into());
        }
        if c.engine != Some(engine) {
            *c = Conversation { engine: Some(engine), ..Default::default() };
        }
        c.busy = true;
        let first = c.claude_session.is_none() && c.turns.is_empty();
        (c.claude_session.clone(), c.turns.clone(), first)
    };

    let plan = build_plan(engine, model.trim(), &query, if first { context.as_ref() } else { None }, resume.as_deref(), &turns);
    let outcome = match plan {
        Ok(plan) => {
            let dir = work_dir();
            tokio::task::spawn_blocking(move || {
                let dir = dir?;
                run(&exe, &plan.args, &dir, plan.stdin.as_deref(), RUN_TIMEOUT)
            })
            .await
            .map_err(|e| format!("{} task failed: {e}", engine.label()))
            .and_then(|r| r)
        }
        Err(e) => Err(e),
    };

    let mut c = chat.inner.lock().unwrap();
    c.busy = false;
    let out = outcome?;
    if out.timed_out {
        return Err(format!("{} took too long to answer.", engine.label()));
    }
    let parsed = parse(engine, &out.stdout);
    if let (Engine::Claude, Some(id)) = (engine, parsed.session.clone()) {
        c.claude_session = Some(id);
    }
    match parsed.text.filter(|t| !t.trim().is_empty()) {
        Some(text) if !parsed.is_error => {
            if engine != Engine::Claude {
                c.turns.push((query, text.clone()));
            }
            Ok(ChatReply { text: text.trim().to_string() })
        }
        other => {
            let detail = other
                .or_else(|| out.stderr.lines().rev().map(str::trim).find(|l| !l.is_empty()).map(str::to_string))
                .unwrap_or_else(|| format!("exit code {}", out.code.map_or("?".into(), |c| c.to_string())));
            Err(format!("{}: {}", engine.label(), detail.chars().take(400).collect::<String>()))
        }
    }
}

fn work_dir() -> Result<PathBuf, String> {
    let dir = crate::settings::local_dir().join("chat");
    std::fs::create_dir_all(&dir).map_err(|e| format!("cannot create the chat folder: {e}"))?;
    Ok(dir)
}

struct Plan {
    args: Vec<String>,
    stdin: Option<String>,
}

/// What a dropped file contributes, per engine. Only inbox copies are used.
struct Attachment {
    path: PathBuf,
    inline_text: Option<String>,
    is_image: bool,
}

fn attachment(context: Option<&ChatContext>) -> Option<Attachment> {
    let Some(ChatContext::File { path, .. }) = context else { return None };
    let path = crate::claude::inbox_file(path)?;
    let ext = path.extension().and_then(|e| e.to_str()).unwrap_or("").to_lowercase();
    let is_image = matches!(ext.as_str(), "png" | "jpg" | "jpeg" | "gif" | "webp");
    let inline_text = if is_image || ext == "pdf" {
        None
    } else {
        std::fs::metadata(&path)
            .ok()
            .filter(|m| m.len() <= MAX_INLINE_TEXT)
            .and_then(|_| std::fs::read_to_string(&path).ok())
    };
    Some(Attachment { path, inline_text, is_image })
}

fn context_line(context: Option<&ChatContext>) -> Option<String> {
    match context? {
        ChatContext::File { name, .. } => Some(format!("The user attached a file: {name}")),
        ChatContext::Window { app_name, title, url } => {
            let mut s = format!("Context — App: {app_name}, Window: {title}");
            if let Some(url) = url {
                s.push_str(&format!(", URL: {url}"));
            }
            Some(s)
        }
    }
}

/// The conversation so far, newest last, trimmed from the front to a budget.
fn transcript(turns: &[(String, String)]) -> String {
    let mut parts: Vec<String> = turns
        .iter()
        .map(|(u, a)| format!("User: {u}\nMochi: {a}"))
        .collect();
    let mut total: usize = parts.iter().map(String::len).sum();
    while total > MAX_HISTORY_CHARS && !parts.is_empty() {
        total -= parts.remove(0).len();
    }
    parts.join("\n\n")
}

fn build_plan(
    engine: Engine,
    model: &str,
    query: &str,
    context: Option<&ChatContext>,
    resume: Option<&str>,
    turns: &[(String, String)],
) -> Result<Plan, String> {
    let file = attachment(context);
    if matches!(context, Some(ChatContext::File { .. })) && file.is_none() {
        return Err("That file is not in Coucou's inbox yet — drop it again.".into());
    }
    let inbox = crate::files::inbox_dir();
    let mut lines: Vec<String> = Vec::new();
    if let Some(line) = context_line(context) {
        lines.push(line);
    }

    match engine {
        Engine::Claude => {
            let tools = "Read,WebSearch,WebFetch";
            let mut args: Vec<String> = vec![
                "-p".into(),
                "--output-format".into(),
                "json".into(),
                "--tools".into(),
                tools.into(),
                "--allowedTools".into(),
                tools.into(),
                "--append-system-prompt".into(),
                PERSONA.into(),
            ];
            if !model.is_empty() {
                args.push("--model".into());
                args.push(model.into());
            }
            if let Some(id) = resume {
                args.push("--resume".into());
                args.push(id.into());
            }
            if let Some(f) = &file {
                args.push("--add-dir".into());
                args.push(inbox.to_string_lossy().to_string());
                lines.push(format!("Its path is {} — read it to answer.", f.path.display()));
            }
            lines.push(query.into());
            Ok(Plan { args, stdin: Some(lines.join("\n\n")) })
        }
        Engine::Codex => {
            let mut args: Vec<String> = [
                "exec",
                "--json",
                "--ephemeral",
                "--ignore-user-config",
                "--ignore-rules",
                "--skip-git-repo-check",
                "--sandbox",
                "read-only",
                "-c",
                "approval_policy=\"never\"",
                "-c",
                "project_doc_max_bytes=0",
                "-c",
                "features.hooks=false",
                "-c",
                "features.shell_tool=false",
                "-c",
                "features.unified_exec=false",
                "-c",
                "features.browser_use=false",
                "-c",
                "features.computer_use=false",
                "-c",
                "features.multi_agent=false",
                "-c",
                "features.apps=false",
                "-c",
                "features.plugins=false",
            ]
            .into_iter()
            .map(String::from)
            .collect();
            if !model.is_empty() {
                args.push("--model".into());
                args.push(model.into());
            }
            if let Some(f) = file.as_ref().filter(|f| f.is_image) {
                args.push("--image".into());
                args.push(f.path.to_string_lossy().to_string());
            }
            args.push("-".into());
            Ok(Plan { args, stdin: Some(replayed_prompt(&lines, file.as_ref(), turns, query)) })
        }
        Engine::Gemini => {
            let mut args: Vec<String> = vec!["--output-format".into(), "json".into()];
            if !model.is_empty() {
                args.push("--model".into());
                args.push(model.into());
            }
            if let Some(f) = file.as_ref().filter(|f| f.inline_text.is_none()) {
                args.push("--include-directories".into());
                args.push(inbox.to_string_lossy().to_string());
                lines.push(format!("Its path is {} — read it to answer.", f.path.display()));
            }
            Ok(Plan { args, stdin: Some(replayed_prompt(&lines, file.as_ref(), turns, query)) })
        }
        Engine::Opencode => {
            // `opencode run` takes the message as an argument, not on stdin. It
            // always starts with the persona, so it can never look like a flag,
            // and `--` ends option parsing before it anyway.
            let dir = work_dir()?;
            let mut args: Vec<String> = vec![
                "run".into(),
                "--format".into(),
                "json".into(),
                "--agent".into(),
                "plan".into(),
                "--dir".into(),
                dir.to_string_lossy().to_string(),
            ];
            if !model.is_empty() {
                args.push("--model".into());
                args.push(model.into());
            }
            if let Some(f) = file.as_ref().filter(|f| f.inline_text.is_none()) {
                args.push("--file".into());
                args.push(f.path.to_string_lossy().to_string());
            }
            args.push("--".into());
            args.push(replayed_prompt(&lines, file.as_ref(), turns, query));
            Ok(Plan { args, stdin: None })
        }
    }
}

/// Persona, earlier turns, context and the new question, as one message.
fn replayed_prompt(lines: &[String], file: Option<&Attachment>, turns: &[(String, String)], query: &str) -> String {
    let mut out = String::from(PERSONA);
    let history = transcript(turns);
    if !history.is_empty() {
        out.push_str("\n\nConversation so far:\n");
        out.push_str(&history);
    }
    for line in lines {
        out.push_str("\n\n");
        out.push_str(line);
    }
    if let Some(text) = file.and_then(|f| f.inline_text.as_deref()) {
        out.push_str("\n\nFile contents:\n");
        out.push_str(text);
    }
    out.push_str("\n\nUser: ");
    out.push_str(query);
    out
}

// ── Output parsing ────────────────────────────────────────────────────────────

#[derive(Default, Debug)]
struct Parsed {
    text: Option<String>,
    session: Option<String>,
    is_error: bool,
}

fn parse(engine: Engine, stdout: &str) -> Parsed {
    match engine {
        // {"type":"result","result":"…","session_id":"…","is_error":false}
        Engine::Claude => match serde_json::from_str::<Value>(stdout.trim()) {
            Ok(v) => Parsed {
                text: v.get("result").and_then(Value::as_str).map(str::to_string),
                session: v.get("session_id").and_then(Value::as_str).map(str::to_string),
                is_error: v.get("is_error").and_then(Value::as_bool).unwrap_or(false),
            },
            Err(_) => Parsed { text: non_empty(stdout), is_error: true, ..Default::default() },
        },
        // JSONL: item.completed {item:{type:agent_message,text}}, error, turn.failed
        Engine::Codex => {
            let mut p = Parsed::default();
            for v in json_lines(stdout) {
                match v.get("type").and_then(Value::as_str) {
                    Some("item.completed") => {
                        let item = v.get("item");
                        if item.and_then(|i| i.get("type")).and_then(Value::as_str) == Some("agent_message") {
                            p.text = item.and_then(|i| i.get("text")).and_then(Value::as_str).map(str::to_string);
                        }
                    }
                    Some("error") => {
                        p.is_error = true;
                        p.text = v.get("message").and_then(Value::as_str).map(str::to_string).or(p.text);
                    }
                    Some("turn.failed") => {
                        p.is_error = true;
                        p.text = v
                            .get("error")
                            .and_then(|e| e.get("message"))
                            .and_then(Value::as_str)
                            .map(str::to_string)
                            .or(p.text);
                    }
                    _ => {}
                }
            }
            p
        }
        // {"response":"…"} or {"error":{"message":"…"}}; older versions print plain text.
        Engine::Gemini => {
            let json = stdout.find('{').and_then(|i| serde_json::from_str::<Value>(&stdout[i..]).ok());
            match json {
                Some(v) => match v.get("error") {
                    Some(e) => Parsed {
                        text: e.get("message").and_then(Value::as_str).map(str::to_string),
                        is_error: true,
                        ..Default::default()
                    },
                    None => Parsed {
                        text: v.get("response").and_then(Value::as_str).map(str::to_string),
                        ..Default::default()
                    },
                },
                None => Parsed { text: non_empty(stdout), ..Default::default() },
            }
        }
        // JSONL: {"type":"text","part":{"text":"…"}}, {"type":"error","error":{…}}
        Engine::Opencode => {
            let mut p = Parsed::default();
            let mut text = String::new();
            for v in json_lines(stdout) {
                match v.get("type").and_then(Value::as_str) {
                    Some("text") => {
                        if let Some(t) = v.get("part").and_then(|p| p.get("text")).and_then(Value::as_str) {
                            text.push_str(t);
                        }
                    }
                    Some("error") => {
                        p.is_error = true;
                        p.text = v
                            .get("error")
                            .and_then(|e| {
                                e.get("data")
                                    .and_then(|d| d.get("message"))
                                    .or_else(|| e.get("message"))
                                    .and_then(Value::as_str)
                            })
                            .map(str::to_string)
                            .or_else(|| Some("opencode reported an error.".into()));
                    }
                    _ => {}
                }
            }
            if !p.is_error {
                p.text = non_empty(&text);
            }
            p
        }
    }
}

fn json_lines(s: &str) -> impl Iterator<Item = Value> + '_ {
    s.lines()
        .map(str::trim)
        .filter(|l| l.starts_with('{'))
        .filter_map(|l| serde_json::from_str::<Value>(l).ok())
}

fn non_empty(s: &str) -> Option<String> {
    let t = s.trim();
    (!t.is_empty()).then(|| t.to_string())
}

// ── Process runner ────────────────────────────────────────────────────────────

pub struct RunOutput {
    pub code: Option<i32>,
    pub stdout: String,
    pub stderr: String,
    pub timed_out: bool,
}

/// A Job Object that kills every process in it when it is closed or terminated.
/// npm-installed CLIs are `.cmd` shims that start node, so killing only the
/// direct child would leave the real process running after a timeout.
struct Job(HANDLE);

impl Job {
    fn new() -> Option<Job> {
        unsafe {
            let job = CreateJobObjectW(None, PCWSTR::null()).ok()?;
            let mut info = JOBOBJECT_EXTENDED_LIMIT_INFORMATION::default();
            info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
            let ok = SetInformationJobObject(
                job,
                JobObjectExtendedLimitInformation,
                (&info as *const JOBOBJECT_EXTENDED_LIMIT_INFORMATION).cast(),
                std::mem::size_of::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>() as u32,
            );
            if ok.is_err() {
                let _ = CloseHandle(job);
                return None;
            }
            Some(Job(job))
        }
    }

    fn adopt(&self, child: &std::process::Child) {
        unsafe {
            let _ = AssignProcessToJobObject(self.0, HANDLE(child.as_raw_handle()));
        }
    }

    fn kill(&self) {
        unsafe {
            let _ = TerminateJobObject(self.0, 1);
        }
    }
}

impl Drop for Job {
    fn drop(&mut self) {
        unsafe {
            let _ = CloseHandle(self.0);
        }
    }
}

fn drain(mut reader: impl Read + Send + 'static) -> std::thread::JoinHandle<String> {
    std::thread::spawn(move || {
        let mut kept = Vec::new();
        let mut chunk = [0u8; 8192];
        loop {
            match reader.read(&mut chunk) {
                Ok(0) | Err(_) => break,
                Ok(n) => {
                    let room = MAX_OUTPUT.saturating_sub(kept.len());
                    kept.extend_from_slice(&chunk[..n.min(room)]);
                }
            }
        }
        String::from_utf8_lossy(&kept).to_string()
    })
}

/// Runs `exe` with no console window, a deadline and capped output. Blocking.
pub fn run(exe: &Path, args: &[String], cwd: &Path, stdin: Option<&str>, timeout: Duration) -> Result<RunOutput, String> {
    let mut cmd = Command::new(exe);
    cmd.args(args)
        .current_dir(cwd)
        .stdin(if stdin.is_some() { Stdio::piped() } else { Stdio::null() })
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .creation_flags(CREATE_NO_WINDOW)
        .env(ENV_INTERNAL, "1")
        .env("NO_COLOR", "1");
    // Nothing that would make a hook (ours or anyone's) take this run for an
    // editor session the user is driving.
    for var in ["TERM_PROGRAM", "TERM_PROGRAM_VERSION", "VSCODE_PID", "WT_SESSION", "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT"] {
        cmd.env_remove(var);
    }

    let job = Job::new();
    let mut child = cmd.spawn().map_err(|e| format!("could not start {}: {e}", exe.display()))?;
    if let Some(job) = &job {
        job.adopt(&child);
    }

    if let (Some(text), Some(mut pipe)) = (stdin, child.stdin.take()) {
        let text = text.to_string();
        std::thread::spawn(move || {
            let _ = pipe.write_all(text.as_bytes());
        });
    }
    let out = child.stdout.take().map(drain);
    let err = child.stderr.take().map(drain);

    let deadline = Instant::now() + timeout;
    let mut timed_out = false;
    let code = loop {
        match child.try_wait() {
            Ok(Some(status)) => break status.code(),
            Ok(None) if Instant::now() >= deadline => {
                timed_out = true;
                match &job {
                    Some(job) => job.kill(),
                    None => {
                        let _ = child.kill();
                    }
                }
                let _ = child.wait();
                break None;
            }
            Ok(None) => std::thread::sleep(Duration::from_millis(50)),
            Err(e) => return Err(e.to_string()),
        }
    };

    Ok(RunOutput {
        code,
        stdout: out.and_then(|h| h.join().ok()).unwrap_or_default(),
        stderr: err.and_then(|h| h.join().ok()).unwrap_or_default(),
        timed_out,
    })
}

/// Engines the user can pick, keyed by id, for `resolve`.
pub fn installed() -> HashMap<Engine, PathBuf> {
    Engine::ALL.into_iter().filter_map(|e| locate(e).map(|p| (e, p))).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn claude_output_is_parsed_with_its_session() {
        let p = parse(Engine::Claude, r#"{"type":"result","result":"hola Mochi","session_id":"abc","is_error":false}"#);
        assert_eq!(p.text.as_deref(), Some("hola Mochi"));
        assert_eq!(p.session.as_deref(), Some("abc"));
        assert!(!p.is_error);
        let e = parse(Engine::Claude, r#"{"result":"Not logged in · Please run /login","is_error":true}"#);
        assert!(e.is_error);
    }

    #[test]
    fn codex_gemini_and_opencode_outputs_are_parsed() {
        let codex = "{\"type\":\"thread.started\",\"thread_id\":\"t1\"}\n{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"hi\"}}\n";
        assert_eq!(parse(Engine::Codex, codex).text.as_deref(), Some("hi"));
        let failed = "{\"type\":\"turn.failed\",\"error\":{\"message\":\"no login\"}}";
        let f = parse(Engine::Codex, failed);
        assert!(f.is_error);
        assert_eq!(f.text.as_deref(), Some("no login"));

        assert_eq!(parse(Engine::Gemini, "Loaded\n{\"response\":\"ok\"}").text.as_deref(), Some("ok"));
        assert!(parse(Engine::Gemini, "{\"error\":{\"message\":\"quota\"}}").is_error);

        let oc = "{\"type\":\"text\",\"part\":{\"text\":\"a\"}}\n{\"type\":\"step_finish\"}\n{\"type\":\"text\",\"part\":{\"text\":\"b\"}}";
        assert_eq!(parse(Engine::Opencode, oc).text.as_deref(), Some("ab"));
    }

    #[test]
    fn claude_runs_read_only_and_takes_the_prompt_on_stdin() {
        let plan = build_plan(Engine::Claude, "", "--help me", None, Some("s1"), &[]).unwrap();
        let joined = plan.args.join(" ");
        assert!(joined.contains("--tools Read,WebSearch,WebFetch"));
        assert!(joined.contains("--allowedTools Read,WebSearch,WebFetch"));
        assert!(joined.contains("--resume s1"));
        assert!(!plan.args.iter().any(|a| a.contains("help me")), "the prompt must not be an argument");
        assert!(!joined.contains("dangerously"));
        assert_eq!(plan.stdin.as_deref(), Some("--help me"));
    }

    #[test]
    fn codex_is_sandboxed_read_only_and_opencode_ends_options_before_the_message() {
        let codex = build_plan(Engine::Codex, "", "hi", None, None, &[]).unwrap();
        let joined = codex.args.join(" ");
        assert!(joined.contains("--sandbox read-only"));
        assert!(joined.contains("features.shell_tool=false"));
        assert_eq!(codex.args.last().map(String::as_str), Some("-"));

        let oc = build_plan(Engine::Opencode, "", "-rf", None, None, &[]).unwrap();
        let dash = oc.args.iter().position(|a| a == "--").unwrap();
        assert_eq!(dash, oc.args.len() - 2);
        assert!(oc.args.last().unwrap().starts_with("You are Mochi"));
    }

    #[test]
    fn history_is_trimmed_from_the_oldest_turn() {
        let turns: Vec<(String, String)> = (0..100).map(|i| (format!("q{i}"), "x".repeat(2_000))).collect();
        let t = transcript(&turns);
        assert!(t.len() <= MAX_HISTORY_CHARS + 2_100);
        assert!(t.contains("q99") && !t.contains("q0\n"));
    }

    /// Talks to the real Claude Code on this machine (uses its login). Run with
    /// `--ignored`; it is the end-to-end check that resume keeps the thread.
    #[test]
    #[ignore]
    fn live_claude_code_keeps_the_conversation() {
        let chat = CliChat::default();
        let first = tauri::async_runtime::block_on(send(&chat, Engine::Claude, "", "Remember the word 'albaricoque'. Reply only: ok".into(), None))
            .expect("first turn");
        assert!(!first.text.is_empty());
        let second = tauri::async_runtime::block_on(send(&chat, Engine::Claude, "", "Which word did I ask you to remember? Reply with the word only.".into(), None))
            .expect("second turn");
        assert!(second.text.to_lowercase().contains("albaricoque"), "got: {}", second.text);
    }

    #[test]
    fn a_file_outside_the_inbox_is_refused() {
        let ctx = ChatContext::File { name: "win.ini".into(), path: r"C:\Windows\win.ini".into() };
        assert!(build_plan(Engine::Claude, "", "q", Some(&ctx), None, &[]).is_err());
    }
}
