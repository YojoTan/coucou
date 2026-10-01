// Worktrees → island: port of Worktrees.swift's run state machine. Rust lists
// and runs (worktrees.rs); here the form's checks, the progress, the result and
// the typed confirmation before a forced rerun.

import { onEvent, Bridge } from "../core/bridge";
import { Sound } from "../core/sound";
import { State, type WtAction, type WtEvent, type WtField, type WtRepoState, type WtRun, type WtValue, type WtWorktree } from "../core/state";
import { t } from "../core/i18n";
import type { Island } from "./island";

export const WORKTREES_ID = "integration_worktrees";

/** The repo the views show: the one picked, else the first. */
export function currentRepo(): WtRepoState | null {
  return State.worktrees.find((r) => r.id === State.wtRepoId) ?? State.worktrees[0] ?? null;
}

/** Nil when the value is acceptable, else why not (WTField.problem). */
export function fieldProblem(f: WtField, value: WtValue | undefined): string | null {
  const required = f.required === true;
  switch (f.type) {
    case "text": {
      const s = typeof value === "string" ? value.trim() : "";
      if (!s) return required ? t("{label} is required.", { label: f.label }) : null;
      if (f.pattern) {
        try {
          if (!new RegExp(f.pattern).test(s)) return t("{label} doesn't look right.", { label: f.label });
        } catch { /* a pattern JavaScript can't read: the provider checks */ }
      }
      return null;
    }
    case "choice":
      return value === undefined && required ? t("{label} is required.", { label: f.label }) : null;
    case "multi":
      return required && (!Array.isArray(value) || value.length === 0) ? t("Pick at least one {label}.", { label: f.label }) : null;
    default:
      return null;
  }
}

let island: Island | null = null;

/** From a row, the pet's menu or "+": a form when the action asks for something, else run. */
export function beginRun(repoId: string, action: WtAction, worktree: WtWorktree | null) {
  const values: Record<string, WtValue> = {};
  for (const f of action.fields ?? []) {
    if (f.default !== undefined) values[f.id] = f.default;
    // A choice shows its first option: that is what it sends unless changed.
    else if (f.type === "choice" && f.options?.length) values[f.id] = f.options[0].value;
  }
  State.wtRun = { repoId, action, worktree, values, stage: "form", log: [], result: null, runId: null };
  island?.alert("worktrees");
  const needsForm = (action.fields ?? []).length > 0 || action.danger === true;
  if (!needsForm) void execute();
}

/** Runs the form's action; `confirm` is the slug typed after a refusal. */
export async function execute(force = false, confirm: string | null = null) {
  const run = State.wtRun;
  if (!run) return;
  run.stage = "running";
  run.log = [];
  run.result = null;
  run.runId = null;
  State.isPinned = true;
  State.notify();
  try {
    const id = await Bridge.worktreesRun(run.repoId, run.action.id, run.worktree?.path ?? null, run.values, force, confirm);
    if (State.wtRun === run && run.runId == null) run.runId = id;
  } catch (err) {
    finish(run, { type: "done", ok: false, text: t(String(err).replace(/^Error:\s*/, "")), risk: [], canForce: false });
  }
}

function finish(run: WtRun, e: Extract<WtEvent, { type: "done" }>) {
  if (State.wtRun !== run) return;
  run.result = e;
  run.stage = "finished";
  State.isPinned = false;
  const name = run.worktree?.slug ?? run.action.label;
  State.showToast(e.ok ? `✓ ${name}` : `✗ ${name}: ${e.text.slice(0, 60)}`, e.ok ? "#30A46C" : "#E5484D");
  Sound.play(e.ok ? "finish" : "error");
  State.notify();
}

export function cancelRun() {
  void Bridge.worktreesCancel();
  State.wtRun = null;
  State.isPinned = false;
  State.notify();
}

interface RunUpdate { run: number; event: WtEvent | null; exitCode: number | null }

function onRun(u: RunUpdate) {
  const run = State.wtRun;
  // A run's own events only (a plain-git terminal answers before its number is known).
  if (!run || run.stage !== "running" || (run.runId != null && run.runId !== u.run)) return;
  run.runId ??= u.run;
  const e = u.event;
  if (e?.type === "progress") {
    run.log.push(e.text);
    if (run.log.length > 200) run.log.splice(0, run.log.length - 200);
  } else if (e?.type === "terminal") {
    run.log.push(t("Opened a terminal: {command}", { command: e.command }));
  } else if (e?.type === "done") {
    return finish(run, e);
  } else if (u.exitCode != null) {
    // The provider exited without a final word: its exit code decides.
    const ok = u.exitCode === 0;
    return finish(run, { type: "done", ok, text: ok ? t("Done.") : run.log.slice(-3).join("\n"), risk: [], canForce: false });
  }
  State.notify();
}

export function registerWorktreeHandlers(i: Island) {
  island = i;
  void onEvent<WtRepoState[]>("worktrees-state", (list) => {
    State.worktrees = list;
    State.notify();
  });
  void onEvent<RunUpdate>("worktrees-run", onRun);
  void Bridge.worktreesState().then((list) => {
    if (list) {
      State.worktrees = list;
      State.notify();
    }
  });
}
