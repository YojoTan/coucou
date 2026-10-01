// The desktop Mochi's speech bubble (macOS PetBubbleView): the island's
// current toast, beside the pet on the side with room. Clicks go through it.

import "./pet.css";
import { listen } from "@tauri-apps/api/event";

const row = document.createElement("div");
row.id = "bubble-row";
const bubble = document.createElement("div");
bubble.className = "bubble";
const dot = document.createElement("i");
const text = document.createElement("span");
bubble.append(dot, text);
row.append(bubble);
document.getElementById("root")!.append(row);

void listen<{ text: string; color: string } | null>("pet-toast", (e) => {
  const t = e.payload;
  bubble.classList.toggle("on", t != null);
  if (t) {
    dot.style.background = t.color;
    text.textContent = t.text;
  }
});

void listen<{ left: boolean }>("pet-side", (e) => {
  row.classList.toggle("left", e.payload.left);
  bubble.style.transformOrigin = e.payload.left ? "right center" : "left center";
});
