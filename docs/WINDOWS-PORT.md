# Porting the 2026-10 macOS work to Windows

Brief for whoever (human or agent) brings PRs #1, #2 and #3 to the Windows build
(`windows/`, Tauri: Rust in `src-tauri/`, TypeScript in `src/`). It says what each
feature does, where the macOS code is, how to do it on Windows, and how to know
it works. Read the project rules in `CLAUDE.md` first; they apply unchanged.

## State on 2026-10-01

| Feature | macOS | Windows |
| --- | --- | --- |
| LAN: answer every beacon (PR #3) | done | **written, never compiled** — `src-tauri/src/lan/mod.rs` |
| LAN Mochis in the header + online/offline toasts (#3) | done | — |
| Compact toasts (#2) | done | — |
| Mochi engine: headphones, dance, whistle, headset, talking mouth, mouth that follows the gaze, nightcap, accessories, moods, confetti, travel, gaze at a speaker (#1–#3) | done | — |
| Spotify Mochi (#1) | done | pill exists (`media.rs`), no personality |
| Orca: terminal jump, no double alerts, asks/gates from the notch (#1) | done | basic pill only (`orca.rs`) |
| Discord (#2) | done | — |
| Extras: custom Mochis, pet, calendar, Mac, weather, voice, travel, Focus (#3) | done | — |

## Step 0 — build, and check the LAN fix (do this first)

The Mac shows a paired Windows PC as offline because the PC's broadcast beacons
never reach the Mac (Windows tends to send `255.255.255.255` out of a WSL /
Hyper-V / VPN adapter), and each side only answered a peer the first time. The
fix makes both sides answer **every** beacon with a unicast one, at most once per
4 s per peer (`docs/LAN.md`, "Discovery").

1. `cd windows && npm ci && npm run tauri build` (or `cargo build` in `src-tauri`).
   The change was written on a Mac without a Rust toolchain: fix whatever the
   compiler says, keeping the behaviour (a `HashMap<String, Instant>` of last
   replies inside `discover`, reply when `elapsed() >= BEACON_EVERY`).
2. `cargo test` in `src-tauri` — the LAN wire vectors must still pass.
3. With the Mac on the new build too: both sides show each other **paired and
   online**, and stay online for minutes. If not, on the Mac,
   `python3` listening on UDP 47801 with `SO_REUSEPORT` shows which beacons
   arrive (the PC's address must appear every ~4 s).
4. If it still fails, add subnet-directed broadcasts (`192.168.x.255` per IPv4
   adapter, via `GetAdaptersAddresses`) next to `255.255.255.255`.

## How the two builds map

| macOS | Windows |
| --- | --- |
| `BotEngine.swift` (Mochi drawn in `Canvas`) | `src/mochi/engine.ts` — a 1:1 port; keep it that way: port functions with the same names and constants |
| `MochiAccessories.swift` | new `src/mochi/accessories.ts`, called from `engine.ts` like the Swift extension |
| `AppState.swift` | `src/core/state.ts` |
| `IslandViewContent.swift`, `*Views.swift` (cards) | `src/views/*.ts` |
| `IslandRootView.swift` (header, compact) | `src/island/island.ts`, `src/views/dom.ts` |
| `SettingsView.swift` | `src/settings/main.ts` |
| Pollers / services (`*Service.swift`, `*Poller.swift`) | Rust in `src-tauri/src/*.rs`, `#[tauri::command]`s + events, wired in `lib.rs`, typed in `src/core/bridge.ts` |
| Keychain (`KeychainStore`) | Credential Manager (`secrets.rs`) — same key names |
| `Localizable.strings` (es, pt-BR) | `src/core/i18n-es.ts`, `i18n-pt.ts` |
| `SoundEngine.swift` | `src/core/sound.ts` |
| Swift pure-function tests (`tests/*.swift`) | `#[test]`s in Rust (the TS side has no runner) |

Rules that matter for this port (from `CLAUDE.md`): secrets only in Credential
Manager; no telemetry, network only to services the user configured; nothing
sent (email, message, webhook post, Orca answer, file) without an explicit click
or an opt-in the user switched on; 0 % CPU while the island is hidden — every
poller works only while its pill is on.

## Suggested order

1. Step 0 (LAN fix).
2. Compact toasts — several features use them.
3. LAN header + toasts.
4. Engine additions (accessories, moods, mouth, headphones…) — the visual base.
5. Spotify Mochi — the data already exists.
6. Discord.
7. Orca.
8. Extras.

---

## 1. Compact toasts (#2)

**What:** one line ("Ana joined") in the compact island's right ear for ~3.5 s; the
compact island widens by 220 px meanwhile; toasts queue (max 4); a hidden island
is revealed for it. Do Not Disturb drops them.

**macOS:** `AppState.showToast`, `CompactToast`, `IslandConst.toastExtraWidth`,
`islandSize(..., toast:)`, `CompactToastView` in `IslandRootView.swift`.

**Windows:** a `toast` field in `state.ts`, the compact width in `layout.ts`
grows when set, `island.ts` renders the text where the mini grid sits
(`showGrid`). Also widen the window's hit-test region.

**Done when:** a toast shows in compact mode, the island grows and shrinks back
smoothly, queued toasts follow each other, and nothing shows with Do Not Disturb.

## 2. LAN Mochis in the header (#3)

**What:** paired Mochis as tiny Mochis (owner's colour from `colorForProject`,
sleeping + dimmed offline) in the expanded island's header; click → Message,
Ask their Mochi, Send a file… (file picker, then the same send as a drop).
Toasts: "X is online" / "X went offline", only after 30 s in the previous state.
The Mochis pill stays, optional.

**macOS:** `NearbyMochisView` (`LanViews.swift`), `LanService.announce`.

**Windows:** `src/island/lan.ts` + header DOM; mini Mochis via `minibots.ts`.

## 3. Engine additions (#1–#3)

Port these from `BotEngine.swift` / `MochiAccessories.swift` with the same
names; check each visually against the macOS app side by side.

- **Headphones and music** — `musicHeadphones`, `musicPlaying`, `groove`,
  `updateDance` (112 BPM: hop, sway, squash, nod; waves per beat; happy eyes
  every 8 beats), `whistle` (8 of every 16 beats: puckered mouth, notes from the
  mouth), `drawHeadphones`, `drawSoundWaves`, `.note` particle, `musicStart()`.
- **Voice call** — `voiceHeadset`, `micBoom`, `talk`/`talking`, `micMuted`,
  `deafened`, `othersSpeaking`, `drawMic` (tip follows the mouth),
  `drawTalkMouth`, sleep when deafened, `glance` (look at who speaks), fatigue
  (`callStartedAt`: yawn > 1 h, sweat > 2 h), `drawNightcap` (23:00–05:00),
  `mouthAlways` (the call's choir).
- **Mouth follows the gaze** — `mouthSpot(rx:ry:)`: the mouth is projected like
  the eyes (yaw, pitch), 0.36 rad below them, narrowed by `cos(yaw)`, hidden when
  turned away. The bug it fixed: eyes ran into a fixed mouth when looking down.
- **Accessories** — `MochiAccessory` (`ExtrasParse.swift`) and
  `drawAccessory`: cap, hardhat, crown, bow, antenna, glasses, sunglasses,
  sleepMask, umbrella, scarf; `eyePositions`. **Moods** — `updateMoods`:
  `sweating`, `sleepy`, `panicked` (shake + wide eyes; reset `ox` when it ends),
  `scruffy` tufts.
- **Reactions** — `react(_:)` (confetti / hearts / laugh / question badge /
  fire), `.confetti` particle, `travel()` (walk out right, back in from left).

## 4. Spotify Mochi (#1)

**What:** headphones while a track is loaded; dance + whistle while playing; off
with Reduce Motion; the beat restarts on play and on a new track (Spotify gives
no tempo to other apps).

**macOS:** `MusicSync` in `BotCanvasView.swift`.

**Windows:** `media.rs` already reports `playing` and the title — drive the
engine flags from it, for the main Mochi when Spotify is focused and for the
Spotify mini pill. `prefers-reduced-motion` stands in for Reduce Motion.

## 5. Discord (#2)

**macOS:** `DiscordService.swift` (RPC), `DiscordCall.swift` (around calls),
`DiscordMic.swift` (mic), `DiscordViews.swift`, `DiscordParse.swift`,
`DiscordSync` in `BotCanvasView.swift`.

- **RPC:** same protocol, but the socket is a named pipe:
  `\\.\pipe\discord-ipc-0` … `-9`. Frames: `u32 op` + `u32 length` (little
  endian) + JSON. Handshake `op 0 {"v":1,"client_id"}`, then `AUTHORIZE`
  (scopes `rpc rpc.voice.read rpc.voice.write rpc.notifications.read identify`)
  → code → token exchange at `https://discord.com/api/oauth2/token` (client
  secret; retry with `redirect_uri=http://127.0.0.1` if Discord asks) →
  `AUTHENTICATE`. Then `SUBSCRIBE` `VOICE_CHANNEL_SELECT`,
  `VOICE_SETTINGS_UPDATE`, `NOTIFICATION_CREATE`, and per channel
  `VOICE_STATE_*`, `SPEAKING_START/STOP`; commands `GET_SELECTED_VOICE_CHANNEL`,
  `GET_CHANNEL`, `GET_VOICE_SETTINGS`, `SET_VOICE_SETTINGS` (`mute`, `deaf`,
  `input/output.device_id`), `SELECT_TEXT_CHANNEL`, `SET_ACTIVITY`. Only connect
  to a pipe served by this same user (as `orca.rs` checks). Client id/secret and
  tokens in Credential Manager under the same names (`discord-client-id`, …).
  Confirmed working with the author's own Discord app (RPC is closed beta but
  open to the app's owner and testers).
- **Mention count:** macOS reads the Dock badge (`lsappinfo`). Windows has no
  readable equivalent (the taskbar overlay can't be read) — count
  `NOTIFICATION_CREATE` since launch instead, and say "connect for mentions"
  without RPC.
- **Webhook:** identical — `DiscordWebhook` (validation in
  `DiscordParse.isWebhook`, `allowed_mentions: {parse: []}`, 10 MB, multipart
  `payload_json` + `files[0]`); posts on Claude Code finish/permission only when
  switched on; tool name only, never the command.
- **Around calls** (`DiscordCall.swift`, pure logic, ports straight to TS):
  join/leave diff → toasts + wave/sad; talk time per person → summary toast and
  card row; Spotify pause/resume (only if Coucou paused it); call mode silences
  `sound.ts` and counts missed alerts; LAN high five by name match.
- **Lock mute:** `WTSRegisterSessionNotification` → `WM_WTSSESSION_CHANGE`
  (`WTS_SESSION_LOCK` / `UNLOCK`); unmute only if the lock muted.
- **Talking while muted** (opt-in, off): WASAPI capture level only (or WebView2
  `getUserMedia` + an `AnalyserNode`), −38 dBFS for 0.7 s within 1.5 s, 20 s
  cooldown; never record or send. **Transcription** (opt-in, off):
  `Windows.Media.SpeechRecognition` continuous dictation, on-device only; the
  text lives until the call ends and goes to the chat engine only on the
  Summarize click. Lowest priority.
- **Pitfall from macOS:** audio/speech callbacks run on their own threads — on
  the Rust side keep them `Send`, hop to the main/UI thread through events; the
  macOS build crashed on every Discord channel switch until this was fixed.

**Tests to port:** `tests/DiscordParseTests.swift` (webhook URL incl. look-alike
hosts, emoji reactions) → Rust `#[test]`s.

## 6. Orca (#1)

**macOS:** `OrcaPoller.swift`, `OrcaCardView` and `QuestionView` in
`IslandViewContent.swift`.

- Row click → `terminal.list` over the runtime pipe, match `leafId` to the
  agent's `paneKey` suffix, then `terminal.focus {terminal, navigation:"host"}`.
- ± → `orca file open-changed --mode diff --worktree id:<worktreeId>`.
- No double alerts: skip the sound/badge when an agent session from Coucou's own
  hooks runs in that worktree's path.
- Questions and gates: `orchestration.runList` (non-legacy runs, their
  `coordinator_handle`), `orchestration.inbox` (type `question`, unanswered = no
  later message with that `thread_id`), `orchestration.gateList {run, status:"pending"}`.
  Answer with the CLI, as the coordinator:
  `orca orchestration reply --id … --body … --run … --from <coordinator> --json`
  / `orca orchestration gate-resolve --id … --resolution … --from <coordinator> --json`.
  Verified on macOS: a gate resolved from the notch is recorded as `resolved`.

## 7. Extras (#3)

**macOS:** `CustomMochis.swift`, `MochiPet.swift`, `ExtrasServices.swift`,
`ExtrasViews.swift`, `ExtrasParse.swift`, `MochiExtrasSync` in
`BotCanvasView.swift`.

- **Custom Mochis:** same model (`custom-mochis` JSON in settings: id
  `custom_xxxxxxxx`, name, colour, accessory, command, interval). Command via
  `cmd /C` (or `pwsh -NoProfile -Command`), 30 s timeout, first line + optional
  `ok:/working:/warning:/error:` prefix (`ExtrasParse.commandOutput`). Local URL
  **identical**: `POST http://127.0.0.1:47823/mochi/<slug>`, header
  `X-Coucou-Token` (token in Credential Manager, `custom-mochi-token`), body text
  or `{"text","state"}`, loopback only, 401/404/405 as on macOS. Shortcuts has no
  Windows equivalent — the URL covers Power Automate / Task Scheduler / scripts.
- **Pet:** pure logic (`MochiPet`): level = 1 + sessions/10, streak by local
  date, trophies 5 bow · 15 antenna · 30 cap · 60 sunglasses · 100 crown,
  scruffy after 3 days. Feed it from the hook "Stop" handling.
- **Calendar:** EventKit has no Windows twin for an unpackaged app
  (`Windows.ApplicationModel.Appointments` needs package identity). Use an
  **iCal URL** (Google "secret address in iCal format", Outlook "publish
  calendar") stored in Credential Manager, fetched every 5 min while the pill is
  on; parse `VEVENT`s for the next 24 h; same Join detection
  (`ExtrasParse.meetingLink`), toasts at 5 and 1 min.
- **Mac → "PC" pill:** CPU from `GetSystemTimes` deltas, battery from
  `GetSystemPowerStatus`, disk from `GetDiskFreeSpaceExW`, builders from a
  ToolHelp process snapshot (feature already enabled): `msbuild.exe`,
  `cl.exe`, `link.exe`, `cargo.exe`, `rustc.exe`, `dotnet.exe`, `node.exe`
  running `tsc/vite/webpack/esbuild` (match the command line if cheap, else skip
  node), `gradle`, `go.exe`. Same moods and thresholds.
- **Weather:** identical (Open-Meteo geocoding + forecast,
  `ExtrasParse.weatherAccessory`).
- **Voice:** WebView2's `speechSynthesis.speak()` is enough (Windows voices);
  opt-in, silent during calls and Focus.
- **Travel:** the engine's `travel()` on a LAN send; a guest Mochi walking in on
  the receiving prompt (`GuestMochiView`).
- **Focus:** no public API for the current Focus state. Offer the manual
  selector (Normal / Do Not Disturb / Work / Sleep) plus
  `POST http://127.0.0.1:47823/mode/<mode>` with the same token, so Power
  Automate or a script can set it. Do Not Disturb / Sleep → sleep mask, no
  sounds, no toasts; Work → glasses.

**Tests to port:** `tests/ExtrasParseTests.swift` (meeting links, weather
outfit, command output) → Rust `#[test]`s.

## Don't change

- The LAN wire format and its test vectors (`docs/LAN.md`) — both builds must
  keep talking.
- The local URL's port, path, header and token semantics — scripts should work
  on both systems.
- Key names in the Keychain / Credential Manager.
- Defaults: everything that listens, posts or speaks stays opt-in and off where
  macOS has it off (muted warning, transcription, presence, voice, webhook posts).
