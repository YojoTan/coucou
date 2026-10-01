import Foundation
import AVFoundation

// MARK: - MochiPet — levels, streaks and trophies
// Every coding-agent session that finishes feeds Mochi: it levels up every 10,
// keeps a streak of days in a row, and unlocks things to wear (a bow at 5, up
// to a crown at 100). Left alone three days or more, it looks scruffy and sad
// until the next session. Saved in the preferences; nothing leaves the Mac.

struct MochiPet: Codable, Equatable, Sendable {
    var sessions = 0
    var streak = 0
    var bestStreak = 0
    var lastDay = ""            // yyyy-MM-dd of the last finished session
    var wearing: MochiAccessory? = nil   // nil: the best one unlocked

    static let key = "mochi-pet"
    static let trophies: [(Int, MochiAccessory)] = [(5, .bow), (15, .antenna), (30, .cap), (60, .sunglasses), (100, .crown)]

    var level: Int { 1 + sessions / 10 }
    var unlocked: [MochiAccessory] { Self.trophies.filter { sessions >= $0.0 }.map(\.1) }
    var nextTrophy: (Int, MochiAccessory)? { Self.trophies.first { sessions < $0.0 } }

    /// What the main Mochi wears when nothing else decides.
    var worn: MochiAccessory {
        if let w = wearing, w == .none || unlocked.contains(w) { return w }
        return unlocked.last ?? .none
    }

    /// Three days or more without a finished session.
    var scruffy: Bool {
        guard let last = Self.day.date(from: lastDay) else { return false }
        return (Calendar.current.dateComponents([.day], from: last, to: Date()).day ?? 0) >= 3
    }

    static func load() -> MochiPet {
        guard let d = UserDefaults.standard.data(forKey: key),
              let p = try? JSONDecoder().decode(MochiPet.self, from: d) else { return MochiPet() }
        return p
    }

    func save() {
        if let d = try? JSONEncoder().encode(self) { UserDefaults.standard.set(d, forKey: Self.key) }
    }

    static let day: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// A session finished (HookServer, Stop): the level, the streak, maybe a trophy.
    @MainActor
    static func sessionFinished() {
        let state = AppState.shared
        var p = state.pet
        let before = p
        let today = day.string(from: Date())
        if p.lastDay != today {
            let yesterday = day.string(from: Date().addingTimeInterval(-86_400))
            p.streak = p.lastDay == yesterday ? p.streak + 1 : 1
            p.bestStreak = max(p.bestStreak, p.streak)
            p.lastDay = today
        }
        p.sessions += 1
        p.save()
        state.pet = p
        if let trophy = p.unlocked.last, !before.unlocked.contains(trophy) {
            state.showToast(String(localized: "Unlocked: \(trophy.label)!"), color: "#F7B32B", icon: "gift.fill", seconds: 5)
            state.petEvent = UUID()
            MochiVoice.say(String(localized: "I unlocked a new outfit!"))
        } else if p.level > before.level {
            state.showToast(String(localized: "Mochi reached level \(p.level)!"), color: "#F7B32B", icon: "star.fill", seconds: 4)
            state.petEvent = UUID()
        } else if p.streak > before.streak && p.streak > 1 {
            state.showToast(String(localized: "🔥 \(p.streak)-day streak"), color: "#F97316", icon: nil)
        }
    }
}

// MARK: - MochiVoice — Mochi says it out loud (Settings › Extras, off by default)

@MainActor
enum MochiVoice {
    static let key = "mochi-voice"
    private static let synth = AVSpeechSynthesizer()

    static func say(_ text: String) {
        let state = AppState.shared
        guard UserDefaults.standard.bool(forKey: key), state.soundEnabled, !state.focusMode.silences else { return }
        #if !APPSTORE
        // Not over a Discord call.
        guard state.discordVoice == nil else { return }
        #endif
        let u = AVSpeechUtterance(string: text)
        let lang = Bundle.main.preferredLocalizations.first ?? Locale.preferredLanguages.first ?? "en"
        u.voice = AVSpeechSynthesisVoice(language: lang)
        u.rate = AVSpeechUtteranceDefaultSpeechRate * 1.05
        u.pitchMultiplier = 1.25        // a small voice for a small character
        synth.speak(u)
    }
}
