import Foundation

// MARK: - DiscordParse — the pure bits of DiscordService, tested by tests/DiscordParseTests.swift

enum DiscordReaction: Equatable, Sendable {
    case confetti, hearts, laugh, question, fire
}

enum DiscordParse {
    /// How Mochi reacts to a DM or mention: the first emoji or word that means
    /// something to it, else nil.
    static func reaction(_ text: String) -> DiscordReaction? {
        let t = text.lowercased()
        let table: [(DiscordReaction, [String])] = [
            (.confetti, ["🎉", "🥳", "🎊"]),
            (.hearts, ["❤️", "❤", "😍", "🥰", "💖", "💕", "<3"]),
            (.fire, ["🔥"]),
            (.laugh, ["😂", "🤣", "jaja", "jeje", "haha", "lol", "lmao", "kkkk"]),
        ]
        var best: (DiscordReaction, String.Index)? = nil
        for (reaction, keys) in table {
            for k in keys {
                if let r = t.range(of: k), best == nil || r.lowerBound < best!.1 { best = (reaction, r.lowerBound) }
            }
        }
        if let best { return best.0 }
        return t.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?") ? .question : nil
    }

    /// `lsappinfo`'s `"StatusLabel"={ "label"="21" }` → 21; `"label"="•"` → a dot.
    static func badge(_ s: String) -> (count: Int, dot: Bool) {
        guard let r = s.range(of: #""label"="([^"]*)""#, options: .regularExpression) else { return (0, false) }
        let label = s[r].dropFirst(9).dropLast()
        if let n = Int(label) { return (n, false) }
        return (0, !label.isEmpty)
    }

    /// Only Discord's own webhook URLs, over https: the URL is the credential.
    static func isWebhook(_ s: String) -> Bool {
        guard let u = URL(string: s), u.scheme == "https", let host = u.host?.lowercased() else { return false }
        return ["discord.com", "discordapp.com", "ptb.discord.com", "canary.discord.com"].contains(host)
            && u.path.hasPrefix("/api/webhooks/")
    }
}
