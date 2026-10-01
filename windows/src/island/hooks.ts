// Coding-agent hook events → island state: Claude Code, plus Codex and opencode
// (tagged `coucou_agent` by coucou-hook). Port of HookServer.processEvent /
// processPermissionRequest from the macOS app. Each event updates its own
// session (sessions.ts); the agent's pill mirrors the session it shows.
// Difference from macOS: no terminal filter. On Windows the hook fires from any
// terminal (Windows Terminal, VS Code, PowerShell…) and all of them are handled.

import type { HostProc } from "../core/bridge";
import { Bridge, onEvent } from "../core/bridge";
import { Sound } from "../core/sound";
import { State } from "../core/state";
import { revealInvisible } from "../views/dom";
import type { Island } from "./island";
import * as Sessions from "./sessions";
import { petSessionFinished, say } from "./extras";
import { t } from "../core/i18n";

/** Clears the approval card if no decision was made before the hook gave up. */
let pendingTimeout: number | null = null;

interface HookPayload {
  hook_event_name?: string;
  request_id?: string;
  session_id?: string;
  cwd?: string;
  message?: string;
  /** UserPromptSubmit carries `prompt`; `message` belongs to Notification/Stop. */
  prompt?: string;
  tool_name?: string;
  tool_input?: Record<string, unknown>;
  /** Set by coucou-hook when it had to cut a field to fit the pipe. */
  coucou_truncated?: boolean;
  /** Stop only: the start of Claude's last reply, read from its transcript. */
  summary?: string;
  /** Codex sends its final reply here on Stop. */
  last_assistant_message?: string;
  /** "codex" or "opencode"; absent for Claude Code. */
  coucou_agent?: string;
  /** Set by Rust from the pipe's client process: the session's host chain. */
  coucou_host?: HostProc[];
  /** SessionStart: "compact" when Codex compacts mid-turn. */
  source?: string;
}

const PROJECT_ALIASES: Record<string, string> = {
  "notch-buddy": "Notch Buddy",
  notchbuddy: "Notch Buddy",
  notch_buddy: "Notch Buddy",
};

function aliasProjectName(name: string): string {
  return PROJECT_ALIASES[name.toLowerCase()] ?? name;
}

function lastPathComponent(p: string): string {
  const cleaned = p.replace(/[\\/]+$/, "");
  const idx = Math.max(cleaned.lastIndexOf("\\"), cleaned.lastIndexOf("/"));
  return idx >= 0 ? cleaned.slice(idx + 1) : cleaned;
}

/** frenchStep() — same labels as the macOS app. */
const TOOL_LABELS: Record<string, string> = {
  Bash: "Exécute",
  Read: "Lit",
  Write: "Écrit",
  Edit: "Modifie",
  Glob: "Cherche",
  Grep: "Recherche",
  WebSearch: "Recherche web",
  WebFetch: "Récupère",
  TodoWrite: "Tâches",
  Task: "Agent",
  LS: "Liste",
  MultiEdit: "Modifie",
  NotebookEdit: "Notebook",
  PowerShell: "Exécute",
};

function stepLabel(tool: string, input: Record<string, unknown>): string {
  const label = TOOL_LABELS[tool] ?? tool;
  const str = (k: string) => (typeof input[k] === "string" ? (input[k] as string) : null);
  const cmd = str("command");
  if (cmd) return `${label} · ${cmd.slice(0, 40)}`;
  const path = str("path");
  if (path) return `${label} · ${lastPathComponent(path)}`;
  const file = str("file_path");
  if (file) return `${label} · ${lastPathComponent(file)}`;
  const query = str("query");
  if (query) return `${label} · ${query.slice(0, 40)}`;
  return label;
}

/**
 * What the Allow button actually authorises. Approving "Write" tells you nothing
 * — approving `Write · C:\…\.env` tells you everything, and the difference is
 * the whole point of approving from the island rather than blind.
 *
 * Ordered by how specific the field is, so an unfamiliar tool still shows
 * whatever identifying string it carries instead of falling back to its name.
 */
const APPROVAL_FIELDS = [
  "command", // Bash, PowerShell
  "file_path", // Write, Edit, MultiEdit, NotebookEdit
  "path", // Read, LS
  "url", // WebFetch
  "query", // WebSearch
  "pattern", // Glob, Grep
  "prompt", // Task
] as const;

function approvalTarget(tool: string, input: Record<string, unknown>): string {
  for (const field of APPROVAL_FIELDS) {
    const value = input[field];
    if (typeof value === "string" && value.trim()) {
      return revealInvisible(`${tool} · ${value.trim()}`);
    }
  }
  // An MCP or unfamiliar tool: its whole input is what is being authorised,
  // so show that rather than a bare tool name.
  if (Object.keys(input).length > 0) {
    try {
      return revealInvisible(`${tool} · ${JSON.stringify(input)}`);
    } catch {
      /* fall through to the name */
    }
  }
  return revealInvisible(tool);
}

export function registerHookHandlers(island: Island) {
  void onEvent<HookPayload>("hook", (payload) => handleHook(island, payload));
}

/** Feeds one hook payload in directly (the dev harness; Tauri uses the event). */
export function dispatchHook(island: Island, payload: Record<string, unknown>) {
  handleHook(island, payload as HookPayload);
}

/** A decision left the card: its session goes back to work. */
export function approvalResolved(sessionKey: string) {
  const s = Sessions.byKey(sessionKey);
  if (s) {
    Sessions.setState(s, "working");
    Sessions.mirror(s.agent);
  }
}

function handleHook(island: Island, payload: HookPayload) {
  if (State.paused) {
    // Silence here used to cost Claude Code nearly two minutes: the relay waited
    // for a decision from an island that had already decided not to look. Say so,
    // and the terminal takes the question immediately.
    if (payload.request_id) void Bridge.approvalDecline(payload.request_id);
    return;
  }

  const name = payload.hook_event_name ?? "";
  const cwd = payload.cwd ?? "";
  const raw = lastPathComponent(cwd);
  const projectName = aliasProjectName(raw || "Session");
  const agent = Sessions.agentOf(payload.coucou_agent);
  const TASK = Sessions.ensureAgentTask(agent);
  const s = Sessions.touch(agent, payload.session_id ?? "", projectName, cwd);
  if (Array.isArray(payload.coucou_host) && payload.coucou_host.length) s.host = payload.coucou_host;
  const focused = State.focusId === TASK;
  /** Is this event's session the one the pill is showing? */
  const isShown = () => Sessions.shown(agent)?.key === s.key;

  /** Alerts force the island open; work events only reveal the compact island. */
  const surface = (view: Parameters<Island["alert"]>[0], isAlert: boolean) => {
    if (State.mode === "expanded") {
      if (isAlert) island.setView(view);
    } else if (isAlert) {
      island.alert(view);
    } else if (State.mode === "hidden") {
      island.reveal();
    }
  };

  switch (name) {
    case "SessionStart":
      // Codex also fires SessionStart when it compacts mid-turn; that one must
      // not reset a running session.
      if (payload.source !== "compact") Sessions.setState(s, "idle");
      surface("overview", false);
      Sound.play("work");
      break;

    case "UserPromptSubmit": {
      s.summary = null;
      Sessions.setState(s, "thinking");
      // The field is `prompt`; reading `message` meant this step was always blank.
      const asked = payload.prompt ?? payload.message;
      if (asked) Sessions.addStep(s, asked.slice(0, 60));
      surface("overview", false);
      break;
    }

    case "PreToolUse": {
      Sessions.setState(s, "working");
      const tool = payload.tool_name ?? "Tool";
      Sessions.addStep(s, stepLabel(tool, payload.tool_input ?? {}));
      surface("overview", false);
      break;
    }

    case "PostToolUse":
      // Codex can deliver a PostToolUse after the turn ended; a late event must
      // not resurrect a finished session.
      if (s.state !== "finished" && s.state !== "idle") Sessions.setState(s, "working");
      break;

    case "PostToolUseFailure":
      Sessions.setState(s, "working");
      Sessions.addStep(s, "⚠ failed");
      break;

    case "Notification": {
      const message = payload.message ?? "";
      const lower = message.toLowerCase();
      if (lower.includes("rate limit") || lower.includes("limite d")) {
        Sessions.setState(s, "ratelimit");
        Sound.play("rate");
      } else if (message.endsWith("?")) {
        Sessions.setState(s, "question");
        Sessions.addStep(s, message);
      }
      break;
    }

    case "Stop": {
      const last = payload.summary ?? payload.last_assistant_message ?? null;
      s.summary = last ? last.replace(/\s+/g, " ").slice(0, 220) : null;
      Sessions.setState(s, "finished");
      if (payload.message) Sessions.addStep(s, payload.message.slice(0, 60));
      Sound.play("finish");
      // Every finished session feeds Mochi (MochiPet), and Mochi may say so.
      petSessionFinished();
      say(t("Done with {project}", { project: s.project }));
      if (focused && isShown()) surface("finished", true);
      else State.setPillBadge(TASK, "finished");
      const key = s.key;
      window.setTimeout(() => {
        const later = Sessions.byKey(key);
        if (later && later.state === "finished") {
          Sessions.setState(later, "idle");
          Sessions.mirror(agent);
        }
        State.setPillBadge(TASK, null);
        State.notify();
      }, 5200);
      break;
    }

    case "StopFailure":
      Sessions.setState(s, "error");
      Sound.play("error");
      if (focused && isShown()) surface("error", true);
      else State.setPillBadge(TASK, "error");
      break;

    case "Interrupt":
      // Codex only: the user stopped the turn.
      Sessions.setState(s, "idle");
      Sessions.addStep(s, "Interrupted");
      break;

    case "SessionEnd":
      Sessions.end(s);
      break;

    case "SubagentStart":
      Sessions.addStep(s, "+ subagent");
      break;

    case "SubagentStop":
      Sessions.addStep(s, "• subagent done");
      break;

    case "PermissionRequest": {
      const requestId = payload.request_id ?? "";
      // One card, one request. A second one must never quietly replace the first
      // — that would leave a human staring at request B while request A waits for
      // a decision nobody can give. Hand it straight back to the terminal.
      if (State.pendingApproval && State.pendingApproval.requestId !== requestId) {
        if (requestId) void Bridge.approvalDecline(requestId);
        break;
      }
      // The relay had to cut part of the request to fit the pipe, so the card
      // could only show some of what Allow would authorise. The terminal shows
      // all of it: hand it back there.
      if (payload.coucou_truncated) {
        if (requestId) void Bridge.approvalDecline(requestId);
        Sessions.addStep(s, "⚠ long request — answer in the terminal");
        break;
      }
      if (pendingTimeout != null) window.clearTimeout(pendingTimeout);
      // The pill follows the session that is asking, so the card names it.
      Sessions.unpin(agent);
      const tool = payload.tool_name ?? "Tool";
      const input = payload.tool_input ?? {};
      State.pendingApproval = {
        requestId,
        sessionId: payload.session_id ?? "",
        tool,
        command: approvalTarget(tool, input),
        agent,
        sessionKey: s.key,
        project: s.project,
      };
      // The relay's short ack window closes in 800 ms; everything below this
      // line is synchronous, so the card really is up by the time it lands.
      if (requestId) void Bridge.approvalAck(requestId);
      Sessions.setState(s, "approval");
      State.isPinned = true;
      Sound.play("approval");
      if (focused) {
        island.alert("approval");
      } else {
        // Another pill holds the view, so the card would yank it away. The badge
        // is the signal instead — but it has to be on screen for that to mean
        // anything, hence the reveal. We just told the relay a human can act.
        State.setPillBadge(TASK, "approval");
        island.reveal();
      }
      // Coucou answers within 108 s or not at all; after that the terminal has
      // taken over and the card would be lying.
      const key = s.key;
      pendingTimeout = window.setTimeout(() => {
        pendingTimeout = null;
        if (!State.pendingApproval) return;
        State.pendingApproval = null;
        State.isPinned = false;
        island.dropPin();
        approvalResolved(key);
        State.setPillBadge(TASK, null);
        if (State.view === "approval") island.setView(State.defaultView());
        State.notify();
      }, 110_000);
      break;
    }

    default:
      break;
  }
  Sessions.mirror(agent);
  State.notify();
}
