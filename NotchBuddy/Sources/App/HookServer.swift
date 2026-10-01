import Foundation
import Darwin
import AppKit

// MARK: - HookServer
// Listens on a Unix domain socket for events from nb-hook (Claude Code hooks).
// Thread-safe: socket I/O on background threads, state updates dispatched to main queue.

final class HookServer: @unchecked Sendable {
    static let shared = HookServer()

    // Support directory paths
    static var supportDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NotchBuddy")
    }
    static var socketPath: String {
        #if APPSTORE
        // Container home root keeps path ≤ 103 bytes (sun_path limit on macOS is 104 incl. NUL)
        // /Users/louis/Library/Containers/fr.louisraille.Coucou/Data/nb.sock = 66 bytes ✓
        return NSHomeDirectory() + "/nb.sock"
        #else
        return supportDir.appendingPathComponent("nb.sock").path
        #endif
    }
    // hookScriptPath is only used by the non-App Store build.
    // App Store build derives the command from the panel-selected claudeURL in buildHooksData(claudeURL:).
    static var hookScriptPath: String { supportDir.appendingPathComponent("nb-hook").path }

    // No approval blocking state — notch is notification-only, user answers in VS Code

    private var serverFD: Int32 = -1
    private var pendingApprovalFD: Int32 = -1   // held open while user decides
    private var pendingApprovalID: UUID? = nil  // the ApprovalInfo on screen
    private var activeSessionId: String? = nil  // current Claude Code session

    /// Largest hook line accepted. nb-hook sends one JSON line per event.
    private static let maxPayload = 1 << 20

    private init() {}

    // MARK: - Start

    func start() {
        // Ensure support directory exists before socket server tries to bind.
        // Owner-only: it holds the socket and the hook relay Claude Code runs.
        try? FileManager.default.createDirectory(at: Self.supportDir, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700 as NSNumber],
                                               ofItemAtPath: Self.supportDir.path)
        #if !APPSTORE
        installHookScript()
        #endif
        Thread.detachNewThread { self.serverThread() }
    }

    // MARK: - Socket server (background thread)

    private func serverThread() {
        let path = Self.socketPath
        // sun_path on macOS is 104 bytes including the NUL terminator → max 103 usable bytes
        let maxSunPathBytes = MemoryLayout<sockaddr_un>.size - MemoryLayout<sa_family_t>.size - 1
        guard path.utf8.count <= maxSunPathBytes else {
            NSLog("HookServer: socket path too long (\(path.utf8.count) bytes, max \(maxSunPathBytes)): \(path)")
            return
        }
        try? FileManager.default.removeItem(atPath: path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        serverFD = fd

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let cpath = Array(path.utf8CString)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, c) in cpath.enumerated() where i < raw.count { raw[i] = UInt8(bitPattern: c) }
        }

        let bindRC = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bindRC == 0 else { close(fd); return }
        // Owner-only socket: the umask default (usually 0755) is not a promise.
        _ = chmod(path, 0o600)
        guard Darwin.listen(fd, 10) == 0 else { close(fd); return }

        while true {
            let clientFD = Darwin.accept(fd, nil, nil)
            guard clientFD >= 0 else { break }
            Thread.detachNewThread { self.handleClient(fd: clientFD) }
        }
    }

    // MARK: - Client handler (background thread)

    private func handleClient(fd: Int32) {
        // Only our own user may talk to us, whatever the socket's mode says.
        var peerUID = uid_t(0)
        var peerGID = gid_t(0)
        guard getpeereid(fd, &peerUID, &peerGID) == 0, peerUID == getuid() else {
            close(fd)
            return
        }
        // nb-hook writes its line straight away; a silent client must not pin a thread.
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        // Read newline-delimited JSON
        var raw = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        outer: while true {
            let n = recv(fd, &buf, buf.count, 0)
            if n <= 0 { break }
            for i in 0..<n {
                if buf[i] == UInt8(ascii: "\n") { break outer }
                raw.append(buf[i])
            }
            if raw.count > Self.maxPayload {
                close(fd)
                return
            }
        }

        guard !raw.isEmpty,
              let payload = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
            sendLine(fd: fd, text: #"{"ok":true}"#)
            close(fd)
            return
        }

        let eventName = payload["hook_event_name"] as? String ?? ""

        if eventName == "PermissionRequest" {
            // Hold fd open — Claude Code waits for our decision (up to 120s)
            Task { @MainActor in self.processPermissionRequest(fd: fd, payload: payload) }
        } else {
            Task { @MainActor in self.processEvent(name: eventName, payload: payload) }
            sendLine(fd: fd, text: #"{"ok":true}"#)
            close(fd)
        }
    }


    // MARK: - Event → AppState
    // Events route to their agent's pill (integration_claude / _codex / _opencode)
    // through AgentSessions: each event updates its own session, and the pill
    // mirrors the session it shows. View switches only happen if that agent is
    // the focused mochi; otherwise the pill animates and shows a badge for alerts.

    @MainActor
    private func processEvent(name: String, payload: [String: Any]) {
        let state = AppState.shared
        let sessionId = payload["session_id"] as? String ?? "unknown"
        let cwd = payload["cwd"] as? String ?? ""
        let rawName = URL(fileURLWithPath: cwd).lastPathComponent
        let projectName = aliasProjectName(rawName.isEmpty ? "Session" : rawName)
        let agent = CodingAgent.from(payload["coucou_agent"] as? String)

        // Claude Code sessions are filtered to VS Code, as upstream; Codex and
        // opencode run anywhere, so every one of their sessions counts.
        if agent == .claude {
            let termProgram = payload["term_program"] as? String ?? ""
            let bundleId    = payload["bundle_id"]    as? String ?? ""
            let isVSCode = termProgram.lowercased().contains("vscode") ||
                           bundleId.lowercased().contains("vscode")
            guard isVSCode else {
                nbLog("Ignored \(name) from \(termProgram.isEmpty ? bundleId : termProgram) (\(projectName))")
                return
            }
        }

        let sessions = AgentSessions.shared
        let taskId = sessions.ensureTask(agent)
        let session = sessions.touch(agent: agent, sessionId: sessionId, project: projectName, cwd: cwd)
        let focused = state.focusId == taskId
        let isShown = { sessions.shown(agent)?.key == session.key }
        activeSessionId = sessionId

        switch name {

        case "SessionStart":
            nbLog("SessionStart [\(agent.rawValue)] \(projectName) (\(sessionId.prefix(8)))")
            // Codex also fires SessionStart when it compacts mid-turn; that one
            // must not reset a running session.
            if (payload["source"] as? String) != "compact" { session.state = .idle }
            if state.isPresent { expandIfNeeded(to: .overview) }
            SoundEngine.shared.play("work")

        case "UserPromptSubmit":
            session.summary = nil
            session.state = .thinking
            if let prompt = payload["prompt"] as? String, !prompt.isEmpty {
                sessions.addStep(session, String(prompt.prefix(60)))
            }
            if state.isPresent { expandIfNeeded(to: .overview) }

        case "PreToolUse":
            session.state = .working
            let tool = payload["tool_name"] as? String ?? "Tool"
            let input = payload["tool_input"] as? [String: Any] ?? [:]
            sessions.addStep(session, frenchStep(tool: tool, input: input))
            // Tool name only: the step text holds the start of the command, and
            // commands carry tokens and passwords often enough to keep them off disk.
            nbLog("PreToolUse [\(agent.rawValue)] \(tool)")

        case "PostToolUse":
            // Codex can deliver a PostToolUse after the turn ended; a late event
            // must not resurrect a finished session.
            if session.state != .finished && session.state != .idle { session.state = .working }

        case "PostToolUseFailure":
            session.state = .working
            sessions.addStep(session, "⚠ failed")

        case "Notification":
            let message = payload["message"] as? String ?? ""
            let lower = message.lowercased()
            if lower.contains("rate limit") || lower.contains("limite d") {
                session.state = .ratelimit
                SoundEngine.shared.play("rate")
            } else if message.hasSuffix("?") {
                session.state = .question
                sessions.addStep(session, message)
            }

        case "Stop":
            // What the agent said last: Claude's transcript (inside ~/.claude
            // only), or the reply Codex sends with Stop.
            if let path = payload["transcript_path"] as? String {
                session.summary = TranscriptSummary.lastReply(transcriptPath: path)
            } else if let last = payload["last_assistant_message"] as? String, !last.isEmpty {
                session.summary = String(last.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").prefix(220))
            }
            session.state = .finished
            if let message = payload["message"] as? String, !message.isEmpty {
                sessions.addStep(session, String(message.prefix(60)))
            }
            SoundEngine.shared.play("finish")
            sessions.mirror(agent)
            if focused && isShown() {
                expandIfNeeded(to: .finished)
            } else {
                setPillBadge(id: taskId, badge: .finished)
            }
            let key = session.key
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.2) {
                if let later = sessions.session(forKey: key), later.state == .finished {
                    later.state = .idle
                    sessions.mirror(agent)
                }
                self.clearPillBadge(id: taskId)
            }

        case "StopFailure":
            session.state = .error
            SoundEngine.shared.play("error")
            sessions.mirror(agent)
            if focused && isShown() {
                expandIfNeeded(to: .error)
            } else {
                setPillBadge(id: taskId, badge: .error)
            }

        case "Interrupt":
            // Codex only: the user stopped the turn.
            session.state = .idle
            sessions.addStep(session, "Interrupted")

        case "SessionEnd":
            sessions.end(session)

        case "SubagentStart":
            sessions.addStep(session, "+ subagent")

        case "SubagentStop":
            sessions.addStep(session, "• subagent done")

        default:
            break
        }
        sessions.mirror(agent)
    }

    // MARK: - Helpers

    @MainActor
    private func expandIfNeeded(to view: IslandView) {
        let state = AppState.shared
        let isAlert: Bool
        switch view {
        case .approval, .finished, .error, .confused: isAlert = true
        default: isAlert = false
        }
        if state.mode == .expanded {
            // Only force-switch view for alerts — leave user on their current view otherwise
            if isAlert { state.view = view }
        } else if isAlert {
            // Alerts always force-expand
            NotificationCenter.default.post(name: .hookExpand, object: view)
        } else if state.mode == .hidden {
            // Non-alert work events: reveal compact only, never force-expand
            NotificationCenter.default.post(name: .hookReveal, object: nil)
        }
        // Already compact and non-alert: Mochi state update is enough, no expand
    }

    // MARK: - Permission request (blocking — Claude Code waits for decision)

    @MainActor
    private func processPermissionRequest(fd: Int32, payload: [String: Any]) {
        let state = AppState.shared
        let sessionId = payload["session_id"] as? String ?? "unknown"
        let cwd       = payload["cwd"]        as? String ?? ""
        let rawName   = URL(fileURLWithPath: cwd).lastPathComponent
        let projectName = aliasProjectName(rawName.isEmpty ? "Session" : rawName)
        let agent = CodingAgent.from(payload["coucou_agent"] as? String)

        if agent == .claude {
            let termProgram = payload["term_program"] as? String ?? ""
            let bundleId    = payload["bundle_id"]    as? String ?? ""
            let isVSCode = termProgram.lowercased().contains("vscode") ||
                           bundleId.lowercased().contains("vscode")
            guard isVSCode else {
                Task.detached { [weak self] in
                    self?.sendLine(fd: fd, text: #"{"permissionDecision":"ask"}"#)
                    close(fd)
                }
                return
            }
        }

        let tool = payload["tool_name"] as? String ?? "Tool"
        let command = Self.approvalSummary(tool: tool, input: payload["tool_input"] as? [String: Any] ?? [:])
        nbLog("PermissionRequest [\(agent.rawValue)] \(tool)")

        if pendingApprovalFD >= 0 {
            let old = pendingApprovalFD
            Task.detached { [weak self] in
                // "ask" → nb-hook outputs nothing → the agent re-asks
                self?.sendLine(fd: old, text: #"{"permissionDecision":"ask"}"#)
                close(old)
            }
        }
        pendingApprovalFD = fd
        activeSessionId = sessionId

        let sessions = AgentSessions.shared
        let taskId = sessions.ensureTask(agent)
        let session = sessions.touch(agent: agent, sessionId: sessionId, project: projectName, cwd: cwd)
        // The pill follows the session that is asking, so the card names it.
        sessions.unpin(agent)
        session.state = .approval
        sessions.mirror(agent)
        let info = ApprovalInfo(sessionId: sessionId, tool: tool, command: command,
                                agent: agent.rawValue, sessionKey: session.key)
        pendingApprovalID = info.id
        state.pendingApproval = info
        state.isPinned = true
        SoundEngine.shared.play("approval")

        // Approval always forces the island open — user must be able to respond
        state.focusId = taskId
        expandIfNeeded(to: .approval)

        // Keyed by the request id, not the fd: the OS reuses fd numbers, and a
        // stale timer must never act on a newer request that got the same one.
        let captured = info.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 115) { [weak self] in
            guard let self, self.pendingApprovalID == captured else { return }
            // "ask" → nb-hook outputs nothing → the agent re-asks rather than denying
            self.sendApprovalDecision("ask")
        }
    }

    /// What the card shows for a request: the whole thing Allow would authorise.
    /// A bare tool name ("Write", "mcp__x__y") tells the user nothing, so the
    /// path, URL or full input is shown, with invisible characters made visible.
    static func approvalSummary(tool: String, input: [String: Any]) -> String {
        if let cmd = input["command"] as? String { return revealInvisible(cmd) }
        for key in ["file_path", "notebook_path", "path", "url", "query", "pattern", "prompt"] {
            if let value = input[key] as? String, !value.isEmpty {
                return revealInvisible("\(tool) · \(value)")
            }
        }
        if !input.isEmpty, JSONSerialization.isValidJSONObject(input),
           let data = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
            return revealInvisible("\(tool) · \(json)")
        }
        return revealInvisible(tool)
    }

    /// Control characters (other than tab and newline), bidi overrides and
    /// zero-width marks become a literal `\u{…}`, so a command cannot show the
    /// user something other than what runs.
    static func revealInvisible(_ text: String) -> String {
        var out = ""
        for scalar in text.unicodeScalars {
            let v = scalar.value
            let hidden = (v < 0x20 && v != 0x09 && v != 0x0A) || (0x7F...0x9F).contains(v)
                || scalar.properties.generalCategory == .format
                || v == 0x2028 || v == 0x2029
            if hidden {
                out += "\\u{" + String(v, radix: 16, uppercase: true) + "}"
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    /// True when the card cannot show the request in full, so it must be
    /// answered in VS Code. Views get a fixed 98 pt frame (IslandRootView), which
    /// leaves one line of 12 pt monospaced text, about 65 columns; non-ASCII
    /// counts double because CJK and emoji take two columns.
    static func needsFullReview(_ summary: String) -> Bool {
        let columns = summary.unicodeScalars.reduce(0) { $0 + ($1.isASCII ? 1 : 2) }
        return columns > 60 || summary.contains("\n") || summary.contains("\\u{")
    }

    /// Called by ApprovalView buttons with the id of the card the user saw.
    /// A click on a card that has since been replaced does nothing.
    @MainActor
    func sendApprovalDecision(_ decision: String, for id: UUID?) {
        guard let id, id == pendingApprovalID else { return }
        sendApprovalDecision(decision)
    }

    /// Writes the decision to the waiting nb-hook and cleans up.
    @MainActor
    func sendApprovalDecision(_ decision: String) {
        let fd = pendingApprovalFD
        pendingApprovalFD = -1
        pendingApprovalID = nil
        let approval = AppState.shared.pendingApproval
        let agent = CodingAgent.from(approval?.agent)

        let json: String
        switch decision {
        case "allow":  json = #"{"permissionDecision":"allow"}"#
        // Codex fails closed on updatedPermissions, so "always" is a plain allow there.
        case "always" where agent != .claude: json = #"{"permissionDecision":"allow"}"#
        case "always": json = #"{"permissionDecision":"always"}"#
        case "ask":    json = #"{"permissionDecision":"ask"}"#
        default:       json = #"{"permissionDecision":"deny"}"#
        }

        if fd >= 0 {
            Task.detached { [weak self] in
                self?.sendLine(fd: fd, text: json)
                close(fd)
            }
        }

        let state = AppState.shared
        state.pendingApproval = nil
        state.isPinned = false
        if let key = approval?.sessionKey, let session = AgentSessions.shared.session(forKey: key) {
            session.state = .working
            AgentSessions.shared.mirror(agent)
        }
        clearPillBadge(id: agent.taskId)
        state.view = state.tasks.isEmpty ? .empty : .overview
    }

    /// Updates integration_claude with the current session project name and cwd.
    @MainActor
    private func upsertTask(projectName: String, cwd: String = "") {
        let state = AppState.shared
        guard let idx = state.tasks.firstIndex(where: { $0.id == "integration_claude" }) else { return }
        state.tasks[idx].name = projectName
        if !cwd.isEmpty { state.tasks[idx].sessionCwd = cwd }
    }

    // MARK: - Badge helpers

    @MainActor
    private func setPillBadge(id: String, badge: PillBadge) {
        let state = AppState.shared
        guard let idx = state.tasks.firstIndex(where: { $0.id == id }) else { return }
        state.tasks[idx].pillBadge = badge
    }

    @MainActor
    private func clearPillBadge(id: String) {
        let state = AppState.shared
        guard let idx = state.tasks.firstIndex(where: { $0.id == id }) else { return }
        state.tasks[idx].pillBadge = nil
    }

    /// Resets integration_claude to idle, clears steps and project name.
    @MainActor
    private func clearSession() {
        let state = AppState.shared
        guard let idx = state.tasks.firstIndex(where: { $0.id == "integration_claude" }) else { return }
        state.tasks[idx].steps = []
        state.tasks[idx].stepIndex = 0
        state.tasks[idx].name = "VS Code"
        state.tasks[idx].pillBadge = nil
    }

    @MainActor
    private func appendStep(id: String, step: String) {
        let state = AppState.shared
        guard let idx = state.tasks.firstIndex(where: { $0.id == id }) else { return }
        state.tasks[idx].steps.append(step)
        if state.tasks[idx].steps.count > 20 { state.tasks[idx].steps.removeFirst() }
        state.tasks[idx].stepIndex = state.tasks[idx].steps.count - 1
    }

    // MARK: - Project name alias mapping

    private func aliasProjectName(_ name: String) -> String {
        let aliases: [String: String] = [
            "notch-buddy":  "Notch Buddy",
            "notchbuddy":   "Notch Buddy",
            "notch_buddy":  "Notch Buddy",
        ]
        return aliases[name.lowercased()] ?? name
    }

    // MARK: - French step labels

    private func frenchStep(tool: String, input: [String: Any]) -> String {
        let labels: [String: String] = [
            "Bash":       "Exécute",
            "Read":       "Lit",
            "Write":      "Écrit",
            "Edit":       "Modifie",
            "Glob":       "Cherche",
            "Grep":       "Recherche",
            "WebSearch":  "Recherche web",
            "WebFetch":   "Récupère",
            "TodoWrite":  "Tâches",
            "Task":       "Agent",
            "LS":         "Liste",
            "MultiEdit":  "Modifie",
            "NotebookEdit": "Notebook",
        ]
        let label = labels[tool] ?? tool
        if let cmd = input["command"] as? String {
            let short = String(cmd.prefix(40))
            return "\(label) · \(short)"
        } else if let path = input["path"] as? String {
            return "\(label) · \(URL(fileURLWithPath: path).lastPathComponent)"
        } else if let file = input["file_path"] as? String {
            return "\(label) · \(URL(fileURLWithPath: file).lastPathComponent)"
        } else if let query = input["query"] as? String {
            return "\(label) · \(String(query.prefix(40)))"
        }
        return label
    }

    // MARK: - Logging

    private func nbLog(_ message: String) {
        let logsDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/NotchBuddy")
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        let logFile = logsDir.appendingPathComponent("nb.log")
        // Start fresh past ~1 MB, so the log can't grow forever.
        if let size = (try? FileManager.default.attributesOfItem(atPath: logFile.path))?[.size] as? NSNumber,
           size.intValue > 1_000_000 {
            try? FileManager.default.removeItem(at: logFile)
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        // One event, one line: a newline in a project or tool name can't forge entries.
        let oneLine = message.replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\r")
        let line = "\(formatter.string(from: Date())) \(oneLine)\n"
        guard let data = line.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: logFile.path) {
            if let handle = try? FileHandle(forWritingTo: logFile) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            }
        } else {
            try? data.write(to: logFile)
            _ = try? FileManager.default.setAttributes([.posixPermissions: 0o600 as NSNumber],
                                                       ofItemAtPath: logFile.path)
        }
    }

    private func sendLine(fd: Int32, text: String) {
        let bytes = Array((text + "\n").utf8)
        bytes.withUnsafeBytes { buffer in
            var sent = 0
            while sent < buffer.count {
                let n = Darwin.send(fd, buffer.baseAddress! + sent, buffer.count - sent, 0)
                if n <= 0 { break }
                sent += n
            }
        }
    }

    // MARK: - nb-hook script installation

    func installHookScript() {
        #if APPSTORE
        // In App Store mode the script is written during settings hook installation
        // (requires NSOpenPanel to ~/.claude chosen by the user)
        #else
        let dir = Self.supportDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // nb-hook: shell wrapper (always exits 0, calls nb-hook.py via python3)
        let wrapperURL = URL(fileURLWithPath: Self.hookScriptPath)
        try? nbHookShellWrapper.write(to: wrapperURL, atomically: true, encoding: .utf8)
        _ = try? FileManager.default.setAttributes([.posixPermissions: 0o755 as NSNumber], ofItemAtPath: wrapperURL.path)
        // nb-hook.py: Python relay
        let pyURL = wrapperURL.deletingLastPathComponent().appendingPathComponent("nb-hook.py")
        try? nbHookPythonGitHub.write(to: pyURL, atomically: true, encoding: .utf8)
        _ = try? FileManager.default.setAttributes([.posixPermissions: 0o755 as NSNumber], ofItemAtPath: pyURL.path)
        #endif
    }

    // MARK: - Outdated hook detection

    /// Returns true if settings.json has a Coucou PermissionRequest hook with timeout < 120s.
    static func hooksNeedUpdate() -> Bool {
        let settingsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
        guard let data = try? Data(contentsOf: settingsURL),
              let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = settings["hooks"] as? [String: Any],
              let permReqHooks = hooks["PermissionRequest"] as? [[String: Any]] else {
            return false
        }
        for matcher in permReqHooks {
            if let hookList = matcher["hooks"] as? [[String: Any]] {
                for hook in hookList {
                    if let cmd = hook["command"] as? String,
                       isCoucouHook(cmd),
                       let timeout = hook["timeout"] as? Int,
                       timeout < 120 {
                        return true
                    }
                }
            }
        }
        return false
    }

    // MARK: - Claude Code settings.json hook installer

    private var _pendingHooksData: Data?

    /// Returns preview JSON without writing — call writeClaudeHooks() to confirm.
    func previewClaudeHooks() throws -> String {
        let data = try buildHooksData()
        _pendingHooksData = data
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Writes the hooks to disk (call after user confirms preview).
    func writeClaudeHooks() throws {
        guard let data = _pendingHooksData else { return }
        let settingsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
        // Only what the user looked at: if settings.json moved since the preview
        // (Claude Code, an editor, another tool), stop and show a fresh one.
        let current = try buildHooksData()
        guard current == data else {
            _pendingHooksData = current
            throw Self.settingsError("settings.json changed since the preview — nothing was written. Review the new one.")
        }
        // Backup first, and a backup that fails stops the write.
        try Self.backupSettings(settingsURL)
        try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: settingsURL, options: .atomic)
        _pendingHooksData = nil
    }

    private static func settingsError(_ message: String) -> NSError {
        NSError(domain: "Coucou", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    /// Reads settings.json. Only a missing or empty file means "start from
    /// nothing": anything unreadable or not a JSON object is an error, because
    /// treating it as {} and writing back would erase the user's permissions,
    /// env and other tools' hooks.
    private static func loadSettings(_ url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        if data.isEmpty { return [:] }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let settings = object as? [String: Any] else {
            throw settingsError("\(url.path) isn't a valid JSON object — Coucou won't overwrite it. Fix or move it, then try again.")
        }
        return settings
    }

    /// Dated copy next to settings.json, down to the second so two changes in
    /// the same minute never collide. Throws, so a failed backup stops the write.
    private static func backupSettings(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let backupURL = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).bak-\(formatter.string(from: Date()))")
        try FileManager.default.copyItem(at: url, to: backupURL)
    }

    /// Single-quoted for /bin/sh: inside double quotes `$`, backticks and `\`
    /// stay live, so a path holding `$(…)` would run on every hook event.
    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Coucou's own entries only: the relay's path, not any command that happens
    /// to contain "coucou" (a common French word) or "NotchBuddy".
    static func isCoucouHook(_ command: String?) -> Bool {
        guard let command else { return false }
        return command.contains("/NotchBuddy/nb-hook") || command.contains("/coucou/nb-hook")
    }

    private func buildHooksData() throws -> Data {
        let settingsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
        var settings = try Self.loadSettings(settingsURL)
        let hookPath = Self.hookScriptPath
        #if APPSTORE
        // Sandboxed apps create quarantined files; /bin/sh bypasses the quarantine flag
        let quotedCmd = "/bin/sh " + Self.shellQuote(hookPath)
        #else
        let quotedCmd = Self.shellQuote(hookPath)
        #endif
        let events: [(String, Int)] = [
            ("SessionStart", 10), ("SessionEnd", 10),
            ("UserPromptSubmit", 10),
            ("PreToolUse", 10), ("PostToolUse", 10), ("PostToolUseFailure", 10),
            ("PermissionRequest", 120),
            ("Notification", 10),
            ("Stop", 10), ("StopFailure", 10),
            ("SubagentStart", 10), ("SubagentStop", 10),
        ]
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for (event, timeout) in events {
            var existing = hooks[event] as? [[String: Any]] ?? []
            existing.removeAll { ($0["hooks"] as? [[String: Any]])?.contains { Self.isCoucouHook($0["command"] as? String) } ?? false }
            existing.append(["hooks": [["type": "command", "command": quotedCmd, "timeout": timeout]]])
            hooks[event] = existing
        }
        settings["hooks"] = hooks
        return try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
    }

    func uninstallClaudeHooks() throws {
        let settingsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
        var settings = try Self.loadSettings(settingsURL)
        guard var hooks = settings["hooks"] as? [String: Any] else { return }

        for key in hooks.keys {
            if var matchers = hooks[key] as? [[String: Any]] {
                matchers.removeAll { matcher in
                    (matcher["hooks"] as? [[String: Any]])?.contains {
                        Self.isCoucouHook($0["command"] as? String)
                    } ?? false
                }
                if matchers.isEmpty { hooks.removeValue(forKey: key) }
                else { hooks[key] = matchers }
            }
        }
        settings["hooks"] = hooks
        let newData = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        try Self.backupSettings(settingsURL)
        try newData.write(to: settingsURL, options: .atomic)
    }

    // MARK: - Codex hooks.json (GitHub build)
    // Codex reads ~/.codex/hooks.json (or $CODEX_HOME/hooks.json). Same rules as
    // settings.json: merged, a backup that must succeed, written only after the
    // preview is confirmed and only if the file didn't move in between. Codex then
    // asks the user to trust non-managed hooks once with /hooks. Event list and
    // quirks after upstream PR #14.

    #if !APPSTORE
    static var codexHooksURL: URL {
        let env = ProcessInfo.processInfo.environment["CODEX_HOME"] ?? ""
        let dir = env.isEmpty
            ? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
            : URL(fileURLWithPath: env)
        return dir.appendingPathComponent("hooks.json")
    }

    /// Codex events and timeouts (s); Codex caps SessionEnd and Interrupt at 3 s.
    private static let codexHookEvents: [(String, Int)] = [
        ("SessionStart", 10), ("SessionEnd", 3),
        ("UserPromptSubmit", 10),
        ("PreToolUse", 10), ("PostToolUse", 10),
        ("PermissionRequest", 120),
        ("Stop", 10),
        ("SubagentStart", 10), ("SubagentStop", 10),
        ("Interrupt", 3),
    ]

    static func codexHooksInstalled() -> Bool {
        guard let root = try? loadSettings(codexHooksURL),
              let hooks = root["hooks"] as? [String: Any] else { return false }
        return hooks.values.contains { value in
            (value as? [[String: Any]])?.contains { matcher in
                (matcher["hooks"] as? [[String: Any]])?.contains { isCoucouHook($0["command"] as? String) } ?? false
            } ?? false
        }
    }

    private var _pendingCodexHooksData: Data?

    func previewCodexHooks() throws -> String {
        let data = try buildCodexHooksData()
        _pendingCodexHooksData = data
        return String(data: data, encoding: .utf8) ?? ""
    }

    func writeCodexHooks() throws {
        guard let data = _pendingCodexHooksData else { return }
        let url = Self.codexHooksURL
        let current = try buildCodexHooksData()
        guard current == data else {
            _pendingCodexHooksData = current
            throw Self.settingsError("hooks.json changed since the preview — nothing was written. Review the new one.")
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.backupSettings(url)
        try data.write(to: url, options: .atomic)
        _pendingCodexHooksData = nil
    }

    func uninstallCodexHooks() throws {
        let url = Self.codexHooksURL
        var root = try Self.loadSettings(url)
        guard var hooks = root["hooks"] as? [String: Any] else { return }
        for key in hooks.keys {
            if var matchers = hooks[key] as? [[String: Any]] {
                matchers.removeAll { ($0["hooks"] as? [[String: Any]])?.contains { Self.isCoucouHook($0["command"] as? String) } ?? false }
                if matchers.isEmpty { hooks.removeValue(forKey: key) } else { hooks[key] = matchers }
            }
        }
        root["hooks"] = hooks
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try Self.backupSettings(url)
        try data.write(to: url, options: .atomic)
    }

    private func buildCodexHooksData() throws -> Data {
        var root = try Self.loadSettings(Self.codexHooksURL)
        // Single-quoted path, then the agent tag nb-hook adds to every payload.
        let command = Self.shellQuote(Self.hookScriptPath) + " --agent codex"
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for (event, timeout) in Self.codexHookEvents {
            var existing = hooks[event] as? [[String: Any]] ?? []
            existing.removeAll { ($0["hooks"] as? [[String: Any]])?.contains { Self.isCoucouHook($0["command"] as? String) } ?? false }
            existing.append(["hooks": [["type": "command", "command": command, "timeout": timeout]]])
            hooks[event] = existing
        }
        root["hooks"] = hooks
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }
    #endif

    // MARK: - App Store: hooks via security-scoped bookmark

    #if APPSTORE
    /// Writes nb-hook script and updates settings.json in one shot.
    /// claudeURL must be a URL from NSOpenPanel (sandbox access is granted immediately — no security scope needed).
    func installAndWriteClaudeHooksAppStore(claudeURL: URL) throws {
        let data = try buildHooksData(claudeURL: claudeURL)

        // Write nb-hook (shell wrapper) + nb-hook.py (Python relay) into ~/.claude/coucou/
        let coucouDir = claudeURL.appendingPathComponent("coucou")
        try FileManager.default.createDirectory(at: coucouDir, withIntermediateDirectories: true)
        let wrapperURL = coucouDir.appendingPathComponent("nb-hook")
        try nbHookShellWrapper.write(to: wrapperURL, atomically: true, encoding: .utf8)
        _ = try? FileManager.default.setAttributes([.posixPermissions: 0o755 as NSNumber], ofItemAtPath: wrapperURL.path)
        let pyURL = coucouDir.appendingPathComponent("nb-hook.py")
        try nbHookPythonAppStore.write(to: pyURL, atomically: true, encoding: .utf8)
        _ = try? FileManager.default.setAttributes([.posixPermissions: 0o755 as NSNumber], ofItemAtPath: pyURL.path)

        // Write settings.json (with a backup that must succeed first)
        let settingsURL = claudeURL.appendingPathComponent("settings.json")
        try Self.backupSettings(settingsURL)
        try data.write(to: settingsURL, options: .atomic)
        UserDefaults.standard.set(true, forKey: "coucouHooksInstalled")
    }

    func uninstallClaudeHooksAppStore(claudeURL: URL) throws {
        let settingsURL = claudeURL.appendingPathComponent("settings.json")
        var settings = try Self.loadSettings(settingsURL)
        guard var hooks = settings["hooks"] as? [String: Any] else { return }
        for key in hooks.keys {
            if var matchers = hooks[key] as? [[String: Any]] {
                matchers.removeAll { matcher in
                    (matcher["hooks"] as? [[String: Any]])?.contains {
                        Self.isCoucouHook($0["command"] as? String)
                    } ?? false
                }
                if matchers.isEmpty { hooks.removeValue(forKey: key) }
                else { hooks[key] = matchers }
            }
        }
        settings["hooks"] = hooks
        let newData = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        try Self.backupSettings(settingsURL)
        try newData.write(to: settingsURL, options: .atomic)
        UserDefaults.standard.set(false, forKey: "coucouHooksInstalled")
    }

    private func buildHooksData(claudeURL: URL) throws -> Data {
        let settingsURL = claudeURL.appendingPathComponent("settings.json")
        var settings = try Self.loadSettings(settingsURL)
        // Derive hook path from the panel-selected claudeURL (real ~/.claude, not container)
        let hookPath = claudeURL.appendingPathComponent("coucou/nb-hook").path
        let quotedCmd = "/bin/sh " + Self.shellQuote(hookPath)
        let events: [(String, Int)] = [
            ("SessionStart", 10), ("SessionEnd", 10),
            ("UserPromptSubmit", 10),
            ("PreToolUse", 10), ("PostToolUse", 10), ("PostToolUseFailure", 10),
            ("PermissionRequest", 120),
            ("Notification", 10),
            ("Stop", 10), ("StopFailure", 10),
            ("SubagentStart", 10), ("SubagentStop", 10),
        ]
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for (event, timeout) in events {
            var existing = hooks[event] as? [[String: Any]] ?? []
            existing.removeAll { ($0["hooks"] as? [[String: Any]])?.contains {
                Self.isCoucouHook($0["command"] as? String)
            } ?? false }
            existing.append(["hooks": [["type": "command", "command": quotedCmd, "timeout": timeout]]])
            hooks[event] = existing
        }
        settings["hooks"] = hooks
        return try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
    }
    #endif
}

// MARK: - Notification names for hook server → controller communication

extension Notification.Name {
    static let hookExpand = Notification.Name("notchBuddy.hookExpand")
}

// MARK: - nb-hook shell wrapper (same for both GitHub and App Store)
// Invoked by Claude Code via /bin/sh or directly via shebang.
// Always exits 0 — never blocks Claude Code.
// Checks xcode-select before running python3 to avoid triggering the
// "install developer tools" dialog on machines without Xcode CLI tools.

private let nbHookShellWrapper = """
#!/bin/sh
# Coucou hook relay — always exits 0, never blocks Claude Code
HOOK_DIR="$(dirname "$0")"
if xcode-select -p >/dev/null 2>&1; then
    out=$(/usr/bin/python3 "$HOOK_DIR/nb-hook.py" "$@" 2>/dev/null)
    rc=$?
    if [ "$rc" -eq 0 ] && [ -n "$out" ]; then
        printf '%s\\n' "$out"
    fi
fi
exit 0
"""

// MARK: - nb-hook Python relay (GitHub / non-sandboxed version)

private let nbHookPythonGitHub = """
#!/usr/bin/env python3
# nb-hook.py — Coucou hook relay for Claude Code (GitHub version)
# Reads JSON from stdin, forwards to Coucou via Unix socket, translates response.
import sys, json, os, socket

def main():
    # Mochi's own chat runs the CLI headless: its hooks must not reach the notch.
    if os.environ.get('COUCOU_INTERNAL'):
        return
    try:
        raw = sys.stdin.buffer.read()
        if not raw:
            return
        payload = json.loads(raw)
    except Exception:
        return

    # The hook command may tag the agent: nb-hook --agent codex|opencode
    args = sys.argv[1:]
    if len(args) >= 2 and args[0] == '--agent' and args[1] in ('claude', 'codex', 'opencode'):
        payload['coucou_agent'] = args[1]

    # Enrich with terminal context
    env = os.environ
    payload.setdefault('term_program', env.get('TERM_PROGRAM', ''))
    payload.setdefault('iterm_session_id', env.get('ITERM_SESSION_ID', ''))
    payload.setdefault('term_session_id', env.get('TERM_SESSION_ID', ''))
    payload.setdefault('bundle_id', env.get('__CFBundleIdentifier', ''))
    if 'cwd' not in payload or not payload['cwd']:
        payload['cwd'] = os.getcwd()

    event = payload.get('hook_event_name', '')
    socket_path = os.path.expanduser(
        '~/Library/Application Support/NotchBuddy/nb.sock'
    )
    # Only a socket owned by this user is Coucou: anything else listening on the
    # path could answer 'allow' to every permission request.
    try:
        if os.stat(socket_path).st_uid != os.getuid():
            sys.exit(0)
    except Exception:
        sys.exit(0)

    if event == 'PermissionRequest':
        # Block and wait for Coucou's decision (Claude Code allows up to 120s)
        try:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.settimeout(118)
            s.connect(socket_path)
            s.sendall((json.dumps(payload) + '\\n').encode())
            chunks = []
            while True:
                chunk = s.recv(4096)
                if not chunk:
                    break
                chunks.append(chunk)
                if b'\\n' in chunk:
                    break
            s.close()
            response = b''.join(chunks).decode().strip()
            if response:
                try:
                    resp_obj = json.loads(response)
                    decision = resp_obj.get('permissionDecision', '')
                except Exception:
                    decision = ''
                if decision == 'allow':
                    out = {'hookSpecificOutput': {'hookEventName': 'PermissionRequest', 'decision': {'behavior': 'allow'}}}
                    sys.stdout.write(json.dumps(out) + '\\n')
                    sys.stdout.flush()
                    sys.exit(0)
                elif decision == 'always':
                    # Only plain rule additions are passed on: a suggestion can also
                    # switch the permission mode or add directories, and none of it
                    # is shown on the card the user clicked.
                    suggestions = [s for s in payload.get('permission_suggestions', [])
                                   if isinstance(s, dict) and s.get('type') == 'addRules'
                                   and s.get('destination') in ('session', 'localSettings')]
                    out = {'hookSpecificOutput': {'hookEventName': 'PermissionRequest', 'decision': {'behavior': 'allow', 'updatedPermissions': suggestions}}}
                    sys.stdout.write(json.dumps(out) + '\\n')
                    sys.stdout.flush()
                    sys.exit(0)
                elif decision == 'deny':
                    out = {'hookSpecificOutput': {'hookEventName': 'PermissionRequest', 'decision': {'behavior': 'deny', 'message': 'Denied from Coucou'}}}
                    sys.stdout.write(json.dumps(out) + '\\n')
                    sys.stdout.flush()
                    sys.exit(0)
                # 'ask' or unknown: fall through → no output → Claude Code re-asks
        except Exception:
            pass
        # App unreachable, timed out, or no explicit decision — print nothing
        # Claude Code will handle the absence of output (re-ask or default behaviour)
        sys.exit(0)

    # All other events: fire-and-forget (0.3s timeout, never blocks)
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(0.3)
        s.connect(socket_path)
        s.sendall((json.dumps(payload) + '\\n').encode())
        s.close()
    except Exception:
        pass  # Always exit cleanly — never block Claude Code

main()
sys.exit(0)
"""

// MARK: - nb-hook Python relay (App Store — socket in sandboxed container)

private let nbHookPythonAppStore = """
#!/usr/bin/env python3
# nb-hook.py — Coucou (App Store) hook relay for Claude Code
# Socket lives inside the sandboxed container; script runs outside the sandbox.
import sys, json, os, socket

def main():
    # Mochi's own chat runs the CLI headless: its hooks must not reach the notch.
    if os.environ.get('COUCOU_INTERNAL'):
        return
    try:
        raw = sys.stdin.buffer.read()
        if not raw:
            return
        payload = json.loads(raw)
    except Exception:
        return

    args = sys.argv[1:]
    if len(args) >= 2 and args[0] == '--agent' and args[1] in ('claude', 'codex', 'opencode'):
        payload['coucou_agent'] = args[1]

    env = os.environ
    payload.setdefault('term_program', env.get('TERM_PROGRAM', ''))
    payload.setdefault('iterm_session_id', env.get('ITERM_SESSION_ID', ''))
    payload.setdefault('term_session_id', env.get('TERM_SESSION_ID', ''))
    payload.setdefault('bundle_id', env.get('__CFBundleIdentifier', ''))
    if 'cwd' not in payload or not payload['cwd']:
        payload['cwd'] = os.getcwd()

    event = payload.get('hook_event_name', '')
    socket_path = os.path.expanduser(
        '~/Library/Containers/fr.louisraille.Coucou/Data/nb.sock'
    )
    # Only a socket owned by this user is Coucou: anything else listening on the
    # path could answer 'allow' to every permission request.
    try:
        if os.stat(socket_path).st_uid != os.getuid():
            sys.exit(0)
    except Exception:
        sys.exit(0)

    if event == 'PermissionRequest':
        # Block and wait for Coucou's decision (Claude Code allows up to 120s)
        try:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.settimeout(118)
            s.connect(socket_path)
            s.sendall((json.dumps(payload) + '\\n').encode())
            chunks = []
            while True:
                chunk = s.recv(4096)
                if not chunk:
                    break
                chunks.append(chunk)
                if b'\\n' in chunk:
                    break
            s.close()
            response = b''.join(chunks).decode().strip()
            if response:
                try:
                    resp_obj = json.loads(response)
                    decision = resp_obj.get('permissionDecision', '')
                except Exception:
                    decision = ''
                if decision == 'allow':
                    out = {'hookSpecificOutput': {'hookEventName': 'PermissionRequest', 'decision': {'behavior': 'allow'}}}
                    sys.stdout.write(json.dumps(out) + '\\n')
                    sys.stdout.flush()
                    sys.exit(0)
                elif decision == 'always':
                    # Only plain rule additions are passed on: a suggestion can also
                    # switch the permission mode or add directories, and none of it
                    # is shown on the card the user clicked.
                    suggestions = [s for s in payload.get('permission_suggestions', [])
                                   if isinstance(s, dict) and s.get('type') == 'addRules'
                                   and s.get('destination') in ('session', 'localSettings')]
                    out = {'hookSpecificOutput': {'hookEventName': 'PermissionRequest', 'decision': {'behavior': 'allow', 'updatedPermissions': suggestions}}}
                    sys.stdout.write(json.dumps(out) + '\\n')
                    sys.stdout.flush()
                    sys.exit(0)
                elif decision == 'deny':
                    out = {'hookSpecificOutput': {'hookEventName': 'PermissionRequest', 'decision': {'behavior': 'deny', 'message': 'Denied from Coucou'}}}
                    sys.stdout.write(json.dumps(out) + '\\n')
                    sys.stdout.flush()
                    sys.exit(0)
                # 'ask' or unknown: fall through → no output → Claude Code re-asks
        except Exception:
            pass
        # App unreachable, timed out, or no explicit decision — print nothing
        sys.exit(0)

    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(0.3)
        s.connect(socket_path)
        s.sendall((json.dumps(payload) + '\\n').encode())
        s.close()
    except Exception:
        pass  # Always exit cleanly — never block Claude Code

main()
sys.exit(0)
"""
