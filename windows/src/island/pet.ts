// The island ↔ the desktop Mochi (Rust pet.rs, windows src/pet/). The island
// stays the one place that knows what Mochi is up to: it sends the pet its look
// and its toasts, fills its menu, and runs what the menu picks.

import { emitTo } from "@tauri-apps/api/event";
import { IS_TAURI, onEvent, Bridge } from "../core/bridge";
import { State } from "../core/state";
import type { BotEngine } from "../mochi/engine";
import type { PetFx, PetSnapshot } from "../pet/pet";
import { beginRun } from "./worktrees";
import type { Island } from "./island";

let lastLook = "";
let lastToast: number | null = null;
let menuShownAt = 0;

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
  const toast = State.toast;
  if ((toast?.id ?? null) !== lastToast) {
    lastToast = toast?.id ?? null;
    void emitTo("pet-bubble", "pet-toast", toast ? { text: toast.text, color: toast.color } : null);
  }
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
  | { kind: "reveal"; repoId: string; path: string };

export function registerPetHandlers(island: Island) {
  const opened = () => {
    menuShownAt = performance.now();
    sendMenu(true);
  };
  void onEvent<null>("pet-menu-open", opened);
  void onEvent<null>("pet-menu-ready", opened);
  void onEvent<null>("pet-docked", () => island.petHome());
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
    }
  });
}
