// Mochis on the network — the island side (Rust: src-tauri/src/lan/).
//
// The `lan` view shows what a paired (or pairing) Mochi asks of this one: the
// pairing code to compare, a file to accept, a message. Nothing here acts on
// its own: every answer is a click.

import { t } from "../core/i18n";
import { h, clear, svg } from "./dom";
import { ICONS } from "./icons";
import { Bridge } from "../core/bridge";
import { State, type LanPeer, type LanPrompt } from "../core/state";
import type { ViewActions, ViewHost } from "./views";
import { createMiniBot, miniEngineOf } from "../mochi/minibots";
import { colorForProject } from "../core/layout";
import { Ease } from "../core/anim";

/**
 * The sender's Mochi walks in from the right to deliver it (GuestMochiView): in
 * its owner's colour, hopping, looking at the card, and a wave once there.
 */
function guestMochi(name: string): HTMLElement {
  const slot = createMiniBot({ id: `guest:${name}`, name, color: colorForProject(name), state: "idle", stepIndex: 0, steps: [], source: "n8n", isIntegration: true }, 32);
  slot.classList.add("lan-guest");
  slot.title = name;
  const e = miniEngineOf(slot);
  if (e) {
    e.lookX = -0.7;
    e.anim("oy", Array.from({ length: 6 }).flatMap(() => [[-0.12, 120, Ease.out], [0, 120, Ease.inOut]] as const));
    window.setTimeout(() => e.greet(), 1300);
  }
  return slot;
}

function sizeLabel(bytes: number): string {
  if (bytes >= 1024 * 1024) return `${(bytes / 1024 / 1024).toFixed(1)} MB`;
  if (bytes >= 1024) return `${Math.round(bytes / 1024)} KB`;
  return `${bytes} B`;
}

/** "working" → "working", with the label when the peer shares it. */
export function peerStatusText(p: LanPeer): string {
  if (!p.online) return t("offline");
  const state = p.status?.state ? t(p.status.state) : t("online");
  return p.status?.label ? `${state} · ${p.status.label}` : state;
}

const STATE_COLORS: Record<string, string> = {
  working: "#38BDF8", thinking: "#A78BFA", approval: "#F5A524", finished: "#22C55E", error: "#F4505E",
};

export function peerColor(p: LanPeer): string {
  if (!p.online) return "#5F646D";
  return STATE_COLORS[p.status?.state ?? ""] ?? "#8E939C";
}

export function buildLan(actions: ViewActions): ViewHost {
  const title = h("div", { class: "title" });
  const sub = h("div", { class: "sub" });
  const code = h("div", { class: "lan-code" });
  const row = h("div", { class: "actions" });
  const guest = h("div", { class: "lan-guest-lane" });
  const el = h(
    "div",
    { class: "view" },
    h("div", { class: "card" }, h("div", { class: "stack", style: "padding:0 18px 0 98px" }, title, sub, code, row), guest),
  );
  let rendered: LanPrompt | null = null;
  let waiting = false;

  const button = (label: string, kind: "primary" | "secondary", onclick: () => void) =>
    h("button", { class: `btn ${kind}`, text: label, onclick });

  const done = () => {
    State.lanPrompt = null;
    actions.lanDone();
  };

  function render(p: LanPrompt) {
    clear(row);
    // Who's visiting: the peer behind a file, a message or a pairing.
    clear(guest);
    if (p.kind === "pair" || p.kind === "file" || p.kind === "message" || p.kind === "received") guest.append(guestMochi(p.peer));
    code.textContent = "";
    code.style.display = "none";
    waiting = false;
    switch (p.kind) {
      case "pair": {
        title.textContent = t("Pair with {name}?", { name: p.peer });
        sub.textContent = t("Pair only if {name}'s screen shows this same code:", { name: p.peer });
        code.textContent = `${p.code.slice(0, 3)} ${p.code.slice(3)}`;
        code.style.display = "";
        const answer = (ok: boolean) => {
          void Bridge.lanDecide(p.token, ok);
          if (!ok) return done();
          waiting = true;
          clear(row);
          sub.textContent = t("Waiting for {name} to confirm…", { name: p.peer });
        };
        row.append(button(t("The codes match"), "primary", () => answer(true)), button(t("Cancel"), "secondary", () => answer(false)));
        break;
      }
      case "file": {
        title.textContent = t("{name} wants to send you a file", { name: p.peer });
        sub.textContent = `${p.name} · ${sizeLabel(p.size)}`;
        row.append(
          button(t("Accept"), "primary", () => {
            void Bridge.lanDecide(p.token, true);
            waiting = true;
            clear(row);
            sub.textContent = t("Receiving {file}…", { file: p.name });
          }),
          button(t("Decline"), "secondary", () => {
            void Bridge.lanDecide(p.token, false);
            done();
          }),
        );
        break;
      }
      case "message": {
        title.textContent = p.peer;
        sub.textContent = p.text;
        row.append(
          button(t("Reply"), "primary", () => {
            State.lanPrompt = null;
            actions.lanCompose(p.peerId, p.peer, "message");
          }),
          button(t("OK"), "secondary", done),
        );
        break;
      }
      case "received": {
        title.textContent = t("{file} received", { file: p.name });
        sub.textContent = t("From {name}, in Downloads › Coucou.", { name: p.peer });
        row.append(
          button(t("Show in folder"), "primary", () => {
            void Bridge.lanReveal(p.path);
            done();
          }),
          button(t("OK"), "secondary", done),
        );
        break;
      }
      case "paired": {
        title.textContent = p.ok ? t("Paired with {name} ✓", { name: p.peer }) : t("Not paired with {name}", { name: p.peer });
        sub.textContent = p.ok
          ? t("You can now see each other's Mochi, send messages and files.")
          : t("One of you cancelled, or the codes didn't match.");
        row.append(button(t("OK"), "secondary", done));
        break;
      }
      case "asked": {
        title.textContent = t("{name}'s Mochi asked yours a question", { name: p.peer });
        sub.textContent = t("Mochi answers it with web search only — never your files.");
        row.append(button(t("OK"), "secondary", done));
        break;
      }
    }
  }

  return {
    el,
    sync() {
      const p = State.lanPrompt;
      if (p && p !== rendered && !(waiting && rendered?.kind === p.kind && "token" in p && "token" in rendered && p.token === rendered.token)) {
        rendered = p;
        render(p);
      }
    },
  };
}

/** The Mochis pill: paired Mochis, their status, and Message / Ask. */
export function lanCard(openSettings: () => void, compose: (id: string, name: string, mode: "message" | "ask") => void): HTMLElement {
  const peers = State.lan.peers.filter((p) => p.paired);
  const rows = h("div", { class: "int-rows" });
  if (peers.length === 0) {
    rows.append(h("div", { class: "int-sub", text: t("No paired Mochis yet.") }));
    rows.append(h("button", { class: "link-btn", text: t("Pair one in Settings…"), onclick: openSettings }));
  }
  peers.slice(0, 3).forEach((p, i) => {
    const row = h("div", { class: i === 0 ? "int-row first" : "int-row" },
      h("i", { class: "dot", style: `background:${peerColor(p)};width:5px;height:5px` }),
      h("span", { class: "int-name", style: "flex:0 1 auto;max-width:40%", text: p.name }),
      h("span", { class: "int-sub", style: "flex:1 1 0", text: peerStatusText(p) }),
    );
    if (p.online) {
      row.append(
        h("button", { class: "mini-btn", title: t("Message"), onclick: () => compose(p.id, p.name, "message") }, svg(ICONS.bubble, 9)),
        h("button", { class: "mini-btn", title: t("Ask {name}'s Mochi", { name: p.name }), text: "?", onclick: () => compose(p.id, p.name, "ask") }),
      );
    }
    rows.append(row);
  });
  const head = h("div", { class: "int-head" },
    h("i", { class: "dot", style: "background:#F472B6;width:7px;height:7px" }),
    h("b", { text: t("Mochis") }),
    h("span", { text: t("On this network") }),
  );
  return h("div", { class: "int-card" }, head, rows);
}
