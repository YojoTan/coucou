import Foundation

// MARK: - OpencodePlugin (experimental, GitHub build)
// opencode loads every file in ~/.config/opencode/plugins at startup, so the
// integration is one file: windows/opencode-plugin/coucou.js, shared with the
// Windows build and bundled as a resource. No opencode config is edited, and a
// coucou.js that isn't Coucou's (no version marker) is never overwritten or
// removed. Based on upstream PR #19.

#if !APPSTORE
enum OpencodePlugin {
    struct Status {
        let path: String
        let installed: Bool
        let outdated: Bool
        let foreign: Bool
    }

    private static let marker = "COUCOU_PLUGIN_VERSION"

    static var pluginURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/opencode/plugins/coucou.js")
    }

    /// The plugin this build carries, from the app bundle.
    static var bundledText: String? {
        guard let url = Bundle.main.url(forResource: "coucou", withExtension: "js") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// `const COUCOU_PLUGIN_VERSION = N;` → N.
    static func version(of text: String) -> Int? {
        guard let line = text.split(separator: "\n").first(where: { $0.contains(marker) && $0.contains("=") }),
              let rhs = line.split(separator: "=").last else { return nil }
        return Int(rhs.trimmingCharacters(in: CharacterSet(charactersIn: " ;\t\r")))
    }

    static func status() -> Status {
        let existing = try? String(contentsOf: pluginURL, encoding: .utf8)
        let ours = existing.flatMap { version(of: $0) }
        let shipped = bundledText.flatMap { version(of: $0) }
        return Status(
            path: pluginURL.path,
            installed: ours != nil,
            outdated: ours != nil && shipped != nil && ours! < shipped!,
            foreign: existing != nil && ours == nil
        )
    }

    /// Writes or removes Coucou's plugin. Called only from an explicit click.
    static func apply(install: Bool) throws -> String {
        let url = pluginURL
        let existing = try? String(contentsOf: url, encoding: .utf8)
        if let existing, version(of: existing) == nil {
            throw NSError(domain: "Coucou", code: 3, userInfo: [NSLocalizedDescriptionKey:
                "\(url.path) exists and isn't Coucou's — it was left untouched."])
        }
        if !install {
            if existing != nil { try FileManager.default.removeItem(at: url) }
            return "Removed \(url.path)."
        }
        guard let text = bundledText else {
            throw NSError(domain: "Coucou", code: 4, userInfo: [NSLocalizedDescriptionKey: "The plugin is missing from the app bundle."])
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return "Installed \(url.path). Restart opencode to load it."
    }
}
#endif
