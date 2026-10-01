// App state — mirror of AppState.swift (the parts the island needs).

import type { BotEmoteName, BotStateName, IslandMode, IslandViewName } from "./layout";
import type { EyeShape } from "../mochi/engine";
import type { MochiAccessory } from "../mochi/accessories";

export type AgentSource = "claudeCode" | "codex" | "opencode" | "n8n";

/** The pills fed by a coding agent's hooks rather than by an API poller. */
export const AGENT_TASK_IDS = ["integration_claude", "integration_codex", "integration_opencode"];

export function isAgentTask(task: { id: string } | null | undefined): boolean {
  return !!task && AGENT_TASK_IDS.includes(task.id);
}

/** What the overview calls each source next to the project name. */
export const SOURCE_LABELS: Record<AgentSource, string> = {
  claudeCode: "Claude Code",
  codex: "Codex",
  opencode: "opencode",
  n8n: "n8n",
};
export type PillBadge = "approval" | "finished" | "error";

export interface AgentTask {
  id: string;
  name: string;
  color: string;
  state: BotStateName;
  stepIndex: number;
  steps: string[];
  source: AgentSource;
  isIntegration: boolean;
  emote?: BotEmoteName | null;
  miniEye?: EyeShape | null;
  pillBadge?: PillBadge | null;
  sessionCwd?: string | null;
  /** Start of Claude's last reply when the session stopped. */
  summary?: string | null;
  /** Agent pills: which session they show, and how many are live. */
  sessionKey?: string | null;
  sessionCount?: number;
}

export interface ApprovalInfo {
  requestId: string;
  sessionId: string;
  tool: string;
  command: string;
  /** Which agent and session asked, and its project, for the card. */
  agent: string;
  sessionKey: string;
  project: string;
}

export interface ChatMessage {
  id: number;
  role: "user" | "assistant";
  content: string;
}

export type PromptContext =
  | { kind: "window"; appName: string; title: string; url?: string }
  | { kind: "file"; name: string; path?: string };

export interface ResultItem {
  label: string;
  detail: string;
  url?: string;
}

export interface SearchResult {
  title: string;
  items: ResultItem[];
  note?: string;
}

const task = (
  id: string, name: string, color: string, source: AgentSource,
): AgentTask => ({
  id, name, color, state: "idle", stepIndex: 0, steps: [], source, isIntegration: true,
});

/** AgentTask.integrationAgents — same ids, names and colours as macOS. */
export const INTEGRATION_AGENTS: AgentTask[] = [
  task("integration_claude", "VS Code", "#F5F6F8", "claudeCode"),
  task("integration_codex", "Codex", "#10A37F", "codex"),
  task("integration_opencode", "opencode", "#F59E0B", "opencode"),
  task("integration_resend", "Resend", "#22C55E", "n8n"),
  task("integration_n8n", "n8n", "#F29B38", "n8n"),
  task("integration_vercel", "Vercel", "#7C5CFF", "n8n"),
  task("integration_github", "GitHub", "#F4505E", "n8n"),
  task("integration_notion", "Notion", "#8C8C8C", "n8n"),
  task("integration_calcom", "Cal.com", "#C9956A", "n8n"),
  task("integration_stripe", "Stripe", "#0570DE", "n8n"),
  task("integration_orca", "Orca", "#8B5CF6", "n8n"),
  task("integration_spotify", "Spotify", "#1DB954", "n8n"),
  task("integration_lan", "Mochis", "#F472B6", "n8n"),
  task("integration_discord", "Discord", "#5865F2", "n8n"),
  task("integration_calendar", "Calendar", "#FF6B6B", "n8n"),
  // macOS calls it "Mac".
  task("integration_system", "PC", "#94A3B8", "n8n"),
  task("integration_weather", "Weather", "#38BDF8", "n8n"),
];

export const TOGGLEABLE_INTEGRATION_IDS = [
  "integration_resend", "integration_n8n", "integration_vercel", "integration_github",
  "integration_notion", "integration_calcom", "integration_stripe", "integration_orca", "integration_spotify", "integration_lan", "integration_discord",
  "integration_calendar", "integration_system", "integration_weather",
];

/** Mochi as a pet (MochiPet), as saved: the island keeps the count. */
export interface PetSave {
  sessions: number;
  streak: number;
  bestStreak: number;
  /** yyyy-MM-dd (local) of the last finished session. */
  lastDay: string;
  /** null: the best trophy unlocked. */
  wearing: MochiAccessory | null;
}

/** What an integration poller last reported. */
export interface IntegrationInfo {
  data: Record<string, unknown>;
  error: string | null;
  loaded: boolean;
  configured: boolean;
}

/** Mochi's mode (macOS FocusMode). Do Not Disturb and Sleep: no sounds, no toasts. */
export type FocusMode = "normal" | "doNotDisturb" | "work" | "sleep";

export function silences(mode: FocusMode | string | undefined): boolean {
  return mode === "doNotDisturb" || mode === "sleep";
}

/** A Mochi of the user's own (Settings → Mochis extras): a command or the local URL feeds it. */
export interface CustomMochi {
  id: string;            // custom_xxxxxxxx
  name: string;
  color: string;
  accessory: MochiAccessory;
  command: string;
  interval: number;      // seconds, 0 = only the local URL
}

/** What the extras know right now (filled by their pollers). */
export interface Extras {
  weather: { place: string; temperature: number; code: number; day: boolean; rainChance: number; accessory: MochiAccessory } | null;
  system: { cpu: number; battery: number | null; charging: boolean; diskFreePercent: number; diskFreeGB: number; building: string | null } | null;
  calendarNext: { id: string; title: string; start: number; end: number; link: string | null } | null;
  pet: { level: number; streak: number; sessions: number; worn: MochiAccessory; scruffy: boolean } | null;
  customStatus: Record<string, { text: string; state: string; at: number }>;
  calendarError?: string | null;
  weatherError?: string | null;
}

/** Discord (Rust discord.rs). */
export interface DiscordMember { id: string; name: string; muted: boolean; deafened: boolean }
export interface DiscordVoice { channelId: string; name: string; members: DiscordMember[]; speaking: string[] }
export interface DiscordNote { id: string; channelId: string; author: string; text: string; reaction: "confetti" | "hearts" | "laugh" | "question" | "fire" | null }
export interface DiscordDevice { id: string; name: string }
export interface DiscordSnapshot {
  running: boolean;
  link: { kind: "notSetUp" | "offline" | "needsApproval" | "waitingApproval" | "connected" | "failed"; name?: string; message?: string };
  me: string | null;
  voice: DiscordVoice | null;
  selfMute: boolean;
  selfDeaf: boolean;
  devices: { inputs: DiscordDevice[]; outputs: DiscordDevice[]; input: string; output: string };
  notes: DiscordNote[];
  unread: number;
}
export interface DiscordPrefs {
  postFinished: boolean;
  postPermission: boolean;
  pauseSpotify: boolean;
  /** Coucou's sounds in a call: always, smart (not over a conversation), never. */
  callSounds: "always" | "smart" | "never";
  lockMute: boolean;
  presence: boolean;
  mutedAlert: boolean;
}
/** A question an Orca worker asked its Run, or a pending decision gate. */
export interface OrcaAsk {
  id: string;
  kind: "question" | "gate";
  runId: string;
  text: string;
  /** Choices, when the worker or the gate gave some: answered with a click on one. */
  options: string[];
}
export interface DiscordCallSummary { minutes: number; myShare: number; top: string | null; topShare: number; missed: number; endedAt: number }

/** One line in the compact island for a few seconds ("Ana joined"). */
export interface CompactToast {
  id: number;
  text: string;
  color: string;
}

/** Mochis on the network (Rust lan/). */
export interface LanPeer {
  id: string;
  name: string;
  paired: boolean;
  online: boolean;
  status: { state: string; label: string } | null;
}

export interface LanView {
  enabled: boolean;
  running: boolean;
  id: string;
  name: string;
  peers: LanPeer[];
}

export interface LanPrefs {
  enabled: boolean;
  name: string;
  shareLabel: boolean;
  allowAsks: boolean;
}

/** What a peer asks of this Mochi, shown in the `lan` view. */
export type LanPrompt =
  | { kind: "pair"; token: string; peer: string; code: string; initiator: boolean }
  | { kind: "file"; token: string; peer: string; name: string; size: number }
  | { kind: "message"; peer: string; peerId: string; text: string }
  | { kind: "received"; peer: string; name: string; path: string }
  | { kind: "paired"; peer: string; ok: boolean }
  | { kind: "asked"; peer: string };

export interface Settings {
  soundEnabled: boolean;
  soundVolume: number;
  autoCloseInterval: number;
  absenceInterval: number;
  activeIntegrations: string[];
  screen: "primary" | "cursor";
  autostart: boolean;
  hooksInstalled: boolean;
  /** Claude model used by the chat. */
  model: string;
  /** What answers the chat: "auto", "api", "claude", "codex", "gemini", "opencode". */
  chatEngine: string;
  /** Model passed to a CLI engine; empty = the CLI's own default. */
  cliModel: string;
  /** OpenAI-compatible endpoint, e.g. http://localhost:11434/v1 (Ollama). */
  openaiBaseUrl: string;
  openaiModel: string;
  anthropicBaseUrl: string;
  anthropicModel: string;
  /** Global shortcut that opens the chat: "off", "ctrl+alt+space", … */
  hotkey: string;
  /** Interface language: "auto" (system), "en", "es" or "pt-BR". */
  language: string;
  lan: LanPrefs;
  focusMode: FocusMode;
  customMochis?: CustomMochi[];
  discord?: DiscordPrefs;
  /** The local URL scripts call (127.0.0.1:47823): off by default. */
  localUrl?: boolean;
  weatherPlace?: { name: string; lat: number; lon: number } | null;
  pet?: PetSave;
  /** Mochi says things out loud: off by default. */
  voice?: boolean;
}

export const DEFAULT_SETTINGS: Settings = {
  soundEnabled: true,
  soundVolume: 0.12,
  autoCloseInterval: 15,
  absenceInterval: 180,
  activeIntegrations: [
    "integration_resend", "integration_n8n", "integration_vercel", "integration_github",
  ],
  screen: "cursor",
  autostart: false,
  hooksInstalled: false,
  model: "claude-opus-5",
  chatEngine: "auto",
  cliModel: "",
  openaiBaseUrl: "",
  openaiModel: "",
  anthropicBaseUrl: "",
  anthropicModel: "",
  hotkey: "ctrl+alt+space",
  language: "auto",
  lan: { enabled: false, name: "", shareLabel: false, allowAsks: false },
  focusMode: "normal",
};

type Listener = () => void;

class AppState {
  mode: IslandMode = "hidden";
  view: IslandViewName = "overview";

  tasks: AgentTask[] = [];
  focusId: string | null = null;

  stateOverride: BotStateName | null = null;

  /** Cursor in logical screen pixels, origin top-left (like AppState.mousePosition). */
  mouse = { x: 0, y: 0 };
  /** Cursor relative to the island's top-left corner. */
  mouseInIsland = { x: 0, y: 0 };

  isPinned = false;
  paused = false;

  /** Orca: the question or gate shown in the `orcaAsk` view, and every one waiting. */
  orcaAsk: OrcaAsk | null = null;
  orcaAsks: OrcaAsk[] = [];

  /** Discord: the pill's snapshot, the call that just ended, "you're muted!". */
  discord: DiscordSnapshot | null = null;
  discordLastCall: DiscordCallSummary | null = null;
  discordTalkingMuted = false;

  /** Weather, PC, calendar, pet, custom Mochis' news (the extras). */
  extras: Extras = { weather: null, system: null, calendarNext: null, pet: null, customStatus: {} };

  /** What the compact island says right now, and what waits behind it (showToast). */
  toast: CompactToast | null = null;
  private toastQueue: CompactToast[] = [];
  private toastSeq = 0;
  /** Set by the island: a toast reveals a hidden island. */
  onToast: (() => void) | null = null;

  /**
   * Shows a line in the compact island — revealing it if hidden — then clears it.
   * Toasts queue (at most 4), each gets its time; Do Not Disturb drops them.
   */
  showToast(text: string, color: string, seconds = 3.5) {
    if (silences(this.settings.focusMode)) return;
    this.toastQueue.push({ id: ++this.toastSeq, text, color });
    this.toastQueue = this.toastQueue.slice(-4);
    if (!this.toast) this.nextToast(seconds);
  }

  clearToasts() {
    this.toastQueue = [];
    this.toast = null;
    this.notify();
  }

  private nextToast(seconds: number) {
    const t = this.toastQueue.shift() ?? null;
    this.toast = t;
    this.notify();
    if (!t) return;
    this.onToast?.();
    window.setTimeout(() => {
      if (this.toast?.id === t.id) this.nextToast(seconds);
    }, seconds * 1000);
  }

  /** Mochis on the network, what one of them asks, and who the chat writes to. */
  lan: LanView = { enabled: false, running: false, id: "", name: "", peers: [] };
  lanPrompt: LanPrompt | null = null;
  peerChat: { id: string; name: string; mode: "message" | "ask" } | null = null;

  uploadProgress = 0;
  uploadDuration = 2.4;
  fileDragOver = false;

  promptContext: PromptContext | null = null;
  /** `label`/`note`: a window screenshot shows the window in its chip and tells the model what it is. */
  droppedFile: { name: string; path: string; label?: string; note?: string } | null = null;
  noteMessage: string | null = null;
  searchResult: SearchResult | null = null;
  chatHistory: ChatMessage[] = [];
  pendingApproval: ApprovalInfo | null = null;
  /** Agent pills (Codex, opencode) shown because their hooks sent something. */
  liveAgents = new Set<string>();

  integrations: Record<string, IntegrationInfo> = {};

  lastActivity = performance.now();

  settings: Settings = { ...DEFAULT_SETTINGS };

  private listeners = new Set<Listener>();

  subscribe(fn: Listener): () => void {
    this.listeners.add(fn);
    return () => this.listeners.delete(fn);
  }

  /** Marks the UI dirty; the island re-renders on the next frame. */
  notify() {
    for (const fn of this.listeners) fn();
  }

  get focusTask(): AgentTask | null {
    return this.tasks.find((t) => t.id === this.focusId) ?? this.tasks[0] ?? null;
  }

  get effectiveState(): BotStateName {
    return this.stateOverride ?? this.focusTask?.state ?? "idle";
  }

  get otherTasks(): AgentTask[] {
    return this.tasks.filter((t) => t.id !== this.focusId);
  }

  setFocus(id: string) {
    const t = this.tasks.find((x) => x.id === id);
    if (!t) return;
    this.focusId = id;
    t.pillBadge = null;
    this.notify();
  }

  updateTask(id: string, state: BotStateName) {
    const t = this.tasks.find((x) => x.id === id);
    if (!t) return;
    t.state = state;
    this.notify();
  }

  appendStep(id: string, step: string) {
    const t = this.tasks.find((x) => x.id === id);
    if (!t) return;
    t.steps.push(step);
    if (t.steps.length > 20) t.steps.shift();
    t.stepIndex = t.steps.length - 1;
    this.notify();
  }

  setPillBadge(id: string, badge: PillBadge | null) {
    const t = this.tasks.find((x) => x.id === id);
    if (!t) return;
    t.pillBadge = badge;
    this.notify();
  }

  /** loadIntegrationTasks() — VS Code always on, the rest opt-in (max 4). */
  loadIntegrationTasks() {
    for (const proto of INTEGRATION_AGENTS) {
      const shouldLoad =
        proto.id === "integration_claude" ||
        this.liveAgents.has(proto.id) ||
        this.settings.activeIntegrations.includes(proto.id);
      const idx = this.tasks.findIndex((t) => t.id === proto.id);
      if (shouldLoad && idx < 0) this.tasks.push({ ...proto, steps: [] });
      if (!shouldLoad && idx >= 0) this.tasks.splice(idx, 1);
    }
    // Custom Mochis: a pill each, named and coloured as in Settings › Extras.
    const customs = this.settings.customMochis ?? [];
    this.tasks = this.tasks.filter((t) => !t.id.startsWith("custom_") || (this.settings.activeIntegrations.includes(t.id) && customs.some((m) => m.id === t.id)));
    for (const m of customs) {
      if (!this.settings.activeIntegrations.includes(m.id)) continue;
      const existing = this.tasks.find((t) => t.id === m.id);
      if (existing) {
        existing.name = m.name;
        existing.color = m.color;
      } else {
        this.tasks.push({ ...task(m.id, m.name, m.color, "n8n"), steps: [] });
      }
    }
    // Keep the declared order so pills never shuffle.
    const order = [...INTEGRATION_AGENTS.map((t) => t.id), ...customs.map((m) => m.id)];
    this.tasks.sort((a, b) => order.indexOf(a.id) - order.indexOf(b.id));
    if (!this.focusId) this.focusId = "integration_claude";
    this.notify();
  }

  toggleIntegration(id: string) {
    if (id === "integration_claude") return;
    const active = this.settings.activeIntegrations;
    if (active.includes(id)) {
      this.settings.activeIntegrations = active.filter((x) => x !== id);
      if (this.focusId === id) this.focusId = "integration_claude";
    } else {
      if (active.length >= 4) return;
      this.settings.activeIntegrations = [...active, id];
    }
    this.loadIntegrationTasks();
  }

  defaultView(): IslandViewName {
    return this.tasks.length === 0 ? "empty" : "overview";
  }
}

export const State = new AppState();
