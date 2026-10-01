// Extras (macOS PR #3): custom Mochis, the Calendar, PC and Weather pills, and
// the local URL scripts call. Each poller works only while its pill is on; the
// local URL listens only when the user switched it on (Settings › Extras).
//
// • Custom Mochis — a name, a colour, something to wear, and news from a command
//   the user typed (custom.rs) or from the local URL (local_url.rs).
// • Calendar — an iCal address (Google's "secret address in iCal format",
//   Outlook's "publish calendar"), kept in the Credential Manager, fetched every
//   5 minutes: the next meeting and its Join link (ical.rs).
// • PC — CPU, battery, free disk and running builds, read locally (system.rs).
// • Weather — Open-Meteo for the city typed in Settings; only that city's
//   coordinates go out (weather.rs).
//
// The pure bits below are ExtrasParse.swift, tested the same way.

pub mod custom;
pub mod ical;
pub mod local_url;
pub mod system;
pub mod weather;

use serde::{Deserialize, Serialize};
use tauri::AppHandle;

/// Things a custom Mochi can wear (MochiAccessory.wearable).
pub const WEARABLE: &[&str] = &["none", "cap", "hardhat", "crown", "bow", "antenna", "glasses", "sunglasses", "scarf"];
const MAX_CUSTOM: usize = 12;

/// A Mochi the user made in Settings › Extras; its id is also its pill's id.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct CustomMochi {
    pub id: String,
    pub name: String,
    pub color: String,
    pub accessory: String,
    /// Run with `cmd /C` every `interval` seconds while its pill is on; empty:
    /// news only arrives by the local URL.
    #[serde(default)]
    pub command: String,
    #[serde(default = "default_interval")]
    pub interval: u32,
}

fn default_interval() -> u32 {
    60
}

impl CustomMochi {
    /// What the URL calls it: lowercase, no accents, dashes.
    pub fn slug(&self) -> String {
        let mut out = String::new();
        for c in self.name.to_lowercase().chars().map(fold) {
            if c.is_alphanumeric() {
                out.push(c);
            } else if !out.is_empty() && !out.ends_with('-') {
                out.push('-');
            }
        }
        out.trim_end_matches('-').to_string()
    }
}

/// Latin letters without their accents (the slug, like macOS's diacritic folding).
fn fold(c: char) -> char {
    match c {
        'á' | 'à' | 'â' | 'ä' | 'ã' | 'å' => 'a',
        'é' | 'è' | 'ê' | 'ë' => 'e',
        'í' | 'ì' | 'î' | 'ï' => 'i',
        'ó' | 'ò' | 'ô' | 'ö' | 'õ' => 'o',
        'ú' | 'ù' | 'û' | 'ü' => 'u',
        'ñ' => 'n',
        'ç' => 'c',
        'ý' | 'ÿ' => 'y',
        _ => c,
    }
}

fn is_hex_color(s: &str) -> bool {
    s.len() == 7 && s.starts_with('#') && s[1..].chars().all(|c| c.is_ascii_hexdigit())
}

/// What a save may keep: well-formed ids, a name, a colour, a known accessory,
/// a command of reasonable length, 5 s to 1 h between runs.
pub fn sanitize_customs(list: Vec<CustomMochi>) -> Vec<CustomMochi> {
    let mut seen = std::collections::HashSet::new();
    list.into_iter()
        .filter(|m| {
            let rest = m.id.strip_prefix("custom_").unwrap_or("");
            rest.len() == 8 && rest.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit()) && seen.insert(m.id.clone())
        })
        .take(MAX_CUSTOM)
        .map(|mut m| {
            m.name = m.name.trim().chars().take(40).collect();
            if m.name.is_empty() {
                m.name = "Mochi".into();
            }
            if !is_hex_color(&m.color) {
                m.color = "#14B8A6".into();
            }
            if !WEARABLE.contains(&m.accessory.as_str()) {
                m.accessory = "none".into();
            }
            m.command = m.command.trim().chars().take(2000).collect();
            m.interval = m.interval.clamp(5, 3600);
            m
        })
        .collect()
}

/// The city the Weather pill follows (Settings › Extras).
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct Place {
    pub name: String,
    pub lat: f64,
    pub lon: f64,
}

/// Mochi as a pet (MochiPet.swift): kept by the island, saved with the settings.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Default)]
#[serde(rename_all = "camelCase", default)]
pub struct Pet {
    pub sessions: u32,
    pub streak: u32,
    pub best_streak: u32,
    /// yyyy-MM-dd (local) of the last finished session.
    pub last_day: String,
    /// None: the best trophy unlocked.
    pub wearing: Option<String>,
}

// ── ExtrasParse ───────────────────────────────────────────────────────────────

/// The video-call link in an event's URL, location or notes: Meet, Zoom, Teams,
/// Webex, Around (ExtrasParse.meetingLink, without a regex engine).
pub fn meeting_link(texts: &[Option<&str>]) -> Option<String> {
    for text in texts.iter().flatten() {
        let lower = text.to_ascii_lowercase();
        let mut from = 0;
        while let Some(i) = lower[from..].find("https://") {
            let start = from + i;
            if let Some(len) = call_link_len(&lower[start..]) {
                let link = text[start..start + len].trim_matches(|c| ".,;)>".contains(c));
                return Some(link.to_string());
            }
            from = start + "https://".len();
        }
    }
    None
}

/// How long the call link at the start of `s` (lowercase, "https://…") is, if it is one.
fn call_link_len(s: &str) -> Option<usize> {
    let rest = &s["https://".len()..];
    let label = |c: char| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-';
    let tail = |r: &str| r.find(|c: char| c.is_whitespace() || "<>\"".contains(c)).unwrap_or(r.len());
    let base = "https://".len();
    // meet.google.com/<code>: only the code's characters.
    if let Some(r) = rest.strip_prefix("meet.google.com/") {
        let n = r.find(|c: char| !label(c)).unwrap_or(r.len());
        return (n > 0).then_some(base + "meet.google.com/".len() + n);
    }
    let host_end = rest.find('/').unwrap_or(rest.len());
    let (host, path) = (&rest[..host_end], &rest[host_end..]);
    let one_label = |h: &str, domain: &str, needs: bool| match h.strip_suffix(domain) {
        Some("") => !needs,
        Some(sub) => sub.strip_suffix('.').is_some_and(|l| !l.is_empty() && l.chars().all(label)),
        None => false,
    };
    let path_ok = |prefixes: &[&str]| prefixes.iter().any(|p| path.strip_prefix(p).is_some_and(|r| tail(r) > 0));
    let ok = (one_label(host, "zoom.us", false) && path_ok(&["/j/", "/my/", "/w/"]))
        || (host == "teams.microsoft.com" && path_ok(&["/l/meetup-join/"]))
        || (host == "teams.live.com" && path_ok(&["/meet/"]))
        || (one_label(host, "webex.com", true) && path_ok(&["/"]))
        || (host == "around.co" && path_ok(&["/"]));
    ok.then(|| base + host_end + tail(path))
}

pub fn is_wet(code: i64) -> bool {
    (51..=67).contains(&code) || (80..=82).contains(&code) || (95..=99).contains(&code)
}

/// What Mochi wears for the weather: an umbrella if rain is here or likely
/// within two hours, a scarf in the cold, sunglasses on a hot clear day.
pub fn weather_accessory(code: i64, temperature: f64, day: bool, rain_chance: i64) -> &'static str {
    if is_wet(code) || rain_chance >= 50 {
        "umbrella"
    } else if temperature < 8.0 {
        "scarf"
    } else if day && code <= 1 && temperature >= 24.0 {
        "sunglasses"
    } else {
        "none"
    }
}

/// A custom Mochi command's output: an "ok:" / "working:" / "warning:" / "error:"
/// prefix sets the mood, else the exit code does. The text is the first line.
pub fn command_output(output: &str, exit_code: i32) -> (String, &'static str) {
    let first = output.split(['\n', '\r']).find(|l| !l.is_empty()).unwrap_or("");
    for mood in ["ok", "working", "warning", "error"] {
        let prefix_len = mood.len() + 1;
        if first.len() >= prefix_len && first.is_char_boundary(prefix_len) && first[..prefix_len].eq_ignore_ascii_case(&format!("{mood}:")) {
            return (first[prefix_len..].trim().to_string(), mood);
        }
    }
    (first.trim().to_string(), if exit_code == 0 { "ok" } else { "error" })
}

// ── Start ─────────────────────────────────────────────────────────────────────

/// The pollers (each idle while its pill is off) and, if switched on, the local URL.
pub fn start(app: &AppHandle) {
    system::start(app.clone());
    weather::start(app.clone());
    ical::start(app.clone());
    custom::start(app.clone());
    local_url::apply(app);
}

/// The pill's switch, from the settings the island and Settings share.
pub(crate) fn pill_on(app: &AppHandle, id: &str) -> bool {
    crate::integrations::is_enabled(app, id)
}

#[cfg(test)]
mod tests {
    use super::*;

    // tests/ExtrasParseTests.swift, line for line.
    #[test]
    fn meeting_links_wherever_the_event_keeps_them() {
        assert_eq!(
            meeting_link(&[None, Some("Sala 3"), Some("Únete: https://meet.google.com/abc-defg-hij.")]).as_deref(),
            Some("https://meet.google.com/abc-defg-hij"),
            "meet in notes, trailing dot dropped"
        );
        let zoom = meeting_link(&[Some("https://us02web.zoom.us/j/8123456789?pwd=xyz")]).unwrap();
        assert!(zoom.starts_with("https://us02web.zoom.us/"), "zoom");
        assert!(meeting_link(&[Some("https://teams.microsoft.com/l/meetup-join/19%3ameeting_x")]).is_some(), "teams");
        assert_eq!(meeting_link(&[Some("https://example.com/meet"), Some("Oficina")]), None, "not a call link");
        // And a few more for the hand-written matcher.
        assert_eq!(meeting_link(&[Some("(https://zoom.us/j/123),")]).as_deref(), Some("https://zoom.us/j/123"));
        assert_eq!(meeting_link(&[Some("https://acme.webex.com/meet/ana <x>")]).as_deref(), Some("https://acme.webex.com/meet/ana"));
        assert_eq!(meeting_link(&[Some("https://webex.com/x")]), None, "webex needs a site");
        assert_eq!(meeting_link(&[Some("https://evil.com/?https://meet.google.com/x")]).as_deref(), Some("https://meet.google.com/x"));
    }

    #[test]
    fn what_mochi_wears_for_the_weather() {
        assert_eq!(weather_accessory(61, 20.0, true, 0), "umbrella", "raining");
        assert_eq!(weather_accessory(2, 20.0, true, 60), "umbrella", "rain likely");
        assert_eq!(weather_accessory(3, 4.0, true, 10), "scarf", "cold");
        assert_eq!(weather_accessory(0, 28.0, true, 0), "sunglasses", "hot and clear");
        assert_eq!(weather_accessory(0, 28.0, false, 0), "none", "no sunglasses at night");
    }

    #[test]
    fn custom_mochi_command_output() {
        assert_eq!(command_output("working: deploying v2\nmore", 0), ("deploying v2".into(), "working"), "prefix");
        assert_eq!(command_output("ERROR: disk full", 0), ("disk full".into(), "error"), "prefix, any case");
        assert_eq!(command_output("3 pods running", 0), ("3 pods running".into(), "ok"), "exit 0");
        assert_eq!(command_output("", 2), ("".into(), "error"), "exit code");
        assert_eq!(command_output("\r\nok: fine\r\n", 1), ("fine".into(), "ok"), "Windows line ends");
    }

    #[test]
    fn slugs_and_saved_mochis() {
        let m = |id: &str, name: &str| CustomMochi {
            id: id.into(), name: name.into(), color: "#zzzzzz".into(), accessory: "umbrella".into(), command: " echo hi ".into(), interval: 1,
        };
        assert_eq!(m("custom_a", "Mi Mochí  de Producción!").slug(), "mi-mochi-de-produccion");
        let kept = sanitize_customs(vec![m("custom_ab12cd34", "  "), m("custom_ab12cd34", "dup"), m("bad", "x"), m("custom_AB12CD34", "caps")]);
        assert_eq!(kept.len(), 1);
        assert_eq!(kept[0].name, "Mochi");
        assert_eq!(kept[0].color, "#14B8A6");
        assert_eq!(kept[0].accessory, "none", "the umbrella belongs to the weather");
        assert_eq!(kept[0].command, "echo hi");
        assert_eq!(kept[0].interval, 5);
    }
}
