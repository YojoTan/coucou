// Coucou for Windows — app wiring and the commands the island calls.

mod capture;
mod claude;
mod clipboard;
mod discord;
mod extras;
mod cli_chat;
mod files;
mod github;
mod hooks;
mod hotkey;
mod integrations;
mod island;
mod jump;
mod lan;
mod log;
mod media;
mod mic;
mod openai_chat;
mod opencode;
mod orca;
mod pipe;
mod secrets;
mod settings;
mod transcript;
mod tuning;
mod tray;
mod win_user;

use std::os::windows::process::CommandExt;
use std::process::Command;
use std::sync::atomic::Ordering;
use std::sync::{Arc, Mutex};

use serde::Serialize;
use tauri::{
    AppHandle, DragDropEvent, Emitter, Manager, State, Webview, WebviewEvent, WebviewUrl,
    WebviewWindowBuilder, WindowEvent,
};
use tauri_plugin_autostart::{ManagerExt, MacosLauncher};

use claude::{Chat, ChatContext, ChatReply};
use cli_chat::{CliChat, Engine, EngineInfo};
use openai_chat::OpenAiChat;
use files::DroppedFile;
use hooks::{HookPreview, HookStatus};
use island::{PollGate, ScreenInfo};
use pipe::Pending;
use settings::Settings;

/// Keeps spawned helpers from flashing a console window.
const CREATE_NO_WINDOW: u32 = 0x0800_0000;

/// The settings window's label. Only it may touch secrets or settings.json.
const SETTINGS_LABEL: &str = "settings";

pub struct Shared {
    pub settings: Mutex<Settings>,
    pub gate: Arc<PollGate>,
}

/// Paths the OS actually dropped on the island. `ingest_file` copies only these,
/// so the webview can never name an arbitrary file on disk and have it read.
#[derive(Default)]
pub struct Dropped(Mutex<Vec<std::path::PathBuf>>);

/// Each command runs only for the window that needs it. The island renders text
/// that comes from outside — hook payloads, API responses — so it gets no way
/// to change keys or write ~/.claude/settings.json; the settings window shows
/// no outside content, so it gets no way to answer a permission request.
fn only(webview: &Webview, label: &str, command: &str) -> Result<(), String> {
    if webview.label() == label {
        return Ok(());
    }
    log::line(format!("refused {command} from window {:?}", webview.label()));
    Err(format!("{command} is not available here"))
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BootInfo {
    settings: Settings,
    screen: ScreenInfo,
    version: String,
    hook_path: String,
}

#[tauri::command]
fn boot(app: AppHandle, shared: State<Shared>) -> BootInfo {
    let mut settings = shared.settings.lock().unwrap().clone();
    // The real state of ~/.claude/settings.json wins over whatever we stored.
    settings.hooks_installed = hooks::status(hooks::Target::Claude).installed;
    let screen = island::screen_info(&app, &settings.screen);
    BootInfo {
        settings,
        screen,
        version: env!("CARGO_PKG_VERSION").to_string(),
        hook_path: settings::hook_exe_path().to_string_lossy().to_string(),
    }
}

#[tauri::command]
fn save_settings(app: AppHandle, webview: Webview, shared: State<Shared>, mut settings: Settings) {
    let (screen_changed, autostart_changed, engine_changed, hotkey_changed, lan_changed, local_url_changed) = {
        let mut current = shared.settings.lock().unwrap();
        // The island saves its own preferences (sound, volume, auto-close), but
        // where the chat sends a conversation is the settings window's call
        // alone: the island renders outside text and must not be able to point
        // the chat — and its key — at another server.
        if webview.label() != SETTINGS_LABEL {
            settings.chat_engine = current.chat_engine.clone();
            settings.cli_model = current.cli_model.clone();
            settings.model = current.model.clone();
            settings.openai_base_url = current.openai_base_url.clone();
            settings.openai_model = current.openai_model.clone();
            settings.anthropic_base_url = current.anthropic_base_url.clone();
            settings.anthropic_model = current.anthropic_model.clone();
            // Whether this PC talks to the network, and lets others ask its
            // Mochi, is the settings window's call alone.
            settings.lan = current.lan.clone();
            settings.hooks_installed = current.hooks_installed;
            // A custom Mochi carries a command, the local URL listens, the
            // weather sends a city out, the voice speaks: Settings' calls too.
            settings.custom_mochis = current.custom_mochis.clone();
            settings.local_url = current.local_url;
            settings.weather_place = current.weather_place.clone();
            settings.voice = current.voice;
            // The island keeps the pet's count; Settings only picks what it wears.
            settings.pet.wearing = current.pet.wearing.clone();
        } else {
            settings.pet = extras::Pet { wearing: settings.pet.wearing.clone(), ..current.pet.clone() };
        }
        settings.custom_mochis = extras::sanitize_customs(std::mem::take(&mut settings.custom_mochis));
        let screen_changed = current.screen != settings.screen;
        let autostart_changed = current.autostart != settings.autostart;
        let engine_changed = current.chat_engine != settings.chat_engine
            || current.cli_model != settings.cli_model
            || current.model != settings.model
            || current.openai_base_url != settings.openai_base_url
            || current.openai_model != settings.openai_model
            || current.anthropic_base_url != settings.anthropic_base_url
            || current.anthropic_model != settings.anthropic_model;
        let hotkey_changed = current.hotkey != settings.hotkey;
        let lan_changed = current.lan != settings.lan;
        let local_url_changed = current.local_url != settings.local_url;
        *current = settings.clone();
        (screen_changed, autostart_changed, engine_changed, hotkey_changed, lan_changed, local_url_changed)
    };
    if local_url_changed {
        extras::local_url::apply(&app);
    }
    if lan_changed {
        let prefs = settings.lan.clone();
        std::thread::spawn(move || lan::apply(&prefs));
    }
    if hotkey_changed {
        let _ = hotkey::apply(&app, &settings.hotkey);
    }
    // Each engine keeps its own history shape; switching starts a new chat.
    if engine_changed {
        app.state::<Chat>().reset();
        app.state::<CliChat>().reset();
        app.state::<OpenAiChat>().reset();
    }
    if let Err(err) = settings::save(&settings) {
        eprintln!("[coucou] could not save settings: {err}");
    }
    if autostart_changed {
        let manager = app.autolaunch();
        let result = if settings.autostart { manager.enable() } else { manager.disable() };
        if let Err(err) = result {
            eprintln!("[coucou] autostart: {err}");
        }
    }
    if screen_changed {
        let collapsed = shared.gate.collapsed.load(Ordering::Relaxed);
        island::apply_geometry(&app, &settings.screen, collapsed);
    }
    // Keep the other window in step (island ⇄ settings window).
    let _ = app.emit("settings-changed", settings);
}

/// Hidden island → shrink the window to the invisible wake strip and park the
/// cursor poll; anything else → full panel and 60 Hz polling.
#[tauri::command]
fn set_collapsed(app: AppHandle, shared: State<Shared>, collapsed: bool) {
    let pref = shared.settings.lock().unwrap().screen.clone();
    shared.gate.collapsed.store(collapsed, Ordering::Relaxed);
    island::apply_geometry(&app, &pref, collapsed);
    // The wake strip must always take the mouse, and a resize invalidates the flag.
    island::set_ignore_cursor(&app, false);
    shared.gate.forget_ignore_state();
    shared.gate.set_active(!collapsed);
}

/// The front end pushes the island shape; Rust decides click-through from it.
#[tauri::command]
fn set_island_rect(shared: State<Shared>, x: f64, y: f64, width: f64, height: f64) {
    shared.gate.set_rect(island::IslandRect { x, y, w: width, h: height });
}

#[tauri::command]
fn focus_window(app: AppHandle, focused: bool) {
    let Some(win) = island::window(&app) else { return };
    island::set_activating(&win, focused);
    if focused {
        let _ = win.set_focus();
    }
}

#[tauri::command]
fn reposition(app: AppHandle, shared: State<Shared>) {
    let pref = shared.settings.lock().unwrap().screen.clone();
    let collapsed = shared.gate.collapsed.load(Ordering::Relaxed);
    island::apply_geometry(&app, &pref, collapsed);
}

/// A URL that is safe to hand to the shell: http(s) with a host, re-serialised by
/// the `url` crate so spaces, quotes and control characters come out
/// percent-encoded. A bare prefix check let `https://x" other-args` through to
/// rundll32 as it was typed.
fn web_url(raw: &str) -> Option<String> {
    let parsed = url::Url::parse(raw.trim()).ok()?;
    if !matches!(parsed.scheme(), "http" | "https") || parsed.host_str().is_none_or(str::is_empty) {
        return None;
    }
    let out = parsed.to_string();
    if out.chars().any(|c| c.is_whitespace() || c.is_control() || c == '"') {
        return None;
    }
    Some(out)
}

#[tauri::command]
fn open_url(url: String) {
    let Some(url) = web_url(&url) else {
        log::line("open_url refused a non-web URL");
        return;
    };
    let _ = Command::new("rundll32.exe")
        .args(["url.dll,FileProtocolHandler", &url])
        .creation_flags(CREATE_NO_WINDOW)
        .spawn();
}

/// A folder worth opening: absolute, existing, and a directory. Anything else is
/// refused — handed to Explorer, a file path is *run*, and handed to `code`, a
/// string starting with `-` is read as an option.
fn project_folder(path: Option<&str>) -> Option<std::path::PathBuf> {
    let p = std::path::Path::new(path?.trim());
    if p.as_os_str().is_empty() || !p.is_absolute() || !p.is_dir() {
        return None;
    }
    Some(p.to_path_buf())
}

/// "Open terminal" opens the working folder in VS Code when `code` is on PATH,
/// and falls back to Explorer otherwise.
#[tauri::command]
fn open_in_vscode(path: Option<String>) -> bool {
    // No `cmd /C` anywhere near this. The path is a project folder chosen by
    // whoever is using Claude Code, and cmd would happily read `&`, `^` and `%`
    // in a folder name as syntax. Finding the launcher ourselves and handing the
    // path over as a separate argument keeps it a path.
    let folder = project_folder(path.as_deref());
    if path.as_deref().is_some_and(|p| !p.is_empty()) && folder.is_none() {
        log::line("open_in_vscode refused a path that is not a folder");
        return false;
    }
    if let Some(code) = find_on_path("code") {
        let mut cmd = Command::new(code);
        if let Some(p) = &folder {
            cmd.arg(p);
        }
        if cmd.creation_flags(CREATE_NO_WINDOW).spawn().is_ok() {
            return true;
        }
    }
    if let Some(p) = &folder {
        let _ = Command::new("explorer").arg(p).spawn();
    }
    false
}

/// Our own `where`: walks %PATH% against %PATHEXT%, no shell involved.
/// Rust quotes arguments correctly for `.cmd`/`.bat` targets since 1.77, so
/// spawning `code.cmd` directly is safe.
pub(crate) fn find_on_path(stem: &str) -> Option<std::path::PathBuf> {
    let exts = std::env::var("PATHEXT").unwrap_or_else(|_| ".COM;.EXE;.BAT;.CMD".into());
    let dirs = std::env::var_os("PATH")?;
    for dir in std::env::split_paths(&dirs) {
        for ext in exts.split(';').filter(|e| !e.is_empty()) {
            let candidate = dir.join(format!("{stem}{}", ext.to_lowercase()));
            if candidate.is_file() {
                return Some(candidate);
            }
        }
    }
    None
}

#[tauri::command]
fn quit_app(app: AppHandle) {
    app.exit(0);
}

/// Tray → Pause. Paused means paused: the pollers stop talking to the network,
/// not just the island stopping showing things.
#[tauri::command]
fn set_paused(paused: bool) {
    integrations::set_paused(paused);
}

// ── Claude Code hooks ─────────────────────────────────────────────────────────

#[tauri::command]
fn hooks_status(target: Option<String>) -> HookStatus {
    hooks::status(hooks::Target::from_id(target.as_deref()).unwrap_or(hooks::Target::Claude))
}

/// Returns the diff the user has to look at before anything is written.
#[tauri::command]
fn hooks_preview(webview: Webview, install: bool, target: Option<String>) -> Result<HookPreview, String> {
    only(&webview, SETTINGS_LABEL, "hooks_preview")?;
    hooks::preview(hooks::Target::from_id(target.as_deref())?, install)
}

/// Only ever called from an explicit click in the settings window.
#[tauri::command]
fn hooks_apply(
    app: AppHandle,
    webview: Webview,
    shared: State<Shared>,
    install: bool,
    fingerprint: String,
    target: Option<String>,
) -> Result<String, String> {
    only(&webview, SETTINGS_LABEL, "hooks_apply")?;
    // The fingerprint comes from the preview the user actually looked at, so a
    // settings.json that changed in between is refused rather than overwritten.
    let target = hooks::Target::from_id(target.as_deref())?;
    let backup = hooks::write(target, install, &fingerprint)?;
    if target == hooks::Target::Codex {
        return Ok(backup);
    }
    let updated = {
        let mut current = shared.settings.lock().unwrap();
        current.hooks_installed = install;
        let _ = settings::save(&current);
        current.clone()
    };
    let _ = app.emit("settings-changed", updated);
    Ok(backup)
}

#[tauri::command]
fn approval_decision(app: AppHandle, webview: Webview, request_id: String, decision: String) {
    if only(&webview, island::WINDOW_LABEL, "approval_decision").is_err() {
        return;
    }
    pipe::answer(&app, &request_id, &decision);
}

/// The island has the card on screen, so the long wait for a human may begin.
/// Until this arrives the relay only waits a few hundred milliseconds, which is
/// what stops a paused or unresponsive island from freezing Claude Code.
#[tauri::command]
fn approval_ack(app: AppHandle, webview: Webview, request_id: String) {
    if only(&webview, island::WINDOW_LABEL, "approval_ack").is_err() {
        return;
    }
    pipe::acknowledge(&app, &request_id);
}

/// Nobody can act on this request — the island is paused, or another card is
/// already up. Claude Code falls back to asking in the terminal immediately.
#[tauri::command]
fn approval_decline(app: AppHandle, webview: Webview, request_id: String) {
    if only(&webview, island::WINDOW_LABEL, "approval_decline").is_err() {
        return;
    }
    pipe::decline(&app, &request_id);
}

// ── Chat, files and secrets ───────────────────────────────────────────────────

/// One chat turn. The API key and any file bytes stay on the Rust side.
#[tauri::command]
async fn chat_send(
    webview: Webview,
    shared: State<'_, Shared>,
    chat: State<'_, Chat>,
    cli: State<'_, CliChat>,
    openai: State<'_, OpenAiChat>,
    query: String,
    context: Option<ChatContext>,
    tuning: Option<tuning::ChatTuning>,
) -> Result<ChatReply, String> {
    only(&webview, island::WINDOW_LABEL, "chat_send")?;
    let s = shared.settings.lock().unwrap().clone();
    // The chat's own model and effort (tuning.rs) win over Settings for this
    // message; the server they go to is still the one Settings chose.
    let tuning = tuning.unwrap_or_default();
    let pick = |configured: &str| tuning.model().map(str::to_string).unwrap_or_else(|| configured.to_string());
    match resolve_engine(&s) {
        Backend::Api => {
            let effort = tuning.effort_for(tuning::efforts("api"));
            claude::send(&chat, &claude::Target::Official, &pick(&s.model), query, context, effort).await
        }
        Backend::AnthropicCompat => {
            let target = claude::Target::Custom(claude::custom_endpoint(&s.anthropic_base_url)?);
            let effort = tuning.effort_for(tuning::efforts("anthropic"));
            claude::send(&chat, &target, &pick(&s.anthropic_model), query, context, effort).await
        }
        Backend::Cli(engine) => {
            let effort = tuning.effort_for(tuning::cli_efforts(engine));
            cli_chat::send(&cli, engine, &pick(&s.cli_model), query, context, effort).await
        }
        Backend::OpenAi => {
            let effort = tuning.effort_for(tuning::efforts("openai"));
            openai_chat::send(&openai, &s.openai_base_url, &pick(&s.openai_model), query, context, effort).await
        }
        Backend::None => Err(
            "No chat engine yet: install Claude Code (or Codex, Gemini CLI, opencode), or add an Anthropic API key in Settings → Chat."
                .into(),
        ),
    }
}

enum Backend {
    Api,
    Cli(Engine),
    OpenAi,
    /// An endpoint speaking Anthropic's Messages dialect (upstream #26).
    AnthropicCompat,
    None,
}

/// "auto" keeps the API for anyone who saved a key (nothing changes for them),
/// then picks the first CLI installed (Claude Code first), then a configured
/// OpenAI-compatible endpoint.
fn resolve_engine(s: &Settings) -> Backend {
    match s.chat_engine.as_str() {
        "api" => Backend::Api,
        "openai" => Backend::OpenAi,
        "anthropic" => Backend::AnthropicCompat,
        "auto" | "" => {
            if secrets::present("anthropic-api-key") {
                return Backend::Api;
            }
            let found = cli_chat::installed();
            if let Some(e) = Engine::ALL.into_iter().find(|e| found.contains_key(e)) {
                return Backend::Cli(e);
            }
            if !s.openai_base_url.trim().is_empty() {
                return Backend::OpenAi;
            }
            if !s.anthropic_base_url.trim().is_empty() {
                return Backend::AnthropicCompat;
            }
            Backend::None
        }
        id => Engine::from_id(id).map_or(Backend::Api, Backend::Cli),
    }
}

#[tauri::command]
fn chat_reset(chat: State<Chat>, cli: State<CliChat>, openai: State<OpenAiChat>) {
    chat.reset();
    cli.reset();
    openai.reset();
}

/// The clipboard's text, read only when the user clicks the clipboard button.
#[tauri::command]
fn clipboard_text(webview: Webview) -> Result<Option<String>, String> {
    only(&webview, island::WINDOW_LABEL, "clipboard_text")?;
    Ok(clipboard::text())
}

/// Shortcut choices for Settings, and whether the current one could be registered.
#[tauri::command]
fn hotkey_choices() -> Vec<(String, String)> {
    hotkey::CHOICES.iter().map(|(id, label)| (id.to_string(), label.to_string())).collect()
}

/// Applies and saves a shortcut, reporting a combination another program owns.
#[tauri::command]
fn hotkey_set(app: AppHandle, webview: Webview, shared: State<Shared>, spec: String) -> Result<(), String> {
    only(&webview, SETTINGS_LABEL, "hotkey_set")?;
    if !hotkey::CHOICES.iter().any(|(id, _)| *id == spec) {
        return Err("Unknown shortcut.".into());
    }
    let result = hotkey::apply(&app, &spec);
    let updated = {
        let mut current = shared.settings.lock().unwrap();
        current.hotkey = if result.is_ok() { spec } else { "off".into() };
        let _ = settings::save(&current);
        current.clone()
    };
    let _ = app.emit("settings-changed", updated);
    result
}

/// "Open Orca" on the Orca card: `orca open` launches or focuses the app.
#[tauri::command]
fn open_orca() -> bool {
    orca::open_app()
}

/// Orca card → a worktree row: Orca's window, on that agent's terminal.
#[tauri::command]
fn orca_focus(id: String) -> bool {
    orca::focus(&id)
}

/// Orca card → ±: the worktree's changes as diffs in Orca's editor.
#[tauri::command]
async fn orca_open_changes(id: String) -> Result<(), String> {
    tauri::async_runtime::spawn_blocking(move || orca::open_changes(&id)).await.map_err(|e| e.to_string())?
}

/// The Orca question view → Send / a choice: the answer, as the Run's
/// coordinator, for a question or gate the last poll read from Orca.
#[tauri::command]
async fn orca_answer(id: String, text: String) -> Result<(), String> {
    tauri::async_runtime::spawn_blocking(move || orca::answer(&id, &text)).await.map_err(|e| e.to_string())?
}

// ── Mochis on the network (lan/) ─────────────────────────────────────────────

/// A paired Mochi asks this one: answered by an engine that can't read this
/// PC's files — the API engines, or Claude Code with web tools only.
pub(crate) async fn answer_for_peer(app: &AppHandle, from: &str, text: &str) -> Result<String, String> {
    let s = app.state::<Shared>().settings.lock().unwrap().clone();
    let query = format!("{from}'s Mochi, on the same local network, asks you this — answer them directly:\n\n{text}");
    let reply = match resolve_engine(&s) {
        Backend::Api => claude::send(&Chat::default(), &claude::Target::Official, &s.model, query, None, None).await,
        Backend::AnthropicCompat => {
            let target = claude::Target::Custom(claude::custom_endpoint(&s.anthropic_base_url)?);
            claude::send(&Chat::default(), &target, &s.anthropic_model, query, None, None).await
        }
        Backend::OpenAi => openai_chat::send(&OpenAiChat::default(), &s.openai_base_url, &s.openai_model, query, None, None).await,
        Backend::Cli(Engine::Claude) => return cli_chat::ask_web_only(&s.cli_model, query).await,
        Backend::Cli(_) => return Err("This Mochi's chat engine can't take questions from other Mochis.".into()),
        Backend::None => return Err("This Mochi has no chat engine set up.".into()),
    };
    reply.map(|r| r.text)
}

#[tauri::command]
fn lan_state() -> lan::LanView {
    lan::view()
}

#[tauri::command]
async fn lan_pair(webview: Webview, id: String) -> Result<(), String> {
    only(&webview, SETTINGS_LABEL, "lan_pair")?;
    tauri::async_runtime::spawn_blocking(move || lan::pair(&id)).await.map_err(|e| e.to_string())?
}

/// A pairing code or a file offer, answered with a click in the island.
#[tauri::command]
fn lan_decide(webview: Webview, token: String, ok: bool) -> Result<(), String> {
    only(&webview, island::WINDOW_LABEL, "lan_decide")?;
    lan::decide(&token, ok);
    Ok(())
}

#[tauri::command]
fn lan_forget(webview: Webview, id: String) -> Result<(), String> {
    only(&webview, SETTINGS_LABEL, "lan_forget")?;
    lan::forget(&id);
    Ok(())
}

#[tauri::command]
async fn lan_message(id: String, text: String) -> Result<(), String> {
    tauri::async_runtime::spawn_blocking(move || lan::send_message(&id, &text)).await.map_err(|e| e.to_string())?
}

#[tauri::command]
async fn lan_ask(id: String, text: String) -> Result<String, String> {
    tauri::async_runtime::spawn_blocking(move || lan::ask(&id, &text)).await.map_err(|e| e.to_string())?
}

/// Sends a dropped file — only Coucou's own inbox copy, never another path.
#[tauri::command]
async fn lan_send_file(id: String, path: String) -> Result<(), String> {
    let file = claude::inbox_file(&path).ok_or("That file is not in Coucou's inbox — drop it again.")?;
    tauri::async_runtime::spawn_blocking(move || lan::send_file(&id, &file)).await.map_err(|e| e.to_string())?
}

/// Header → a paired Mochi → "Send a file…": the Open dialog. Returns a token
/// and the file's name; the path stays in Rust.
#[tauri::command]
async fn lan_pick_file(app: AppHandle) -> Option<(String, String)> {
    let owner = island::window(&app).and_then(|w| w.hwnd().ok()).map(|h| h.0 as isize);
    tauri::async_runtime::spawn_blocking(move || lan::pick_file(owner)).await.ok().flatten()
}

#[tauri::command]
async fn lan_send_picked(id: String, token: String) -> Result<(), String> {
    tauri::async_runtime::spawn_blocking(move || lan::send_picked(&id, &token)).await.map_err(|e| e.to_string())?
}

/// What Mochi is doing, for the paired Mochis that ask.
#[tauri::command]
fn lan_set_status(state: String, label: String) {
    lan::set_local_status(&state, &label);
}

/// Shows a received file in Explorer — only inside Downloads\Coucou.
#[tauri::command]
fn lan_reveal(path: String) -> bool {
    let dir = lan::downloads_dir();
    let (Ok(file), Ok(dir)) = (std::fs::canonicalize(&path), std::fs::canonicalize(&dir)) else { return false };
    if !file.starts_with(&dir) || !file.is_file() {
        return false;
    }
    Command::new("explorer").arg(format!("/select,{}", file.display())).spawn().is_ok()
}

// ── Discord (discord.rs) ─────────────────────────────────────────────────────

#[tauri::command]
fn discord_state() -> Option<discord::Snapshot> {
    discord::snapshot()
}

// ── Extras (extras/) ──────────────────────────────────────────────────────────

/// Settings › Extras → City → Set: the place Open-Meteo knows by that name. The
/// settings window then saves it like any setting.
#[tauri::command]
async fn extras_geocode(webview: Webview, city: String, language: String) -> Result<Option<extras::Place>, String> {
    only(&webview, SETTINGS_LABEL, "extras_geocode")?;
    let language: String = language.chars().filter(|c| c.is_ascii_alphabetic() || *c == '-').take(8).collect();
    Ok(extras::weather::geocode(&city, if language.is_empty() { "en" } else { &language }).await)
}

/// A city or a calendar address changed: fetch now rather than in 15 minutes.
#[tauri::command]
async fn extras_refresh(app: AppHandle, what: String) {
    match what.as_str() {
        "weather" => extras::weather::tick(&app, true).await,
        "calendar" => extras::ical::tick(&app, true).await,
        _ => {}
    }
}

/// A custom Mochi's card → Run now.
#[tauri::command]
fn custom_run(app: AppHandle, id: String) -> bool {
    extras::custom::run_now(&app, &id)
}

/// Settings › Extras shows the curl line with this PC's own token.
#[tauri::command]
fn local_url_token(webview: Webview) -> Result<Option<String>, String> {
    only(&webview, SETTINGS_LABEL, "local_url_token")?;
    Ok(extras::local_url::token())
}

/// Settings → Connect to Discord: the approval window in the Discord app.
#[tauri::command]
fn discord_connect(webview: Webview) -> Result<(), String> {
    only(&webview, SETTINGS_LABEL, "discord_connect")?;
    discord::request_approval();
    Ok(())
}

#[tauri::command]
fn discord_sign_out(webview: Webview) -> Result<(), String> {
    only(&webview, SETTINGS_LABEL, "discord_sign_out")?;
    discord::sign_out();
    Ok(())
}

/// The card's buttons: mute, deafen, the microphone and the output.
#[tauri::command]
fn discord_set(what: String, on: Option<bool>, id: Option<String>) {
    match (what.as_str(), on, id) {
        ("mute", Some(on), _) => discord::set_mute(on),
        ("deaf", Some(on), _) => discord::set_deaf(on),
        ("input", _, Some(id)) => discord::set_device(false, &id),
        ("output", _, Some(id)) => discord::set_device(true, &id),
        _ => {}
    }
}

#[tauri::command]
fn discord_open(channel: Option<String>) {
    discord::open(channel);
}

/// Rich Presence (opt-in in Settings → Discord).
#[tauri::command]
fn discord_presence(app: AppHandle, details: Option<String>, state: Option<String>) {
    let on = app.state::<Shared>().settings.lock().unwrap().discord.presence;
    discord::set_activity(if on { details.map(|d| (d, state)) } else { None });
}

/// "You're talking while muted" (opt-in): the island turns the meter on while
/// Discord has the user muted in a call; the setting must be on as well.
#[tauri::command]
fn discord_mic(app: AppHandle, on: bool) {
    let allowed = app.state::<Shared>().settings.lock().unwrap().discord.muted_alert;
    mic::set_listening(&app, on && allowed);
}

/// The webhook: a test from Settings, or a dropped file (the inbox copy only).
#[tauri::command]
async fn discord_webhook(text: String, path: Option<String>) -> Result<(), String> {
    let file = match path {
        Some(p) => Some(claude::inbox_file(&p).ok_or("That file is not in Coucou's inbox — drop it again.")?),
        None => None,
    };
    discord::webhook_send(&text, file).await
}

/// Drag-out of Mochi: the window under the cursor, captured into the inbox.
#[tauri::command]
async fn attach_window() -> Result<capture::AttachedWindow, String> {
    tauri::async_runtime::spawn_blocking(capture::attach)
        .await
        .map_err(|e| e.to_string())?
}

/// "Jump to terminal": focuses the window hosting a session (see jump.rs).
/// False when there is none, so the island falls back to opening the folder.
#[tauri::command]
async fn focus_session(host: Vec<jump::HostProc>, cwd: Option<String>) -> bool {
    if host.len() > 16 {
        return false;
    }
    tauri::async_runtime::spawn_blocking(move || jump::focus(&host, cwd.as_deref()))
        .await
        .unwrap_or(false)
}

/// Spotify pill buttons: play/pause, next, previous.
#[tauri::command]
async fn media_control(app: AppHandle, action: String) -> Result<(), String> {
    let result = tauri::async_runtime::spawn_blocking(move || media::control(&action))
        .await
        .map_err(|e| e.to_string())?;
    // Show the new track right away rather than at the next poll.
    integrations::poll_once(app, "integration_spotify").await;
    result
}

/// Where the GitHub pill's token comes from: "token" (pasted), "gh" (the local
/// gh login) or None. The token itself never leaves Rust.
#[tauri::command]
async fn github_auth() -> Option<&'static str> {
    tauri::async_runtime::spawn_blocking(github::token)
        .await
        .ok()
        .flatten()
        .map(|(_, source)| source.id())
}

/// opencode plugin state for Settings (experimental).
#[tauri::command]
fn opencode_status() -> opencode::PluginStatus {
    opencode::status()
}

/// The plugin's text, shown before anything is written.
#[tauri::command]
fn opencode_plugin_text() -> String {
    opencode::PLUGIN.to_string()
}

/// Installs or removes Coucou's opencode plugin — only from an explicit click.
#[tauri::command]
fn opencode_apply(webview: Webview, install: bool) -> Result<String, String> {
    only(&webview, SETTINGS_LABEL, "opencode_apply")?;
    opencode::apply(install)
}

/// Which chat engines are installed, with their versions, for Settings → Chat.
#[tauri::command]
async fn chat_engines() -> Vec<EngineInfo> {
    tauri::async_runtime::spawn_blocking(cli_chat::detect).await.unwrap_or_default()
}

/// What the chat's model and effort menus offer for the engine answering now:
/// the server's own model list when it has one.
#[tauri::command]
async fn chat_choices(shared: State<'_, Shared>) -> Result<tuning::Choices, String> {
    let s = shared.settings.lock().unwrap().clone();
    let (engine, default_label, models) = match resolve_engine(&s) {
        Backend::Api => ("api".to_string(), s.model.clone(), claude::models(&claude::Target::Official).await),
        Backend::AnthropicCompat => {
            let models = match claude::custom_endpoint(&s.anthropic_base_url) {
                Ok(url) => claude::models(&claude::Target::Custom(url)).await,
                Err(_) => Vec::new(),
            };
            ("anthropic".to_string(), s.anthropic_model.clone(), models)
        }
        Backend::OpenAi => ("openai".to_string(), s.openai_model.clone(), openai_chat::models(&s.openai_base_url).await),
        Backend::Cli(e) => {
            let models = if e == Engine::Claude { tuning::claude_cli_models() } else { Vec::new() };
            (e.id().to_string(), s.cli_model.clone(), models)
        }
        Backend::None => (String::new(), String::new(), Vec::new()),
    };
    let efforts = tuning::efforts(&engine).to_vec();
    Ok(tuning::Choices { engine, default_label, models, efforts })
}

/// The engine "auto" resolves to right now, for the island's badge and Settings.
#[tauri::command]
fn chat_engine_active(shared: State<Shared>) -> String {
    let s = shared.settings.lock().unwrap().clone();
    match resolve_engine(&s) {
        Backend::Api => "api".into(),
        Backend::Cli(e) => e.id().into(),
        Backend::OpenAi => "openai".into(),
        Backend::AnthropicCompat => "anthropic".into(),
        Backend::None => String::new(),
    }
}

/// Copies a dropped file into the inbox and reports its name back. Only a path
/// the OS really dropped on the island is accepted, once.
#[tauri::command]
fn ingest_file(webview: Webview, dropped: State<Dropped>, path: String) -> Result<DroppedFile, String> {
    only(&webview, island::WINDOW_LABEL, "ingest_file")?;
    {
        let mut list = dropped.0.lock().unwrap();
        let wanted = std::path::Path::new(&path);
        let Some(i) = list.iter().position(|p| p.as_path() == wanted) else {
            log::line("ingest_file refused a path that was not dropped");
            return Err("Drop the file on Mochi to share it.".into());
        };
        list.remove(i);
    }
    files::ingest(&path)
}

/// Remembers what the OS dropped on the island, for `ingest_file`.
fn remember_drop(app: &AppHandle, label: &str, paths: &[std::path::PathBuf]) {
    if label != island::WINDOW_LABEL {
        return;
    }
    let dropped = app.state::<Dropped>();
    let mut list = dropped.0.lock().unwrap();
    for p in paths {
        if !list.contains(p) {
            list.push(p.clone());
        }
    }
    // Only the latest few matter; the island ingests the first path at once.
    let excess = list.len().saturating_sub(16);
    list.drain(..excess);
}

/// The island may only ask whether a key exists — never read it.
#[tauri::command]
fn secret_present(key: String) -> bool {
    secrets::present(&key)
}

#[tauri::command]
fn secret_set(webview: Webview, key: String, value: String) -> Result<(), String> {
    only(&webview, SETTINGS_LABEL, "secret_set")?;
    // The n8n API key is sent to whatever this URL says, so it has to be a URL
    // the key can safely travel to.
    if key == "n8n-url" && !value.trim().is_empty() {
        integrations::secure_base_url(&value)?;
    }
    secrets::set(&key, &value)
}

#[tauri::command]
fn secret_clear(webview: Webview, key: String) -> Result<(), String> {
    only(&webview, SETTINGS_LABEL, "secret_clear")?;
    secrets::clear(&key)
}

/// Opens the configured n8n instance — the URL lives in the Credential Manager.
#[tauri::command]
fn open_n8n() {
    if let Some(url) = secrets::get("n8n-url") {
        open_url(url);
    }
}

/// Refresh buttons in the integration cards.
#[tauri::command]
async fn refresh_integration(app: AppHandle, id: String) {
    integrations::poll_once(app, &id).await;
}

/// Lets the island write to the same log as the Rust side.
#[tauri::command]
fn log_line(message: String) {
    log::line(format!("ui  {message}"));
}

// ── Settings window ───────────────────────────────────────────────────────────

/// WebView2 allows exactly one browser environment per app, and its options are
/// fixed by whichever webview is created first. Every window must therefore ask
/// for the *same* arguments as the island (see `additionalBrowserArgs` in
/// tauri.conf.json) — a mismatch makes the second window come up blank, with no
/// error anywhere.
const BROWSER_ARGS: &str = "--disable-features=msWebOOUI,msPdfOOUI,msSmartScreenProtection --autoplay-policy=no-user-gesture-required";

/// In a dev build the pages are served by Vite, so the second window needs the
/// absolute dev URL; a bundled build resolves it inside the app bundle.
fn settings_page_url(app: &AppHandle) -> WebviewUrl {
    #[cfg(dev)]
    if let Some(mut base) = app.config().build.dev_url.clone() {
        base.set_path("/settings.html");
        return WebviewUrl::External(base);
    }
    let _ = app;
    WebviewUrl::App("settings.html".into())
}

/// The settings window is created hidden at launch and only ever shown and
/// hidden afterwards. A WebView2 window created later — on the main thread or
/// not — silently comes up blank in this app, so the window that works is the
/// one that exists before the island's webview does.
fn create_settings_window(app: &AppHandle) {
    let url = settings_page_url(app);
    match WebviewWindowBuilder::new(app, "settings", url)
        .additional_browser_args(BROWSER_ARGS)
        .title("Settings — Coucou")
        .inner_size(560.0, 680.0)
        .min_inner_size(460.0, 480.0)
        .resizable(true)
        .visible(false)
        .center()
        .build()
    {
        Ok(win) => {
            // Closing it must only hide it, or it could never be reopened.
            let hidden = win.clone();
            win.on_window_event(move |event| {
                if let tauri::WindowEvent::CloseRequested { api, .. } = event {
                    api.prevent_close();
                    let _ = hidden.hide();
                }
            });
        }
        Err(err) => log::line(format!("settings window failed: {err}")),
    }
}

pub fn show_settings_window(app: &AppHandle) {
    let Some(win) = app.get_webview_window("settings") else {
        log::line("settings window missing");
        return;
    };
    let _ = win.unminimize();
    let _ = win.show();
    let _ = win.set_focus();
}

#[tauri::command]
fn open_settings_window(app: AppHandle) {
    show_settings_window(&app);
}

pub fn run() {
    let loaded = settings::load();
    let gate = Arc::new(PollGate::new());

    tauri::Builder::default()
        .plugin(tauri_plugin_single_instance::init(|app, _argv, _cwd| {
            let _ = app.emit_to(island::WINDOW_LABEL, "tray", "open".to_string());
        }))
        .plugin(tauri_plugin_autostart::init(MacosLauncher::LaunchAgent, None))
        .manage(Shared {
            settings: Mutex::new(loaded.clone()),
            gate: gate.clone(),
        })
        .manage(Pending::default())
        .manage(Chat::default())
        .manage(CliChat::default())
        .manage(OpenAiChat::default())
        .manage(Dropped::default())
        // Depending on the webview, a drop arrives as a window or a webview
        // event; both feed the same list.
        .on_window_event(|window, event| {
            if let WindowEvent::DragDrop(DragDropEvent::Drop { paths, .. }) = event {
                remember_drop(window.app_handle(), window.label(), paths);
            }
        })
        .on_webview_event(|webview, event| {
            if let WebviewEvent::DragDrop(DragDropEvent::Drop { paths, .. }) = event {
                remember_drop(webview.app_handle(), webview.label(), paths);
            }
        })
        .invoke_handler(tauri::generate_handler![
            boot,
            save_settings,
            set_collapsed,
            set_island_rect,
            focus_window,
            reposition,
            open_url,
            open_in_vscode,
            quit_app,
            hooks_status,
            hooks_preview,
            hooks_apply,
            approval_decision,
            approval_ack,
            approval_decline,
            log_line,
            chat_send,
            chat_reset,
            chat_engines,
            chat_engine_active,
            clipboard_text,
            hotkey_choices,
            hotkey_set,
            open_orca,
            orca_focus,
            orca_open_changes,
            orca_answer,
            github_auth,
            attach_window,
            focus_session,
            media_control,
            chat_choices,
            lan_state,
            lan_pair,
            lan_decide,
            lan_forget,
            lan_message,
            lan_ask,
            lan_send_file,
            lan_set_status,
            lan_pick_file,
            discord_state,
            discord_connect,
            extras_geocode,
            extras_refresh,
            custom_run,
            local_url_token,
            discord_sign_out,
            discord_set,
            discord_open,
            discord_presence,
            discord_webhook,
            discord_mic,
            lan_send_picked,
            lan_reveal,
            opencode_status,
            opencode_plugin_text,
            opencode_apply,
            ingest_file,
            secret_present,
            secret_set,
            secret_clear,
            refresh_integration,
            open_n8n,
            open_settings_window,
            set_paused,
        ])
        .setup(move |app| {
            let handle = app.handle().clone();
            tray::build(&handle)?;
            // Before the island: see create_settings_window.
            create_settings_window(&handle);

            if let Some(win) = island::window(&handle) {
                island::make_non_activating(&win);
                island::apply_geometry(&handle, &loaded.screen, false);
                let _ = win.show();
            }
            gate.collapsed.store(false, Ordering::Relaxed);
            gate.set_active(true);
            island::spawn_cursor_poll(handle.clone(), gate.clone());
            island::spawn_screen_follow(handle.clone(), gate.clone());

            log::line(format!("--- Coucou {} started ---", env!("CARGO_PKG_VERSION")));
            hooks::ensure_hook_exe(&handle);
            if let Err(err) = hotkey::apply(&handle, &loaded.hotkey) {
                log::line(format!("hotkey not registered: {err}"));
            }
            pipe::start(handle.clone());
            integrations::start(handle.clone());
            lan::init(&handle, &loaded.lan);
            discord::start(&handle);
            extras::start(&handle);
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running Coucou");
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_web_urls_reach_the_shell_and_they_come_out_encoded() {
        assert_eq!(web_url("https://vercel.com/dashboard").as_deref(), Some("https://vercel.com/dashboard"));
        assert_eq!(web_url("https://a.b/x y\"z").as_deref(), Some("https://a.b/x%20y%22z"));
        for bad in [
            "file:///C:/Windows/System32/calc.exe",
            "javascript:alert(1)",
            r"C:\Windows\System32\calc.exe",
            "calc.exe",
            "ms-settings:",
            "https://",
            "",
        ] {
            assert!(web_url(bad).is_none(), "{bad:?} must be refused");
        }
    }

    #[test]
    fn only_existing_absolute_folders_are_opened() {
        let tmp = std::env::temp_dir();
        assert!(project_folder(tmp.to_str()).is_some());
        assert!(project_folder(Some("--install-extension=evil.vsix")).is_none());
        assert!(project_folder(Some(r"relative\folder")).is_none());
        let file = tmp.join(format!("coucou-not-a-folder-{}.exe", std::process::id()));
        std::fs::write(&file, b"x").unwrap();
        assert!(project_folder(file.to_str()).is_none(), "a file must never be handed to Explorer");
        let _ = std::fs::remove_file(&file);
        assert!(project_folder(None).is_none());
    }
}
