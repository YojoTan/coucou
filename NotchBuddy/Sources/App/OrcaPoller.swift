import Foundation
import Darwin
import AppKit

// MARK: - OrcaPoller (GitHub build) — after upstream PR #33 (OrcaService)
// Orca, the coding-agent orchestrator, runs a local runtime its CLI talks to
// over a Unix socket: newline-delimited JSON-RPC, authenticated with the
// authToken in ~/Library/Application Support/orca/orca-runtime.json. Every 5 s,
// while the Orca pill is on, Coucou asks it for `worktree.ps`: a worktree that
// starts waiting for a permission raises an approval badge, one that finishes
// gets a ✓. Same model as the Windows build (orca.rs).
//
// Permissions are answered in Orca, never from here: a row click focuses the
// agent's terminal there. A worktree whose agent already reports to Coucou
// through its hooks (AgentSessions) is listed but doesn't alert twice.
//
// Orchestration questions (`orchestration ask`) and decision gates are the one
// thing answered from the notch: they wait on the Run's coordinator, and the
// answer goes out through the `orca` CLI as that coordinator, only on a click.
//
// The token goes only to a socket whose peer is this same user (getpeereid).

#if !APPSTORE
struct OrcaWorktree: Sendable, Identifiable, Equatable {
    let id: String
    let name: String
    let repo: String
    let path: String
    let status: String      // working | permission | done | active | inactive
    let agent: String
    let paneKey: String     // "<tabId>:<leafId>" of the agent's terminal pane
    let prompt: String
    let tool: String
    let lastMessage: String
}

/// A question a worker asked its Run, or a pending decision gate.
struct OrcaAsk: Sendable, Identifiable, Equatable {
    enum Kind: Sendable { case question, gate }
    let id: String
    let kind: Kind
    let runId: String
    let coordinator: String?   // the Run's coordinator handle, answered as
    let text: String
    let options: [String]
}

final class OrcaPoller: @unchecked Sendable {
    static let shared = OrcaPoller()
    static let taskId = "integration_orca"
    private var timer: DispatchSourceTimer?
    private var seen: [String: String]? = nil   // main queue only
    private var seenAsks: Set<String>? = nil    // main queue only
    private init() {}

    func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        t.schedule(deadline: .now() + 6, repeating: 5)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private func tick() {
        DispatchQueue.main.async {
            // Only while the user has the Orca pill on.
            guard AppState.shared.tasks.contains(where: { $0.id == Self.taskId }) else { return }
            DispatchQueue.global(qos: .utility).async {
                let rows = Self.query()
                let asks = rows == nil ? [] : Self.queryAsks()
                DispatchQueue.main.async { self.consume(rows, asks) }
            }
        }
    }

    private static var runtimeURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/orca/orca-runtime.json")
    }

    /// One JSON-RPC round trip; the `result` object, nil when Orca isn't reachable or can't be trusted.
    static func rpc(_ method: String, _ params: [String: Any]) -> [String: Any]? {
        guard let data = try? Data(contentsOf: runtimeURL),
              let meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = meta["authToken"] as? String,
              let transports = meta["transports"] as? [[String: Any]],
              let endpoint = transports.first(where: { $0["kind"] as? String == "unix" })?["endpoint"] as? String
        else { return nil }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let cpath = Array(endpoint.utf8CString)
        guard cpath.count <= MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, c) in cpath.enumerated() where i < raw.count { raw[i] = UInt8(bitPattern: c) }
        }
        var tv = timeval(tv_sec: 4, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let rc = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else { return nil }
        // The token only goes to a server running as this same user.
        var peerUID = uid_t(0)
        var peerGID = gid_t(0)
        guard getpeereid(fd, &peerUID, &peerGID) == 0, peerUID == getuid() else { return nil }

        let request: [String: Any] = [
            "id": "coucou-\(method)", "authToken": token, "method": method, "params": params,
        ]
        guard var payload = try? JSONSerialization.data(withJSONObject: request) else { return nil }
        payload.append(UInt8(ascii: "\n"))
        let sent = payload.withUnsafeBytes { buf in Darwin.write(fd, buf.baseAddress, buf.count) }
        guard sent == payload.count else { return nil }

        var raw = Data()
        var buf = [UInt8](repeating: 0, count: 65536)
        while raw.count <= 4_000_000 {
            let n = recv(fd, &buf, buf.count, 0)
            if n <= 0 { break }
            raw.append(contentsOf: buf[0..<n])
            if raw.contains(UInt8(ascii: "\n")) { break }
        }
        let end = raw.firstIndex(of: UInt8(ascii: "\n")) ?? raw.endIndex
        guard let json = try? JSONSerialization.jsonObject(with: raw[raw.startIndex..<end]) as? [String: Any],
              json["ok"] as? Bool == true
        else { return nil }
        return json["result"] as? [String: Any]
    }

    /// `worktree.ps`; nil when Orca isn't reachable.
    static func query() -> [OrcaWorktree]? {
        guard let list = rpc("worktree.ps", ["limit": 50])?["worktrees"] as? [[String: Any]] else { return nil }
        return parse(list)
    }

    static func oneLine(_ s: String, _ max: Int) -> String {
        String(s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").prefix(max))
    }

    static func parse(_ list: [[String: Any]]) -> [OrcaWorktree] {
        let rows: [OrcaWorktree] = list.compactMap { w in
            guard (w["isArchived"] as? Bool) != true,
                  let id = w["worktreeId"] as? String, !id.isEmpty else { return nil }
            let agents = w["agents"] as? [[String: Any]] ?? []
            let agent = agents.first { ["blocked", "waiting", "working"].contains($0["state"] as? String ?? "") } ?? agents.first
            var name = w["displayName"] as? String ?? ""
            if name.isEmpty { name = w["branch"] as? String ?? "" }
            let prompt = (agent?["prompt"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (agent?["taskTitle"] as? String ?? "")
            return OrcaWorktree(
                id: id, name: name, repo: w["repo"] as? String ?? "",
                path: w["path"] as? String ?? "",
                status: w["status"] as? String ?? "",
                agent: agent?["agentType"] as? String ?? "",
                paneKey: agent?["paneKey"] as? String ?? "",
                prompt: oneLine(prompt, 160),
                tool: oneLine(agent?["toolName"] as? String ?? "", 60),
                lastMessage: oneLine(agent?["lastAssistantMessage"] as? String ?? "", 200)
            )
        }
        let rank = ["permission": 0, "working": 1, "done": 2, "active": 3]
        return rows.sorted { (rank[$0.status] ?? 4) < (rank[$1.status] ?? 4) }
    }

    /// Unanswered worker questions and pending gates, across the live Runs.
    static func queryAsks() -> [OrcaAsk] {
        let runs = (rpc("orchestration.runList", [:])?["runs"] as? [[String: Any]] ?? [])
            .filter { ($0["legacy"] as? Int ?? 0) == 0 }
        guard !runs.isEmpty else { return [] }
        var coordinators: [String: String] = [:]
        for r in runs { if let id = r["id"] as? String { coordinators[id] = r["coordinator_handle"] as? String } }

        var asks: [OrcaAsk] = []
        // ponytail: an answered question is one with a later message in its thread;
        // the inbox window is the last 100 messages, ask Orca for question status if that misses.
        let messages = rpc("orchestration.inbox", ["limit": 100])?["messages"] as? [[String: Any]] ?? []
        let threaded = Set(messages.compactMap { m -> String? in
            guard let t = m["thread_id"] as? String, t != m["id"] as? String else { return nil }
            return t
        })
        for m in messages where m["type"] as? String == "question" {
            guard let id = m["id"] as? String, !threaded.contains(id),
                  let run = m["run_id"] as? String, coordinators.keys.contains(run) else { continue }
            let payload = (m["payload"] as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
            asks.append(OrcaAsk(id: id, kind: .question, runId: run, coordinator: coordinators[run] ?? nil,
                                text: oneLine(m["body"] as? String ?? "", 300),
                                options: payload?["options"] as? [String] ?? []))
        }
        for (run, coordinator) in coordinators {
            let gates = rpc("orchestration.gateList", ["run": run, "status": "pending"])?["gates"] as? [[String: Any]] ?? []
            for g in gates {
                guard let id = g["id"] as? String else { continue }
                asks.append(OrcaAsk(id: id, kind: .gate, runId: run, coordinator: coordinator,
                                    text: oneLine(g["question"] as? String ?? "", 300),
                                    options: options(g["options"])))
            }
        }
        return asks
    }

    /// Gate options arrive as an array or as the JSON text of one.
    private static func options(_ v: Any?) -> [String] {
        if let a = v as? [String] { return a }
        if let s = v as? String, let a = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String] { return a }
        return []
    }

    /// Main queue: state, alerts for new permissions, finishes and questions.
    @MainActor
    private func consume(_ rows: [OrcaWorktree]?, _ asks: [OrcaAsk]) {
        let state = AppState.shared
        guard let rows else {
            state.orcaError = String(localized: "Orca isn't running on this Mac.")
            return
        }
        state.orcaError = nil
        if state.orcaWorktrees != rows { state.orcaWorktrees = rows }
        consumeAsks(asks)
        let previous = seen
        seen = Dictionary(rows.map { ($0.id, $0.status) }, uniquingKeysWith: { a, _ in a })
        guard let previous, let idx = state.tasks.firstIndex(where: { $0.id == Self.taskId }) else { return }
        // Agents already reporting through hooks alert from their own pill.
        let sessions = AgentSessions.shared
        let fresh = rows.filter { !sessions.covers(path: $0.path) }
        let attention = fresh.filter { $0.status == "permission" && previous[$0.id] != "permission" }
        let finished = fresh.first { $0.status == "done" && previous[$0.id] == "working" }
        let focused = state.focusId == Self.taskId
        if let w = attention.first {
            let waiting = rows.filter { $0.status == "permission" }.count
            state.tasks[idx].state = .approval
            state.tasks[idx].steps = waiting > 1
                ? [String(localized: "\(waiting) worktrees need permission"), attention.map(\.name).joined(separator: " · ")]
                : [String(localized: "\(w.name) needs permission"), [w.tool, w.prompt].filter { !$0.isEmpty }.joined(separator: " · ")]
            state.tasks[idx].stepIndex = 1
            if !focused { state.tasks[idx].pillBadge = .approval }
            SoundEngine.shared.play("approval")
            NotificationCenter.default.post(name: .hookReveal, object: nil)
        } else if let w = finished {
            state.tasks[idx].state = .finished
            state.tasks[idx].steps = [String(localized: "\(w.name) finished"), w.lastMessage.isEmpty ? w.prompt : w.lastMessage]
            state.tasks[idx].stepIndex = 1
            if !focused { state.tasks[idx].pillBadge = .finished }
            SoundEngine.shared.play("finish")
        } else if !rows.contains(where: { $0.status == "permission" }), state.tasks[idx].state == .approval {
            state.tasks[idx].state = .idle
            state.tasks[idx].pillBadge = nil
        }
    }

    /// A question or gate seen for the first time opens the ask view; one answered
    /// elsewhere (in Orca, or by the coordinator agent) closes it.
    @MainActor
    private func consumeAsks(_ asks: [OrcaAsk]) {
        let state = AppState.shared
        let previous = seenAsks
        seenAsks = Set(asks.map(\.id))
        if state.orcaAsks != asks { state.orcaAsks = asks }
        if let shown = state.orcaAsk, !asks.contains(where: { $0.id == shown.id }) {
            state.orcaAsk = nil
            if state.view == .question {
                state.isPinned = false
                state.view = state.tasks.isEmpty ? .empty : .overview
            }
        }
        guard let previous, state.orcaAsk == nil,
              let ask = asks.first(where: { !previous.contains($0.id) }) else { return }
        state.orcaAsk = ask
        state.isPinned = true
        SoundEngine.shared.play("approval")
        NotificationCenter.default.post(name: .hookExpand, object: IslandView.question)
    }

    // MARK: Actions (all on a click)

    /// Row click: Orca to the front, on the agent's terminal when it can be found.
    static func focus(_ w: OrcaWorktree) {
        openOrca()
        DispatchQueue.global(qos: .userInitiated).async {
            let terminals = rpc("terminal.list", [:])?["terminals"] as? [[String: Any]] ?? []
            let inTree = terminals.filter { $0["worktreeId"] as? String == w.id }
            let leaf = w.paneKey.split(separator: ":").last.map(String.init)
            guard let handle = (inTree.first { $0["leafId"] as? String == leaf } ?? inTree.first)?["handle"] as? String
            else { return }
            _ = rpc("terminal.focus", ["terminal": handle, "navigation": "host"])
        }
    }

    /// The worktree's git changes, as diffs in Orca's editor.
    static func openChanges(_ w: OrcaWorktree) {
        openOrca()
        DispatchQueue.global(qos: .userInitiated).async {
            _ = cli(["file", "open-changed", "--mode", "diff", "--worktree", "id:\(w.id)"])
        }
    }

    /// Answers a question (`reply`) or resolves a gate as the Run's coordinator.
    /// Calls back on the main queue with nil on success, else Orca's message.
    static func answer(_ ask: OrcaAsk, _ text: String, done: @escaping @MainActor @Sendable (String?) -> Void) {
        var args: [String]
        switch ask.kind {
        case .question: args = ["orchestration", "reply", "--id", ask.id, "--body", text, "--run", ask.runId]
        case .gate:     args = ["orchestration", "gate-resolve", "--id", ask.id, "--resolution", text]
        }
        if let c = ask.coordinator { args += ["--from", c] }
        DispatchQueue.global(qos: .userInitiated).async {
            let error = cli(args)
            DispatchQueue.main.async { done(error) }
        }
    }

    /// Runs the `orca` CLI shipped inside Orca.app with --json; nil on success, else what went wrong.
    private static func cli(_ args: [String]) -> String? {
        let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.stablyai.orca")
            ?? URL(fileURLWithPath: "/Applications/Orca.app")
        let bin = app.appendingPathComponent("Contents/Resources/bin/orca")
        guard FileManager.default.isExecutableFile(atPath: bin.path) else {
            return String(localized: "Orca's command-line tool wasn't found.")
        }
        let p = Process()
        p.executableURL = bin
        p.arguments = args + ["--json"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        do { try p.run() } catch { return error.localizedDescription }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], json["ok"] as? Bool == true {
            return nil
        }
        let text = String(decoding: data, as: UTF8.self)
        let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
            .flatMap { ($0["error"] as? [String: Any])?["message"] as? String }
        return oneLine(message ?? text, 200)
    }

    /// "Open Orca" — the app, by bundle id, else /Applications.
    static func openOrca() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.stablyai.orca") {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Orca.app"))
        }
    }
}
#endif
