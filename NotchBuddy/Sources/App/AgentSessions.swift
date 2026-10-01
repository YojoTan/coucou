import Foundation

// MARK: - AgentSessions
// Several coding-agent sessions at once — Claude Code terminals, plus Codex and
// opencode (upstream issue #18, PRs #14/#19). Every hook event updates its own
// session; each agent's pill mirrors one of them: the one the user picked with
// ⇄ in the overview, or else the one with the latest activity. A permission
// request brings its own session to the front, so the card names the project
// that is actually asking. Same model as the Windows build (sessions.ts).

enum CodingAgent: String, CaseIterable, Sendable {
    case claude, codex, opencode

    /// The `coucou_agent` tag set by the relay; absent means Claude Code.
    static func from(_ tag: String?) -> CodingAgent {
        CodingAgent(rawValue: tag ?? "") ?? .claude
    }

    var taskId: String {
        switch self {
        case .claude: return "integration_claude"
        case .codex: return "integration_codex"
        case .opencode: return "integration_opencode"
        }
    }

    /// The pill's name when it has no session to show.
    var idleName: String {
        switch self {
        case .claude: return "VS Code"
        case .codex: return "Codex"
        case .opencode: return "opencode"
        }
    }

    static func forTask(_ id: String) -> CodingAgent? {
        allCases.first { $0.taskId == id }
    }
}

@MainActor
final class AgentSessions {
    static let shared = AgentSessions()

    final class Session {
        let key: String
        let agent: CodingAgent
        var project: String
        var cwd: String
        var state: BotState = .idle
        var steps: [String] = []
        var summary: String? = nil
        var lastSeen = Date()
        var seq = 0
        #if !APPSTORE
        /// The app the session runs in (SessionJump), for "jump to terminal".
        var host: SessionHost? = nil
        #endif

        init(key: String, agent: CodingAgent, project: String, cwd: String) {
            self.key = key
            self.agent = agent
            self.project = project
            self.cwd = cwd
        }
    }

    /// A session with no event for this long is gone (closed without SessionEnd).
    private let staleAfter: TimeInterval = 30 * 60
    private var sessions: [String: Session] = [:]
    private var pinned: [CodingAgent: String] = [:]
    private var counter = 0

    /// Codex and opencode pills appear the first time their agent sends an event.
    func ensureTask(_ agent: CodingAgent) -> String {
        let state = AppState.shared
        if agent != .claude && !state.liveAgents.contains(agent.taskId) {
            state.liveAgents.insert(agent.taskId)
            state.loadIntegrationTasks()
        }
        return agent.taskId
    }

    /// Finds or creates the session an event belongs to, and marks it active.
    func touch(agent: CodingAgent, sessionId: String, project: String, cwd: String) -> Session {
        let now = Date()
        sessions = sessions.filter { now.timeIntervalSince($0.value.lastSeen) < staleAfter }
        let key = "\(agent.rawValue):\(sessionId.isEmpty ? "default" : sessionId)"
        let s = sessions[key] ?? Session(key: key, agent: agent, project: project, cwd: cwd)
        sessions[key] = s
        if !project.isEmpty && project != "Session" { s.project = project }
        if !cwd.isEmpty { s.cwd = cwd }
        s.lastSeen = now
        counter += 1
        s.seq = counter
        return s
    }

    func addStep(_ s: Session, _ step: String) {
        s.steps.append(step)
        if s.steps.count > 20 { s.steps.removeFirst() }
    }

    func end(_ s: Session) {
        sessions[s.key] = nil
        if pinned[s.agent] == s.key { pinned[s.agent] = nil }
    }

    private func live(_ agent: CodingAgent) -> [Session] {
        sessions.values.filter { $0.agent == agent }.sorted { $0.seq > $1.seq }
    }

    /// The pinned session while it lives, else the latest.
    func shown(_ agent: CodingAgent) -> Session? {
        let all = live(agent)
        if let key = pinned[agent], let s = all.first(where: { $0.key == key }) { return s }
        return all.first
    }

    func unpin(_ agent: CodingAgent) { pinned[agent] = nil }

    /// The overview's ⇄ button: show the next session of this agent.
    func cycle(_ agent: CodingAgent) {
        let all = live(agent)
        guard all.count > 1 else { return }
        let current = shown(agent)
        let i = all.firstIndex { $0.key == current?.key } ?? 0
        pinned[agent] = all[(i + 1) % all.count].key
        mirror(agent)
    }

    func session(forKey key: String) -> Session? { sessions[key] }

    /// Whether a live session runs in this directory or below it (Orca dedup).
    func covers(path: String) -> Bool {
        guard !path.isEmpty else { return false }
        let now = Date()
        return sessions.values.contains {
            now.timeIntervalSince($0.lastSeen) < staleAfter && ($0.cwd == path || $0.cwd.hasPrefix(path + "/"))
        }
    }

    /// Copies the shown session into the agent's pill.
    func mirror(_ agent: CodingAgent) {
        let state = AppState.shared
        guard let idx = state.tasks.firstIndex(where: { $0.id == agent.taskId }) else { return }
        state.tasks[idx].sessionCount = live(agent).count
        guard let s = shown(agent) else {
            state.tasks[idx].name = agent.idleName
            state.tasks[idx].steps = []
            state.tasks[idx].stepIndex = 0
            state.tasks[idx].summary = nil
            state.tasks[idx].sessionKey = nil
            state.tasks[idx].state = .idle
            return
        }
        state.tasks[idx].name = s.project
        state.tasks[idx].steps = s.steps
        state.tasks[idx].stepIndex = max(0, s.steps.count - 1)
        state.tasks[idx].state = s.state
        state.tasks[idx].summary = s.summary
        if !s.cwd.isEmpty { state.tasks[idx].sessionCwd = s.cwd }
        state.tasks[idx].sessionKey = s.key
    }
}
