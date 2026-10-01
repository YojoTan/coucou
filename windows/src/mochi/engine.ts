// Mochi — direct port of NotchBuddy/Sources/App/BotEngine.swift to Canvas 2D.
// Same constants, same tweens, same easings, same particles. The only intentional
// difference is the `happy`/`wink` eye arc, which follows the prototype
// (design/prototype/notch-buddy.html, the visual source of truth) — the Swift
// arc angles produce a different shape.

import { Ease, lerp, type EaseFn } from "../core/anim";
import { Sound } from "../core/sound";
import type { BotEmoteName, BotStateName } from "../core/layout";
import { drawAccessory, updateMoods, type MochiAccessory } from "./accessories";

/** DiscordParse.DiscordReaction: how Mochi answers a DM or a mention. */
export type MochiReaction = "confetti" | "hearts" | "laugh" | "question" | "fire";

// ── Types ─────────────────────────────────────────────────────────────────────

export type EyeShape =
  | "pill" | "wide" | "dot" | "line" | "flat" | "happy" | "closed"
  | "spiral" | "heart" | "star" | "tired" | "wink" | "cup";

export type BadgeKind = "dots" | "bang" | "question" | "dot";

export interface Badge {
  kind: BadgeKind;
  color: RGB;
}

export type RGB = readonly [number, number, number]; // components 0…1

export type TweenKey = readonly [target: number, durationMs: number, ease: EaseFn];

interface Tween {
  prop: PropKey;
  keys: TweenKey[];
  index: number;
  from: number;
  startMs: number;
  onComplete?: () => void;
}

type PropKey =
  | "yaw" | "pitch" | "roll" | "tilt" | "open" | "sx" | "sy"
  | "oy" | "ox" | "tint" | "morph" | "hands" | "blush" | "es" | "badgeS";

interface BotStateCfg {
  color: RGB;
  tint: number;
  eye: EyeShape;
  badge: Badge | null;
  bounces: boolean;
  scans: boolean;
  breathes: boolean;
  zz: boolean;
  sweat: boolean;
  look: readonly [number, number] | null;
  tilt: number;
}

interface Particle {
  type: "heart" | "star" | "spark" | "sweat" | "z" | "note" | "confetti";
  x: number; y: number; vx: number; vy: number;
  age: number; life: number; rot: number; size: number;
}

// ── Constants (MochiConst / PISTES.mochi) ─────────────────────────────────────

const EYE_W = 0.25;
const EYE_H = 0.27;
const EYE_SP = 0.37;
const EYE_P = -0.12;
const BASE_TOP: RGB = [0.929, 0.929, 0.937]; // #EDEDEF
const BASE_BOTTOM: RGB = [0.769, 0.773, 0.792]; // #C4C5CA
const INK = "rgb(26,20,18)"; // #1A1412
const MINI_INK = "rgb(16,19,26)"; // #10131A

const C = {
  idle: [0.902, 0.914, 0.933] as RGB,
  working: [0.231, 0.62, 1] as RGB,
  thinking: [0.545, 0.361, 0.965] as RGB,
  searching: [0.388, 0.396, 0.949] as RGB,
  approval: [0.961, 0.647, 0.141] as RGB,
  question: [0.133, 0.827, 0.933] as RGB,
  error: [0.957, 0.314, 0.369] as RGB,
  finished: [0.204, 0.831, 0.6] as RGB,
  ratelimit: [0.984, 0.573, 0.235] as RGB,
  sleeping: [0.58, 0.635, 0.722] as RGB,
  dizzy: [0.957, 0.447, 0.714] as RGB,
};

const base = {
  bounces: false, scans: false, breathes: false, zz: false, sweat: false,
  look: null, tilt: 0,
};

export const BOT_STATES: Record<BotStateName, BotStateCfg> = {
  idle: { ...base, color: C.idle, tint: 0, eye: "pill", badge: null },
  working: { ...base, color: C.working, tint: 0.72, eye: "pill", badge: { kind: "dots", color: C.working } },
  thinking: { ...base, color: C.thinking, tint: 0.72, eye: "pill", badge: { kind: "dots", color: C.thinking }, look: [0.55, 0.55] },
  searching: { ...base, color: C.searching, tint: 0.72, eye: "pill", badge: { kind: "dots", color: C.searching }, scans: true },
  approval: { ...base, color: C.approval, tint: 0.78, eye: "wide", badge: { kind: "bang", color: C.approval }, bounces: true },
  question: { ...base, color: C.question, tint: 0.75, eye: "pill", badge: { kind: "question", color: C.question }, tilt: 0.17 },
  error: { ...base, color: C.error, tint: 0.78, eye: "flat", badge: { kind: "dot", color: C.error } },
  finished: { ...base, color: C.finished, tint: 0.35, eye: "happy", badge: { kind: "dot", color: C.finished } },
  ratelimit: { ...base, color: C.ratelimit, tint: 0.72, eye: "tired", badge: { kind: "dot", color: C.ratelimit }, sweat: true },
  sleeping: { ...base, color: C.sleeping, tint: 0.32, eye: "closed", badge: null, breathes: true, zz: true },
  dizzy: { ...base, color: C.dizzy, tint: 0.7, eye: "spiral", badge: null },
};

/** State → sound, as in BotStateCfg.sound. */
export const STATE_SOUND: Partial<Record<BotStateName, string>> = {
  working: "work", thinking: "think", searching: "search", approval: "approval",
  question: "question", error: "error", finished: "finish", ratelimit: "rate",
  sleeping: "sleep", dizzy: "dizzy",
};

const EMOTE_EYE: Record<BotEmoteName, EyeShape> = {
  love: "heart", surprised: "dot", proud: "star", wink: "wink",
  yawn: "tired", happy: "happy", annoyed: "line",
};

// ── Small helpers ─────────────────────────────────────────────────────────────

const now = () => performance.now() / 1000;

export function hexToRGB(hex: string): RGB {
  const h = hex.replace("#", "");
  const v = parseInt(h, 16);
  return [((v >> 16) & 255) / 255, ((v >> 8) & 255) / 255, (v & 255) / 255];
}

const rgba = (c: RGB, a = 1) =>
  `rgba(${Math.round(c[0] * 255)},${Math.round(c[1] * 255)},${Math.round(c[2] * 255)},${a})`;

const mix3 = (a: RGB, b: RGB, t: number): RGB => [
  lerp(a[0], b[0], t), lerp(a[1], b[1], t), lerp(a[2], b[2], t),
];

function roundRectPath(x: CanvasRenderingContext2D, X: number, Y: number, W: number, H: number, R: number) {
  const r = Math.max(0, Math.min(R, W / 2, H / 2));
  x.beginPath();
  x.moveTo(X + r, Y);
  x.arcTo(X + W, Y, X + W, Y + H, r);
  x.arcTo(X + W, Y + H, X, Y + H, r);
  x.arcTo(X, Y + H, X, Y, r);
  x.arcTo(X, Y, X + W, Y, r);
  x.closePath();
}

function heartPath(x: CanvasRenderingContext2D, s: number) {
  x.beginPath();
  x.moveTo(0, s * 0.38);
  x.bezierCurveTo(-s * 1.05, -s * 0.15, -s * 0.5, -s * 0.95, 0, -s * 0.38);
  x.bezierCurveTo(s * 0.5, -s * 0.95, s * 1.05, -s * 0.15, 0, s * 0.38);
  x.closePath();
}

function starPath(x: CanvasRenderingContext2D, ro: number, ri: number) {
  x.beginPath();
  for (let i = 0; i < 10; i++) {
    const r = i % 2 ? ri : ro;
    const a = -Math.PI / 2 + (i * Math.PI) / 5;
    x.lineTo(Math.cos(a) * r, Math.sin(a) * r);
  }
  x.closePath();
}

const FONT = `system-ui, "Segoe UI Variable Text", "Segoe UI", sans-serif`;

// ── Engine ────────────────────────────────────────────────────────────────────

export class BotEngine {
  isMini = false;
  /** Solid body colour for mini bots / integration pills (null = Mochi gradient). */
  bodyColor: RGB | null = null;

  // Animated state (BotEngine `s`)
  yaw = 0; pitch = 0; roll = 0; tilt = 0; open = 1;
  sx = 1; sy = 1; oy = 0; ox = 0;
  tint = 0; morph = 0; hands = 0; blush = 0; es = 1; badgeS = 0;

  // Targets
  tgYaw = 0; tgPitch = 0; tgTilt = 0; tgSy = 1; tgSx = 1; tgEs = 1;

  /** Extra canvas height above the body so hearts can fly out without clipping. */
  particleOverhang = 0;

  // Mouth spring (fraction of R)
  slotH = 0; slotHTarget = 0; slotHVel = 0; isChewing = false;

  col: RGB = C.idle;
  colT: RGB = C.idle;

  state: BotStateName = "idle";
  cfg: BotStateCfg = BOT_STATES.idle;

  eyeOverride: EyeShape | null = null;
  eyeOverrideUntil = 0;
  permanentEye: EyeShape | null = null;
  permanentEmote: BotEmoteName | null = null;
  miniNextBehavior = 0;

  badge: Badge | null = null;
  private badgeKey = "none";
  private badgeToken = 0;

  private tweens = new Map<PropKey, Tween>();
  private locks = new Set<PropKey>();
  private particles: Particle[] = [];

  lookX = 0;
  lookY = 0;

  lastTime = now();
  private t0 = now() - Math.random() * 5;
  private nextBlink = now() + 1.5 + Math.random() * 2;
  waveUntil = 0;
  waveStart = 0;
  private greetToken = 0;
  private lastAmbient = 0;
  private slapTimes: number[] = [];
  private miniLookTarget = { x: 0, y: 0 };
  private miniLookNextTime = 0;

  // Music (Spotify pill): headphones on, and a dance on a steady beat while
  // playing. Spotify gives no tempo or beat to other apps, so the beat is a
  // fixed groove restarted on each track (musicStart), not the song's own.
  musicHeadphones = false;
  musicPlaying = false;
  // Discord call: a headset with a mic, the mouth while you talk, waves while
  // the others do.
  voiceHeadset = false;
  talking = false;
  micMuted = false;
  deafened = false;
  othersSpeaking = false;
  micBoom = 0;
  talk = 0;
  private nextVoiceWave = 0;
  get wantsHeadphones(): boolean { return this.musicHeadphones || this.voiceHeadset; }
  /** Where the person speaking sits on the card, in look units; null when nobody. */
  glance: { x: number; y: number } | null = null;
  private lastSleepZ = 0;
  // Accessories and moods (accessories.ts), set by the extras.
  accessory: MochiAccessory = "none";
  accessoryColor: string | null = null;
  sweating = false;
  sleepy = false;
  scruffy = false;
  private _panicked = false;
  get panicked(): boolean { return this._panicked; }
  set panicked(on: boolean) {
    this._panicked = on;
    if (!on) this.ox = 0;
  }
  lastMoodSweat = 0;
  /** The call's choir: a mouth and sleep without the headset. */
  mouthAlways = false;
  /** When the call began (ms since epoch): an hour in, yawns; two, sweat and tired eyes. */
  callStartedAt: number | null = null;
  private nextYawn = 0;
  private lastSweat = 0;
  /** Past 23:00 in a call: a nightcap. Checked twice a minute. */
  nightcap = false;
  private nightcapCheck = 0;
  headphones = 0;      // 0→1, eases in and out
  groove = 0;          // 0→1, how much Mochi dances
  whistle = 0;         // 0→1, the puckered mouth: 8 beats of every 16
  bpm = 112;
  beatT0 = now();
  private lastBeat = -1;
  private waveStarts: number[] = [];   // now() of each sound wave
  // The dance, applied on top of the pose in draw (never fed back into it).
  danceOy = 0;
  danceTilt = 0;
  danceSx = 1;
  danceSy = 1;

  /** A new track (or play after a stop): the beat starts again from here. */
  musicStart() {
    this.beatT0 = now();
    this.lastBeat = -1;
  }

  /** Fired when three slaps land inside 1.7 s (→ dizzy + confused view). */
  onDizzy: (() => void) | null = null;

  // ── Public API ──────────────────────────────────────────────────────────────

  setState(next: BotStateName, force = false) {
    if (this.state === next && !force) return;
    const prev = this.state;
    this.state = next;
    this.cfg = BOT_STATES[next];
    this.colT = this.cfg.color;
    if (!this.locks.has("tint")) this.tint = this.cfg.tint;
    if (!this.locks.has("tilt")) this.tgTilt = this.cfg.tilt;
    this.setBadge(this.cfg.badge);

    switch (next) {
      case "finished":
        this.doRoll(950, 1);
        setTimeout(() => this.emit("spark", 5), 500);
        break;
      case "error":
        this.anim("ox", [
          [0.08, 50, Ease.out], [-0.08, 70, Ease.inOut],
          [0.05, 70, Ease.inOut], [0, 90, Ease.out],
        ]);
        break;
      case "approval":
        this.anim("oy", [[-0.2, 150, Ease.out], [0, 300, Ease.back]]);
        break;
      case "dizzy":
        this.doRoll(1300, 2);
        break;
      case "question":
        this.blink();
        break;
      case "ratelimit":
        this.emit("sweat", 1);
        break;
      default:
        if (prev !== "idle" || next !== "idle") this.blink();
    }
  }

  setBadge(b: Badge | null) {
    const key = b ? `${b.kind}-${b.color.join(",")}` : "none";
    if (key === this.badgeKey) return;
    this.badgeKey = key;
    const tok = ++this.badgeToken;
    this.anim("badgeS", [[0, 90, Ease.inOut]]);
    setTimeout(() => {
      if (tok !== this.badgeToken) return;
      this.badge = b;
      if (b) this.anim("badgeS", [[1, 280, Ease.back]]);
    }, 100);
  }

  blink() {
    if (this.locks.has("open")) return;
    this.anim("open", [[0.06, 70, Ease.inOut], [1, 130, Ease.out]]);
  }

  squash() {
    this.anim("sy", [[0.78, 70, Ease.out], [1.1, 130, Ease.out], [1, 170, Ease.inOut]]);
    this.anim("sx", [[1.16, 70, Ease.out], [0.95, 130, Ease.out], [1, 170, Ease.inOut]]);
  }

  /** Mailbox swallow — opens the slot, chews, then closes. */
  gulp() {
    this.slotHTarget = 0.42;
    setTimeout(() => {
      this.slotHTarget = 0;
      this.isChewing = true;
      setTimeout(() => { this.isChewing = false; }, 800);
    }, 460);
    this.anim("sy", [[0.78, 80, Ease.out], [1.18, 130, Ease.out], [1, 220, Ease.back]]);
    this.anim("sx", [[1.28, 80, Ease.out], [0.92, 130, Ease.out], [1, 220, Ease.back]]);
    this.blink();
  }

  slap() {
    this.interruptGreet();
    if (this.state === "dizzy") return;
    const t = now();
    this.slapTimes = this.slapTimes.filter((s) => t - s < 1.7);
    this.slapTimes.push(t);
    Sound.play("slap");
    this.squash();
    if (this.slapTimes.length >= 3) {
      this.slapTimes = [];
      this.onDizzy?.();
    } else {
      this.eyeOverride = "line";
      this.eyeOverrideUntil = t + 0.8;
      setTimeout(() => Sound.play("annoyed"), 60);
    }
  }

  doRoll(durationMs: number, turns: number) {
    this.roll = 0;
    this.anim("roll", [[Math.PI * 2 * turns, durationMs, Ease.inOut]], () => { this.roll = 0; });
  }

  /** Peek wave — the "coucou". Timings from BotEngine.greet(). */
  greet() {
    const t = now();
    const tok = ++this.greetToken;
    this.waveStart = t + 0.45;
    this.waveUntil = t + 1.55;

    this.eyeOverride = "happy";
    this.eyeOverrideUntil = t + 2.0;
    this.anim("oy", [[-0.06, 220, Ease.out], [0.0, 220, Ease.back]]);

    setTimeout(() => {
      if (this.greetToken !== tok) return;
      this.anim("hands", [[1, 280, Ease.out]]);
      this.anim("sy", [[0.95, 100, Ease.out], [1.0, 260, Ease.back]]);
      this.anim("sx", [[1.04, 100, Ease.out], [1.0, 260, Ease.back]]);
      Sound.play("greet");
    }, 250);

    setTimeout(() => { if (this.greetToken === tok) this.blink(); }, 550);
    setTimeout(() => { if (this.greetToken === tok) this.blink(); }, 1500);
    setTimeout(() => {
      if (this.greetToken !== tok) return;
      this.waveUntil = 0;
      this.anim("hands", [[0, 200, Ease.inOut]]);
    }, 1550);
    setTimeout(() => {
      if (this.greetToken !== tok) return;
      this.eyeOverride = "happy";
      this.eyeOverrideUntil = now() + 0.3;
    }, 1750);
  }

  interruptGreet() {
    if (this.hands <= 0.01 && now() >= this.waveUntil) return;
    this.greetToken++;
    this.waveUntil = 0;
    this.waveStart = 0;
    this.anim("hands", [[0, 150, Ease.inOut]]);
  }

  setPermanentEmote(emote: BotEmoteName | null) {
    this.permanentEmote = emote;
    if (emote === "wink") {
      this.miniNextBehavior = now() + 0.8 + Math.random() * 1.7;
      return;
    }
    this.permanentEye = emote ? EMOTE_EYE[emote] : null;
    if (this.permanentEye) {
      this.eyeOverride = this.permanentEye;
      this.eyeOverrideUntil = Number.POSITIVE_INFINITY;
    } else if (this.eyeOverrideUntil === Number.POSITIVE_INFINITY) {
      this.eyeOverride = null;
      this.eyeOverrideUntil = 0;
    }
    this.miniNextBehavior = now() + 0.8 + Math.random() * 1.7;
  }

  triggerEmote(emote: BotEmoteName, duration = 1.8) {
    const t = now();
    this.eyeOverride = EMOTE_EYE[emote];
    this.eyeOverrideUntil = t + duration;

    switch (emote) {
      case "love":
        this.anim("blush", [
          [1, 300, Ease.out], [1, (duration - 0.6) * 1000, Ease.lin], [0, 300, Ease.inOut],
        ]);
        this.emit("heart", 4);
        this.anim("oy", [[-0.1, 160, Ease.out], [0, 300, Ease.back]]);
        break;
      case "surprised":
        this.anim("oy", [[-0.3, 140, Ease.out], [0, 380, Ease.back]]);
        this.anim("es", [[1.25, 120, Ease.out], [1, 500, Ease.inOut]]);
        break;
      case "proud":
        this.emit("star", 5);
        this.anim("tilt", [
          [-0.14, 220, Ease.out], [-0.14, (duration - 0.5) * 1000, Ease.lin], [0, 280, Ease.inOut],
        ]);
        this.anim("blush", [
          [0.7, 250, Ease.out], [0.7, (duration - 0.5) * 1000, Ease.lin], [0, 300, Ease.inOut],
        ]);
        break;
      case "wink":
        this.anim("tilt", [
          [0.12, 160, Ease.out], [0.12, (duration - 0.4) * 1000, Ease.lin], [0, 240, Ease.inOut],
        ]);
        break;
      case "yawn":
        this.anim("sy", [[1.12, 500, Ease.inOut], [1, 500, Ease.inOut]]);
        this.anim("sx", [[0.94, 500, Ease.inOut], [1, 500, Ease.inOut]]);
        setTimeout(() => { this.eyeOverride = "closed"; this.emit("z", 2); }, 700);
        break;
      case "happy":
        this.anim("blush", [[0.6, 200, Ease.out], [0, 600, Ease.inOut]]);
        break;
      case "annoyed":
        this.eyeOverride = "line";
        this.eyeOverrideUntil = t + 0.8;
        setTimeout(() => Sound.play("annoyed"), 60);
        break;
    }
  }

  emit(type: Particle["type"], count: number) {
    for (let i = 0; i < count; i++) {
      const isZ = type === "z";
      this.particles.push({
        type,
        x: (Math.random() - 0.5) * 0.9 + (isZ ? 0.55 : 0),
        y: -0.7 - Math.random() * 0.2,
        vx: (Math.random() - 0.5) * 0.35 + (isZ ? 0.18 : 0),
        vy: -(0.45 + Math.random() * 0.35),
        age: -i * 0.14,
        life: 1.3 + Math.random() * 0.5,
        rot: Math.random() * Math.PI * 2,
        size: 0.15 + Math.random() * 0.08,
      });
    }
  }

  /** A trip to a paired Mochi (LAN send): it hops off to the right and comes back in from the left. */
  travel() {
    this.anim("ox", [
      [-0.25, 160, Ease.out],   // a little run-up
      [24, 900, Ease.inOut],    // off it goes
      [-10, 1, Ease.lin],       // round the back
      [-10, 700, Ease.lin],     // away a moment
      [0, 750, Ease.out],       // and back in
    ]);
    const hops: TweenKey[] = [];
    for (let i = 0; i < 10; i++) hops.push([-0.12, 110, Ease.out], [0, 110, Ease.inOut]);
    this.anim("oy", hops);
    this.eyeOverride = "happy";
    this.eyeOverrideUntil = now() + 2.6;
  }

  /** A Discord reaction: confetti, hearts, a laugh, a question, fire. */
  react(r: MochiReaction) {
    switch (r) {
      case "confetti": this.emit("confetti", 16); break;
      case "hearts": this.emit("heart", 6); break;
      case "laugh": this.triggerEmote("happy"); this.squash(); break;
      case "question":
        this.setBadge({ kind: "question", color: [0.6, 0.66, 1] });
        setTimeout(() => this.setBadge(this.cfg.badge), 2500);
        break;
      case "fire":
        this.emit("spark", 8);
        this.anim("blush", [[1, 200, Ease.out], [1, 900, Ease.lin], [0, 500, Ease.inOut]]);
        break;
    }
  }

  animateMorph(target: number, durationMs?: number) {
    const dur = durationMs ?? (target > 0.5 ? 550 : 650);
    this.anim("morph", [[target, dur, Ease.inOut]]);
  }

  resetMorph() {
    this.tweens.delete("morph");
    this.locks.delete("morph");
    this.morph = 0;
  }

  /** True while anything is still moving — lets the island stop its RAF loop. */
  get busy(): boolean {
    return (
      this.tweens.size > 0 ||
      this.particles.length > 0 ||
      this.cfg.bounces || this.cfg.scans || this.cfg.breathes || this.cfg.zz || this.cfg.sweat ||
      this.isMini ||
      this.animatedExtras ||
      Math.abs(this.tgYaw - this.yaw) > 0.002 ||
      Math.abs(this.tgPitch - this.pitch) > 0.002 ||
      Math.abs(this.tgTilt - this.tilt) > 0.002 ||
      Math.abs(this.tgSy - this.sy) > 0.002 ||
      Math.abs(this.tgSx - this.sx) > 0.002 ||
      Math.abs(this.tgEs - this.es) > 0.002 ||
      this.slotH > 0.001 || Math.abs(this.slotHVel) > 0.001 ||
      Math.abs(this.col[0] - this.colT[0]) > 0.003 ||
      Math.abs(this.col[1] - this.colT[1]) > 0.003 ||
      Math.abs(this.col[2] - this.colT[2]) > 0.003
    );
  }

  /** Music, a call, an accessory that moves, a mood: they keep the loop running. */
  private get animatedExtras(): boolean {
    return (
      this.musicPlaying || this.voiceHeadset || this.mouthAlways || this.nightcap ||
      this.groove > 0.005 || this.headphones > 0.01 || this.micBoom > 0.01 || this.talk > 0.02 ||
      this.whistle > 0.02 || this.waveStarts.length > 0 ||
      this.accessory === "antenna" || this.accessory === "umbrella" ||
      this.sweating || this.sleepy || this._panicked || this.accessory === "sleepMask"
    );
  }

  // ── Tweens ──────────────────────────────────────────────────────────────────

  anim(prop: PropKey, keys: TweenKey[], onComplete?: () => void) {
    this.tweens.set(prop, {
      prop, keys, index: 0, from: this[prop], startMs: performance.now(), onComplete,
    });
    this.locks.add(prop);
  }

  // ── Update ──────────────────────────────────────────────────────────────────

  update(dt: number) {
    const n = now();
    const nowMs = performance.now();

    for (const tw of [...this.tweens.values()]) {
      const k = tw.keys[tw.index];
      const p = Math.min(1, Math.max(0, (nowMs - tw.startMs) / k[1]));
      this[tw.prop] = tw.from + (k[0] - tw.from) * k[2](p);
      if (p >= 1) {
        tw.from = k[0];
        tw.index += 1;
        tw.startMs = nowMs;
        if (tw.index >= tw.keys.length) {
          this.tweens.delete(tw.prop);
          this.locks.delete(tw.prop);
          tw.onComplete?.();
        }
      }
    }

    const t = n - this.t0;
    let ty = this.lookX * 0.62;
    let tp = this.lookY * 0.5;

    if (this.cfg.look) {
      ty = ty * 0.35 + this.cfg.look[0] * 0.55;
      tp = tp * 0.3 + this.cfg.look[1] * 0.5;
    }
    if (this.cfg.scans) {
      ty = Math.sin(t * 2.6) * 0.6;
      tp = -0.06;
    }
    if (this.state === "sleeping") { ty = 0; tp = -0.14; }
    if (this.state === "dizzy") { ty = Math.sin(t * 9) * 0.25; }

    // Mini bots never follow the mouse — they wander.
    if (this.isMini && !this.cfg.look && !this.cfg.scans && this.state !== "sleeping" && this.state !== "dizzy") {
      if (n > this.miniLookNextTime) {
        this.miniLookTarget = {
          x: -0.88 + Math.random() * 1.76,
          y: -0.55 + Math.random() * 1.0,
        };
        this.miniLookNextTime = n + 0.5 + Math.random() * 1.5;
      }
      ty = this.miniLookTarget.x * 0.62;
      tp = this.miniLookTarget.y * 0.5;
    }

    this.tgYaw = ty;
    this.tgPitch = tp;
    this.tgTilt = this.cfg.tilt;

    if (n > this.waveStart && n < this.waveUntil) {
      const wt = n - this.waveStart;
      this.tgTilt = -0.06 + Math.sin(2 * Math.PI * 1.2 * wt) * 0.07;
    }

    const bounce = this.cfg.bounces ? -Math.abs(Math.sin(t * 5.2)) * 0.07 : 0;
    const kGen = 1 - Math.pow(0.0008, dt);
    if (!this.locks.has("oy")) this.oy += (bounce - this.oy) * kGen;

    if (this.cfg.breathes) {
      const amp = this.isMini ? 0.07 : 0.035;
      this.tgSy = 1 + Math.sin(t * 1.8) * amp;
      this.tgSx = 1 - Math.sin(t * 1.8) * amp * 0.57;
    } else if (this.isMini) {
      this.tgSy = 1 + Math.sin(t * 2.2) * 0.04;
      this.tgSx = 1 - Math.sin(t * 2.2) * 0.02;
    } else {
      this.tgSy = 1;
      this.tgSx = 1;
    }

    if (this.isMini && n > this.miniNextBehavior) this.doMiniBehaviorLoop();

    this.updateDance(n, dt);
    updateMoods(this, n);

    const kLook = 1 - Math.pow(0.0025, dt);
    if (!this.locks.has("yaw")) this.yaw += (this.tgYaw - this.yaw) * kLook;
    if (!this.locks.has("pitch")) this.pitch += (this.tgPitch - this.pitch) * kLook;
    if (!this.locks.has("tilt")) this.tilt += (this.tgTilt - this.tilt) * kGen;
    if (!this.locks.has("sy")) this.sy += (this.tgSy - this.sy) * kGen;
    if (!this.locks.has("sx")) this.sx += (this.tgSx - this.sx) * kGen;
    if (!this.locks.has("es")) this.es += (this.tgEs - this.es) * kGen;

    this.col = mix3(this.col, this.colT, 1 - Math.pow(0.002, dt));

    if (n > this.nextBlink) {
      if (this.state !== "sleeping" && this.state !== "dizzy") {
        this.blink();
        if (Math.random() < 0.22) setTimeout(() => this.blink(), 230);
      }
      this.nextBlink = n + 2.2 + Math.random() * 3.2;
    }

    if (this.eyeOverride && n > this.eyeOverrideUntil) {
      this.eyeOverride = this.permanentEye;
      if (this.permanentEye) this.eyeOverrideUntil = Number.POSITIVE_INFINITY;
    }

    if (n - this.lastAmbient > 1.3) {
      this.lastAmbient = n;
      if (this.cfg.zz) this.emit("z", 1);
      if (!this.isMini && this.cfg.sweat && Math.random() < 0.5) this.emit("sweat", 1);
    }

    for (const p of this.particles) p.age += dt;
    this.particles = this.particles.filter((p) => p.age < p.life);

    // Mouth slot spring — ω₀ = 2π/0.25, ζ = 0.6
    const omega = (2 * Math.PI) / 0.25;
    const zeta = 0.6;
    const acc = omega * omega * (this.slotHTarget - this.slotH) - 2 * zeta * omega * this.slotHVel;
    this.slotHVel += acc * dt;
    this.slotH = Math.max(0, this.slotH + this.slotHVel * dt);

    this.lastTime = n;
  }

  private updateDance(n: number, dt: number) {
    const k = 1 - Math.pow(0.03, dt);
    this.headphones += ((this.wantsHeadphones ? 1 : 0) - this.headphones) * k;
    this.groove += ((this.musicPlaying ? 1 : 0) - this.groove) * k;
    this.micBoom += ((this.voiceHeadset ? 1 : 0) - this.micBoom) * k;
    this.talk += ((this.talking ? 1 : 0) - this.talk) * (1 - Math.pow(0.0005, dt));
    this.waveStarts = this.waveStarts.filter((w) => n - w <= 1.1);
    if (this.othersSpeaking && this.voiceHeadset && n > this.nextVoiceWave) {
      this.waveStarts.push(n);
      this.nextVoiceWave = n + 0.45;
    }
    // A long call wears Mochi out; a late one gets a nightcap.
    if (this.voiceHeadset && !this.isMini && this.callStartedAt != null) {
      const minutes = (Date.now() - this.callStartedAt) / 60000;
      if (minutes > 60 && n > this.nextYawn) {
        this.nextYawn = n + 240;
        this.triggerEmote("yawn");
      }
      if (minutes > 120 && n - this.lastSweat > 2.4) {
        this.lastSweat = n;
        this.emit("sweat", 1);
        if (this.eyeOverride == null || this.eyeOverride === this.permanentEye) {
          this.eyeOverride = "tired";
          this.eyeOverrideUntil = n + 1.2;
        }
      }
    }
    if (n > this.nightcapCheck) {
      this.nightcapCheck = n + 30;
      const hour = new Date().getHours();
      this.nightcap = this.voiceHeadset && !this.isMini && (hour >= 23 || hour < 5);
    }
    // Deafened in a call: eyes shut, a z now and then.
    if (this.deafened && (this.voiceHeadset || this.mouthAlways) && this.morph < 0.05) {
      const o = this.eyeOverride;
      if (o == null || o === this.permanentEye || o === "closed") {
        this.eyeOverride = "closed";
        this.eyeOverrideUntil = n + 0.2;
      }
      if (n - this.lastSleepZ > 1.6) {
        this.lastSleepZ = n;
        this.emit("z", 1);
      }
    }
    const beats = Math.max(0, ((n - this.beatT0) * this.bpm) / 60);
    // Bars of 16 beats: 8 dancing, then 8 whistling along.
    const whistling = this.musicPlaying && Math.floor(beats) % 16 >= 8;
    this.whistle += ((whistling ? 1 : 0) - this.whistle) * (1 - Math.pow(0.002, dt));
    if (this.groove <= 0.005) {
      this.danceOy = 0; this.danceTilt = 0; this.danceSx = 1; this.danceSy = 1;
      return;
    }
    const phase = beats % 1;
    const hit = Math.pow(1 - phase, 3);                          // sharp on the beat, then decays
    this.danceOy = -Math.abs(Math.sin(Math.PI * beats)) * 0.075 * this.groove;   // a hop per beat
    this.danceTilt = Math.sin((Math.PI * beats) / 2) * 0.085 * this.groove;      // sway, one side per beat
    this.danceSy = 1 - hit * 0.07 * this.groove;                 // squash as it lands
    this.danceSx = 1 + hit * 0.05 * this.groove;
    this.tgPitch += (hit * 0.1 - 0.03) * this.groove;            // nod with the beat
    this.tgYaw *= 1 - 0.6 * this.groove;                         // eyes mostly forward while vibing

    const beat = Math.floor(beats);
    if (beat === this.lastBeat || !this.musicPlaying) return;
    this.lastBeat = beat;
    this.waveStarts.push(n);
    if (whistling) {
      // Eyes shut in bliss, a note out of the mouth on every beat.
      const o = this.eyeOverride;
      if (o == null || o === this.permanentEye || o === "happy") {
        this.eyeOverride = "happy";
        this.eyeOverrideUntil = n + 60 / this.bpm + 0.05;
      }
      if (!this.isMini) this.emitNote(true);
    } else {
      // Dancing: two beats of blissed-out eyes every 8; a note from the side every 4.
      if (beat % 8 === 4 && (this.eyeOverride == null || this.eyeOverride === this.permanentEye)) {
        this.eyeOverride = "happy";
        this.eyeOverrideUntil = n + (2 * 60) / this.bpm;
      }
      if (!this.isMini && beat % 4 === 2) this.emitNote(false);
    }
  }

  private emitNote(fromMouth: boolean) {
    const side = fromMouth ? 1 : Math.random() < 0.5 ? 1 : -1;
    const rand = (a: number, b: number) => a + Math.random() * (b - a);
    this.particles.push({
      type: "note",
      // Particle units are R·1.3 from the body centre; the mouth sits low and a bit right.
      x: fromMouth ? 0.2 : side * rand(0.55, 0.75),
      y: fromMouth ? 0.2 : -0.55,
      vx: side * (fromMouth ? rand(0.35, 0.55) : rand(0.08, 0.2)),
      vy: -rand(0.3, 0.5),
      age: 0, life: 1.6, rot: side * 0.2, size: 0.15 + Math.random() * 0.06,
    });
  }

  /**
   * Where the mouth sits, projected on the head like the eyes (drawEyes): it
   * follows yaw and pitch, narrows (f) as the head turns, and is null when it
   * has turned out of sight. Below the eyes by a fixed angle on the sphere.
   */
  private mouthSpot(rx: number, ry: number): [number, number, number] | null {
    const p = EYE_P - 0.36 + this.pitch + this.roll;
    const cp = Math.cos(p);
    if (Math.cos(this.yaw) * cp <= 0.1) return null;
    return [Math.sin(this.yaw) * cp * rx, -Math.sin(p) * ry, Math.max(0.3, Math.cos(this.yaw))];
  }

  /** The whistling "o", low on the face and turned with the gaze. */
  private drawWhistleMouth(x: CanvasRenderingContext2D, body: Path2D, R: number, rx: number, ry: number) {
    const spot = this.mouthSpot(rx, ry);
    if (!spot) return;
    const [mx, y, f] = spot;
    const beats = Math.max(0, ((now() - this.beatT0) * this.bpm) / 60);
    const pulse = 1 + 0.18 * Math.pow(1 - (beats % 1), 2);
    const w = R * 0.13 * this.whistle * pulse * f;
    const h = R * 0.16 * this.whistle * pulse;
    x.save();
    x.clip(body);
    x.fillStyle = this.isMini ? MINI_INK : INK;
    x.beginPath();
    x.ellipse(mx + R * 0.07 * f, y, w / 2, h / 2, 0, 0, Math.PI * 2);
    x.fill();
    x.restore();
  }

  /** Spotify green for music, Discord blurple for a call. */
  private accent(alpha: number): string {
    return this.voiceHeadset ? `rgba(154,168,255,${alpha})` : `rgba(29,185,84,${alpha})`;
  }

  /** Headband over the top of the head and a cup on each side, in body space. */
  private drawHeadphones(x: CanvasRenderingContext2D, R: number, rx: number, ry: number) {
    x.save();
    x.globalAlpha *= Math.min(1, this.headphones);
    x.translate(0, -(1 - this.headphones) * R * 0.35);   // they slide down onto the head
    x.lineCap = "round";
    const band = () => {
      x.beginPath();
      x.moveTo(-rx * 0.97, -ry * 0.18);
      x.bezierCurveTo(-rx * 0.95, -ry * 1.45, rx * 0.95, -ry * 1.45, rx * 0.97, -ry * 0.18);
    };
    const bandW = Math.max(1.5, R * 0.11);
    band();
    x.strokeStyle = "#23262D";
    x.lineWidth = bandW;
    x.stroke();
    band();
    x.strokeStyle = "rgba(255,255,255,0.16)";
    x.lineWidth = Math.max(0.6, bandW * 0.3);
    x.stroke();
    const cw = R * 0.3, ch = R * 0.56;
    for (const sd of [-1, 1]) {
      const cx = sd * rx * 0.97;
      const y0 = -ry * 0.22;
      const g = x.createLinearGradient(cx, y0, cx, y0 + ch);
      g.addColorStop(0, "#3A3E47");
      g.addColorStop(1, "#16181D");
      x.beginPath();
      x.roundRect(cx - cw / 2, y0, cw, ch, cw * 0.45);
      x.fillStyle = g;
      x.fill();
      x.strokeStyle = "rgba(255,255,255,0.14)";
      x.lineWidth = Math.max(0.5, R * 0.025);
      x.stroke();
      // A small light on the outer side of each cup.
      const a = 0.55 + 0.45 * Math.max(this.groove, this.talk);
      x.fillStyle = this.deafened && this.voiceHeadset ? `rgba(218,55,60,${a})` : this.accent(a);
      x.beginPath();
      x.ellipse(cx, y0 + ch / 2, cw * 0.14, cw * 0.14, 0, 0, Math.PI * 2);
      x.fill();
    }
    if (this.micBoom > 0.01) this.drawMic(x, R, rx, ry);
    x.restore();
  }

  /** The headset's boom, from the left cup to beside the mouth; a red tip when muted. */
  private drawMic(x: CanvasRenderingContext2D, R: number, rx: number, ry: number) {
    x.save();
    x.globalAlpha *= this.micBoom;
    const spot = this.mouthSpot(rx, ry);
    // The tip sits just left of and below the mouth, wherever the gaze takes it.
    const tip = spot
      ? { x: Math.max(-rx * 0.7, spot[0] - R * 0.34), y: Math.min(ry * 0.78, spot[1] + ry * 0.14) }
      : { x: -R * 0.38, y: ry * 0.62 };
    x.strokeStyle = "#23262D";
    x.lineWidth = Math.max(1.2, R * 0.07);
    x.lineCap = "round";
    x.beginPath();
    x.moveTo(-rx * 0.97, ry * 0.3);
    x.quadraticCurveTo(-rx * 0.9, ry * 0.7, tip.x, tip.y);
    x.stroke();
    const r = Math.max(1.5, R * 0.09);
    x.fillStyle = this.micMuted ? "#DA373C" : "#3A3E47";
    x.beginPath();
    x.ellipse(tip.x, tip.y, r, r * 0.8, 0, 0, Math.PI * 2);
    x.fill();
    x.restore();
  }

  /** While talking in a call, a mouth that opens and closes; muted, a closed line. */
  private drawTalkMouth(x: CanvasRenderingContext2D, body: Path2D, R: number, rx: number, ry: number) {
    const spot = this.mouthSpot(rx, ry);
    if (!spot) return;
    const [mx, y, f] = spot;
    const ink = this.isMini ? MINI_INK : INK;
    x.save();
    x.clip(body);
    if (this.micMuted) {
      x.globalAlpha *= this.mouthAlways ? 1 : this.micBoom;
      x.strokeStyle = ink;
      x.lineWidth = Math.max(1, R * 0.045);
      x.lineCap = "round";
      x.beginPath();
      x.moveTo(mx - R * 0.11 * f, y);
      x.lineTo(mx + R * 0.11 * f, y);
      x.stroke();
      x.restore();
      return;
    }
    const t = now();
    // Two sines out of step: it reads as syllables, not a metronome.
    const open = (0.5 + 0.5 * Math.abs(Math.sin(t * 11)) * (0.6 + 0.4 * Math.sin(t * 3.7))) * this.talk;
    const w = R * 0.2 * f, h = R * (0.03 + 0.15 * open);
    x.fillStyle = ink;
    x.beginPath();
    x.roundRect(mx - w / 2, y - h / 2, w, h, Math.min(w, h) / 2);
    x.fill();
    x.restore();
  }

  /** A floppy cap over the headband, its pompom hanging off to the right. */
  private drawNightcap(x: CanvasRenderingContext2D, R: number, rx: number, ry: number) {
    const sway = Math.sin(now() * 1.3) * R * 0.04;
    x.save();
    x.beginPath();
    x.moveTo(-rx * 0.62, -ry * 0.78);
    x.quadraticCurveTo(rx * 0.15, -ry * 1.75, rx * 0.95 + sway, -ry * 0.62);
    x.quadraticCurveTo(rx * 0.55, -ry * 1.05, rx * 0.55, -ry * 0.84);
    x.quadraticCurveTo(0, -ry * 0.98, -rx * 0.62, -ry * 0.78);
    const g = x.createLinearGradient(0, -ry * 1.5, 0, -ry * 0.8);
    g.addColorStop(0, "#3C45A5");
    g.addColorStop(1, "#272D73");
    x.fillStyle = g;
    x.fill();
    x.strokeStyle = "rgba(255,255,255,0.9)";
    x.lineWidth = Math.max(1.2, R * 0.1);
    x.lineCap = "round";
    x.beginPath();
    x.moveTo(-rx * 0.64, -ry * 0.8);
    x.quadraticCurveTo(0, -ry * 1.02, rx * 0.56, -ry * 0.86);
    x.stroke();
    x.fillStyle = "#fff";
    x.beginPath();
    x.ellipse(rx * 0.95 + sway, -ry * 0.62, R * 0.11, R * 0.11, 0, 0, Math.PI * 2);
    x.fill();
    x.restore();
  }

  /** Arcs on both sides, one pair per beat, spreading out and fading. */
  private drawSoundWaves(x: CanvasRenderingContext2D, R: number, rx: number, cx: number, cy: number) {
    const n = now();
    x.save();
    x.lineCap = "round";
    for (const start of this.waveStarts) {
      const k = (n - start) / 1.1;
      if (k < 0 || k >= 1) continue;
      const radius = rx * (1.12 + 0.42 * k);
      x.strokeStyle = this.accent((1 - k) * (1 - k) * 0.55 * Math.max(this.groove, this.micBoom));
      x.lineWidth = Math.max(1, R * 0.05 * (1 - k * 0.5));
      for (const mid of [0, Math.PI]) {
        x.beginPath();
        x.arc(cx, cy, radius, mid - (28 * Math.PI) / 180, mid + (28 * Math.PI) / 180);
        x.stroke();
      }
    }
    x.restore();
  }

  private doMiniBehaviorLoop() {
    const n = now();
    switch (this.permanentEmote) {
      case "happy":
        if (this.locks.has("oy")) { this.miniNextBehavior = n + 0.4; return; }
        this.anim("oy", [[-0.3, 120, Ease.out], [0.03, 200, Ease.inOut], [0, 160, Ease.back]]);
        this.anim("sy", [[0.82, 80, Ease.out], [1.18, 130, Ease.out], [0.88, 160, Ease.inOut], [1, 200, Ease.back]]);
        this.anim("sx", [[1.15, 80, Ease.out], [0.88, 130, Ease.out], [1.06, 160, Ease.inOut], [1, 200, Ease.back]]);
        this.miniNextBehavior = n + 2.2 + Math.random() * 1.2;
        break;
      case "annoyed":
        if (this.locks.has("yaw")) { this.miniNextBehavior = n + 0.5; return; }
        this.anim("yaw", [
          [-0.65, 50, Ease.out], [0.65, 90, Ease.inOut], [-0.5, 80, Ease.inOut],
          [0.4, 75, Ease.inOut], [-0.2, 70, Ease.inOut], [0, 140, Ease.out],
        ]);
        this.miniNextBehavior = n + 3.0 + Math.random() * 2.5;
        break;
      case "wink":
        this.eyeOverride = "wink";
        this.eyeOverrideUntil = n + 0.55;
        this.anim("tilt", [[0.13, 100, Ease.out], [0.13, 320, Ease.lin], [0, 200, Ease.inOut]]);
        this.miniNextBehavior = n + 2.2 + Math.random() * 2.0;
        break;
      case "love":
        this.emit("heart", 2);
        this.anim("tilt", [[-0.1, 180, Ease.out], [0.1, 340, Ease.inOut], [0, 220, Ease.inOut]]);
        this.miniNextBehavior = n + 2.6 + Math.random() * 1.5;
        break;
      default:
        this.miniNextBehavior = n + 3.0 + Math.random() * 2.0;
    }
  }

  // ── Draw ────────────────────────────────────────────────────────────────────

  /**
   * Draws hands, body, blush, eyes, mouth, badge and particles into a canvas of
   * `w`×`h` CSS pixels (the caller has already applied the DPR transform).
   */
  draw(x: CanvasRenderingContext2D, W: number, H: number) {
    const R = W * 0.3;
    const rx = R * 1.14;
    const ry = R * 0.88;
    const cx = W / 2 + this.ox * R;
    const cy = H / 2 + this.particleOverhang / 2 + (this.oy + this.danceOy) * R + R * 0.06;

    this.drawHandsBehind(x, R, rx, ry, cx, cy);

    x.save();
    x.translate(cx, cy);
    const tiltNow = this.tilt + this.danceTilt;
    if (tiltNow !== 0) x.rotate(tiltNow);
    x.scale(this.sx * this.danceSx, this.sy * this.danceSy);

    const body = this.bodyPath(rx, ry, R);
    this.drawBody(x, body, R, rx, ry);

    const blushVal = Math.max(this.blush, this.tint * 0.5) * (1 - this.morph);
    if (blushVal > 0.01) {
      x.save();
      x.clip(body);
      const yOffset = Math.sin(this.yaw) * rx * 0.8;
      x.fillStyle = `rgba(255,120,150,${0.5 * blushVal})`;
      for (const sd of [-1, 1]) {
        x.beginPath();
        x.ellipse(sd * rx * 0.55 + yOffset, ry * 0.2, R * 0.17, R * 0.1, 0, 0, Math.PI * 2);
        x.fill();
      }
      x.restore();
    }

    this.drawEyes(x, body, R, rx, ry);

    if (this.morph < 0.05 && this.whistle < 0.02 && (this.micBoom > 0.01 || this.mouthAlways) && (this.talk > 0.02 || this.micMuted)) {
      this.drawTalkMouth(x, body, R, rx, ry);
    }
    if (this.whistle > 0.02 && this.morph < 0.05) this.drawWhistleMouth(x, body, R, rx, ry);
    if (this.headphones > 0.01 && this.morph < 0.05) this.drawHeadphones(x, R, rx, ry);
    if (this.nightcap && this.morph < 0.05) this.drawNightcap(x, R, rx, ry);
    drawAccessory(this, x, body, R, rx, ry);

    if (this.morph > 0.05) this.drawMouth(x, body, R);

    x.restore();

    if (this.waveStarts.length > 0 && (this.groove > 0.01 || this.micBoom > 0.01)) {
      this.drawSoundWaves(x, R, rx, cx, cy);
    }

    if (this.badge && this.badgeS > 0.01 && this.morph < 0.25) {
      this.drawBadge(x, this.badge, R, cx, cy);
    }
    this.drawParticles(x, R, cx, cy);
  }

  private bodyPath(rx: number, ry: number, R: number): Path2D {
    const n = 72;
    const expN = 2.0 / 2.7;
    const tw = R * 1.0;
    const th = R * 0.94;
    const tr = R * 0.42;
    const p = new Path2D();
    const m = this.morph;
    for (let i = 0; i <= n; i++) {
      const a = (i / n) * Math.PI * 2;
      const ca = Math.cos(a);
      const sa = Math.sin(a);
      const px0 = rx * (ca >= 0 ? Math.pow(ca, expN) : -Math.pow(-ca, expN));
      const py0 = ry * (sa >= 0 ? Math.pow(sa, expN) : -Math.pow(-sa, expN));
      let px = px0;
      let py = py0;
      if (m >= 0.005) {
        const rr = rrPoint(ca, sa, tw, th, tr);
        px = lerp(px0, rr.x, m);
        py = lerp(py0, rr.y, m);
      }
      if (i === 0) p.moveTo(px, py);
      else p.lineTo(px, py);
    }
    p.closePath();
    return p;
  }

  private drawBody(x: CanvasRenderingContext2D, body: Path2D, R: number, rx: number, ry: number) {
    if (this.bodyColor) {
      // Mini bots: flat solid fill — no gradient, no reflection, no highlight
      x.fillStyle = rgba(this.bodyColor, 1);
      x.fill(body);
      return;
    }
    const g = x.createLinearGradient(rx * 0.7, -ry * 0.85, -rx * 0.8, ry * 0.9);
    g.addColorStop(0, rgba(BASE_TOP));
    g.addColorStop(1, rgba(BASE_BOTTOM));
    x.fillStyle = g;
    x.fill(body);

    const effectiveTint = this.tint * (1 - this.morph);
    if (effectiveTint > 0.01) {
      const tg = x.createLinearGradient(0, ry, 0, -ry);
      tg.addColorStop(0, rgba(this.col, 0.72 * effectiveTint));
      tg.addColorStop(1, rgba(this.col, 0));
      x.fillStyle = tg;
      x.fill(body);
    }

    const sh = x.createRadialGradient(0, 0, R * 0.15, 0, 0, R * 1.25);
    sh.addColorStop(0, "rgba(0,0,0,0)");
    sh.addColorStop(0.6, "rgba(0,0,0,0)");
    sh.addColorStop(1, "rgba(0,0,0,0.2)");
    x.fillStyle = sh;
    x.fill(body);

    const hl = x.createRadialGradient(rx * 0.34, -ry * 0.46, 0, rx * 0.34, -ry * 0.46, R * 0.42);
    hl.addColorStop(0, "rgba(255,255,255,0.55)");
    hl.addColorStop(1, "rgba(255,255,255,0)");
    x.fillStyle = hl;
    x.fill(body);
  }

  private drawEyes(x: CanvasRenderingContext2D, body: Path2D, R: number, rx: number, ry: number) {
    let shape: EyeShape = this.eyeOverride ?? this.cfg.eye;
    if (this.morph > 0.5) {
      if (this.isChewing) shape = "happy";
      else if (this.slotHTarget > 0.05 || this.slotH > 0.1) shape = "cup";
    }

    x.save();
    x.clip(body);
    const ink = this.isMini ? MINI_INK : INK;
    x.fillStyle = ink;
    x.strokeStyle = ink;

    for (const sd of [-1, 1]) {
      const eyeYaw = sd * EYE_SP + this.yaw;
      let eyePitch = EYE_P + this.pitch + this.roll;
      eyePitch = (((eyePitch + Math.PI) % (Math.PI * 2)) + Math.PI * 2) % (Math.PI * 2) - Math.PI;
      const cp = Math.cos(eyePitch);
      if (Math.cos(eyeYaw) * cp <= 0.04) continue;

      const ex = Math.sin(eyeYaw) * cp * rx;
      const ey = -Math.sin(eyePitch) * ry + (this.morph > 0 ? ry * 0.14 * this.morph : 0);
      const fx = lerp(Math.max(0.18, Math.cos(eyeYaw)), 1, this.morph * 0.7);
      const fy = lerp(Math.max(0.18, cp), 1, this.morph * 0.7);
      const eyeMult = this.isMini ? 1.9 : 1.0;
      const ew = R * EYE_W * this.es * eyeMult;
      const eh = R * EYE_H * this.es * eyeMult;

      x.save();
      x.translate(ex, ey);
      x.scale(fx, fy);
      this.drawEyeShape(x, shape, ew, eh, sd, ink);
      x.restore();
    }
    x.restore();
  }

  private drawEyeShape(
    x: CanvasRenderingContext2D, shape: EyeShape,
    w: number, h: number, sd: number, ink: string,
  ) {
    const t = now();
    switch (shape) {
      case "wide":
        this.drawEyeShape(x, "pill", w * 1.16, h * 1.12, sd, ink);
        break;
      case "pill": {
        const hh = Math.max(h * this.open, w * 0.3);
        roundRectPath(x, -w / 2, -hh / 2, w, hh, Math.min(w / 2, hh / 2));
        x.fill();
        break;
      }
      case "dot":
        x.beginPath();
        x.arc(0, 0, w * 0.45, 0, Math.PI * 2);
        x.fill();
        break;
      case "line":
        x.rotate(-sd * 0.2);
        roundRectPath(x, -w * 0.78, -w * 0.21, w * 1.56, w * 0.42, w * 0.21);
        x.fill();
        break;
      case "flat":
        roundRectPath(x, -w * 0.72, -w * 0.2, w * 1.44, w * 0.4, w * 0.2);
        x.fill();
        break;
      case "happy":
        x.lineWidth = w * 0.5;
        x.lineCap = "round";
        x.beginPath();
        x.arc(0, h * 0.18, w * 0.82, Math.PI * 1.12, Math.PI * 1.88);
        x.stroke();
        break;
      case "closed":
        x.lineWidth = w * 0.36;
        x.lineCap = "round";
        x.beginPath();
        x.arc(0, -h * 0.08, w * 0.78, Math.PI * 0.15, Math.PI * 0.85);
        x.stroke();
        break;
      case "spiral": {
        x.lineWidth = w * 0.22;
        x.lineCap = "round";
        x.beginPath();
        for (let a = 0; a < 4.4 * Math.PI; a += 0.2) {
          const r = w * 0.06 + a * w * 0.058;
          const aa = a + t * 9 * sd;
          const px = Math.cos(aa) * r;
          const py = Math.sin(aa) * r;
          if (a === 0) x.moveTo(px, py);
          else x.lineTo(px, py);
        }
        x.stroke();
        break;
      }
      case "heart":
        x.fillStyle = "#FF4D6D";
        heartPath(x, w * 1.2);
        x.fill();
        x.fillStyle = ink;
        break;
      case "star":
        x.fillStyle = "#F7B32B";
        x.rotate(t * 1.5 * sd);
        starPath(x, w * 1.05, w * 0.46);
        x.fill();
        x.fillStyle = ink;
        break;
      case "tired":
        roundRectPath(x, -w / 2, -h * 0.02, w, h * 0.38, w / 2);
        x.fill();
        roundRectPath(x, -w * 0.62, -h * 0.1, w * 1.24, w * 0.22, w * 0.11);
        x.fill();
        break;
      case "wink":
        if (sd < 0) {
          const hh = Math.max(h * this.open, w * 0.3);
          roundRectPath(x, -w / 2, -hh / 2, w, hh, Math.min(w / 2, hh / 2));
          x.fill();
        } else {
          x.lineWidth = w * 0.5;
          x.lineCap = "round";
          x.beginPath();
          x.arc(0, h * 0.18, w * 0.82, Math.PI * 1.12, Math.PI * 1.88);
          x.stroke();
        }
        break;
      case "cup": {
        // Flat top, rounded bottom corners (U shape) — used while the box is open
        const hh = Math.max(h * this.open, w * 0.3);
        const cr = Math.min(w / 2, hh / 2);
        x.beginPath();
        x.moveTo(-w / 2, -hh / 2);
        x.lineTo(w / 2, -hh / 2);
        x.lineTo(w / 2, hh / 2 - cr);
        x.quadraticCurveTo(w / 2, hh / 2, w / 2 - cr, hh / 2);
        x.lineTo(-w / 2 + cr, hh / 2);
        x.quadraticCurveTo(-w / 2, hh / 2, -w / 2, hh / 2 - cr);
        x.closePath();
        x.fill();
        break;
      }
    }
  }

  /** Mailbox slot: dark pill cut into the box face, with rim and lip highlights. */
  private drawMouth(x: CanvasRenderingContext2D, body: Path2D, R: number) {
    const m = this.morph;
    const hW = R * 1.8 * m;
    const hH = this.slotH * R * m;
    const hX = -hW / 2;
    const boxTop = -R * (0.88 + 0.06 * m);
    const hY = boxTop + R * 0.08 * m;

    x.save();
    x.clip(body);

    x.strokeStyle = `rgba(255,255,255,${0.55 * m})`;
    x.lineWidth = 1;
    x.lineCap = "round";
    x.beginPath();
    x.moveTo(-R * 0.9 * m, boxTop + 1);
    x.lineTo(R * 0.9 * m, boxTop + 1);
    x.stroke();

    if (hH > 0.8) {
      const hR = Math.min(hW / 2, hH / 2);
      const g = x.createLinearGradient(0, hY, 0, hY + hH);
      g.addColorStop(0, "rgb(7,8,10)");
      g.addColorStop(1, "rgb(16,19,26)");
      roundRectPath(x, hX, hY, hW, hH, hR);
      x.fillStyle = g;
      x.fill();
      if (hH > 4) {
        const lipR = Math.min(hR, (hW - 2) / 2);
        x.strokeStyle = `rgba(255,255,255,${0.28 * m})`;
        x.beginPath();
        x.moveTo(hX + lipR, hY + hH - 0.5);
        x.lineTo(hX + hW - lipR, hY + hH - 0.5);
        x.stroke();
      }
    }
    x.restore();
  }

  /** Hands sit behind the body — drawn before it, in world coordinates. */
  private drawHandsBehind(
    x: CanvasRenderingContext2D,
    R: number, rx: number, ry: number, cx: number, cy: number,
  ) {
    if (this.hands <= 0.01 || this.isMini) return;
    if (R <= 14) return; // meaningless at compact/peek sizes

    const n = now();
    const bodyH = 2 * ry;
    const hew = 0.3 * ry * this.hands;
    const heh = 0.26 * ry * this.hands;
    const hwB = rx * this.sx;
    const hhB = ry * this.sy;
    const isWaving = n >= this.waveStart && this.waveStart > 0 && n < this.waveUntil;

    for (const sd of [-1, 1]) {
      let localX: number;
      let localY: number;
      let handRot = 0;

      if (sd > 0 && isWaving) {
        const wt = n - this.waveStart;
        const rise = Math.min(1, wt / 0.18);
        const riseEased = 1 - Math.pow(1 - rise, 3);
        const restX = hwB * 1.08;
        const restY = hhB * 0.7;
        const oscX = Math.cos(13 * wt) * 0.06 * bodyH;
        const oscY = -Math.sin(13 * wt) * 0.14 * bodyH;
        const waveX = hwB * 1.1 + oscX;
        const waveY = -hhB * 0.15 + oscY;
        localX = restX + (waveX - restX) * riseEased;
        localY = restY + (waveY - restY) * riseEased;
        handRot = (-0.5 + Math.sin(13 * wt) * 0.35) * riseEased;
      } else if (sd < 0 && isWaving) {
        const wt = n - this.waveStart;
        localX = -hwB * 1.08;
        localY = hhB * 0.7 + Math.sin(6 * wt) * 0.04 * bodyH;
      } else {
        localX = sd * hwB * 1.08;
        localY = hhB * 0.7;
      }

      const cosT = Math.cos(this.tilt);
      const sinT = Math.sin(this.tilt);
      const worldX = cx + cosT * localX - sinT * localY;
      const worldY = cy + sinT * localX + cosT * localY;

      x.save();
      x.translate(worldX, worldY);
      if (handRot !== 0) x.rotate(handRot);
      const g = x.createLinearGradient(hew * 0.7, -heh * 0.85, -hew * 0.8, heh * 0.9);
      if (this.bodyColor) {
        g.addColorStop(0, rgba(mix3(this.bodyColor, [1, 1, 1], 0.35)));
        g.addColorStop(1, rgba(this.bodyColor));
      } else {
        g.addColorStop(0, rgba(BASE_TOP));
        g.addColorStop(1, rgba(BASE_BOTTOM));
      }
      x.beginPath();
      x.ellipse(0, 0, hew, heh, 0, 0, Math.PI * 2);
      x.fillStyle = g;
      x.fill();
      x.strokeStyle = "rgba(0,0,0,0.08)";
      x.lineWidth = 1;
      x.stroke();
      x.restore();
    }
  }

  private drawBadge(x: CanvasRenderingContext2D, badge: Badge, R: number, cx: number, cy: number) {
    const bs = this.badgeS * (this.isMini ? 1.25 : 1);
    const bx = cx - R * 0.72 * this.sx;
    const by = cy - R * 0.72 * this.sy;
    const t = now();

    x.save();
    x.translate(bx, by);
    x.scale(bs, bs);
    const col = rgba(badge.color);

    if (badge.kind === "dots") {
      if (this.isMini) {
        const phase = (t * 2.4) % 1;
        const dotR = R * 0.22 * (1 + 0.25 * Math.sin(phase * Math.PI * 2));
        x.fillStyle = "#000";
        x.beginPath();
        x.arc(0, 0, R * 0.2, 0, Math.PI * 2);
        x.fill();
        x.fillStyle = col;
        x.beginPath();
        x.arc(0, 0, dotR, 0, Math.PI * 2);
        x.fill();
      } else {
        const pw = R * 0.72;
        const ph = R * 0.36;
        roundRectPath(x, -pw / 2, -ph / 2, pw, ph, ph / 2);
        x.fillStyle = col;
        x.fill();
        for (let i = 0; i < 3; i++) {
          const phase = (((t * 2.4 - i * 0.22) % 1) + 1) % 1;
          const dotR = R * 0.055 * (1 + 0.4 * Math.max(0, Math.sin(phase * Math.PI * 2)));
          x.fillStyle = "#fff";
          x.beginPath();
          x.arc((i - 1) * R * 0.18, 0, dotR, 0, Math.PI * 2);
          x.fill();
        }
      }
    } else if (badge.kind === "bang" || badge.kind === "question") {
      x.fillStyle = "#000";
      x.beginPath();
      x.arc(0, 0, R * 0.3, 0, Math.PI * 2);
      x.fill();
      x.fillStyle = col;
      x.beginPath();
      x.arc(0, 0, R * 0.23, 0, Math.PI * 2);
      x.fill();
      if (!this.isMini) {
        x.fillStyle = "#fff";
        x.font = `900 ${R * 0.32}px ${FONT}`;
        x.textAlign = "center";
        x.textBaseline = "middle";
        x.fillText(badge.kind === "bang" ? "!" : "?", 0, R * 0.02);
      }
    } else {
      x.fillStyle = "#000";
      x.beginPath();
      x.arc(0, 0, R * 0.2, 0, Math.PI * 2);
      x.fill();
      x.fillStyle = col;
      x.beginPath();
      x.arc(0, 0, R * 0.135, 0, Math.PI * 2);
      x.fill();
    }
    x.restore();
  }

  private drawParticles(x: CanvasRenderingContext2D, R: number, cx: number, cy: number) {
    for (const p of this.particles) {
      if (p.age <= 0) continue;
      const k = p.age / p.life;
      const a = k < 0.2 ? k / 0.2 : 1 - (k - 0.2) / 0.8;
      const px = cx + (p.x + p.vx * p.age) * R * 1.3;
      const py = cy + (p.y + p.vy * p.age) * R * 1.3;
      const sz = R * p.size * (1 + k * 0.4);

      x.save();
      x.translate(px, py);
      x.globalAlpha = Math.min(1, Math.max(0, a));
      switch (p.type) {
        case "heart":
          x.rotate(Math.sin(p.age * 6) * 0.3);
          x.fillStyle = "#FF4D6D";
          heartPath(x, sz);
          x.fill();
          break;
        case "star":
          x.rotate(p.rot + p.age * 2);
          x.fillStyle = "#F7B32B";
          starPath(x, sz, sz * 0.45);
          x.fill();
          break;
        case "spark":
          x.rotate(p.rot);
          x.fillStyle = "#fff";
          starPath(x, sz * 0.8, sz * 0.18);
          x.fill();
          break;
        case "sweat":
          x.fillStyle = "#7CC7FF";
          x.beginPath();
          x.moveTo(0, -sz);
          x.quadraticCurveTo(sz * 0.8, sz * 0.2, 0, sz * 0.6);
          x.quadraticCurveTo(-sz * 0.8, sz * 0.2, 0, -sz);
          x.fill();
          break;
        case "confetti": {
          const palette = ["#F87171", "#FBBF24", "#34D399", "#60A5FA", "#A78BFA", "#F472B6"];
          x.rotate(p.rot + p.age * 7);
          x.fillStyle = palette[Math.floor(Math.abs(p.rot) * 100) % palette.length];
          x.fillRect(-sz * 0.45, -sz * 0.22, sz * 0.9, sz * 0.44);
          break;
        }
        case "note":
          x.rotate(p.rot + Math.sin(p.age * 5) * 0.25);
          x.fillStyle = "#fff";
          x.font = `700 ${sz * 2.2}px ${FONT}`;
          x.textAlign = "center";
          x.textBaseline = "middle";
          x.fillText(p.size > 0.185 ? "♫" : "♪", 0, 0);
          break;
        case "z":
          x.fillStyle = "rgb(209,219,235)";
          x.font = `700 ${sz * 1.9}px ${FONT}`;
          x.textAlign = "center";
          x.textBaseline = "middle";
          x.fillText("z", 0, 0);
          break;
      }
      x.restore();
    }
  }
}

/** Ray → rounded-rect boundary intersection, for the mailbox morph. */
function rrPoint(ca: number, sa: number, W: number, H: number, cr: number): { x: number; y: number } {
  const eps = 1e-6;
  const kx = ca >= 0 ? 1 : -1;
  const ky = sa >= 0 ? 1 : -1;
  const cx = kx * (W - cr);
  const cy = ky * (H - cr);

  const dot = ca * cx + sa * cy;
  const disc = dot * dot - (cx * cx + cy * cy - cr * cr);
  if (disc >= 0) {
    const t = dot + Math.sqrt(disc);
    if (t > eps) {
      const px = ca * t;
      const py = sa * t;
      if (Math.abs(px) >= W - cr - eps && Math.abs(py) >= H - cr - eps) return { x: px, y: py };
    }
  }
  if (Math.abs(sa) > eps) {
    const t = (ky * H) / sa;
    if (t > eps) {
      const px = ca * t;
      if (Math.abs(px) <= W - cr + eps) return { x: px, y: ky * H };
    }
  }
  if (Math.abs(ca) > eps) {
    const t = (kx * W) / ca;
    if (t > eps) {
      const py = sa * t;
      if (Math.abs(py) <= H - cr + eps) return { x: kx * W, y: py };
    }
  }
  return { x: kx * W, y: ky * H };
}
