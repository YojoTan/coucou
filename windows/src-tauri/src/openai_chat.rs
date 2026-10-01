// OpenAI-compatible chat: one `POST {base}/chat/completions` client for any
// server that speaks that dialect — a local Ollama or LM Studio, OpenRouter,
// OpenAI, vLLM, LiteLLM. Idea from upstream PRs #20 and #30, written for this
// fork's rules:
//
//   * the base URL must be https, or plain http only to this machine
//     (`integrations::secure_base_url`), so neither the key nor the
//     conversation crosses a network in the clear;
//   * redirects are never followed: the key rides in `Authorization`, and a
//     redirect is not where the user said to send it;
//   * the key is optional (local servers often need none) and lives in the
//     Credential Manager as `openai-api-key`, like every other key.

use std::sync::Mutex;
use std::time::Duration;

use serde_json::{json, Value};

use crate::claude::{ChatContext, ChatReply};

const TIMEOUT: Duration = Duration::from_secs(120);
const MAX_TOKENS: u32 = 4096;
const MAX_INLINE_TEXT: u64 = 200_000;
const MAX_IMAGE: u64 = 20 * 1024 * 1024;

const PERSONA: &str = "You are Mochi, a small assistant living at the top of the user's screen. \
Answer in the user's language, clearly and completely. \
Plain text only: no markdown (no **, no #, no bullet dashes), just line breaks.";

#[derive(Default)]
pub struct OpenAiChat {
    messages: Mutex<Vec<Value>>,
}

impl OpenAiChat {
    pub fn reset(&self) {
        self.messages.lock().unwrap().clear();
    }
}

/// `{base}/chat/completions`, whether the base already ends in `/v1` or not
/// (Ollama and LM Studio are usually given with it, OpenRouter with `/api/v1`).
pub fn endpoint(base: &str) -> Result<String, String> {
    let base = crate::integrations::secure_base_url(base)?;
    if base.ends_with("/chat/completions") {
        return Ok(base);
    }
    Ok(format!("{base}/chat/completions"))
}

/// The user turn: text, plus a dropped file when there is one (inbox copies only).
fn user_content(query: &str, context: Option<&ChatContext>) -> Result<Value, String> {
    let mut text = String::new();
    let mut image: Option<String> = None;
    match context {
        Some(ChatContext::File { name, path, note }) => {
            let file = crate::claude::inbox_file(path)
                .ok_or_else(|| "That file is not in Coucou's inbox yet — drop it again.".to_string())?;
            let ext = file.extension().and_then(|e| e.to_str()).unwrap_or("").to_lowercase();
            let size = std::fs::metadata(&file).map(|m| m.len()).unwrap_or(u64::MAX);
            match ext.as_str() {
                "png" | "jpg" | "jpeg" | "gif" | "webp" => {
                    if size > MAX_IMAGE {
                        return Err("That image is too large to send.".into());
                    }
                    let bytes = std::fs::read(&file).map_err(|e| e.to_string())?;
                    let mime = if ext == "jpg" { "jpeg".to_string() } else { ext.clone() };
                    image = Some(format!("data:image/{mime};base64,{}", crate::claude::base64_for(&bytes)));
                    match note {
                        Some(note) => text.push_str(&format!("{note}\n\n")),
                        None => text.push_str(&format!("The user attached an image: {name}\n\n")),
                    }
                }
                "pdf" => {
                    return Err("PDFs need the Anthropic API or a CLI engine — this endpoint only takes text and images.".into());
                }
                _ => {
                    if size > MAX_INLINE_TEXT {
                        return Err("That file is too large to send as text.".into());
                    }
                    let body = std::fs::read_to_string(&file)
                        .map_err(|_| "That file isn't text this endpoint can read.".to_string())?;
                    text.push_str(&format!("The user attached a file: {name}\nFile contents:\n{body}\n\n"));
                }
            }
        }
        Some(ChatContext::Window { app_name, title, url }) => {
            text.push_str(&format!("Context — App: {app_name}, Window: {title}"));
            if let Some(url) = url {
                text.push_str(&format!(", URL: {url}"));
            }
            text.push_str("\n\n");
        }
        Some(ChatContext::Clipboard { text: copied }) => {
            text.push_str(&ChatContext::clipboard_block(copied));
            text.push_str("\n\n");
        }
        None => {}
    }
    text.push_str(query);
    Ok(match image {
        Some(url) => json!([
            { "type": "text", "text": text },
            { "type": "image_url", "image_url": { "url": url } },
        ]),
        None => Value::String(text),
    })
}

/// `choices[0].message.content` — a string, or (some servers) an array of parts.
fn reply_text(v: &Value) -> Option<String> {
    let content = v.get("choices")?.get(0)?.get("message")?.get("content")?;
    match content {
        Value::String(s) => Some(s.clone()),
        Value::Array(parts) => Some(
            parts
                .iter()
                .filter_map(|p| p.get("text").and_then(Value::as_str))
                .collect::<Vec<_>>()
                .join(""),
        ),
        _ => None,
    }
    .filter(|s| !s.trim().is_empty())
}

fn error_text(v: &Value) -> Option<String> {
    let e = v.get("error")?;
    e.get("message")
        .and_then(Value::as_str)
        .or_else(|| e.as_str())
        .map(str::to_string)
}

pub async fn send(
    chat: &OpenAiChat,
    base: &str,
    model: &str,
    query: String,
    context: Option<ChatContext>,
) -> Result<ChatReply, String> {
    if base.trim().is_empty() {
        return Err("Set the endpoint URL in Settings → Chat (for example http://localhost:11434/v1 for Ollama).".into());
    }
    if model.trim().is_empty() {
        return Err("Set the model name in Settings → Chat (for example llama3.2 or qwen2.5).".into());
    }
    let url = endpoint(base)?;
    let first = chat.messages.lock().unwrap().is_empty();
    let content = user_content(&query, if first { context.as_ref() } else { None })?;

    let mut messages = vec![json!({ "role": "system", "content": PERSONA })];
    messages.extend(chat.messages.lock().unwrap().iter().cloned());
    let user = json!({ "role": "user", "content": content });
    messages.push(user.clone());

    let body = json!({
        "model": model.trim(),
        "messages": messages,
        "max_tokens": MAX_TOKENS,
        "stream": false,
    });

    let client = reqwest::Client::builder()
        .timeout(TIMEOUT)
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .map_err(|e| e.to_string())?;
    let mut request = client.post(&url).json(&body);
    if let Some(key) = crate::secrets::get("openai-api-key") {
        request = request.bearer_auth(key);
    }
    let response = request.send().await.map_err(|e| {
        if e.is_connect() {
            format!("Can't reach {url} — is the server running?")
        } else {
            format!("Network error: {e}")
        }
    })?;
    let status = response.status();
    let raw = response.text().await.map_err(|e| e.to_string())?;
    let parsed = serde_json::from_str::<Value>(&raw).ok();

    if !status.is_success() {
        let detail = parsed
            .as_ref()
            .and_then(error_text)
            .unwrap_or_else(|| raw.chars().take(200).collect());
        return Err(format!("Endpoint {status}: {detail}"));
    }
    let parsed = parsed.ok_or_else(|| "The endpoint did not answer with JSON.".to_string())?;
    if let Some(err) = error_text(&parsed) {
        return Err(err);
    }
    let text = reply_text(&parsed).ok_or_else(|| "No response text.".to_string())?;

    let mut history = chat.messages.lock().unwrap();
    history.push(user);
    history.push(json!({ "role": "assistant", "content": text }));
    Ok(ChatReply { text: text.trim().to_string() })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_endpoint_is_built_from_any_usual_base() {
        assert_eq!(endpoint("http://localhost:11434/v1").unwrap(), "http://localhost:11434/v1/chat/completions");
        assert_eq!(endpoint("http://127.0.0.1:1234/v1/").unwrap(), "http://127.0.0.1:1234/v1/chat/completions");
        assert_eq!(endpoint("https://openrouter.ai/api/v1").unwrap(), "https://openrouter.ai/api/v1/chat/completions");
        assert_eq!(
            endpoint("https://api.openai.com/v1/chat/completions").unwrap(),
            "https://api.openai.com/v1/chat/completions"
        );
        // A key and a conversation never travel over plain http off this machine.
        assert!(endpoint("http://192.168.1.20:11434/v1").is_err());
        assert!(endpoint("https://user:pw@example.com/v1").is_err());
    }

    #[test]
    fn replies_and_errors_are_read_in_both_usual_shapes() {
        let plain = json!({ "choices": [{ "message": { "content": "hola" } }] });
        assert_eq!(reply_text(&plain).as_deref(), Some("hola"));
        let parts = json!({ "choices": [{ "message": { "content": [{ "type": "text", "text": "a" }, { "type": "text", "text": "b" }] } }] });
        assert_eq!(reply_text(&parts).as_deref(), Some("ab"));
        assert_eq!(error_text(&json!({ "error": { "message": "bad model" } })).as_deref(), Some("bad model"));
        assert_eq!(error_text(&json!({ "error": "quota" })).as_deref(), Some("quota"));
    }

    /// A fake OpenAI-compatible server on localhost: checks what Mochi sends
    /// and answers like Ollama would. Two turns, so the history is exercised.
    #[test]
    fn a_local_server_gets_the_conversation_and_its_reply_comes_back() {
        use std::io::{BufRead, BufReader, Read, Write};
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let server = std::thread::spawn(move || {
            let mut bodies = Vec::new();
            for reply in ["hola", "sigo aqui"] {
                let (stream, _) = listener.accept().unwrap();
                let mut reader = BufReader::new(stream.try_clone().unwrap());
                let mut len = 0usize;
                let mut line = String::new();
                let mut request_line = String::new();
                reader.read_line(&mut request_line).unwrap();
                loop {
                    line.clear();
                    reader.read_line(&mut line).unwrap();
                    if line.trim().is_empty() { break; }
                    if let Some(v) = line.to_ascii_lowercase().strip_prefix("content-length:") {
                        len = v.trim().parse().unwrap();
                    }
                }
                let mut body = vec![0u8; len];
                reader.read_exact(&mut body).unwrap();
                bodies.push((request_line, String::from_utf8(body).unwrap()));
                let json = format!(r#"{{"choices":[{{"message":{{"role":"assistant","content":"{reply}"}}}}]}}"#);
                let mut out = stream;
                write!(out, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}", json.len(), json).unwrap();
            }
            bodies
        });

        let chat = OpenAiChat::default();
        let base = format!("http://127.0.0.1:{port}/v1");
        let one = tauri::async_runtime::block_on(send(&chat, &base, "llama3.2", "hi".into(), None)).unwrap();
        assert_eq!(one.text, "hola");
        let two = tauri::async_runtime::block_on(send(&chat, &base, "llama3.2", "still there?".into(), None)).unwrap();
        assert_eq!(two.text, "sigo aqui");

        let bodies = server.join().unwrap();
        assert!(bodies[0].0.starts_with("POST /v1/chat/completions"));
        let second: Value = serde_json::from_str(&bodies[1].1).unwrap();
        assert_eq!(second["model"], "llama3.2");
        let roles: Vec<&str> = second["messages"].as_array().unwrap().iter().map(|m| m["role"].as_str().unwrap()).collect();
        assert_eq!(roles, ["system", "user", "assistant", "user"], "the second turn carries the first");
    }

    #[test]
    fn only_inbox_files_are_attached() {
        let ctx = ChatContext::File { name: "win.ini".into(), path: r"C:\Windows\win.ini".into(), note: None };
        assert!(user_content("q", Some(&ctx)).is_err());
        assert_eq!(user_content("q", None).unwrap(), Value::String("q".into()));
    }
}
