// The Discord pill — port of DiscordService.swift and DiscordWebhook
// (docs/WINDOWS-PORT.md §5).
//
// 1. Mentions: macOS reads the Dock badge; Windows has nothing readable like it,
//    so the count is the DMs and mentions RPC delivered since launch.
// 2. Calls and DMs: Discord's local RPC pipe (`\\.\pipe\discord-ipc-N`, frames of
//    u32 op + u32 length, little endian, then JSON). It needs a Discord app of
//    the user's own (client id and secret in the Credential Manager) and one
//    approval in Discord; the tokens come back from discord.com and live in the
//    Credential Manager too, out of the settings window's reach. Then the pill
//    follows the voice channel, mutes and deafens on a click, and shows DMs and
//    mentions as they arrive.
// 3. A webhook: send-only, to the channel the user picked.
//
// The pipe is opened only while the pill is on, and only when it is served by
// a process of this same user (as orca.rs checks).

use std::collections::HashMap;
use std::sync::{Mutex, OnceLock};
use std::time::Duration;

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use tauri::{AppHandle, Emitter, Manager};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::windows::named_pipe::ClientOptions;
use tokio::sync::mpsc;

use crate::secrets;

const SCOPES: [&str; 5] = ["rpc", "rpc.voice.read", "rpc.voice.write", "rpc.notifications.read", "identify"];
const KEYRING_SERVICE: &str = "fr.louisraille.coucou";
const TASK_ID: &str = "integration_discord";
const VOICE_EVENTS: [&str; 5] = ["VOICE_STATE_CREATE", "VOICE_STATE_UPDATE", "VOICE_STATE_DELETE", "SPEAKING_START", "SPEAKING_STOP"];

// ── What the island sees ─────────────────────────────────────────────────────

#[derive(Serialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Member {
    pub id: String,
    pub name: String,
    pub muted: bool,
    pub deafened: bool,
}

#[derive(Serialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Voice {
    pub channel_id: String,
    pub name: String,
    pub members: Vec<Member>,
    pub speaking: Vec<String>,
}

#[derive(Serialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Note {
    pub id: String,
    pub channel_id: String,
    pub author: String,
    pub text: String,
    /// How Mochi reacts: confetti, hearts, laugh, question, fire — or none.
    pub reaction: Option<&'static str>,
}

#[derive(Serialize, Clone, Debug, Default, PartialEq)]
pub struct Device {
    pub id: String,
    pub name: String,
}

#[derive(Serialize, Clone, Debug, Default, PartialEq)]
pub struct Devices {
    pub inputs: Vec<Device>,
    pub outputs: Vec<Device>,
    pub input: String,
    pub output: String,
}

#[derive(Serialize, Clone, Debug, PartialEq)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum Link {
    NotSetUp,
    Offline,
    NeedsApproval,
    WaitingApproval,
    Connected { name: String },
    Failed { message: String },
}

#[derive(Serialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Snapshot {
    pub running: bool,
    pub link: Link,
    pub me: Option<String>,
    pub voice: Option<Voice>,
    pub self_mute: bool,
    pub self_deaf: bool,
    pub devices: Devices,
    pub notes: Vec<Note>,
    /// DMs and mentions since launch (Windows has no badge to read).
    pub unread: u32,
}

/// Settings → Discord, beside the keys (all automatic actions have a switch).
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase", default)]
pub struct DiscordPrefs {
    pub post_finished: bool,
    pub post_permission: bool,
    pub pause_spotify: bool,
    pub quiet_calls: bool,
    pub lock_mute: bool,
    pub presence: bool,
    pub muted_alert: bool,
}

impl Default for DiscordPrefs {
    fn default() -> Self {
        Self { post_finished: false, post_permission: false, pause_spotify: true, quiet_calls: true, lock_mute: true, presence: false, muted_alert: false }
    }
}

// ── The pure bits (DiscordParse) ─────────────────────────────────────────────

/// How Mochi reacts to a DM or mention: the first emoji or word that means
/// something to it, else a question when it ends in "?".
pub fn reaction(text: &str) -> Option<&'static str> {
    let t = text.to_lowercase();
    let table: [(&'static str, &[&str]); 4] = [
        ("confetti", &["🎉", "🥳", "🎊"]),
        ("hearts", &["❤️", "❤", "😍", "🥰", "💖", "💕", "<3"]),
        ("fire", &["🔥"]),
        ("laugh", &["😂", "🤣", "jaja", "jeje", "haha", "lol", "lmao", "kkkk"]),
    ];
    let mut best: Option<(&'static str, usize)> = None;
    for (r, keys) in table {
        for k in keys {
            if let Some(i) = t.find(k) {
                if best.is_none_or(|(_, b)| i < b) {
                    best = Some((r, i));
                }
            }
        }
    }
    if let Some((r, _)) = best {
        return Some(r);
    }
    t.trim().ends_with('?').then_some("question")
}

/// Only Discord's own webhook URLs, over https: the URL is the credential.
pub fn is_webhook(s: &str) -> bool {
    let Ok(u) = url::Url::parse(s.trim()) else { return false };
    let host = u.host_str().unwrap_or_default().to_lowercase();
    u.scheme() == "https"
        && ["discord.com", "discordapp.com", "ptb.discord.com", "canary.discord.com"].contains(&host.as_str())
        && u.path().starts_with("/api/webhooks/")
        && u.username().is_empty()
        && u.port().is_none()
}

fn one_line(s: &str, max: usize) -> String {
    s.split_whitespace().collect::<Vec<_>>().join(" ").chars().take(max).collect()
}

fn text(v: &Value, k: &str) -> Option<String> {
    v.get(k).and_then(Value::as_str).filter(|s| !s.is_empty()).map(str::to_string)
}

fn member(d: &Value) -> Option<Member> {
    let user = d.get("user")?;
    let id = text(user, "id")?;
    let st = d.get("voice_state").cloned().unwrap_or(Value::Null);
    let flag = |k: &str| st.get(k).and_then(Value::as_bool).unwrap_or(false);
    let name = text(d, "nick").or_else(|| text(user, "global_name")).or_else(|| text(user, "username")).unwrap_or_else(|| "?".into());
    Some(Member { id, name, muted: flag("self_mute") || flag("mute"), deafened: flag("self_deaf") || flag("deaf") })
}

fn devices(d: &Value) -> Option<Devices> {
    let (input, output) = (d.get("input")?, d.get("output")?);
    let list = |io: &Value| -> Vec<Device> {
        io.get("available_devices")
            .and_then(Value::as_array)
            .map(|a| {
                a.iter()
                    .filter_map(|dev| {
                        let id = text(dev, "id")?;
                        Some(Device { name: text(dev, "name").unwrap_or_else(|| id.clone()), id })
                    })
                    .collect()
            })
            .unwrap_or_default()
    };
    Some(Devices {
        inputs: list(input),
        outputs: list(output),
        input: text(input, "device_id").unwrap_or_default(),
        output: text(output, "device_id").unwrap_or_default(),
    })
}

// ── State ────────────────────────────────────────────────────────────────────

type Reply = Box<dyn FnOnce(Value) + Send>;

struct Inner {
    snap: Snapshot,
    out: Option<mpsc::UnboundedSender<Vec<u8>>>,
    connection: u64,
    ready: bool,
    wants_approval: bool,
    channel: Option<String>,
    nonce: u64,
    pending: HashMap<String, Reply>,
    activity: Option<(String, Option<String>)>,
    sent_activity: Option<String>,
    muted_by_lock: bool,
    locked: bool,
}

struct Discord {
    app: AppHandle,
    inner: Mutex<Inner>,
}

static DISCORD: OnceLock<Discord> = OnceLock::new();

fn get() -> Option<&'static Discord> {
    DISCORD.get()
}

fn keyring_get(key: &str) -> Option<String> {
    keyring::Entry::new(KEYRING_SERVICE, key).ok()?.get_password().ok().filter(|s| !s.is_empty())
}

fn keyring_set(key: &str, value: Option<&str>) {
    if let Ok(e) = keyring::Entry::new(KEYRING_SERVICE, key) {
        match value {
            Some(v) => {
                let _ = e.set_password(v);
            }
            None => {
                let _ = e.delete_credential();
            }
        }
    }
}

fn credentials() -> Option<(String, String)> {
    Some((secrets::get("discord-client-id")?, secrets::get("discord-client-secret")?))
}

fn prefs(app: &AppHandle) -> DiscordPrefs {
    app.state::<crate::Shared>().settings.lock().unwrap().discord.clone()
}

fn publish(d: &Discord, change: impl FnOnce(&mut Snapshot)) {
    let snap = {
        let mut inner = d.inner.lock().unwrap();
        let before = inner.snap.clone();
        change(&mut inner.snap);
        if inner.snap == before {
            return;
        }
        inner.snap.clone()
    };
    let _ = d.app.emit("discord-state", snap);
}

pub fn snapshot() -> Option<Snapshot> {
    Some(get()?.inner.lock().unwrap().snap.clone())
}

pub fn start(app: &AppHandle) {
    let _ = DISCORD.set(Discord {
        app: app.clone(),
        inner: Mutex::new(Inner {
            snap: Snapshot {
                running: false,
                link: Link::NotSetUp,
                me: None,
                voice: None,
                self_mute: false,
                self_deaf: false,
                devices: Devices::default(),
                notes: vec![],
                unread: 0,
            },
            out: None,
            connection: 0,
            ready: false,
            wants_approval: false,
            channel: None,
            nonce: 0,
            pending: HashMap::new(),
            activity: None,
            sent_activity: None,
            muted_by_lock: false,
            locked: false,
        }),
    });
    tauri::async_runtime::spawn(async {
        tokio::time::sleep(Duration::from_secs(3)).await;
        loop {
            let in_call = get().is_some_and(|d| d.inner.lock().unwrap().snap.voice.is_some());
            tick().await;
            // While in a call, every 2 s (the lock check); otherwise every 5 s.
            tokio::time::sleep(Duration::from_secs(if in_call { 2 } else { 5 })).await;
        }
    });
}

fn discord_running() -> bool {
    let names = crate::jump::process_names();
    ["discord.exe", "discordptb.exe", "discordcanary.exe"].iter().any(|n| names.contains(*n))
}

async fn tick() {
    let Some(d) = get() else { return };
    let on = crate::integrations::is_enabled(&d.app, TASK_ID) && !crate::integrations::PAUSED.load(std::sync::atomic::Ordering::Relaxed);
    let running = tauri::async_runtime::spawn_blocking(discord_running).await.unwrap_or(false);
    if !on || !running {
        disconnect(d);
        publish(d, |s| {
            s.running = running;
            s.voice = None;
            if matches!(s.link, Link::Connected { .. }) {
                s.link = Link::Offline;
            }
        });
        return;
    }
    publish(d, |s| s.running = true);
    let (connected, wants) = {
        let inner = d.inner.lock().unwrap();
        (inner.out.is_some(), inner.wants_approval)
    };
    if credentials().is_none() {
        publish(d, |s| s.link = Link::NotSetUp);
    } else if !connected && (keyring_get("discord-access-token").is_some() || wants) {
        connect(d).await;
    } else if !connected {
        publish(d, |s| s.link = Link::NeedsApproval);
    }
    check_lock(d);
}

// ── The pipe ─────────────────────────────────────────────────────────────────

fn frame(op: u32, payload: &Value) -> Vec<u8> {
    let body = payload.to_string().into_bytes();
    let mut f = Vec::with_capacity(8 + body.len());
    f.extend_from_slice(&op.to_le_bytes());
    f.extend_from_slice(&(body.len() as u32).to_le_bytes());
    f.extend_from_slice(&body);
    f
}

async fn connect(d: &'static Discord) {
    let Some((client_id, _)) = credentials() else { return };
    for i in 0..10 {
        let Ok(client) = ClientOptions::new().open(format!(r"\\.\pipe\discord-ipc-{i}")) else { continue };
        {
            use std::os::windows::io::AsRawHandle;
            let handle = windows::Win32::Foundation::HANDLE(client.as_raw_handle());
            if !crate::win_user::pipe_server_is_same_user(handle) {
                continue;
            }
        }
        let (mut rd, mut wr) = tokio::io::split(client);
        let (tx, mut rx) = mpsc::unbounded_channel::<Vec<u8>>();
        let conn = {
            let mut inner = d.inner.lock().unwrap();
            inner.connection += 1;
            inner.out = Some(tx.clone());
            inner.ready = false;
            inner.connection
        };
        let _ = tx.send(frame(0, &json!({ "v": 1, "client_id": client_id })));
        tauri::async_runtime::spawn(async move {
            while let Some(f) = rx.recv().await {
                if wr.write_all(&f).await.is_err() {
                    break;
                }
            }
        });
        tauri::async_runtime::spawn(async move {
            let mut header = [0u8; 8];
            loop {
                if rd.read_exact(&mut header).await.is_err() {
                    break;
                }
                let op = u32::from_le_bytes(header[..4].try_into().unwrap());
                let len = u32::from_le_bytes(header[4..].try_into().unwrap()) as usize;
                if len > 4_000_000 {
                    break;
                }
                let mut body = vec![0u8; len];
                if rd.read_exact(&mut body).await.is_err() {
                    break;
                }
                let json: Value = serde_json::from_slice(&body).unwrap_or(Value::Null);
                match op {
                    1 => handle(d, conn, json),
                    3 => send_raw(d, frame(4, &json)), // ping → pong
                    2 => {
                        // Discord closed us, with a reason (a bad client id, say).
                        let why = text(&json, "message").unwrap_or_else(|| "Discord closed the connection.".into());
                        disconnect(d);
                        d.inner.lock().unwrap().wants_approval = false;
                        publish(d, |s| s.link = Link::Failed { message: why });
                        return;
                    }
                    _ => {}
                }
            }
            let mine = d.inner.lock().unwrap().connection == conn;
            if mine {
                disconnect(d);
                publish(d, |s| {
                    s.voice = None;
                    if matches!(s.link, Link::Connected { .. }) {
                        s.link = Link::Offline;
                    }
                });
            }
        });
        return;
    }
    publish(d, |s| s.link = Link::Offline);
}

fn disconnect(d: &Discord) {
    let mut inner = d.inner.lock().unwrap();
    inner.out = None;
    inner.ready = false;
    inner.channel = None;
    inner.pending.clear();
    inner.sent_activity = None;
    inner.connection += 1;
    inner.snap.me = None;
}

fn send_raw(d: &Discord, bytes: Vec<u8>) {
    if let Some(tx) = &d.inner.lock().unwrap().out {
        let _ = tx.send(bytes);
    }
}

/// One command; `reply` gets the whole response frame (check `evt == "ERROR"`).
fn send(d: &Discord, cmd: &str, args: Value, evt: Option<&str>, reply: Option<Reply>) {
    let bytes = {
        let mut inner = d.inner.lock().unwrap();
        if inner.out.is_none() {
            return;
        }
        inner.nonce += 1;
        let n = format!("coucou-{}", inner.nonce);
        let mut f = json!({ "cmd": cmd, "args": args, "nonce": n });
        if let Some(evt) = evt {
            f["evt"] = json!(evt);
        }
        if let Some(reply) = reply {
            inner.pending.insert(n, reply);
        }
        frame(1, &f)
    };
    send_raw(d, bytes);
}

fn handle(d: &'static Discord, conn: u64, f: Value) {
    if d.inner.lock().unwrap().connection != conn {
        return;
    }
    if let Some(n) = f.get("nonce").and_then(Value::as_str) {
        let reply = d.inner.lock().unwrap().pending.remove(n);
        if let Some(reply) = reply {
            reply(f);
            return;
        }
    }
    if f.get("cmd").and_then(Value::as_str) != Some("DISPATCH") {
        return;
    }
    let data = f.get("data").cloned().unwrap_or(Value::Null);
    match f.get("evt").and_then(Value::as_str).unwrap_or_default() {
        "READY" => {
            let wants = {
                let mut inner = d.inner.lock().unwrap();
                inner.ready = true;
                inner.wants_approval
            };
            push_activity(d);
            match keyring_get("discord-access-token") {
                Some(token) if !wants => authenticate(d, token, false),
                _ if wants => authorize(d),
                _ => {}
            }
        }
        "VOICE_CHANNEL_SELECT" => follow(d, text(&data, "channel_id")),
        "VOICE_STATE_CREATE" | "VOICE_STATE_UPDATE" => {
            if let Some(m) = member(&data) {
                publish(d, |s| {
                    if let Some(v) = &mut s.voice {
                        match v.members.iter_mut().find(|x| x.id == m.id) {
                            Some(x) => *x = m,
                            None => v.members.push(m),
                        }
                    }
                });
            }
        }
        "VOICE_STATE_DELETE" => {
            let id = data.pointer("/user/id").and_then(Value::as_str).unwrap_or_default().to_string();
            publish(d, |s| {
                if let Some(v) = &mut s.voice {
                    v.members.retain(|m| m.id != id);
                    v.speaking.retain(|x| *x != id);
                }
            });
        }
        "SPEAKING_START" | "SPEAKING_STOP" => {
            let Some(id) = text(&data, "user_id") else { return };
            let on = f.get("evt").and_then(Value::as_str) == Some("SPEAKING_START");
            publish(d, |s| {
                if let Some(v) = &mut s.voice {
                    v.speaking.retain(|x| *x != id);
                    if on {
                        v.speaking.push(id);
                    }
                }
            });
        }
        "VOICE_SETTINGS_UPDATE" => {
            let mute = data.get("mute").and_then(Value::as_bool);
            let deaf = data.get("deaf").and_then(Value::as_bool);
            let devs = devices(&data);
            publish(d, |s| {
                if let Some(m) = mute {
                    s.self_mute = m;
                }
                if let Some(x) = deaf {
                    s.self_deaf = x;
                }
                if let Some(devs) = devs {
                    s.devices = devs;
                }
            });
        }
        "NOTIFICATION_CREATE" => {
            let message = data.get("message").cloned().unwrap_or(Value::Null);
            let author = message.get("author").cloned().unwrap_or(Value::Null);
            let name = text(&author, "global_name")
                .or_else(|| text(&author, "username"))
                .or_else(|| text(&data, "title"))
                .unwrap_or_else(|| "Discord".into());
            let body = text(&message, "content").or_else(|| text(&data, "body")).unwrap_or_default();
            let note = Note {
                id: text(&message, "id").unwrap_or_else(|| crate::lan::wire::random_hex(8)),
                channel_id: text(&data, "channel_id").unwrap_or_default(),
                author: one_line(&name, 60),
                reaction: reaction(&body),
                text: one_line(&body, 140),
            };
            publish(d, |s| {
                s.notes.insert(0, note);
                s.notes.truncate(5);
                s.unread += 1;
            });
        }
        _ => {}
    }
}

fn error_message(f: &Value) -> String {
    let message = f.pointer("/data/message").and_then(Value::as_str).unwrap_or("Discord refused.").to_string();
    // RPC is in a closed beta: Discord grants it to the app's owner and testers.
    if message.to_lowercase().contains("scope") {
        format!("Discord refused the scopes ({message}). The app must be yours, or list you as an App Tester.")
    } else {
        message
    }
}

fn authorize(d: &'static Discord) {
    let Some((client_id, secret)) = credentials() else { return };
    d.inner.lock().unwrap().wants_approval = false;
    publish(d, |s| s.link = Link::WaitingApproval);
    let reply: Reply = Box::new(move |f: Value| {
        let code = f.pointer("/data/code").and_then(Value::as_str).map(str::to_string);
        let Some(code) = code.filter(|_| f.get("evt").and_then(Value::as_str) != Some("ERROR")) else {
            let why = error_message(&f);
            publish(d, |s| s.link = Link::Failed { message: why });
            return;
        };
        tauri::async_runtime::spawn(async move {
            match token(&[("grant_type", "authorization_code"), ("code", &code)], &client_id, &secret).await {
                Ok(t) => authenticate(d, t, false),
                Err(why) => publish(d, |s| s.link = Link::Failed { message: why }),
            }
        });
    });
    send(d, "AUTHORIZE", json!({ "client_id": credentials().map(|c| c.0), "scopes": SCOPES }), None, Some(reply));
}

fn authenticate(d: &'static Discord, access: String, retried: bool) {
    let reply: Reply = Box::new(move |f: Value| {
        if f.get("evt").and_then(Value::as_str) == Some("ERROR") {
            // Expired or revoked: one refresh, else the user approves again.
            let refresh = keyring_get("discord-refresh-token");
            match (retried, credentials(), refresh) {
                (false, Some((id, secret)), Some(refresh)) => {
                    tauri::async_runtime::spawn(async move {
                        match token(&[("grant_type", "refresh_token"), ("refresh_token", &refresh)], &id, &secret).await {
                            Ok(t) => authenticate(d, t, true),
                            Err(_) => {
                                keyring_set("discord-access-token", None);
                                publish(d, |s| s.link = Link::NeedsApproval);
                            }
                        }
                    });
                }
                _ => {
                    keyring_set("discord-access-token", None);
                    publish(d, |s| s.link = Link::NeedsApproval);
                }
            }
            return;
        }
        let user = f.pointer("/data/user").cloned().unwrap_or(Value::Null);
        let me = text(&user, "id");
        let name = text(&user, "global_name").or_else(|| text(&user, "username")).unwrap_or_default();
        publish(d, |s| {
            s.link = Link::Connected { name };
            s.me = me;
        });
        for evt in ["VOICE_CHANNEL_SELECT", "VOICE_SETTINGS_UPDATE", "NOTIFICATION_CREATE"] {
            send(d, "SUBSCRIBE", json!({}), Some(evt), None);
        }
        send(d, "GET_VOICE_SETTINGS", json!({}), None, Some(Box::new(move |f: Value| {
            let data = f.get("data").cloned().unwrap_or(Value::Null);
            let devs = devices(&data);
            publish(d, |s| {
                s.self_mute = data.get("mute").and_then(Value::as_bool).unwrap_or(false);
                s.self_deaf = data.get("deaf").and_then(Value::as_bool).unwrap_or(false);
                if let Some(devs) = devs {
                    s.devices = devs;
                }
            });
        })));
        send(d, "GET_SELECTED_VOICE_CHANNEL", json!({}), None, Some(Box::new(move |f: Value| {
            follow(d, f.pointer("/data/id").and_then(Value::as_str).map(str::to_string));
        })));
    });
    send(d, "AUTHENTICATE", json!({ "access_token": access }), None, Some(reply));
}

/// Subscribes to the voice channel's events (and drops the previous one's).
fn follow(d: &'static Discord, id: Option<String>) {
    let old = d.inner.lock().unwrap().channel.clone();
    if let Some(old) = old.filter(|o| Some(o) != id.as_ref()) {
        for evt in VOICE_EVENTS {
            send(d, "UNSUBSCRIBE", json!({ "channel_id": old }), Some(evt), None);
        }
    }
    d.inner.lock().unwrap().channel = id.clone();
    let Some(id) = id else {
        publish(d, |s| s.voice = None);
        return;
    };
    for evt in VOICE_EVENTS {
        send(d, "SUBSCRIBE", json!({ "channel_id": id }), Some(evt), None);
    }
    let channel = id.clone();
    send(d, "GET_CHANNEL", json!({ "channel_id": id }), None, Some(Box::new(move |f: Value| {
        let data = f.get("data").cloned().unwrap_or(Value::Null);
        let members = data.get("voice_states").and_then(Value::as_array).map(|a| a.iter().filter_map(member).collect()).unwrap_or_default();
        let voice = Voice { channel_id: channel, name: text(&data, "name").unwrap_or_default(), members, speaking: vec![] };
        publish(d, |s| s.voice = Some(voice));
    })));
}

/// The OAuth token exchange (code or refresh); stores both tokens on success.
async fn token(grant: &[(&str, &str)], client_id: &str, secret: &str) -> Result<String, String> {
    let http = reqwest::Client::builder()
        .timeout(Duration::from_secs(15))
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .map_err(|e| e.to_string())?;
    let mut form: Vec<(&str, &str)> = grant.to_vec();
    form.push(("client_id", client_id));
    form.push(("client_secret", secret));
    let post = |form: Vec<(&str, &str)>| {
        let http = http.clone();
        let owned: Vec<(String, String)> = form.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect();
        async move {
            let r = http.post("https://discord.com/api/oauth2/token").form(&owned).send().await.ok()?;
            let status = r.status().as_u16();
            Some((status, r.json::<Value>().await.unwrap_or(Value::Null)))
        }
    };
    let (mut status, mut body) = post(form.clone()).await.ok_or("discord.com can't be reached.")?;
    // Some apps want the redirect the code was issued for: the one Settings asks to add.
    let is_code = grant.iter().any(|(k, v)| *k == "grant_type" && *v == "authorization_code");
    if status == 400 && is_code && text(&body, "error_description").unwrap_or_default().contains("redirect") {
        form.push(("redirect_uri", "http://127.0.0.1"));
        if let Some(again) = post(form).await {
            (status, body) = again;
        }
    }
    let Some(access) = text(&body, "access_token").filter(|_| status == 200) else {
        return Err(text(&body, "error_description").or_else(|| text(&body, "error")).unwrap_or_else(|| format!("HTTP {status}")));
    };
    keyring_set("discord-access-token", Some(&access));
    if let Some(refresh) = text(&body, "refresh_token") {
        keyring_set("discord-refresh-token", Some(&refresh));
    }
    Ok(access)
}

// ── Lock mute ────────────────────────────────────────────────────────────────

/// Is the workstation locked? The input desktop can't be switched to then.
fn is_locked() -> bool {
    use windows::Win32::System::StationsAndDesktops::{CloseDesktop, OpenInputDesktop, SwitchDesktop, DESKTOP_ACCESS_FLAGS, DESKTOP_CONTROL_FLAGS};
    unsafe {
        match OpenInputDesktop(DESKTOP_CONTROL_FLAGS(0), false, DESKTOP_ACCESS_FLAGS(0x0100)) {
            Ok(h) => {
                let switchable = SwitchDesktop(h).is_ok();
                let _ = CloseDesktop(h);
                !switchable
            }
            Err(_) => true,
        }
    }
}

/// Locking the screen during a call mutes; unlocking unmutes, only if the lock muted.
fn check_lock(d: &'static Discord) {
    let (in_call, muted, was_locked) = {
        let inner = d.inner.lock().unwrap();
        (inner.snap.voice.is_some(), inner.snap.self_mute, inner.locked)
    };
    if !in_call || !prefs(&d.app).lock_mute {
        d.inner.lock().unwrap().locked = false;
        return;
    }
    let locked = is_locked();
    if locked == was_locked {
        return;
    }
    let mut inner = d.inner.lock().unwrap();
    inner.locked = locked;
    if locked && !muted {
        inner.muted_by_lock = true;
        drop(inner);
        set_mute(true);
    } else if !locked && inner.muted_by_lock {
        inner.muted_by_lock = false;
        drop(inner);
        set_mute(false);
        let _ = d.app.emit("discord-toast", json!({ "text": "Mic back on", "color": "#23A55A" }));
    }
}

// ── Actions (all on a click, or an opt-in) ──────────────────────────────────

/// "Connect to Discord": opens the approval window in the Discord app.
pub fn request_approval() {
    let Some(d) = get() else { return };
    let ready = {
        let mut inner = d.inner.lock().unwrap();
        inner.wants_approval = true;
        inner.out.is_some() && inner.ready
    };
    if ready {
        authorize(d);
    } else {
        disconnect(d);
        tauri::async_runtime::spawn(connect(d));
    }
}

pub fn sign_out() {
    let Some(d) = get() else { return };
    keyring_set("discord-access-token", None);
    keyring_set("discord-refresh-token", None);
    disconnect(d);
    publish(d, |s| {
        s.link = Link::NeedsApproval;
        s.voice = None;
        s.notes.clear();
    });
}

pub fn set_mute(on: bool) {
    if let Some(d) = get() {
        send(d, "SET_VOICE_SETTINGS", json!({ "mute": on }), None, None);
    }
}

pub fn set_deaf(on: bool) {
    if let Some(d) = get() {
        send(d, "SET_VOICE_SETTINGS", json!({ "deaf": on }), None, None);
    }
}

pub fn set_device(output: bool, id: &str) {
    if let Some(d) = get() {
        let key = if output { "output" } else { "input" };
        send(d, "SET_VOICE_SETTINGS", json!({ key: { "device_id": id } }), None, None);
    }
}

/// Discord to the front, on that channel when the pipe is up.
pub fn open(channel: Option<String>) {
    let _ = std::process::Command::new("explorer").arg("discord://").spawn();
    if let (Some(d), Some(ch)) = (get(), channel.filter(|c| c.chars().all(|x| x.is_ascii_digit()) && !c.is_empty())) {
        send(d, "SELECT_TEXT_CHANNEL", json!({ "channel_id": ch }), None, None);
        publish(d, |s| s.unread = 0);
    } else if let Some(d) = get() {
        publish(d, |s| s.unread = 0);
    }
}

/// Rich Presence (opt-in): details and state lines; None clears.
pub fn set_activity(activity: Option<(String, Option<String>)>) {
    if let Some(d) = get() {
        d.inner.lock().unwrap().activity = activity;
        push_activity(d);
    }
}

/// Sends the wanted activity once per change (Discord rate-limits it).
fn push_activity(d: &Discord) {
    let args = {
        let mut inner = d.inner.lock().unwrap();
        if inner.out.is_none() || !inner.ready {
            return;
        }
        let key = inner.activity.as_ref().map(|(a, b)| format!("{a}|{}", b.as_deref().unwrap_or(""))).unwrap_or_default();
        if inner.sent_activity.as_deref() == Some(key.as_str()) {
            return;
        }
        inner.sent_activity = Some(key);
        let mut args = json!({ "pid": std::process::id() });
        if let Some((details, state)) = &inner.activity {
            let mut a = json!({ "details": details.chars().take(120).collect::<String>() });
            if let Some(state) = state {
                a["state"] = json!(state.chars().take(120).collect::<String>());
            }
            args["activity"] = a;
        }
        args
    };
    send(d, "SET_ACTIVITY", args, None, None);
}

// ── Webhook ──────────────────────────────────────────────────────────────────

pub const MAX_FILE: u64 = 10 * 1024 * 1024;

/// Posts a message, with a file if given. No @everyone, @here or role pings.
pub async fn webhook_send(message: &str, file: Option<std::path::PathBuf>) -> Result<(), String> {
    let url = secrets::get("discord-webhook").filter(|u| is_webhook(u)).ok_or("No Discord webhook in Settings.")?;
    let payload = json!({ "content": message.chars().take(1900).collect::<String>(), "allowed_mentions": { "parse": [] } });
    let http = reqwest::Client::builder()
        .timeout(Duration::from_secs(60))
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .map_err(|e| e.to_string())?;
    let request = match file {
        Some(path) => {
            let size = std::fs::metadata(&path).map_err(|e| e.to_string())?.len();
            if size > MAX_FILE {
                return Err("Discord takes files up to 10 MB.".into());
            }
            let bytes = std::fs::read(&path).map_err(|_| "The file can't be read.".to_string())?;
            let name = crate::lan::safe_file_name(&path.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default());
            // multipart/form-data by hand: payload_json + files[0].
            let boundary = format!("coucou-{}", crate::lan::wire::random_hex(12));
            let mut body = Vec::with_capacity(bytes.len() + 512);
            body.extend_from_slice(format!("--{boundary}\r\nContent-Disposition: form-data; name=\"payload_json\"\r\nContent-Type: application/json\r\n\r\n{payload}\r\n").as_bytes());
            body.extend_from_slice(format!("--{boundary}\r\nContent-Disposition: form-data; name=\"files[0]\"; filename=\"{name}\"\r\nContent-Type: application/octet-stream\r\n\r\n").as_bytes());
            body.extend_from_slice(&bytes);
            body.extend_from_slice(format!("\r\n--{boundary}--\r\n").as_bytes());
            http.post(&url).header("content-type", format!("multipart/form-data; boundary={boundary}")).body(body)
        }
        None => http.post(&url).json(&payload),
    };
    let r = request.send().await.map_err(|_| "discord.com can't be reached.".to_string())?;
    if r.status().is_success() {
        Ok(())
    } else {
        Err(format!("Discord: HTTP {}", r.status().as_u16()))
    }
}

/// Claude Code events the user opted into (Settings, off by default): the
/// project and the tool name only — commands can carry tokens.
pub fn notify_hook(app: &AppHandle, event: &str, payload: &Value) {
    let p = prefs(app);
    let wanted = match event {
        "Stop" => p.post_finished,
        "PermissionRequest" => p.post_permission,
        _ => false,
    };
    if !wanted || secrets::get("discord-webhook").is_none() {
        return;
    }
    let project = payload
        .get("cwd")
        .and_then(Value::as_str)
        .and_then(|c| c.trim_end_matches(['\\', '/']).rsplit(['\\', '/']).next())
        .unwrap_or("Session")
        .to_string();
    let agent = match payload.get("coucou_agent").and_then(Value::as_str) {
        Some("codex") => "Codex",
        Some("opencode") => "opencode",
        _ => "Claude Code",
    };
    let line = if event == "Stop" {
        let summary = payload.get("summary").and_then(Value::as_str).map(|s| format!("\n> {}", one_line(s, 300))).unwrap_or_default();
        format!("✅ **{project}** — {agent} finished{summary}")
    } else {
        let tool = payload.get("tool_name").and_then(Value::as_str).unwrap_or("a tool");
        format!("⏳ **{project}** — {agent} asks to use {}", one_line(tool, 60))
    };
    tauri::async_runtime::spawn(async move {
        if let Err(e) = webhook_send(&line, None).await {
            crate::log::line(format!("discord webhook: {e}"));
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_discords_own_https_webhooks_count() {
        assert!(is_webhook("https://discord.com/api/webhooks/123/abc"));
        assert!(is_webhook("https://ptb.discord.com/api/webhooks/1/x"));
        for bad in [
            "http://discord.com/api/webhooks/1/x",
            "https://discord.com.evil.io/api/webhooks/1/x",
            "https://evil.io/discord.com/api/webhooks/1/x",
            "https://discord.com/api/channels/1",
            "https://user@discord.com/api/webhooks/1/x",
            "https://discord.com:8443/api/webhooks/1/x",
            "",
        ] {
            assert!(!is_webhook(bad), "{bad}");
        }
    }

    #[test]
    fn mochi_reacts_to_the_first_thing_that_means_something() {
        assert_eq!(reaction("ganamos 🎉🔥"), Some("confetti"));
        assert_eq!(reaction("🔥 y 🎉"), Some("fire"));
        assert_eq!(reaction("jajaja ok"), Some("laugh"));
        assert_eq!(reaction("te quiero <3"), Some("hearts"));
        assert_eq!(reaction("¿vienes?"), Some("question"));
        assert_eq!(reaction("ok"), None);
    }

    #[test]
    fn members_and_devices_are_read_from_rpc_payloads() {
        let m = member(&json!({ "nick": "", "user": { "id": "7", "global_name": "Ana", "username": "ana" },
                                "voice_state": { "self_mute": true } })).unwrap();
        assert_eq!((m.name.as_str(), m.muted, m.deafened), ("Ana", true, false));
        let d = devices(&json!({ "input": { "device_id": "a", "available_devices": [{ "id": "a", "name": "Mic" }] },
                                 "output": { "device_id": "b", "available_devices": [] } })).unwrap();
        assert_eq!(d.inputs[0].name, "Mic");
        assert_eq!(d.output, "b");
    }
}
