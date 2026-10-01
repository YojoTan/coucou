// The squad over the desktop pet (macOS PetSquadView): a tiny Mochi per live
// coding-agent session and per Orca worktree that is working or waiting, at
// most 8. A click goes to that session; the island knows where it lives.

import "./pet.css";
import { emitTo, listen } from "@tauri-apps/api/event";
import { h, clear } from "../views/dom";
import { createMiniBot, pruneMiniBots, tickMiniBots } from "../mochi/minibots";
import type { AgentTask } from "../core/state";

interface Member { id: string; name: string; color: string; state: AgentTask["state"] }

const row = h("div", { class: "squad" });
document.getElementById("root")!.append(row);
let key = "";

void listen<Member[]>("pet-squad", (e) => {
  const members = e.payload.slice(0, 8);
  const k = members.map((m) => `${m.id}:${m.state}:${m.color}`).join("|");
  if (k === key) return;
  key = k;
  clear(row);
  for (const m of members) {
    const bot = createMiniBot({ id: `squad_${m.id}`, name: m.name, color: m.color, state: m.state, stepIndex: 0, steps: [], source: "n8n", isIntegration: true }, 13);
    row.append(h("button", { class: "squad-bot", title: m.name, onclick: () => void emitTo("island", "pet-squad-open", { id: m.id }) }, bot));
  }
  pruneMiniBots();
}).then(() => emitTo("island", "pet-squad-ready", null));

let last = performance.now();
function frame(t: number) {
  if (t - last >= 1000 / 30) {
    tickMiniBots(Math.min(0.05, (t - last) / 1000));
    last = t;
  }
  requestAnimationFrame(frame);
}
requestAnimationFrame(frame);
