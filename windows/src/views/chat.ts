// Chat view — DOM port of PromptView / ChatBubble / TypingDotsView from
// IslandViewContent.swift.

import { t } from "../core/i18n";
import { h, svg, clear } from "./dom";
import { ICONS } from "./icons";
import { Bridge, type ChatChoices, type ChatContext, type ChatTuning } from "../core/bridge";
import { Sound } from "../core/sound";
import { State, type ChatMessage } from "../core/state";
import type { ViewHost } from "./views";

let nextId = 1;

function bubble(message: ChatMessage): HTMLElement {
  if (message.role === "user") {
    return h(
      "div",
      { class: "chat-row user" },
      h("div", { class: "bubble", text: message.content }),
    );
  }
  return h("div", { class: "chat-row" }, h("div", { class: "reply", text: message.content }));
}

function typingDots(): HTMLElement {
  return h(
    "div",
    { class: "chat-row" },
    h("div", { class: "typing" }, h("i"), h("i"), h("i")),
  );
}

/** The coloured chip showing what the question is about (a dropped file). */
function contextChip(label: string, onRemove?: () => void): HTMLElement {
  const chip = h("div", { class: "chip" }, h("i", { class: "chip-dot" }), h("span", { text: label }));
  if (onRemove) {
    chip.append(h("button", { class: "chip-x", title: t("Remove"), onclick: onRemove }, svg(ICONS.close, 10)));
  }
  requestAnimationFrame(() => chip.classList.add("settled"));
  return chip;
}

/** One-click questions about a dropped file: [label, prompt]. */
const FILE_ACTIONS: [string, string][] = [
  [t("Summarize"), t("Summarize this file in a few short paragraphs.")],
  [t("Explain"), t("Explain what this file is and what it does, simply.")],
  [t("Key points"), t("List the key points of this file, one per line.")],
];
/** The same, for a window Mochi was dropped on. */
const WINDOW_ACTIONS: [string, string][] = [
  [t("Summarize"), t("Summarize what this window shows.")],
  [t("Explain"), t("Explain what is on this screen, simply.")],
  [t("What next?"), t("Looking at this, what should I do next?")],
];
const CODE_ACTION: [string, string] = [t("Review code"), t("Review this code: point out bugs, risks and clear improvements, most important first.")];
const CODE_EXT = /\.(rs|ts|tsx|js|jsx|py|swift|go|java|kt|c|cc|cpp|h|cs|rb|php|sh|ps1|sql)$/i;

/** Longest clipboard text attached to one question (Rust caps it again). */
const MAX_CLIP = 20_000;

// ── The chat's own model and effort ───────────────────────────────────────────
// Picked here, not in Settings: a lighter model or less thinking for a quick
// answer. Remembered per engine on this PC; Rust checks both before use.

const TUNING_KEY = "coucou.chat-tuning";
const EFFORT_LABELS: Record<string, string> = {
  low: "Low", medium: "Medium", high: "High", xhigh: "Extra high", max: "Max",
};

function loadTunings(): Record<string, ChatTuning> {
  try {
    const v = JSON.parse(localStorage.getItem(TUNING_KEY) ?? "{}");
    return v && typeof v === "object" ? v : {};
  } catch {
    return {};
  }
}

function saveTuning(engine: string, tuning: ChatTuning) {
  try {
    const all = loadTunings();
    if (!tuning.model && !tuning.effort) delete all[engine];
    else all[engine] = tuning;
    localStorage.setItem(TUNING_KEY, JSON.stringify(all));
  } catch {
    /* storage blocked: the choice lasts for this page only */
  }
}

export function buildPrompt(onHeightChange: () => void): ViewHost {
  const chipRow = h("div", { class: "chip-row" });
  const log = h("div", { class: "chat-log" });
  const input = h("input", {
    type: "text",
    class: "chat-input",
    placeholder: t("Ask me anything…"),
    spellcheck: "false",
  }) as HTMLInputElement;
  const send = h("button", { class: "send-btn", title: t("Send") }, svg(ICONS.arrowUp, 11));
  // Attaches what is on the clipboard — read only on this click, shown as a
  // chip that can be removed before sending.
  const clipBtn = h("button", { class: "clip-btn", title: t("Ask about the clipboard") }, svg(ICONS.clipboard, 14));
  const tuneLabel = h("span", { text: t("Default") });
  const tuneBtn = h("button", { class: "tune-btn", title: t("Model and effort for this chat") }, svg(ICONS.sliders, 11), tuneLabel);
  const bar = h("div", { class: "chat-bar" }, clipBtn, tuneBtn, input, send);
  const suggestRow = h("div", { class: "suggest-row" });
  const tuneRow = h("div", { class: "tune-row" });

  const el = h(
    "div",
    { class: "view" },
    h("div", { class: "card wash chat-card" }, h("div", { class: "chat-body" }, chipRow, suggestRow, log, tuneRow, bar)),
  );

  // Which engine answers, what its menus offer, and what this chat picked.
  let engine = "";
  let choices: ChatChoices | null = null;
  let tuning: ChatTuning = { model: null, effort: null };

  function labelFor(model: string | null): string {
    if (!model) return t("Default");
    const known = choices?.models.find((m) => m.id === model)?.label ?? model;
    return known.length > 16 ? `${known.slice(0, 15)}…` : known;
  }

  function showTuning() {
    const effort = tuning.effort ? t(EFFORT_LABELS[tuning.effort] ?? tuning.effort) : "";
    tuneLabel.textContent = effort ? `${labelFor(tuning.model)} · ${effort}` : labelFor(tuning.model);
    tuneBtn.classList.toggle("on", !!(tuning.model || tuning.effort));
  }

  async function refreshEngine() {
    const now = (await Bridge.chatEngineActive()) ?? "";
    if (now !== engine) {
      engine = now;
      choices = null;
      tuneRow.classList.remove("open");
    }
    tuning = loadTunings()[engine] ?? { model: null, effort: null };
    showTuning();
  }

  function renderTuneRow() {
    clear(tuneRow);
    if (!choices) {
      tuneRow.append(h("span", { class: "tune-hint", text: "…" }));
      return;
    }
    const c = choices;
    const modelSel = h("select", { class: "tune-select" }) as HTMLSelectElement;
    const def = c.defaultLabel ? `${t("Default")} (${c.defaultLabel})` : t("Default");
    modelSel.append(h("option", { value: "", text: def }));
    for (const m of c.models) modelSel.append(h("option", { value: m.id, text: m.label }));
    modelSel.append(h("option", { value: "__other", text: t("Other…") }));
    const other = h("input", { type: "text", class: "tune-other", placeholder: t("model name"), spellcheck: "false" }) as HTMLInputElement;
    const custom = !!tuning.model && !c.models.some((m) => m.id === tuning.model);
    modelSel.value = custom ? "__other" : (tuning.model ?? "");
    other.value = custom ? (tuning.model ?? "") : "";
    other.style.display = custom ? "" : "none";

    const commit = () => {
      saveTuning(engine, tuning);
      showTuning();
    };
    modelSel.addEventListener("change", () => {
      if (modelSel.value === "__other") {
        other.style.display = "";
        other.focus();
        return;
      }
      other.style.display = "none";
      tuning = { ...tuning, model: modelSel.value || null };
      commit();
    });
    other.addEventListener("change", () => {
      const v = other.value.trim();
      tuning = { ...tuning, model: v || null };
      commit();
    });
    other.addEventListener("keydown", (e) => e.stopPropagation());

    tuneRow.append(h("span", { class: "tune-hint", text: t("Model") }), modelSel, other);
    if (c.efforts.length) {
      const effortSel = h("select", { class: "tune-select" }) as HTMLSelectElement;
      effortSel.append(h("option", { value: "", text: t("Default") }));
      for (const e of c.efforts) effortSel.append(h("option", { value: e, text: t(EFFORT_LABELS[e] ?? e) }));
      effortSel.value = tuning.effort && c.efforts.includes(tuning.effort) ? tuning.effort : "";
      effortSel.addEventListener("change", () => {
        tuning = { ...tuning, effort: effortSel.value || null };
        commit();
      });
      tuneRow.append(h("span", { class: "tune-hint", text: t("Effort") }), effortSel);
    }
  }

  tuneBtn.addEventListener("click", async () => {
    const open = !tuneRow.classList.contains("open");
    tuneRow.classList.toggle("open", open);
    tuneBtn.classList.toggle("active", open);
    onHeightChange();
    if (!open) return;
    await refreshEngine();
    tuneRow.classList.add("open");
    renderTuneRow();
    if (!choices) {
      choices = (await Bridge.chatChoices()) ?? { engine, defaultLabel: "", models: [], efforts: [] };
      renderTuneRow();
      showTuning();
    }
  });
  (el.querySelector(".card") as HTMLElement).style.setProperty("--wash", "rgba(99,102,241,0.5)");

  let sending = false;
  let renderedCount = -1;
  let clip: string | null = null;

  clipBtn.addEventListener("click", async () => {
    if (clip) {
      clip = null;
    } else {
      const text = (await Bridge.clipboardText()) ?? null;
      clip = text ? text.slice(0, MAX_CLIP) : null;
      if (!clip) input.placeholder = t("Nothing to attach — copy some text first");
    }
    chipRow.dataset.label = "";
    State.notify();
    input.focus();
  });

  async function submit() {
    const query = input.value.trim();
    if (!query || sending) return;
    input.value = "";
    sending = true;
    Sound.play("send");

    State.chatHistory.push({ id: nextId++, role: "user", content: query });
    State.stateOverride = "thinking";
    State.notify();
    onHeightChange();

    const first = State.chatHistory.length === 1;
    const file = State.droppedFile;
    let context: ChatContext | null = first && file ? { kind: "file", name: file.name, path: file.path, note: file.note } : null;
    // Context rides on the first turn only, so later clipboard text goes in the
    // question itself — the bubble still shows just what was typed.
    let sendQuery = query;
    if (clip && !context && first) context = { kind: "clipboard", text: clip };
    else if (clip) sendQuery = `${query}\n\nThe user copied this text and is asking about it:\n<clipboard>\n${clip}\n</clipboard>`;
    clip = null;
    chipRow.dataset.label = "";

    try {
      const peer = State.peerChat;
      if (peer) {
        // To a paired Mochi: a message for its user, or a question for it.
        if (peer.mode === "message") {
          await Bridge.lanMessage(peer.id, query);
          State.chatHistory.push({ id: nextId++, role: "assistant", content: t("Sent to {name} ✓", { name: peer.name }) });
        } else {
          const answer = await Bridge.lanAsk(peer.id, query);
          State.chatHistory.push({ id: nextId++, role: "assistant", content: answer });
        }
        State.stateOverride = null;
        Sound.play("finish");
        return;
      }
      if (!engine) await refreshEngine();
      const picked = tuning.model || tuning.effort ? tuning : null;
      const reply = await Bridge.chatSend(sendQuery, context, picked);
      State.chatHistory.push({ id: nextId++, role: "assistant", content: reply.text });
      State.stateOverride = null;
      Sound.play("finish");
    } catch (err) {
      State.stateOverride = null;
      State.noteMessage = String(err).replace(/^Error:\s*/, "");
      State.view = "note";
      Sound.play("error");
    } finally {
      sending = false;
      State.notify();
      onHeightChange();
      input.focus();
    }
  }

  send.addEventListener("click", () => void submit());
  input.addEventListener("keydown", (e) => {
    if ((e as KeyboardEvent).key === "Enter") {
      e.preventDefault();
      void submit();
    }
    e.stopPropagation(); // Escape closes the island, not the chat
  });

  return {
    el,
    sync() {
      const file = State.droppedFile;
      const clipLabel = clip ? t("Clipboard · {n} chars", { n: clip.length.toLocaleString() }) : "";
      const fileLabel = file?.label ?? file?.name ?? "";
      const peer = State.peerChat;
      const peerLabel = peer
        ? peer.mode === "message" ? t("Message to {name}", { name: peer.name }) : t("Ask {name}'s Mochi", { name: peer.name })
        : "";
      const wantChip = `${fileLabel}|${clipLabel}|${peerLabel}`;
      if (chipRow.dataset.label !== wantChip) {
        chipRow.dataset.label = wantChip;
        clear(chipRow);
        if (fileLabel) chipRow.append(contextChip(fileLabel));
        if (peer) {
          const chip = contextChip(peerLabel, () => {
            State.peerChat = null;
            State.chatHistory = [];
            chipRow.dataset.label = "";
            State.notify();
          });
          // A click on the chip switches between a message and a question.
          chip.title = t("Click to switch between a message and a question");
          chip.addEventListener("click", (e) => {
            if ((e.target as HTMLElement).closest(".chip-x")) return;
            peer.mode = peer.mode === "message" ? "ask" : "message";
            chipRow.dataset.label = "";
            State.notify();
          });
          chipRow.append(chip);
        }
        if (clipLabel) {
          chipRow.append(contextChip(clipLabel, () => {
            clip = null;
            chipRow.dataset.label = "";
            State.notify();
          }));
        }
      }
      clipBtn.classList.toggle("on", !!clip);
      // Toward a peer, Settings' engine isn't involved: no model to pick.
      tuneBtn.style.display = State.peerChat ? "none" : "";
      clipBtn.style.display = State.peerChat ? "none" : "";

      // Quick actions only while a dropped file waits for its first question.
      const wantSuggest = file && State.chatHistory.length === 0 && !sending ? file.name : "";
      if (suggestRow.dataset.file !== wantSuggest) {
        suggestRow.dataset.file = wantSuggest;
        clear(suggestRow);
        if (wantSuggest) {
          const actions = file?.note ? WINDOW_ACTIONS : CODE_EXT.test(wantSuggest) ? [...FILE_ACTIONS, CODE_ACTION] : FILE_ACTIONS;
          for (const [label, prompt] of actions) {
            suggestRow.append(h("button", {
              class: "suggest",
              onclick: () => {
                input.value = prompt;
                void submit();
              },
            }, label));
          }
        }
      }

      const thinking = State.stateOverride === "thinking";
      const count = State.chatHistory.length + (thinking ? 0.5 : 0);
      if (count !== renderedCount) {
        renderedCount = count;
        clear(log);
        for (const m of State.chatHistory) log.append(bubble(m));
        if (thinking) log.append(typingDots());
        log.scrollTop = log.scrollHeight;
      }

      input.placeholder = State.peerChat
        ? State.peerChat.mode === "message"
          ? t("Write to {name}…", { name: State.peerChat.name })
          : t("Ask {name}'s Mochi…", { name: State.peerChat.name })
        : t(State.chatHistory.length === 0 ? "Ask me anything…" : "Continue…");
      input.disabled = sending;
    },
    focus() {
      void refreshEngine();
      input.focus();
      input.select();
    },
  };
}
