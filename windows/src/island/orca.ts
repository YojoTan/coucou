// Orca → island: port of OrcaPoller.consume / consumeAsks (macOS). Rust polls
// Orca and says which worktrees changed (orca.rs); the island decides what is
// worth an alert, because it knows which agents already report through
// Coucou's own hooks — those alert from their own pill, not twice.

import { State, type OrcaAsk } from "../core/state";
import { Sound } from "../core/sound";
import { t } from "../core/i18n";
import * as Sessions from "./sessions";
import type { IntegrationUpdate } from "../core/bridge";
import type { Island } from "./island";

export const ORCA_ID = "integration_orca";

interface OrcaRow {
  id: string;
  name: string;
  path: string;
  status: string;
  tool: string;
  prompt: string;
  lastMessage: string;
}

let seenAsks: Set<string> | null = null;

function rows(data: Record<string, unknown>): OrcaRow[] {
  return (Array.isArray(data.worktrees) ? data.worktrees : []) as OrcaRow[];
}

/**
 * This poll's alert, or null: a worktree that started waiting for a permission
 * beats one that finished, and a worktree whose agent Coucou's hooks already
 * follow raises nothing here.
 */
export function orcaEvent(data: Record<string, unknown>): IntegrationUpdate["event"] {
  const all = rows(data);
  const fresh = (ids: unknown) => {
    const list = Array.isArray(ids) ? (ids as string[]) : [];
    return all.filter((r) => list.includes(r.id) && !Sessions.covers(r.path));
  };
  const attention = fresh(data.attention);
  const finished = fresh(data.finished);
  if (attention.length) {
    const waiting = all.filter((r) => r.status === "permission").length;
    const w = attention[0];
    return waiting > 1
      ? { success: false, attention: true, label: t("{n} worktrees need permission", { n: waiting }), detail: attention.map((r) => r.name).join(" · ") }
      : { success: false, attention: true, label: t("{name} needs permission", { name: w.name }), detail: [w.tool, w.prompt].filter(Boolean).join(" · ") || null };
  }
  if (finished.length) {
    const w = finished[0];
    return { success: true, label: t("{name} finished", { name: w.name }), detail: w.lastMessage || w.prompt || null };
  }
  return null;
}

/** No worktree waits for a permission any more (answered in Orca): the badge goes. */
export function orcaSettle(data: Record<string, unknown>) {
  const task = State.tasks.find((x) => x.id === ORCA_ID);
  if (!task || task.state !== "approval" || rows(data).some((r) => r.status === "permission")) return;
  task.state = "idle";
  task.pillBadge = null;
}

/**
 * A question or gate seen for the first time opens the ask view; one answered
 * elsewhere (in Orca, or by the coordinator agent) closes it.
 */
export function consumeAsks(island: Island, data: Record<string, unknown>) {
  const asks = (Array.isArray(data.asks) ? data.asks : []) as OrcaAsk[];
  const previous = seenAsks;
  seenAsks = new Set(asks.map((a) => a.id));
  State.orcaAsks = asks;
  const shown = State.orcaAsk;
  if (shown && !asks.some((a) => a.id === shown.id)) {
    State.orcaAsk = null;
    if (State.view === "orcaAsk") island.orcaAskDone();
  }
  if (!previous || State.orcaAsk) return;
  const ask = asks.find((a) => !previous.has(a.id));
  if (!ask) return;
  Sound.play("approval");
  island.openOrcaAsk(ask);
}
