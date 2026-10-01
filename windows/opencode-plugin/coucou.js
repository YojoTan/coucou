// coucou.js — Coucou plugin for opencode (experimental).
//
// Forwards opencode session, tool and permission events to Coucou through the
// same relay Claude Code hooks use — coucou-hook.exe on Windows, nb-hook on
// macOS — tagged `--agent opencode`, so the island gives opencode its own pill
// and lets you approve its permission requests. Based on upstream PR #19.
//
// Never block opencode:
//   * every event but a permission request is fire-and-forget, 2 s at most;
//   * a permission request waits up to 110 s for the island; no answer
//     (Coucou closed, timeout, relay missing) changes nothing and opencode
//     asks in its own TUI exactly as if Coucou weren't installed.
//
// Installed to ~/.config/opencode/plugins/coucou.js from Coucou's settings
// (preview first; a foreign file of the same name is never overwritten).
// opencode loads files in that folder at startup.
//
// COUCOU_PLUGIN_VERSION is read by the installers (do not rename). Bump it on
// any protocol change so outdated copies are offered an update.
const COUCOU_PLUGIN_VERSION = 2;

// ── Relay ─────────────────────────────────────────────────────────────────────

function relayPath() {
  try {
    const env = typeof process !== "undefined" ? process.env : {};
    if (env.LOCALAPPDATA) return `${env.LOCALAPPDATA}\\Coucou\\bin\\coucou-hook.exe`;
    if (env.HOME) return `${env.HOME}/Library/Application Support/NotchBuddy/nb-hook`;
  } catch { /* no process.env — no relay */ }
  return "";
}

/**
 * Runs the relay with the payload on stdin and returns its trimmed stdout —
 * "" when the relay is missing, crashed or ran out of time. Never throws.
 */
async function relay(event, payload, timeoutMs, $) {
  const exe = relayPath();
  if (!exe) return "";
  const body = `${JSON.stringify({ ...payload, hook_event_name: event })}\n`;
  try {
    if ($) {
      // Bun's shell quotes interpolated values: the path stays one argument.
      const proc = $`${exe} --agent opencode ${event}`.stdin(body).quiet().nothrow();
      const out = await Promise.race([
        proc.then((r) => (r && r.stdout ? r.stdout.toString() : "")),
        new Promise((resolve) => setTimeout(() => resolve(""), timeoutMs)),
      ]);
      return String(out ?? "").trim();
    }
  } catch { /* fall back to child_process */ }
  try {
    // eslint-disable-next-line @typescript-eslint/no-require-imports
    const { spawnSync } = require("node:child_process");
    const res = spawnSync(exe, ["--agent", "opencode", event], {
      input: body,
      encoding: "utf8",
      timeout: timeoutMs,
      windowsHide: true,
    });
    return String(res.stdout ?? "").trim();
  } catch {
    return "";
  }
}

function fireAndForget(event, payload, $) {
  void relay(event, payload, 2000, $).catch(() => {});
}

// ── Payload helpers (event shapes vary across opencode versions) ─────────────

function pick(obj, paths) {
  for (const p of paths) {
    const v = p.split(".").reduce((o, k) => (o == null ? o : o[k]), obj);
    if (typeof v === "string" && v) return v;
    if (typeof v === "number") return String(v);
  }
  return "";
}

function sessionIdOf(input) {
  return pick(input, ["sessionID", "session.id", "sessionId", "properties.sessionID", "id"]) || "opencode";
}

/** The relay answers in Claude Code's shape; opencode wants allow / deny. */
function translateDecision(stdout) {
  if (!stdout) return null;
  try {
    const behavior = JSON.parse(stdout)?.hookSpecificOutput?.decision?.behavior;
    if (behavior === "allow" || behavior === "deny") return behavior;
  } catch { /* not JSON */ }
  return null;
}

// ── Plugin ────────────────────────────────────────────────────────────────────

export const CoucouPlugin = async ({ $, directory }) => {
  const cwd = directory || (typeof process !== "undefined" ? process.cwd() : "");
  const base = (extra = {}) => ({ cwd, ...extra });

  return {
    event: async ({ event }) => {
      const type = event?.type ?? "";
      const props = event?.properties ?? {};
      const session_id = sessionIdOf(props);
      if (type === "session.created") fireAndForget("SessionStart", base({ session_id }), $);
      else if (type === "session.idle") fireAndForget("Stop", base({ session_id }), $);
      else if (type === "session.error") {
        fireAndForget("StopFailure", base({ session_id, message: pick(props, ["error.message", "message"]) }), $);
      } else if (type === "session.deleted") fireAndForget("SessionEnd", base({ session_id }), $);
    },

    "chat.message": async (input, output) => {
      const prompt = pick(output ?? {}, ["message.content", "parts.0.text"]) || pick(input ?? {}, ["message.content", "content"]);
      if (prompt) {
        fireAndForget("UserPromptSubmit", base({ session_id: sessionIdOf(input), prompt: prompt.slice(0, 2000) }), $);
      }
    },

    "tool.execute.before": async (input, output) => {
      const tool = pick(input, ["tool", "toolName", "name"]) || "Tool";
      const args = (output && typeof output.args === "object" && output.args) || input.args || {};
      fireAndForget("PreToolUse", base({ session_id: sessionIdOf(input), tool_name: tool, tool_input: args }), $);
    },

    "tool.execute.after": async (input, output) => {
      const failed = Boolean(output?.error || input?.error);
      fireAndForget(failed ? "PostToolUseFailure" : "PostToolUse", base({ session_id: sessionIdOf(input) }), $);
    },

    // The only hook that waits. `output.status` is opencode's answer field;
    // anything but a clear allow/deny leaves it as it was ("ask").
    "permission.ask": async (input, output) => {
      const tool = pick(input, ["type", "tool", "permission", "title"]) || "Tool";
      const args = input?.metadata || input?.pattern || {};
      const stdout = await relay(
        "PermissionRequest",
        base({ session_id: sessionIdOf(input), tool_name: tool, tool_input: typeof args === "object" ? args : { pattern: String(args) } }),
        110_000,
        $,
      ).catch(() => "");
      const decision = translateDecision(stdout);
      if (decision && output && typeof output === "object") output.status = decision;
    },
  };
};

export default CoucouPlugin;
