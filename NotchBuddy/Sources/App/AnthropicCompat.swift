import Foundation

// MARK: - Anthropic-compatible endpoint (after upstream #26)
// A server that speaks Anthropic's Messages API without being Anthropic: a
// gateway such as LiteLLM, or a provider that offers the dialect (DeepSeek,
// Kimi, GLM…). ClaudeService sends it the same requests minus Anthropic's own
// features (web search, betas). Same rules as the Windows build (claude.rs):
//   * https only, plain http only to this Mac;
//   * its own optional key, "anthropic-compat-key" — the official key never
//     goes anywhere but api.anthropic.com.

enum AnthropicCompat {
    static let baseURLKey = "anthropicBaseURL"
    static let modelKey = "anthropicModel"
    static let keychainKey = "anthropic-compat-key"

    struct Preset: Identifiable, Sendable {
        let label: String
        let url: String
        let model: String
        var id: String { url }
    }

    static let presets: [Preset] = [
        Preset(label: "LiteLLM (this Mac)", url: "http://localhost:4000", model: "claude-sonnet-5"),
        Preset(label: "DeepSeek", url: "https://api.deepseek.com/anthropic", model: "deepseek-chat"),
        Preset(label: "Moonshot (Kimi)", url: "https://api.moonshot.ai/anthropic", model: "kimi-k2-turbo-preview"),
        Preset(label: "Z.ai (GLM)", url: "https://api.z.ai/api/anthropic", model: "glm-4.6"),
    ]

    static var baseURL: String { UserDefaults.standard.string(forKey: baseURLKey) ?? "" }
    static var model: String { UserDefaults.standard.string(forKey: modelKey) ?? "" }
    static var isConfigured: Bool { !baseURL.isEmpty && !model.isEmpty }

    /// `…/anthropic`, `…/v1` or `…/v1/messages` → the messages URL; nil when the
    /// base isn't https (or http to this Mac).
    static func endpoint(_ base: String) -> URL? {
        var s = base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard N8nPoller.isAcceptableBaseURL(s) else { return nil }
        while s.hasSuffix("/") { s.removeLast() }
        if s.hasSuffix("/v1/messages") {
            // already complete
        } else if s.hasSuffix("/v1") {
            s += "/messages"
        } else {
            s += "/v1/messages"
        }
        return URL(string: s)
    }
}
