// Named-pipe server for coucou-hook.
//
// `\\.\pipe\coucou-<sid>` — one instance per connection. Every hook event is
// forwarded to the island as a `hook` event. `PermissionRequest` is the only one
// that keeps its connection open: it waits for the island's decision and writes
// it back on the same pipe, which is how approving from the island works.
//
// Claude Code is never blocked by us. Three things guarantee it:
//   * coucou-hook gives the connection 300 ms and exits cleanly if we are closed;
//   * we only wait for a human once the island has *confirmed* the card is on
//     screen, so a paused island or a webview that is not listening costs a few
//     hundred milliseconds, not two minutes;
//   * whatever happens we drop the connection after the decision timeout, and
//     the terminal takes over.
//
// What we write back is the bare word `allow` or `deny`. Turning that into the
// documented hookSpecificOutput JSON is coucou-hook's job, so the wire format
// Claude Code expects lives in exactly one place.

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde_json::{json, Value};
use tauri::{AppHandle, Emitter, Manager};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::windows::named_pipe::{NamedPipeServer, ServerOptions};
use tokio::sync::{mpsc, Semaphore};
use windows::core::PCWSTR;
use windows::Win32::Foundation::{LocalFree, HLOCAL};
use windows::Win32::Security::Authorization::{
    ConvertStringSecurityDescriptorToSecurityDescriptorW, SDDL_REVISION_1,
};
use windows::Win32::Security::{PSECURITY_DESCRIPTOR, SECURITY_ATTRIBUTES};

use crate::island::WINDOW_LABEL;
use crate::log;

/// Slightly under coucou-hook's own 110 s wait, so we always answer first.
const DECISION_TIMEOUT: Duration = Duration::from_secs(108);
/// How long the island gets to say "the card is up". This is the whole of B4:
/// without it, an island that is paused, hidden behind a crashed webview or
/// simply not listening would leave Claude Code staring at a prompt nobody can
/// see for nearly two minutes.
const ACK_TIMEOUT: Duration = Duration::from_millis(800);
const MAX_PAYLOAD: usize = 1 << 20;
/// coucou-hook writes its whole line straight after connecting. A client that
/// connects and then says nothing is not a hook, and must not hold a task open.
const READ_TIMEOUT: Duration = Duration::from_secs(5);
/// Connections served at once. Each PermissionRequest holds one for up to
/// DECISION_TIMEOUT; anything past this is dropped rather than queued, so a
/// flood of connections cannot exhaust handles or memory.
const MAX_CONNECTIONS: usize = 64;

/// What the island can say about a permission request.
pub enum Reply {
    /// The card is on screen and a human can act on it.
    Ack,
    /// A human clicked: `allow` or `deny`.
    Decision(String),
    /// Nobody can act on it — paused, or another request already holds the card.
    Decline,
}

/// Permission requests the island has been told about.
#[derive(Default)]
pub struct Pending(pub Mutex<HashMap<String, mpsc::Sender<Reply>>>);

static COUNTER: AtomicU64 = AtomicU64::new(1);

/// `\\.\pipe\coucou-<sid>` — must match coucou-hook's `pipe_path()` exactly.
pub fn pipe_name() -> String {
    let key = crate::win_user::current_user_sid()
        .unwrap_or_else(|| std::env::var("USERNAME").unwrap_or_else(|_| "user".into()));
    format!(r"\\.\pipe\coucou-{key}")
}

/// The pipe's DACL: full access for our own account and for SYSTEM, nothing for
/// anybody else. Without it the pipe gets the default descriptor, which lets
/// Everyone and the anonymous account open it for reading — enough for another
/// account on this machine to connect and tie up instances.
fn pipe_sddl(sid: &str) -> String {
    format!("D:P(A;;GA;;;{sid})(A;;GA;;;SY)")
}

/// Creates one pipe instance that only our own account can open.
/// Fails closed: no SID or no descriptor means no pipe, never a default one.
fn create_instance(name: &str, first: bool) -> std::io::Result<NamedPipeServer> {
    let sid = crate::win_user::current_user_sid()
        .ok_or_else(|| std::io::Error::other("cannot read our own SID"))?;
    let sddl: Vec<u16> = pipe_sddl(&sid).encode_utf16().chain(std::iter::once(0)).collect();

    let mut descriptor = PSECURITY_DESCRIPTOR::default();
    unsafe {
        ConvertStringSecurityDescriptorToSecurityDescriptorW(
            PCWSTR(sddl.as_ptr()),
            SDDL_REVISION_1,
            &mut descriptor,
            None,
        )
    }
    .map_err(|e| std::io::Error::other(format!("pipe security descriptor: {e}")))?;

    let mut attributes = SECURITY_ATTRIBUTES {
        nLength: std::mem::size_of::<SECURITY_ATTRIBUTES>() as u32,
        lpSecurityDescriptor: descriptor.0,
        bInheritHandle: false.into(),
    };
    let mut options = ServerOptions::new();
    // first_pipe_instance also means we refuse to join a pipe somebody else
    // already owns under our name, rather than serving on top of it.
    options.first_pipe_instance(first).reject_remote_clients(true);
    // SAFETY: `attributes` is a valid SECURITY_ATTRIBUTES whose descriptor stays
    // alive until after the call returns; CreateNamedPipeW copies it.
    let result = unsafe {
        options.create_with_security_attributes_raw(name, (&mut attributes as *mut SECURITY_ATTRIBUTES).cast())
    };
    unsafe {
        let _ = LocalFree(Some(HLOCAL(descriptor.0)));
    }
    result
}

pub fn start(app: AppHandle) {
    tauri::async_runtime::spawn(async move {
        let name = pipe_name();
        let mut server = match create_instance(&name, true) {
            Ok(s) => s,
            Err(err) => {
                log::line(format!("cannot open the relay pipe: {err}"));
                return;
            }
        };
        let slots = Arc::new(Semaphore::new(MAX_CONNECTIONS));
        loop {
            if server.connect().await.is_err() {
                tokio::time::sleep(Duration::from_millis(200)).await;
                continue;
            }
            // Hand the connected instance to a task and listen on a fresh one.
            let next = match create_instance(&name, false) {
                Ok(s) => s,
                Err(err) => {
                    log::line(format!("cannot reopen the relay pipe: {err}"));
                    return;
                }
            };
            let connected = std::mem::replace(&mut server, next);
            let Ok(slot) = slots.clone().try_acquire_owned() else {
                // Full: drop this one. The relay exits 0 and Claude Code carries on.
                let _ = connected.disconnect();
                continue;
            };
            let app = app.clone();
            tauri::async_runtime::spawn(async move {
                handle(app, connected).await;
                drop(slot);
            });
        }
    });
}

/// Reads one line, under READ_TIMEOUT and MAX_PAYLOAD.
async fn read_line(pipe: &mut NamedPipeServer) -> Option<Vec<u8>> {
    let mut buf = Vec::new();
    let mut chunk = [0u8; 4096];
    let read = async {
        loop {
            match pipe.read(&mut chunk).await {
                Ok(0) => return true,
                Ok(n) => {
                    buf.extend_from_slice(&chunk[..n]);
                    if buf.contains(&b'\n') {
                        return true;
                    }
                    // Oversized: refuse it rather than parse a cut-off line.
                    if buf.len() > MAX_PAYLOAD {
                        return false;
                    }
                }
                Err(_) => return false,
            }
        }
    };
    match tokio::time::timeout(READ_TIMEOUT, read).await {
        Ok(true) => {}
        _ => return None,
    }
    let end = buf.iter().position(|b| *b == b'\n').unwrap_or(buf.len());
    buf.truncate(end);
    Some(buf)
}

async fn handle(app: AppHandle, mut pipe: NamedPipeServer) {
    let Some(line) = read_line(&mut pipe).await else {
        let _ = pipe.disconnect();
        return;
    };
    let Ok(mut payload) = serde_json::from_slice::<Value>(&line) else { return };
    let Some(map) = payload.as_object_mut() else { return };
    // `request_id` is ours to assign. One arriving on the wire could otherwise
    // be used to answer or release somebody else's pending request.
    map.remove("request_id");

    let event = payload
        .get("hook_event_name")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string();

    if event != "PermissionRequest" {
        log::line(format!("hook {event}"));
        let _ = app.emit_to(WINDOW_LABEL, "hook", payload);
        let _ = pipe.disconnect();
        return;
    }

    let id = format!("{}-{}", std::process::id(), COUNTER.fetch_add(1, Ordering::Relaxed));
    let (tx, mut rx) = mpsc::channel::<Reply>(4);
    {
        let pending = app.state::<Pending>();
        pending.0.lock().unwrap().insert(id.clone(), tx);
    }
    payload["request_id"] = json!(id);
    log::line(format!("hook PermissionRequest id={id}"));
    let _ = app.emit_to(WINDOW_LABEL, "hook", payload);

    let decision = wait_for_decision(&id, &mut rx).await;
    app.state::<Pending>().0.lock().unwrap().remove(&id);

    // No decision: say nothing at all. coucou-hook then writes nothing to stdout
    // and Claude Code asks in the terminal, exactly as if Coucou were closed.
    if let Some(d) = decision {
        let _ = pipe.write_all(format!("{d}\n").as_bytes()).await;
        let _ = pipe.flush().await;
    }
    let _ = pipe.disconnect();
}

/// Two waits: a short one for "the card is up", then the long one for a human.
async fn wait_for_decision(id: &str, rx: &mut mpsc::Receiver<Reply>) -> Option<String> {
    match tokio::time::timeout(ACK_TIMEOUT, rx.recv()).await {
        Ok(Some(Reply::Ack)) => {}
        // A click that beats the ack is still a click.
        Ok(Some(Reply::Decision(d))) => {
            log::line(format!("hook id={id} answered {d}"));
            return Some(d);
        }
        Ok(Some(Reply::Decline)) => {
            log::line(format!("hook id={id} not shown — terminal takes over"));
            return None;
        }
        Ok(None) => return None,
        Err(_) => {
            log::line(format!("hook id={id} island never acknowledged — terminal takes over"));
            return None;
        }
    }

    match tokio::time::timeout(DECISION_TIMEOUT, rx.recv()).await {
        Ok(Some(Reply::Decision(d))) => {
            log::line(format!("hook id={id} answered {d}"));
            Some(d)
        }
        Ok(Some(Reply::Decline)) => {
            log::line(format!("hook id={id} released without a decision"));
            None
        }
        _ => {
            log::line(format!("hook id={id} timed out — terminal takes over"));
            None
        }
    }
}

fn send(app: &AppHandle, request_id: &str, reply: Reply, keep: bool) {
    let sender = {
        let pending = app.state::<Pending>();
        let mut map = pending.0.lock().unwrap();
        if keep { map.get(request_id).cloned() } else { map.remove(request_id) }
    };
    match sender {
        Some(tx) => {
            let _ = tx.try_send(reply);
        }
        None => log::line(format!("reply for id={request_id} — no pending request")),
    }
}

/// The island has the card on screen; the long wait may begin.
pub fn acknowledge(app: &AppHandle, request_id: &str) {
    send(app, request_id, Reply::Ack, true);
}

/// Nobody can act on this one — paused, or another card already holds the view.
pub fn decline(app: &AppHandle, request_id: &str) {
    log::line(format!("decline id={request_id}"));
    send(app, request_id, Reply::Decline, false);
}

/// Called by the island's Allow / Deny buttons. Only ever a bare word: turning
/// it into Claude Code's JSON is coucou-hook's job.
pub fn answer(app: &AppHandle, request_id: &str, decision: &str) {
    let word = match decision {
        "allow" | "always" => "allow",
        _ => "deny",
    };
    log::line(format!("decision id={request_id} {word}"));
    send(app, request_id, Reply::Decision(word.to_string()), false);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_descriptor_admits_only_its_owner_and_system() {
        let sddl = pipe_sddl("S-1-5-21-1-2-3-1001");
        assert_eq!(sddl, "D:P(A;;GA;;;S-1-5-21-1-2-3-1001)(A;;GA;;;SY)");
        // No Everyone (WD), anonymous (AN) or authenticated-users (AU) entry.
        for broad in ["WD", "AN", "AU", "BU"] {
            assert!(!sddl.contains(&format!(";;;{broad})")), "{broad} must not be granted");
        }
    }

    #[test]
    fn an_instance_uses_our_descriptor_and_still_accepts_us() {
        let rt = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
        rt.block_on(async {
            let name = format!(r"\\.\pipe\coucou-test-{}", std::process::id());
            let server = create_instance(&name, true).expect("a pipe with our DACL");
            // Somebody already serving under the name: a first instance is refused.
            assert!(create_instance(&name, true).is_err());
            let client = std::fs::OpenOptions::new().read(true).write(true).open(&name);
            assert!(client.is_ok(), "our own account must still be able to connect");
            drop(server);
        });
    }
}
