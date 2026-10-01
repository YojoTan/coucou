// Extras → island: ports of CustomMochis.push, the alerts of CalendarMochi,
// SystemMochi and WeatherMochi, MochiPet and MochiVoice (macOS PR #3). Rust
// reads (extras/), the island decides what is news: toasts, badges, sounds,
// and what Mochi says out loud when the user turned its voice on.

import { onEvent, Bridge } from "../core/bridge";
import { Sound } from "../core/sound";
import { State, silences, type PetSave } from "../core/state";
import { currentLanguage, t } from "../core/i18n";
import type { MochiAccessory } from "../mochi/accessories";
import type { BotStateName } from "../core/layout";
import { callWouldInterrupt } from "./discord";
import type { Island } from "./island";

export const CALENDAR_ID = "integration_calendar";
export const SYSTEM_ID = "integration_system";
export const WEATHER_ID = "integration_weather";

// ── Voice ─────────────────────────────────────────────────────────────────────

/** Mochi says it (Settings › Extras, off by default): not in Focus, not over a call. */
export function say(text: string) {
  if (!State.settings.voice || !State.settings.soundEnabled || silences(State.settings.focusMode) || callWouldInterrupt()) return;
  if (typeof speechSynthesis === "undefined") return;
  const u = new SpeechSynthesisUtterance(text);
  u.lang = currentLanguage();
  u.rate = 1.05;
  u.pitch = 1.25; // a small voice for a small character
  speechSynthesis.speak(u);
}

// ── Pet ───────────────────────────────────────────────────────────────────────

const TROPHIES: [number, MochiAccessory][] = [[5, "bow"], [15, "antenna"], [30, "cap"], [60, "sunglasses"], [100, "crown"]];
const NO_PET: PetSave = { sessions: 0, streak: 0, bestStreak: 0, lastDay: "", wearing: null };

export function petSave(): PetSave {
  return { ...NO_PET, ...(State.settings.pet ?? {}) };
}

export function petLevel(p: PetSave): number {
  return 1 + Math.floor(p.sessions / 10);
}

export function unlocked(p: PetSave): MochiAccessory[] {
  return TROPHIES.filter(([n]) => p.sessions >= n).map(([, a]) => a);
}

export function nextTrophy(p: PetSave): [number, MochiAccessory] | null {
  return TROPHIES.find(([n]) => p.sessions < n) ?? null;
}

/** What the main Mochi wears when nothing else decides. */
function worn(p: PetSave): MochiAccessory {
  const w = p.wearing;
  if (w != null && (w === "none" || unlocked(p).includes(w))) return w;
  return unlocked(p).at(-1) ?? "none";
}

function localDay(d: Date): string {
  const pad = (n: number) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
}

/** Three days or more without a finished session. */
function scruffy(p: PetSave): boolean {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(p.lastDay);
  if (!m) return false;
  const last = new Date(Number(m[1]), Number(m[2]) - 1, Number(m[3]));
  return (Date.now() - last.getTime()) / 86_400_000 >= 3;
}

/** The pet as Mochi shows it (sync.ts reads it). */
export function refreshPet() {
  const p = petSave();
  State.extras.pet = { level: petLevel(p), streak: p.streak, sessions: p.sessions, worn: worn(p), scruffy: scruffy(p) };
}

const petListeners: (() => void)[] = [];
/** A trophy or a level: Mochi celebrates (the island's engine). */
export function onPetEvent(fn: () => void) {
  petListeners.push(fn);
}

/** A session finished (hooks.ts, Stop): the level, the streak, maybe a trophy. */
export function petSessionFinished() {
  const before = petSave();
  const p = { ...before };
  const now = new Date();
  const today = localDay(now);
  if (p.lastDay !== today) {
    const yesterday = localDay(new Date(now.getTime() - 86_400_000));
    p.streak = p.lastDay === yesterday ? p.streak + 1 : 1;
    p.bestStreak = Math.max(p.bestStreak, p.streak);
    p.lastDay = today;
  }
  p.sessions += 1;
  State.settings.pet = p;
  void Bridge.saveSettings(State.settings);
  refreshPet();
  const trophy = unlocked(p).at(-1);
  if (trophy && !unlocked(before).includes(trophy)) {
    State.showToast(t("Unlocked: {name}!", { name: t(ACCESSORY_LABELS[trophy]) }), "#F7B32B", 5);
    for (const fn of petListeners) fn();
    say(t("I unlocked a new outfit!"));
  } else if (petLevel(p) > petLevel(before)) {
    State.showToast(t("Mochi reached level {n}!", { n: petLevel(p) }), "#F7B32B", 4);
    for (const fn of petListeners) fn();
  } else if (p.streak > before.streak && p.streak > 1) {
    State.showToast(t("🔥 {n}-day streak", { n: p.streak }), "#F97316");
  }
}

/** Shown in Settings pickers (MochiAccessory.label). */
export const ACCESSORY_LABELS: Record<MochiAccessory, string> = {
  none: "Nothing", cap: "Cap", hardhat: "Hard hat", crown: "Crown", bow: "Bow", antenna: "Antenna",
  glasses: "Glasses", sunglasses: "Sunglasses", sleepMask: "Sleep mask", umbrella: "Umbrella", scarf: "Scarf",
  pumpkin: "Pumpkin", santaHat: "Santa hat", partyHat: "Party hat",
};

/** Today's outfit (Rust reads the date); on the birthday, confetti and a toast once that day. */
async function refreshSeason() {
  const s = await Bridge.extrasSeason();
  if (!s) return;
  State.extras.season = (s.outfit ?? null) as MochiAccessory | null;
  if (s.party) {
    window.setTimeout(() => {
      for (const fn of petListeners) fn();
      State.showToast(t("🎂 Happy birthday!"), "#A78BFA", 6);
    }, 1000);
  }
  State.notify();
}

// ── Custom Mochis ─────────────────────────────────────────────────────────────

interface CustomPush { id: string; text: string; state: string }

const CUSTOM_STATES: Record<string, BotStateName> = { idle: "idle", ok: "finished", working: "working", warning: "question", error: "error" };

/** News for a custom Mochi, from its command or the local URL. */
function pushCustom(p: CustomPush) {
  const m = State.settings.customMochis?.find((x) => x.id === p.id);
  if (!m) return;
  const old = State.extras.customStatus[p.id];
  const text = p.text.slice(0, 140);
  State.extras.customStatus[p.id] = { text, state: p.state, at: Date.now() };
  const task = State.tasks.find((x) => x.id === p.id);
  if (task) {
    task.state = CUSTOM_STATES[p.state] ?? "idle";
    task.steps = text ? [text] : [];
    task.stepIndex = 0;
    // A change of mood is news: a toast, and a badge when it isn't the focused one.
    if ((old?.state !== p.state || old?.text !== text) && p.state !== "idle") {
      State.showToast(`${m.name}: ${text || t(p.state)}`, m.color);
      if (State.focusId !== p.id) task.pillBadge = p.state === "error" ? "error" : "finished";
      if (p.state === "error") Sound.play("error");
    }
  }
  State.notify();
}

// ── Calendar ──────────────────────────────────────────────────────────────────

interface CalendarUpdate {
  next: { id: string; title: string; start: number; end: number; link: string | null } | null;
  error: string | null;
}

const alerted = new Set<string>();

function onCalendar(island: Island, u: CalendarUpdate) {
  State.extras.calendarError = u.error;
  State.extras.calendarNext = u.next;
  const next = u.next;
  const task = State.tasks.find((x) => x.id === CALENDAR_ID);
  if (next && task) {
    const minutes = (next.start - Date.now()) / 60_000;
    task.steps = [next.title];
    if (minutes <= 5.5 && minutes > 1.5 && !alerted.has(next.id + "5")) {
      alerted.add(next.id + "5");
      State.showToast(t("In 5 min: {title}", { title: next.title }), "#FF6B6B", 5);
      say(t("{title} starts in five minutes", { title: next.title }));
      if (State.focusId !== CALENDAR_ID) task.pillBadge = "approval";
      Sound.play("tick");
    } else if (minutes <= 1.5 && minutes > -1 && !alerted.has(next.id + "1")) {
      alerted.add(next.id + "1");
      State.showToast(t("Starting now: {title}", { title: next.title }), "#FF6B6B", 6);
      say(t("Your meeting is starting"));
      Sound.play("approval");
      island.reveal();
    }
  }
  State.notify();
}

// ── PC ────────────────────────────────────────────────────────────────────────

interface SystemSnapshot { cpu: number; battery: number | null; charging: boolean; diskFreeGb: number; diskFreePercent: number; building: string | null }

let warnedBattery = false;
let warnedDisk = false;

function onSystem(s: SystemSnapshot) {
  State.extras.system = { cpu: s.cpu, battery: s.battery, charging: s.charging, diskFreeGB: s.diskFreeGb, diskFreePercent: s.diskFreePercent, building: s.building };
  const task = State.tasks.find((x) => x.id === SYSTEM_ID);
  if (task) task.state = s.building ? "working" : s.cpu > 85 ? "thinking" : "idle";
  const lowBattery = (s.battery ?? 100) <= 10 && !s.charging;
  const fullDisk = s.diskFreePercent < 5;
  if (lowBattery && !warnedBattery) State.showToast(t("Battery at {n} % — plug me in", { n: s.battery ?? 0 }), "#F87171");
  if (fullDisk && !warnedDisk) State.showToast(t("Disk almost full: {n} GB left", { n: Math.floor(s.diskFreeGb) }), "#F87171");
  warnedBattery = lowBattery;
  if (fullDisk) warnedDisk = true;
  State.notify();
}

// ── Weather ───────────────────────────────────────────────────────────────────

interface WeatherNow { place: string; temperature: number; code: number; day: boolean; rainChance: number; accessory: MochiAccessory }

/** Open-Meteo's WMO code, in words and as an emoji (ExtrasParse.weather). */
export function weatherWords(code: number, day: boolean): [string, string] {
  // Not "Clear": that key is also a button (macOS shares it and says "Limpiar").
  if (code === 0) return [t("Clear sky"), day ? "☀️" : "🌙"];
  if (code === 1 || code === 2) return [t("Partly cloudy"), day ? "⛅" : "☁️"];
  if (code === 3) return [t("Cloudy"), "☁️"];
  if (code === 45 || code === 48) return [t("Fog"), "🌫️"];
  if (code >= 51 && code <= 57) return [t("Drizzle"), "🌦️"];
  if ((code >= 61 && code <= 67) || (code >= 80 && code <= 82)) return [t("Rain"), "🌧️"];
  if ((code >= 71 && code <= 77) || code === 85 || code === 86) return [t("Snow"), "🌨️"];
  if (code >= 95 && code <= 99) return [t("Storm"), "⛈️"];
  return ["—", "☁️"];
}

function isWet(code: number): boolean {
  return (code >= 51 && code <= 67) || (code >= 80 && code <= 82) || (code >= 95 && code <= 99);
}

function onWeather(u: { weather: WeatherNow | null; error: string | null }) {
  if (!u.weather) {
    State.extras.weatherError = u.error;
    State.notify();
    return;
  }
  const w = u.weather;
  const was = State.extras.weather;
  const wasDry = (was?.rainChance ?? 0) < 50 && !(was ? isWet(was.code) : false);
  State.extras.weatherError = null;
  State.extras.weather = w;
  const task = State.tasks.find((x) => x.id === WEATHER_ID);
  if (task) task.steps = [`${Math.round(w.temperature)}° · ${weatherWords(w.code, w.day)[0]}`];
  if (wasDry && w.accessory === "umbrella") State.showToast(t("☔️ Rain likely soon in {place}", { place: w.place }), "#38BDF8", 5);
  State.notify();
}

export function registerExtrasHandlers(island: Island) {
  refreshPet();
  void refreshSeason();
  // Scruffy comes with the days, and so do the seasons.
  window.setInterval(() => {
    refreshPet();
    void refreshSeason();
  }, 60 * 60 * 1000);
  State.subscribe(() => {
    const p = State.settings.pet;
    if (p && (p.sessions !== State.extras.pet?.sessions || worn(petSave()) !== State.extras.pet?.worn)) refreshPet();
  });
  void onEvent<CustomPush>("custom-mochi", pushCustom);
  void onEvent<CalendarUpdate>("extras-calendar", (u) => onCalendar(island, u));
  void onEvent<SystemSnapshot>("extras-system", onSystem);
  void onEvent<{ weather: WeatherNow | null; error: string | null }>("extras-weather", onWeather);
}
