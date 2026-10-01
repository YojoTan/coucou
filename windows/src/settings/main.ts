// Settings window — the place where anything that writes to disk is confirmed.
// Stage 2 covers the Claude Code hooks and the general preferences; API keys and
// integrations land here too in a later stage.

import { setLanguage, t } from "../core/i18n";
import "./settings.css";
import { Bridge, onEvent, type EngineInfo, type HookStatus, type HookTarget } from "../core/bridge";
import { DEFAULT_SETTINGS, type Settings } from "../core/state";
import { h, clear } from "../views/dom";

let settings: Settings = { ...DEFAULT_SETTINGS };
let version = "";

const root = document.getElementById("settings-root")!;

async function save() {
  await Bridge.saveSettings(settings);
}

// ── Reusable bits ─────────────────────────────────────────────────────────────

function toggle(on: boolean, onChange: (v: boolean) => void): HTMLElement {
  const el = h("button", { class: on ? "switch on" : "switch", "aria-pressed": on });
  el.addEventListener("click", () => {
    const next = !el.classList.contains("on");
    el.classList.toggle("on", next);
    onChange(next);
  });
  return el;
}

function statusDot(ok: boolean): HTMLElement {
  return h("i", { class: "dot", style: `background:${ok ? "#22c55e" : "#f4505e"}` });
}

function renderDiff(text: string): HTMLElement {
  const box = h("div", { class: "diff" });
  for (const line of text.split("\n")) {
    const cls = line.startsWith("+") ? "add" : line.startsWith("-") ? "del" : "ctx";
    box.append(h("div", { class: cls, text: line }));
  }
  return box;
}

// ── Claude Code section ───────────────────────────────────────────────────────

/** What differs between the Claude Code and Codex hook sections. */
const HOOK_TARGETS: Record<HookTarget, { title: string; file: string; on: string; off: string; done: string }> = {
  claude: {
    title: "Claude Code",
    file: "settings.json",
    on: "Coucou is hooked into your Claude Code sessions. Tool calls, questions and permission requests show up in the island, and you can answer them there.",
    off: "Install the hooks to see your Claude Code sessions in the island and approve permissions without leaving what you are doing.",
    done: "Open a new Claude Code session to pick the hooks up.",
  },
  codex: {
    title: "Codex",
    file: "hooks.json",
    on: "Coucou is hooked into Codex: its sessions get their own pill, and you can approve from the island.",
    off: "Install the hooks to see Codex sessions in the island next to Claude Code. Codex then asks you to trust them once.",
    done: "In Codex, run /hooks once and trust Coucou's hooks — Codex ignores them until you do.",
  },
};

/** opencode: one plugin file, shown before it is written. Experimental. */
function opencodeSection(): HTMLElement {
  const body = h("div", { style: "display:flex;flex-direction:column;gap:10px" });
  const head = h("h2", {});
  const section = h("section", {}, head, body);

  async function draw() {
    clear(body);
    const st = await Bridge.opencodeStatus();
    clear(head);
    head.append(statusDot(!!st?.installed && !st.outdated), h("span", { text: t("opencode (experimental)") }));
    if (!st) return;
    body.append(
      h("div", { class: "hint", text: st.installed
        ? t("Coucou's plugin is in opencode's plugin folder: opencode sessions get their own pill, and you can approve from the island.")
        : t("Adds one file to opencode's plugin folder so its sessions show up in the island. No opencode config is edited.") }),
      h("div", { class: "row" }, h("label", { text: t("Plugin") }), h("span", { class: "path", text: st.path })),
    );
    if (!st.opencodeFound) body.append(h("div", { class: "notice warn", text: t("opencode isn't on this PC's PATH — install it first, or install the plugin anyway.") }));
    if (st.foreign) {
      body.append(h("div", { class: "notice err", text: t("A coucou.js that Coucou didn't write is already there — it is left alone.") }));
      return;
    }
    const preview = h("pre", { class: "diff", style: "display:none;max-height:220px;overflow:auto" });
    const show = h("button", { text: t("Show the plugin"), onclick: async () => {
      if (!preview.textContent) preview.textContent = (await Bridge.opencodePluginText()) ?? "";
      preview.style.display = preview.style.display === "none" ? "" : "none";
    } });
    const install = h("button", { class: "primary", text: t(st.installed ? (st.outdated ? "Update plugin" : "Reinstall plugin") : "Install plugin") });
    const remove = h("button", { class: "danger", text: t("Remove plugin") });
    const note = h("div", {});
    install.addEventListener("click", async () => {
      try { note.className = "notice ok"; note.textContent = await Bridge.opencodeApply(true); }
      catch (err) { note.className = "notice err"; note.textContent = String(err).replace(/^Error:\s*/, ""); }
      window.setTimeout(() => void draw(), 2400);
    });
    remove.addEventListener("click", async () => {
      try { note.className = "notice ok"; note.textContent = await Bridge.opencodeApply(false); }
      catch (err) { note.className = "notice err"; note.textContent = String(err).replace(/^Error:\s*/, ""); }
      window.setTimeout(() => void draw(), 2400);
    });
    const row = h("div", { class: "row" }, install, show);
    if (st.installed) row.append(remove);
    body.append(row, preview, note);
  }
  void draw();
  return section;
}

function claudeSection(status: HookStatus): HTMLElement {
  return hooksSection("claude", status);
}

function hooksSection(target: HookTarget, status: HookStatus): HTMLElement {
  const cfg = HOOK_TARGETS[target];
  const body = h("div", { style: "display:flex;flex-direction:column;gap:12px" });
  const section = h(
    "section",
    {},
    h("h2", {}, statusDot(status.installed), h("span", { text: t(cfg.title) })),
    body,
  );

  const rebuild = async () => {
    const fresh = await Bridge.hooksStatus(target);
    if (fresh) Object.assign(status, fresh);
    clear(body);
    draw();
    const head = section.querySelector("h2")!;
    clear(head);
    head.append(statusDot(status.installed), h("span", { text: t(cfg.title) }));
  };

  function draw() {
    body.append(
      h("div", {
        class: "hint",
        text: t(status.installed ? cfg.on : cfg.off),
      }),
      h("div", { class: "row" },
        h("label", { text: cfg.file }),
        h("span", { class: "path", text: status.settingsPath }),
      ),
      h("div", { class: "row" },
        h("label", { text: t("Relay") }),
        h("span", { class: "path", text: status.hookPath }),
        statusDot(status.hookReady),
      ),
    );

    if (!status.hookReady) {
      body.append(h("div", {
        class: "notice warn",
        text: t("coucou-hook.exe is not in place yet. Restart Coucou; if it still fails, build it with `cargo build -p coucou-hook`."),
      }));
    }

    const actions = h("div", { class: "row" });
    const install = h("button", {
      class: "primary",
      text: t(status.installed ? "Reinstall hooks…" : "Install hooks…"),
      onclick: () => showPreview(true),
    });
    // Writing hook commands that point at a relay which isn't there would give
    // every Claude Code session a broken hook and nothing to show for it.
    if (!status.hookReady) {
      install.disabled = true;
      install.title = t("The relay isn't installed yet.");
    }
    actions.append(install);
    if (status.installed) {
      actions.append(h("button", {
        class: "danger",
        text: t("Uninstall hooks…"),
        onclick: () => showPreview(false),
      }));
    }
    body.append(actions);
  }

  async function showPreview(install: boolean) {
    let preview;
    try {
      preview = await Bridge.hooksPreview(install, target);
    } catch (err) {
      // An unreadable or invalid settings.json stops here rather than being
      // treated as empty and written over.
      clear(body);
      body.append(
        h("div", { class: "notice err", text: String(err).replace(/^Error:\s*/, "") }),
        h("div", { class: "row" }, h("button", {
          text: t("Back"),
          onclick: () => { clear(body); draw(); },
        })),
      );
      return;
    }
    if (!preview) return;
    clear(body);
    body.append(
      h("div", {
        class: "hint",
        text: install
          ? t("This is exactly what will change in your {file}. Your own hooks are left untouched.", { file: cfg.file })
          : t("This removes Coucou's entries only. Your own hooks are left untouched."),
      }),
      renderDiff(preview.diff),
      h("div", { class: "row" },
        h("span", { class: "path", text: t("Backup → {path}", { path: preview.backup }) }),
      ),
    );
    const confirm = h("button", {
      class: install ? "primary" : "danger",
      text: t(install ? "Back up and write" : "Back up and remove"),
    });
    confirm.addEventListener("click", async () => {
      confirm.disabled = true;
      try {
        const backup = await Bridge.hooksApply(install, preview.fingerprint, target);
        clear(body);
        body.append(h("div", {
          class: "notice ok",
          text: `${t("Done. Previous file saved as {path}.", { path: backup })} ${install ? t(cfg.done) : ""}`.trim(),
        }));
        window.setTimeout(() => void rebuild(), 2600);
      } catch (err) {
        confirm.disabled = false;
        body.append(h("div", { class: "notice err", text: t("Could not write: {error}", { error: String(err) }) }));
      }
    });
    body.append(h("div", { class: "row" }, confirm, h("button", {
      text: t("Cancel"),
      onclick: () => { clear(body); draw(); },
    })));
  }

  draw();
  return section;
}

// ── Claude API section ────────────────────────────────────────────────────────

const MODELS: [string, string][] = [
  ["claude-opus-5", "Claude Opus 5"],
  ["claude-sonnet-5", "Claude Sonnet 5"],
  ["claude-haiku-4-5", "Claude Haiku 4.5"],
];

// ── Chat engine section ───────────────────────────────────────────────────────

const ENGINE_LABELS: Record<string, string> = {
  api: "Anthropic API",
  claude: "Claude Code",
  codex: "Codex",
  gemini: "Gemini CLI",
  opencode: "opencode",
  openai: "OpenAI-compatible endpoint",
  anthropic: "Anthropic-compatible endpoint",
};

/** Servers that speak Anthropic's Messages API (upstream #26): [label, base URL, example model]. */
const ANTHROPIC_PRESETS: [string, string, string][] = [
  [t("LiteLLM (this PC)"), "http://localhost:4000", "claude-sonnet-5"],
  ["DeepSeek", "https://api.deepseek.com/anthropic", "deepseek-chat"],
  ["Moonshot (Kimi)", "https://api.moonshot.ai/anthropic", "kimi-k2-turbo-preview"],
  ["Z.ai (GLM)", "https://api.z.ai/api/anthropic", "glm-4.6"],
];

/** Base URL, model and optional key for the Anthropic-compatible engine. */
function anthropicPanel(): HTMLElement {
  const preset = h("select", {}) as HTMLSelectElement;
  preset.append(h("option", { value: "", text: t("Preset…") }));
  for (const [label, url] of ANTHROPIC_PRESETS) preset.append(h("option", { value: url, text: label }));
  const base = h("input", { type: "text", placeholder: "https://gateway.example.com", spellcheck: "false", autocomplete: "off", style: "flex:1 1 auto;min-width:0" }) as HTMLInputElement;
  const model = h("input", { type: "text", placeholder: t("model name"), spellcheck: "false", autocomplete: "off", style: "flex:1 1 auto;min-width:0" }) as HTMLInputElement;
  const key = h("input", { type: "password", placeholder: t("optional — local servers need none"), autocomplete: "off", style: "flex:1 1 auto;min-width:0" }) as HTMLInputElement;
  const saveKey = h("button", { text: t("Save key") });
  const note = h("div", { class: "hint" });
  base.value = settings.anthropicBaseUrl;
  model.value = settings.anthropicModel;

  async function refreshKey() {
    const present = (await Bridge.secretPresent("anthropic-compat-key")) ?? false;
    key.placeholder = present ? "••••••••  (stored)" : t("optional — local servers need none");
  }
  preset.addEventListener("change", async () => {
    const p = ANTHROPIC_PRESETS.find(([, url]) => url === preset.value);
    if (!p) return;
    base.value = p[1];
    if (!model.value) model.value = p[2];
    settings.anthropicBaseUrl = base.value;
    settings.anthropicModel = model.value;
    await save();
  });
  for (const [input, field] of [[base, "anthropicBaseUrl"], [model, "anthropicModel"]] as const) {
    input.addEventListener("change", async () => {
      settings[field] = input.value.trim();
      await save();
    });
  }
  saveKey.addEventListener("click", async () => {
    try {
      await Bridge.secretSet("anthropic-compat-key", key.value.trim());
      key.value = "";
      note.textContent = t("Key saved in the Windows Credential Manager.");
    } catch (err) {
      note.textContent = t("Could not save: {error}", { error: String(err) });
    }
    await refreshKey();
  });
  void refreshKey();
  note.textContent = t("Anthropic's Messages API on another server: a gateway like LiteLLM, or a provider that offers it. Its own key — your Anthropic key never goes there. https only, except servers on this PC. No web search.");
  return h("div", { style: "display:flex;flex-direction:column;gap:6px" },
    h("div", { class: "row" }, h("label", { text: t("Server") }), preset),
    h("div", { class: "row" }, h("label", { text: t("Base URL") }), base),
    h("div", { class: "row" }, h("label", { text: t("Model") }), model),
    h("div", { class: "row" }, h("label", { text: t("API key") }), key, saveKey),
    note,
  );
}

/** Common OpenAI-compatible servers: [label, base URL, example model]. */
const OPENAI_PRESETS: [string, string, string][] = [
  [t("Ollama (this PC)"), "http://localhost:11434/v1", "llama3.2"],
  [t("LM Studio (this PC)"), "http://localhost:1234/v1", "qwen2.5-7b-instruct"],
  ["OpenRouter", "https://openrouter.ai/api/v1", "anthropic/claude-sonnet-4.5"],
  ["OpenAI", "https://api.openai.com/v1", "gpt-4o-mini"],
];

/** Base URL, model and optional key for the OpenAI-compatible engine. */
function openaiPanel(): HTMLElement {
  const preset = h("select", {}) as HTMLSelectElement;
  preset.append(h("option", { value: "", text: t("Preset…") }));
  for (const [label, url] of OPENAI_PRESETS) preset.append(h("option", { value: url, text: label }));
  const base = h("input", { type: "text", placeholder: "http://localhost:11434/v1", spellcheck: "false", autocomplete: "off", style: "flex:1 1 auto;min-width:0" }) as HTMLInputElement;
  const model = h("input", { type: "text", placeholder: t("model name"), spellcheck: "false", autocomplete: "off", style: "flex:1 1 auto;min-width:0" }) as HTMLInputElement;
  const key = h("input", { type: "password", placeholder: t("optional — local servers need none"), autocomplete: "off", style: "flex:1 1 auto;min-width:0" }) as HTMLInputElement;
  const saveKey = h("button", { text: t("Save key") });
  const note = h("div", { class: "hint" });
  base.value = settings.openaiBaseUrl;
  model.value = settings.openaiModel;

  async function refreshKey() {
    const present = (await Bridge.secretPresent("openai-api-key")) ?? false;
    key.placeholder = present ? "••••••••  (stored)" : "optional — local servers need none";
  }
  preset.addEventListener("change", async () => {
    const p = OPENAI_PRESETS.find(([, url]) => url === preset.value);
    if (!p) return;
    base.value = p[1];
    if (!model.value) model.value = p[2];
    settings.openaiBaseUrl = base.value;
    settings.openaiModel = model.value;
    await save();
  });
  for (const [input, field] of [[base, "openaiBaseUrl"], [model, "openaiModel"]] as const) {
    input.addEventListener("change", async () => {
      settings[field] = input.value.trim();
      await save();
    });
  }
  saveKey.addEventListener("click", async () => {
    try {
      await Bridge.secretSet("openai-api-key", key.value.trim());
      key.value = "";
      note.textContent = t("Key saved in the Windows Credential Manager.");
    } catch (err) {
      note.textContent = t("Could not save: {error}", { error: String(err) });
    }
    await refreshKey();
  });
  void refreshKey();
  note.textContent = t("https only, except servers on this PC (localhost). Text and images; PDFs need the Anthropic API or a CLI.");
  return h("div", { style: "display:flex;flex-direction:column;gap:6px" },
    h("div", { class: "row" }, h("label", { text: t("Server") }), preset),
    h("div", { class: "row" }, h("label", { text: t("Base URL") }), base),
    h("div", { class: "row" }, h("label", { text: t("Model") }), model),
    h("div", { class: "row" }, h("label", { text: t("API key") }), key, saveKey),
    note,
  );
}

/**
 * Which brain answers the island's chat. A CLI uses the login it already has —
 * a Claude Code subscription needs no API key at all — and runs read-only in
 * Coucou's own folder, so the chat can look things up but never change files.
 */
function chatSection(): HTMLElement {
  const select = h("select", {}) as HTMLSelectElement;
  const active = h("div", { class: "hint" });
  const list = h("div", { style: "display:flex;flex-direction:column;gap:4px;margin:6px 0" });
  const detect = h("button", { text: t("Detect again") });
  const cliModel = h("input", {
    type: "text",
    placeholder: t("CLI default (e.g. sonnet, haiku)"),
    spellcheck: "false",
    autocomplete: "off",
    style: "flex:1 1 auto;min-width:0",
  }) as HTMLInputElement;
  cliModel.value = settings.cliModel;

  let engines: EngineInfo[] = [];
  const openai = openaiPanel();
  const anthropic = anthropicPanel();

  function fillSelect() {
    clear(select);
    select.append(h("option", { value: "auto", text: t("Automatic — API key if saved, else the first CLI found") }));
    for (const e of engines) {
      const state = e.installed ? (e.version ?? t("installed")) : t("not installed");
      const tag = e.experimental ? ` · ${t("experimental")}` : "";
      select.append(h("option", { value: e.id, text: `${e.label} (${state})${tag}`, disabled: !e.installed && settings.chatEngine !== e.id }));
    }
    select.append(h("option", { value: "openai", text: t("OpenAI-compatible (Ollama, LM Studio, OpenRouter…)") }));
    select.append(h("option", { value: "anthropic", text: t("Anthropic-compatible (LiteLLM, DeepSeek, Kimi, GLM…)") }));
    select.append(h("option", { value: "api", text: t("Anthropic API (key below)") }));
    select.value = settings.chatEngine || "auto";
    openai.style.display = select.value === "openai" ? "" : "none";
    anthropic.style.display = select.value === "anthropic" ? "" : "none";
  }

  function fillList() {
    clear(list);
    for (const e of engines) {
      list.append(
        h("div", { class: "row", style: "gap:8px" },
          statusDot(e.installed),
          h("span", { style: "min-width:96px", text: e.label }),
          h("span", { class: "hint", text: e.installed ? `${e.version ?? ""}  ${e.path ?? ""}`.trim() : t("Not installed") }),
        ),
      );
    }
  }

  async function refreshActive() {
    const id = (await Bridge.chatEngineActive()) ?? "";
    active.textContent = id
      ? t("Answering now: {engine}.", { engine: t(ENGINE_LABELS[id] ?? id) })
      : t("Nothing can answer yet: install Claude Code (or another CLI) or save an API key below.");
  }

  async function load() {
    detect.setAttribute("disabled", "");
    list.textContent = t("Looking for installed CLIs…");
    engines = (await Bridge.chatEngines()) ?? [];
    fillSelect();
    fillList();
    detect.removeAttribute("disabled");
    await refreshActive();
  }

  select.addEventListener("change", async () => {
    settings.chatEngine = select.value;
    openai.style.display = select.value === "openai" ? "" : "none";
    anthropic.style.display = select.value === "anthropic" ? "" : "none";
    await save();
    await refreshActive();
  });
  cliModel.addEventListener("change", async () => {
    settings.cliModel = cliModel.value.trim();
    await save();
  });
  detect.addEventListener("click", () => void load());
  void load();

  return h(
    "section",
    {},
    h("h2", {}, h("span", { text: t("Chat") })),
    h("div", {
      class: "hint",
      text: t("Mochi can answer with an AI CLI you already use — Claude Code with your subscription needs no API key. It runs read-only in Coucou's own folder: it can read a dropped file and search the web, never change files or run commands."),
    }),
    h("div", { class: "row" }, h("label", { text: t("Engine") }), select),
    list,
    h("div", { class: "row" }, h("label", { text: t("CLI model") }), cliModel, detect),
    openai,
    anthropic,
    active,
  );
}

function apiSection(hasKey: boolean): HTMLElement {
  const dot = statusDot(hasKey);
  const state = h("span", { class: "hint", text: t(hasKey ? "Key saved in the Windows Credential Manager." : "No key — only needed for the Anthropic API engine.") });

  const field = h("input", {
    type: "password",
    placeholder: hasKey ? "••••••••••••  (stored)" : "sk-ant-...",
    style: "flex:1 1 auto;min-width:0",
    autocomplete: "off",
    spellcheck: "false",
  }) as HTMLInputElement;

  const saveBtn = h("button", { class: "primary", text: t("Save key") });
  const clearBtn = h("button", { class: "danger", text: t("Remove") });
  const feedback = h("div", {});

  async function refresh() {
    const present = (await Bridge.secretPresent("anthropic-api-key")) ?? false;
    dot.style.background = present ? "#22c55e" : "#f4505e";
    state.textContent = present
      ? t("Key saved in the Windows Credential Manager.")
      : t("No key — only needed for the Anthropic API engine.");
    field.placeholder = present ? "••••••••••••  (stored)" : "sk-ant-...";
    clearBtn.style.display = present ? "" : "none";
  }

  saveBtn.addEventListener("click", async () => {
    const value = field.value.trim();
    if (!value) return;
    clear(feedback);
    try {
      await Bridge.secretSet("anthropic-api-key", value);
      field.value = "";
      feedback.append(h("div", { class: "notice ok", text: t("Saved. It never touches disk.") }));
      await refresh();
    } catch (err) {
      feedback.append(h("div", { class: "notice err", text: t("Could not save: {error}", { error: String(err) }) }));
    }
  });

  clearBtn.addEventListener("click", async () => {
    clear(feedback);
    try {
      await Bridge.secretClear("anthropic-api-key");
      feedback.append(h("div", { class: "notice ok", text: t("Key removed.") }));
      await refresh();
    } catch (err) {
      feedback.append(h("div", { class: "notice err", text: t("Could not remove: {error}", { error: String(err) }) }));
    }
  });

  const model = h("select", {}) as HTMLSelectElement;
  for (const [id, label] of MODELS) model.append(h("option", { value: id, text: label }));
  if (!MODELS.some(([id]) => id === settings.model)) {
    model.append(h("option", { value: settings.model, text: settings.model }));
  }
  model.value = settings.model;
  model.addEventListener("change", () => {
    settings.model = model.value;
    void save();
  });

  clearBtn.style.display = hasKey ? "" : "none";

  return h(
    "section",
    {},
    h("h2", {}, dot, h("span", { text: "Anthropic API" })),
    state,
    h("div", { class: "row" }, h("label", { text: t("API key") }), field, saveBtn, clearBtn),
    h("div", { class: "row" }, h("label", { text: t("Model") }), model),
    feedback,
  );
}

// ── Integrations section ──────────────────────────────────────────────────────

interface IntegrationDef {
  id: string;
  name: string;
  color: string;
  /** Credential Manager keys, in the order they are shown. */
  fields: { key: string; label: string; placeholder: string; secret: boolean }[];
}

const INTEGRATIONS: IntegrationDef[] = [
  // No key: Coucou reads the Orca running on this PC through its local pipe.
  { id: "integration_orca", name: "Orca", color: "#8B5CF6", fields: [] },
  // No key either: what Windows' media flyout shows, Spotify first.
  { id: "integration_spotify", name: "Spotify", color: "#1DB954", fields: [] },
  { id: "integration_stripe", name: "Stripe", color: "#0570DE",
    fields: [{ key: "stripe-api-key", label: "Secret key", placeholder: t("sk_live_…"), secret: true }] },
  { id: "integration_github", name: "GitHub", color: "#F4505E",
    fields: [{ key: "github-token", label: "Token", placeholder: t("optional — overrides gh"), secret: true }] },
  { id: "integration_vercel", name: "Vercel", color: "#7C5CFF",
    fields: [{ key: "vercel-token", label: "Token", placeholder: "…", secret: true }] },
  { id: "integration_n8n", name: "n8n", color: "#F29B38",
    fields: [
      { key: "n8n-url", label: t("Instance URL"), placeholder: "https://n8n.example.com", secret: false },
      { key: "n8n-api-key", label: "API key", placeholder: "…", secret: true },
    ] },
  { id: "integration_resend", name: "Resend", color: "#22C55E",
    fields: [{ key: "resend-api-key", label: "API key", placeholder: t("re_…"), secret: true }] },
  { id: "integration_notion", name: "Notion", color: "#8C8C8C",
    fields: [{ key: "notion-api-key", label: "Integration token", placeholder: t("ntn_…"), secret: true }] },
  { id: "integration_calcom", name: "Cal.com", color: "#C9956A",
    fields: [{ key: "calcom-api-key", label: "API key", placeholder: t("cal_…"), secret: true }] },
];

const MAX_ACTIVE = 4;

function integrationsSection(present: Record<string, boolean>): HTMLElement {
  const note = h("div", { class: "hint" });
  const list = h("div", { style: "display:flex;flex-direction:column;gap:14px" });

  function updateNote() {
    const used = settings.activeIntegrations.length;
    note.textContent = t("Pick up to {max} pills to show next to Mochi — {used}/{max} in use. Keys are stored in the Windows Credential Manager, never on disk.", { max: MAX_ACTIVE, used });
  }

  for (const def of INTEGRATIONS) {
    const active = settings.activeIntegrations.includes(def.id);
    const sw = h("button", { class: active ? "switch on" : "switch" });
    sw.addEventListener("click", () => {
      const on = settings.activeIntegrations.includes(def.id);
      if (on) {
        settings.activeIntegrations = settings.activeIntegrations.filter((x) => x !== def.id);
      } else {
        if (settings.activeIntegrations.length >= MAX_ACTIVE) return;
        settings.activeIntegrations = [...settings.activeIntegrations, def.id];
      }
      sw.classList.toggle("on", !on);
      updateNote();
      void save();
    });

    const rows = h("div", { style: "display:flex;flex-direction:column;gap:6px;flex:1 1 auto;min-width:0" });
    for (const field of def.fields) {
      const input = h("input", {
        type: field.secret ? "password" : "text",
        placeholder: present[field.key] ? "••••••••  (stored)" : field.placeholder,
        autocomplete: "off",
        spellcheck: "false",
        style: "flex:1 1 auto;min-width:0",
      }) as HTMLInputElement;
      const saveBtn = h("button", { text: t("Save") });
      const dotEl = statusDot(present[field.key] ?? false);
      saveBtn.addEventListener("click", async () => {
        const value = input.value.trim();
        try {
          await Bridge.secretSet(field.key, value);
          present[field.key] = value.length > 0;
          input.value = "";
          input.placeholder = value ? "••••••••  (stored)" : field.placeholder;
          dotEl.style.background = value ? "#22c55e" : "#f4505e";
        } catch {
          dotEl.style.background = "#f5a524";
        }
      });
      rows.append(
        h("div", { class: "row" },
          h("label", { style: "min-width:104px", text: t(field.label) }),
          input, saveBtn, dotEl,
        ),
      );
    }

    if (def.id === "integration_github") rows.append(githubStatus());

    list.append(
      h("div", { style: "display:flex;gap:12px;align-items:flex-start" },
        h("div", { style: "display:flex;align-items:center;gap:8px;min-width:132px;padding-top:4px" },
          sw,
          h("i", { class: "dot", style: `background:${def.color}` }),
          h("span", { style: "font-size:12.5px", text: def.name }),
        ),
        rows,
      ),
    );
  }

  updateNote();
  return h("section", {}, h("h2", {}, h("span", { text: t("Integrations") })), note, list);
}

/** Which GitHub login the pill uses, or why there isn't one (after upstream PR #15). */
function githubStatus(): HTMLElement {
  const line = h("div", { class: "hint", text: "…" });
  const refresh = async () => {
    const source = await Bridge.githubAuth().catch(() => null);
    line.textContent = source === "gh"
      ? t("Using your gh login.")
      : source === "token"
        ? t("Using the token above.")
        : t("gh not found or not logged in — run gh auth login, or paste a token.");
  };
  void refresh();
  return line;
}

// ── General section ───────────────────────────────────────────────────────────

function generalSection(): HTMLElement {
  const volume = h("input", {
    type: "range", min: "0", max: "0.2", step: "0.005",
    value: String(settings.soundVolume),
  }) as HTMLInputElement;
  volume.addEventListener("input", () => {
    settings.soundVolume = Number(volume.value);
    void save();
  });

  const autoClose = h("input", {
    type: "number", min: "5", max: "120", step: "1",
    value: String(Math.round(settings.autoCloseInterval)),
    style: "width:72px",
  }) as HTMLInputElement;
  autoClose.addEventListener("change", () => {
    settings.autoCloseInterval = Math.max(5, Math.min(120, Number(autoClose.value) || 15));
    autoClose.value = String(settings.autoCloseInterval);
    void save();
  });

  const screen = h("select", {}) as HTMLSelectElement;
  screen.append(
    h("option", { value: "primary", text: t("Main display") }),
    h("option", { value: "cursor", text: t("Display under the cursor") }),
  );
  screen.value = settings.screen;
  screen.addEventListener("change", () => {
    settings.screen = screen.value as Settings["screen"];
    void save();
  });

  // Global shortcut to the chat. Applied by Rust, which reports a combination
  // another program already owns instead of failing silently.
  const shortcut = h("select", {}) as HTMLSelectElement;
  const shortcutNote = h("span", { class: "hint" });
  void Bridge.hotkeyChoices().then((choices) => {
    for (const [id, label] of choices ?? []) shortcut.append(h("option", { value: id, text: label }));
    shortcut.value = settings.hotkey || "ctrl+alt+space";
  });
  shortcut.addEventListener("change", async () => {
    try {
      await Bridge.hotkeySet(shortcut.value);
      settings.hotkey = shortcut.value;
      shortcutNote.textContent = shortcut.value === "off" ? "" : t("opens Mochi's chat from anywhere");
    } catch (err) {
      settings.hotkey = "off";
      shortcut.value = "off";
      shortcutNote.textContent = String(err).replace(/^Error:\s*/, "");
    }
  });
  shortcutNote.textContent = settings.hotkey === "off" ? "" : t("opens Mochi's chat from anywhere");

  const language = h("select", {}) as HTMLSelectElement;
  language.append(
    h("option", { value: "auto", text: t("Same as Windows") }),
    h("option", { value: "en", text: "English" }),
    h("option", { value: "es", text: "Español" }),
    h("option", { value: "pt-BR", text: "Português (Brasil)" }),
  );
  language.value = settings.language || "auto";
  language.addEventListener("change", async () => {
    settings.language = language.value;
    await save();
    if (setLanguage(settings.language)) location.reload();
  });

  return h(
    "section",
    {},
    h("h2", {}, h("span", { text: t("General") })),
    h("div", { class: "row" },
      h("label", { text: t("Language") }),
      language,
    ),
    h("div", { class: "row" },
      h("label", { text: t("Chat shortcut") }),
      shortcut,
      shortcutNote,
    ),
    h("div", { class: "row" },
      h("label", { text: t("Sound") }),
      toggle(settings.soundEnabled, (v) => { settings.soundEnabled = v; void save(); }),
      volume,
    ),
    h("div", { class: "row" },
      h("label", { text: t("Auto-close") }),
      autoClose,
      h("span", { class: "hint", text: t("seconds after you leave the island") }),
    ),
    h("div", { class: "row" },
      h("label", { text: t("Island lives on") }),
      screen,
    ),
    h("div", { class: "row" },
      h("label", { text: t("Launch at startup") }),
      toggle(settings.autostart, (v) => { settings.autostart = v; void save(); }),
    ),
  );
}

// ── Boot ──────────────────────────────────────────────────────────────────────

async function main() {
  const boot = await Bridge.boot();
  if (boot) {
    settings = { ...settings, ...boot.settings };
    version = boot.version;
    if (setLanguage(settings.language)) {
      location.reload();
      return;
    }
  }
  const status = (await Bridge.hooksStatus()) ?? {
    installed: false, settingsPath: "", hookPath: "", hookReady: false,
  };
  const codexStatus = (await Bridge.hooksStatus("codex")) ?? {
    installed: false, settingsPath: "", hookPath: "", hookReady: false,
  };

  const hasKey = (await Bridge.secretPresent("anthropic-api-key")) ?? false;

  const keys = [
    "stripe-api-key", "github-token", "vercel-token",
    "n8n-url", "n8n-api-key", "resend-api-key", "notion-api-key", "calcom-api-key",
  ];
  const present: Record<string, boolean> = {};
  for (const k of keys) present[k] = (await Bridge.secretPresent(k)) ?? false;

  clear(root);
  // Tabs, as in upstream PR #33: the window had grown into one long scroll.
  const tabs: [string, string, HTMLElement[]][] = [
    ["general", t("General"), [generalSection()]],
    ["chat", t("Chat"), [chatSection(), apiSection(hasKey)]],
    ["agents", t("Agents"), [claudeSection(status), hooksSection("codex", codexStatus), opencodeSection()]],
    ["integrations", t("Integrations"), [integrationsSection(present)]],
  ];
  const bar = h("div", { class: "tabs", role: "tablist" });
  const panes = h("div", { class: "tab-panes" });
  let current = "general";
  try {
    current = localStorage.getItem("coucou.settings-tab") ?? "general";
  } catch { /* no storage: start on General */ }
  if (!tabs.some(([id]) => id === current)) current = "general";
  const show = (id: string) => {
    current = id;
    try { localStorage.setItem("coucou.settings-tab", id); } catch { /* fine */ }
    for (const b of bar.children) (b as HTMLElement).classList.toggle("on", (b as HTMLElement).dataset.tab === id);
    for (const p of panes.children) (p as HTMLElement).style.display = (p as HTMLElement).dataset.tab === id ? "" : "none";
  };
  for (const [id, label, sections] of tabs) {
    bar.append(h("button", { class: "tab", role: "tab", "data-tab": id, text: label, onclick: () => show(id) }));
    const pane = h("div", { class: "tab-pane", "data-tab": id }, ...sections);
    panes.append(pane);
  }
  root.append(
    h("h1", {}, h("span", { text: "Coucou" }), h("span", { class: "version", text: version })),
    bar,
    panes,
    h("div", {
      class: "hint",
      text: t("No telemetry. Network requests only go to the services you configure yourself."),
    }),
  );
  show(current);

  void onEvent<Settings>("settings-changed", (s) => {
    settings = { ...settings, ...s };
    if (setLanguage(settings.language)) location.reload();
  });
}

void main();
