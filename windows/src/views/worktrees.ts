// Worktrees: the island view, the pill's card — ports of WorktreesView and
// WorktreesCardView (WorktreesViews.swift). The logic is island/worktrees.ts.

import { t } from "../core/i18n";
import { h, clear, svg } from "./dom";
import { ICONS } from "./icons";
import { Bridge } from "../core/bridge";
import { State, type WtField, type WtRepoState, type WtRun, type WtStatus, type WtWorktree } from "../core/state";
import { beginRun, cancelRun, currentRepo, execute, fieldProblem } from "../island/worktrees";
import type { ViewActions, ViewHost } from "./views";

const ACCENT = "#F97316";

function chips(s: WtStatus | undefined): HTMLElement {
  const row = h("span", { class: "wt-chips" });
  if (!s) return row;
  const chip = (text: string, color: string) => {
    const el = h("span", { class: "wt-chip", text });
    el.style.color = color;
    el.style.background = `${color}24`;
    return el;
  };
  if (s.dirty > 0) row.append(chip(`✎ ${s.dirty}`, "#F5A524"));
  if (s.unpushed > 0) row.append(chip(`↑ ${s.unpushed}`, "#60A5FA"));
  if (s.dirty === 0 && s.unpushed === 0) row.append(chip("✓", "#30A46C"));
  return row;
}

function ago(seconds: number | null): string {
  if (!seconds) return "";
  const diff = seconds - Date.now() / 1000;
  const f = new Intl.RelativeTimeFormat(document.documentElement.lang || undefined, { style: "narrow", numeric: "auto" });
  const abs = Math.abs(diff);
  if (abs < 3600) return f.format(Math.round(diff / 60), "minute");
  if (abs < 86_400) return f.format(Math.round(diff / 3600), "hour");
  return f.format(Math.round(diff / 86_400), "day");
}

/** What a plain-git repo offers is Coucou's, so its label is too. */
function label(r: WtRepoState | null, text: string): string {
  return r && !r.hasProvider ? t(text) : text;
}

/** The pill's card: the repo, a couple of worktrees with their state, Open and "+ Create". */
export function worktreesCard(open: () => void): HTMLElement {
  const repo = currentRepo();
  const head = h("div", { class: "int-head" },
    h("i", { class: "dot", style: `background:${ACCENT};width:7px;height:7px` }),
    h("b", { text: t("Worktrees") }),
    h("span", { text: repo ? `${repo.name} · ${repo.worktrees.length}` : "" }),
  );
  const rows = h("div", { class: "int-rows" });
  if (!repo) rows.append(h("div", { class: "int-sub ex-hint", text: t("Add a repo in Settings › Extras › Worktrees.") }));
  else if (repo.error) rows.append(h("div", { class: "int-sub wt-error", text: t(repo.error) }));
  for (const w of (repo?.worktrees ?? []).slice(0, 2)) {
    rows.append(h("div", { class: "int-row" }, h("span", { class: "int-name", style: "flex:0 1 auto", text: w.slug }), chips(repo!.status[w.path])));
  }
  const actions = h("div", { class: "int-actions" }, h("button", { class: "link-btn", style: `color:${ACCENT}`, text: t("Open"), onclick: open }));
  const create = repo?.description.actions.find((a) => a.scope === "repo");
  if (repo && create) {
    actions.append(h("button", { class: "link-btn", style: `color:${ACCENT}`, text: `+ ${label(repo, create.label)}`, onclick: () => beginRun(repo.id, create, null) }));
  }
  return h("div", { class: "int-card" }, head, rows, actions);
}

/** The header's shortcut, when a repo is set up: no pill slot needed. */
export function worktreesHeaderButton(go: () => void): HTMLElement {
  const btn = h("button", { class: "wt-header", title: t("Worktrees"), onclick: go }, svg(ICONS.branch, 13));
  return btn;
}

export function buildWorktrees(actions: ViewActions): ViewHost {
  const body = h("div", { class: "wt-body" });
  const el = h("div", { class: "view" }, h("div", { class: "card" }, body));
  let key = "";
  let openRow: string | null = null;
  let problem: string | null = null;
  let typed = "";

  const input = (value: string, placeholder: string, onInput: (v: string) => void, mono = false) => {
    const i = h("input", { type: "text", class: mono ? "wt-input mono" : "wt-input", value, placeholder, spellcheck: "false" }) as HTMLInputElement;
    i.addEventListener("mousedown", () => actions.takeKeyboard());
    i.addEventListener("input", () => onInput(i.value));
    return i;
  };
  const button = (text: string, kind: "primary" | "secondary" | "danger", onclick: () => void) =>
    h("button", { class: `wt-btn ${kind}`, text, onclick });

  function title(run: WtRun): HTMLElement {
    const repo = State.worktrees.find((r) => r.id === run.repoId) ?? null;
    return h("div", { class: "wt-title" }, h("b", { text: label(repo, run.action.label) }), run.worktree ? h("span", { text: run.worktree.slug }) : null);
  }

  function log(lines: string[]): HTMLElement {
    const box = h("div", { class: "wt-log" });
    for (const l of lines) box.append(h("div", { text: l }));
    queueMicrotask(() => { box.scrollTop = box.scrollHeight; });
    return box;
  }

  function list(): Node[] {
    const repos = State.worktrees;
    const repo = currentRepo();
    const top = h("div", { class: "wt-top" });
    if (repos.length > 1) {
      const sel = h("select", { class: "tune-select" }) as HTMLSelectElement;
      for (const r of repos) sel.append(h("option", { value: r.id, text: r.name }));
      sel.value = repo?.id ?? "";
      sel.addEventListener("change", () => { State.wtRepoId = sel.value; State.notify(); });
      top.append(sel);
    } else {
      top.append(h("b", { text: repo?.name ?? t("Worktrees") }));
    }
    top.append(h("span", { class: "wt-count", text: String(repo?.worktrees.length ?? 0) }), h("span", { class: "grow" }));
    if (repo) {
      for (const a of repo.description.actions.filter((x) => x.scope === "repo")) {
        top.append(h("button", { class: "link-btn", style: `color:${ACCENT};font-weight:600`, text: `+ ${label(repo, a.label)}`, onclick: () => beginRun(repo.id, a, null) }));
      }
    }
    const out: Node[] = [top];
    if (!repo) out.push(h("div", { class: "int-sub", text: t("Add a repo in Settings › Extras › Worktrees.") }));
    else if (repo.error) out.push(h("div", { class: "wt-error", text: t(repo.error) }));
    const rows = h("div", { class: "wt-rows" });
    for (const w of repo?.worktrees ?? []) rows.append(row(repo!, w));
    out.push(rows);
    return out;
  }

  function row(repo: WtRepoState, w: WtWorktree): HTMLElement {
    const s = repo.status[w.path];
    const open = openRow === w.path;
    const sub = [w.branch, w.note, ago(s?.lastCommit ?? null)].filter((x) => x).join(" · ");
    const more = h("button", { class: "mini-btn", title: t("More"), onclick: () => { openRow = open ? null : w.path; key = ""; State.notify(); } }, svg(ICONS.ellipsis, 11));
    const box = h("div", { class: open ? "wt-row open" : "wt-row" },
      h("div", { class: "wt-line" },
        h("div", { class: "wt-name" }, h("b", { text: w.slug }), h("span", { text: sub })),
        chips(s),
        more,
      ),
    );
    if (open) {
      const acts = h("div", { class: "wt-actions" });
      for (const a of repo.description.actions.filter((x) => x.scope === "worktree")) {
        const text = label(repo, a.label) + (a.danger ? "…" : "");
        acts.append(h("button", { class: a.danger ? "wt-pill danger" : "wt-pill", text, onclick: () => { openRow = null; beginRun(repo.id, a, w); } }));
      }
      acts.append(
        h("button", { class: "wt-pill", text: t("Show in Explorer"), onclick: () => void Bridge.worktreesReveal(repo.id, w.path) }),
        h("button", { class: "wt-pill", text: t("Open in VS Code"), onclick: () => void Bridge.worktreesVscode(repo.id, w.path) }),
      );
      box.append(acts);
    }
    return box;
  }

  function field(f: WtField, run: WtRun): HTMLElement {
    const name = f.label + (f.required ? " *" : "");
    const wrap = h("div", { class: "wt-field" });
    switch (f.type) {
      case "text": {
        const v = typeof run.values[f.id] === "string" ? (run.values[f.id] as string) : "";
        wrap.append(h("label", { text: name }), input(v, f.placeholder ?? "", (x) => { run.values[f.id] = x; }));
        break;
      }
      case "choice": {
        const sel = h("select", { class: "tune-select" }) as HTMLSelectElement;
        for (const o of f.options ?? []) sel.append(h("option", { value: o.value, text: o.label }));
        if (typeof run.values[f.id] === "string") sel.value = run.values[f.id] as string;
        sel.addEventListener("change", () => { run.values[f.id] = sel.value; });
        wrap.classList.add("inline");
        wrap.append(h("label", { text: name }), sel);
        break;
      }
      case "multi": {
        const picked = Array.isArray(run.values[f.id]) ? [...(run.values[f.id] as string[])] : [];
        const flow = h("div", { class: "wt-flow" });
        for (const o of f.options ?? []) {
          const b = h("button", { class: picked.includes(o.value) ? "wt-opt on" : "wt-opt", text: o.label });
          b.addEventListener("click", () => {
            const i = picked.indexOf(o.value);
            if (i >= 0) picked.splice(i, 1);
            else picked.push(o.value);
            run.values[f.id] = [...picked];
            b.classList.toggle("on", i < 0);
          });
          flow.append(b);
        }
        wrap.append(h("label", { text: name }), flow);
        break;
      }
      case "bool": {
        const box = h("input", { type: "checkbox" }) as HTMLInputElement;
        box.checked = run.values[f.id] === true;
        box.addEventListener("change", () => { run.values[f.id] = box.checked; });
        wrap.classList.add("inline");
        wrap.append(h("label", { class: "wt-check" }, box, h("span", { text: f.label })));
        break;
      }
    }
    return wrap;
  }

  function form(run: WtRun): Node[] {
    const fields = h("div", { class: "wt-form" });
    for (const f of run.action.fields ?? []) fields.append(field(f, run));
    if (run.action.danger && !(run.action.fields ?? []).length) {
      fields.append(h("div", { class: "wt-soft", text: t("This removes {slug} — the provider checks nothing is lost first.", { slug: run.worktree?.slug ?? "" }) }));
    }
    const go = button(label(State.worktrees.find((r) => r.id === run.repoId) ?? null, run.action.label), run.action.danger ? "danger" : "primary", () => {
      const p = (run.action.fields ?? []).map((f) => fieldProblem(f, run.values[f.id])).find((x) => x);
      problem = p ?? null;
      if (!p) void execute();
      else { key = ""; State.notify(); }
    });
    return [
      title(run),
      fields,
      problem ? h("div", { class: "wt-error", text: problem }) : h("span"),
      h("div", { class: "wt-buttons" }, button(t("Cancel"), "secondary", () => { State.wtRun = null; problem = null; State.notify(); }), go),
    ];
  }

  function running(run: WtRun): Node[] {
    return [
      h("div", { class: "wt-title-row" }, h("i", { class: "wt-spinner" }), title(run)),
      log(run.log.slice(-9)),
      h("div", { class: "wt-buttons" }, button(t("Stop"), "secondary", cancelRun)),
    ];
  }

  function finished(run: WtRun): Node[] {
    const r = run.result;
    if (!r) return [];
    const icon = h("i", { class: r.ok ? "wt-ok" : "wt-ko", text: r.ok ? "✓" : "!" });
    const out: Node[] = [h("div", { class: "wt-title-row" }, icon, title(run)), h("div", { class: "wt-soft clamp", text: t(r.text) })];
    if (r.risk.length) out.push(log(r.risk));
    else if (!r.ok && run.log.length) out.push(log(run.log.slice(-6)));
    const buttons = h("div", { class: "wt-buttons" }, button(t("Back to the list"), "secondary", () => { State.wtRun = null; State.notify(); }));
    if (r.canForce && run.worktree) {
      buttons.append(h("button", { class: "link-btn", style: "color:#F87171;font-weight:600", text: t("Force…"), onclick: () => { typed = ""; run.stage = "confirmForce"; State.notify(); } }));
    }
    out.push(buttons);
    return out;
  }

  /** Forcing loses work: the user types the worktree's name to go on. */
  function confirmForce(run: WtRun): Node[] {
    const slug = run.worktree?.slug ?? "";
    const go = button(t("Force {action}", { action: run.action.label.toLowerCase() }), "danger", () => { if (typed === slug) void execute(true, typed); }) as HTMLButtonElement;
    go.disabled = typed !== slug;
    const field = input(typed, slug, (v) => { typed = v; go.disabled = typed !== slug; }, true);
    return [
      h("div", { class: "wt-danger", text: t("Forcing loses what isn't pushed or committed in {slug}.", { slug }) }),
      h("div", { class: "wt-soft", text: t("Type {slug} to confirm:", { slug }) }),
      field,
      h("div", { class: "wt-buttons" }, button(t("Cancel"), "secondary", () => { run.stage = "finished"; State.notify(); }), go),
    ];
  }

  return {
    el,
    sync() {
      const run = State.wtRun;
      // Re-render on a change of what is shown, not on every keystroke in a form.
      const k = run
        ? `${run.stage}:${run.action.id}:${run.worktree?.path ?? ""}:${run.log.length}:${run.result?.text ?? ""}:${problem ?? ""}`
        : `list:${JSON.stringify(State.worktrees)}:${State.wtRepoId}:${openRow}`;
      if (k === key) return;
      key = k;
      clear(body);
      const nodes = !run ? list() : run.stage === "form" ? form(run) : run.stage === "running" ? running(run) : run.stage === "finished" ? finished(run) : confirmForce(run);
      body.append(...nodes);
    },
  };
}
