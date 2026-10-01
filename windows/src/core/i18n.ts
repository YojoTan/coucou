// Interface language: English (the source text), Spanish or Brazilian
// Portuguese (after upstream PR #33). gettext-style —
// t() takes the English string itself as the key, so an untranslated string
// simply shows in English, and the code reads the same as before.
//
// "auto" follows the system (WebView2 reports it in navigator.language).
// Placeholders are written {name} and filled from `vars`.

import { ES } from "./i18n-es";
import { PT } from "./i18n-pt";

export type Language = "auto" | "en" | "es" | "pt-BR";
type Active = "en" | "es" | "pt-BR";

const TABLES: Record<Active, Record<string, string> | null> = { en: null, es: ES, "pt-BR": PT };

function known(v: unknown): v is Active {
  return v === "en" || v === "es" || v === "pt-BR";
}

const STORE_KEY = "coucou.language";

/** Read synchronously at load, so module-level labels are already right. */
function stored(): Language {
  try {
    const v = localStorage.getItem(STORE_KEY);
    return known(v) ? v : "auto";
  } catch {
    return "auto";
  }
}

let active: Active = detect(stored());

function detect(pref: Language): Active {
  if (known(pref)) return pref;
  const sys = (typeof navigator !== "undefined" ? navigator.language || "" : "").toLowerCase();
  // Any Portuguese gets the Brazilian table: closer than falling back to English.
  return sys.startsWith("es") ? "es" : sys.startsWith("pt") ? "pt-BR" : "en";
}

/** Applies the preference; true when the language changed (the page reloads). */
export function setLanguage(pref: Language | string | undefined): boolean {
  const p: Language = known(pref) ? pref : "auto";
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

export function currentLanguage(): Active {
  return active;
}

export function t(source: string, vars?: Record<string, string | number>): string {
  let out = TABLES[active]?.[source] ?? source;
  if (vars) {
    for (const [k, v] of Object.entries(vars)) out = out.split(`{${k}}`).join(String(v));
  }
  return out;
}
