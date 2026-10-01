// "What did Claude Code just do?" — when a session stops, the island shows the
// start of Claude's last reply instead of only the last tool step. It comes
// from the session transcript Claude Code keeps on disk, read here, locally.
//
// The path arrives in the Stop hook payload, so it is checked before anything
// is opened: a `.jsonl` file inside %USERPROFILE%\.claude, nothing else. Only
// the tail of the file is read, and only the text of the last assistant turn
// leaves this function, cut to a couple of lines.

use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};

use serde_json::Value;

/// How much of the end of a transcript is scanned for the last reply.
const TAIL_BYTES: u64 = 256 * 1024;
const MAX_SUMMARY: usize = 220;

fn claude_dir() -> Option<PathBuf> {
    let home = std::env::var_os("USERPROFILE").map(PathBuf::from)?;
    std::fs::canonicalize(home.join(".claude")).ok()
}

/// The transcript, if `raw` names a .jsonl file inside ~/.claude.
fn transcript_file(raw: &str) -> Option<PathBuf> {
    let file = std::fs::canonicalize(raw).ok()?;
    let inside = file.starts_with(claude_dir()?);
    let jsonl = file.extension().and_then(|e| e.to_str()) == Some("jsonl");
    (inside && jsonl && file.is_file()).then_some(file)
}

/// The text of the last assistant message among JSONL lines, if any.
fn last_assistant_text(lines: &str) -> Option<String> {
    lines.lines().rev().find_map(|line| {
        let v: Value = serde_json::from_str(line.trim()).ok()?;
        if v.get("type").and_then(Value::as_str) != Some("assistant") {
            return None;
        }
        let content = v.get("message")?.get("content")?;
        let text = match content {
            Value::String(s) => s.clone(),
            Value::Array(parts) => parts
                .iter()
                .filter(|p| p.get("type").and_then(Value::as_str) == Some("text"))
                .filter_map(|p| p.get("text").and_then(Value::as_str))
                .collect::<Vec<_>>()
                .join(" "),
            _ => return None,
        };
        let text = text.split_whitespace().collect::<Vec<_>>().join(" ");
        (!text.is_empty()).then_some(text)
    })
}

fn shorten(text: &str) -> String {
    if text.chars().count() <= MAX_SUMMARY {
        return text.to_string();
    }
    let cut: String = text.chars().take(MAX_SUMMARY).collect();
    let cut = cut.rsplit_once(' ').map(|(head, _)| head.to_string()).unwrap_or(cut);
    format!("{cut}…")
}

fn read_tail(path: &Path) -> Option<String> {
    let mut file = std::fs::File::open(path).ok()?;
    let len = file.metadata().ok()?.len();
    file.seek(SeekFrom::Start(len.saturating_sub(TAIL_BYTES))).ok()?;
    let mut buf = Vec::new();
    file.take(TAIL_BYTES).read_to_end(&mut buf).ok()?;
    Some(String::from_utf8_lossy(&buf).to_string())
}

/// A short summary of the last thing Claude said in this session.
pub fn last_reply(transcript_path: &str) -> Option<String> {
    let path = transcript_file(transcript_path)?;
    last_assistant_text(&read_tail(&path)?).map(|t| shorten(&t))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_last_assistant_text_is_found_and_tool_turns_skipped() {
        let jsonl = [
            r#"{"type":"user","message":{"content":"fix the bug"}}"#,
            r#"{"type":"assistant","message":{"content":[{"type":"text","text":"Fixed the   off-by-one\nin parser.rs"}]}}"#,
            r#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash"}]}}"#,
            "not json",
        ]
        .join("\n");
        assert_eq!(last_assistant_text(&jsonl).as_deref(), Some("Fixed the off-by-one in parser.rs"));
        assert!(last_assistant_text(r#"{"type":"user","message":{"content":"hi"}}"#).is_none());
    }

    #[test]
    fn long_replies_are_cut_on_a_word() {
        let s = shorten(&"palabra ".repeat(100));
        assert!(s.chars().count() <= MAX_SUMMARY + 1);
        assert!(s.ends_with("palabra…"));
    }

    #[test]
    fn only_jsonl_files_inside_dot_claude_are_read() {
        assert!(transcript_file(r"C:\Windows\win.ini").is_none());
        let outside = std::env::temp_dir().join(format!("coucou-t-{}.jsonl", std::process::id()));
        std::fs::write(&outside, b"{}").unwrap();
        assert!(transcript_file(outside.to_str().unwrap()).is_none());
        let _ = std::fs::remove_file(&outside);
    }
}
