// The island ↔ the desktop Mochi (Rust pet.rs, windows src/pet/). The island
// stays the one place that knows what Mochi is up to: it sends the pet its look
// and its toasts, fills its menu, and runs what the menu picks.

import { emitTo } from "@tauri-apps/api/event";
import { invoke } from "@tauri-apps/api/core";
import { IS_TAURI, onEvent, Bridge } from "../core/bridge";
import { State, type LanPrompt } from "../core/state";
import { Sound } from "../core/sound";
import { t } from "../core/i18n";
import { colorForProject } from "../core/layout";
import { liveSessions } from "./sessions";
import type { BotEngine } from "../mochi/engine";
import type { PetFx, PetSnapshot } from "../pet/pet";
import { beginRun } from "./worktrees";
import type { Island } from "./island";

let lastLook = "";
let lastToast: number | null = null;
let menuShownAt = 0;
let lastCard = "";
let cardShownAt: { id: string; at: number } | null = null;
let lastSquad = "";
let lastLan: LanPrompt | null = null;

const AGENT_NAMES: Record<string, string> = { claude: "Claude Code", codex: "Codex", opencode: "opencode" };

/** The pet says something in its bubble (an answer, a hello). */
export function petSay(text: string, seconds: number) {
  if (out()) void emitTo("pet-bubble", "pet-say", { text, seconds, translate: false });
}

function news() {
  if (out()) void invoke("pet_news");
}

/** The permission card beside the pet: the pending request, or none. */
function cardData() {
  const a = State.pendingApproval;
  return a ? { requestId: a.requestId, agent: AGENT_NAMES[a.agent] ?? "Claude Code", project: a.project, command: a.command || a.tool || "…" } : null;
}

function sendCard(force = false) {
  const data = cardData();
  const key = JSON.stringify(data);
  if (!force && key === lastCard) return;
  const wasShown = lastCard !== "" && lastCard !== "null";
  lastCard = key;
  if (data && cardShownAt?.id !== data.requestId) cardShownAt = { id: data.requestId, at: performance.now() };
  void invoke("pet_card", { kind: "approval", show: data != null, count: 0 });
  void emitTo("pet-approval", "pet-card", data);
  if (data && !wasShown) news();
}

/** A tiny Mochi per live coding-agent session, then per busy Orca worktree, at most 8. */
function squadMembers() {
  const out: { id: string; name: string; color: string; state: string }[] = [];
  for (const s of liveSessions()) {
    out.push({ id: s.key, name: `${AGENT_NAMES[s.agent] ?? s.agent} · ${s.project}`, color: colorForProject(s.project), state: s.state });
  }
  const worktrees = (State.integrations.integration_orca?.data?.worktrees ?? []) as { id: string; name: string; status: string }[];
  for (const w of worktrees) {
    if (w.status === "working" || w.status === "permission") {
      out.push({ id: `orca:${w.id}`, name: `Orca · ${w.name}`, color: "#8B5CF6", state: w.status === "permission" ? "approval" : "working" });
    }
  }
  return out.slice(0, 8);
}

function sendSquad(force = false) {
  const members = squadMembers();
  const key = JSON.stringify(members);
  if (!force && key === lastSquad) return;
  lastSquad = key;
  void invoke("pet_card", { kind: "squad", show: members.length > 0, count: members.length });
  void emitTo("pet-squad", "pet-squad", members);
}

/** A paired Mochi sends something: its Mochi walks in to say so. */
function visitors() {
  const p = State.lanPrompt;
  if (p === lastLan) return;
  lastLan = p;
  if (p?.kind === "file") void invoke("pet_visit", { name: p.peer, saying: t("{name} brought you {file} 📦", { name: p.peer, file: p.name }) });
  else if (p?.kind === "message") void invoke("pet_visit", { name: p.peer, saying: t("{name} left you a message ✉️", { name: p.peer }) });
}

/** "Ask Mochi…" in the pet's menu: the answer shows in its bubble, the whole of it in the chat. */
async function ask(text: string) {
  State.promptContext = null;
  State.chatHistory.push({ id: Date.now(), role: "user", content: text });
  State.stateOverride = "thinking";
  State.notify();
  petSay(t("Thinking…"), 30);
  try {
    const reply = await Bridge.chatSend(text, null, null);
    State.chatHistory.push({ id: Date.now() + 1, role: "assistant", content: reply.text });
    petSay(reply.text.slice(0, 280), 14);
    Sound.play("finish");
  } catch (err) {
    petSay(t(String(err).replace(/^Error:\s*/, "")), 6);
    Sound.play("error");
  } finally {
    State.stateOverride = null;
    State.notify();
    news();
  }
}

function out(): boolean {
  return IS_TAURI && State.settings.desktopMochi === true;
}

/** After the island dressed its own Mochi: the pet wears the same, says the same. */
export function petSync(e: BotEngine) {
  if (!out()) {
    lastLook = "";
    return;
  }
  const focus = State.focusTask;
  const snap: PetSnapshot = {
    state: State.effectiveState,
    color: focus?.isIntegration ? focus.color : null,
    accessory: e.accessory,
    accessoryColor: e.accessoryColor,
    sweating: e.sweating,
    sleepy: e.sleepy,
    scruffy: e.scruffy,
    panicked: e.panicked,
    musicHeadphones: e.musicHeadphones,
    musicPlaying: e.musicPlaying,
    voiceHeadset: e.voiceHeadset,
    talking: e.talking,
    micMuted: e.micMuted,
    deafened: e.deafened,
    othersSpeaking: e.othersSpeaking,
    callStartedAt: e.callStartedAt,
  };
  const key = JSON.stringify(snap);
  if (key !== lastLook) {
    lastLook = key;
    void emitTo("pet", "pet-sync", snap);
  }
  // While a permission waits, its card speaks; the bubble keeps quiet.
  const toast = State.pendingApproval ? null : State.toast;
  if ((toast?.id ?? null) !== lastToast) {
    lastToast = toast?.id ?? null;
    void emitTo("pet-bubble", "pet-toast", toast ? { text: toast.text, color: toast.color } : null);
    if (toast) news();
  }
  sendCard();
  sendSquad();
  visitors();
  // The menu, while it shows, follows what changes (a toast, the worktrees).
  if (performance.now() - menuShownAt < 120_000) sendMenu();
}

/** A greeting, a reaction: the pet does it too. */
export function petFx(fx: PetFx) {
  if (out()) void emitTo("pet", "pet-fx", fx);
}

let lastMenu = "";
function sendMenu(force = false) {
  const focus = State.focusTask;
  const step = focus?.steps.at(-1);
  const data = {
    color: focus?.color ?? "#F5F6F8",
    status: State.toast?.text ?? (focus && step ? `${focus.name} · ${step}` : focus?.name ?? ""),
    repos: State.worktrees,
  };
  const key = JSON.stringify(data);
  if (!force && key === lastMenu) return;
  lastMenu = key;
  void emitTo("pet-menu", "pet-menu-data", data);
}

type PetChoice =
  | { kind: "island" | "chat" | "worktrees" }
  | { kind: "run"; repoId: string; actionId: string; worktreePath?: string }
  | { kind: "reveal"; repoId: string; path: string }
  | { kind: "ask"; text: string };

export function registerPetHandlers(island: Island) {
  const opened = () => {
    menuShownAt = performance.now();
    sendMenu(true);
  };
  void onEvent<null>("pet-menu-open", opened);
  void onEvent<null>("pet-menu-ready", opened);
  void onEvent<null>("pet-docked", () => island.petHome());
  // The pet's own windows, asking for what they show, or what was clicked there.
  void onEvent<null>("pet-card-ready", () => sendCard(true));
  void onEvent<null>("pet-squad-ready", () => sendSquad(true));
  void onEvent<{ requestId: string; decision: "allow" | "deny" | "terminal"; fits: boolean }>("pet-approve", (e) => {
    const shownAt = cardShownAt?.id === e.requestId ? cardShownAt.at : null;
    island.petDecide(e.requestId, e.decision, e.fits === true, shownAt);
  });
  void onEvent<{ id: string }>("pet-squad-open", (e) => void island.petOpenSquad(e.id));
  void onEvent<string>("pet-dropped", (path) => island.petDropped(path));
  // Petting: the love sound, played here where the sounds are (and the mute is).
  void onEvent<string>("pet-sound", (name) => {
    if (name === "love") Sound.play("love");
  });
  void onEvent<PetChoice>("pet-action", (c) => {
    menuShownAt = 0;
    switch (c.kind) {
      case "island":
        island.alert(State.defaultView());
        break;
      case "chat":
        island.alert("prompt");
        break;
      case "worktrees":
        State.wtRun = null;
        island.alert("worktrees");
        void Bridge.worktreesRefresh();
        break;
      case "run": {
        const repo = State.worktrees.find((r) => r.id === c.repoId);
        const action = repo?.description.actions.find((a) => a.id === c.actionId);
        const wt = c.worktreePath ? repo?.worktrees.find((w) => w.path === c.worktreePath) ?? null : null;
        if (repo && action && (action.scope === "repo" || wt)) beginRun(repo.id, action, wt);
        break;
      }
      case "reveal":
        void Bridge.worktreesReveal(c.repoId, c.path);
        break;
      case "ask":
        void ask(c.text.slice(0, 2000));
        break;
    }
  });
}
