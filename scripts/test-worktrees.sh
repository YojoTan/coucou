#!/usr/bin/env bash
# The worktree provider protocol: the Swift parser, and examples/worktree-provider.sh
# end to end in a throwaway repo (create, refuse a removal that loses work, remove).
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
T="$(mktemp -d "${TMPDIR:-/tmp}/coucou-wt.XXXXXX")"
trap 'rm -rf "$T"' EXIT
swiftc -swift-version 6 -strict-concurrency=complete \
    NotchBuddy/Sources/App/WorktreeParse.swift tests/WorktreeParseTests.swift -o "$T/parse-tests"
"$T/parse-tests"

P="$ROOT/examples/worktree-provider.sh"
git init -q --bare "$T/origin.git"
git init -q -b main "$T/repo" && cd "$T/repo"
git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git remote add origin "$T/origin.git" && git push -q origin main
check() { if [ "$1" != "$2" ]; then echo "FAIL: $3 (got '$1', want '$2')"; exit 1; fi; }

check "$("$P" describe | jq -r '[.actions[].id] | join(",")')" "create,session,remove" "describe"
check "$("$P" list | jq '.worktrees | length')" "0" "empty list"
"$P" run create '{"name":"fix-a"}' | tail -1 | jq -e '.type == "done" and .ok' >/dev/null || { echo "FAIL: create"; exit 1; }
check "$("$P" list | jq -r '.worktrees[0].slug')" "repo-fix-a" "listed"
WT="$("$P" list | jq -r '.worktrees[0].path')"
touch "$WT/wip.txt"
OUT="$("$P" run remove "{\"worktree\":{\"path\":\"$WT\"}}" || true)"
echo "$OUT" | tail -1 | jq -e '.ok == false and (.risk | length) == 1' >/dev/null || { echo "FAIL: dirty removal refused: $OUT"; exit 1; }
[ -d "$WT" ] || { echo "FAIL: dirty worktree removed"; exit 1; }
rm "$WT/wip.txt"
"$P" run remove "{\"worktree\":{\"path\":\"$WT\"}}" | tail -1 | jq -e '.ok' >/dev/null || { echo "FAIL: clean removal"; exit 1; }
[ ! -d "$WT" ] || { echo "FAIL: clean worktree still there"; exit 1; }
echo "Worktree provider tests passed"
