// A paired LAN Mochi walking in to the desktop pet (macOS VisitorView): in its
// owner's colour, a wave once there. Rust walks the window (pet.rs, visit).

import "./pet.css";
import { listen } from "@tauri-apps/api/event";
import { BotEngine, hexToRGB } from "../mochi/engine";
import { colorForProject } from "../core/layout";

const SIZE = 64;
const canvas = document.createElement("canvas");
canvas.id = "pet";
document.getElementById("root")!.append(canvas);
const dpr = Math.min(2, window.devicePixelRatio || 1);
canvas.width = Math.round(SIZE * dpr);
canvas.height = Math.round(SIZE * dpr);

const engine = new BotEngine();
engine.setState("idle", true);
let greetTimer: number | null = null;

void listen<{ name: string }>("pet-visitor", (e) => {
  engine.bodyColor = hexToRGB(colorForProject(e.payload.name));
  engine.setState("idle", true);
  engine.lookX = 0;
  if (greetTimer != null) window.clearTimeout(greetTimer);
  greetTimer = window.setTimeout(() => engine.greet(), 1700);
});

let last = performance.now();
function frame(t: number) {
  if (t - last >= 1000 / 30) {
    engine.update(Math.min(0.05, (t - last) / 1000));
    last = t;
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
