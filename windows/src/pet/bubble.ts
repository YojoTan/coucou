// The desktop Mochi's speech bubble (macOS PetBubbleView): the island's
// current toast, beside the pet on the side with room. Clicks go through it.

import "./pet.css";
import { listen } from "@tauri-apps/api/event";
import { t as tr } from "../core/i18n";

const row = document.createElement("div");
row.id = "bubble-row";
const bubble = document.createElement("div");
bubble.className = "bubble";
const dot = document.createElement("i");
const text = document.createElement("span");
bubble.append(dot, text);
row.append(bubble);
document.getElementById("root")!.append(row);

let toast: { text: string; color: string } | null = null;
let saying: string | null = null;
let sayTimer: number | null = null;

/** What Mochi says (an answer, "Ouch!", a visitor's news) first, else the toast. */
function render() {
  bubble.classList.toggle("on", saying != null || toast != null);
  bubble.classList.toggle("say", saying != null);
  if (saying != null) {
    dot.style.display = "none";
    text.textContent = saying;
  } else if (toast) {
    dot.style.display = "";
    dot.style.background = toast.color;
    text.textContent = toast.text;
  }
}

void listen<{ text: string; color: string } | null>("pet-toast", (e) => {
  toast = e.payload;
  render();
});

void listen<{ text: string; seconds: number; translate?: boolean }>("pet-say", (e) => {
  const s = e.payload;
  saying = s.translate ? tr(s.text) : s.text;
  if (sayTimer != null) window.clearTimeout(sayTimer);
  sayTimer = window.setTimeout(() => {
    saying = null;
    sayTimer = null;
    render();
  }, Math.max(1, s.seconds) * 1000);
  render();
});

void listen<{ left: boolean }>("pet-side", (e) => {
  row.classList.toggle("left", e.payload.left);
  bubble.style.transformOrigin = e.payload.left ? "right center" : "left center";
});
