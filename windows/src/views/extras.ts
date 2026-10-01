// The Extras' cards — ports of CustomCardView, CalendarCardView, SystemCardView
// and WeatherCardView (ExtrasViews.swift). Their data comes from island/extras.ts.

import { t } from "../core/i18n";
import { h } from "./dom";
import { Bridge } from "../core/bridge";
import { State, type AgentTask } from "../core/state";
import { weatherWords } from "../island/extras";

function head(color: string, title: string, subtitle: string): HTMLElement {
  return h("div", { class: "int-head" },
    h("i", { class: "dot", style: `background:${color};width:7px;height:7px` }),
    h("b", { text: title }),
    h("span", { text: subtitle }),
  );
}

function chip(text: string, color: string): HTMLElement {
  const el = h("div", { class: "ex-chip", text, title: text });
  el.style.background = `${color}1A`;
  return el;
}

function link(label: string, color: string, onclick: () => void): HTMLElement {
  return h("button", { class: "link-btn", style: `color:${color}`, text: label, onclick });
}

function ago(at: number): string {
  const s = Math.max(0, Math.round((Date.now() - at) / 1000));
  if (s < 60) return t("just now");
  if (s < 3600) return t("{n} min ago", { n: Math.floor(s / 60) });
  return t("{n} h ago", { n: Math.floor(s / 3600) });
}

/** A custom Mochi: its latest news, Run now, Edit. */
export function customCard(task: AgentTask, openSettings: () => void): HTMLElement {
  const m = State.settings.customMochis?.find((x) => x.id === task.id);
  const color = m?.color ?? task.color;
  const status = State.extras.customStatus[task.id];
  const body = h("div", { class: "int-rows" });
  if (status?.text) body.append(chip(status.text, color));
  else {
    body.append(h("div", {
      class: "int-sub ex-hint",
      text: m?.command ? t("Runs its command every {n} s.", { n: m.interval }) : t("Send it news by the local URL (Settings › Extras)."),
    }));
  }
  const actions = h("div", { class: "int-actions" });
  if (m?.command) actions.append(link(t("Run now"), color, () => void Bridge.customRun(task.id)));
  actions.append(link(t("Edit"), "#8E939C", openSettings));
  return h("div", { class: "int-card" }, head(color, m?.name ?? task.name, status ? ago(status.at) : t("Waiting for news")), body, actions);
}

function when(start: number): string {
  const m = Math.ceil((start - Date.now()) / 60_000);
  if (m <= 0) return t("Now");
  if (m < 60) return t("In {n} min", { n: m });
  return t("In {h} h {m} min", { h: Math.floor(m / 60), m: m % 60 });
}

function clock(ms: number): string {
  return new Date(ms).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
}

/** The next meeting, with Join for a call link. */
export function calendarCard(): HTMLElement {
  const e = State.extras.calendarNext;
  if (!e) {
    const error = State.extras.calendarError;
    return h("div", { class: "int-card" }, head("#FF6B6B", t("Calendar"), ""),
      h("div", { class: "int-sub ex-hint", text: error ? t(error) : t("Nothing in the next 24 hours. 🌴") }));
  }
  const actions = h("div", { class: "int-actions" });
  if (e.link) {
    const url = e.link;
    actions.append(h("button", { class: "ex-join", text: t("Join"), onclick: () => void Bridge.openUrl(url) }));
  }
  return h("div", { class: "int-card" },
    head("#FF6B6B", t("Calendar"), when(e.start)),
    h("div", { class: "int-rows" }, chip(e.title, "#FF6B6B"), h("div", { class: "int-sub ex-times", text: `${clock(e.start)} – ${clock(e.end)}` })),
    actions,
  );
}

function gauge(label: string, value: string, alarm: boolean): HTMLElement {
  return h("span", { class: alarm ? "ex-gauge alarm" : "ex-gauge" }, h("i", { text: label }), h("b", { text: value }));
}

/** CPU, battery, free disk, and the build that runs. */
export function systemCard(): HTMLElement {
  const s = State.extras.system;
  const sub = s?.building ? t("Building · {name}", { name: s.building }) : t("All calm");
  if (!s) return h("div", { class: "int-card" }, head("#94A3B8", t("PC"), sub), h("div", { class: "int-sub ex-hint", text: t("Reading the PC…") }));
  const row = h("div", { class: "ex-gauges" }, gauge("CPU", `${s.cpu} %`, s.cpu > 85));
  if (s.battery != null) row.append(gauge(s.charging ? "⚡" : "🔋", `${s.battery} %`, s.battery < 15 && !s.charging));
  row.append(gauge(t("Disk"), `${Math.round(s.diskFreeGB)} GB`, s.diskFreePercent < 5));
  return h("div", { class: "int-card" }, head("#94A3B8", t("PC"), sub), row);
}

/** The sky over the city typed in Settings. */
export function weatherCard(): HTMLElement {
  const w = State.extras.weather;
  if (!w) {
    const error = State.extras.weatherError;
    return h("div", { class: "int-card" }, head("#38BDF8", t("Weather"), ""),
      h("div", { class: "int-sub ex-hint", text: error ? t(error) : t("Looking at the sky…") }));
  }
  const [words, icon] = weatherWords(w.code, w.day);
  const card = h("div", { class: "int-card" },
    head("#38BDF8", t("Weather"), w.place),
    h("div", { class: "ex-weather" }, h("span", { class: "ex-icon", text: icon }), h("b", { text: `${Math.round(w.temperature)}°` }), h("span", { text: words })),
  );
  if (w.rainChance > 0) card.append(h("div", { class: "int-sub", text: t("☔️ {n} % chance of rain in the next 2 h", { n: w.rainChance }) }));
  return card;
}
