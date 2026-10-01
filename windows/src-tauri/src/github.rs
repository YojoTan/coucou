// GitHub pull requests — the Windows side of upstream PR #15.
//
// The pill used to need a Personal Access Token and only showed repo and star
// counts. Now it lists the pull requests that need the user: reviews requested
// from them first, then their own open PRs with CI status. One GraphQL query to
// api.github.com per poll.
//
// Token: one pasted in Settings wins; otherwise the local `gh` login is used
// (`gh auth token`), read fresh on every poll and never stored — `gh auth
// logout` disconnects Coucou too. The token never leaves this module except
// in the Authorization header to api.github.com.

use std::path::PathBuf;
use std::time::Duration;

use serde::Serialize;
use serde_json::{json, Value};

use crate::secrets;

const GH_TIMEOUT: Duration = Duration::from_secs(10);

#[derive(Clone, Copy, PartialEq, Debug)]
pub enum Source {
    Token,
    Gh,
}

impl Source {
    pub fn id(self) -> &'static str {
        match self {
            Source::Token => "token",
            Source::Gh => "gh",
        }
    }
}

/// `gh` on PATH, else where its installer puts it.
fn gh_path() -> Option<PathBuf> {
    crate::find_on_path("gh").or_else(|| {
        let p = PathBuf::from(std::env::var_os("ProgramFiles")?).join("GitHub CLI").join("gh.exe");
        p.is_file().then_some(p)
    })
}

/// The token to use and where it came from. Blocking (it may run `gh`).
pub fn token() -> Option<(String, Source)> {
    if let Some(t) = secrets::get("github-token").filter(|t| !t.trim().is_empty()) {
        return Some((t.trim().to_string(), Source::Token));
    }
    let gh = gh_path()?;
    let home = std::env::var_os("USERPROFILE").map(PathBuf::from).unwrap_or_else(std::env::temp_dir);
    let args = ["auth", "token", "--hostname", "github.com"].map(String::from);
    let out = crate::cli_chat::run(&gh, &args, &home, None, GH_TIMEOUT).ok()?;
    let t = out.stdout.trim();
    // A token is one word; anything else is gh talking, not a token.
    (out.code == Some(0) && !out.timed_out && is_token_like(t)).then(|| (t.to_string(), Source::Gh))
}

fn is_token_like(t: &str) -> bool {
    !t.is_empty() && t.len() < 512 && t.chars().all(|c| c.is_ascii_alphanumeric() || c == '_')
}

pub const QUERY: &str = r#"query {
  viewer { login }
  review: search(query: "is:open is:pr review-requested:@me archived:false sort:updated-desc", type: ISSUE, first: 5) {
    issueCount
    nodes { ... on PullRequest { number title url isDraft repository { nameWithOwner } author { login } } }
  }
  mine: search(query: "is:open is:pr author:@me archived:false sort:updated-desc", type: ISSUE, first: 5) {
    issueCount
    nodes { ... on PullRequest { number title url isDraft reviewDecision repository { nameWithOwner }
      commits(last: 1) { nodes { commit { statusCheckRollup { state } } } } } }
  }
}"#;

#[derive(Serialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Pr {
    pub url: String,
    pub number: i64,
    pub title: String,
    pub repo: String,
    pub author: Option<String>,
    /// success | failure | pending, or None when the PR has no checks.
    pub ci: Option<&'static str>,
    pub review_decision: Option<String>,
    pub is_draft: bool,
}

fn ci_state(rollup: Option<&str>) -> Option<&'static str> {
    match rollup? {
        "SUCCESS" => Some("success"),
        "FAILURE" | "ERROR" => Some("failure"),
        "PENDING" | "EXPECTED" => Some("pending"),
        _ => None,
    }
}

fn prs(search: Option<&Value>) -> Vec<Pr> {
    let nodes = search.and_then(|s| s.get("nodes")).and_then(Value::as_array).cloned().unwrap_or_default();
    nodes
        .iter()
        .filter_map(|n| {
            let url = n.get("url").and_then(Value::as_str)?;
            // Rows open in the browser: only ever a github.com page.
            if !url.starts_with("https://github.com/") {
                return None;
            }
            let rollup = n
                .pointer("/commits/nodes")
                .and_then(Value::as_array)
                .and_then(|c| c.last())
                .and_then(|c| c.pointer("/commit/statusCheckRollup/state"))
                .and_then(Value::as_str);
            Some(Pr {
                url: url.to_string(),
                number: n.get("number").and_then(Value::as_i64)?,
                title: n.get("title").and_then(Value::as_str).unwrap_or_default().to_string(),
                repo: n.pointer("/repository/nameWithOwner").and_then(Value::as_str).unwrap_or_default().to_string(),
                author: n.pointer("/author/login").and_then(Value::as_str).map(String::from),
                ci: ci_state(rollup),
                review_decision: n.get("reviewDecision").and_then(Value::as_str).map(String::from),
                is_draft: n.get("isDraft").and_then(Value::as_bool).unwrap_or(false),
            })
        })
        .collect()
}

/// The `data` of a GraphQL reply, as the island's GitHub card reads it.
pub fn summary(data: &Value, source: Source) -> Value {
    let count = |k: &str| data.pointer(&format!("/{k}/issueCount")).and_then(Value::as_i64).unwrap_or(0);
    json!({
        "source": source.id(),
        "login": data.pointer("/viewer/login").and_then(Value::as_str).unwrap_or_default(),
        "reviewCount": count("review"),
        "reviewRequests": prs(data.get("review")),
        "mineCount": count("mine"),
        "mine": prs(data.get("mine")),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_reply_becomes_review_requests_and_own_prs_with_ci() {
        let data = json!({
            "viewer": { "login": "octo" },
            "review": { "issueCount": 7, "nodes": [
                { "number": 4, "title": "Fix", "url": "https://github.com/a/b/pull/4", "isDraft": false,
                  "repository": { "nameWithOwner": "a/b" }, "author": { "login": "x" } },
                { "number": 5, "title": "Evil", "url": "https://evil.example/pull/5" },
                {}
            ]},
            "mine": { "issueCount": 1, "nodes": [
                { "number": 9, "title": "Mine", "url": "https://github.com/me/c/pull/9", "isDraft": true,
                  "reviewDecision": "APPROVED", "repository": { "nameWithOwner": "me/c" },
                  "commits": { "nodes": [{ "commit": { "statusCheckRollup": { "state": "ERROR" } } }] } }
            ]}
        });
        let s = summary(&data, Source::Gh);
        assert_eq!(s["login"], "octo");
        assert_eq!(s["source"], "gh");
        assert_eq!(s["reviewCount"], 7);
        assert_eq!(s["reviewRequests"].as_array().unwrap().len(), 1, "non-github.com and empty nodes are dropped");
        assert_eq!(s["reviewRequests"][0]["author"], "x");
        assert_eq!(s["mine"][0]["ci"], "failure");
        assert_eq!(s["mine"][0]["isDraft"], true);
        assert_eq!(s["mine"][0]["reviewDecision"], "APPROVED");
    }

    #[test]
    fn only_a_single_word_counts_as_a_gh_token() {
        assert!(is_token_like("gho_abcDEF123"));
        assert!(!is_token_like(""));
        assert!(!is_token_like("You are not logged into any GitHub hosts. Run gh auth login"));
    }
}
