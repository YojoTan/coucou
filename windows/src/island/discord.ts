// Discord → island state — the TypeScript side of discord.rs, and a port of
// DiscordCall.swift (what happens around a call):
//
// • joins and leaves → a compact toast ("Ana joined"), and Mochi waves or looks sad;
// • who talks how long → a summary when the call ends ("52 min · you 61 %");
// • a paired LAN Mochi whose name matches someone in the call → a high five;
// • joining pauses Spotify, leaving resumes it (only if Coucou paused it);
// • call mode: Coucou's sounds hold their peace, the summary counts the alerts;
// • Rich Presence: what Mochi is doing, on the user's profile (opt-in).
// Locking the screen mutes in Rust (discord.rs), where the lock is seen.

import { onEvent, Bridge } from "../core/bridge";
import { Sound } from "../core/sound";
import { State, type DiscordNote, type DiscordSnapshot, type DiscordVoice } from "../core/state";
import { t } from "../core/i18n";
import type { Island } from "./island";

export const DISCORD_ID = "integration_discord";

/** Something Mochi reacts to (DiscordSync); the island applies it to the engines. */
export type DiscordEffect =
  | { kind: "note"; note: DiscordNote }
  | { kind: "joined" | "left" | "highFive" | "talkingMuted" };

const effectListeners: ((e: DiscordEffect) => void)[] = [];
export function onDiscordEffect(fn: (e: DiscordEffect) => void) {
  effectListeners.push(fn);
}
function effect(e: DiscordEffect) {
  for (const fn of effectListeners) fn(e);
}

// ── The call ────────────────────────────────────────────────────────────────

let previous: DiscordVoice | null = null;
let startedAt: number | null = null;
let talkStart = new Map<string, number>();
let talked = new Map<string, number>();
const names = new Map<string, string>();
let highFived = new Set<string>();
let pausedSpotify = false;
let missed = 0;
let deferred: string | null = null; // the sound waiting for a pause
let wasMuted = false;

/** When the call began (ms), for Mochi's fatigue. */
export function callStartedAt(): number | null {
  return startedAt;
}

/** Call mode: Sound asks before every sound (DiscordCall.shouldSilence). */
export function callSilences(name: string): boolean {
  if (startedAt == null) return false;
  switch (State.settings.discord?.callSounds ?? "smart") {
    case "always":
      return false;
    case "never":
      missed += 1;
      return true;
    default:
      if (!conversationGoing()) return false;
      deferred = name; // the latest wins; one sound when the pause comes
      return true;
  }
}

/** Mochi's voice: not over a conversation, not when the user chose silence. */
export function callWouldInterrupt(): boolean {
  if (startedAt == null) return false;
  const mode = State.settings.discord?.callSounds ?? "smart";
  return mode === "never" || (mode === "smart" && conversationGoing());
}

/** Mic open and someone speaking: the only time a sound would get in the way. */
function conversationGoing(): boolean {
  const d = State.discord;
  return (d?.voice?.speaking.length ?? 0) > 0 && !d!.selfMute && !d!.selfDeaf;
}

/** A pause (1.5 s with nobody speaking), a mute, or the end of the call: play what waited. */
function releaseDeferred(delay = 1500) {
  if (deferred == null) return;
  window.setTimeout(() => {
    const name = deferred;
    if (name == null || conversationGoing()) return;
    deferred = null;
    Sound.play(name);
  }, delay);
}

function spotifyPlaying(): boolean {
  const np = State.integrations.integration_spotify?.data?.nowPlaying as { playing?: boolean } | null | undefined;
  return np?.playing === true;
}

function highFiveIfMochi(id: string, name: string) {
  if (highFived.has(id)) return;
  const peers = State.lan.peers.filter((p) => p.paired && p.online);
  const same = (a: string, b: string) => a.localeCompare(b, undefined, { sensitivity: "base" }) === 0;
  if (!peers.some((p) => same(p.name, name))) return;
  highFived.add(id);
  State.showToast(t("🙌 {name} has a Mochi too", { name }), "#F472B6");
  effect({ kind: "highFive" });
}

function closeTalk(id: string, now: number) {
  const s = talkStart.get(id);
  if (s == null) return;
  talkStart.delete(id);
  talked.set(id, (talked.get(id) ?? 0) + (now - s));
}

function callStarted(v: DiscordVoice) {
  startedAt = Date.now();
  talkStart = new Map();
  talked = new Map();
  highFived = new Set();
  missed = 0;
  for (const m of v.members) names.set(m.id, m.name);
  const me = State.discord?.me;
  for (const m of v.members) if (m.id !== me) highFiveIfMochi(m.id, m.name);
  if (State.settings.discord?.pauseSpotify && spotifyPlaying()) {
    void Bridge.mediaControl("pause");
    pausedSpotify = true;
  }
}

function callEnded() {
  const now = Date.now();
  for (const id of [...talkStart.keys()]) closeTalk(id, now);
  const minutes = Math.round((now - (startedAt ?? now)) / 60000);
  const total = [...talked.values()].reduce((a, b) => a + b, 0);
  const me = State.discord?.me ?? "";
  const myShare = total > 0 ? (talked.get(me) ?? 0) / total : 0;
  let top: [string, number] | null = null;
  for (const [id, ms] of talked) if (id !== me && (!top || ms > top[1])) top = [id, ms];
  startedAt = null;
  releaseDeferred(300);
  if (pausedSpotify) {
    pausedSpotify = false;
    if (!spotifyPlaying()) void Bridge.mediaControl("play");
  }
  if (minutes < 1 && total === 0) return;
  State.discordLastCall = {
    minutes: Math.max(1, minutes),
    myShare,
    top: top ? names.get(top[0]) ?? "?" : null,
    topShare: top && total > 0 ? top[1] / total : 0,
    missed,
    endedAt: now,
  };
  let line = t("Call · {n} min", { n: Math.max(1, minutes) });
  if (total > 0) line += " · " + t("you {n} %", { n: Math.round(myShare * 100) });
  if (missed > 0) line += " · " + t("{n} alerts", { n: missed });
  State.showToast(line, "#5865F2", 5);
}

function voiceChanged(v: DiscordVoice | null) {
  const old = previous;
  previous = v;
  const me = State.discord?.me;
  if (!old && v) return callStarted(v);
  if (old && !v) return callEnded();
  if (!old || !v) return;
  if (old.channelId !== v.channelId) {
    callEnded();
    callStarted(v);
    return;
  }
  for (const m of v.members) names.set(m.id, m.name);
  const before = new Set(old.members.map((m) => m.id));
  const after = new Set(v.members.map((m) => m.id));
  for (const id of after) {
    if (before.has(id) || id === me) continue;
    const name = names.get(id) ?? "?";
    State.showToast(t("{name} joined", { name }), "#23A55A");
    effect({ kind: "joined" });
    highFiveIfMochi(id, name);
  }
  for (const id of before) {
    if (after.has(id) || id === me) continue;
    State.showToast(t("{name} left", { name: names.get(id) ?? "?" }), "#8E939C");
    effect({ kind: "left" });
  }
  // Talking time: a speaking set that changed opens or closes a stretch.
  const now = Date.now();
  const was = new Set(old.speaking);
  const is = new Set(v.speaking);
  for (const id of is) if (!was.has(id)) talkStart.set(id, now);
  for (const id of was) if (!is.has(id)) closeTalk(id, now);
  if (v.speaking.length === 0) releaseDeferred();
}

// ── Presence (opt-in): Claude Code at work, or what Spotify plays ───────────

let presenceTimer: number | null = null;
let lastPresence = "";
function schedulePresence() {
  if (presenceTimer != null) window.clearTimeout(presenceTimer);
  presenceTimer = window.setTimeout(() => {
    presenceTimer = null;
    if (!State.settings.discord?.presence || !State.discord?.running) return;
    const agents = ["integration_claude", "integration_codex", "integration_opencode"];
    const busy = State.tasks.find((x) => agents.includes(x.id) && (x.state === "working" || x.state === "thinking"));
    const np = State.integrations.integration_spotify?.data?.nowPlaying as { playing?: boolean; title?: string; artist?: string } | null | undefined;
    let details: string | null = null, line: string | null = null;
    if (busy) {
      const who = busy.id === "integration_codex" ? "Codex" : busy.id === "integration_opencode" ? "opencode" : "Claude Code";
      details = t("🤖 {who} is working", { who });
      line = t("on {project}", { project: busy.name });
    } else if (np?.playing && np.title) {
      details = `🎧 ${np.title}`;
      line = np.artist ? t("by {artist}", { artist: np.artist }) : null;
    }
    const key = `${details}|${line}`;
    if (key === lastPresence) return;
    lastPresence = key;
    void Bridge.discordPresence(details, line);
  }, 3000);
}

// ── Wiring ──────────────────────────────────────────────────────────────────

/** The pill's own alert: a sound, and a badge unless it is the focused one. */
function alert(island: Island, title: string, detail: string) {
  const task = State.tasks.find((x) => x.id === DISCORD_ID);
  if (!task) return;
  task.steps = [title, detail].filter(Boolean);
  task.stepIndex = Math.max(0, task.steps.length - 1);
  if (State.focusId !== DISCORD_ID) task.pillBadge = "approval";
  Sound.play("pop");
  island.reveal();
}

let micOn = false;
/** The meter listens only while Discord has the user muted in a call, with the switch on. */
function followMic() {
  const d = State.discord;
  const muted = !!d?.voice && (d.selfMute || d.selfDeaf);
  if (muted && !wasMuted) releaseDeferred(200);
  wasMuted = muted;
  const want = !!d?.voice && (d.selfMute || d.selfDeaf) && !!State.settings.discord?.mutedAlert;
  if (want === micOn) return;
  micOn = want;
  void Bridge.discordMic(want);
}

export function registerDiscordHandlers(island: Island) {
  // Speech while Discord has the user muted: the card's Unmute, brought up.
  void onEvent<null>("discord-talking-muted", () => {
    State.discordTalkingMuted = true;
    effect({ kind: "talkingMuted" });
    State.showToast(t("You're muted!"), "#DA373C");
    State.setFocus(DISCORD_ID);
    island.alert("overview");
    window.setTimeout(() => {
      State.discordTalkingMuted = false;
      State.notify();
    }, 8000);
  });
  const apply = (s: DiscordSnapshot) => {
    const before = State.discord;
    State.discord = s;
    State.integrations[DISCORD_ID] = { data: { ...s, talkingMuted: State.discordTalkingMuted }, error: null, loaded: true, configured: true };
    if (JSON.stringify(before?.voice ?? null) !== JSON.stringify(s.voice ?? null)) voiceChanged(s.voice);
    // A new DM or mention: a toast, the pill's alert, and Mochi's reaction.
    const newest = s.notes[0];
    if (newest && newest.id !== before?.notes[0]?.id && before) {
      State.showToast(`${newest.author}: ${newest.text}`, "#5865F2");
      alert(island, t("{name} on Discord", { name: newest.author }), newest.text);
      effect({ kind: "note", note: newest });
    }
    if (!s.selfMute && !s.selfDeaf) State.discordTalkingMuted = false;
    followMic();
    State.notify();
  };
  void onEvent<DiscordSnapshot>("discord-state", apply);
  void onEvent<{ text: string; color: string }>("discord-toast", (m) => State.showToast(t(m.text), m.color));
  void Bridge.discordState().then((s) => s && apply(s));
  State.subscribe(schedulePresence);
  State.subscribe(followMic);
}
