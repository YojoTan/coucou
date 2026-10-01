// The local URL scripts call — the same as on macOS:
//
//   curl -H "X-Coucou-Token: <token>" -d "Build OK" http://127.0.0.1:47823/mochi/<name>
//
// gives a custom Mochi its news (JSON works too: {"text": "...", "state":
// "working"}), and, on Windows, where no API says which Focus is on,
//
//   curl -X POST -H "X-Coucou-Token: <token>" http://127.0.0.1:47823/mode/doNotDisturb
//
// sets Mochi's mode, so Power Automate, Task Scheduler or any script can.
//
// Loopback only, and off until the user switches it on (Settings › Extras).
// The token header keeps web pages out: a browser can't send a custom header
// cross-origin without a preflight, and the preflight gets a 401. The token is
// made once and kept in the Credential Manager.

use std::io::{Read, Write};
use std::net::{Ipv4Addr, SocketAddrV4, TcpListener, TcpStream};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

use serde_json::Value;
use tauri::{AppHandle, Emitter, Manager};

use super::custom::Push;
use super::CustomMochi;

pub const PORT: u16 = 47823;
const TOKEN_KEY: &str = "custom-mochi-token";
const MAX_REQUEST: usize = 16 * 1024;
const MODES: &[&str] = &["normal", "doNotDisturb", "work", "sleep"];

/// The token the URL wants, made once (24 characters, no look-alikes).
pub fn token() -> Option<String> {
    let entry = keyring::Entry::new("fr.louisraille.coucou", TOKEN_KEY).ok()?;
    if let Ok(t) = entry.get_password() {
        if t.len() >= 16 {
            return Some(t);
        }
    }
    const ALPHABET: &[u8] = b"abcdefghijkmnopqrstuvwxyz23456789";
    let mut bytes = [0u8; 24];
    ring::rand::SecureRandom::fill(&ring::rand::SystemRandom::new(), &mut bytes).ok()?;
    let t: String = bytes.iter().map(|b| ALPHABET[*b as usize % ALPHABET.len()] as char).collect();
    entry.set_password(&t).ok()?;
    Some(t)
}

/// What a request asks for, once it passed the checks.
#[derive(Debug, PartialEq)]
enum Action {
    Push(Push),
    Mode(&'static str),
}

fn header<'a>(head: &'a str, name: &str) -> Option<&'a str> {
    head.split("\r\n").skip(1).find_map(|line| {
        let (k, v) = line.split_once(':')?;
        k.trim().eq_ignore_ascii_case(name).then(|| v.trim())
    })
}

fn same(a: &str, b: &str) -> bool {
    a.len() == b.len() && a.bytes().zip(b.bytes()).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

fn percent_decode(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    let hex = |b: u8| (b as char).to_digit(16).map(|d| d as u8);
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            if let (Some(hi), Some(lo)) = (hex(bytes[i + 1]), hex(bytes[i + 2])) {
                out.push(hi << 4 | lo);
                i += 3;
                continue;
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).to_string()
}

/// A custom Mochi by id, URL name or name (CustomMochis.find).
fn find<'a>(list: &'a [CustomMochi], key: &str) -> Option<&'a CustomMochi> {
    let k = key.to_lowercase();
    list.iter().find(|m| m.id == k || m.slug() == k || m.name.to_lowercase() == k)
}

/// The answer to one request: status, message, and what to do (macOS's order:
/// token, then method, then path).
fn route(head: &str, body: &str, token: &str, list: &[CustomMochi]) -> (u16, &'static str, Option<Action>) {
    let mut first = head.split("\r\n").next().unwrap_or("").split(' ');
    let (Some(method), Some(target)) = (first.next(), first.next()) else {
        return (400, "bad request", None);
    };
    if !header(head, "x-coucou-token").is_some_and(|t| same(t, token)) {
        return (401, "missing or wrong X-Coucou-Token (Settings › Extras)", None);
    }
    if method != "POST" {
        return (405, "POST /mochi/<name> or /mode/<mode>", None);
    }
    let path = target.split('?').next().unwrap_or("");
    if let Some(mode) = path.strip_prefix("/mode/") {
        return match MODES.iter().find(|m| m.eq_ignore_ascii_case(&percent_decode(mode))) {
            Some(m) => (200, "ok", Some(Action::Mode(m))),
            None => (404, "no such mode: normal, doNotDisturb, work or sleep", None),
        };
    }
    let Some(m) = path.strip_prefix("/mochi/").and_then(|name| find(list, &percent_decode(name))) else {
        return (404, "no such Mochi", None);
    };
    let body = body.trim();
    let (text, state) = match serde_json::from_str::<Value>(body) {
        Ok(json) if json.is_object() => {
            let state = json.get("state").and_then(Value::as_str).filter(|s| ["idle", "ok", "working", "warning", "error"].contains(s));
            (json.get("text").and_then(Value::as_str).unwrap_or("").to_string(), state.unwrap_or("ok").to_string())
        }
        _ => {
            let (text, mood) = super::command_output(body, 0);
            (text, mood.to_string())
        }
    };
    (200, "ok", Some(Action::Push(Push { id: m.id.clone(), text: text.trim().chars().take(140).collect(), state })))
}

fn respond(stream: &mut TcpStream, code: u16, message: &str) {
    let reason = match code {
        200 => "OK",
        400 => "Bad Request",
        401 => "Unauthorized",
        404 => "Not Found",
        405 => "Method Not Allowed",
        _ => "Error",
    };
    let body = format!("{message}\n");
    let _ = write!(
        stream,
        "HTTP/1.1 {code} {reason}\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len()
    );
}

/// Headers, then as much body as Content-Length says (capped at 16 KB).
fn read_request(stream: &mut TcpStream) -> Option<(String, String)> {
    let _ = stream.set_read_timeout(Some(Duration::from_secs(3)));
    let mut raw = Vec::new();
    let mut buf = [0u8; 8192];
    while raw.len() < MAX_REQUEST {
        let n = stream.read(&mut buf).ok()?;
        if n == 0 {
            break;
        }
        raw.extend_from_slice(&buf[..n]);
        if let Some(end) = raw.windows(4).position(|w| w == b"\r\n\r\n") {
            let head = String::from_utf8_lossy(&raw[..end]).to_string();
            let length = header(&head, "content-length").and_then(|v| v.parse::<usize>().ok()).unwrap_or(0);
            if raw.len() - (end + 4) >= length.min(MAX_REQUEST) {
                break;
            }
        }
    }
    let end = raw.windows(4).position(|w| w == b"\r\n\r\n")?;
    Some((String::from_utf8_lossy(&raw[..end]).to_string(), String::from_utf8_lossy(&raw[end + 4..]).to_string()))
}

fn serve(app: &AppHandle, mut stream: TcpStream) {
    let Some((head, body)) = read_request(&mut stream) else {
        return respond(&mut stream, 400, "bad request");
    };
    let Some(token) = token() else {
        return respond(&mut stream, 401, "no token yet (Settings › Extras)");
    };
    let list = app.try_state::<crate::Shared>().map(|s| s.settings.lock().unwrap().custom_mochis.clone()).unwrap_or_default();
    let (code, message, action) = route(&head, &body, &token, &list);
    respond(&mut stream, code, message);
    match action {
        Some(Action::Push(push)) => {
            let _ = app.emit("custom-mochi", push);
        }
        Some(Action::Mode(mode)) => {
            if let Some(shared) = app.try_state::<crate::Shared>() {
                let settings = {
                    let mut current = shared.settings.lock().unwrap();
                    current.focus_mode = mode.to_string();
                    current.clone()
                };
                if let Err(e) = crate::settings::save(&settings) {
                    crate::log::line(format!("local URL: could not save the mode: {e}"));
                }
                let _ = app.emit("settings-changed", settings);
            }
        }
        None => {}
    }
}

static GENERATION: AtomicU64 = AtomicU64::new(0);
static LISTENING: AtomicU64 = AtomicU64::new(0);

/// Listens or stops, as Settings › Extras says.
pub fn apply(app: &AppHandle) {
    let on = app.try_state::<crate::Shared>().is_some_and(|s| s.settings.lock().unwrap().local_url);
    let listening = LISTENING.load(Ordering::SeqCst) != 0;
    if on == listening {
        return;
    }
    let generation = GENERATION.fetch_add(1, Ordering::SeqCst) + 1;
    if !on {
        LISTENING.store(0, Ordering::SeqCst);
        // Wake the accept() so the old loop sees it is over.
        let _ = TcpStream::connect_timeout(&SocketAddrV4::new(Ipv4Addr::LOCALHOST, PORT).into(), Duration::from_millis(300));
        return;
    }
    let listener = match TcpListener::bind(SocketAddrV4::new(Ipv4Addr::LOCALHOST, PORT)) {
        Ok(l) => l,
        Err(e) => {
            crate::log::line(format!("local URL: port {PORT} is busy: {e}"));
            return;
        }
    };
    let _ = token();
    LISTENING.store(generation, Ordering::SeqCst);
    let app = app.clone();
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            if GENERATION.load(Ordering::SeqCst) != generation {
                break;
            }
            let Ok(stream) = stream else { continue };
            // Loopback only: bound to 127.0.0.1, and checked again here.
            if !stream.peer_addr().is_ok_and(|a| a.ip().is_loopback()) {
                continue;
            }
            let app = app.clone();
            std::thread::spawn(move || serve(&app, stream));
        }
        let _ = LISTENING.compare_exchange(generation, 0, Ordering::SeqCst, Ordering::SeqCst);
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    fn mochi() -> CustomMochi {
        CustomMochi { id: "custom_ab12cd34".into(), name: "Producción API".into(), color: "#14B8A6".into(), accessory: "cap".into(), command: String::new(), interval: 60 }
    }

    fn req(method: &str, path: &str, token: Option<&str>) -> String {
        let mut h = format!("{method} {path} HTTP/1.1\r\nHost: 127.0.0.1:47823");
        if let Some(t) = token {
            h.push_str(&format!("\r\nX-Coucou-Token: {t}"));
        }
        h
    }

    #[test]
    fn the_url_answers_like_the_macs() {
        let list = [mochi()];
        let t = "secret-token-1234567890";
        assert_eq!(route(&req("POST", "/mochi/produccion-api", None), "x", t, &list).0, 401, "no token");
        assert_eq!(route(&req("POST", "/mochi/produccion-api", Some("nope")), "x", t, &list).0, 401, "wrong token");
        assert_eq!(route(&req("OPTIONS", "/mochi/produccion-api", None), "", t, &list).0, 401, "a browser's preflight");
        assert_eq!(route(&req("GET", "/mochi/produccion-api", Some(t)), "", t, &list).0, 405);
        assert_eq!(route(&req("POST", "/mochi/other", Some(t)), "", t, &list).0, 404);

        let (code, _, action) = route(&req("POST", "/mochi/produccion-api", Some(t)), "error: build broke\n", t, &list);
        assert_eq!(code, 200);
        assert_eq!(action, Some(Action::Push(Push { id: "custom_ab12cd34".into(), text: "build broke".into(), state: "error".into() })));
        let (_, _, action) = route(&req("POST", "/mochi/Producci%C3%B3n%20API?x=1", Some(t)), r#"{"text":"deploying","state":"working"}"#, t, &list);
        assert_eq!(action, Some(Action::Push(Push { id: "custom_ab12cd34".into(), text: "deploying".into(), state: "working".into() })), "by name, percent-encoded");
        let (_, _, action) = route(&req("POST", "/mochi/custom_ab12cd34", Some(t)), r#"{"text":"x","state":"exploded"}"#, t, &list);
        assert!(matches!(action, Some(Action::Push(p)) if p.state == "ok"), "an unknown mood is ok");
    }

    #[test]
    fn scripts_can_set_mochis_mode() {
        let t = "secret-token-1234567890";
        assert_eq!(route(&req("POST", "/mode/doNotDisturb", Some(t)), "", t, &[]).2, Some(Action::Mode("doNotDisturb")));
        assert_eq!(route(&req("POST", "/mode/SLEEP", Some(t)), "", t, &[]).2, Some(Action::Mode("sleep")));
        assert_eq!(route(&req("POST", "/mode/party", Some(t)), "", t, &[]).0, 404);
        assert_eq!(route(&req("POST", "/mode/work", None), "", t, &[]).0, 401);
    }
}
