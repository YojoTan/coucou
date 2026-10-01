// Interface language: English (the source text) or Spanish. gettext-style —
// t() takes the English string itself as the key, so an untranslated string
// simply shows in English, and the code reads the same as before.
//
// "auto" follows the system (WebView2 reports it in navigator.language).
// Placeholders are written {name} and filled from `vars`.

import { ES } from "./i18n-es";

export type Language = "auto" | "en" | "es";

const STORE_KEY = "coucou.language";

/** Read synchronously at load, so module-level labels are already right. */
function stored(): Language {
  try {
    const v = localStorage.getItem(STORE_KEY);
    return v === "en" || v === "es" ? v : "auto";
  } catch {
    return "auto";
  }
}

let active: "en" | "es" = detect(stored());

function detect(pref: Language): "en" | "es" {
  if (pref === "en" || pref === "es") return pref;
  const sys = typeof navigator !== "undefined" ? navigator.language || "" : "";
  return sys.toLowerCase().startsWith("es") ? "es" : "en";
}

/** Applies the preference; true when the language changed (the page reloads). */
export function setLanguage(pref: Language | string | undefined): boolean {
  const p: Language = pref === "en" || pref === "es" ? pref : "auto";
  let persisted = false;
  try {
    localStorage.setItem(STORE_KEY, p);
    persisted = localStorage.getItem(STORE_KEY) === p;
  } catch {
    /* storage blocked — the preference still applies to this page */
  }
  const next = detect(p);
  const changed = next !== active;
  active = next;
  if (typeof document !== "undefined") document.documentElement.lang = active;
  // Without storage a reload would come back to "auto" and loop: never ask for one.
  return changed && persisted;
}

export function currentLanguage(): "en" | "es" {
  return active;
}

export function t(source: string, vars?: Record<string, string | number>): string {
  let out = active === "es" ? (ES[source] ?? source) : source;
  if (vars) {
    for (const [k, v] of Object.entries(vars)) out = out.split(`{${k}}`).join(String(v));
  }
  return out;
}
