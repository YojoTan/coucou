// Entry point: boot the bridge, wire the island, start the greeting.

import { callSilences, registerDiscordHandlers } from "./island/discord";
import { registerExtrasHandlers } from "./island/extras";
import { registerWorktreeHandlers } from "./island/worktrees";
import { registerLanHandlers } from "./island/lan";
import "./style.css";
import { Bridge, IS_TAURI, onEvent } from "./core/bridge";
import { Sound } from "./core/sound";
import { State, silences, type Settings } from "./core/state";
import { setLanguage } from "./core/i18n";
import { Island } from "./island/island";
import { registerHookHandlers } from "./island/hooks";
import { registerIntegrationHandlers, refreshConfigured } from "./island/integrations";

async function main() {
  const root = document.getElementById("root");
  if (!root) return;

  void Sound.preload();

  // The language first: every label is built in it. A preference that differs
  // from what the page loaded with means one reload, then never again.
  const boot = await Bridge.boot();
  if (boot) {
    State.settings = { ...State.settings, ...boot.settings };
    if (setLanguage(boot.settings.language)) {
      location.reload();
      return;
    }
  }

  const island = new Island(root);
  island.applySettings();
  State.loadIntegrationTasks();

  await onEvent<{ x: number; y: number; down?: boolean }>("cursor", ({ x, y, down }) => island.onCursor(x, y, down ?? false));
  // A release anywhere on screen: ends a drag of Mochi out of the island.
  await onEvent<{ x: number; y: number }>("mouse-up", ({ x, y }) => island.onMouseUp(x, y));

  /** Pause has to reach Rust too, or the pollers keep calling out. */
  const setPaused = (on: boolean) => {
    if (State.paused === on) return;
    State.paused = on;
    void Bridge.setPaused(on);
  };

  await onEvent<string>("tray", (what) => {
    switch (what) {
      case "settings":
        setPaused(false);
        island.alert("settings");
        break;
      case "open":
        setPaused(false);
        island.alert(State.defaultView());
        break;
      case "pause":
        setPaused(!State.paused);
        if (State.paused) island.fsm.forceHidden();
        else island.reveal();
        break;
    }
  });

  await onEvent<null>("screen-changed", () => void Bridge.reposition());

  // The global shortcut (Settings → General): straight to the chat, focused.
  await onEvent<null>("hotkey", () => island.alert("prompt"));
  await onEvent<null>("outside-click", () => island.dismissOutside());

  // The settings window writes preferences; apply them here without a restart.
  await onEvent<Settings>("settings-changed", (s) => {
    if (setLanguage(s.language)) {
      location.reload();
      return;
    }
    State.settings = { ...State.settings, ...s };
    if (silences(State.settings.focusMode)) State.clearToasts();
    island.applySettings();
    State.loadIntegrationTasks();
    void refreshConfigured();
  });

  // Do Not Disturb and Sleep keep Coucou quiet; a toast shows the hidden island.
  // A Discord call too: now, after the conversation's pause, or never (counted).
  Sound.silenced = (name) => silences(State.settings.focusMode) || callSilences(name);
  State.onToast = () => island.reveal();

  registerHookHandlers(island);
  registerIntegrationHandlers(island);
  registerLanHandlers(island);
  registerDiscordHandlers(island);
  registerExtrasHandlers(island);
  registerWorktreeHandlers(island);

  island.launch();

  // In a plain browser there is no wake strip behind the cursor: make the whole
  // page wake the island so the visuals can be checked with `npm run dev`.
  if (!IS_TAURI) {
    document.addEventListener("click", () => Sound.resume(), { once: true });
  }
}

void main();
