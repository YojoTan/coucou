import SwiftUI

/// SwiftUI wrapper: TimelineView drives a Canvas that calls BotEngine.draw().
/// Uses a shared engine per-task; the main bot uses AppState's shared engine.
struct BotCanvasView: View {
    @ObservedObject var state: AppState
    var particleOverhang: CGFloat = 0
    var isVisible: Bool = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var idleBurst: IdleMicroAnimation?

    // One engine per view instance (main bot)
    @StateObject private var engine = BotEngine()

    var body: some View {
        TimelineView(.animation(minimumInterval: state.mode == .hidden ? 1.0 / 20 : nil,
                                paused: state.mode == .hidden && idleBurst == nil)) { timeline in
            Canvas { context, size in
                let now = timeline.date.timeIntervalSinceReferenceDate
                let dtRaw = min(0.05, now - engine.lastTime)
                let dt = dtRaw
                if let glance = engine.glance, Date().timeIntervalSince(state.lastMouseMove) > 1 {
                    // Someone is talking in the Discord call: look at them.
                    engine.lookX = glance.x
                    engine.lookY = glance.y
                } else if let burst = idleBurst, Date().timeIntervalSince(state.lastMouseMove) > 1 {
                    let look = burst.look(at: now)
                    engine.lookX = look.x
                    engine.lookY = look.y
                } else if state.mode == .hidden && state.idleAnimationsEnabled && state.effectiveState == .idle {
                    engine.lookX = 0
                    engine.lookY = 0
                } else {
                    let look = lookDirection(state: state)
                    engine.lookX = look.x
                    engine.lookY = look.y
                }
                engine.particleOverhang = particleOverhang
                // Widen slot when file is hovering over the mailbox (morph > 0.5)
                // Open mouth (hover=0.20R) when file dragged over box; close when not
                if engine.morph > 0.3 {
                    engine.slotHTarget = state.fileDragOver ? 0.20 : 0
                } else {
                    engine.slotHTarget = 0
                    if engine.morph < 0.05 { engine.slotH = 0; engine.slotHVel = 0 }
                }
                // Integration pills have a fixed brand color → use it as bodyColor.
                // Claude Code tasks use state-based gradient (working=blue, thinking=purple, etc.).
                engine.bodyColor = (state.focusTask?.isIntegration == true)
                    ? cgColorFromHex(state.focusTask!.color)
                    : nil
                engine.update(dt: dt)
                engine.drawHandsBehind(context: context, size: size)
                engine.draw(context: context, size: size)
                engine.drawHandsAndExtras(context: context, size: size)
            }
        }
        .onChange(of: state.effectiveState) { _, newState in
            engine.setState(newState)
        }
        .onChange(of: state.view) { _, newView in
            // Morph up when upload view is active
            if state.mode == .expanded && newView == .upload {
                engine.anim("morph", keys: [TweenKey(target: 1, duration: 550, ease: Ease.inOut)])
            } else if newView != .upload && newView != .uploading && engine.morph > 0.01 {
                // Any other view (not mid-gulp): morph back
                engine.anim("morph", keys: [TweenKey(target: 0, duration: 550, ease: Ease.inOut)])
            }
        }
        .onChange(of: state.mode) { _, newMode in
            // Hard-reset morph when island collapses
            if newMode != .expanded {
                engine.tweens.removeValue(forKey: "morph")
                engine.locks.remove("morph")
                engine.morph = 0
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .triggerEmote)) { notif in
            if let emote = notif.object as? BotEmote {
                engine.triggerEmote(emote)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .triggerSlap)) { _ in
            engine.slap()
        }
        .onReceive(NotificationCenter.default.publisher(for: .botBlink)) { _ in
            engine.blink()
        }
        .onReceive(NotificationCenter.default.publisher(for: .botSetTgEs)) { notif in
            if let v = notif.object as? CGFloat {
                engine.tgEs = v
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .botGulp)) { _ in
            engine.gulp()
        }
        .onReceive(NotificationCenter.default.publisher(for: .botMorphTo)) { notif in
            if let target = notif.object as? CGFloat {
                let dur: CGFloat = target > 0.5 ? 550 : 650
                engine.anim("morph", keys: [TweenKey(target: target, duration: dur, ease: Ease.inOut)])
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .botGreet)) { _ in
            engine.greet()
        }
        .onReceive(NotificationCenter.default.publisher(for: .botTravel)) { _ in
            engine.travel()
        }
        .onAppear {
            engine.setState(state.effectiveState, force: true)
        }
        .task(id: idleAnimationsEligible) {
            await runIdleAnimations()
        }
        #if !APPSTORE
        .background(MusicSync(engine: engine, active: state.focusTask?.id == "integration_spotify"))
        .background(DiscordSync(engine: engine, active: state.focusTask?.id == DiscordService.taskId))
        .background(MochiExtrasSync(engine: engine, taskId: state.focusTask?.id, isMain: true))
        #endif
    }

    private var idleAnimationsEligible: Bool {
        IdleMicroAnimation.isEligible(enabled: state.idleAnimationsEnabled,
                                      visible: isVisible && !state.isDraggingBot,
                                      resting: state.mode == .hidden || state.mode == .compact,
                                      idle: state.effectiveState == .idle,
                                      reduceMotion: reduceMotion)
    }

    @MainActor
    private func runIdleAnimations() async {
        guard idleAnimationsEligible else { return }
        defer {
            if idleBurst != nil { settleRestingEyes() }
            idleBurst = nil
        }
        do {
            while !Task.isCancelled {
                try await Task.sleep(for: .seconds(Double.random(in: IdleMicroAnimation.pauseRange)))
                guard Date().timeIntervalSince(state.lastMouseMove) > 1 else { continue }
                let burst = IdleMicroAnimation.random(startTime: Date().timeIntervalSinceReferenceDate)
                // Prevent an overdue ambient blink from starting on the first frame.
                engine.nextBlink = CACurrentMediaTime() + IdleMicroAnimation.duration + 3
                idleBurst = burst
                try await Task.sleep(for: .seconds(IdleMicroAnimation.blinkDelay))
                if burst.blinks && Date().timeIntervalSince(state.lastMouseMove) > 1 {
                    engine.blink()
                }
                try await Task.sleep(for: .seconds(IdleMicroAnimation.duration - IdleMicroAnimation.blinkDelay))
                settleRestingEyes()
                idleBurst = nil
            }
        } catch is CancellationError {
            // SwiftUI cancels this task on a mode/setting change or disappearance.
        } catch {
            assertionFailure("Unexpected idle animation sleep failure: \(error)")
        }
    }

    private func settleRestingEyes() {
        guard state.mode == .hidden && state.effectiveState == .idle else { return }
        engine.yaw = 0
        engine.pitch = 0
        engine.tgYaw = 0
        engine.tgPitch = 0
        engine.open = 1
        engine.tweens.removeValue(forKey: "open")
        engine.locks.remove("open")
    }

    private func lookDirection(state: AppState) -> CGPoint {
        let (islandW, islandH) = islandSize(mode: state.mode, view: state.view,
                                             progress: state.uploadProgress,
                                             nw: state.notchWidth, nh: state.notchHeight,
                                             toast: state.compactToast != nil)
        let actualH: CGFloat = (state.mode == .expanded && state.view == .prompt)
            ? min(300, 240 + CGFloat(state.chatHistory.count) * 40)
            : islandH
        let (botCx, botCy, _, _) = botPosition(mode: state.mode, view: state.view,
                                             islandW: islandW, islandH: actualH,
                                             uploadProgress: state.uploadProgress)
        return IslandGazeGeometry.direction(mouse: state.mousePosition,
                                            panelFrame: state.islandPanelFrame,
                                            islandWidth: islandW,
                                            botCenter: CGPoint(x: botCx, y: botCy))
    }
}

/// Mini bot canvas (for agent pills/column)
struct MiniBotCanvasView: View {
    let task: AgentTask
    @StateObject private var engine: BotEngine

    init(task: AgentTask) {
        self.task = task
        _engine = StateObject(wrappedValue: {
            let e = BotEngine()
            e.isMini = true
            e.bodyColor = cgColorFromHex(task.color)
            return e
        }())
    }

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                let now = timeline.date.timeIntervalSinceReferenceDate
                let dt = min(0.05, now - engine.lastTime)
                engine.update(dt: dt)
                engine.draw(context: context, size: size)
            }
        }
        .onChange(of: task.state) { _, newState in
            engine.setState(newState)
        }
        .onAppear {
            engine.setState(task.state, force: true)
            if let emote = task.emote {
                engine.setPermanentEmote(emote)
            }
            // Direct eye override takes priority (e.g. .wide eyes for Research)
            if let eye = task.miniEye {
                engine.permanentEye = eye
                engine.eyeOverride = eye
                engine.eyeOverrideUntil = .greatestFiniteMagnitude
            }
        }
        #if !APPSTORE
        .background {
            if task.id == "integration_spotify" { MusicSync(engine: engine, active: true) }
            if task.id == DiscordService.taskId { DiscordSync(engine: engine, active: true) }
            MochiExtrasSync(engine: engine, taskId: task.id, isMain: false)
        }
        #endif
    }
}

#if !APPSTORE
/// Spotify's play state into a Mochi: headphones while a track is loaded, the
/// dance while it plays (not with Reduce Motion). Only the Spotify Mochis carry
/// one, so the other pills don't re-render on every track change.
struct MusicSync: View {
    @ObservedObject private var state = AppState.shared
    let engine: BotEngine
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Color.clear
            .onAppear { apply(previous: nil) }
            .onChange(of: state.spotifyNow) { old, _ in apply(previous: old) }
            .onChange(of: active) { _, _ in apply(previous: nil) }
            .onChange(of: reduceMotion) { _, _ in apply(previous: nil) }
    }

    private func apply(previous: SpotifyTrack?) {
        let track = state.spotifyNow
        engine.musicHeadphones = active && track != nil
        let playing = active && track?.playing == true && !reduceMotion
        // The beat starts over on play and on a new track.
        if playing && (!engine.musicPlaying || (previous != nil && previous?.title != track?.title)) {
            engine.musicStart()
        }
        engine.musicPlaying = playing
    }
}

/// Discord's call into a Mochi: the headset while in a voice channel, the
/// mouth while you talk, a closed mouth and a red mic when muted, waves while
/// the others talk, and a surprised face on a new DM or mention.
struct DiscordSync: View {
    @ObservedObject private var state = AppState.shared
    let engine: BotEngine
    let active: Bool

    var body: some View {
        Color.clear
            .onAppear(perform: apply)
            .onChange(of: state.discordVoice) { _, _ in apply() }
            .onChange(of: state.discordSelfMute) { _, _ in apply() }
            .onChange(of: state.discordSelfDeaf) { _, _ in apply() }
            .onChange(of: active) { _, _ in apply() }
            .onChange(of: state.discordNotes.first?.id) { _, new in
                guard active, new != nil, let note = state.discordNotes.first else { return }
                // 🎉 confetti, ❤️ hearts, 😂 a laugh, ? a question mark, 🔥 fire; else surprise.
                if let r = DiscordParse.reaction(note.text) {
                    engine.react(r)
                } else {
                    engine.triggerEmote(.surprised, silent: true)
                    engine.squash()
                }
            }
            .onChange(of: state.discordEvent) { _, e in
                guard active, let e else { return }
                switch e.kind {
                case .joined: engine.greet()
                case .left:
                    engine.eyeOverride = .tired
                    engine.eyeOverrideUntil = CACurrentMediaTime() + 1.6
                case .highFive:
                    engine.greet()
                    engine.emit(.star, count: 6)
                case .talkingMuted:
                    engine.greet()
                    engine.triggerEmote(.surprised, silent: true)
                }
            }
    }

    private func apply() {
        let voice = active ? state.discordVoice : nil
        let me = state.discordMe ?? ""
        engine.voiceHeadset = voice != nil
        engine.callStartedAt = voice != nil ? DiscordCall.shared.startedAt : nil
        engine.micMuted = voice != nil && (state.discordSelfMute || state.discordSelfDeaf)
        engine.deafened = state.discordSelfDeaf
        engine.talking = voice?.speaking.contains(me) == true && !engine.micMuted
        engine.othersSpeaking = !(voice?.speaking.subtracting([me]).isEmpty ?? true)
        // The card lists the call's first 7 people left to right, right of Mochi.
        if let voice, let i = voice.members.prefix(7).firstIndex(where: { $0.id != me && voice.speaking.contains($0.id) }) {
            engine.glance = CGPoint(x: min(0.95, 0.5 + 0.075 * CGFloat(i)), y: 0.05)
        } else {
            engine.glance = nil
        }
    }
}

/// Accessories and moods from the Extras, for one Mochi:
/// a custom Mochi's outfit, the weather's, the Mac's moods (sweat, sleepy, panic,
/// hard hat while building), the meeting about to start; and for the main one,
/// a Focus mode's mask or glasses, else its trophy, and scruffy when neglected.
struct MochiExtrasSync: View {
    @ObservedObject private var state = AppState.shared
    let engine: BotEngine
    let taskId: String?
    let isMain: Bool

    var body: some View {
        // A ticking date: the meeting countdown moves on its own.
        TimelineView(.periodic(from: .now, by: 15)) { t in
            Color.clear
                .onAppear(perform: apply)
                .onChange(of: t.date) { _, _ in apply() }
        }
        .onChange(of: taskId) { _, _ in apply() }
        .onChange(of: state.system) { _, _ in apply() }
        .onChange(of: state.weather) { _, _ in apply() }
        .onChange(of: state.calendarNext) { _, _ in apply() }
        .onChange(of: state.focusMode) { _, _ in apply() }
        .onChange(of: state.pet) { _, _ in apply() }
        .onChange(of: state.customStatus) { _, _ in apply() }
        .onChange(of: state.petEvent) { _, e in
            guard isMain, e != nil else { return }
            engine.react(.confetti)
            engine.greet()
        }
    }

    private func apply() {
        var accessory = MochiAccessory.none
        var color: Color? = nil
        var sweat = false, sleepy = false, panic = false
        switch taskId {
        case let id? where id.hasPrefix("custom_"):
            if let m = CustomMochis.all.first(where: { $0.id == id }) {
                accessory = m.accessory
                color = Color(hex: m.color).opacity(0.95)
            }
        case WeatherMochi.taskId?:
            accessory = state.weather?.accessory ?? .none
        case SystemMochi.taskId?:
            if let s = state.system {
                accessory = s.building != nil ? .hardhat : .none
                sweat = s.cpu > 85
                sleepy = (s.battery ?? 100) < 15 && !s.charging
                panic = s.diskFreePercent < 5
            }
        case CalendarMochi.taskId?:
            if let e = state.calendarNext {
                let minutes = e.start.timeIntervalSinceNow / 60
                sweat = minutes <= 2 && minutes > -1
                accessory = minutes <= 5 && minutes > -10 ? .glasses : .none
            }
        default:
            break
        }
        if isMain {
            switch state.focusMode {
            case .doNotDisturb, .sleep: accessory = .sleepMask
            case .work: accessory = .glasses
            case .normal:
                // The trophy, unless the focused pill already dresses Mochi.
                if accessory == .none && !(taskId ?? "").hasPrefix("custom_") { accessory = state.pet.worn }
            }
        }
        engine.accessory = accessory
        engine.accessoryColor = color
        engine.sweating = sweat
        let neglected = isMain && state.pet.scruffy && state.focusMode == .normal
        engine.sleepy = sleepy || neglected
        engine.scruffy = neglected
        if engine.panicked != panic { engine.panicked = panic }
    }
}
#endif

// MARK: - CGColor from hex string

func cgColorFromHex(_ hex: String) -> CGColor? {
    let h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
    guard let val = UInt64(h, radix: 16) else { return nil }
    let r = CGFloat((val >> 16) & 0xFF) / 255
    let g = CGFloat((val >> 8)  & 0xFF) / 255
    let b = CGFloat( val        & 0xFF) / 255
    return CGColor(red: r, green: g, blue: b, alpha: 1)
}

extension CGColor {
    static func from(_ hex: String) -> CGColor {
        cgColorFromHex(hex) ?? CGColor(gray: 0.5, alpha: 1)
    }
}
