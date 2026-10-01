import Foundation
import AppKit
import Combine

// MARK: - DiscordCall (GitHub build) — what happens around a Discord call
// Watches AppState.discordVoice (filled by DiscordService) on the main queue:
//
// • joins and leaves → a toast in the compact island ("Ana joined"), and Mochi
//   waves or looks sad;
// • who talks how long → a summary when the call ends ("52 min · you 61 %");
// • a paired LAN Mochi whose name matches someone in the call → a high five;
// • joining pauses Spotify, leaving resumes it (if Coucou paused it);
// • call mode: Coucou's sounds never talk over a conversation — muted, or with
//   nobody speaking, they play as usual; while someone speaks with your mic
//   open, the sound waits for a pause instead of being lost ("smart", the
//   default; "always" and "never" are the other choices);
// • locking the screen mutes, unlocking unmutes (only if the lock muted);
// • the microphone helpers (DiscordMic) follow the call and the mute;
// • Rich Presence: what Mochi is doing, on the user's Discord profile (opt-in).
//
// Every automatic action has a switch in Settings › Discord.

#if !APPSTORE
struct DiscordCallSummary: Equatable {
    let minutes: Int
    let myShare: Double          // 0…1 of the talking time
    let top: String?             // who talked most, when it isn't you
    let topShare: Double
    let missed: Int              // Coucou alerts silenced by call mode
    let hasTranscript: Bool
    let endedAt: Date
}

/// Something Mochi should react to (DiscordSync).
struct DiscordEvent: Equatable {
    enum Kind: Equatable { case joined, left, highFive, talkingMuted }
    let id = UUID()
    let kind: Kind
}

@MainActor
final class DiscordCall {
    static let shared = DiscordCall()

    static let pauseSpotifyKey = "discord-pause-spotify"      // default on
    static let quietKey = "discord-quiet-calls"                // before "smart": off meant always
    static let soundsKey = "discord-call-sounds"

    enum CallSounds: String, CaseIterable { case always, smart, never }

    static var callSounds: CallSounds {
        if let raw = UserDefaults.standard.string(forKey: soundsKey), let v = CallSounds(rawValue: raw) { return v }
        return UserDefaults.standard.object(forKey: quietKey) as? Bool == false ? .always : .smart
    }
    static let lockMuteKey = "discord-lock-mute"                // default on
    static let presenceKey = "discord-presence"                 // default off

    private var watches: [AnyCancellable] = []
    private var previous: DiscordVoice? = nil
    private var started: Date? = nil
    var startedAt: Date? { started }
    private var talkStart: [String: Date] = [:]
    private var talked: [String: TimeInterval] = [:]
    private var names: [String: String] = [:]
    private var highFived: Set<String> = []
    private var pausedSpotify = false
    private var mutedByLock = false
    private(set) var missed = 0
    private var deferred: String? = nil        // the sound waiting for a pause

    private init() {}

    static func on(_ key: String) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? (key != presenceKey)
    }

    func start() {
        let state = AppState.shared
        watches.append(state.$discordVoice.sink { [weak self] v in
            MainActor.assumeIsolated { self?.voiceChanged(v) }
        })
        watches.append(state.$discordSelfMute.combineLatest(state.$discordSelfDeaf).sink { [weak self] mute, deaf in
            MainActor.assumeIsolated { self?.micFollow(muted: mute || deaf) }
        })
        // Presence: Claude Code at work, or what Spotify plays — settled for 3 s.
        watches.append(state.$tasks.combineLatest(state.$spotifyNow)
            .debounce(for: .seconds(3), scheduler: DispatchQueue.main)
            .sink { _ in MainActor.assumeIsolated { DiscordCall.pushPresence() } })
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.locked(true) }
        }
        dnc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.locked(false) }
        }
    }

    /// Call mode: SoundEngine asks before every sound.
    func shouldSilence(_ name: String) -> Bool {
        guard started != nil else { return false }
        switch Self.callSounds {
        case .always: return false
        case .never:
            missed += 1
            return true
        case .smart:
            guard conversationGoing else { return false }
            deferred = name          // the latest wins; one sound when the pause comes
            return true
        }
    }

    /// Mochi's voice: not over a conversation, not when the user chose silence.
    var wouldInterrupt: Bool {
        guard started != nil else { return false }
        switch Self.callSounds {
        case .always: return false
        case .never: return true
        case .smart: return conversationGoing
        }
    }

    /// Mic open and someone speaking: the only time a sound would get in the way.
    private var conversationGoing: Bool {
        let s = AppState.shared
        let speaking = !(s.discordVoice?.speaking.isEmpty ?? true)
        return speaking && !s.discordSelfMute && !s.discordSelfDeaf
    }

    /// A pause (1.5 s with nobody speaking), a mute, or the end of the call: play what waited.
    private func releaseDeferred(after delay: Double = 1.5) {
        guard deferred != nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, let name = self.deferred, !self.conversationGoing else { return }
            self.deferred = nil
            SoundEngine.shared.play(name)
        }
    }

    // MARK: Voice

    private func voiceChanged(_ v: DiscordVoice?) {
        let old = previous
        previous = v
        let me = AppState.shared.discordMe
        switch (old, v) {
        case (nil, let new?):
            callStarted(new)
        case (let o?, nil):
            callEnded(o)
        case (let o?, let new?) where o.channelId != new.channelId:
            callEnded(o)
            callStarted(new)
        case (let o?, let new?):
            for m in new.members { names[m.id] = m.name }
            let before = Set(o.members.map(\.id)), after = Set(new.members.map(\.id))
            for id in after.subtracting(before) where id != me {
                let name = names[id] ?? "?"
                AppState.shared.showToast(String(localized: "\(name) joined"), color: "#23A55A", icon: "person.fill.badge.plus")
                AppState.shared.discordEvent = DiscordEvent(kind: .joined)
                highFiveIfMochi(id: id, name: name)
            }
            for id in before.subtracting(after) where id != me {
                AppState.shared.showToast(String(localized: "\(names[id] ?? "?") left"), color: "#8E939C", icon: "person.fill.badge.minus")
                AppState.shared.discordEvent = DiscordEvent(kind: .left)
            }
            // Talking time: a speaking set that changed opens or closes a stretch.
            let now = Date()
            for id in new.speaking.subtracting(o.speaking) { talkStart[id] = now }
            for id in o.speaking.subtracting(new.speaking) { closeTalk(id, now) }
            if new.speaking.isEmpty { releaseDeferred() }
        default:
            break
        }
    }

    private func callStarted(_ v: DiscordVoice) {
        started = Date()
        talkStart = [:]
        talked = [:]
        highFived = []
        missed = 0
        for m in v.members { names[m.id] = m.name }
        for m in v.members where m.id != AppState.shared.discordMe { highFiveIfMochi(id: m.id, name: m.name) }
        let state = AppState.shared
        if Self.on(Self.pauseSpotifyKey), state.spotifyNow?.playing == true {
            SpotifyWatcher.control("pause")
            pausedSpotify = true
        }
        micFollow(muted: state.discordSelfMute || state.discordSelfDeaf)
    }

    private func callEnded(_ v: DiscordVoice) {
        let now = Date()
        for id in talkStart.keys { closeTalk(id, now) }
        let state = AppState.shared
        let minutes = Int(((now.timeIntervalSince(started ?? now)) / 60).rounded())
        let total = talked.values.reduce(0, +)
        let me = state.discordMe ?? ""
        let myShare = total > 0 ? (talked[me] ?? 0) / total : 0
        let topEntry = talked.filter { $0.key != me }.max { $0.value < $1.value }
        let transcript = DiscordMic.shared.takeTranscript()
        started = nil
        releaseDeferred(after: 0.3)
        micFollow(muted: true)
        if pausedSpotify {
            pausedSpotify = false
            if state.spotifyNow?.playing == false { SpotifyWatcher.control("play") }
        }
        guard minutes >= 1 || total > 0 else { return }
        state.discordTranscript = transcript.isEmpty ? nil : transcript
        state.discordLastCall = DiscordCallSummary(
            minutes: max(1, minutes), myShare: myShare,
            top: topEntry.map { names[$0.key] ?? "?" }, topShare: total > 0 ? (topEntry?.value ?? 0) / total : 0,
            missed: missed, hasTranscript: !transcript.isEmpty, endedAt: now)
        var line = String(localized: "Call · \(max(1, minutes)) min")
        if total > 0 { line += " · " + String(localized: "you \(Int((myShare * 100).rounded())) %") }
        if missed > 0 { line += " · " + String(localized: "\(missed) alerts") }
        state.showToast(line, color: "#5865F2", icon: "phone.down.fill", seconds: 5)
    }

    private func closeTalk(_ id: String, _ now: Date) {
        guard let s = talkStart.removeValue(forKey: id) else { return }
        talked[id, default: 0] += now.timeIntervalSince(s)
    }

    /// ponytail: a LAN Mochi is "in the call" when its name matches a participant's
    /// (case-insensitive) — no Discord id on the wire; add one to LanWire if names collide.
    private func highFiveIfMochi(id: String, name: String) {
        guard !highFived.contains(id) else { return }
        let peers = AppState.shared.lanSnapshot.peers.filter { $0.paired && $0.online }
        guard peers.contains(where: { $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame })
        else { return }
        highFived.insert(id)
        AppState.shared.showToast(String(localized: "🙌 \(name) has a Mochi too"), color: "#F472B6", icon: nil)
        AppState.shared.discordEvent = DiscordEvent(kind: .highFive)
    }

    // MARK: Mic, lock

    private func micFollow(muted: Bool) {
        DiscordMic.shared.update(inCall: started != nil, muted: muted)
        if !muted { AppState.shared.discordTalkingMuted = false }
        if muted { releaseDeferred(after: 0.2) }
    }

    /// Settings toggled a mic option: start or stop listening now.
    func refreshMic() {
        let s = AppState.shared
        micFollow(muted: s.discordSelfMute || s.discordSelfDeaf)
    }

    private func locked(_ isLocked: Bool) {
        let state = AppState.shared
        guard Self.on(Self.lockMuteKey), started != nil else { return }
        if isLocked, !state.discordSelfMute {
            DiscordService.shared.setMute(true)
            mutedByLock = true
        } else if !isLocked, mutedByLock {
            mutedByLock = false
            DiscordService.shared.setMute(false)
            state.showToast(String(localized: "Mic back on"), color: "#23A55A", icon: "mic.fill")
        }
    }

    /// From DiscordMic: speech while Discord has the user muted.
    func talkingWhileMuted() {
        let state = AppState.shared
        state.discordTalkingMuted = true
        state.discordEvent = DiscordEvent(kind: .talkingMuted)
        state.showToast(String(localized: "You're muted!"), color: "#DA373C", icon: "mic.slash.fill")
        // The card has the unmute button: bring it up.
        state.focusId = DiscordService.taskId
        NotificationCenter.default.post(name: .hookExpand, object: IslandView.overview)
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { state.discordTalkingMuted = false }
    }

    // MARK: Presence

    static func pushPresence() {
        guard on(presenceKey) else {
            DiscordService.shared.setActivity(nil)
            return
        }
        let state = AppState.shared
        let agents = ["integration_claude", "integration_codex", "integration_opencode"]
        if let t = state.tasks.first(where: { agents.contains($0.id) && [.working, .thinking].contains($0.state) }) {
            let who = CodingAgent.forTask(t.id)?.displayName ?? "Claude Code"
            DiscordService.shared.setActivity((String(localized: "🤖 \(who) is working"), String(localized: "on \(t.name)")))
        } else if let track = state.spotifyNow, track.playing {
            DiscordService.shared.setActivity(("🎧 \(track.title)", track.artist.isEmpty ? nil : String(localized: "by \(track.artist)")))
        } else {
            DiscordService.shared.setActivity(nil)
        }
    }
}
#endif
