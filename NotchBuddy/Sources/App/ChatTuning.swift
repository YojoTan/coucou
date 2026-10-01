import AppKit

// MARK: - Chat tuning — the model and the effort picked in the chat itself
// Not the provider's settings: a lighter model or less thinking for a quick
// answer, remembered per engine on this Mac. Same rules as the Windows build
// (tuning.rs): an effort is one of a fixed list, and a model is one plain word —
// it can become a CLI argument, so it never starts with "-" and carries no
// space, quote or shell character.

struct ChatTuning: Equatable, Sendable {
    var model: String?
    var effort: String?

    static let none = ChatTuning(model: nil, effort: nil)
    var isDefault: Bool { model == nil && effort == nil }

    static func validModel(_ s: String) -> Bool {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._:/@+-[]"))
        let t = s.trimmingCharacters(in: .whitespaces)
        return !t.isEmpty && t.count <= 120 && !t.hasPrefix("-")
            && t.unicodeScalars.allSatisfy { $0.isASCII && allowed.contains($0) }
    }

    /// The model override, when it is a valid one.
    var cleanModel: String? {
        guard let m = model?.trimmingCharacters(in: .whitespaces), Self.validModel(m) else { return nil }
        return m
    }

    /// The effort, when this engine takes it.
    func effort(for engine: ChatEngine) -> String? {
        guard let e = effort, Self.efforts(engine).contains(e) else { return nil }
        return e
    }

    static func efforts(_ engine: ChatEngine) -> [String] {
        switch engine {
        case .claude: return ["low", "medium", "high", "xhigh", "max"]
        case .api, .anthropic: return ["low", "medium", "high", "max"]
        case .codex, .openai: return ["low", "medium", "high"]
        case .gemini, .opencode: return []
        }
    }

    static func effortLabel(_ e: String) -> String {
        switch e {
        case "low": return String(localized: "Low")
        case "medium": return String(localized: "Medium")
        case "high": return String(localized: "High")
        case "xhigh": return String(localized: "Extra high")
        case "max": return String(localized: "Max")
        default: return e
        }
    }

    // MARK: Storage — per engine, in this app's preferences

    private static let defaultsKey = "chatTuning"

    static func load(for engine: ChatEngine) -> ChatTuning {
        let all = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: [String: String]] ?? [:]
        let v = all[engine.rawValue] ?? [:]
        return ChatTuning(model: v["model"], effort: v["effort"])
    }

    static func save(_ tuning: ChatTuning, for engine: ChatEngine) {
        var all = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: [String: String]] ?? [:]
        if tuning.isDefault {
            all[engine.rawValue] = nil
        } else {
            var v: [String: String] = [:]
            if let m = tuning.model { v["model"] = m }
            if let e = tuning.effort { v["effort"] = e }
            all[engine.rawValue] = v
        }
        UserDefaults.standard.set(all, forKey: defaultsKey)
    }

    // MARK: Model lists

    struct Choice: Identifiable, Equatable, Sendable {
        let id: String
        let label: String
    }

    /// Claude Code's aliases, which follow the newest model of each size.
    static let claudeAliases = [Choice(id: "opus", label: "Opus"), Choice(id: "sonnet", label: "Sonnet"), Choice(id: "haiku", label: "Haiku")]

    /// `data[].id` (+ `display_name`): both Anthropic's and OpenAI's list shape.
    static func parseModels(_ data: Data) -> [Choice] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = json["data"] as? [[String: Any]] else { return [] }
        var seen = Set<String>()
        return list.compactMap { m -> Choice? in
            guard let id = m["id"] as? String, validModel(id), seen.insert(id).inserted else { return nil }
            return Choice(id: id, label: m["display_name"] as? String ?? id)
        }
        .prefix(60).map { $0 }
    }

    /// What the model menu offers for `engine`: the server's own list when it has one.
    @MainActor
    static func models(for engine: ChatEngine) async -> [Choice] {
        var request: URLRequest
        switch engine {
        case .claude:
            return claudeAliases
        case .api:
            guard let key = KeychainStore.shared.get("anthropic-api-key"),
                  let url = URL(string: "https://api.anthropic.com/v1/models?limit=100") else { return [] }
            request = URLRequest(url: url, timeoutInterval: 6)
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .anthropic:
            guard let messages = AnthropicCompat.endpoint(AnthropicCompat.baseURL),
                  let url = URL(string: messages.absoluteString.replacingOccurrences(of: "/messages", with: "/models"))
            else { return [] }
            request = URLRequest(url: url, timeoutInterval: 6)
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            if let key = KeychainStore.shared.get(AnthropicCompat.keychainKey), !key.isEmpty {
                request.setValue(key, forHTTPHeaderField: "x-api-key")
                request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            }
        case .openai:
            guard let chat = OpenAICompatChat.endpoint(OpenAICompatChat.baseURL),
                  let url = URL(string: chat.absoluteString.replacingOccurrences(of: "/chat/completions", with: "/models"))
            else { return [] }
            request = URLRequest(url: url, timeoutInterval: 6)
            if let key = KeychainStore.shared.get("openai-api-key"), !key.isEmpty {
                request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            }
        case .codex, .gemini, .opencode:
            return []
        }
        guard let (data, response) = try? await NoRedirectSession.shared.session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
        return parseModels(data)
    }

    /// "Other…": asks for a model name. Nil when cancelled or not a valid name.
    @MainActor
    static func askForModel(current: String?) -> String? {
        let alert = NSAlert()
        alert.messageText = String(localized: "Model for this chat")
        alert.informativeText = String(localized: "The model name, as the engine expects it.")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = current ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "Save"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let v = field.stringValue.trimmingCharacters(in: .whitespaces)
        return validModel(v) ? v : nil
    }
}
