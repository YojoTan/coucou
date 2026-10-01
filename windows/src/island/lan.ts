// Mochis on the network → island state: the peers list for the pill, the
// prompts a peer raises, and what this Mochi is doing, for paired peers that
// ask (`status?`). Rust owns the network; this file only reacts.

import { onEvent, Bridge } from "../core/bridge";
import { Sound } from "../core/sound";
import { State, type LanPrompt, type LanView } from "../core/state";
import type { Island } from "./island";

export function registerLanHandlers(island: Island) {
  void onEvent<LanView>("lan-state", (view) => {
    State.lan = view;
    State.integrations.integration_lan = { data: { view }, error: null, loaded: true, configured: view.enabled };
    State.notify();
  });
  void onEvent<LanPrompt>("lan-prompt", (p) => {
    if (State.paused && p.kind !== "paired") return;
    State.lanPrompt = p;
    // A code to compare or a file to accept waits for its click.
    const decision = p.kind === "pair" || p.kind === "file";
    if (decision) State.isPinned = true;
    Sound.play(decision ? "approval" : p.kind === "message" ? "pop" : "blip");
    island.alert("lan");
  });
  void Bridge.lanState().then((view) => {
    if (!view) return;
    State.lan = view;
    State.integrations.integration_lan = { data: { view }, error: null, loaded: true, configured: view.enabled };
    State.notify();
  });

  // What this Mochi is doing, told to Rust when it changes (paired peers read it).
  let last = "";
  State.subscribe(() => {
    if (!State.lan.running) return;
    const task = State.focusTask;
    const state = State.stateOverride ?? task?.state ?? "idle";
    const label = task && task.state !== "idle" ? task.name : "";
    const key = `${state}|${label}`;
    if (key === last) return;
    last = key;
    void Bridge.lanSetStatus(state, label);
  });
}
