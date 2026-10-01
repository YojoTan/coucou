// The Discord card — port of DiscordCardView (DiscordViews.swift).
// In a call: who's in, as tiny Mochis in their own colour (they talk when the
// person talks, keep the mouth shut muted, sleep deafened), then mute, deafen,
// the devices and Open. Otherwise: the call that just ended, the latest DMs and
// mentions, or what is missing to get them.

import { t } from "../core/i18n";
import { h, svg } from "./dom";
import { ICONS } from "./icons";
import { Bridge } from "../core/bridge";
import { State, type AgentTask, type DiscordMember } from "../core/state";
import { colorForProject } from "../core/layout";
import { createMiniBot, miniEngineOf } from "../mochi/minibots";

const BLURPLE = "#5865F2";

function subtitle(): string {
  const d = State.discord;
  if (!d?.running) return t("Not running");
  if (d.voice) return d.voice.name ? `🔊 ${d.voice.name}` : t("In a call");
  if (d.unread > 0) return d.unread === 1 ? t("1 mention") : t("{n} mentions", { n: d.unread });
  return t("All read");
}

function hint(): string {
  switch (State.discord?.link.kind) {
    case "connected": return t("DMs and mentions show up here, calls too.");
    case "waitingApproval": return t("Approve Coucou in the Discord window.");
    case "failed": return t("Discord connection failed — see Settings › Integrations › Discord.");
    default: return t("Connect Discord in Settings for calls, mute and DMs.");
  }
}

function memberBot(m: DiscordMember, speaking: boolean): HTMLElement {
  const slot = createMiniBot({
    id: `member_${m.id}`, name: m.name, color: colorForProject(m.name), state: "idle", stepIndex: 0, steps: [],
    source: "n8n", isIntegration: true,
  } as AgentTask, 13);
  const e = miniEngineOf(slot);
  if (e) {
    e.mouthAlways = true;
    e.micMuted = m.muted || m.deafened;
    e.deafened = m.deafened;
    e.talking = speaking && !e.micMuted;
  }
  const wrap = h("span", { class: "dc-member" + (speaking ? " speaking" : ""), title: m.name }, slot);
  if (m.muted || m.deafened) wrap.append(h("i", { class: "dc-muted", text: m.deafened ? "🔇" : "✕" }));
  return wrap;
}

function pillButton(label: string, on: boolean, run: () => void, icon: string): HTMLElement {
  return h("button", { class: "dc-toggle" + (on ? " on" : ""), title: label, onclick: run }, svg(icon, 10));
}

function callLine(): string | null {
  const c = State.discordLastCall;
  if (!c || Date.now() - c.endedAt > 30 * 60_000) return null;
  const parts = ["📞 " + t("{n} min", { n: c.minutes })];
  if (c.myShare > 0 || c.top) parts.push(t("you {n} %", { n: Math.round(c.myShare * 100) }) + (c.myShare > 0.6 && c.top ? " 🎤" : ""));
  if (c.top && c.topShare > 0) parts.push(`${c.top} ${Math.round(c.topShare * 100)} %`);
  if (c.missed > 0) parts.push(t("{n} alerts", { n: c.missed }));
  return parts.join(" · ");
}

export function discordCard(): HTMLElement {
  const d = State.discord;
  const head = h("div", { class: "int-head" },
    h("i", { class: "dot", style: `background:${BLURPLE};width:7px;height:7px` }),
    h("b", { text: "Discord" }),
    h("span", { text: subtitle() }),
  );
  const body = h("div", { class: "int-rows" });
  const open = h("button", { class: "link-btn dc-open", style: `color:${BLURPLE}`, text: t("Open Discord"), onclick: () => void Bridge.discordOpen(null) });
  if (d?.voice) {
    if (State.discordTalkingMuted) {
      body.append(h("div", { class: "dc-alert" },
        h("span", { text: t("You're muted!") }),
        h("button", { text: t("Unmute"), onclick: () => { void Bridge.discordSet("mute", false); State.discordTalkingMuted = false; State.notify(); } }),
      ));
    }
    const members = h("div", { class: "dc-members" });
    for (const m of d.voice.members.slice(0, 7)) members.append(memberBot(m, d.voice.speaking.includes(m.id)));
    if (d.voice.members.length > 7) members.append(h("span", { class: "int-sub", text: `+${d.voice.members.length - 7}` }));
    body.append(members);
    const actions = h("div", { class: "int-actions" },
      pillButton(d.selfMute ? t("Unmute") : t("Mute"), d.selfMute, () => void Bridge.discordSet("mute", !d.selfMute), ICONS.mic),
      pillButton(d.selfDeaf ? t("Undeafen") : t("Deafen"), d.selfDeaf, () => void Bridge.discordSet("deaf", !d.selfDeaf), ICONS.headphones),
    );
    if (d.devices.inputs.length) {
      const select = h("select", { class: "tune-select dc-device", title: t("Microphone and output") }) as HTMLSelectElement;
      select.append(h("option", { value: "", text: "🎙 🔈" }));
      for (const dev of d.devices.inputs) select.append(h("option", { value: `in:${dev.id}`, text: `${dev.id === d.devices.input ? "✓ " : ""}🎙 ${dev.name}` }));
      for (const dev of d.devices.outputs) select.append(h("option", { value: `out:${dev.id}`, text: `${dev.id === d.devices.output ? "✓ " : ""}🔈 ${dev.name}` }));
      select.addEventListener("change", () => {
        const [kind, id] = [select.value.slice(0, select.value.indexOf(":")), select.value.slice(select.value.indexOf(":") + 1)];
        if (kind === "in") void Bridge.discordSet("input", undefined, id);
        if (kind === "out") void Bridge.discordSet("output", undefined, id);
      });
      actions.append(select);
    }
    actions.append(open);
    body.append(actions);
  } else {
    const line = callLine();
    if (line) body.append(h("div", { class: "int-sub dc-call", text: line }));
    const notes = d?.notes ?? [];
    if (!notes.length && !line) body.append(h("div", { class: "int-sub", text: hint() }));
    for (const n of notes.slice(0, line ? 1 : 2)) {
      body.append(h("button", { class: "dc-note", title: t("Open in Discord"), onclick: () => void Bridge.discordOpen(n.channelId) },
        h("b", { text: n.author }), h("span", { text: n.text })));
    }
    body.append(h("div", { class: "int-actions" }, open));
  }
  return h("div", { class: "int-card" }, head, body);
}
