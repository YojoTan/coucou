// Worktrees from Mochi (macOS PR #6) — manage a repo's git worktrees from the
// island, its pill or the desktop pet. The protocol is docs/WORKTREES.md, the
// same on both systems so one provider serves both builds:
//
//   <provider> describe | list | run <action-id> <arguments-json>
//
// run in the repo's root through cmd.exe (a `bash …` provider needs Git Bash or
// WSL on PATH), with COUCOU=1 and the arguments JSON also in COUCOU_ARGS.
// Coucou draws the forms and streams the progress; the provider does the work.
//
// • Without a provider: the list (`git worktree list`, minus the main
//   checkout) and a terminal in each — never a removal: `git worktree remove
//   --force` deletes submodule clones with whatever commits they hold.
// • Whatever the provider, Coucou reads each worktree's state with git itself:
//   changed files and commits on no remote, submodules included.
// • Polls every 30 s only while the Worktrees pill is on, or the view or the
//   pet's menu is open; `describe` is cached 10 minutes.
//
// Repos and provider commands are saved by the settings window only: a
// provider is a command, and the island must never be able to plant one.

use std::collections::{BTreeMap, HashMap};
use std::io::{BufRead, BufReader, Read};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};
use serde_json::Value;
use tauri::{AppHandle, Emitter, Manager};

pub const TASK_ID: &str = "integration_worktrees";
const CREATE_NO_WINDOW: u32 = 0x0800_0000;
const CREATE_NEW_CONSOLE: u32 = 0x0000_0010;
const CALL_TIMEOUT: Duration = Duration::from_secs(20);
const DESCRIBE_EVERY: Duration = Duration::from_secs(600);
const MAX_OUTPUT: u64 = 2 * 1024 * 1024;

// ── Model (WorktreeParse.swift) ───────────────────────────────────────────────

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct Repo {
    pub id: String,
    pub name: String,
    pub path: String,
    /// Empty: plain git.
    #[serde(default)]
    pub provider: String,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct WtOption {
    pub value: String,
    pub label: String,
}

#[derive(Serialize, Deserialize, Clone, Copy, Debug, PartialEq)]
#[serde(rename_all = "lowercase")]
pub enum Kind {
    Text,
    Choice,
    Multi,
    Bool,
}

/// A field's value: text, a list (multi) or a flag.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(untagged)]
pub enum WtValue {
    Flag(bool),
    Text(String),
    List(Vec<String>),
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct Field {
    pub id: String,
    #[serde(rename = "type")]
    pub kind: Kind,
    pub label: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub required: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub placeholder: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pattern: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub options: Option<Vec<WtOption>>,
    #[serde(default, rename = "default", skip_serializing_if = "Option::is_none")]
    pub default_value: Option<WtValue>,
}

#[derive(Serialize, Deserialize, Clone, Copy, Debug, PartialEq)]
#[serde(rename_all = "lowercase")]
pub enum Scope {
    Repo,
    Worktree,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct Action {
    pub id: String,
    pub label: String,
    pub scope: Scope,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub danger: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fields: Option<Vec<Field>>,
}

fn version_one() -> i64 {
    1
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Default)]
pub struct Description {
    #[serde(default = "version_one")]
    pub version: i64,
    #[serde(default)]
    pub actions: Vec<Action>,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct Worktree {
    pub slug: String,
    pub path: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub branch: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub note: Option<String>,
}

#[derive(Deserialize)]
struct List {
    #[serde(default)]
    worktrees: Vec<Worktree>,
}

/// One line of a `run`.
#[derive(Serialize, Clone, Debug, PartialEq)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum Event {
    Progress { text: String },
    Terminal { command: String, cwd: Option<String>, title: Option<String> },
    #[serde(rename_all = "camelCase")]
    Done { ok: bool, text: String, risk: Vec<String>, can_force: bool },
}

/// Git's view of a worktree, for every provider.
#[derive(Serialize, Clone, Debug, PartialEq, Default)]
#[serde(rename_all = "camelCase")]
pub struct Status {
    /// Changed files, the worktree and its submodules.
    pub dirty: u32,
    /// Commits not on any remote.
    pub unpushed: u32,
    /// Seconds since 1970 of the last commit.
    pub last_commit: Option<i64>,
}

pub fn describe(json: &str) -> Option<Description> {
    serde_json::from_str(json.trim()).ok()
}

pub fn list(json: &str) -> Option<Vec<Worktree>> {
    serde_json::from_str::<List>(json.trim()).ok().map(|l| l.worktrees)
}

/// One output line of a `run`: a JSON event, or plain text shown as progress.
pub fn event(line: &str) -> Option<Event> {
    let t = line.trim();
    if t.is_empty() {
        return None;
    }
    let progress = || Some(Event::Progress { text: t.to_string() });
    let Some(o) = t.starts_with('{').then(|| serde_json::from_str::<Value>(t).ok()).flatten().filter(Value::is_object) else {
        return progress();
    };
    let s = |k: &str| o.get(k).and_then(Value::as_str).map(str::to_string);
    match o.get("type").and_then(Value::as_str) {
        Some("progress") => Some(Event::Progress { text: s("text").unwrap_or_default() }),
        Some("terminal") => {
            let command = s("command").filter(|c| !c.is_empty())?;
            Some(Event::Terminal { command, cwd: s("cwd"), title: s("title") })
        }
        Some("done") => Some(Event::Done {
            ok: o.get("ok").and_then(Value::as_bool).unwrap_or(false),
            text: s("text").unwrap_or_default(),
            risk: o.get("risk").and_then(Value::as_array).map(|a| a.iter().filter_map(Value::as_str).map(str::to_string).collect()).unwrap_or_default(),
            can_force: o.get("canForce").and_then(Value::as_bool).unwrap_or(false),
        }),
        None => progress(),
        Some(_) => progress(),
    }
}

/// `git worktree list --porcelain` → worktrees, without the main checkout.
pub fn git_worktrees(porcelain: &str) -> Vec<Worktree> {
    let mut out = Vec::new();
    let (mut path, mut branch, mut first): (Option<String>, Option<String>, bool) = (None, None, true);
    let mut flush = |path: &mut Option<String>, branch: &mut Option<String>, first: &mut bool| {
        if let Some(p) = path.take() {
            if !*first {
                let slug = p.trim_end_matches(['/', '\\']).rsplit(['/', '\\']).next().unwrap_or(&p).to_string();
                out.push(Worktree { slug, path: p.clone(), branch: branch.take(), note: None });
            }
            *first = false;
        }
        *branch = None;
    };
    for line in porcelain.split('\n') {
        let line = line.strip_suffix('\r').unwrap_or(line);
        if let Some(p) = line.strip_prefix("worktree ") {
            flush(&mut path, &mut branch, &mut first);
            path = Some(p.to_string());
        } else if let Some(b) = line.strip_prefix("branch ") {
            branch = Some(b.replace("refs/heads/", ""));
        }
    }
    flush(&mut path, &mut branch, &mut first);
    out
}

/// The arguments JSON a `run` gets: the form's values, the worktree, a force confirmation.
pub fn arguments(values: &BTreeMap<String, WtValue>, worktree: Option<&Worktree>, force: bool, confirm: Option<&str>) -> String {
    let mut o: BTreeMap<String, Value> = values.iter().map(|(k, v)| (k.clone(), serde_json::to_value(v).unwrap_or(Value::Null))).collect();
    if let Some(w) = worktree {
        let mut wt = BTreeMap::new();
        wt.insert("branch", Value::from(w.branch.clone().unwrap_or_default()));
        wt.insert("path", Value::from(w.path.clone()));
        wt.insert("slug", Value::from(w.slug.clone()));
        o.insert("worktree".into(), serde_json::to_value(wt).unwrap_or(Value::Null));
    }
    if force {
        o.insert("force".into(), Value::Bool(true));
    }
    if let Some(c) = confirm {
        o.insert("confirm".into(), Value::from(c));
    }
    serde_json::to_string(&o).unwrap_or_else(|_| "{}".into())
}

/// Only the form's own fields, with values of their own type.
fn clean_values(action: &Action, values: &serde_json::Map<String, Value>) -> BTreeMap<String, WtValue> {
    let mut out = BTreeMap::new();
    for f in action.fields.iter().flatten() {
        let Some(v) = values.get(&f.id) else { continue };
        let value = match (f.kind, v) {
            (Kind::Text | Kind::Choice, Value::String(s)) => WtValue::Text(s.chars().take(2000).collect()),
            (Kind::Multi, Value::Array(a)) => WtValue::List(a.iter().filter_map(Value::as_str).map(str::to_string).take(100).collect()),
            (Kind::Bool, Value::Bool(b)) => WtValue::Flag(*b),
            _ => continue,
        };
        out.insert(f.id.clone(), value);
    }
    out
}

/// Settings may keep: absolute git repos, a name, a provider of sane length.
pub fn sanitize_repos(list: Vec<Repo>) -> Vec<Repo> {
    let mut seen = std::collections::HashSet::new();
    list.into_iter()
        .filter(|r| !r.id.is_empty() && r.id.len() <= 64 && r.id.chars().all(|c| c.is_ascii_alphanumeric() || c == '-') && seen.insert(r.id.clone()))
        .filter(|r| Path::new(&r.path).is_absolute())
        .take(20)
        .map(|mut r| {
            r.name = r.name.trim().chars().take(60).collect();
            if r.name.is_empty() {
                r.name = Path::new(&r.path).file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_else(|| "repo".into());
            }
            r.provider = r.provider.trim().chars().take(1000).collect();
            r
        })
        .collect()
}

// ── Processes ─────────────────────────────────────────────────────────────────

/// A command-line argument as the C runtime (and MSYS's bash) reads it back.
fn quote_arg(s: &str) -> String {
    let mut out = String::from("\"");
    let mut backslashes = 0;
    for c in s.chars() {
        match c {
            '\\' => backslashes += 1,
            '"' => {
                out.push_str(&"\\".repeat(backslashes * 2 + 1));
                out.push('"');
                backslashes = 0;
            }
            _ => {
                out.push_str(&"\\".repeat(backslashes));
                out.push(c);
                backslashes = 0;
            }
        }
    }
    out.push_str(&"\\".repeat(backslashes * 2));
    out.push('"');
    out
}

/// `<provider> <verb>` in cmd.exe, in the repo. The run's JSON reaches the
/// provider through delayed expansion (`!COUCOU_ARGV!`, quoted for the C
/// runtime): cmd substitutes it after reading the line, so none of its
/// characters are cmd syntax.
fn provider_command(repo: &Repo, verb: &str, args_json: Option<&str>) -> std::process::Command {
    use std::os::windows::process::CommandExt;
    let cmd = std::env::var_os("ComSpec").unwrap_or_else(|| "cmd.exe".into());
    let mut c = std::process::Command::new(cmd);
    let tail = if args_json.is_some() { format!("{verb} !COUCOU_ARGV!") } else { verb.to_string() };
    c.raw_arg(format!("/D /V:ON /S /C \"{} {tail}\"", repo.provider))
        .current_dir(&repo.path)
        .env("COUCOU", "1")
        .stdin(std::process::Stdio::null())
        .creation_flags(CREATE_NO_WINDOW);
    if let Some(json) = args_json {
        c.env("COUCOU_ARGS", json).env("COUCOU_ARGV", quote_arg(json));
    }
    c
}

/// A short call (describe, list): stdout, None on failure or after 20 s.
fn call(repo: &Repo, verb: &str) -> Result<String, String> {
    use std::process::Stdio;
    let mut child = provider_command(repo, verb, None)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| e.to_string())?;
    let job = crate::cli_chat::Job::new();
    if let Some(j) = &job {
        j.adopt(&child);
    }
    let read = |p: Option<Box<dyn Read + Send>>| {
        std::thread::spawn(move || {
            let mut kept = Vec::new();
            if let Some(mut p) = p {
                let _ = p.by_ref().take(MAX_OUTPUT).read_to_end(&mut kept);
                let _ = std::io::copy(&mut p, &mut std::io::sink());
            }
            kept
        })
    };
    let out = read(child.stdout.take().map(|p| Box::new(p) as Box<dyn Read + Send>));
    let err = read(child.stderr.take().map(|p| Box::new(p) as Box<dyn Read + Send>));
    let started = Instant::now();
    let status = loop {
        match child.try_wait() {
            Ok(Some(s)) => break s,
            Ok(None) if started.elapsed() < CALL_TIMEOUT => std::thread::sleep(Duration::from_millis(50)),
            _ => {
                drop(job);
                let _ = child.kill();
                let _ = child.wait();
                return Err(format!("`{verb}` took more than 20 s."));
            }
        }
    };
    drop(job);
    let (out, err) = (out.join().unwrap_or_default(), err.join().unwrap_or_default());
    if status.success() {
        return Ok(String::from_utf8_lossy(&out).to_string());
    }
    let err = String::from_utf8_lossy(&err);
    // cmd's own words when the provider's program isn't there.
    if err.contains("is not recognized") || err.contains("no se reconoce") || err.contains("não é reconhecido") {
        return Err("The provider's program wasn't found — a bash provider needs Git Bash or WSL on PATH.".into());
    }
    Err(err.lines().find(|l| !l.trim().is_empty()).map(|l| l.chars().take(200).collect()).unwrap_or_else(|| format!("`{verb}` failed.")))
}

fn git(path: &str, args: &[&str]) -> Option<String> {
    use std::os::windows::process::CommandExt;
    let exe = crate::find_on_path("git")?;
    let out = std::process::Command::new(exe)
        .arg("-C")
        .arg(path)
        .args(args)
        .stdin(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .creation_flags(CREATE_NO_WINDOW)
        .output()
        .ok()?;
    out.status.success().then(|| String::from_utf8_lossy(&out.stdout).to_string())
}

fn count_lines(s: Option<String>) -> u32 {
    s.map_or(0, |s| s.lines().filter(|l| !l.trim().is_empty()).count() as u32)
}

fn unpushed(path: &str) -> u32 {
    git(path, &["rev-list", "--count", "HEAD", "--not", "--remotes"]).and_then(|s| s.trim().parse().ok()).unwrap_or(0)
}

/// Changed files and commits on no remote, the worktree and its submodules; the last commit.
pub fn status(path: &str) -> Status {
    let mut st = Status {
        dirty: count_lines(git(path, &["status", "--porcelain"])),
        unpushed: unpushed(path),
        last_commit: git(path, &["log", "-1", "--format=%ct"]).and_then(|s| s.trim().parse().ok()).filter(|t: &i64| *t > 0),
    };
    let modules = Path::new(path).join(".gitmodules");
    if modules.is_file() {
        let listed = git(path, &["config", "--file", ".gitmodules", "--get-regexp", r"^submodule\..*\.path$"]).unwrap_or_default();
        for sub in listed.lines().filter_map(|l| l.split_once(' ').map(|(_, p)| p.trim())) {
            let dir = Path::new(path).join(sub);
            if dir.join(".git").exists() {
                let d = dir.to_string_lossy().to_string();
                st.dirty += count_lines(git(&d, &["status", "--porcelain"]));
                st.unpushed += unpushed(&d);
            }
        }
    }
    st
}

// ── Terminals ─────────────────────────────────────────────────────────────────

/// In Orca when it runs (a tab in that worktree), else a console window —
/// which Windows 11 opens in the default terminal (Windows Terminal).
pub fn open_terminal(command: Option<&str>, cwd: Option<&str>, worktree: Option<&str>) {
    use std::os::windows::process::CommandExt;
    let command = command.filter(|c| !c.trim().is_empty());
    let dir = cwd.or(worktree);
    if let (Some(wt), true) = (worktree, crate::jump::process_names().contains("orca.exe")) {
        if let Some(orca) = crate::orca::cli_exe() {
            let mut c = std::process::Command::new(orca);
            c.args(["terminal", "create", "--worktree", &format!("path:{wt}"), "--focus", "--json"]);
            match (command, cwd.filter(|d| !same_path(d, wt))) {
                (Some(cmd), Some(d)) => {
                    c.args(["--shell", "cmd.exe", "--command", &format!("cd /d \"{d}\" && {cmd}")]);
                }
                (Some(cmd), None) => {
                    c.args(["--command", cmd]);
                }
                _ => {}
            }
            let ok = c
                .stdin(std::process::Stdio::null())
                .stdout(std::process::Stdio::null())
                .stderr(std::process::Stdio::null())
                .creation_flags(CREATE_NO_WINDOW)
                .status()
                .is_ok_and(|s| s.success());
            if ok {
                crate::orca::open_app();
                return;
            }
        }
    }
    let shell = std::env::var_os("ComSpec").unwrap_or_else(|| "cmd.exe".into());
    let mut c = std::process::Command::new(shell);
    if let Some(cmd) = command {
        c.raw_arg(format!("/K {cmd}"));
    }
    if let Some(d) = dir.filter(|d| Path::new(d).is_dir()) {
        c.current_dir(d);
    }
    let _ = c.creation_flags(CREATE_NEW_CONSOLE).spawn();
}

fn same_path(a: &str, b: &str) -> bool {
    let n = |s: &str| s.replace('/', "\\").trim_end_matches('\\').to_lowercase();
    n(a) == n(b)
}

// ── State and polling ─────────────────────────────────────────────────────────

#[derive(Serialize, Clone, Debug, Default)]
#[serde(rename_all = "camelCase")]
pub struct RepoState {
    pub id: String,
    pub name: String,
    pub path: String,
    pub has_provider: bool,
    pub description: Description,
    pub worktrees: Vec<Worktree>,
    /// By worktree path.
    pub status: HashMap<String, Status>,
    pub error: Option<String>,
    #[serde(skip)]
    described: Option<Instant>,
    #[serde(skip)]
    provider: String,
}

static STATE: Mutex<Vec<RepoState>> = Mutex::new(Vec::new());
static WATCHED: AtomicBool = AtomicBool::new(false);
/// One refresh at a time; a forced one after a run waits its turn.
static REFRESH: Mutex<()> = Mutex::new(());

fn repos(app: &AppHandle) -> Vec<Repo> {
    app.try_state::<crate::Shared>().map(|s| s.settings.lock().unwrap().worktree_repos.clone()).unwrap_or_default()
}

/// Without a provider, the one thing Coucou does: a terminal in the worktree.
fn plain_git() -> Description {
    Description { version: 1, actions: vec![Action { id: "session".into(), label: "Open a terminal".into(), scope: Scope::Worktree, danger: None, fields: None }] }
}

fn refresh_repo(repo: &Repo, old: Option<RepoState>, force: bool) -> RepoState {
    let mut st = old.filter(|o| o.path == repo.path && o.provider == repo.provider).unwrap_or_default();
    st.id = repo.id.clone();
    st.name = repo.name.clone();
    st.path = repo.path.clone();
    st.provider = repo.provider.clone();
    st.has_provider = !repo.provider.is_empty();
    if !Path::new(&repo.path).join(".git").exists() {
        st.error = Some("That folder isn't a git repository any more.".into());
        st.worktrees.clear();
        return st;
    }
    let mut error = None;
    if force || st.described.is_none_or(|t| t.elapsed() >= DESCRIBE_EVERY) {
        if repo.provider.is_empty() {
            st.description = plain_git();
        } else {
            match call(repo, "describe") {
                Ok(out) => match describe(&out) {
                    Some(d) => st.description = d,
                    None => error = Some("The provider didn't describe itself (docs/WORKTREES.md).".to_string()),
                },
                Err(e) => error = Some(e),
            }
        }
        st.described = Some(Instant::now());
    }
    let listed = if repo.provider.is_empty() {
        git(&repo.path, &["worktree", "list", "--porcelain"]).map(|p| git_worktrees(&p)).ok_or_else(|| "git isn't on PATH.".to_string())
    } else {
        call(repo, "list").and_then(|out| list(&out).ok_or_else(|| "The provider's list isn't the expected JSON (docs/WORKTREES.md).".to_string()))
    };
    match listed {
        Ok(worktrees) => {
            st.status = worktrees.iter().map(|w| (w.path.clone(), status(&w.path))).collect();
            st.worktrees = worktrees;
            st.error = error;
        }
        Err(e) => st.error = Some(error.unwrap_or(e)),
    }
    st
}

/// Re-reads every repo (one refresh at a time) and tells the island.
pub fn refresh(app: &AppHandle, force: bool) {
    let _turn = REFRESH.lock().unwrap_or_else(|e| e.into_inner());
    let list = repos(app);
    let old: Vec<RepoState> = STATE.lock().unwrap().clone();
    let fresh: Vec<RepoState> = list.iter().map(|r| refresh_repo(r, old.iter().find(|o| o.id == r.id).cloned(), force)).collect();
    *STATE.lock().unwrap() = fresh.clone();
    let _ = app.emit("worktrees-state", fresh);
}

pub fn snapshot() -> Vec<RepoState> {
    STATE.lock().unwrap().clone()
}

/// The view or the pet's menu opened (or closed): poll while it shows.
pub fn watch(app: &AppHandle, open: bool) {
    WATCHED.store(open, Ordering::Relaxed);
    if open {
        let app = app.clone();
        std::thread::spawn(move || refresh(&app, false));
    }
}

pub fn start(app: AppHandle) {
    std::thread::spawn(move || {
        std::thread::sleep(Duration::from_secs(3));
        let mut last = Instant::now() - Duration::from_secs(60);
        loop {
            let wanted = WATCHED.load(Ordering::Relaxed) || crate::integrations::is_enabled(&app, TASK_ID);
            if wanted && last.elapsed() >= Duration::from_secs(30) && !repos(&app).is_empty() {
                last = Instant::now();
                refresh(&app, false);
            }
            std::thread::sleep(Duration::from_secs(2));
        }
    });
}

// ── Running an action ─────────────────────────────────────────────────────────

static RUN_ID: AtomicU64 = AtomicU64::new(0);
static CANCEL: AtomicU64 = AtomicU64::new(0);

#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
struct RunEvent {
    run: u64,
    event: Option<Event>,
    /// Set when the provider exited.
    exit_code: Option<i32>,
}

/// Runs an action the last refresh read, on a worktree it listed. Returns the
/// run's number; its events arrive as `worktrees-run`.
pub fn run(app: &AppHandle, repo_id: &str, action_id: &str, worktree_path: Option<&str>, values: &serde_json::Map<String, Value>, force: bool, confirm: Option<&str>) -> Result<u64, String> {
    let repo = repos(app).into_iter().find(|r| r.id == repo_id).ok_or("That repo is gone.")?;
    let st = snapshot().into_iter().find(|s| s.id == repo_id).ok_or("Refresh the worktrees first.")?;
    let action = st.description.actions.iter().find(|a| a.id == action_id).cloned().ok_or("The provider has no such action.")?;
    let worktree = match (action.scope, worktree_path) {
        (Scope::Worktree, Some(p)) => Some(st.worktrees.iter().find(|w| w.path == p).cloned().ok_or("That worktree is gone.")?),
        (Scope::Worktree, None) => return Err("Pick a worktree.".into()),
        (Scope::Repo, _) => None,
    };
    let run_id = RUN_ID.fetch_add(1, Ordering::SeqCst) + 1;
    let emit = {
        let app = app.clone();
        move |event: Option<Event>, exit_code: Option<i32>| {
            let _ = app.emit("worktrees-run", RunEvent { run: run_id, event, exit_code });
        }
    };
    if repo.provider.is_empty() {
        // Plain git: the one action is a terminal in the worktree.
        if let Some(w) = &worktree {
            open_terminal(None, Some(&w.path), Some(&w.path));
        }
        emit(Some(Event::Done { ok: true, text: "Terminal opened.".into(), risk: vec![], can_force: false }), Some(0));
        return Ok(run_id);
    }
    if !action.id.chars().all(|c| c.is_ascii_alphanumeric() || "._-".contains(c)) || action.id.is_empty() || action.id.len() > 64 {
        return Err("The provider's action id isn't a plain word.".into());
    }
    let args = arguments(&clean_values(&action, values), worktree.as_ref(), force, confirm);
    let mut child = provider_command(&repo, &format!("run {}", action.id), Some(&args))
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .spawn()
        .map_err(|e| e.to_string())?;
    let worktree_path = worktree.map(|w| w.path);
    let app = app.clone();
    std::thread::spawn(move || {
        let job = crate::cli_chat::Job::new();
        if let Some(j) = &job {
            j.adopt(&child);
        }
        let lines = |p: Option<Box<dyn Read + Send>>, emit: Box<dyn Fn(Event) + Send>| {
            std::thread::spawn(move || {
                let Some(p) = p else { return };
                for line in BufReader::new(p).lines().map_while(Result::ok) {
                    if let Some(e) = event(&line) {
                        emit(e);
                    }
                }
            })
        };
        let wt = worktree_path.clone();
        let on_event = {
            let emit = emit.clone();
            move |e: Event| {
                if let Event::Terminal { command, cwd, .. } = &e {
                    open_terminal(Some(command), cwd.as_deref(), wt.as_deref().or(cwd.as_deref()));
                }
                emit(Some(e), None);
            }
        };
        let on_err = {
            let emit = emit.clone();
            move |e: Event| emit(Some(e), None)
        };
        let out = lines(child.stdout.take().map(|p| Box::new(p) as Box<dyn Read + Send>), Box::new(on_event));
        let err = lines(child.stderr.take().map(|p| Box::new(p) as Box<dyn Read + Send>), Box::new(on_err));
        let code = loop {
            if CANCEL.load(Ordering::SeqCst) == run_id {
                drop(job);
                let _ = child.kill();
                let _ = child.wait();
                return;
            }
            match child.try_wait() {
                Ok(Some(s)) => break s.code().unwrap_or(1),
                Ok(None) => std::thread::sleep(Duration::from_millis(100)),
                Err(_) => break 1,
            }
        };
        let _ = out.join();
        let _ = err.join();
        drop(job);
        emit(None, Some(code));
        refresh(&app, true);
    });
    Ok(run_id)
}

/// Stop: the provider and everything it started.
pub fn cancel() {
    CANCEL.store(RUN_ID.load(Ordering::SeqCst), Ordering::SeqCst);
}

/// "Show in Explorer" for a worktree the last refresh listed.
pub fn reveal(repo_id: &str, path: &str) -> bool {
    use std::os::windows::process::CommandExt;
    let known = snapshot().iter().any(|s| s.id == repo_id && s.worktrees.iter().any(|w| w.path == path));
    if !known || !Path::new(path).is_dir() {
        return false;
    }
    std::process::Command::new("explorer.exe").arg(PathBuf::from(path.replace('/', "\\"))).creation_flags(CREATE_NO_WINDOW).spawn().is_ok()
}

/// A worktree the last refresh listed (VS Code, a terminal).
pub fn known_path(repo_id: &str, path: &str) -> bool {
    snapshot().iter().any(|s| s.id == repo_id && s.worktrees.iter().any(|w| w.path == path))
}

/// Settings › Add a repo: the folder picker; a git repo, or why not.
pub fn pick_repo(owner: Option<isize>) -> Result<Option<(String, String)>, String> {
    let path = std::thread::spawn(move || unsafe {
        use windows::Win32::Foundation::HWND;
        use windows::Win32::System::Com::{CoCreateInstance, CoInitializeEx, CoTaskMemFree, CoUninitialize, CLSCTX_INPROC_SERVER, COINIT_APARTMENTTHREADED};
        use windows::Win32::UI::Shell::{FileOpenDialog, IFileOpenDialog, FOS_FORCEFILESYSTEM, FOS_PICKFOLDERS, SIGDN_FILESYSPATH};
        let com = CoInitializeEx(None, COINIT_APARTMENTTHREADED).is_ok();
        let picked = (|| -> windows::core::Result<PathBuf> {
            let dialog: IFileOpenDialog = CoCreateInstance(&FileOpenDialog, None, CLSCTX_INPROC_SERVER)?;
            dialog.SetOptions(dialog.GetOptions()? | FOS_PICKFOLDERS | FOS_FORCEFILESYSTEM)?;
            dialog.Show(owner.map(|h| HWND(h as *mut _)))?;
            let name = dialog.GetResult()?.GetDisplayName(SIGDN_FILESYSPATH)?;
            let path = name.to_string().map(PathBuf::from);
            CoTaskMemFree(Some(name.0 as *const _));
            path.map_err(|_| windows::core::Error::from_win32())
        })();
        if com {
            CoUninitialize();
        }
        picked.ok()
    })
    .join()
    .ok()
    .flatten();
    let Some(path) = path else { return Ok(None) };
    if !path.join(".git").exists() {
        return Err("That folder isn't a git repository.".into());
    }
    let name = path.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_else(|| "repo".into());
    Ok(Some((path.to_string_lossy().to_string(), name)))
}

#[cfg(test)]
mod tests {
    use super::*;

    // tests/WorktreeParseTests.swift, line for line.
    #[test]
    fn the_protocol_parses_like_the_macs() {
        let d = describe(r#"{"version":1,"actions":[{"id":"create","label":"New","scope":"repo","fields":[
          {"id":"name","type":"text","label":"Name","required":true,"pattern":"^[a-z-]+$"},
          {"id":"parts","type":"multi","label":"Parts","options":[{"value":"a","label":"A"}]},
          {"id":"open","type":"bool","label":"Open","default":true}]},
          {"id":"rm","label":"Remove","scope":"worktree","danger":true}]}"#).unwrap();
        assert_eq!(d.actions.len(), 2);
        assert_eq!(d.actions[1].danger, Some(true));
        assert_eq!(d.actions[0].fields.as_ref().unwrap()[2].default_value, Some(WtValue::Flag(true)), "bool default");
        assert!(describe(r#"{"actions":[{"id":"x","label":"X","scope":"repo","fields":[{"id":"f","type":"date","label":"F"}]}]}"#).is_none(), "an unknown field type");

        assert_eq!(event(r#"{"type":"progress","text":"hi"}"#), Some(Event::Progress { text: "hi".into() }));
        assert_eq!(event("plain output"), Some(Event::Progress { text: "plain output".into() }));
        assert_eq!(event("   "), None);
        assert_eq!(event(r#"{"type":"terminal","command":"claude","cwd":"/x"}"#), Some(Event::Terminal { command: "claude".into(), cwd: Some("/x".into()), title: None }));
        assert_eq!(event(r#"{"type":"done","ok":false,"text":"no","risk":["a"],"canForce":true}"#),
                   Some(Event::Done { ok: false, text: "no".into(), risk: vec!["a".into()], can_force: true }));

        let porcelain = "worktree /r\nHEAD 1\nbranch refs/heads/main\n\nworktree /r-x\nHEAD 2\nbranch refs/heads/x\n\nworktree /r-y\nHEAD 3\ndetached\n";
        let wts = git_worktrees(porcelain);
        assert_eq!(wts.iter().map(|w| w.slug.as_str()).collect::<Vec<_>>(), ["r-x", "r-y"]);
        assert_eq!(wts[0].branch.as_deref(), Some("x"));
        assert_eq!(wts[1].branch, None);
        let windows = git_worktrees("worktree C:/src/app\r\nbranch refs/heads/main\r\n\r\nworktree C:/src/app-fix\r\nbranch refs/heads/fix\r\n");
        assert_eq!(windows[0].slug, "app-fix");

        let mut values = BTreeMap::new();
        values.insert("name".to_string(), WtValue::Text("x".into()));
        let a: Value = serde_json::from_str(&arguments(&values, Some(&wts[0]), true, Some("r-x"))).unwrap();
        assert_eq!(a["name"], "x");
        assert_eq!(a["force"], true);
        assert_eq!(a["confirm"], "r-x");
        assert_eq!(a["worktree"]["path"], "/r-x");
    }

    #[test]
    fn only_the_forms_fields_go_to_the_provider() {
        let d = describe(r#"{"actions":[{"id":"create","label":"New","scope":"repo","fields":[
          {"id":"name","type":"text","label":"Name"},{"id":"open","type":"bool","label":"Open"},{"id":"parts","type":"multi","label":"P"}]}]}"#).unwrap();
        let values: serde_json::Map<String, Value> = serde_json::from_str(r#"{"name":"x","open":"yes","parts":["a",1],"extra":"no"}"#).unwrap();
        let clean = clean_values(&d.actions[0], &values);
        assert_eq!(clean.get("name"), Some(&WtValue::Text("x".into())));
        assert!(!clean.contains_key("open"), "a bool field gets a bool");
        assert_eq!(clean.get("parts"), Some(&WtValue::List(vec!["a".into()])));
        assert!(!clean.contains_key("extra"));
    }

    #[test]
    fn json_reaches_the_provider_intact_through_cmd() {
        let dir = std::env::temp_dir().join(format!("coucou-wt-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        // A batch provider reads COUCOU_ARGS (its %3 would re-split on cmd's own quote rules).
        std::fs::write(dir.join("echo.cmd"), "@echo off\r\necho ENV=!COUCOU_ARGS!\r\n").unwrap();
        let repo = |provider: &str| Repo { id: "r".into(), name: "r".into(), path: dir.to_string_lossy().to_string(), provider: provider.into() };
        let json = r#"{"name":"a & b | c > d","quote":"say \"hi\"","pct":"100%","path":"C:\\x\\"}"#;
        // A provider in the repo is written `.\…`: cmd may not search the current folder.
        let out = provider_command(&repo(r".\echo.cmd"), "run create", Some(json)).output().unwrap();
        let text = String::from_utf8_lossy(&out.stdout);
        assert!(text.contains(&format!("ENV={json}")), "COUCOU_ARGS is untouched: {text}");
        assert!(!dir.join("d").exists(), "no redirection happened");
        // A program reading its argv the C runtime's way gets the JSON back whole.
        if crate::find_on_path("node").is_some() {
            let out = provider_command(&repo("node -e \"console.log(process.argv[3])\""), "run create", Some(json)).output().unwrap();
            assert_eq!(String::from_utf8_lossy(&out.stdout).trim(), json, "argv 3 is the JSON");
        }
        let _ = std::fs::remove_dir_all(&dir);
        assert_eq!(quote_arg(r#"a\"b\"#), r#""a\\\"b\\""#);
    }

    #[test]
    fn saved_repos_are_absolute_and_named() {
        let r = |id: &str, path: &str, name: &str| Repo { id: id.into(), name: name.into(), path: path.into(), provider: "  bash p.sh  ".into() };
        let kept = sanitize_repos(vec![r("a1", r"C:\src\app", " "), r("a1", r"C:\src\dup", "x"), r("b2", "relative", "x"), r("c 3", r"C:\x", "x")]);
        assert_eq!(kept.len(), 1);
        assert_eq!(kept[0].name, "app");
        assert_eq!(kept[0].provider, "bash p.sh");
    }
}
