// Chat tuning — the model and the effort picked in the chat itself, not in the
// provider's settings: a lighter model or less thinking for a quick answer,
// without touching what Settings → Chat says.
//
// The island sends them with each message. They are checked here before they
// reach anything: an effort is one of a fixed list, and a model is one plain
// word — it becomes a CLI argument, so it can never start with `-` or carry a
// space, a quote or a shell character.

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::cli_chat::Engine;

#[derive(Deserialize, Default, Clone, Debug)]
#[serde(rename_all = "camelCase")]
pub struct ChatTuning {
    #[serde(default)]
    pub model: Option<String>,
    #[serde(default)]
    pub effort: Option<String>,
}

const EFFORTS: [&str; 5] = ["low", "medium", "high", "xhigh", "max"];

pub fn valid_model(s: &str) -> bool {
    let s = s.trim();
    !s.is_empty()
        && s.len() <= 120
        && !s.starts_with('-')
        && s.chars().all(|c| c.is_ascii_alphanumeric() || "._:/@+-[]".contains(c))
}

impl ChatTuning {
    /// The model override, when it is a valid one.
    pub fn model(&self) -> Option<&str> {
        self.model.as_deref().map(str::trim).filter(|m| valid_model(m))
    }

    /// The effort, when it is one this engine understands.
    pub fn effort_for(&self, allowed: &[&'static str]) -> Option<&'static str> {
        let e = self.effort.as_deref()?.trim();
        EFFORTS.iter().copied().find(|x| *x == e).filter(|x| allowed.contains(x))
    }
}

/// Efforts each engine accepts, in its own words.
pub fn efforts(engine: &str) -> &'static [&'static str] {
    match engine {
        "claude" => &["low", "medium", "high", "xhigh", "max"],
        "api" | "anthropic" => &["low", "medium", "high", "max"],
        "codex" | "openai" => &["low", "medium", "high"],
        _ => &[],
    }
}

pub fn cli_efforts(engine: Engine) -> &'static [&'static str] {
    efforts(engine.id())
}

#[derive(Serialize, Clone, Debug, PartialEq)]
pub struct Choice {
    pub id: String,
    pub label: String,
}

#[derive(Serialize, Debug)]
#[serde(rename_all = "camelCase")]
pub struct Choices {
    /// The engine the next message goes to ("claude", "api", "openai"…).
    pub engine: String,
    /// What "Default" means right now: Settings' model, or the CLI's own.
    pub default_label: String,
    pub models: Vec<Choice>,
    pub efforts: Vec<&'static str>,
}

fn choice(id: &str, label: &str) -> Choice {
    Choice { id: id.into(), label: label.into() }
}

/// Claude Code's own aliases: they follow the newest model of each size.
pub fn claude_cli_models() -> Vec<Choice> {
    vec![choice("opus", "Opus"), choice("sonnet", "Sonnet"), choice("haiku", "Haiku")]
}

/// `data[].id` (+ `display_name`) — the shape of both Anthropic's and OpenAI's
/// model lists. Capped, and only ids that could be sent back as a model.
pub fn parse_models(v: &Value) -> Vec<Choice> {
    let mut out: Vec<Choice> = v
        .get("data")
        .and_then(Value::as_array)
        .map(|list| {
            list.iter()
                .filter_map(|m| {
                    let id = m.get("id").and_then(Value::as_str)?;
                    if !valid_model(id) {
                        return None;
                    }
                    let label = m.get("display_name").and_then(Value::as_str).unwrap_or(id);
                    Some(choice(id, label))
                })
                .take(60)
                .collect()
        })
        .unwrap_or_default();
    out.dedup_by(|a, b| a.id == b.id);
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn a_model_is_one_plain_word_and_never_a_flag() {
        for ok in ["haiku", "claude-sonnet-5", "anthropic/claude-sonnet-4.5", "qwen2.5:7b", "gpt-5@2026"] {
            assert!(valid_model(ok), "{ok}");
        }
        for bad in ["", "--dangerously-skip-permissions", "-m", "a b", "x;rm", "a\"b", "$(x)", "a`b"] {
            assert!(!valid_model(bad), "{bad}");
        }
    }

    #[test]
    fn an_effort_must_be_one_the_engine_takes() {
        let t = ChatTuning { model: None, effort: Some("xhigh".into()) };
        assert_eq!(t.effort_for(efforts("claude")), Some("xhigh"));
        assert_eq!(t.effort_for(efforts("openai")), None);
        let t = ChatTuning { model: None, effort: Some("ultra".into()) };
        assert_eq!(t.effort_for(efforts("claude")), None);
    }

    #[test]
    fn model_lists_are_read_in_both_shapes() {
        let anthropic = json!({ "data": [{ "id": "claude-haiku-4-5", "display_name": "Claude Haiku 4.5" }, { "id": "--evil" }] });
        assert_eq!(parse_models(&anthropic), vec![choice("claude-haiku-4-5", "Claude Haiku 4.5")]);
        let openai = json!({ "object": "list", "data": [{ "id": "llama3.2:latest", "object": "model" }] });
        assert_eq!(parse_models(&openai)[0].label, "llama3.2:latest");
    }
}
