// The desktop Mochi itself (macOS DesktopMochiView): the same engine as the
// island's, at 30 fps while it shows, eyes on the cursor (Rust sends where it
// is), dressed and animated as the island says (pet-sync). A drag moves it, a
// click opens its menu, a right click too, a double click sends it home.

import "./pet.css";
import { emitTo, listen } from "@tauri-apps/api/event";
import { invoke } from "@tauri-apps/api/core";
import { BotEngine, hexToRGB } from "../mochi/engine";
import { Ease } from "../core/anim";
import type { BotStateName } from "../core/layout";
import type { MochiAccessory } from "../mochi/accessories";
import { t } from "../core/i18n";

/** What the island's Mochi looks like right now (island/pet.ts). */
export interface PetSnapshot {
  state: BotStateName;
  color: string | null;
  accessory: MochiAccessory;
  accessoryColor: string | null;
  sweating: boolean;
  sleepy: boolean;
  scruffy: boolean;
  panicked: boolean;
  musicHeadphones: boolean;
  musicPlaying: boolean;
  voiceHeadset: boolean;
  talking: boolean;
  micMuted: boolean;
  deafened: boolean;
  othersSpeaking: boolean;
  callStartedAt: number | null;
}

export type PetFx = { kind: "greet" } | { kind: "react"; reaction: string } | { kind: "emote"; emote: string };

const SIZE = 92;
const root = document.getElementById("root")!;
const stage = document.createElement("div");
stage.id = "stage";
const halo = document.createElement("div");
halo.id = "halo";
const canvas = document.createElement("canvas");
canvas.id = "pet";
stage.append(halo, canvas);
stage.title = t("Click: Mochi's menu (island, chat, worktrees…) · Double click: back to the island");
root.append(stage);

const dpr = Math.min(2, window.devicePixelRatio || 1);
canvas.width = Math.round(SIZE * dpr);
canvas.height = Math.round(SIZE * dpr);

const engine = new BotEngine();
engine.setState("idle", true);
const now = () => performance.now() / 1000;

function apply(s: PetSnapshot) {
  engine.setState(s.state);
  engine.bodyColor = s.color ? hexToRGB(s.color) : null;
  engine.accessory = s.accessory;
  engine.accessoryColor = s.accessoryColor;
  engine.sweating = s.sweating;
  engine.sleepy = s.sleepy;
  engine.scruffy = s.scruffy;
  if (engine.panicked !== s.panicked) engine.panicked = s.panicked;
  engine.musicHeadphones = s.musicHeadphones;
  if (s.musicPlaying && !engine.musicPlaying) engine.musicStart();
  engine.musicPlaying = s.musicPlaying;
  engine.voiceHeadset = s.voiceHeadset;
  engine.talking = s.talking;
  engine.micMuted = s.micMuted;
  engine.deafened = s.deafened;
  engine.othersSpeaking = s.othersSpeaking;
  engine.callStartedAt = s.callStartedAt;
}

void listen<PetSnapshot>("pet-sync", (e) => apply(e.payload));
void listen<{ x: number; y: number }>("pet-look", (e) => {
  engine.lookX = e.payload.x;
  engine.lookY = -e.payload.y;
});
// A hop: a squash on take-off and landing, happy eyes.
void listen("pet-hop", () => {
  engine.squash();
  engine.eyeOverride = "happy";
  engine.eyeOverrideUntil = now() + 1;
});
// A teleport: sparkles, closed eyes on the way out, a squash on arrival.
void listen<boolean>("pet-teleport", (e) => {
  engine.emit("spark", 10);
  if (e.payload) {
    stage.classList.remove("gone");
    engine.squash();
  } else {
    stage.classList.add("gone");
    engine.eyeOverride = "closed";
    engine.eyeOverrideUntil = now() + 0.4;
  }
});
// A throw hit an edge.
void listen("pet-bump", () => engine.squash());
// A file over it: surprised; dropped: it gulps it.
void listen("pet-hungry", () => engine.triggerEmote("surprised"));
void listen("pet-gulp", () => {
  engine.squash();
  engine.eyeOverride = "happy";
  engine.eyeOverrideUntil = now() + 1.2;
});
void listen<PetFx>("pet-fx", (e) => {
  const fx = e.payload;
  if (fx.kind === "greet") engine.greet();
  else if (fx.kind === "react") engine.react(fx.reaction as Parameters<BotEngine["react"]>[0]);
  else engine.triggerEmote(fx.emote as Parameters<BotEngine["triggerEmote"]>[0]);
});

// 30 fps is plenty for a pet on the desktop.
let last = performance.now();
function frame(t: number) {
  if (t - last >= 1000 / 30) {
    const dt = Math.min(0.05, (t - last) / 1000);
    last = t;
    engine.update(dt);
    const ctx = canvas.getContext("2d");
    if (ctx) {
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
      ctx.clearRect(0, 0, SIZE, SIZE);
      engine.draw(ctx, SIZE, SIZE);
    }
  }
  requestAnimationFrame(frame);
}
requestAnimationFrame(frame);

// ── The mouse: drag, click, right click, double click ────────────────────────

let press: { x: number; y: number } | null = null;
let clickTimer: number | null = null;

document.addEventListener("mousedown", (e) => {
  if (e.button !== 0) return;
  press = { x: e.screenX, y: e.screenY };
});
document.addEventListener("mousemove", (e) => {
  if (!press || (e.buttons & 1) === 0) return;
  if (Math.hypot(e.screenX - press.x, e.screenY - press.y) > 3) {
    press = null;
    if (clickTimer != null) window.clearTimeout(clickTimer);
    void invoke("pet_drag");
  }
});
document.addEventListener("mouseup", (e) => {
  if (e.button !== 0 || !press) return;
  press = null;
  if (clickTimer != null) window.clearTimeout(clickTimer);
  clickTimer = null;
  if (e.detail >= 2) {
    void invoke("pet_dock");
    return;
  }
  // A click opens the menu, once it's clear no second click is coming.
  clickTimer = window.setTimeout(() => {
    clickTimer = null;
    void invoke("pet_menu_toggle");
  }, 380);
});
// Petting: five quick back-and-forths of the cursor over Mochi → hearts.
const strokes: { t: number; dir: number }[] = [];
let lastX: number | null = null;
let lastPetted = 0;
document.addEventListener("mousemove", (e) => {
  if (e.buttons !== 0) return;
  const x = e.screenX;
  const t = performance.now() / 1000;
  if (lastX != null && Math.abs(x - lastX) > 2) {
    const dir = x > lastX ? 1 : -1;
    if (strokes.at(-1)?.dir !== dir) strokes.push({ t, dir });
    while (strokes.length && t - strokes[0].t > 1.2) strokes.shift();
    if (strokes.length >= 5 && t - lastPetted > 2) {
      lastPetted = t;
      strokes.length = 0;
      engine.emit("heart", 5);
      engine.eyeOverride = "happy";
      engine.eyeOverrideUntil = t + 1.6;
      engine.anim("blush", [[1, 200, Ease.out], [1, 900, Ease.lin], [0, 500, Ease.inOut]]);
      void emitTo("island", "pet-sound", "love");
    }
  }
  lastX = x;
});
document.addEventListener("mouseleave", () => {
  lastX = null;
  strokes.length = 0;
});
document.addEventListener("contextmenu", (e) => {
  e.preventDefault();
  if (clickTimer != null) window.clearTimeout(clickTimer);
  clickTimer = null;
  void invoke("pet_menu_toggle");
});
