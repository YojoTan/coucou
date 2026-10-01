// Mochi accessories and moods — port of NotchBuddy/Sources/App/MochiAccessories.swift.
// Things a Mochi can wear or feel, drawn in code like the rest of it, in body
// space (so they hop, tilt and squash with it). Who wears what is decided by
// the extras (a custom Mochi's pick, a trophy, the weather, the system, a mode).

import type { BotEngine } from "./engine";

/** ExtrasParse.MochiAccessory — same names, so settings and scripts agree. */
export type MochiAccessory =
  | "none" | "cap" | "hardhat" | "crown" | "bow" | "antenna"
  | "glasses" | "sunglasses" | "sleepMask" | "umbrella" | "scarf";

/** The ones a custom Mochi can pick (the others belong to weather, mode, trophies). */
export const WEARABLE: MochiAccessory[] = ["none", "cap", "hardhat", "crown", "bow", "antenna", "glasses", "sunglasses", "scarf"];

const EYE_SP = 0.37;
const EYE_P = -0.12;
const INK = "#1B1D22";

const now = () => performance.now() / 1000;

function ellipse(x: CanvasRenderingContext2D, cx: number, cy: number, rx: number, ry: number) {
  x.beginPath();
  x.ellipse(cx, cy, rx, ry, 0, 0, Math.PI * 2);
}

/** Where the eyes sit (same projection as drawEyes), for glasses and the mask. */
export function eyePositions(e: BotEngine, rx: number, ry: number): { x: number; y: number }[] {
  const out: { x: number; y: number }[] = [];
  for (const sd of [-1, 1]) {
    const eyeYaw = sd * EYE_SP + e.yaw;
    const eyePitch = EYE_P + e.pitch + e.roll;
    const cp = Math.cos(eyePitch);
    if (Math.cos(eyeYaw) * cp <= 0.04) continue;
    out.push({ x: Math.sin(eyeYaw) * cp * rx, y: -Math.sin(eyePitch) * ry });
  }
  return out;
}

/** Called from draw(), in body space, after the eyes. */
export function drawAccessory(e: BotEngine, x: CanvasRenderingContext2D, body: Path2D, R: number, rx: number, ry: number) {
  if (e.morph >= 0.05) return;
  const line = Math.max(1, R * 0.06);
  x.save();
  x.lineCap = "round";
  if (e.scruffy && e.accessory === "none") {
    // Left alone for days: a few tufts sticking up.
    x.strokeStyle = "rgba(27,29,34,0.75)";
    x.lineWidth = Math.max(1, R * 0.05);
    for (const [tx, lean, h] of [[-0.3, -0.35, 0.28], [-0.05, 0.1, 0.36], [0.22, 0.4, 0.26]]) {
      x.beginPath();
      x.moveTo(rx * tx, -ry * 0.86);
      x.quadraticCurveTo(rx * (tx - lean * 0.2), -ry * (0.9 + h * 0.6), rx * (tx + lean * 0.4), -ry * (0.86 + h));
      x.stroke();
    }
  }
  const t = now();
  switch (e.accessory) {
    case "none":
      break;
    case "cap": {
      const c = e.accessoryColor ?? "#E5484D";
      x.beginPath();
      x.moveTo(-rx * 0.8, -ry * 0.62);
      x.bezierCurveTo(-rx * 0.75, -ry * 1.42, rx * 0.75, -ry * 1.42, rx * 0.8, -ry * 0.62);
      x.closePath();
      x.fillStyle = c;
      x.fill();
      x.globalAlpha = 0.8;
      x.beginPath();
      x.roundRect(rx * 0.25, -ry * 0.69, rx * 1.0, ry * 0.15, ry * 0.07);
      x.fill();
      x.globalAlpha = 1;
      x.fillStyle = "rgba(255,255,255,0.8)";
      ellipse(x, 0, -ry * 1.22, R * 0.07, R * 0.07);
      x.fill();
      break;
    }
    case "hardhat": {
      const c = "#F5B90A";
      x.beginPath();
      x.moveTo(-rx * 0.8, -ry * 0.62);
      x.bezierCurveTo(-rx * 0.78, -ry * 1.48, rx * 0.78, -ry * 1.48, rx * 0.8, -ry * 0.62);
      x.closePath();
      const g = x.createLinearGradient(0, -ry * 1.1, 0, -ry * 0.66);
      g.addColorStop(0, "#FFD54A");
      g.addColorStop(1, c);
      x.fillStyle = g;
      x.fill();
      x.fillStyle = c;
      x.beginPath();
      x.roundRect(-rx * 0.98, -ry * 0.68, rx * 1.96, ry * 0.14, ry * 0.06);
      x.fill();
      x.strokeStyle = "#C98F00";
      x.lineWidth = line * 1.4;
      x.beginPath();
      x.moveTo(0, -ry * 1.24);
      x.lineTo(0, -ry * 0.68);
      x.stroke();
      break;
    }
    case "crown": {
      const w = rx * 0.82, base = -ry * 0.82, top = -ry * 1.3;
      x.beginPath();
      x.moveTo(-w / 2, base);
      x.lineTo(-w / 2, top + ry * 0.12);
      x.lineTo(-w / 4, base - ry * 0.16);
      x.lineTo(0, top);
      x.lineTo(w / 4, base - ry * 0.16);
      x.lineTo(w / 2, top + ry * 0.12);
      x.lineTo(w / 2, base);
      x.closePath();
      const g = x.createLinearGradient(0, top, 0, base);
      g.addColorStop(0, "#FFE08A");
      g.addColorStop(1, "#F7B32B");
      x.fillStyle = g;
      x.fill();
      for (const [gx, col] of [[-w / 4, "#E5484D"], [0, "#3E63DD"], [w / 4, "#30A46C"]] as [number, string][]) {
        x.fillStyle = col;
        ellipse(x, gx, base - ry * 0.1, R * 0.055, R * 0.055);
        x.fill();
      }
      break;
    }
    case "bow": {
      const c = e.accessoryColor ?? "#F472B6";
      const cx = rx * 0.42, cy = -ry * 0.86, s = R * 0.26;
      x.fillStyle = c;
      for (const sd of [-1, 1]) {
        x.beginPath();
        x.moveTo(cx, cy);
        x.lineTo(cx + sd * s, cy - s * 0.6);
        x.lineTo(cx + sd * s, cy + s * 0.6);
        x.closePath();
        x.fill();
      }
      x.globalAlpha = 0.8;
      ellipse(x, cx, cy, s * 0.25, s * 0.25);
      x.fill();
      break;
    }
    case "antenna": {
      const tip = { x: rx * 0.15 + Math.sin(t * 2.2) * R * 0.08, y: -ry * 1.5 };
      x.strokeStyle = INK;
      x.lineWidth = line;
      x.beginPath();
      x.moveTo(0, -ry * 0.9);
      x.quadraticCurveTo(-rx * 0.05, -ry * 1.25, tip.x, tip.y);
      x.stroke();
      x.globalAlpha = 0.6 + 0.4 * Math.abs(Math.sin(t * 3));
      x.fillStyle = e.accessoryColor ?? "#FF5D5D";
      ellipse(x, tip.x, tip.y, R * 0.1, R * 0.1);
      x.fill();
      break;
    }
    case "glasses":
    case "sunglasses": {
      const eyes = eyePositions(e, rx, ry);
      const r = R * 0.2;
      x.lineWidth = line;
      for (const p of eyes) {
        x.beginPath();
        x.roundRect(p.x - r, p.y - r * 0.85, r * 2, r * 1.7, r * 0.55);
        if (e.accessory === "sunglasses") {
          x.fillStyle = "rgba(17,19,24,0.92)";
          x.fill();
          x.strokeStyle = "rgba(255,255,255,0.5)";
          x.lineWidth = line * 0.8;
          x.beginPath();
          x.moveTo(p.x - r * 0.5, p.y - r * 0.4);
          x.lineTo(p.x - r * 0.1, p.y - r * 0.6);
          x.stroke();
          x.lineWidth = line;
          x.beginPath();
          x.roundRect(p.x - r, p.y - r * 0.85, r * 2, r * 1.7, r * 0.55);
        }
        x.strokeStyle = INK;
        x.stroke();
      }
      if (eyes.length === 2) {
        const [a, b] = eyes;
        x.strokeStyle = INK;
        x.beginPath();
        x.moveTo(a.x + r, a.y - r * 0.2);
        x.quadraticCurveTo((a.x + b.x) / 2, a.y - r * 0.6, b.x - r, b.y - r * 0.2);
        x.stroke();
      }
      break;
    }
    case "sleepMask": {
      x.save();
      x.clip(body);
      const eyes = eyePositions(e, rx, ry);
      const y = eyes[0]?.y ?? ry * 0.1;
      x.fillStyle = "#4C3A8C";
      x.beginPath();
      x.roundRect(-rx * 1.1, y - R * 0.24, rx * 2.2, R * 0.54, R * 0.12);
      x.fill();
      x.strokeStyle = "rgba(255,255,255,0.85)";
      x.lineWidth = line * 0.9;
      for (const p of eyes) {
        x.beginPath();
        x.moveTo(p.x - R * 0.11, y);
        x.quadraticCurveTo(p.x, y + R * 0.1, p.x + R * 0.11, y);
        x.stroke();
      }
      x.restore();
      break;
    }
    case "umbrella": {
      const cx = rx * 0.45, top = -ry * 1.55, r = rx * 0.78;
      x.strokeStyle = INK;
      x.lineWidth = line;
      x.beginPath();
      x.moveTo(cx, top);
      x.lineTo(cx + rx * 0.05, -ry * 0.25);
      x.quadraticCurveTo(cx + rx * 0.15, -ry * 0.05, cx + rx * 0.25, -ry * 0.22);
      x.stroke();
      x.beginPath();
      x.moveTo(cx - r, top + r * 0.45);
      x.quadraticCurveTo(cx, top - r * 0.75, cx + r, top + r * 0.45);
      for (let i = 3; i >= 0; i--) {
        const x0 = cx - r + (i * r) / 2;
        x.quadraticCurveTo(x0 + r / 4, top + r * 0.25, x0, top + r * 0.45);
      }
      x.fillStyle = e.accessoryColor ?? "#3E63DD";
      x.fill();
      // Rain: three drops falling past it.
      for (let i = 0; i < 3; i++) {
        const k = (t * 0.9 + i / 3) % 1;
        x.fillStyle = `rgba(124,199,255,${1 - k})`;
        x.beginPath();
        x.ellipse(cx - r * 1.25 + i * r * 1.2 + R * 0.025, top + k * ry * 1.6 + R * 0.06, R * 0.025, R * 0.06, 0, 0, Math.PI * 2);
        x.fill();
      }
      break;
    }
    case "scarf": {
      const col = e.accessoryColor ?? "#E5484D";
      x.save();
      x.clip(body);
      x.fillStyle = col;
      x.fillRect(-rx * 1.2, ry * 0.5, rx * 2.4, ry * 0.24);
      x.fillStyle = "rgba(255,255,255,0.35)";
      for (let i = 0; i < 5; i++) x.fillRect(-rx + i * rx * 0.5, ry * 0.5, rx * 0.12, ry * 0.24);
      x.restore();
      x.fillStyle = col;
      x.beginPath();
      x.roundRect(rx * 0.45, ry * 0.6, rx * 0.22, ry * 0.5, rx * 0.05);
      x.fill();
      break;
    }
  }
  x.restore();
}

/** Moods set by the extras: sweat, sleepy eyes, panic. Called from update(). */
export function updateMoods(e: BotEngine, n: number) {
  if (e.sweating && n - e.lastMoodSweat > 1.5) {
    e.lastMoodSweat = n;
    e.emit("sweat", 1);
  }
  if (e.sleepy || e.accessory === "sleepMask") {
    const o = e.eyeOverride;
    if (o == null || o === e.permanentEye || o === "tired" || o === "closed") {
      e.eyeOverride = e.accessory === "sleepMask" ? "closed" : "tired";
      e.eyeOverrideUntil = n + 0.3;
    }
  }
  if (e.panicked) {
    e.ox = Math.sin(n * 40) * 0.025;
    const o = e.eyeOverride;
    if (o == null || o === e.permanentEye || o === "wide") {
      e.eyeOverride = "wide";
      e.eyeOverrideUntil = n + 0.3;
    }
  }
}
