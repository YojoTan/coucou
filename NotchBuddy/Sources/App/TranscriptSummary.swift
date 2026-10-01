import Foundation

// MARK: - TranscriptSummary
// "What did Claude Code just do?" — when a session stops, the finished card shows
// the start of Claude's last reply, read locally from the session transcript.
// The path comes in the Stop hook payload, so it is checked first: a .jsonl file
// inside ~/.claude, nothing else. Only the tail of the file is read, and only a
// couple of lines of the last assistant text come out. Same rules as the Windows
// build (transcript.rs).

enum TranscriptSummary {
    private static let tailBytes = 256 * 1024
    private static let maxLength = 220

    /// ~/.claude of the real user (the App Store build is sandboxed and can't read it).
    private static var claudeDir: String {
        let home = getpwuid(getuid()).flatMap { $0.pointee.pw_dir.map { String(cString: $0) } }
            ?? NSHomeDirectory()
        return URL(fileURLWithPath: home).appendingPathComponent(".claude")
            .resolvingSymlinksInPath().standardizedFileURL.path + "/"
    }

    static func lastReply(transcriptPath: String) -> String? {
        let url = URL(fileURLWithPath: transcriptPath).resolvingSymlinksInPath().standardizedFileURL
        guard url.pathExtension == "jsonl", url.path.hasPrefix(claudeDir),
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0)
        guard let data = try? handle.readToEnd(), let text = String(data: data, encoding: .utf8) else { return nil }
        guard let reply = lastAssistantText(text) else { return nil }
        return shorten(reply)
    }

    /// The text of the last assistant message among JSONL lines.
    static func lastAssistantText(_ lines: String) -> String? {
        for line in lines.split(separator: "\n").reversed() {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  obj["type"] as? String == "assistant",
                  let message = obj["message"] as? [String: Any] else { continue }
            var text = ""
            if let s = message["content"] as? String {
                text = s
            } else if let parts = message["content"] as? [[String: Any]] {
                text = parts.filter { $0["type"] as? String == "text" }
                    .compactMap { $0["text"] as? String }
                    .joined(separator: " ")
            }
            let collapsed = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            if !collapsed.isEmpty { return collapsed }
        }
        return nil
    }

    private static func shorten(_ text: String) -> String {
        guard text.count > maxLength else { return text }
        let cut = String(text.prefix(maxLength))
        if let space = cut.lastIndex(of: " ") { return String(cut[..<space]) + "…" }
        return cut + "…"
    }
}
