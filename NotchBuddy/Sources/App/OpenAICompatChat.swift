import Foundation

// MARK: - OpenAI-compatible chat
// One `POST {base}/chat/completions` client for any server speaking that dialect:
// a local Ollama or LM Studio, OpenRouter, OpenAI, vLLM, LiteLLM. Same rules as
// the Windows build (openai_chat.rs):
//   * https only, plain http only to this Mac (N8nPoller.isAcceptableBaseURL);
//   * redirects are refused — the key rides in Authorization;
//   * the key is optional and lives in the Keychain as "openai-api-key";
//   * only Coucou's inbox copy of a dropped file is sent.

@MainActor
final class OpenAICompatChat {
    static let shared = OpenAICompatChat()

    static let baseURLKey = "openaiBaseURL"
    static let modelKey = "openaiModel"

    struct Preset: Identifiable, Sendable {
        let label: String
        let url: String
        let model: String
        var id: String { url }
    }

    /// Common servers, with an example model each.
    static let presets: [Preset] = [
        Preset(label: "Ollama (this Mac)", url: "http://localhost:11434/v1", model: "llama3.2"),
        Preset(label: "LM Studio (this Mac)", url: "http://localhost:1234/v1", model: "qwen2.5-7b-instruct"),
        Preset(label: "OpenRouter", url: "https://openrouter.ai/api/v1", model: "anthropic/claude-sonnet-4.5"),
        Preset(label: "OpenAI", url: "https://api.openai.com/v1", model: "gpt-4o-mini"),
    ]

    private var messages: [[String: Any]] = []
    private(set) var isBusy = false

    private let persona = """
    You are Mochi, a small assistant living in the notch of the user's Mac. \
    Answer in the user's language, clearly and completely. \
    Plain text only: no markdown (no **, no #, no bullet dashes), just line breaks.
    """

    static var baseURL: String { UserDefaults.standard.string(forKey: baseURLKey) ?? "" }
    static var model: String { UserDefaults.standard.string(forKey: modelKey) ?? "" }
    static var isConfigured: Bool { !baseURL.isEmpty && !model.isEmpty }

    func reset() { messages = [] }

    /// `{base}/chat/completions`, whether the base already ends in /v1 or not.
    static func endpoint(_ base: String) -> URL? {
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard N8nPoller.isAcceptableBaseURL(trimmed) else { return nil }
        var s = trimmed
        while s.hasSuffix("/") { s.removeLast() }
        if !s.hasSuffix("/chat/completions") { s += "/chat/completions" }
        return URL(string: s)
    }

    func send(query: String, context: PromptContext?, tuning: ChatTuning = .none) async -> LocalCLIChat.Reply {
        guard !isBusy else { return .init(text: "Still answering the previous message…", isError: true) }
        let base = Self.baseURL, model = tuning.cleanModel ?? Self.model
        guard !base.isEmpty else {
            return .init(text: "Set the endpoint URL in Settings → Chat (e.g. http://localhost:11434/v1 for Ollama).", isError: true)
        }
        guard !model.isEmpty else {
            return .init(text: "Set the model name in Settings → Chat (e.g. llama3.2).", isError: true)
        }
        guard let url = Self.endpoint(base) else {
            return .init(text: "Use https:// — plain http:// is only allowed to this Mac (localhost).", isError: true)
        }
        isBusy = true
        defer { isBusy = false }

        let userContent: Any
        switch buildUserContent(query: query, context: messages.isEmpty ? context : nil) {
        case .success(let c): userContent = c
        case .failure(let e): return .init(text: e.message, isError: true)
        }
        let userMessage: [String: Any] = ["role": "user", "content": userContent]
        var all: [[String: Any]] = [["role": "system", "content": persona]]
        all += messages
        all.append(userMessage)

        var body: [String: Any] = ["model": model, "messages": all, "max_tokens": 4096, "stream": false]
        // The chat's effort, for reasoning models; dropped if the server refuses it.
        let effort = tuning.effort(for: .openai)
        if let effort { body["reasoning_effort"] = effort }
        let key = KeychainStore.shared.get("openai-api-key")
        func request(_ body: [String: Any]) -> URLRequest? {
            guard let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
            var req = URLRequest(url: url, timeoutInterval: 120)
            req.httpMethod = "POST"
            req.httpBody = data
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let key, !key.isEmpty { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
            return req
        }
        guard let req = request(body) else {
            return .init(text: "Could not build the request.", isError: true)
        }

        do {
            var (respData, response) = try await NoRedirectSession.shared.session.data(for: req)
            var status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if effort != nil, status == 400, String(data: respData, encoding: .utf8)?.contains("reasoning") == true {
                body["reasoning_effort"] = nil
                if let again = request(body) {
                    (respData, response) = try await NoRedirectSession.shared.session.data(for: again)
                    status = (response as? HTTPURLResponse)?.statusCode ?? 0
                }
            }
            let json = (try? JSONSerialization.jsonObject(with: respData)) as? [String: Any]
            if !(200..<300).contains(status) {
                let detail = Self.errorText(json) ?? String(data: respData.prefix(200), encoding: .utf8) ?? ""
                return .init(text: "Endpoint \(status): \(detail)", isError: true)
            }
            if let err = Self.errorText(json) { return .init(text: err, isError: true) }
            guard let text = Self.replyText(json), !text.isEmpty else {
                return .init(text: "No response text.", isError: true)
            }
            messages.append(userMessage)
            messages.append(["role": "assistant", "content": text])
            return .init(text: text, isError: false)
        } catch {
            return .init(text: "Can't reach \(url.absoluteString): \(error.localizedDescription)", isError: true)
        }
    }

    /// One question with no history (a paired Mochi asking this one).
    static func oneShot(query: String) async -> LocalCLIChat.Reply {
        guard isConfigured, let url = endpoint(baseURL) else {
            return .init(text: "This Mochi has no chat engine set up.", isError: true)
        }
        let body: [String: Any] = ["model": model, "max_tokens": 2048, "stream": false,
                                   "messages": [["role": "user", "content": query]]]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else {
            return .init(text: "Could not build the request.", isError: true)
        }
        var req = URLRequest(url: url, timeoutInterval: 120)
        req.httpMethod = "POST"
        req.httpBody = data
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key = KeychainStore.shared.get("openai-api-key"), !key.isEmpty {
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        guard let (respData, response) = try? await NoRedirectSession.shared.session.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let text = replyText((try? JSONSerialization.jsonObject(with: respData)) as? [String: Any]), !text.isEmpty
        else { return .init(text: "No answer.", isError: true) }
        return .init(text: text, isError: false)
    }

    private struct ContentError: Error { let message: String }

    private func buildUserContent(query: String, context: PromptContext?) -> Result<Any, ContentError> {
        var text = ""
        var imageURL: String?
        switch context {
        case .file(let name, let fileURL):
            let inbox = HookServer.supportDir.appendingPathComponent("inbox").standardizedFileURL.path + "/"
            guard let fileURL, fileURL.standardizedFileURL.path.hasPrefix(inbox) else {
                return .failure(ContentError(message: "That file is not in Coucou's inbox yet — drop it again."))
            }
            let ext = fileURL.pathExtension.lowercased()
            let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? Int.max
            if ["png", "jpg", "jpeg", "gif", "webp"].contains(ext) {
                guard size <= 20_000_000, let data = try? Data(contentsOf: fileURL) else {
                    return .failure(ContentError(message: "That image is too large to send."))
                }
                let mime = ext == "jpg" ? "jpeg" : ext
                imageURL = "data:image/\(mime);base64,\(data.base64EncodedString())"
                text += "The user attached an image: \(name)\n\n"
            } else if ext == "pdf" {
                return .failure(ContentError(message: "PDFs need the Anthropic API or a CLI engine — this endpoint only takes text and images."))
            } else {
                guard size <= 200_000, let body = try? String(contentsOf: fileURL, encoding: .utf8) else {
                    return .failure(ContentError(message: "That file is too large, or not text this endpoint can read."))
                }
                text += "The user attached a file: \(name)\nFile contents:\n\(body)\n\n"
            }
        case .window(let app, let title, let url):
            text += "Context — App: \(app), Window: \(title)"
            if let url { text += ", URL: \(url)" }
            text += "\n\n"
        case nil:
            break
        }
        text += query
        if let imageURL {
            return .success([
                ["type": "text", "text": text],
                ["type": "image_url", "image_url": ["url": imageURL]],
            ] as [[String: Any]])
        }
        return .success(text)
    }

    /// choices[0].message.content — a string, or an array of text parts.
    static func replyText(_ json: [String: Any]?) -> String? {
        guard let choices = json?["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any] else { return nil }
        if let s = message["content"] as? String {
            return s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let parts = message["content"] as? [[String: Any]] {
            return parts.compactMap { $0["text"] as? String }.joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    static func errorText(_ json: [String: Any]?) -> String? {
        if let e = json?["error"] as? [String: Any] { return e["message"] as? String }
        return json?["error"] as? String
    }
}

/// A URLSession that never follows redirects: a 3xx comes back as the response.
final class NoRedirectSession: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = NoRedirectSession()
    lazy var session: URLSession = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}
