// Preferences, stored as plain JSON in %APPDATA%\Coucou\settings.json.
// No secret ever lands here — API keys live in the Windows Credential Manager.

use serde::{Deserialize, Serialize};
use std::path::PathBuf;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Settings {
    pub sound_enabled: bool,
    pub sound_volume: f64,
    pub auto_close_interval: f64,
    pub absence_interval: f64,
    pub active_integrations: Vec<String>,
    /// "primary" = the main display, "cursor" = whichever display the mouse is on.
    pub screen: String,
    pub autostart: bool,
    pub hooks_installed: bool,
    /// Claude model used by the chat. Changeable in the settings window.
    /// Defaulted explicitly so a settings.json written by an older build still loads.
    #[serde(default = "default_model")]
    pub model: String,
    /// What answers the chat: "auto", "api", or a CLI id ("claude", "codex",
    /// "gemini", "opencode"). "auto" keeps the API when a key is saved, and
    /// otherwise uses the first CLI installed, so nobody needs a key to start.
    #[serde(default = "default_chat_engine")]
    pub chat_engine: String,
    /// Model passed to the CLI engine; empty means the CLI's own default.
    #[serde(default)]
    pub cli_model: String,
    /// OpenAI-compatible endpoint (Ollama, LM Studio, OpenRouter…). Not a
    /// secret; its optional key is in the Credential Manager.
    #[serde(default)]
    pub openai_base_url: String,
    #[serde(default)]
    pub openai_model: String,
    /// Anthropic-compatible endpoint (LiteLLM, DeepSeek, Kimi, GLM…), upstream
    /// #26. Not a secret; its optional key is `anthropic-compat-key`.
    #[serde(default)]
    pub anthropic_base_url: String,
    #[serde(default)]
    pub anthropic_model: String,
    /// Global shortcut that opens the chat: "off" or one of hotkey::CHOICES.
    #[serde(default = "default_hotkey")]
    pub hotkey: String,
    /// Mochi's mode (macOS FocusMode): "normal", "doNotDisturb", "work" or
    /// "sleep". Do Not Disturb and Sleep silence sounds and toasts.
    #[serde(default = "default_focus_mode")]
    pub focus_mode: String,
    /// Discord's switches (discord.rs); keys are in the Credential Manager.
    #[serde(default)]
    pub discord: crate::discord::DiscordPrefs,
    /// Mochis on the local network (lan/): off by default.
    #[serde(default)]
    pub lan: crate::lan::LanPrefs,
    /// Interface language: "auto" (follow Windows), "en", "es" or "pt-BR".
    #[serde(default = "default_language")]
    pub language: String,
    /// Custom Mochis (extras/): only the settings window may change them, since
    /// each one can carry a command.
    #[serde(default)]
    pub custom_mochis: Vec<crate::extras::CustomMochi>,
    /// The local URL scripts call (127.0.0.1:47823): off by default.
    #[serde(default)]
    pub local_url: bool,
    /// The Weather pill's city, looked up once in Settings.
    #[serde(default)]
    pub weather_place: Option<crate::extras::Place>,
    /// Mochi as a pet: sessions, streak, what it wears.
    #[serde(default)]
    pub pet: crate::extras::Pet,
    /// Mochi says things out loud (finished sessions, meetings): off by default.
    #[serde(default)]
    pub voice: bool,
    /// Worktrees from Mochi (worktrees.rs): repos and their provider commands,
    /// changed by the settings window only.
    #[serde(default)]
    pub worktree_repos: Vec<crate::worktrees::Repo>,
    /// The desktop Mochi (pet.rs): off by default.
    #[serde(default)]
    pub desktop_mochi: bool,
    /// It follows the cursor to another screen.
    #[serde(default = "default_true")]
    pub pet_follow: bool,
    /// Where it sits on each screen, relative to the work area (0…1).
    #[serde(default)]
    pub pet_positions: std::collections::HashMap<String, [f64; 2]>,
    /// The pet walks on top of your windows (off), comes when you shake the
    /// mouse (on), steps out of sight while you present or share (on).
    #[serde(default)]
    pub pet_walker: bool,
    #[serde(default = "default_true")]
    pub pet_shake: bool,
    #[serde(default = "default_true")]
    pub pet_hide: bool,
    /// Seasonal outfits (pumpkin, Santa hat, party hat): on by default.
    #[serde(default = "default_true")]
    pub seasonal: bool,
    /// The user's birthday, "MM-dd" (empty: none).
    #[serde(default)]
    pub birthday: String,
    /// The year the birthday's confetti last went off (Rust only).
    #[serde(default)]
    pub birthday_party_year: i32,
}

fn default_true() -> bool {
    true
}

fn default_focus_mode() -> String {
    "normal".into()
}

fn default_language() -> String {
    "auto".into()
}

fn default_hotkey() -> String {
    "ctrl+alt+space".into()
}

fn default_model() -> String {
    crate::claude::DEFAULT_MODEL.to_string()
}

fn default_chat_engine() -> String {
    "auto".into()
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            sound_enabled: true,
            sound_volume: 0.12,
            auto_close_interval: 15.0,
            absence_interval: 180.0,
            active_integrations: vec![
                "integration_resend".into(),
                "integration_n8n".into(),
                "integration_vercel".into(),
                "integration_github".into(),
            ],
            // The island follows the cursor's screen (macOS: on by default).
            screen: "cursor".into(),
            autostart: false,
            hooks_installed: false,
            model: default_model(),
            chat_engine: default_chat_engine(),
            cli_model: String::new(),
            openai_base_url: String::new(),
            openai_model: String::new(),
            anthropic_base_url: String::new(),
            anthropic_model: String::new(),
            lan: Default::default(),
            focus_mode: default_focus_mode(),
            discord: Default::default(),
            hotkey: default_hotkey(),
            language: default_language(),
            custom_mochis: Vec::new(),
            local_url: false,
            weather_place: None,
            pet: Default::default(),
            voice: false,
            worktree_repos: Vec::new(),
            desktop_mochi: false,
            pet_follow: true,
            pet_positions: Default::default(),
            pet_walker: false,
            pet_shake: true,
            pet_hide: true,
            seasonal: true,
            birthday: String::new(),
            birthday_party_year: 0,
        }
    }
}

/// %APPDATA%\Coucou
pub fn config_dir() -> PathBuf {
    let base = std::env::var_os("APPDATA")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("."));
    base.join("Coucou")
}

/// %LOCALAPPDATA%\Coucou — where coucou-hook.exe and the log live.
pub fn local_dir() -> PathBuf {
    let base = std::env::var_os("LOCALAPPDATA")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("."));
    base.join("Coucou")
}

pub fn hook_exe_path() -> PathBuf {
    local_dir().join("bin").join("coucou-hook.exe")
}

fn settings_path() -> PathBuf {
    config_dir().join("settings.json")
}

pub fn load() -> Settings {
    match std::fs::read(settings_path()) {
        Ok(bytes) => serde_json::from_slice(&bytes).unwrap_or_default(),
        Err(_) => Settings::default(),
    }
}

pub fn save(settings: &Settings) -> std::io::Result<()> {
    let dir = config_dir();
    std::fs::create_dir_all(&dir)?;
    let json = serde_json::to_vec_pretty(settings)
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))?;
    std::fs::write(settings_path(), json)
}
