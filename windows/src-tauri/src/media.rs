// Now playing — the Spotify pill (after upstream PR #11).
//
// Windows already knows what is playing: the media flyout above the volume
// slider reads it from the System Media Transport Controls, which Spotify,
// browsers and most players publish to. Coucou reads the same thing — no API
// key, no OAuth, no window-title scraping — and its buttons ask the session to
// play, pause or skip, the way the flyout's do. Spotify wins when several apps
// have a session; otherwise whatever Windows considers current.

use serde::Serialize;
use windows::Media::Control::{
    GlobalSystemMediaTransportControlsSession as Session,
    GlobalSystemMediaTransportControlsSessionManager as Manager,
    GlobalSystemMediaTransportControlsSessionPlaybackStatus as Status,
};

#[derive(Serialize, Clone, Debug, Default, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct NowPlaying {
    pub playing: bool,
    pub title: String,
    pub artist: String,
    /// "Spotify", "Chrome"… from the session's app id.
    pub app: String,
}

/// "SpotifyAB.SpotifyMusic_zpdnekdrzrea0!Spotify" or "Spotify.exe" → "Spotify";
/// "Chrome" stays "Chrome".
fn app_label(id: &str) -> String {
    let lower = id.to_lowercase();
    for (needle, label) in [("spotify", "Spotify"), ("chrome", "Chrome"), ("msedge", "Edge"), ("firefox", "Firefox"),
                            ("zunemusic", "Media Player"), ("vlc", "VLC"), ("brave", "Brave")] {
        if lower.contains(needle) {
            return label.to_string();
        }
    }
    let tail = id.rsplit(['!', '\\', '/']).next().unwrap_or(id);
    tail.trim_end_matches(".exe").to_string()
}

fn session() -> windows::core::Result<Option<Session>> {
    let manager = Manager::RequestAsync()?.get()?;
    let sessions = manager.GetSessions()?;
    let spotify = (0..sessions.Size()?)
        .filter_map(|i| sessions.GetAt(i).ok())
        .find(|s| s.SourceAppUserModelId().map(|id| id.to_string().to_lowercase().contains("spotify")).unwrap_or(false));
    Ok(spotify.or_else(|| manager.GetCurrentSession().ok()))
}

/// What is playing now; None when nothing has a media session. Blocking.
pub fn now_playing() -> Option<NowPlaying> {
    let session = session().ok()??;
    let props = session.TryGetMediaPropertiesAsync().ok()?.get().ok()?;
    let title = props.Title().map(|t| t.to_string()).unwrap_or_default();
    if title.trim().is_empty() {
        return None;
    }
    let playing = session
        .GetPlaybackInfo()
        .and_then(|i| i.PlaybackStatus())
        .map(|s| s == Status::Playing)
        .unwrap_or(false);
    Some(NowPlaying {
        playing,
        title,
        artist: props.Artist().map(|a| a.to_string()).unwrap_or_default(),
        app: app_label(&session.SourceAppUserModelId().map(|id| id.to_string()).unwrap_or_default()),
    })
}

/// Play/pause, next or previous on the session shown. Blocking.
pub fn control(action: &str) -> Result<(), String> {
    let session = session().map_err(|e| e.to_string())?.ok_or("Nothing is playing.")?;
    let op = match action {
        "toggle" => session.TryTogglePlayPauseAsync(),
        // A Discord call pauses the music, and plays it again after (only if it paused it).
        "play" => session.TryPlayAsync(),
        "pause" => session.TryPauseAsync(),
        "next" => session.TrySkipNextAsync(),
        "previous" => session.TrySkipPreviousAsync(),
        _ => return Err("unknown media action".into()),
    };
    match op.and_then(|o| o.get()) {
        Ok(true) => Ok(()),
        Ok(false) => Err("The player declined.".into()),
        Err(e) => Err(e.to_string()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn app_ids_become_names() {
        assert_eq!(app_label("SpotifyAB.SpotifyMusic_zpdnekdrzrea0!Spotify"), "Spotify");
        assert_eq!(app_label("Spotify.exe"), "Spotify");
        assert_eq!(app_label("MSEdge"), "Edge");
        assert_eq!(app_label("Some.App_123!Player"), "Player");
    }

    /// Reads this PC's current media session. `--ignored`.
    #[test]
    #[ignore]
    fn live_now_playing() {
        println!("{:?}", now_playing().map(|n| (n.playing, n.app)));
    }
}
