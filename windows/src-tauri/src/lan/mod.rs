// Mochis on the local network (docs/LAN.md): find the other Coucous on this
// network, pair with one by comparing a six-digit code, then see its status,
// send it messages and files, and ask its Mochi.
//
// Off until the user turns it on. Nothing is accepted from an unpaired Mochi
// but a pairing request, which only shows a prompt. Every connection is an
// authenticated key exchange followed by AES-256-GCM (wire.rs). A file is
// only ever received after a click, and a peer may ask this Mochi only if the
// user allowed it — the answer then comes from an engine with no access to
// this PC's files.

pub mod wire;

use std::collections::HashMap;
use std::io::{Read, Write};
use std::net::{IpAddr, SocketAddr, TcpListener, TcpStream, UdpSocket};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{mpsc, Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

use ring::digest::{Context, SHA256};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use tauri::{AppHandle, Emitter};

use wire::{b64, hex, unb64, Channel, Identity};

pub const UDP_PORT: u16 = 47801;
const BEACON_EVERY: Duration = Duration::from_secs(4);
const GONE_AFTER: Duration = Duration::from_secs(15);
const STATUS_EVERY: Duration = Duration::from_secs(10);
const DECIDE_TIMEOUT: Duration = Duration::from_secs(120);
const MAX_FILE: u64 = 512 * 1024 * 1024;
const CHUNK: usize = 48 * 1024;
const KEYRING_SERVICE: &str = "fr.louisraille.coucou";
const IDENTITY_KEY: &str = "lan-identity";

// ── Preferences and the trusted list ─────────────────────────────────────────

/// Settings → Mochis. Stored with the other settings (settings.rs).
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Default)]
#[serde(rename_all = "camelCase", default)]
pub struct LanPrefs {
    pub enabled: bool,
    /// How this Mochi appears to others; empty → the computer's name.
    pub name: String,
    /// Send what Mochi is doing ("working on coucou"), not only its state.
    pub share_label: bool,
    /// Let paired Mochis ask this one (answered by an engine with no file access).
    pub allow_asks: bool,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct Trusted {
    pub id: String,
    pub name: String,
    pub key: String,
}

fn base_dir() -> PathBuf {
    #[cfg(test)]
    if let Some(dir) = tests::DIR.get() {
        return dir.clone();
    }
    crate::settings::config_dir()
}

fn trusted_path() -> PathBuf {
    base_dir().join("lan-peers.json")
}

fn load_trusted() -> Vec<Trusted> {
    std::fs::read(trusted_path())
        .ok()
        .and_then(|b| serde_json::from_slice(&b).ok())
        .unwrap_or_default()
}

fn save_trusted(list: &[Trusted]) {
    let _ = std::fs::create_dir_all(base_dir());
    if let Ok(json) = serde_json::to_vec_pretty(list) {
        let _ = std::fs::write(trusted_path(), json);
    }
}

/// The long-term key, in the Credential Manager — not one of the keys the
/// settings window can read or write (secrets.rs keeps its own list).
fn identity() -> Option<Identity> {
    #[cfg(test)]
    if tests::DIR.get().is_some() {
        return Identity::generate();
    }
    let entry = keyring::Entry::new(KEYRING_SERVICE, IDENTITY_KEY).ok()?;
    if let Some(id) = entry.get_password().ok().and_then(|s| unb64(&s)).and_then(|b| Identity::from_pkcs8(&b)) {
        return Some(id);
    }
    let fresh = Identity::generate()?;
    entry.set_password(&b64(fresh.pkcs8())).ok()?;
    Some(fresh)
}

fn computer_name() -> String {
    std::env::var("COMPUTERNAME").unwrap_or_else(|_| "Coucou".into())
}

// ── State ────────────────────────────────────────────────────────────────────

#[derive(Clone, Debug)]
struct Seen {
    name: String,
    addr: IpAddr,
    port: u16,
    key: Vec<u8>,
    at: Instant,
}

#[derive(Serialize, Clone, Debug, Default, PartialEq)]
pub struct PeerStatus {
    pub state: String,
    pub label: String,
}

#[derive(Serialize, Clone, Debug)]
#[serde(rename_all = "camelCase")]
pub struct PeerView {
    pub id: String,
    pub name: String,
    pub paired: bool,
    pub online: bool,
    pub status: Option<PeerStatus>,
}

#[derive(Serialize, Clone, Debug)]
#[serde(rename_all = "camelCase")]
pub struct LanView {
    pub enabled: bool,
    pub running: bool,
    pub id: String,
    pub name: String,
    pub peers: Vec<PeerView>,
}

struct Inner {
    prefs: LanPrefs,
    me: Option<Arc<Identity>>,
    port: u16,
    seen: HashMap<String, Seen>,
    status: HashMap<String, PeerStatus>,
    local: PeerStatus,
    pending: HashMap<String, mpsc::Sender<bool>>,
    asking: bool,
    last_ask: HashMap<String, Instant>,
}

struct Lan {
    app: Option<AppHandle>,
    inner: Mutex<Inner>,
    /// Bumped on every start/stop: a thread from an older run sees it changed and ends.
    generation: AtomicU64,
}

static LAN: OnceLock<Lan> = OnceLock::new();

fn lan() -> Option<&'static Lan> {
    LAN.get()
}

pub fn init(app: &AppHandle, prefs: &LanPrefs) {
    let _ = LAN.set(Lan {
        app: Some(app.clone()),
        inner: Mutex::new(Inner {
            prefs: LanPrefs::default(),
            me: None,
            port: 0,
            seen: HashMap::new(),
            status: HashMap::new(),
            local: PeerStatus { state: "idle".into(), label: String::new() },
            pending: HashMap::new(),
            asking: false,
            last_ask: HashMap::new(),
        }),
        generation: AtomicU64::new(0),
    });
    apply(prefs);
}

fn my_name(prefs: &LanPrefs) -> String {
    let n: String = prefs.name.trim().chars().filter(|c| !c.is_control()).take(40).collect();
    if n.is_empty() { computer_name() } else { n }
}

/// Settings changed: start, stop, or just take the new name and switches.
pub fn apply(prefs: &LanPrefs) {
    let Some(lan) = lan() else { return };
    let (was, now) = {
        let mut inner = lan.inner.lock().unwrap();
        let was = inner.prefs.enabled && inner.me.is_some();
        inner.prefs = prefs.clone();
        (was, prefs.enabled)
    };
    if was && !now {
        stop(lan);
    } else if !was && now {
        start(lan);
    }
    emit_state(lan);
}

fn stop(lan: &Lan) {
    lan.generation.fetch_add(1, Ordering::SeqCst);
    let mut inner = lan.inner.lock().unwrap();
    inner.me = None;
    inner.port = 0;
    inner.seen.clear();
    inner.status.clear();
    // Whoever waits on a decision gets a no.
    inner.pending.clear();
}

fn start(lan: &'static Lan) {
    let Some(me) = identity().map(Arc::new) else {
        crate::log::line("lan: no identity (Credential Manager?)");
        return;
    };
    let listener = match TcpListener::bind("0.0.0.0:0") {
        Ok(l) => l,
        Err(e) => {
            crate::log::line(format!("lan: cannot listen: {e}"));
            return;
        }
    };
    let _ = listener.set_nonblocking(true);
    let port = listener.local_addr().map(|a| a.port()).unwrap_or(0);
    let generation = lan.generation.fetch_add(1, Ordering::SeqCst) + 1;
    {
        let mut inner = lan.inner.lock().unwrap();
        inner.me = Some(me.clone());
        inner.port = port;
    }
    crate::log::line(format!("lan: on, id {} port {port}", me.id()));
    std::thread::spawn(move || serve(lan, listener, generation));
    // A unit test runs the server only: no beacons on the real network.
    #[cfg(test)]
    let in_test = tests::DIR.get().is_some();
    #[cfg(not(test))]
    let in_test = false;
    if !in_test {
        std::thread::spawn(move || discover(lan, generation));
    }
    std::thread::spawn(move || poll_status(lan, generation));
}

fn alive(lan: &Lan, generation: u64) -> bool {
    lan.generation.load(Ordering::SeqCst) == generation
}

pub fn view() -> LanView {
    let Some(lan) = lan() else {
        return LanView { enabled: false, running: false, id: String::new(), name: String::new(), peers: vec![] };
    };
    let inner = lan.inner.lock().unwrap();
    let trusted = load_trusted();
    let mut peers: Vec<PeerView> = trusted
        .iter()
        .map(|t| PeerView {
            id: t.id.clone(),
            name: inner.seen.get(&t.id).map(|s| s.name.clone()).unwrap_or_else(|| t.name.clone()),
            paired: true,
            online: inner.seen.contains_key(&t.id),
            status: inner.status.get(&t.id).cloned(),
        })
        .collect();
    for (id, s) in &inner.seen {
        if !trusted.iter().any(|t| &t.id == id) {
            peers.push(PeerView { id: id.clone(), name: s.name.clone(), paired: false, online: true, status: None });
        }
    }
    peers.sort_by(|a, b| (!a.paired, !a.online, a.name.to_lowercase()).cmp(&(!b.paired, !b.online, b.name.to_lowercase())));
    LanView {
        enabled: inner.prefs.enabled,
        running: inner.me.is_some(),
        id: inner.me.as_ref().map(|m| m.id()).unwrap_or_default(),
        name: my_name(&inner.prefs),
        peers,
    }
}

fn emit_state(lan: &Lan) {
    if let Some(app) = &lan.app {
        let _ = app.emit("lan-state", view());
    }
}

fn prompt(lan: &Lan, payload: Value) {
    #[cfg(test)]
    tests::PROMPTS.lock().unwrap().push(payload.clone());
    if let Some(app) = &lan.app {
        let _ = app.emit("lan-prompt", payload);
    }
}

/// The island says what Mochi is doing; peers read it with `status?`.
pub fn set_local_status(state: &str, label: &str) {
    if let Some(lan) = lan() {
        let mut inner = lan.inner.lock().unwrap();
        inner.local = PeerStatus {
            state: state.chars().filter(char::is_ascii_alphabetic).take(16).collect(),
            label: label.chars().filter(|c| !c.is_control()).take(80).collect(),
        };
    }
}

/// A pairing code or a file offer answered in the island.
pub fn decide(token: &str, ok: bool) {
    if let Some(lan) = lan() {
        if let Some(tx) = lan.inner.lock().unwrap().pending.remove(token) {
            let _ = tx.send(ok);
        }
    }
}

fn wait_decision(lan: &Lan, token: &str, timeout: Duration) -> bool {
    let (tx, rx) = mpsc::channel();
    lan.inner.lock().unwrap().pending.insert(token.to_string(), tx);
    let ok = rx.recv_timeout(timeout).unwrap_or(false);
    lan.inner.lock().unwrap().pending.remove(token);
    ok
}

pub fn forget(id: &str) {
    let mut list = load_trusted();
    list.retain(|t| t.id != id);
    save_trusted(&list);
    if let Some(lan) = lan() {
        lan.inner.lock().unwrap().status.remove(id);
        emit_state(lan);
    }
}

// ── Discovery ────────────────────────────────────────────────────────────────

fn beacon(lan: &Lan) -> Option<Vec<u8>> {
    let inner = lan.inner.lock().unwrap();
    let me = inner.me.as_ref()?;
    Some(
        json!({ "coucou": 1, "id": me.id(), "name": my_name(&inner.prefs), "port": inner.port, "key": b64(&me.public()) })
            .to_string()
            .into_bytes(),
    )
}

/// A beacon worth believing: well formed, its id matches its key, not ours.
fn parse_beacon(data: &[u8], own_id: &str) -> Option<(String, String, u16, Vec<u8>)> {
    if data.len() > 1024 {
        return None;
    }
    let v: Value = serde_json::from_slice(data).ok()?;
    if v.get("coucou").and_then(Value::as_u64) != Some(1) {
        return None;
    }
    let key = unb64(v.get("key")?.as_str()?)?;
    let id = v.get("id")?.as_str()?.to_string();
    if key.len() != 32 || id != wire::id_of(&key) || id == own_id {
        return None;
    }
    let port = u16::try_from(v.get("port")?.as_u64()?).ok().filter(|p| *p != 0)?;
    let name: String = v.get("name").and_then(Value::as_str).unwrap_or("Mochi").chars().filter(|c| !c.is_control()).take(40).collect();
    Some((id, name, port, key))
}

fn discover(lan: &'static Lan, generation: u64) {
    let socket = match UdpSocket::bind(("0.0.0.0", UDP_PORT)) {
        Ok(s) => s,
        Err(e) => {
            crate::log::line(format!("lan: discovery port busy ({e}); only announcing"));
            match UdpSocket::bind("0.0.0.0:0") {
                Ok(s) => s,
                Err(_) => return,
            }
        }
    };
    let _ = socket.set_broadcast(true);
    let _ = socket.set_read_timeout(Some(Duration::from_millis(500)));
    let mut last_beacon = Instant::now() - BEACON_EVERY;
    let mut buf = [0u8; 1500];
    while alive(lan, generation) {
        if last_beacon.elapsed() >= BEACON_EVERY {
            if let Some(b) = beacon(lan) {
                let _ = socket.send_to(&b, ("255.255.255.255", UDP_PORT));
            }
            last_beacon = Instant::now();
        }
        let mut changed = false;
        if let Ok((n, from)) = socket.recv_from(&mut buf) {
            let own = lan.inner.lock().unwrap().me.as_ref().map(|m| m.id()).unwrap_or_default();
            if let Some((id, name, port, key)) = parse_beacon(&buf[..n], &own) {
                let mut inner = lan.inner.lock().unwrap();
                let new = !inner.seen.contains_key(&id);
                let entry = Seen { name, addr: from.ip(), port, key, at: Instant::now() };
                changed = new || inner.seen.get(&id).map(|s| s.name != entry.name || s.addr != entry.addr || s.port != entry.port).unwrap_or(true);
                inner.seen.insert(id, entry);
                drop(inner);
                // Answer a newcomer straight away, so it sees us without waiting.
                if new {
                    if let Some(b) = beacon(lan) {
                        let _ = socket.send_to(&b, from);
                    }
                }
            }
        }
        {
            let mut inner = lan.inner.lock().unwrap();
            let before = inner.seen.len();
            inner.seen.retain(|_, s| s.at.elapsed() < GONE_AFTER);
            changed |= inner.seen.len() != before;
        }
        if changed {
            emit_state(lan);
        }
    }
}

// ── Server ───────────────────────────────────────────────────────────────────

fn serve(lan: &'static Lan, listener: TcpListener, generation: u64) {
    while alive(lan, generation) {
        match listener.accept() {
            Ok((stream, from)) => {
                std::thread::spawn(move || {
                    if let Err(e) = handle(lan, stream) {
                        crate::log::line(format!("lan: {from}: {e}"));
                    }
                });
            }
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => std::thread::sleep(Duration::from_millis(200)),
            Err(_) => std::thread::sleep(Duration::from_millis(500)),
        }
    }
}

fn is_trusted(key: &[u8]) -> bool {
    let key = b64(key);
    load_trusted().iter().any(|t| t.key == key)
}

fn handle(lan: &'static Lan, stream: TcpStream) -> std::io::Result<()> {
    let _ = stream.set_nonblocking(false);
    stream.set_read_timeout(Some(Duration::from_secs(15)))?;
    stream.set_write_timeout(Some(Duration::from_secs(15)))?;
    let (me, name) = {
        let inner = lan.inner.lock().unwrap();
        (inner.me.clone().ok_or_else(|| std::io::Error::other("off"))?, my_name(&inner.prefs))
    };
    let (mut ch, mode) = wire::accept(stream, &me, &name, is_trusted)?;
    if mode == "pair" {
        return pair_flow(lan, ch, false);
    }
    let request = ch.recv()?;
    let peer = ch.peer_name.clone();
    match request.get("t").and_then(Value::as_str).unwrap_or_default() {
        "status?" => {
            let local = lan.inner.lock().unwrap().local.clone();
            let share = lan.inner.lock().unwrap().prefs.share_label;
            ch.send(&json!({ "t": "status", "state": local.state, "label": if share { local.label } else { String::new() } }))
        }
        "msg" => {
            let text: String = request.get("text").and_then(Value::as_str).unwrap_or_default().chars().take(2000).collect();
            if text.trim().is_empty() {
                return ch.send(&json!({ "t": "error", "text": "empty" }));
            }
            prompt(lan, json!({ "kind": "message", "peer": peer, "peerId": ch.peer_id, "text": text }));
            ch.send(&json!({ "t": "ok" }))
        }
        "ask" => serve_ask(lan, &mut ch, &request),
        "file" => receive_file(lan, &mut ch, &request),
        _ => ch.send(&json!({ "t": "error", "text": "unknown request" })),
    }
}

fn serve_ask(lan: &Lan, ch: &mut Channel<TcpStream>, request: &Value) -> std::io::Result<()> {
    let text: String = request.get("text").and_then(Value::as_str).unwrap_or_default().chars().take(4000).collect();
    let refuse = |ch: &mut Channel<TcpStream>, why: &str| ch.send(&json!({ "t": "answer", "ok": false, "text": why }));
    {
        let mut inner = lan.inner.lock().unwrap();
        if !inner.prefs.allow_asks {
            drop(inner);
            return refuse(ch, "This Mochi doesn't take questions from other Mochis.");
        }
        if inner.asking {
            drop(inner);
            return refuse(ch, "This Mochi is answering another question — try again in a moment.");
        }
        if inner.last_ask.get(&ch.peer_id).is_some_and(|t| t.elapsed() < Duration::from_secs(10)) {
            drop(inner);
            return refuse(ch, "One question every 10 seconds, please.");
        }
        inner.asking = true;
        inner.last_ask.insert(ch.peer_id.clone(), Instant::now());
    }
    // Answering can take a while; the asker waits up to three minutes.
    let _ = ch.stream.set_write_timeout(Some(Duration::from_secs(30)));
    prompt(lan, json!({ "kind": "asked", "peer": ch.peer_name }));
    let result = match &lan.app {
        Some(app) => tauri::async_runtime::block_on(crate::answer_for_peer(app, &ch.peer_name, &text)),
        None => Ok(format!("echo: {text}")),
    };
    lan.inner.lock().unwrap().asking = false;
    match result {
        Ok(answer) => ch.send(&json!({ "t": "answer", "ok": true, "text": answer })),
        Err(e) => refuse(ch, &e),
    }
}

/// Only a name: any path is dropped, and so are characters Windows refuses.
pub fn safe_file_name(raw: &str) -> String {
    let base = raw.rsplit(['/', '\\']).next().unwrap_or_default();
    let cleaned: String = base
        .chars()
        .filter(|c| !c.is_control() && !"<>:\"|?*".contains(*c))
        .take(120)
        .collect();
    let cleaned = cleaned.trim().trim_matches('.').to_string();
    if cleaned.is_empty() { "file".into() } else { cleaned }
}

pub fn downloads_dir() -> PathBuf {
    #[cfg(test)]
    if let Some(dir) = tests::DIR.get() {
        return dir.join("Downloads");
    }
    std::env::var_os("USERPROFILE")
        .map(PathBuf::from)
        .unwrap_or_else(std::env::temp_dir)
        .join("Downloads")
        .join("Coucou")
}

fn unique_path(dir: &Path, name: &str) -> PathBuf {
    let candidate = dir.join(name);
    if !candidate.exists() {
        return candidate;
    }
    let (stem, ext) = match name.rsplit_once('.') {
        Some((s, e)) if !s.is_empty() => (s.to_string(), format!(".{e}")),
        _ => (name.to_string(), String::new()),
    };
    (2..1000)
        .map(|i| dir.join(format!("{stem} ({i}){ext}")))
        .find(|p| !p.exists())
        .unwrap_or_else(|| dir.join(format!("{stem}-{}{ext}", wire::random_hex(4))))
}

fn receive_file(lan: &Lan, ch: &mut Channel<TcpStream>, request: &Value) -> std::io::Result<()> {
    let name = safe_file_name(request.get("name").and_then(Value::as_str).unwrap_or_default());
    let size = request.get("size").and_then(Value::as_u64).unwrap_or(u64::MAX);
    if size > MAX_FILE {
        return ch.send(&json!({ "t": "file", "ok": false, "text": "Too large (512 MB at most)." }));
    }
    let token = wire::random_hex(8);
    prompt(lan, json!({ "kind": "file", "token": token, "peer": ch.peer_name, "name": name, "size": size }));
    // The sender waits for the click; reads must outlast it.
    let _ = ch.stream.set_read_timeout(Some(DECIDE_TIMEOUT + Duration::from_secs(5)));
    let ok = wait_decision(lan, &token, DECIDE_TIMEOUT);
    ch.send(&json!({ "t": "file", "ok": ok }))?;
    if !ok {
        return Ok(());
    }
    let _ = ch.stream.set_read_timeout(Some(Duration::from_secs(30)));
    let dir = downloads_dir();
    std::fs::create_dir_all(&dir)?;
    let part = dir.join(format!(".{}.part", wire::random_hex(6)));
    let mut out = std::fs::File::create(&part)?;
    let mut hash = Context::new(&SHA256);
    let mut got: u64 = 0;
    let finish = loop {
        let msg = match ch.recv() {
            Ok(m) => m,
            Err(e) => break Err(e.to_string()),
        };
        match msg.get("t").and_then(Value::as_str) {
            Some("chunk") => {
                let Some(data) = msg.get("data").and_then(Value::as_str).and_then(unb64) else { break Err("bad chunk".into()) };
                got += data.len() as u64;
                if got > size {
                    break Err("more data than announced".into());
                }
                hash.update(&data);
                out.write_all(&data)?;
            }
            Some("end") => {
                let want = msg.get("sha256").and_then(Value::as_str).unwrap_or_default().to_string();
                break if got == size && hex(hash.clone().finish().as_ref()) == want { Ok(()) } else { Err("the file arrived damaged".into()) };
            }
            _ => break Err("unexpected message".into()),
        }
    };
    drop(out);
    match finish {
        Ok(()) => {
            let dest = unique_path(&dir, &name);
            std::fs::rename(&part, &dest)?;
            prompt(lan, json!({ "kind": "received", "peer": ch.peer_name, "name": name, "path": dest.to_string_lossy() }));
            ch.send(&json!({ "t": "ok" }))
        }
        Err(why) => {
            let _ = std::fs::remove_file(&part);
            let _ = ch.send(&json!({ "t": "error", "text": why }));
            Ok(())
        }
    }
}

// ── Pairing ──────────────────────────────────────────────────────────────────

/// Both ends: show the code, send our user's answer, read theirs; both yes →
/// each stores the other.
fn pair_flow(lan: &Lan, mut ch: Channel<TcpStream>, initiator: bool) -> std::io::Result<()> {
    let token = wire::random_hex(8);
    prompt(lan, json!({ "kind": "pair", "token": token, "peer": ch.peer_name, "code": ch.code, "initiator": initiator }));
    let _ = ch.stream.set_read_timeout(Some(DECIDE_TIMEOUT * 2));
    let mine = wait_decision(lan, &token, DECIDE_TIMEOUT);
    ch.send(&json!({ "t": "pair", "ok": mine }))?;
    let theirs = ch.recv().ok().and_then(|v| v.get("ok").and_then(Value::as_bool)).unwrap_or(false);
    let paired = mine && theirs;
    if paired {
        let mut list = load_trusted();
        list.retain(|t| t.id != ch.peer_id);
        list.push(Trusted { id: ch.peer_id.clone(), name: ch.peer_name.clone(), key: b64(&ch.peer_key) });
        save_trusted(&list);
    }
    prompt(lan, json!({ "kind": "paired", "peer": ch.peer_name, "ok": paired }));
    emit_state(lan);
    Ok(())
}

// ── Client side ──────────────────────────────────────────────────────────────

fn dial(lan: &Lan, id: &str, mode: &str) -> Result<Channel<TcpStream>, String> {
    let (me, name, seen) = {
        let inner = lan.inner.lock().unwrap();
        let me = inner.me.clone().ok_or("Turn on Mochis on the network in Settings first.")?;
        let seen = inner.seen.get(id).cloned().ok_or("That Mochi isn't on the network right now.")?;
        (me, my_name(&inner.prefs), seen)
    };
    let expect = if mode == "session" {
        let trusted = load_trusted().into_iter().find(|t| t.id == id).ok_or("Pair with that Mochi first.")?;
        Some(unb64(&trusted.key).ok_or("bad stored key")?)
    } else {
        None
    };
    // The address is the one its beacon came from; the key decides who it is.
    let stream = TcpStream::connect_timeout(&SocketAddr::new(seen.addr, seen.port), Duration::from_secs(5))
        .map_err(|e| format!("Can't reach that Mochi: {e}"))?;
    stream.set_read_timeout(Some(Duration::from_secs(15))).ok();
    stream.set_write_timeout(Some(Duration::from_secs(15))).ok();
    if mode == "pair" && seen.key.len() != 32 {
        return Err("bad peer key".into());
    }
    wire::connect(stream, &me, &name, mode, expect.as_deref()).map_err(|e| format!("Secure connection failed: {e}"))
}

/// Settings → Pair: runs the code comparison with that Mochi. Blocking.
pub fn pair(id: &str) -> Result<(), String> {
    let lan = lan().ok_or("off")?;
    let ch = dial(lan, id, "pair")?;
    pair_flow(lan, ch, true).map_err(|e| e.to_string())
}

fn request(id: &str, msg: Value, wait: Duration) -> Result<Value, String> {
    let lan = lan().ok_or("off")?;
    let mut ch = dial(lan, id, "session")?;
    ch.stream.set_read_timeout(Some(wait)).ok();
    ch.send(&msg).map_err(|e| e.to_string())?;
    ch.recv().map_err(|e| e.to_string())
}

pub fn send_message(id: &str, text: &str) -> Result<(), String> {
    let text: String = text.chars().take(2000).collect();
    let reply = request(id, json!({ "t": "msg", "text": text }), Duration::from_secs(15))?;
    match reply.get("t").and_then(Value::as_str) {
        Some("ok") => Ok(()),
        _ => Err("That Mochi didn't take the message.".into()),
    }
}

pub fn ask(id: &str, text: &str) -> Result<String, String> {
    let text: String = text.chars().take(4000).collect();
    let reply = request(id, json!({ "t": "ask", "text": text }), Duration::from_secs(200))?;
    let answer = reply.get("text").and_then(Value::as_str).unwrap_or_default().to_string();
    if reply.get("ok").and_then(Value::as_bool) == Some(true) { Ok(answer) } else { Err(answer) }
}

/// Sends an inbox file to a paired Mochi, once its user accepted. Blocking.
pub fn send_file(id: &str, path: &Path) -> Result<(), String> {
    let lan = lan().ok_or("off")?;
    let size = std::fs::metadata(path).map_err(|e| e.to_string())?.len();
    if size > MAX_FILE {
        return Err("Too large to send (512 MB at most).".into());
    }
    let name = safe_file_name(&path.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default());
    let mut ch = dial(lan, id, "session")?;
    ch.send(&json!({ "t": "file", "name": name, "size": size })).map_err(|e| e.to_string())?;
    ch.stream.set_read_timeout(Some(DECIDE_TIMEOUT + Duration::from_secs(10))).ok();
    let answer = ch.recv().map_err(|e| e.to_string())?;
    if answer.get("ok").and_then(Value::as_bool) != Some(true) {
        return Err(answer.get("text").and_then(Value::as_str).unwrap_or("They declined the file.").to_string());
    }
    ch.stream.set_read_timeout(Some(Duration::from_secs(60))).ok();
    let mut file = std::fs::File::open(path).map_err(|e| e.to_string())?;
    let mut hash = Context::new(&SHA256);
    let mut buf = vec![0u8; CHUNK];
    loop {
        let n = file.read(&mut buf).map_err(|e| e.to_string())?;
        if n == 0 {
            break;
        }
        hash.update(&buf[..n]);
        ch.send(&json!({ "t": "chunk", "data": b64(&buf[..n]) })).map_err(|e| e.to_string())?;
    }
    ch.send(&json!({ "t": "end", "sha256": hex(hash.finish().as_ref()) })).map_err(|e| e.to_string())?;
    let done = ch.recv().map_err(|e| e.to_string())?;
    match done.get("t").and_then(Value::as_str) {
        Some("ok") => Ok(()),
        _ => Err(done.get("text").and_then(Value::as_str).unwrap_or("The transfer failed.").to_string()),
    }
}

fn poll_status(lan: &'static Lan, generation: u64) {
    let mut last = Instant::now() - STATUS_EVERY;
    while alive(lan, generation) {
        std::thread::sleep(Duration::from_millis(500));
        if last.elapsed() < STATUS_EVERY {
            continue;
        }
        last = Instant::now();
        let online: Vec<String> = {
            let inner = lan.inner.lock().unwrap();
            load_trusted().into_iter().map(|t| t.id).filter(|id| inner.seen.contains_key(id)).collect()
        };
        let mut changed = false;
        for id in online {
            let status = request(&id, json!({ "t": "status?" }), Duration::from_secs(5)).ok().map(|v| PeerStatus {
                state: v.get("state").and_then(Value::as_str).unwrap_or_default().chars().take(16).collect(),
                label: v.get("label").and_then(Value::as_str).unwrap_or_default().chars().filter(|c| !c.is_control()).take(80).collect(),
            });
            let mut inner = lan.inner.lock().unwrap();
            let before = inner.status.get(&id).cloned();
            match status {
                Some(s) => {
                    inner.status.insert(id.clone(), s);
                }
                None => {
                    inner.status.remove(&id);
                }
            }
            changed |= inner.status.get(&id) != before.as_ref();
        }
        if changed {
            emit_state(lan);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    pub static DIR: OnceLock<PathBuf> = OnceLock::new();
    pub static PROMPTS: Mutex<Vec<Value>> = Mutex::new(Vec::new());

    /// One Mochi running in this process (no app, no discovery needed), and its port.
    fn node() -> (u16, Vec<u8>) {
        static PORT: OnceLock<(u16, Vec<u8>)> = OnceLock::new();
        PORT.get_or_init(|| {
            let dir = std::env::temp_dir().join(format!("coucou-lan-node-{}", wire::random_hex(4)));
            std::fs::create_dir_all(&dir).unwrap();
            DIR.set(dir).unwrap();
            let _ = LAN.set(Lan {
                app: None,
                inner: Mutex::new(Inner {
                    prefs: LanPrefs::default(),
                    me: None,
                    port: 0,
                    seen: HashMap::new(),
                    status: HashMap::new(),
                    local: PeerStatus { state: "working".into(), label: "coucou".into() },
                    pending: HashMap::new(),
                    asking: false,
                    last_ask: HashMap::new(),
                }),
                generation: AtomicU64::new(0),
            });
            apply(&LanPrefs { enabled: true, name: "Node".into(), share_label: false, allow_asks: false });
            let inner = lan().unwrap().inner.lock().unwrap();
            (inner.port, inner.me.as_ref().unwrap().public())
        })
        .clone()
    }

    fn trust(me: &Identity) {
        let mut list = load_trusted();
        list.push(Trusted { id: me.id(), name: "Tester".into(), key: b64(&me.public()) });
        save_trusted(&list);
    }

    fn session(me: &Identity) -> std::io::Result<Channel<TcpStream>> {
        let (port, key) = node();
        let stream = TcpStream::connect(("127.0.0.1", port))?;
        stream.set_read_timeout(Some(Duration::from_secs(10)))?;
        wire::connect(stream, me, "Tester", "session", Some(&key))
    }

    /// Waits for the node to raise a prompt of `kind`, and returns it.
    fn wait_prompt(kind: &str) -> Value {
        for _ in 0..200 {
            {
                let mut prompts = PROMPTS.lock().unwrap();
                if let Some(i) = prompts.iter().position(|p| p["kind"] == kind) {
                    return prompts.remove(i);
                }
            }
            std::thread::sleep(Duration::from_millis(25));
        }
        panic!("no {kind} prompt");
    }

    #[test]
    fn a_paired_mochi_can_message_send_files_and_read_the_status_and_others_cannot() {
        let me = Identity::generate().unwrap();
        // Not paired yet: the session is refused.
        assert!(session(&me).and_then(|mut c| c.recv()).is_err());
        trust(&me);

        // Status: the state only, since sharing the label is off.
        let mut ch = session(&me).unwrap();
        ch.send(&json!({ "t": "status?" })).unwrap();
        let status = ch.recv().unwrap();
        assert_eq!((status["state"].as_str(), status["label"].as_str()), (Some("working"), Some("")));

        // A message becomes a prompt.
        let mut ch = session(&me).unwrap();
        ch.send(&json!({ "t": "msg", "text": "hola, ¿comemos?" })).unwrap();
        assert_eq!(ch.recv().unwrap()["t"], "ok");
        assert_eq!(wait_prompt("message")["text"], "hola, ¿comemos?");

        // Questions are off unless the user allows them.
        let mut ch = session(&me).unwrap();
        ch.send(&json!({ "t": "ask", "text": "2+2?" })).unwrap();
        assert_eq!(ch.recv().unwrap()["ok"], false);

        // A file: offered, accepted with a click, streamed, checked, saved under its bare name.
        let body: Vec<u8> = (0..120_000u32).map(|i| (i % 251) as u8).collect();
        let mut ch = session(&me).unwrap();
        ch.send(&json!({ "t": "file", "name": "..\\..\\informe.pdf", "size": body.len() })).unwrap();
        let offer = wait_prompt("file");
        assert_eq!(offer["name"], "informe.pdf");
        decide(offer["token"].as_str().unwrap(), true);
        assert_eq!(ch.recv().unwrap()["ok"], true);
        let mut hash = Context::new(&SHA256);
        for chunk in body.chunks(CHUNK) {
            hash.update(chunk);
            ch.send(&json!({ "t": "chunk", "data": b64(chunk) })).unwrap();
        }
        ch.send(&json!({ "t": "end", "sha256": hex(hash.finish().as_ref()) })).unwrap();
        assert_eq!(ch.recv().unwrap()["t"], "ok");
        let saved = wait_prompt("received");
        assert_eq!(std::fs::read(saved["path"].as_str().unwrap()).unwrap(), body);

        // Declined: nothing is written.
        let mut ch = session(&me).unwrap();
        ch.send(&json!({ "t": "file", "name": "no.txt", "size": 3 })).unwrap();
        let offer = wait_prompt("file");
        decide(offer["token"].as_str().unwrap(), false);
        assert_eq!(ch.recv().unwrap()["ok"], false);
        assert!(!downloads_dir().join("no.txt").exists());

        // A damaged transfer is thrown away.
        let mut ch = session(&me).unwrap();
        ch.send(&json!({ "t": "file", "name": "bad.bin", "size": 4 })).unwrap();
        decide(wait_prompt("file")["token"].as_str().unwrap(), true);
        assert_eq!(ch.recv().unwrap()["ok"], true);
        ch.send(&json!({ "t": "chunk", "data": b64(b"abcd") })).unwrap();
        ch.send(&json!({ "t": "end", "sha256": "00" })).unwrap();
        assert_eq!(ch.recv().unwrap()["t"], "error");
        assert!(!downloads_dir().join("bad.bin").exists());
    }

    #[test]
    fn pairing_needs_a_yes_on_both_screens() {
        let (port, key) = node();
        let me = Identity::generate().unwrap();
        let stream = TcpStream::connect(("127.0.0.1", port)).unwrap();
        stream.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
        let mut ch = wire::connect(stream, &me, "Pairer", "pair", None).unwrap();
        assert_eq!(ch.peer_key, key);
        let shown = wait_prompt("pair");
        assert_eq!(shown["code"], ch.code.as_str(), "both screens show the same code");
        decide(shown["token"].as_str().unwrap(), true);
        assert_eq!(ch.recv().unwrap()["ok"], true);
        ch.send(&json!({ "t": "pair", "ok": true })).unwrap();
        assert_eq!(wait_prompt("paired")["ok"], true);
        assert!(load_trusted().iter().any(|t| t.id == me.id()));
    }

    #[test]
    fn received_names_lose_their_path_and_bad_characters() {
        assert_eq!(safe_file_name("..\\..\\Windows\\evil.exe"), "evil.exe");
        assert_eq!(safe_file_name("/etc/passwd"), "passwd");
        assert_eq!(safe_file_name("in:fo?.txt"), "info.txt");
        assert_eq!(safe_file_name(".."), "file");
        assert_eq!(safe_file_name(""), "file");
    }

    #[test]
    fn a_beacon_must_match_its_key_and_not_be_ours() {
        let id = Identity::generate().unwrap();
        let good = json!({ "coucou": 1, "id": id.id(), "name": "Laura\u{7}", "port": 5000, "key": b64(&id.public()) }).to_string();
        let parsed = parse_beacon(good.as_bytes(), "someone-else").unwrap();
        assert_eq!(parsed.1, "Laura", "control characters are dropped");
        assert!(parse_beacon(good.as_bytes(), &id.id()).is_none(), "our own beacon");
        let lying = json!({ "coucou": 1, "id": "0011223344556677", "name": "x", "port": 5000, "key": b64(&id.public()) }).to_string();
        assert!(parse_beacon(lying.as_bytes(), "").is_none());
        let no_port = json!({ "coucou": 1, "id": id.id(), "name": "x", "port": 0, "key": b64(&id.public()) }).to_string();
        assert!(parse_beacon(no_port.as_bytes(), "").is_none());
    }

    #[test]
    fn a_taken_name_gets_a_number() {
        let dir = std::env::temp_dir().join(format!("coucou-lan-{}", wire::random_hex(4)));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("a.txt"), b"x").unwrap();
        assert_eq!(unique_path(&dir, "a.txt").file_name().unwrap(), "a (2).txt");
        let _ = std::fs::remove_dir_all(&dir);
    }
}
