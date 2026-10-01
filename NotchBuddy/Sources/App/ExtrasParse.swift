import Foundation

// MARK: - ExtrasParse — the pure bits of the Extras, tested by tests/ExtrasParseTests.swift

/// Things a Mochi can wear (drawn in MochiAccessories.swift).
enum MochiAccessory: String, CaseIterable, Codable, Sendable {
    case none, cap, hardhat, crown, bow, antenna, glasses, sunglasses, sleepMask, umbrella, scarf
    case pumpkin, santaHat, partyHat      // seasonal (ExtrasParse.season)

    /// Shown in Settings pickers.
    var label: String {
        switch self {
        case .none: return String(localized: "Nothing")
        case .cap: return String(localized: "Cap")
        case .hardhat: return String(localized: "Hard hat")
        case .crown: return String(localized: "Crown")
        case .bow: return String(localized: "Bow")
        case .antenna: return String(localized: "Antenna")
        case .glasses: return String(localized: "Glasses")
        case .sunglasses: return String(localized: "Sunglasses")
        case .sleepMask: return String(localized: "Sleep mask")
        case .umbrella: return String(localized: "Umbrella")
        case .scarf: return String(localized: "Scarf")
        case .pumpkin: return String(localized: "Pumpkin")
        case .santaHat: return String(localized: "Santa hat")
        case .partyHat: return String(localized: "Party hat")
        }
    }

    /// The ones a custom Mochi can pick (the others belong to weather, Focus, trophies).
    static let wearable: [MochiAccessory] = [.none, .cap, .hardhat, .crown, .bow, .antenna, .glasses, .sunglasses, .scarf]
}


enum ExtrasParse {
    /// The seasonal outfit for a day: a party hat on the birthday ("MM-dd"), a
    /// pumpkin the last two weeks of October, a Santa hat in December, else nil.
    static func season(month: Int, day: Int, birthday: String?) -> MochiAccessory? {
        if let b = birthday, b == String(format: "%02d-%02d", month, day) { return .partyHat }
        if month == 10 && day >= 15 { return .pumpkin }
        if month == 12 { return .santaHat }
        return nil
    }

    /// The video-call link in an event's URL, location or notes: Meet, Zoom, Teams, Webex, Around.
    static func meetingLink(in texts: [String?]) -> URL? {
        let pattern = #"https://(?:meet\.google\.com/[a-z0-9\-]+|[a-z0-9\-]*\.?zoom\.us/(?:j|my|w)/[^\s<>"]+|teams\.microsoft\.com/l/meetup-join/[^\s<>"]+|teams\.live\.com/meet/[^\s<>"]+|[a-z0-9\-]+\.webex\.com/[^\s<>"]+|around\.co/[^\s<>"]+)"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        for case let t? in texts {
            let range = NSRange(t.startIndex..., in: t)
            if let m = re.firstMatch(in: t, range: range), let r = Range(m.range, in: t) {
                let link = t[r].trimmingCharacters(in: CharacterSet(charactersIn: ".,;)>"))
                if let url = URL(string: link) { return url }
            }
        }
        return nil
    }

    /// Open-Meteo's WMO weather code, in words and as an SF Symbol.
    static func weather(code: Int, day: Bool) -> (String, String) {
        switch code {
        case 0: return (String(localized: "Clear"), day ? "sun.max.fill" : "moon.stars.fill")
        case 1, 2: return (String(localized: "Partly cloudy"), day ? "cloud.sun.fill" : "cloud.moon.fill")
        case 3: return (String(localized: "Cloudy"), "cloud.fill")
        case 45, 48: return (String(localized: "Fog"), "cloud.fog.fill")
        case 51...57: return (String(localized: "Drizzle"), "cloud.drizzle.fill")
        case 61...67, 80...82: return (String(localized: "Rain"), "cloud.rain.fill")
        case 71...77, 85, 86: return (String(localized: "Snow"), "cloud.snow.fill")
        case 95...99: return (String(localized: "Storm"), "cloud.bolt.rain.fill")
        default: return ("—", "cloud.fill")
        }
    }

    static func isWet(_ code: Int) -> Bool { (51...67).contains(code) || (80...82).contains(code) || (95...99).contains(code) }

    /// What Mochi wears for the weather: an umbrella if rain is here or likely
    /// within two hours, a scarf in the cold, sunglasses on a hot clear day.
    static func weatherAccessory(code: Int, temperature: Double, day: Bool, rainChance: Int) -> MochiAccessory {
        if isWet(code) || rainChance >= 50 { return .umbrella }
        if temperature < 8 { return .scarf }
        if day && code <= 1 && temperature >= 24 { return .sunglasses }
        return .none
    }

    /// A custom Mochi command's output: an "ok:" / "working:" / "warning:" / "error:"
    /// prefix sets the mood, else the exit code does. The text is the first line.
    static func commandOutput(_ output: String, exitCode: Int32) -> (text: String, mood: String) {
        let first = output.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        for mood in ["ok", "working", "warning", "error"] where first.lowercased().hasPrefix(mood + ":") {
            return (String(first.dropFirst(mood.count + 1)).trimmingCharacters(in: .whitespaces), mood)
        }
        return (first.trimmingCharacters(in: .whitespaces), exitCode == 0 ? "ok" : "error")
    }
}
