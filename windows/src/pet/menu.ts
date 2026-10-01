// The desktop pet's own menu (macOS PetMenu): shortcuts to the island, the
// chat, the worktrees and Settings; then each repo's worktrees with their
// state — a tap unfolds a row's actions. The island sends what to show
// (pet-menu-data) and runs what is picked; Rust closes the menu on a click
// elsewhere or Escape.

import "./pet.css";
import { emitTo, listen } from "@tauri-apps/api/event";
import { invoke } from "@tauri-apps/api/core";
import { t } from "../core/i18n";
import { h, clear, svg } from "../views/dom";
import { ICONS } from "../views/icons";
import type { WtRepoState } from "../core/state";

interface MenuData { color: string; status: string; repos: WtRepoState[] }

const root = document.getElementById("root")!;
let data: MenuData = { color: "#F5F6F8", status: "", repos: [] };
let openRow: string | null = null;

const choose = (choice: Record<string, unknown>) => void invoke("pet_menu_choose", { choice });

function shortcut(icon: string, label: string, run: () => void): HTMLElement {
  return h("button", { class: "pm-shortcut", onclick: run }, h("span", { class: "disc" }, svg(icon, 15)), h("span", { text: label }));
}

function mark(text: string, color: string): HTMLElement {
  const el = h("span", { class: "pm-mark", text });
  el.style.color = color;
  el.style.background = `${color}26`;
  return el;
}

function repoBlock(repo: WtRepoState): HTMLElement {
  const label = (s: string) => (repo.hasProvider ? s : t(s));
  const head = h("div", { class: "pm-repo-head" }, svg(ICONS.branch, 11), h("b", { text: repo.name }), h("span", { text: String(repo.worktrees.length) }), h("span", { class: "grow" }));
  for (const a of repo.description.actions.filter((x) => x.scope === "repo")) {
    head.append(h("button", { class: "pm-create", text: `+ ${label(a.label)}`, onclick: () => choose({ kind: "run", repoId: repo.id, actionId: a.id }) }));
  }
  const block = h("div", { class: "pm-repo" }, head);
  if (repo.error) block.append(h("div", { class: "pm-error", text: t(repo.error) }));
  const rows = h("div", { class: "pm-rows" });
  for (const w of repo.worktrees) {
    const s = repo.status[w.path];
    const risk = !!s && (s.dirty > 0 || s.unpushed > 0);
    const open = openRow === w.path;
    const line = h("button", { class: "pm-line", onclick: () => { openRow = open ? null : w.path; render(); } },
      h("i", { class: "dot", style: `background:${risk ? "#F5A524" : "#30A46C"}` }),
      h("span", { class: "slug", text: w.slug }),
    );
    if (s?.dirty) line.append(mark(`✎ ${s.dirty}`, "#F5A524"));
    if (s?.unpushed) line.append(mark(`↑ ${s.unpushed}`, "#60A5FA"));
    line.append(h("span", { class: "pm-chev", text: open ? "▲" : "▼" }));
    const row = h("div", { class: open ? "pm-row open" : "pm-row" }, line);
    if (open) {
      if (w.note) row.append(h("div", { class: "pm-note", text: w.note }));
      const pills = h("div", { class: "pm-pills" });
      for (const a of repo.description.actions.filter((x) => x.scope === "worktree")) {
        pills.append(h("button", {
          class: a.danger ? "pm-pill danger" : "pm-pill",
          text: label(a.label) + (a.danger ? "…" : ""),
          onclick: () => choose({ kind: "run", repoId: repo.id, actionId: a.id, worktreePath: w.path }),
        }));
      }
      pills.append(h("button", { class: "pm-pill", text: t("Explorer"), onclick: () => choose({ kind: "reveal", repoId: repo.id, path: w.path }) }));
      row.append(pills);
    }
    rows.append(row);
  }
  block.append(rows);
  return block;
}

function render() {
  clear(root);
  const card = h("div", { class: "pm-card" });
  card.append(h("div", { class: "pm-head" },
    h("i", { style: `background:${data.color}` }),
    h("div", {}, h("b", { text: "Mochi" }), h("span", { text: data.status })),
  ));
  const shortcuts = h("div", { class: "pm-shortcuts" },
    shortcut(ICONS.house, t("Island"), () => choose({ kind: "island" })),
    shortcut(ICONS.bubble, t("Chat"), () => choose({ kind: "chat" })),
  );
  if (data.repos.length) shortcuts.append(shortcut(ICONS.branch, t("Worktrees"), () => choose({ kind: "worktrees" })));
  shortcuts.append(shortcut(ICONS.gear, t("Settings"), () => choose({ kind: "settings" })));
  card.append(shortcuts);
  for (const repo of data.repos) card.append(repoBlock(repo));
  card.append(h("div", { class: "pm-foot" }, h("button", { text: `↥ ${t("Back to the island")}`, onclick: () => void invoke("pet_dock") })));
  root.append(card);
  // Rust sizes the window to the card.
  requestAnimationFrame(() => void invoke("pet_menu_size", { height: Math.ceil(card.getBoundingClientRect().height) }));
}

void listen<MenuData>("pet-menu-data", (e) => {
  data = e.payload;
  render();
});
// Each time it opens: a fresh look, rows folded.
void listen("pet-menu-shown", () => {
  openRow = null;
  void emitTo("island", "pet-menu-ready", null);
});
render();
void emitTo("island", "pet-menu-ready", null);
