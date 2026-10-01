// opencode plugin installer (experimental). opencode loads every file in
// ~/.config/opencode/plugins at startup, so integrating means writing one file
// there: windows/opencode-plugin/coucou.js, embedded at build time. No config
// file is edited. A coucou.js that isn't ours (no version marker) is never
// overwritten or removed. Based on upstream PR #19.

use std::path::PathBuf;

use serde::Serialize;

pub const PLUGIN: &str = include_str!("../../opencode-plugin/coucou.js");
const MARKER: &str = "COUCOU_PLUGIN_VERSION";

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PluginStatus {
    pub path: String,
    pub installed: bool,
    /// Installed but older than the one this build carries.
    pub outdated: bool,
    /// A coucou.js that Coucou did not write.
    pub foreign: bool,
    pub opencode_found: bool,
}

fn plugin_path() -> PathBuf {
    let home = std::env::var_os("USERPROFILE").map(PathBuf::from).unwrap_or_else(|| PathBuf::from("."));
    home.join(".config").join("opencode").join("plugins").join("coucou.js")
}

/// `const COUCOU_PLUGIN_VERSION = N;` → N.
fn version_of(text: &str) -> Option<u32> {
    let line = text.lines().find(|l| l.contains(MARKER) && l.contains('='))?;
    line.split('=').nth(1)?.trim().trim_end_matches(';').trim().parse().ok()
}

pub fn status() -> PluginStatus {
    let path = plugin_path();
    let existing = std::fs::read_to_string(&path).ok();
    let ours = existing.as_deref().and_then(version_of);
    PluginStatus {
        path: path.to_string_lossy().to_string(),
        installed: ours.is_some(),
        outdated: ours.is_some_and(|v| Some(v) < version_of(PLUGIN)),
        foreign: existing.is_some() && ours.is_none(),
        opencode_found: crate::cli_chat::locate(crate::cli_chat::Engine::Opencode).is_some(),
    }
}

/// Writes (or removes) Coucou's plugin. Called only from an explicit click.
pub fn apply(install: bool) -> Result<String, String> {
    let path = plugin_path();
    let existing = std::fs::read_to_string(&path).ok();
    if existing.is_some() && existing.as_deref().and_then(version_of).is_none() {
        return Err(format!("{} exists and isn't Coucou's — it was left untouched.", path.display()));
    }
    if !install {
        if existing.is_some() {
            std::fs::remove_file(&path).map_err(|e| format!("could not remove: {e}"))?;
        }
        return Ok(format!("Removed {}.", path.display()));
    }
    let dir = path.parent().ok_or("no plugin folder")?;
    std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
    let temp = path.with_extension(format!("js.coucou-{}", std::process::id()));
    std::fs::write(&temp, PLUGIN).map_err(|e| format!("write failed: {e}"))?;
    if let Err(err) = std::fs::rename(&temp, &path) {
        let _ = std::fs::remove_file(&temp);
        return Err(format!("write failed: {err}"));
    }
    Ok(format!("Installed {}. Restart opencode to load it.", path.display()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_embedded_plugin_carries_its_version_and_tags_the_agent() {
        assert!(version_of(PLUGIN).is_some_and(|v| v >= 2));
        assert!(PLUGIN.contains("--agent opencode"));
        assert_eq!(version_of("const COUCOU_PLUGIN_VERSION = 7;"), Some(7));
        assert_eq!(version_of("export const x = 1;"), None);
    }
}
