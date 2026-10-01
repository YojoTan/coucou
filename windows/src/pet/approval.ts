// The permission card beside the desktop pet (macOS PetApprovalView): the
// island's rules exactly. The command shows in full in a two-line box; Allow
// only when all of it fits and 0.7 s after the card appeared for that request;
// otherwise "Review in terminal", where Claude Code asks in full. Nothing is
// decided here: the island checks the request and decides (island/pet.ts).

import "./pet.css";
import { emitTo, listen } from "@tauri-apps/api/event";
import { t } from "../core/i18n";
import { h } from "../views/dom";

interface Card { requestId: string; agent: string; project: string; command: string }

const ARM_MS = 700;
const root = document.getElementById("root")!;
const who = h("div", { class: "pa-who" });
const code = h("div", { class: "pa-code" });
let card: Card | null = null;
let armedAt = 0;
let fits = false;

const decide = (decision: "allow" | "deny" | "terminal") => {
  if (!card) return;
  void emitTo("island", "pet-approve", { requestId: card.requestId, decision, fits });
};
const deny = h("button", { class: "pa-btn", text: t("Deny"), onclick: () => decide("deny") });
const allow = h("button", { class: "pa-btn allow", text: t("Allow"), onclick: () => {
  refit();
  if (fits && performance.now() >= armedAt) decide("allow");
} });
const review = h("button", { class: "pa-btn review", text: t("Review in terminal"), onclick: () => decide("terminal") });
root.append(h("div", { class: "pa-card" }, who, code, h("div", { class: "pa-row" }, deny, allow, review)));

/** Does the whole command fit the two-line box? Whatever doesn't is never allowed from here. */
function refit() {
  fits = code.scrollHeight <= code.clientHeight + 1;
  allow.style.display = fits ? "" : "none";
  review.style.display = fits ? "none" : "";
}

function arm() {
  allow.classList.toggle("live", performance.now() >= armedAt);
  if (performance.now() < armedAt) window.setTimeout(arm, 60);
}

void listen<Card | null>("pet-card", (e) => {
  const next = e.payload;
  if (!next) {
    card = null;
    return;
  }
  if (next.requestId !== card?.requestId) armedAt = performance.now() + ARM_MS;
  card = next;
  who.textContent = `✋ ${next.agent} · ${next.project ? `${next.project} · ` : ""}${t("needs permission")}`;
  code.textContent = next.command;
  code.title = next.command;
  refit();
  arm();
}).then(() => emitTo("island", "pet-card-ready", null));
