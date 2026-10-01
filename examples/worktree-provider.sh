#!/usr/bin/env bash
# A Coucou worktree provider for a plain git repository (docs/WORKTREES.md).
#   describe | list | run <create|session|remove> <json>
# Creates worktrees next to the repo as ../<repo>-<name> on a new branch <name>;
# removes one only when nothing would be lost (no changes, no commits on no
# remote, no submodules). Needs jq.
set -euo pipefail
command -v jq >/dev/null || { echo '{"type":"done","ok":false,"text":"jq is required"}'; exit 1; }

ROOT="$(git rev-parse --show-toplevel)"
REPO="$(basename "$ROOT")"
event() { jq -cn "$@"; }

case "${1:-}" in
describe)
  jq -n '{version: 1, actions: [
    {id: "create", label: "New worktree", scope: "repo", fields: [
      {id: "name", type: "text", label: "Branch", required: true, pattern: "^[A-Za-z0-9._/-]+$", placeholder: "fix-login"},
      {id: "base", type: "text", label: "From", default: "HEAD", placeholder: "main"}]},
    {id: "session", label: "Open a terminal", scope: "worktree"},
    {id: "remove", label: "Remove", scope: "worktree", danger: true}]}'
  ;;
list)
  git worktree list --porcelain | awk -v main="$ROOT" '
    /^worktree / { path = substr($0, 10) }
    /^branch /   { branch = substr($0, 8); sub("refs/heads/", "", branch) }
    /^$/         { if (path != main && path != "") print path "\t" branch; path = ""; branch = "" }
    END          { if (path != main && path != "") print path "\t" branch }' |
  jq -R -s '{worktrees: [split("\n")[] | select(length > 0) | split("\t") |
            {slug: (.[0] | split("/") | last), path: .[0], branch: .[1]}]}'
  ;;
run)
  ACTION="${2:-}"; ARGS="${3:-${COUCOU_ARGS:-{\}}}"
  arg() { jq -r "$1 // empty" <<<"$ARGS"; }
  case "$ACTION" in
  create)
    NAME="$(arg .name)"; BASE="$(arg .base)"; BASE="${BASE:-HEAD}"
    DEST="$(dirname "$ROOT")/$REPO-${NAME//\//-}"
    event --arg t "Creating ${DEST} from ${BASE}…" '{type: "progress", text: $t}'
    if git worktree add -b "$NAME" "$DEST" "$BASE" 2>&1; then
      event --arg t "$NAME is ready" '{type: "done", ok: true, text: $t}'
    else
      event '{type: "done", ok: false, text: "git worktree add failed"}'; exit 1
    fi
    ;;
  session)
    event --arg p "$(arg .worktree.path)" '{type: "terminal", command: "git status", cwd: $p}'
    event '{type: "done", ok: true, text: "Terminal opened"}'
    ;;
  remove)
    WT="$(arg .worktree.path)"
    RISK=()
    [ -f "$WT/.gitmodules" ] && RISK+=("it has submodules — remove it with your own tools")
    D="$(git -C "$WT" status --porcelain | wc -l | tr -d ' ')"; [ "$D" = 0 ] || RISK+=("$D file(s) not committed")
    U="$(git -C "$WT" rev-list --count HEAD --not --remotes)"; [ "$U" = 0 ] || RISK+=("$U commit(s) on no remote")
    if [ "${#RISK[@]}" -gt 0 ]; then
      printf '%s\n' "${RISK[@]}" | jq -R -s -c '{type: "done", ok: false, text: "Nothing removed: work would be lost.", risk: (split("\n") | map(select(length > 0))), canForce: false}'
      exit 1
    fi
    git worktree remove "$WT" 2>&1
    event --arg t "Removed $(basename "$WT")" '{type: "done", ok: true, text: $t}'
    ;;
  *) event --arg a "$ACTION" '{type: "done", ok: false, text: ("unknown action " + $a)}'; exit 1 ;;
  esac
  ;;
*) echo "usage: $0 describe | list | run <action> <json>" >&2; exit 2 ;;
esac
