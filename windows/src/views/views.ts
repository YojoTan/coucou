// Island views — DOM ports of IslandViewContent.swift. Paddings, font sizes,
// colours and wording are copied from the Swift views so both platforms read
// identically.

import { t } from "../core/i18n";
import { h, svg, clear, dot } from "./dom";
import { ICONS } from "./icons";
import { agentForTask, agentOf, cycle as cycleSession, taskIdFor } from "../island/sessions";
import { Ticker } from "./ticker";
import { isAgentTask, SOURCE_LABELS, State, type AgentTask, type LanPeer } from "../core/state";
import { colorForProject, washRGBA, type IslandViewName, type Wash } from "../core/layout";
import { createMiniBot, pruneMiniBots } from "../mochi/minibots";
import { buildPrompt } from "./chat";
import { buildLan, lanCard, peerStatusText } from "./lan";
import { buildChoose, buildUpload, buildUploading } from "./upload";
import { renderIntegrationCard, type IntegrationCardHooks } from "./integrations";

export interface ViewActions {
  setView(v: IslandViewName): void;
  collapse(): void;
  setFocus(id: string): void;
  openTerminal(): void;
  /** The ↗ button: opens whatever the focused pill points at. */
  openTarget(): void;
  openUrl(url: string): void;
  /** "terminal" hands the request back: Claude Code asks there, in full. */
  decide(d: "allow" | "deny" | "terminal"): void;
  toggleSound(): void;
  setVolume(v: number): void;
  setAutoClose(seconds: number): void;
  openSettingsWindow(): void;
  blip(): void;
  /** Opens the chat toward a paired Mochi: a message to its user, or a question to it. */
  lanCompose(id: string, name: string, mode: "message" | "ask"): void;
  /** A `lan` prompt is answered: back to where the island was. */
  lanDone(): void;
  /** Header → a paired Mochi → "Send a file…": the picker, then the trip. */
  lanSendFile(id: string, name: string): void;
}

export interface ViewHost {
  el: HTMLElement;
  sync(): void;
  /** Called when the view becomes active, for views with a text field. */
  focus?(): void;
  /** Called every frame while the view is on screen. */
  tick?(nowMs: number): void;
}

// ── Shared pieces ─────────────────────────────────────────────────────────────

function card(wash: Wash, ...children: (Node | string)[]): HTMLElement {
  const el = h("div", { class: wash ? "card wash" : "card" }, ...children);
  if (wash) el.style.setProperty("--wash", washRGBA(wash));
  return el;
}

function btn(
  label: string,
  kind: "primary" | "secondary",
  onClick: () => void,
  kbd?: string,
): HTMLElement {
  return h(
    "button",
    { class: `btn ${kind}`, onclick: onClick },
    h("span", { text: label }),
    kbd ? h("span", { class: "kbd", text: kbd }) : null,
  );
}

/** AgentWho — coloured dot + task name + grey label. */
function agentWho(task: AgentTask | null, label: string): HTMLElement {
  const row = h("div", { class: "who-row" });
  if (task) {
    row.append(dot(task.color, 8), h("span", { class: "n", text: task.name }));
  }
  row.append(h("span", { text: label }));
  return row;
}

function stack(padLeft: number, padRight: number, ...children: Node[]): HTMLElement {
  const el = h("div", { class: "stack" }, ...children);
  el.style.padding = `4px ${padRight}px 4px ${padLeft}px`;
  return el;
}

// ── Header ────────────────────────────────────────────────────────────────────

export function buildHeader(actions: ViewActions): ViewHost {
  const tabHome = h("button", { class: "tab", title: t("Overview"), onclick: () => go("overview") }, svg(ICONS.house, 13));
  const tabChat = h("button", { class: "tab", title: t("Ask"), onclick: () => go("prompt") }, svg(ICONS.bubble, 13));
  const tabDrop = h("button", { class: "tab", title: t("Drop"), onclick: () => go("upload") }, svg(ICONS.plus, 13));

  const gearBtn = h("button", { title: t("Settings"), onclick: () => go("settings") }, svg(ICONS.gear, 14));
  const soundBtn = h("button", { title: t("Mute"), onclick: () => actions.toggleSound() }, svg(ICONS.speakerOn, 14));

  function go(v: IslandViewName) {
    actions.blip();
    actions.setView(v);
  }

  // Paired Mochis on the network, always at hand (macOS NearbyMochisView): a tiny
  // Mochi each in its owner's colour, asleep and dimmed offline; a click opens
  // what can be done with it.
  const nearby = h("div", { class: "nearby" });
  const menu = h("div", { class: "nearby-menu" });
  let nearbyKey = "";
  const closeMenu = () => menu.classList.remove("open");
  document.addEventListener("mousedown", (e) => {
    if (!menu.contains(e.target as Node) && !nearby.contains(e.target as Node)) closeMenu();
  });
  function openMenu(p: LanPeer, anchor: HTMLElement) {
    clear(menu);
    menu.append(h("div", { class: "nearby-head", text: p.online ? `${p.name} · ${peerStatusText(p)}` : `${p.name} · ${t("offline")}` }));
    if (p.online) {
      const item = (label: string, run: () => void) =>
        h("button", { text: label, onclick: () => { closeMenu(); run(); } });
      menu.append(
        item(t("Message"), () => actions.lanCompose(p.id, p.name, "message")),
        item(t("Ask their Mochi"), () => actions.lanCompose(p.id, p.name, "ask")),
        item(t("Send a file…"), () => actions.lanSendFile(p.id, p.name)),
      );
    }
    menu.style.left = `${anchor.offsetLeft - 60}px`;
    menu.classList.add("open");
  }
  function syncNearby() {
    const peers = State.lan.enabled
      ? State.lan.peers.filter((p) => p.paired).sort((a, b) => Number(b.online) - Number(a.online)).slice(0, 4)
      : [];
    const key = peers.map((p) => `${p.id}:${p.online}:${p.status?.state ?? ""}`).join("|");
    if (key === nearbyKey) return;
    nearbyKey = key;
    clear(nearby);
    for (const p of peers) {
      const state = (p.online ? (p.status?.state || "idle") : "sleeping") as AgentTask["state"];
      const bot = createMiniBot({
        id: `peer_${p.id}`, name: p.name, color: colorForProject(p.name), state, stepIndex: 0, steps: [],
        source: "n8n", isIntegration: true,
      } as AgentTask, 13);
      const btn = h("button", { class: "nearby-bot", title: p.name, onclick: () => openMenu(p, btn) }, bot);
      btn.style.opacity = p.online ? "1" : "0.35";
      nearby.append(btn);
    }
    pruneMiniBots();
  }

  const el = h(
    "div",
    { id: "header" },
    h("div", { class: "tabs" }, tabHome, tabChat, tabDrop),
    h("div", { class: "grow" }),
    nearby,
    menu,
    h("div", { class: "header-actions" }, gearBtn, soundBtn),
  );

  return {
    el,
    sync() {
      const v = State.view;
      tabHome.classList.toggle("on", v === "overview" || v === "empty");
      tabChat.classList.toggle("on", v === "prompt");
      tabDrop.classList.toggle("on", v === "upload");
      gearBtn.classList.toggle("on", v === "settings");
      clear(gearBtn);
      gearBtn.append(svg(v === "settings" ? ICONS.gearFill : ICONS.gear, 14));
      clear(soundBtn);
      soundBtn.append(svg(State.settings.soundEnabled ? ICONS.speakerOn : ICONS.speakerOff, 14));
      el.style.opacity = v === "confused" ? "0" : "1";
      syncNearby();
    },
  };
}

// ── Overview ──────────────────────────────────────────────────────────────────

function buildOverview(actions: ViewActions): ViewHost {
  const ticker = new Ticker();
  const who = h("div", { class: "who" });
  const tickerBody = h("div", { class: "card-body" }, who, ticker.el);
  const leftBody = h("div", { class: "left-body" });
  const jump = h(
    "button",
    { class: "icon-btn jump", title: t("Open"), onclick: () => actions.openTarget() },
    svg(ICONS.arrowUpRight, 8),
  );
  const left = card(null, leftBody, jump);
  const pills = h("div", { class: "pills" });
  const right = card(null, pills);

  const el = h("div", { class: "view overview" },
    h("div", { class: "left" }, left),
    h("div", { class: "right" }, right),
  );

  let pillIds = "";
  let detailOpen = false;
  let lastFocus: string | null = null;
  let mode: "ticker" | "card" | null = null;
  let cardKey = "";
  let tickerSession: string | null = null;

  const hooks: IntegrationCardHooks = {
    get detailOpen() {
      return detailOpen;
    },
    openDetail() {
      detailOpen = true;
      cardKey = "";
      State.notify();
    },
    closeDetail() {
      detailOpen = false;
      cardKey = "";
      State.notify();
    },
    openSettings: () => actions.openSettingsWindow(),
  };

  return {
    el,
    tick(nowMs: number) {
      if (mode === "ticker") ticker.tick(nowMs);
    },
    sync() {
      const task = State.focusTask;
      if (task?.id !== lastFocus) {
        lastFocus = task?.id ?? null;
        detailOpen = false;
        cardKey = "";
        mode = null;
      }

      // VS Code with a live Claude Code session keeps the ticker; every other
      // pill shows its own card, exactly like IntegrationCardView.
      const sessionActive =
        isAgentTask(task) && !!task && (task.state !== "idle" || task.steps.length > 0);

      if (task && sessionActive) {
        if (mode !== "ticker") {
          clear(leftBody);
          leftBody.append(tickerBody);
          mode = "ticker";
          cardKey = "";
        }
        clear(who);
        who.append(
          dot(task.color, 7),
          h("span", { class: "name", text: task.name }),
          h("span", { class: "tool", text: SOURCE_LABELS[task.source] }),
        );
        // Several sessions of this agent at once: ⇄ shows the next one.
        const agent = agentForTask(task);
        if (agent && (task.sessionCount ?? 0) > 1) {
          who.append(h("button", {
            class: "session-btn",
            title: t("Show the next session"),
            onclick: () => {
              cycleSession(agent);
              State.notify();
            },
          }, `⇄ ${task.sessionCount}`));
        }
        // A different session: start its ticker fresh instead of scrolling
        // through another project's steps.
        if (task.sessionKey !== tickerSession) {
          tickerSession = task.sessionKey ?? null;
          ticker.reset();
        }
        if (task.steps.length > 1) {
          who.append(h("span", {
            class: "count",
            text: `${Math.min(task.stepIndex + 1, task.steps.length)}/${task.steps.length}`,
          }));
        }
        ticker.sync(task);
      } else if (task) {
        const info = State.integrations[task.id];
        const key = [
          task.id, detailOpen, task.state, task.steps.join("|"),
          info?.loaded, info?.error, info?.configured,
          JSON.stringify(info?.data ?? {}),
        ].join("~");
        if (key !== cardKey) {
          cardKey = key;
          mode = "card";
          clear(leftBody);
          leftBody.append(task.id === "integration_lan"
            ? lanCard(() => actions.openSettingsWindow(), (id, name, m) => actions.lanCompose(id, name, m))
            : renderIntegrationCard(task, hooks));
        }
      }

      jump.style.display = detailOpen ? "none" : "";

      const others = State.otherTasks.slice(0, 4);
      const pillKey = others.map((t) => `${t.id}:${t.pillBadge ?? ""}`).join("|");
      if (pillKey !== pillIds) {
        pillIds = pillKey;
        clear(pills);
        for (const t of others) pills.append(buildPill(t, actions));
        pruneMiniBots();
      }
    },
  };
}

function buildPill(task: AgentTask, actions: ViewActions): HTMLElement {
  const label = task.id === "integration_claude" ? "VS Code" : task.name;
  const canvas = createMiniBot(task, 24);
  const pill = h(
    "div",
    { class: "pill", onclick: () => actions.setFocus(task.id) },
    canvas,
    h("span", { class: "lbl", text: label }),
  );
  pill.style.borderColor = `${task.color}24`;
  pill.addEventListener("mouseenter", () => {
    pill.style.background = `${task.color}2e`;
    pill.style.borderColor = `${task.color}8c`;
    pill.style.boxShadow = `0 2px 10px ${task.color}59`;
    (pill.querySelector(".lbl") as HTMLElement).style.color = lighten(task.color, 0.3);
  });
  pill.addEventListener("mouseleave", () => {
    pill.style.background = "";
    pill.style.borderColor = `${task.color}24`;
    pill.style.boxShadow = "";
    (pill.querySelector(".lbl") as HTMLElement).style.color = "";
  });

  if (task.pillBadge) {
    const colors = { approval: "#F5A524", finished: "#22C55E", error: "#F4505E" } as const;
    const icons = { approval: ICONS.bang, finished: ICONS.check, error: ICONS.xmark } as const;
    const inner = h("i", { style: `background:${colors[task.pillBadge]}` }, svg(icons[task.pillBadge], 6, { stroke: task.pillBadge === "finished" ? 3 : 0 }));
    const badge = h("div", { class: "pill-badge" }, inner);
    badge.style.boxShadow = `0 0 4px ${colors[task.pillBadge]}99`;
    pill.append(badge);
  }
  return pill;
}

function lighten(hex: string, amount: number): string {
  const v = parseInt(hex.replace("#", ""), 16);
  const c = [(v >> 16) & 255, (v >> 8) & 255, v & 255].map((x) =>
    Math.min(255, Math.round(x + amount * 255)),
  );
  return `rgb(${c[0]},${c[1]},${c[2]})`;
}

// ── Empty ─────────────────────────────────────────────────────────────────────

function buildEmpty(actions: ViewActions): ViewHost {
  const body = h(
    "div",
    { class: "stack", style: "padding:0 18px 0 118px;flex-direction:row;align-items:center;gap:16px" },
    h(
      "div",
      { style: "display:flex;flex-direction:column;gap:5px" },
      h("div", { class: "title", text: t("Nothing running right now.") }),
      h("div", { class: "sub", text: t("Drop a file or window, or ask me anything.") }),
    ),
    h("div", { class: "grow" }),
    btn(t("Ask Claude"), "primary", () => actions.setView("prompt")),
  );
  return { el: h("div", { class: "view" }, card(null, body)), sync() {} };
}

// ── Approval ──────────────────────────────────────────────────────────────────

/**
 * The card springs open under wherever the pointer happens to be. A click that
 * was already on its way — aimed at a tab or a window behind — must not land on
 * Allow, so Allow only counts once the card has been up this long (the same
 * idea as a browser's permission-prompt delay). Deny is never delayed.
 */
const ALLOW_ARM_MS = 700;

function buildApproval(actions: ViewActions): ViewHost {
  const who = h("div");
  // `review`: wraps instead of clipping with an ellipsis, up to the two lines
  // the 108 px card has room for. Whatever does not fit is never approved from
  // here (see `fits` below), because a scroll box would hide the end of the
  // command — exactly where `; curl … | sh` goes.
  const code = h("div", { class: "code review" });
  const row = h("div", { class: "actions" });
  const el = h("div", { class: "view" }, card("amber", stack(116, 16, who, code, row)));
  let shownId: string | null = null;
  let armedAt = 0;
  let fits = false;

  // Built once. Rebuilding them between a mouse-down and a mouse-up would
  // swallow the click; only which one shows changes, and only per request.
  // "Always" is gone until the remembered-rules list exists to back it.
  const allow = btn(t("Allow"), "primary", () => {
    refit();
    if (!fits || performance.now() < armedAt) return;
    actions.decide("allow");
  }, "Y");
  const review = btn(t("Review in terminal"), "primary", () => actions.decide("terminal"));
  row.append(btn(t("Deny"), "secondary", () => actions.decide("deny"), "N"), allow, review);

  /** Does the whole text fit the two-line box at the card's current width? */
  function refit() {
    fits = code.scrollHeight <= code.clientHeight + 1;
    allow.style.display = fits ? "" : "none";
    review.style.display = fits ? "none" : "";
  }
  // The card grows with the island's expand animation, so the answer changes
  // while it opens; re-measure whenever the box itself changes size.
  new ResizeObserver(refit).observe(code);

  return {
    el,
    sync() {
      clear(who);
      // The card names the session that is asking, whatever the pill shows.
      const asking = State.pendingApproval;
      const askingTask = asking ? State.tasks.find((t) => t.id === taskIdFor(agentOf(asking.agent))) ?? null : null;
      who.append(agentWho(askingTask ? { ...askingTask, name: asking!.project } : State.focusTask, t("needs permission")));
      const req = State.pendingApproval;
      // The whole point of approving here rather than in the terminal: this box
      // is the command, the file path or the URL being authorised, in full,
      // not just the name of the tool asking.
      code.textContent = req?.command || req?.tool || "…";
      code.title = code.textContent;
      if ((req?.requestId ?? null) !== shownId) {
        shownId = req?.requestId ?? null;
        armedAt = performance.now() + ALLOW_ARM_MS;
      }
      // The view is laid out (it fades with opacity, never display:none), so
      // this is the real wrapped height against the two-line box.
      refit();
    },
  };
}

// ── Question ──────────────────────────────────────────────────────────────────

function buildQuestion(): ViewHost {
  const who = h("div");
  const title = h("div", { class: "title" });
  const row = h("div", { class: "actions" });
  const el = h("div", { class: "view" }, card("cyan", stack(116, 16, who, title, row)));
  return {
    el,
    sync() {
      clear(who);
      who.append(agentWho(State.focusTask, t("Claude Code is asking a question")));
      const task = State.focusTask;
      title.textContent = task?.steps.at(-1) ?? t("Claude needs an answer.");
      clear(row);
      row.append(h("div", { class: "sub", text: t("Answer in your terminal — Coucou can't reply for you yet.") }));
    },
  };
}

// ── Error ─────────────────────────────────────────────────────────────────────

function buildError(actions: ViewActions): ViewHost {
  const who = h("div");
  const title = h("div", { class: "title", text: t("Workflow stopped.") });
  const detail = h("div", { class: "detail" });
  const row = h("div", { class: "actions" },
    btn(t("Retry"), "primary", () => actions.setView(State.defaultView())),
    btn(t("Open in n8n"), "secondary", () => actions.openUrl("")),
  );
  const el = h("div", { class: "view" }, card("red", stack(116, 16, who, title, detail, row)));
  return {
    el,
    sync() {
      const task = State.focusTask;
      clear(who);
      who.append(agentWho(task, task?.source === "n8n" ? "n8n" : "Claude Code"));
      title.textContent = t(task?.source === "n8n" ? "Workflow stopped." : "Session stopped on an error.");
      detail.textContent = task?.steps.at(-1) ?? t("No detail available.");
    },
  };
}

// ── Finished ──────────────────────────────────────────────────────────────────

function buildFinished(actions: ViewActions): ViewHost {
  const who = h("div");
  const title = h("div", { class: "title clamp2" });
  const row = h("div", { class: "actions" },
    btn(t("Open terminal"), "primary", () => actions.openTerminal()),
    btn("OK", "secondary", () => actions.collapse()),
  );
  const el = h("div", { class: "view" }, card("green", stack(116, 16, who, title, row)));
  return {
    el,
    sync() {
      clear(who);
      who.append(agentWho(State.focusTask, t("Claude Code finished")));
      // What Claude said last beats the last tool step: it says what was done.
      title.textContent = State.focusTask?.summary || State.focusTask?.steps.at(-1) || t("Session finished");
      title.title = title.textContent;
    },
  };
}

// ── Confused ──────────────────────────────────────────────────────────────────

function buildConfused(): ViewHost {
  const body = h(
    "div",
    { class: "stack", style: "padding:0 18px 0 128px" },
    h("div", { class: "title", text: t("Too many hits at once.") }),
    h("div", { class: "sub", text: t("Give me a sec — back to work in three seconds.") }),
  );
  return { el: h("div", { class: "view" }, card("pink", body)), sync() {} };
}

// ── Note ──────────────────────────────────────────────────────────────────────

function buildNote(): ViewHost {
  const title = h("div", { class: "title" });
  const el = h("div", { class: "view" }, card(null, h("div", { class: "stack", style: "padding:0 18px 0 98px" }, title)));
  return {
    el,
    sync() {
      title.textContent = State.noteMessage ?? "";
    },
  };
}

// ── In-island settings ────────────────────────────────────────────────────────

function buildSettings(actions: ViewActions): ViewHost {
  const soundSwitch = h("button", { class: "switch", onclick: () => actions.toggleSound() });
  const volume = h("input", {
    type: "range", min: "0", max: "0.2", step: "0.005",
    oninput: (e: Event) => actions.setVolume(Number((e.target as HTMLInputElement).value)),
  }) as HTMLInputElement;
  const autoLabel = h("span", {});
  const segButtons = [10, 15, 30].map((s) =>
    h("button", { onclick: () => actions.setAutoClose(s) }, `${s}s`),
  );
  const claudeBadge = h("span", { class: "status-badge" });
  const apiBadge = h("span", { class: "status-badge" });

  const rows = h(
    "div",
    { class: "settings-rows" },
    h("div", { class: "settings-row" }, soundSwitch, h("span", { text: t("Sound") }), volume),
    h(
      "div",
      { class: "settings-row" },
      svg(ICONS.timer, 12),
      autoLabel,
      h("div", { class: "seg" }, ...segButtons),
    ),
    h(
      "div",
      { class: "settings-row", style: "gap:14px" },
      claudeBadge,
      apiBadge,
      h("div", { class: "grow" }),
      h("button", {
        class: "link-btn",
        style: "color:#8e939c;font-size:11.5px",
        text: t("Settings…"),
        onclick: () => actions.openSettingsWindow(),
      }),
    ),
  );

  const el = h("div", { class: "view" },
    card(null, h("div", { class: "stack", style: "padding:14px 16px 14px 84px" }, rows)));

  return {
    el,
    sync() {
      const s = State.settings;
      soundSwitch.classList.toggle("on", s.soundEnabled);
      volume.value = String(s.soundVolume);
      volume.style.opacity = s.soundEnabled ? "1" : "0.4";
      autoLabel.textContent = `Auto-close · ${Math.round(s.autoCloseInterval)}s`;
      segButtons.forEach((b, i) => b.classList.toggle("on", s.autoCloseInterval === [10, 15, 30][i]));
      clear(claudeBadge);
      claudeBadge.append(
        dot(s.hooksInstalled ? "#22C55E" : "#F4505E", 6),
        h("span", { text: "Claude Code" }),
      );
      clear(apiBadge);
      apiBadge.append(dot("#F4505E", 6), h("span", { text: t("API") }));
    },
  };
}

// ── Placeholders filled in later stages ───────────────────────────────────────

function buildPlaceholder(title: string, sub: string): ViewHost {
  const body = h(
    "div",
    { class: "stack", style: "padding:0 18px 0 118px" },
    h("div", { class: "title", text: title }),
    h("div", { class: "sub", text: sub }),
  );
  return { el: h("div", { class: "view" }, card(null, body)), sync() {} };
}

// ── Registry ──────────────────────────────────────────────────────────────────

export function buildViews(
  actions: ViewActions,
  onChatHeightChange: () => void,
): Map<IslandViewName, ViewHost> {
  const map = new Map<IslandViewName, ViewHost>();
  map.set("overview", buildOverview(actions));
  map.set("empty", buildEmpty(actions));
  map.set("approval", buildApproval(actions));
  map.set("question", buildQuestion());
  map.set("error", buildError(actions));
  map.set("finished", buildFinished(actions));
  map.set("confused", buildConfused());
  map.set("note", buildNote());
  map.set("lan", buildLan(actions));
  map.set("settings", buildSettings(actions));
  map.set("prompt", buildPrompt(onChatHeightChange));
  map.set("upload", buildUpload());
  map.set("uploading", buildUploading());
  map.set("choose", buildChoose(actions));
  // Not in the Windows v1: sending a file by email, window attach + web result.
  map.set("mail", buildPlaceholder("Sending by email isn't in this version.", ""));
  map.set("searching", buildPlaceholder("Claude is searching…", ""));
  map.set("result", buildPlaceholder("Result", ""));
  return map;
}
