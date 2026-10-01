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
// Read-only: permissions are answered in Orca ("Open Orca"), never from here.
// The token goes only to a socket whose peer is this same user (getpeereid).

#if !APPSTORE
struct OrcaWorktree: Sendable, Identifiable, Equatable {
    let id: String
    let name: String
    let repo: String
    let status: String      // working | permission | done | active | inactive
    let agent: String
    let prompt: String
    let tool: String
    let lastMessage: String
}

final class OrcaPoller: @unchecked Sendable {
    static let shared = OrcaPoller()
    static let taskId = "integration_orca"
    private var timer: DispatchSourceTimer?
    private var seen: [String: String]? = nil   // main queue only
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
                let result = Self.query()
                DispatchQueue.main.async { self.consume(result) }
            }
        }
    }

    private static var runtimeURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/orca/orca-runtime.json")
    }

    /// One `worktree.ps` round trip; nil when Orca isn't reachable or can't be trusted.
    static func query() -> [OrcaWorktree]? {
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
            "id": "coucou-ps", "authToken": token, "method": "worktree.ps", "params": ["limit": 50],
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
              json["ok"] as? Bool == true,
              let result = json["result"] as? [String: Any],
              let list = result["worktrees"] as? [[String: Any]]
        else { return nil }
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
                status: w["status"] as? String ?? "",
                agent: agent?["agentType"] as? String ?? "",
                prompt: oneLine(prompt, 160),
                tool: oneLine(agent?["toolName"] as? String ?? "", 60),
                lastMessage: oneLine(agent?["lastAssistantMessage"] as? String ?? "", 200)
            )
        }
        let rank = ["permission": 0, "working": 1, "done": 2, "active": 3]
        return rows.sorted { (rank[$0.status] ?? 4) < (rank[$1.status] ?? 4) }
    }

    /// Main queue: state, alerts for new permissions and finishes.
    @MainActor
    private func consume(_ rows: [OrcaWorktree]?) {
        let state = AppState.shared
        guard let rows else {
            state.orcaError = String(localized: "Orca isn't running on this Mac.")
            return
        }
        state.orcaError = nil
        state.orcaWorktrees = Array(rows.prefix(6))
        let previous = seen
        seen = Dictionary(rows.map { ($0.id, $0.status) }, uniquingKeysWith: { a, _ in a })
        guard let previous, let idx = state.tasks.firstIndex(where: { $0.id == Self.taskId }) else { return }

        let attention = rows.first { $0.status == "permission" && previous[$0.id] != "permission" }
        let finished = rows.first { $0.status == "done" && previous[$0.id] == "working" }
        let focused = state.focusId == Self.taskId
        if let w = attention {
            state.tasks[idx].state = .approval
            state.tasks[idx].steps = [String(localized: "\(w.name) needs permission"), [w.tool, w.prompt].filter { !$0.isEmpty }.joined(separator: " · ")]
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
