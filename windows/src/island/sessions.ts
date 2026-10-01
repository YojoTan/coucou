// Coding-agent sessions — several Claude Code terminals at once, plus Codex and
// opencode (upstream issue #18 and PRs #14/#19). Every hook event updates its
// own session; each agent's pill mirrors one of them: the session the user
// picked in the overview, or else the one with the latest activity. An approval
// always brings its own session to the front, so the card names the project
// that is actually asking.

import { State, type AgentTask } from "../core/state";
import type { HostProc } from "../core/bridge";
import type { BotStateName } from "../core/layout";

export type AgentKind = "claude" | "codex" | "opencode";

export interface AgentSession {
  key: string;
  agent: AgentKind;
  project: string;
  cwd: string;
  state: BotStateName;
  steps: string[];
  summary: string | null;
  /** Wall clock, for expiry. */
  lastSeen: number;
  /** Order of activity: events can share a millisecond, a counter can't. */
  seq: number;
  /** Processes behind the session, nearest first: where "jump" looks for its window. */
  host?: HostProc[];
}

/** A session with no event for this long is gone (crashed, closed without SessionEnd). */
const STALE_MS = 30 * 60 * 1000;
const MAX_STEPS = 20;

const TASK_IDS: Record<AgentKind, string> = {
  claude: "integration_claude",
  codex: "integration_codex",
  opencode: "integration_opencode",
};

/** The pill's name when it has no session to show. */
const IDLE_NAMES: Record<AgentKind, string> = {
  claude: "VS Code",
  codex: "Codex",
  opencode: "opencode",
};

const sessions = new Map<string, AgentSession>();
let counter = 0;
const pinned: Partial<Record<AgentKind, string>> = {};

export function agentOf(tag: string | undefined): AgentKind {
  return tag === "codex" || tag === "opencode" ? tag : "claude";
}

export function taskIdFor(agent: AgentKind): string {
  return TASK_IDS[agent];
}

export function agentForTask(task: AgentTask | null | undefined): AgentKind | null {
  if (!task) return null;
  const entry = (Object.entries(TASK_IDS) as [AgentKind, string][]).find(([, id]) => id === task.id);
  return entry ? entry[0] : null;
}

/** Codex and opencode pills appear the first time their agent sends an event. */
export function ensureAgentTask(agent: AgentKind): string {
  const id = TASK_IDS[agent];
  if (agent !== "claude" && !State.liveAgents.has(id)) {
    State.liveAgents.add(id);
    State.loadIntegrationTasks();
  }
  return id;
}

function prune(now: number) {
  for (const [key, s] of sessions) {
    if (now - s.lastSeen > STALE_MS) sessions.delete(key);
  }
}

/** Finds or creates the session an event belongs to, and marks it active. */
export function touch(agent: AgentKind, sessionId: string, project: string, cwd: string): AgentSession {
  const now = Date.now();
  prune(now);
  const key = `${agent}:${sessionId || "default"}`;
  let s = sessions.get(key);
  if (!s) {
    s = { key, agent, project, cwd, state: "idle", steps: [], summary: null, lastSeen: now, seq: 0 };
    sessions.set(key, s);
  }
  if (project && project !== "Session") s.project = project;
  if (cwd) s.cwd = cwd;
  s.lastSeen = now;
  s.seq = ++counter;
  return s;
}

export function setState(s: AgentSession, state: BotStateName) {
  s.state = state;
}

export function addStep(s: AgentSession, step: string) {
  s.steps.push(step);
  if (s.steps.length > MAX_STEPS) s.steps.shift();
}

export function end(s: AgentSession) {
  sessions.delete(s.key);
  if (pinned[s.agent] === s.key) delete pinned[s.agent];
}

function live(agent: AgentKind): AgentSession[] {
  return [...sessions.values()]
    .filter((s) => s.agent === agent)
    .sort((a, b) => b.seq - a.seq);
}

/** The session the pill shows: the pinned one while it lives, else the latest. */
export function shown(agent: AgentKind): AgentSession | null {
  const all = live(agent);
  const pick = pinned[agent];
  return all.find((s) => s.key === pick) ?? all[0] ?? null;
}

/** Follow the latest activity again (an approval does this for its own agent). */
export function unpin(agent: AgentKind) {
  delete pinned[agent];
}

/** The overview's ⇄ button: show the next session of this agent. */
export function cycle(agent: AgentKind) {
  const all = live(agent);
  if (all.length < 2) return;
  const current = shown(agent);
  const i = Math.max(0, all.findIndex((s) => s.key === current?.key));
  pinned[agent] = all[(i + 1) % all.length].key;
  mirror(agent);
}

export function sessionCount(agent: AgentKind): number {
  return live(agent).length;
}

/** Copies the shown session into the agent's pill. */
export function mirror(agent: AgentKind) {
  const task = State.tasks.find((t) => t.id === TASK_IDS[agent]);
  if (!task) return;
  const s = shown(agent);
  task.sessionCount = live(agent).length;
  if (!s) {
    task.name = IDLE_NAMES[agent];
    task.steps = [];
    task.stepIndex = 0;
    task.summary = null;
    task.sessionKey = null;
    task.state = "idle";
    return;
  }
  task.name = s.project;
  task.steps = s.steps;
  task.stepIndex = Math.max(0, s.steps.length - 1);
  task.state = s.state;
  task.summary = s.summary;
  task.sessionCwd = s.cwd || task.sessionCwd;
  task.sessionKey = s.key;
}

/** Looks a session up again by key (a timer may outlive it). */
export function byKey(key: string): AgentSession | null {
  return sessions.get(key) ?? null;
}
