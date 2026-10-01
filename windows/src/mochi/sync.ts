// What the integrations put on a Mochi — ports of MusicSync, DiscordSync and
// MochiExtrasSync (BotCanvasView.swift). Each one reads State and sets flags on
// an engine; the main Mochi and the pills' minis go through the same code.

import { State } from "../core/state";
import type { BotEngine } from "./engine";
import type { MochiAccessory } from "./accessories";

const lastTitle = new WeakMap<BotEngine, string | null>();

/**
 * Discord's call into a Mochi: the headset in a voice channel, the mouth while
 * you talk, a closed mouth and a red mic when muted, waves while the others
 * talk, and a glance at whoever speaks (DiscordSync).
 */
export function applyDiscord(e: BotEngine, active: boolean, startedAt: number | null) {
  const d = State.discord;
  const voice = active ? d?.voice ?? null : null;
  const me = d?.me ?? "";
  e.voiceHeadset = voice != null;
  e.callStartedAt = voice ? startedAt : null;
  e.micMuted = voice != null && (d!.selfMute || d!.selfDeaf);
  e.deafened = d?.selfDeaf ?? false;
  e.talking = (voice?.speaking.includes(me) ?? false) && !e.micMuted;
  e.othersSpeaking = (voice?.speaking.some((id) => id !== me)) ?? false;
  // The card lists the call's first 7 people left to right, right of Mochi.
  const i = voice ? voice.members.slice(0, 7).findIndex((m) => m.id !== me && voice.speaking.includes(m.id)) : -1;
  e.glance = i >= 0 ? { x: Math.min(0.95, 0.5 + 0.075 * i), y: 0.05 } : null;
}

function reducedMotion(): boolean {
  return typeof matchMedia === "function" && matchMedia("(prefers-reduced-motion: reduce)").matches;
}

/**
 * Spotify into a Mochi: headphones while a track is loaded, the dance while it
 * plays (not with reduced motion). The beat starts over on play and on a new track.
 */
export function applyMusic(e: BotEngine, active: boolean) {
  const np = (State.integrations.integration_spotify?.data?.nowPlaying ?? null) as
    { playing?: boolean; title?: string } | null;
  e.musicHeadphones = active && np != null;
  const playing = active && np?.playing === true && !reducedMotion();
  const previous = lastTitle.get(e);
  if (playing && (!e.musicPlaying || (previous != null && previous !== np?.title))) e.musicStart();
  lastTitle.set(e, np?.title ?? null);
  e.musicPlaying = playing;
}

/**
 * Accessories and moods from the extras for one Mochi; for the main one, the
 * mode's mask or glasses, else its trophy, and scruffy when neglected. The
 * pieces that need data (weather, PC, calendar, custom Mochis, pet) read it
 * from State as the extras fill it in.
 */
export function applyExtras(e: BotEngine, taskId: string | null, isMain: boolean) {
  let accessory: MochiAccessory = "none";
  let color: string | null = null;
  let sweat = false, sleepy = false, panic = false;
  const x = State.extras;
  if (taskId?.startsWith("custom_")) {
    const m = State.settings.customMochis?.find((c) => c.id === taskId);
    if (m) {
      accessory = m.accessory;
      color = m.color;
    }
  } else if (taskId === "integration_weather") {
    accessory = x.weather?.accessory ?? "none";
  } else if (taskId === "integration_system") {
    const s = x.system;
    if (s) {
      accessory = s.building ? "hardhat" : "none";
      sweat = s.cpu > 85;
      sleepy = (s.battery ?? 100) < 15 && !s.charging;
      panic = s.diskFreePercent < 5;
    }
  } else if (taskId === "integration_calendar") {
    const ev = x.calendarNext;
    if (ev) {
      const minutes = (ev.start - Date.now()) / 60000;
      sweat = minutes <= 2 && minutes > -1;
      accessory = minutes <= 5 && minutes > -10 ? "glasses" : "none";
    }
  }
  if (isMain) {
    switch (State.settings.focusMode) {
      case "doNotDisturb":
      case "sleep":
        accessory = "sleepMask";
        break;
      case "work":
        accessory = "glasses";
        break;
      default:
        // The season's outfit, else the trophy — unless the focused pill already dresses Mochi.
        if (accessory === "none" && !(taskId ?? "").startsWith("custom_")) accessory = x.season ?? x.pet?.worn ?? "none";
    }
  }
  e.accessory = accessory;
  e.accessoryColor = color;
  e.sweating = sweat;
  const neglected = isMain && (x.pet?.scruffy ?? false) && State.settings.focusMode === "normal";
  e.sleepy = sleepy || neglected;
  e.scruffy = neglected;
  if (e.panicked !== panic) e.panicked = panic;
}
