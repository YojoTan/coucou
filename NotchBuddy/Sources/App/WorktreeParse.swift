import Foundation

// MARK: - Worktree provider protocol: models and parsing (pure; tests/WorktreeParseTests.swift)
// The protocol is in docs/WORKTREES.md. A repo's provider script tells Coucou
// what it can do (`describe`), which worktrees exist (`list`), and does it
// (`run`, streaming NDJSON events). Coucou only draws the forms and lists.

struct WTOption: Codable, Equatable, Hashable, Sendable {
    let value: String
    let label: String
}

struct WTField: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable { case text, choice, multi, bool }
    let id: String
    let type: Kind
    let label: String
    var required: Bool? = nil
    var placeholder: String? = nil
    var pattern: String? = nil
    var options: [WTOption]? = nil
    var defaultValue: WTValue? = nil

    enum CodingKeys: String, CodingKey { case id, type, label, required, placeholder, pattern, options, defaultValue = "default" }

    /// Nil when the value is acceptable, else why not.
    func problem(with value: WTValue?) -> String? {
        switch (type, value) {
        case (.text, .text(let s)?):
            let t = s.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { return required == true ? String(localized: "\(label) is required.") : nil }
            if let p = pattern, t.range(of: p, options: .regularExpression) == nil {
                return String(localized: "\(label) doesn't look right.")
            }
            return nil
        case (.text, nil), (.choice, nil):
            return required == true ? String(localized: "\(label) is required.") : nil
        case (.multi, .list(let l)?):
            return required == true && l.isEmpty ? String(localized: "Pick at least one \(label).") : nil
        default:
            return nil
        }
    }
}

/// A field's value: text, a list (multi) or a flag.
enum WTValue: Codable, Equatable, Hashable, Sendable {
    case text(String), list([String]), flag(Bool)

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let b = try? c.decode(Bool.self) { self = .flag(b) }
        else if let s = try? c.decode(String.self) { self = .text(s) }
        else { self = .list(try c.decode([String].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .text(let s): try c.encode(s)
        case .list(let l): try c.encode(l)
        case .flag(let b): try c.encode(b)
        }
    }

    var json: Any {
        switch self {
        case .text(let s): return s
        case .list(let l): return l
        case .flag(let b): return b
        }
    }
}

struct WTAction: Codable, Equatable, Identifiable, Sendable {
    enum Scope: String, Codable, Sendable { case repo, worktree }
    let id: String
    let label: String
    let scope: Scope
    var danger: Bool? = nil
    var fields: [WTField]? = nil
}

struct WTDescription: Codable, Equatable, Sendable {
    var version: Int = 1
    var actions: [WTAction] = []
}

struct WTWorktree: Codable, Equatable, Identifiable, Sendable {
    let slug: String
    let path: String
    var branch: String? = nil
    var note: String? = nil
    var id: String { path }
}

struct WTList: Codable, Equatable, Sendable {
    var worktrees: [WTWorktree] = []
}

/// One line of a `run`.
enum WTEvent: Equatable, Sendable {
    case progress(String)
    case terminal(command: String, cwd: String?, title: String?)
    case done(ok: Bool, text: String, risk: [String], canForce: Bool)
}

/// Git's view of a worktree, computed by Coucou for every provider.
struct WTStatus: Equatable, Sendable {
    var dirty = 0          // changed files, the worktree and its submodules
    var unpushed = 0       // commits not on any remote
    var stashes = 0
    var lastCommit: Date? = nil
    var atRisk: Bool { dirty > 0 || unpushed > 0 || stashes > 0 }
}

enum WorktreeParse {
    static func describe(_ data: Data) -> WTDescription? {
        try? JSONDecoder().decode(WTDescription.self, from: data)
    }

    static func list(_ data: Data) -> WTList? {
        try? JSONDecoder().decode(WTList.self, from: data)
    }

    /// One stdout line of a `run`: a JSON event, or plain text shown as progress.
    static func event(_ line: String) -> WTEvent? {
        let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        guard t.hasPrefix("{"), let o = (try? JSONSerialization.jsonObject(with: Data(t.utf8))) as? [String: Any],
              let type = o["type"] as? String else { return .progress(t) }
        switch type {
        case "progress": return .progress(o["text"] as? String ?? "")
        case "terminal":
            guard let cmd = o["command"] as? String, !cmd.isEmpty else { return nil }
            return .terminal(command: cmd, cwd: o["cwd"] as? String, title: o["title"] as? String)
        case "done":
            return .done(ok: o["ok"] as? Bool ?? false, text: o["text"] as? String ?? "",
                         risk: o["risk"] as? [String] ?? [], canForce: o["canForce"] as? Bool ?? false)
        default: return .progress(t)
        }
    }

    /// `git worktree list --porcelain` → worktrees, without the main checkout.
    static func gitWorktrees(_ porcelain: String) -> [WTWorktree] {
        var out: [WTWorktree] = []
        var path: String? = nil, branch: String? = nil, first = true
        func flush() {
            if let p = path, !first { out.append(WTWorktree(slug: (p as NSString).lastPathComponent, path: p, branch: branch)) }
            if path != nil { first = false }
            path = nil; branch = nil
        }
        for line in porcelain.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("worktree ") { flush(); path = String(line.dropFirst(9)) }
            else if line.hasPrefix("branch ") { branch = String(line.dropFirst(7)).replacingOccurrences(of: "refs/heads/", with: "") }
        }
        flush()
        return out
    }

    /// The arguments JSON a `run` gets: the form's values, the worktree, and a force confirmation.
    static func arguments(values: [String: WTValue], worktree: WTWorktree?, force: Bool, confirm: String?) -> String {
        var o: [String: Any] = values.mapValues(\.json)
        if let w = worktree { o["worktree"] = ["slug": w.slug, "path": w.path, "branch": w.branch ?? ""] }
        if force { o["force"] = true }
        if let confirm { o["confirm"] = confirm }
        let data = (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}
