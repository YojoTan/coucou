// Thin wrapper over the Tauri commands/events. Every call is a no-op when the
// page is opened in a plain browser, so the island can be iterated on with
// `npm run dev` alone.

import type { DiscordSnapshot, LanView } from "./state";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { getCurrentWebview } from "@tauri-apps/api/webview";
import type { Settings } from "./state";

export const IS_TAURI =
  typeof window !== "undefined" && "__TAURI_INTERNALS__" in window;

async function call<T>(cmd: string, args?: Record<string, unknown>): Promise<T | null> {
  if (!IS_TAURI) return null;
  try {
    return await invoke<T>(cmd, args);
  } catch (err) {
    console.error(`[coucou] ${cmd} failed`, err);
    return null;
  }
}

export interface BootInfo {
  settings: Settings;
  /** Logical screen rect of the monitor the island lives on. */
  screen: { x: number; y: number; width: number; height: number; scale: number };
  version: string;
  hookPath: string;
}

export const Bridge = {
  boot: () => call<BootInfo>("boot"),

  saveSettings: (settings: Settings) => call<void>("save_settings", { settings }),

  /** Shrink the window down to the invisible wake strip (hidden) or back to full. */
  setCollapsed: (collapsed: boolean) => call<void>("set_collapsed", { collapsed }),

  /**
   * Pushes the island shape in window coordinates. Rust flips click-through from
   * its own cursor poll, so the flag is never a frame behind a click.
   */
  setIslandRect: (x: number, y: number, width: number, height: number) =>
    call<void>("set_island_rect", { x, y, width, height }),

  /** Give the window keyboard focus (chat field) and take it away again. */
  focusWindow: (focused: boolean) => call<void>("focus_window", { focused }),

  reposition: () => call<void>("reposition"),

  openUrl: (url: string) => call<void>("open_url", { url }),

  /** "Open terminal" → opens the folder in VS Code when `code` is on PATH. */
  openInVSCode: (path: string | null) => call<boolean>("open_in_vscode", { path }),

  quit: () => call<void>("quit_app"),

  openSettingsWindow: () => call<void>("open_settings_window"),

  /** Writes to %LOCALAPPDATA%\Coucou\coucou.log, next to the Rust lines. */
  log: (message: string) => call<void>("log_line", { message }),

  // ── Claude Code hooks ─────────────────────────────────────────────────────
  /** `target`: "claude" (default) or "codex". */
  hooksStatus: (target?: HookTarget) => call<HookStatus>("hooks_status", { target }),
  /** Diff to show before anything is written. `install: false` previews removal. */
  hooksPreview: (install: boolean, target?: HookTarget) =>
    callOrThrow<HookPreview>("hooks_preview", { install, target }),
  /**
   * Writes ~/.claude/settings.json — only ever after an explicit click, and only
   * when the file still matches the preview the user looked at.
   */
  hooksApply: (install: boolean, fingerprint: string, target?: HookTarget) =>
    callOrThrow<string>("hooks_apply", { install, fingerprint, target }),

  approvalDecision: (requestId: string, decision: "allow" | "deny") =>
    call<void>("approval_decision", { requestId, decision }),
  /** "The card is up" — until this lands the relay only waits a moment. */
  approvalAck: (requestId: string) => call<void>("approval_ack", { requestId }),
  /** "Nobody can act on this" — Claude Code asks in the terminal right away. */
  approvalDecline: (requestId: string) => call<void>("approval_decline", { requestId }),

  // ── Chat, files, secrets ──────────────────────────────────────────────────
  /** One chat turn. The API key and any file bytes never leave Rust. */
  chatSend: (query: string, context: ChatContext | null, tuning: ChatTuning | null = null) =>
    callOrThrow<{ text: string }>("chat_send", { query, context, tuning }),
  /** Model and effort menus for the engine answering now (tuning.rs). */
  chatChoices: () => call<ChatChoices>("chat_choices"),
  chatReset: () => call<void>("chat_reset"),
  /** Clipboard text — only ever read on an explicit click in the chat. */
  clipboardText: () => call<string | null>("clipboard_text"),
  hotkeyChoices: () => call<[string, string][]>("hotkey_choices"),
  // ── Extras ────────────────────────────────────────────────────────────────
  /** Settings › Extras → City: the place Open-Meteo knows by that name. */
  extrasGeocode: (city: string, language: string) => call<{ name: string; lat: number; lon: number } | null>("extras_geocode", { city, language }),
  /** A city or calendar address changed: fetch now. */
  extrasRefresh: (what: "weather" | "calendar") => call<void>("extras_refresh", { what }),
  /** A custom Mochi's card → Run now. */
  customRun: (id: string) => call<boolean>("custom_run", { id }),
  /** Settings › Extras: this PC's token for the local URL. */
  localUrlToken: () => call<string | null>("local_url_token"),
  /** `orca open`: launches or focuses Orca. */
  openOrca: () => call<boolean>("open_orca"),
  /** Orca card → a row: Orca on that worktree agent's terminal. */
  orcaFocus: (id: string) => call<boolean>("orca_focus", { id }),
  /** Orca card → ±: the worktree's changes as diffs in Orca. */
  orcaOpenChanges: (id: string) => callOrThrow<void>("orca_open_changes", { id }),
  /** The Orca question view: answers as the Run's coordinator; rejects with Orca's message. */
  orcaAnswer: (id: string, text: string) => callOrThrow<void>("orca_answer", { id, text }),
  /** Drag-out of Mochi: captures the window under the cursor into the inbox. */
  attachWindow: () => callOrThrow<AttachedWindow>("attach_window"),
  /** Focuses the terminal window hosting a session; false → nothing found. */
  focusSession: (host: HostProc[], cwd: string | null) => call<boolean>("focus_session", { host, cwd }),
  // ── Mochis on the network ─────────────────────────────────────────────────
  lanState: () => call<LanView>("lan_state"),
  lanPair: (id: string) => callOrThrow<void>("lan_pair", { id }),
  lanDecide: (token: string, ok: boolean) => call<void>("lan_decide", { token, ok }),
  lanForget: (id: string) => call<void>("lan_forget", { id }),
  lanMessage: (id: string, text: string) => callOrThrow<void>("lan_message", { id, text }),
  lanAsk: (id: string, text: string) => callOrThrow<string>("lan_ask", { id, text }),
  lanSendFile: (id: string, path: string) => callOrThrow<void>("lan_send_file", { id, path }),
  lanSetStatus: (state: string, label: string) => call<void>("lan_set_status", { state, label }),
  lanReveal: (path: string) => call<boolean>("lan_reveal", { path }),
  /** The Open dialog; [token, file name] — the path stays in Rust. */
  lanPickFile: () => call<[string, string] | null>("lan_pick_file"),
  lanSendPicked: (id: string, token: string) => callOrThrow<void>("lan_send_picked", { id, token }),
  // ── Discord ───────────────────────────────────────────────────────────────
  discordState: () => call<DiscordSnapshot | null>("discord_state"),
  discordConnect: () => callOrThrow<void>("discord_connect"),
  discordSignOut: () => call<void>("discord_sign_out"),
  discordSet: (what: "mute" | "deaf" | "input" | "output", on?: boolean, id?: string) => call<void>("discord_set", { what, on, id }),
  discordOpen: (channel: string | null) => call<void>("discord_open", { channel }),
  discordPresence: (details: string | null, state: string | null) => call<void>("discord_presence", { details, state }),
  discordWebhook: (text: string, path: string | null) => callOrThrow<void>("discord_webhook", { text, path }),
  /** The "talking while muted" meter (opt-in; Rust checks the setting too). */
  discordMic: (on: boolean) => call<void>("discord_mic", { on }),
  /** Spotify pill buttons. */
  mediaControl: (action: "toggle" | "next" | "previous" | "play" | "pause") => call<void>("media_control", { action }),
  /** "token" (pasted), "gh" (local gh login) or null — never the token itself. */
  githubAuth: () => call<"token" | "gh" | null>("github_auth"),
  opencodeStatus: () => call<PluginStatus>("opencode_status"),
  opencodePluginText: () => call<string>("opencode_plugin_text"),
  opencodeApply: (install: boolean) => callOrThrow<string>("opencode_apply", { install }),
  hotkeySet: (spec: string) => callOrThrow<void>("hotkey_set", { spec }),
  /** Installed chat CLIs and their versions (slow: runs each `--version`). */
  chatEngines: () => call<EngineInfo[]>("chat_engines"),
  /** What "auto" resolves to right now: "api", a CLI id, or "" for nothing. */
  chatEngineActive: () => call<string>("chat_engine_active"),
  /** Copies a dropped file into the inbox. */
  ingestFile: (path: string) => callOrThrow<DroppedFile>("ingest_file", { path }),
  /** Only ever tells you whether a key exists — never its value. */
  secretPresent: (key: string) => call<boolean>("secret_present", { key }),
  secretSet: (key: string, value: string) => callOrThrow<void>("secret_set", { key, value }),
  secretClear: (key: string) => callOrThrow<void>("secret_clear", { key }),

  // ── Integrations ──────────────────────────────────────────────────────────
  refreshIntegration: (id: string) => call<void>("refresh_integration", { id }),
  /** Opens the configured n8n instance in the browser. */
  openN8n: () => call<void>("open_n8n"),

  /** Tray → Pause. Stops the integration pollers, not just the island. */
  setPaused: (paused: boolean) => call<void>("set_paused", { paused }),
};

export interface IntegrationUpdate {
  id: string;
  data: Record<string, unknown>;
  error: string | null;
  /** `attention`: needs the user (an Orca permission) rather than a result. */
  event: { success: boolean; attention?: boolean; label: string; detail: string | null } | null;
}

export type ChatContext =
  | { kind: "file"; name: string; path: string; note?: string }
  | { kind: "clipboard"; text: string }
  | { kind: "window"; appName: string; title: string; url?: string };

export interface EngineInfo {
  id: string;
  label: string;
  installed: boolean;
  path: string | null;
  version: string | null;
  experimental: boolean;
}

export interface DroppedFile {
  name: string;
  path: string;
  size: number;
}

export type HookTarget = "claude" | "codex";

export interface PluginStatus {
  path: string;
  installed: boolean;
  outdated: boolean;
  foreign: boolean;
  opencodeFound: boolean;
}

/** The chat's own model and effort; null fields mean "as in Settings". */
export interface ChatTuning {
  model: string | null;
  effort: string | null;
}

export interface ChatChoices {
  engine: string;
  defaultLabel: string;
  models: { id: string; label: string }[];
  efforts: string[];
}

export interface AttachedWindow {
  name: string;
  path: string;
  size: number;
  appName: string;
  title: string;
}

/** A process behind a coding-agent session (set by Rust on each hook). */
export interface HostProc {
  pid: number;
  exe: string;
}

export interface HookStatus {
  installed: boolean;
  settingsPath: string;
  hookPath: string;
  hookReady: boolean;
}

export interface HookPreview {
  diff: string;
  backup: string;
  settingsPath: string;
  /** Hand back to hooksApply so only the reviewed diff is ever written. */
  fingerprint: string;
}

/** Same as `call`, but surfaces the error so the UI can show what went wrong. */
async function callOrThrow<T>(cmd: string, args?: Record<string, unknown>): Promise<T> {
  if (!IS_TAURI) throw new Error("not running inside Coucou");
  return invoke<T>(cmd, args);
}

export type BridgeEvent =
  | { name: "cursor"; payload: { x: number; y: number; down?: boolean } }
  | { name: "tray"; payload: string }
  | { name: "hook"; payload: Record<string, unknown> }
  | { name: "screen-changed"; payload: null };

export interface DragDropPayload {
  type: "enter" | "over" | "drop" | "leave";
  paths?: string[];
}

/** Files dragged onto the island. Only reaches us when the window takes the mouse. */
export async function onDragDrop(handler: (e: DragDropPayload) => void) {
  if (!IS_TAURI) return () => {};
  return getCurrentWebview().onDragDropEvent((event) => {
    handler(event.payload as DragDropPayload);
  });
}

export async function onEvent<T>(name: string, handler: (payload: T) => void) {
  if (!IS_TAURI) return () => {};
  return listen<T>(name, (e) => handler(e.payload));
}
