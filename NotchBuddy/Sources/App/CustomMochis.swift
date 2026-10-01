import Foundation
import Darwin
import AppIntents

// MARK: - Custom Mochis (GitHub build)
// Mochis the user makes in Settings › Extras: a name, a colour, something to
// wear, and where their news comes from —
//
// • a shell command, run every N seconds while the pill is on: the first line
//   of its output is the text; an "ok:", "working:", "warning:" or "error:"
//   prefix sets the mood, else the exit code does (0 fine, else error);
// • a local URL any script can call:
//     curl -H "X-Coucou-Token: <token>" -d "Build OK" http://127.0.0.1:47823/mochi/<name>
//   (JSON works too: {"text": "...", "state": "working"}). Loopback only, and
//   the token header keeps web pages out: a browser can't send a custom header
//   cross-origin without a preflight this server never answers;
// • Shortcuts: "Set a custom Mochi" (SetMochiIntent below), so any Shortcut,
//   automation or Siri can drive one.

#if !APPSTORE
enum CustomState: String, Codable, Sendable, CaseIterable {
    case idle, ok, working, warning, error

    var botState: BotState {
        switch self {
        case .idle: return .idle
        case .ok: return .finished
        case .working: return .working
        case .warning: return .question
        case .error: return .error
        }
    }
}

struct CustomMochi: Codable, Identifiable, Equatable, Sendable {
    var id: String               // "custom_…", also the pill's task id
    var name: String
    var color: String            // hex
    var accessory: MochiAccessory
    var command: String          // empty: news only arrives by URL or Shortcuts
    var interval: Int            // seconds between runs of the command

    /// What the URL calls it: lowercase, dashes.
    var slug: String {
        let allowed = CharacterSet.alphanumerics
        return name.lowercased().folding(options: .diacriticInsensitive, locale: nil)
            .unicodeScalars.map { allowed.contains($0) ? String($0) : "-" }.joined()
            .split(separator: "-").joined(separator: "-")
    }

    static func new() -> CustomMochi {
        CustomMochi(id: "custom_\(UUID().uuidString.prefix(8).lowercased())", name: String(localized: "My Mochi"),
                    color: "#14B8A6", accessory: .cap, command: "", interval: 60)
    }
}

struct CustomStatus: Equatable, Sendable {
    var text: String
    var state: CustomState
    var at: Date
}

enum CustomMochis {
    static let storeKey = "custom-mochis"
    static let port: UInt16 = 47823

    /// All of them, as saved in Settings.
    static var all: [CustomMochi] {
        guard let d = UserDefaults.standard.data(forKey: storeKey),
              let list = try? JSONDecoder().decode([CustomMochi].self, from: d) else { return [] }
        return list
    }

    static func save(_ list: [CustomMochi]) {
        if let d = try? JSONEncoder().encode(list) { UserDefaults.standard.set(d, forKey: storeKey) }
    }

    static func find(_ key: String) -> CustomMochi? {
        let k = key.lowercased()
        return all.first { $0.id == k || $0.slug == k || $0.name.lowercased() == k }
    }

    /// The token the URL wants, made once and kept in the Keychain.
    static var token: String {
        if let t = KeychainStore.shared.get("custom-mochi-token") { return t }
        let t = (0..<24).map { _ in String("abcdefghijkmnopqrstuvwxyz23456789".randomElement()!) }.joined()
        KeychainStore.shared.set("custom-mochi-token", value: t)
        return t
    }

    /// Text and mood from a command's output: an "ok:"-style prefix wins, else the exit code.
    static func parse(output: String, exitCode: Int32) -> (String, CustomState) {
        let r = ExtrasParse.commandOutput(output, exitCode: exitCode)
        return (r.text, CustomState(rawValue: r.mood) ?? .ok)
    }

    /// News for a Mochi, from any source; on the main queue.
    @MainActor
    static func push(_ id: String, text: String, state: CustomState) {
        let s = AppState.shared
        let old = s.customStatus[id]
        s.customStatus[id] = CustomStatus(text: String(text.prefix(140)), state: state, at: Date())
        guard let i = s.tasks.firstIndex(where: { $0.id == id }) else { return }
        s.tasks[i].state = state.botState
        s.tasks[i].steps = text.isEmpty ? [] : [String(text.prefix(140))]
        s.tasks[i].stepIndex = 0
        // A change of mood is news: a toast, and a badge when it isn't the focused one.
        if old?.state != state || old?.text != text, state != .idle {
            let name = all.first { $0.id == id }?.name ?? "Mochi"
            let color = all.first { $0.id == id }?.color ?? "#14B8A6"
            s.showToast("\(name): \(text.isEmpty ? state.rawValue : text)", color: color,
                        icon: state == .error ? "exclamationmark.triangle.fill" : nil)
            if s.focusId != id { s.tasks[i].pillBadge = state == .error ? .error : .finished }
            if state == .error { SoundEngine.shared.play("error") }
        }
    }
}

// MARK: - Runner: commands and the local URL

final class CustomMochiRunner: @unchecked Sendable {
    static let shared = CustomMochiRunner()
    private let q = DispatchQueue(label: "coucou.custom", attributes: .concurrent)
    private var timer: DispatchSourceTimer?
    private var lastRun: [String: Date] = [:]     // main only
    private var running: Set<String> = []        // main only
    private var listenFD: Int32 = -1

    private init() {}

    func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 2, repeating: 1)
        t.setEventHandler { MainActor.assumeIsolated { CustomMochiRunner.shared.tick() } }
        t.resume()
        timer = t
        q.async { self.listen() }
    }

    /// Every second: run the commands that are due, for the pills that are on.
    @MainActor
    private func tick() {
        let on = Set(AppState.shared.tasks.map(\.id))
        for m in CustomMochis.all where on.contains(m.id) && !m.command.isEmpty && !running.contains(m.id) {
            let due = lastRun[m.id].map { Date().timeIntervalSince($0) >= Double(max(5, m.interval)) } ?? true
            if due { run(m) }
        }
    }

    /// "Run now" in the card, or a due tick.
    @MainActor
    func run(_ m: CustomMochi) {
        guard !m.command.isEmpty, !running.contains(m.id) else { return }
        running.insert(m.id)
        lastRun[m.id] = Date()
        let command = m.command, id = m.id
        q.async {
            let (out, code) = Self.shell(command)
            let (text, state) = CustomMochis.parse(output: out, exitCode: code)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    CustomMochiRunner.shared.running.remove(id)
                    CustomMochis.push(id, text: text, state: state)
                }
            }
        }
    }

    /// The user's own command, in their login shell, killed after 30 s.
    private static func shell(_ command: String) -> (String, Int32) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
        p.arguments = ["-lc", command]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        do { try p.run() } catch { return (error.localizedDescription, 127) }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: killer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        return (String(decoding: data.prefix(4096), as: UTF8.self), p.terminationStatus)
    }

    // MARK: Local URL — 127.0.0.1:47823

    private func listen() {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = CustomMochis.port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")     // loopback only, never the network
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, Darwin.listen(fd, 8) == 0 else { close(fd); return }
        listenFD = fd
        while true {
            let client = Darwin.accept(fd, nil, nil)
            if client < 0 { continue }
            q.async { self.serve(client) }
        }
    }

    private func serve(_ fd: Int32) {
        defer { close(fd) }
        var tv = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var raw = Data()
        var buf = [UInt8](repeating: 0, count: 8192)
        // Headers, then as much body as Content-Length says (capped at 16 KB).
        while raw.count < 16_384 {
            let n = recv(fd, &buf, buf.count, 0)
            if n <= 0 { break }
            raw.append(contentsOf: buf[0..<n])
            if let r = raw.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: raw[..<r.lowerBound], as: UTF8.self)
                let length = Self.header(head, "content-length").flatMap(Int.init) ?? 0
                if raw.count - r.upperBound >= min(length, 16_384) { break }
            }
        }
        guard let r = raw.range(of: Data("\r\n\r\n".utf8)) else { return respond(fd, 400, "bad request") }
        let head = String(decoding: raw[..<r.lowerBound], as: UTF8.self)
        let body = String(decoding: raw[r.upperBound...], as: UTF8.self)
        let parts = head.split(separator: "\r\n").first?.split(separator: " ") ?? []
        guard parts.count >= 2 else { return respond(fd, 400, "bad request") }
        guard Self.header(head, "x-coucou-token") == CustomMochis.token else {
            return respond(fd, 401, "missing or wrong X-Coucou-Token (Settings › Extras)")
        }
        guard parts[0] == "POST" else { return respond(fd, 405, "POST /mochi/<name>") }
        let path = parts[1].split(separator: "?").first.map(String.init) ?? ""
        guard path.hasPrefix("/mochi/"), let m = CustomMochis.find(String(path.dropFirst(7)).removingPercentEncoding ?? "") else {
            return respond(fd, 404, "no such Mochi")
        }
        var text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        var state = CustomState.ok
        if let json = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] {
            text = json["text"] as? String ?? ""
            state = (json["state"] as? String).flatMap(CustomState.init) ?? .ok
        } else {
            let parsed = CustomMochis.parse(output: text, exitCode: 0)
            text = parsed.0
            state = parsed.1
        }
        let id = m.id, t = text, st = state
        DispatchQueue.main.async { MainActor.assumeIsolated { CustomMochis.push(id, text: t, state: st) } }
        respond(fd, 200, "ok")
    }

    private static func header(_ head: String, _ name: String) -> String? {
        for line in head.split(separator: "\r\n").dropFirst() {
            let kv = line.split(separator: ":", maxSplits: 1)
            if kv.count == 2, kv[0].trimmingCharacters(in: .whitespaces).lowercased() == name {
                return kv[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private func respond(_ fd: Int32, _ code: Int, _ message: String) {
        let reason = [200: "OK", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found", 405: "Method Not Allowed"][code] ?? "Error"
        let body = message + "\n"
        let resp = "HTTP/1.1 \(code) \(reason)\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        _ = resp.withCString { send(fd, $0, strlen($0), 0) }
    }
}

// MARK: - Shortcuts

enum CustomStateEntity: String, AppEnum {
    case ok, working, warning, error, idle
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Mochi mood"
    static let caseDisplayRepresentations: [CustomStateEntity: DisplayRepresentation] = [
        .ok: "Fine", .working: "Working", .warning: "Warning", .error: "Error", .idle: "Idle",
    ]
}

struct SetMochiIntent: AppIntent {
    static let title: LocalizedStringResource = "Set a custom Mochi"
    static let description = IntentDescription("Gives one of your custom Mochis a line of text and a mood.")

    @Parameter(title: "Mochi name") var mochi: String
    @Parameter(title: "Text", default: "") var text: String
    @Parameter(title: "Mood", default: .ok) var mood: CustomStateEntity

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let m = CustomMochis.find(mochi) else {
            return .result(dialog: IntentDialog(stringLiteral: String(localized: "No custom Mochi named \(mochi).")))
        }
        CustomMochis.push(m.id, text: text, state: CustomState(rawValue: mood.rawValue) ?? .ok)
        return .result(dialog: IntentDialog(stringLiteral: String(localized: "\(m.name) updated.")))
    }
}

/// What the Focus automations set (Settings › Extras explains how).
enum FocusModeEntity: String, AppEnum {
    case normal, doNotDisturb, work, sleep
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Mochi mode"
    static let caseDisplayRepresentations: [FocusModeEntity: DisplayRepresentation] = [
        .normal: "Normal", .doNotDisturb: "Do Not Disturb", .work: "Work", .sleep: "Sleep",
    ]
}

struct SetMochiModeIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Mochi's mode"
    static let description = IntentDescription("Do Not Disturb and Sleep put a mask on Mochi and keep Coucou quiet; Work puts glasses on.")

    @Parameter(title: "Mode", default: .normal) var mode: FocusModeEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        AppState.shared.focusMode = FocusMode(rawValue: mode.rawValue) ?? .normal
        return .result()
    }
}

struct CoucouShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: SetMochiModeIntent(), phrases: ["Set \(.applicationName) mode"],
                    shortTitle: "Mochi mode", systemImageName: "moon.zzz")
        AppShortcut(intent: SetMochiIntent(), phrases: ["Update a \(.applicationName) Mochi"],
                    shortTitle: "Custom Mochi", systemImageName: "face.smiling")
    }
}
#endif

/// Mochi's mode, from a Focus automation (SetMochiModeIntent).
enum FocusMode: String, Codable, Sendable {
    case normal, doNotDisturb, work, sleep

    /// Do Not Disturb and Sleep: no sounds, no toasts.
    var silences: Bool { self == .doNotDisturb || self == .sleep }
}
