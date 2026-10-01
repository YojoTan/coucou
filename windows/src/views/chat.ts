// Chat view — DOM port of PromptView / ChatBubble / TypingDotsView from
// IslandViewContent.swift.

import { t } from "../core/i18n";
import { h, svg, clear } from "./dom";
import { ICONS } from "./icons";
import { Bridge, type ChatContext } from "../core/bridge";
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
  const bar = h("div", { class: "chat-bar" }, clipBtn, input, send);
  const suggestRow = h("div", { class: "suggest-row" });

  const el = h(
    "div",
    { class: "view" },
    h("div", { class: "card wash chat-card" }, h("div", { class: "chat-body" }, chipRow, suggestRow, log, bar)),
  );
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
      const reply = await Bridge.chatSend(sendQuery, context);
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
      const wantChip = `${fileLabel}|${clipLabel}`;
      if (chipRow.dataset.label !== wantChip) {
        chipRow.dataset.label = wantChip;
        clear(chipRow);
        if (fileLabel) chipRow.append(contextChip(fileLabel));
        if (clipLabel) {
          chipRow.append(contextChip(clipLabel, () => {
            clip = null;
            chipRow.dataset.label = "";
            State.notify();
          }));
        }
      }
      clipBtn.classList.toggle("on", !!clip);

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

      input.placeholder = t(State.chatHistory.length === 0 ? "Ask me anything…" : "Continue…");
      input.disabled = sending;
    },
    focus() {
      input.focus();
      input.select();
    },
  };
}
