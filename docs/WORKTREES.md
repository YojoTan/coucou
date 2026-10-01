# Worktrees from Mochi — the provider protocol

Coucou can show and manage a repository's git worktrees from the island, its
pill, or the desktop pet. What it can *do* in a repo comes from that repo's
**provider**: a command (usually a script in the repo) that tells Coucou which
actions exist and what they ask for, and then runs them. Coucou only draws the
forms, the lists and the confirmations — so a team's own rules and tools for
worktrees (setup steps, submodules, safety checks) stay in its own scripts.

Repos and their provider commands are added in Settings › Extras › Worktrees and
kept in that Mac's preferences only.

**Without a provider**, Coucou lists the worktrees (`git worktree list`) and
opens a terminal in one. It never removes a worktree on its own:
`git worktree remove --force` deletes a worktree's submodule clones with
whatever commits they hold.

**Whatever the provider**, Coucou reads each worktree's state itself with git —
changed files and commits that are on no remote, submodules included — and
shows it next to each worktree.

## Calling convention

Coucou runs, in the repository's root, through the user's login shell:

```
<provider> describe
<provider> list
<provider> run <action-id> <arguments-json>
```

with `COUCOU=1` in the environment, and the arguments JSON also in
`COUCOU_ARGS`. `describe` and `list` must answer within 20 s with one JSON
object on stdout and exit 0. `run` can take as long as it needs; the user sees
its progress live and can stop it.

## `describe`

```json
{
  "version": 1,
  "actions": [
    { "id": "create", "label": "New worktree", "scope": "repo",
      "fields": [
        { "id": "name", "type": "text", "label": "Name", "required": true,
          "pattern": "^[a-z0-9][a-z0-9-]*$", "placeholder": "fix-login" },
        { "id": "parts", "type": "multi", "label": "Modules",
          "options": [ { "value": "api", "label": "api" }, { "value": "web", "label": "web" } ] },
        { "id": "deps", "type": "choice", "label": "Dependencies", "default": "auto",
          "options": [ { "value": "auto", "label": "Auto" }, { "value": "none", "label": "None" } ] },
        { "id": "open", "type": "bool", "label": "Open a session when ready", "default": true }
      ] },
    { "id": "session", "label": "Open a session", "scope": "worktree" },
    { "id": "remove", "label": "Tear down", "scope": "worktree", "danger": true }
  ]
}
```

- `scope`: `repo` actions show as buttons on top of the list ("+ New worktree");
  `worktree` actions in each worktree's menu.
- `danger: true`: Coucou always shows a confirmation step first, in red.
- Field types: `text` (with optional `pattern`, a regular expression), `choice`
  (one of `options`), `multi` (any of `options`, sent as a list), `bool`.
  `default` pre-fills; `required` is checked before running.

## `list`

```json
{ "worktrees": [
    { "slug": "fix-login", "path": "/abs/path/to/worktree", "branch": "fix-login", "note": "port 4210" }
] }
```

`slug` is what the user sees and what typed confirmations ask for; `path` must
be absolute. List only the worktrees the provider manages (not the main
checkout). `note` is optional, shown under the name.

## `run`

The arguments JSON holds the form's values by field id, plus:

- `worktree`: `{"slug", "path", "branch"}` for `worktree` actions;
- `force: true` and `confirm: "<what the user typed>"` on a forced rerun.

The provider writes **one event per line** on stdout (stderr is shown too):

```json
{"type": "progress", "text": "Creating fix-login…"}
{"type": "terminal", "command": "claude", "cwd": "/abs/path/to/worktree", "title": "fix-login"}
{"type": "done", "ok": true, "text": "fix-login is ready"}
{"type": "done", "ok": false, "text": "Work would be lost", "risk": ["3 files not committed", "2 commits not pushed"], "canForce": true}
```

- Lines that aren't JSON are shown as progress, so a provider can simply pass
  its tools' output through.
- `terminal`: Coucou opens a terminal there running `command` — a tab in Orca
  when Orca is running (in that worktree), else Terminal.app. This is how an
  interactive session (an agent, a shell) starts from a click.
- `done` ends the run. Without one, the exit code decides (0 = success).
- `canForce: true` on a failure: Coucou offers "Force…", asks the user to
  **type the worktree's slug**, and reruns the same action with `force: true`
  and `confirm` set to what was typed. The provider must check `confirm`
  itself before doing anything it can't undo.

## Example

[`examples/worktree-provider.sh`](../examples/worktree-provider.sh) is a
complete provider for a plain git repository (needs `jq`, part of macOS 15):
create a worktree on a new branch next to the repo, open a terminal in it, and
tear it down only when nothing would be lost — no changes, no unpushed commits,
no submodules. Point a repo's provider at it, or copy it into your repo and
adapt it to your own tools.
