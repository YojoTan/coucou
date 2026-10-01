import Foundation
import SwiftUI
import Combine

// Integration pills — always-present, never purged
extension AgentTask {
    /// All available integration pills: the built-in ones, then the user's custom Mochis.
    /// Claude is always active; others are opt-in (max 4).
    static var integrationAgents: [AgentTask] {
        #if APPSTORE
        builtInAgents
        #else
        builtInAgents + CustomMochis.all.map {
            AgentTask(id: $0.id, name: $0.name, color: $0.color, state: .idle, steps: [], source: .n8n, isIntegration: true)
        }
        #endif
    }

    static let builtInAgents: [AgentTask] = [
        AgentTask(id: "integration_claude",  name: "VS Code",   color: "#F5F6F8", state: .idle, steps: [], source: .claudeCode, isIntegration: true),
        AgentTask(id: "integration_codex",   name: "Codex",     color: "#10A37F", state: .idle, steps: [], source: .codex, isIntegration: true),
        AgentTask(id: "integration_opencode", name: "opencode", color: "#F59E0B", state: .idle, steps: [], source: .opencode, isIntegration: true),
        AgentTask(id: "integration_resend",  name: "Resend",    color: "#22C55E", state: .idle, steps: [], source: .n8n, isIntegration: true),
        AgentTask(id: "integration_n8n",     name: "n8n",       color: "#F29B38", state: .idle, steps: [], source: .n8n, isIntegration: true),
        AgentTask(id: "integration_vercel",  name: "Vercel",    color: "#7C5CFF", state: .idle, steps: [], source: .n8n, isIntegration: true),
        AgentTask(id: "integration_github",  name: "GitHub",    color: "#F4505E", state: .idle, steps: [], source: .n8n, isIntegration: true),
        AgentTask(id: "integration_notion",  name: "Notion",    color: "#8C8C8C", state: .idle, steps: [], source: .n8n, isIntegration: true),
        AgentTask(id: "integration_calcom",  name: "Cal.com",   color: "#C9956A", state: .idle, steps: [], source: .n8n, isIntegration: true),
        AgentTask(id: "integration_stripe",  name: "Stripe",    color: "#0570DE", state: .idle, steps: [], source: .n8n, isIntegration: true),
        AgentTask(id: "integration_orca",    name: "Orca",      color: "#8B5CF6", state: .idle, steps: [], source: .n8n, isIntegration: true),
        AgentTask(id: "integration_spotify", name: "Spotify",   color: "#1DB954", state: .idle, steps: [], source: .n8n, isIntegration: true),
        AgentTask(id: "integration_lan",     name: "Mochis",    color: "#F472B6", state: .idle, steps: [], source: .n8n, isIntegration: true),
        AgentTask(id: "integration_discord", name: "Discord",   color: "#5865F2", state: .idle, steps: [], source: .n8n, isIntegration: true),
        AgentTask(id: "integration_calendar", name: "Calendar", color: "#FF6B6B", state: .idle, steps: [], source: .n8n, isIntegration: true),
        AgentTask(id: "integration_system",  name: "Mac",       color: "#94A3B8", state: .idle, steps: [], source: .n8n, isIntegration: true),
        AgentTask(id: "integration_weather", name: "Weather",   color: "#38BDF8", state: .idle, steps: [], source: .n8n, isIntegration: true),
    ]

    /// IDs that can be toggled (VS Code is always on and excluded from this list)
    static var toggleableIntegrationIds: [String] {
        builtInToggleable + integrationAgents.map(\.id).filter { $0.hasPrefix("custom_") }
    }

    static let builtInToggleable: [String] = [
        "integration_resend", "integration_n8n", "integration_vercel", "integration_github",
        "integration_notion", "integration_calcom", "integration_stripe", "integration_orca", "integration_spotify", "integration_lan", "integration_discord",
        "integration_calendar", "integration_system", "integration_weather",
    ]

}

/// One line shown in the compact island's right ear for a few seconds.
struct CompactToast: Equatable {
    let id = UUID()
    let text: String
    let color: String       // hex
    let icon: String?       // SF Symbol, else a dot
}

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    /// What the compact island says right now (showToast).
    @Published var compactToast: CompactToast? = nil

    /// Mochi's mode, from a Focus automation in Shortcuts (SetMochiModeIntent).
    @Published var focusMode: FocusMode = FocusMode(rawValue: UserDefaults.standard.string(forKey: "focus-mode") ?? "") ?? .normal {
        didSet {
            UserDefaults.standard.set(focusMode.rawValue, forKey: "focus-mode")
            if focusMode.silences { toastQueue.removeAll(); compactToast = nil }
        }
    }

    /// Shows a line in the compact island — revealing it if hidden — then clears it.
    /// Toasts queue: each gets its time on screen.
    func showToast(_ text: String, color: String, icon: String? = nil, seconds: Double = 3.5) {
        guard !focusMode.silences else { return }   // Do Not Disturb means it
        toastQueue.append(CompactToast(text: text, color: color, icon: icon))
        toastQueue = Array(toastQueue.suffix(4))
        if compactToast == nil { nextToast(seconds) }
    }

    private var toastQueue: [CompactToast] = []

    private func nextToast(_ seconds: Double) {
        guard !toastQueue.isEmpty else { compactToast = nil; return }
        let t = toastQueue.removeFirst()
        compactToast = t
        NotificationCenter.default.post(name: .hookReveal, object: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.compactToast?.id == t.id else { return }
            self.nextToast(seconds)
        }
    }

    // Island state
    @Published var mode: IslandMode = .hidden
    @Published var view: IslandView = .overview

    // Tasks
    @Published var tasks: [AgentTask] = []
    @Published var focusId: String? = nil

    // Bot state override
    @Published var stateOverride: BotState? = nil

    // Real notch dimensions (set by IslandWindowController on launch)
    /// Bumped when the island moves to another screen: views re-measure.
    @Published var screenEpoch = 0
    /// Mochi is out on the desktop (DesktopMochi): the island's compact Mochi steps aside.
    @Published var desktopMochiOn = false
    var notchWidth:  CGFloat = IslandConst.notchWidth
    var notchHeight: CGFloat = IslandConst.notchHeight
    var hasNotch = true

    // Last app active before NotchBuddy (for window context capture)
    var lastExternalApp: NSRunningApplication? = nil

    // Bot drag-attach state (hides original bot while ghost follows cursor)
    @Published var isDraggingBot: Bool = false

    // Cursor and hosting panel in global AppKit coordinates (Y increases upward).
    var mousePosition: CGPoint = .zero
    var islandPanelFrame: CGRect = .zero
    var lastMouseMove: Date = .now
    var lastActivity: Date = .now
    var isPresent: Bool = true

    // Pinned (alerts that stay open, never auto-close)
    var isPinned: Bool = false

    // Upload progress (0-1) — set to 1.0 only at completion; animation is time-based
    @Published var uploadProgress: Double = 0

    // Upload animation timing (non-published — TimelineViews read these directly)
    var uploadStartTime: Date?
    var uploadDuration: Double = 2.4

    // File drag-over state (mailbox morph glow + mouth spring)
    @Published var fileDragOver: Bool = false

    // Sound enabled — persisted
    @Published var soundEnabled: Bool = true {
        didSet { UserDefaults.standard.set(soundEnabled, forKey: "soundEnabled") }
    }

    // Optional idle glances — no animation wakeups unless enabled and visible.
    @Published var idleAnimationsEnabled: Bool = false {
        didSet { UserDefaults.standard.set(idleAnimationsEnabled, forKey: "idleAnimationsEnabled") }
    }

    // Sound volume (0–0.2) — persisted, synced to SoundEngine
    @Published var soundVolume: Double = 0.12 {
        didSet {
            UserDefaults.standard.set(soundVolume, forKey: "soundVolume")
            SoundEngine.shared.volume = Float(soundVolume)
        }
    }

    // Context for prompt (window attach / file)
    @Published var promptContext: PromptContext? = nil

    // Dropped file (set during upload flow)
    @Published var droppedFile: DroppedFile? = nil

    // Short note message (shown in NoteView)
    @Published var noteMessage: String? = nil

    // Auto-close delay — persisted
    @Published var autoCloseInterval: TimeInterval = 15 {
        didSet { UserDefaults.standard.set(autoCloseInterval, forKey: "autoCloseInterval") }
    }

    // Absence interval — persisted
    var absenceInterval: TimeInterval = 3 * 60 {
        didSet { UserDefaults.standard.set(absenceInterval, forKey: "absenceInterval") }
    }

    // Greeting threshold — how long hidden before greeting on reappear (default 2 min)
    var greetThresholdSeconds: TimeInterval = 120 {
        didSet { UserDefaults.standard.set(greetThresholdSeconds, forKey: "greetThreshold") }
    }

    // Hotkey to show island (e.g. ⌘⇧N)
    @Published var hotkeyEnabled: Bool = false {
        didSet { UserDefaults.standard.set(hotkeyEnabled, forKey: "hotkeyEnabled") }
    }
    var hotkeyFlags: UInt = NSEvent.ModifierFlags([.command, .shift]).rawValue {
        didSet { UserDefaults.standard.set(Int(hotkeyFlags), forKey: "hotkeyFlags") }
    }
    var hotkeyCode: UInt16 = 45 {  // 'n'
        didSet { UserDefaults.standard.set(Int(hotkeyCode), forKey: "hotkeyCode") }
    }

    // Vercel project filter — empty = watch all projects
    @Published var vercelProjectFilter: Set<String> = [] {
        didSet {
            if let data = try? JSONEncoder().encode(Array(vercelProjectFilter)) {
                UserDefaults.standard.set(data, forKey: "vercelProjectFilter")
            }
        }
    }

    // n8n workflow filter — empty = watch all workflows
    @Published var n8nWorkflowFilter: Set<String> = [] {
        didSet {
            if let data = try? JSONEncoder().encode(Array(n8nWorkflowFilter)) {
                UserDefaults.standard.set(data, forKey: "n8nWorkflowFilter")
            }
        }
    }

    // Active integration pills (VS Code excluded — always on). Max 4.
    @Published var activeIntegrations: Set<String> = ["integration_resend", "integration_n8n", "integration_vercel", "integration_github"] {
        didSet {
            if let data = try? JSONEncoder().encode(Array(activeIntegrations)) {
                UserDefaults.standard.set(data, forKey: "activeIntegrations")
            }
        }
    }

    // Pending API result
    @Published var searchResult: SearchResult? = nil

    // Vercel deployments (populated by VercelPoller)
    @Published var vercelDeployments: [VercelDeployment] = []

    // Resend emails (populated by ResendPoller)
    @Published var resendEmails: [ResendEmail] = []
    #if !APPSTORE
    /// Orca worktrees (OrcaPoller), and why the last poll found none.
    @Published var orcaWorktrees: [OrcaWorktree] = []
    @Published var orcaError: String? = nil
    /// The orchestration question or gate the ask view shows (OrcaPoller).
    @Published var orcaAsk: OrcaAsk? = nil
    @Published var orcaAsks: [OrcaAsk] = []
    /// What Spotify last said it is playing (SpotifyWatcher).
    @Published var spotifyNow: SpotifyTrack? = nil
    /// Discord (DiscordService): the Dock badge, the voice channel, DMs and mentions.
    @Published var discordRunning = false
    @Published var discordUnread = 0
    @Published var discordUnreadDot = false
    @Published var discordLink: DiscordLink = .notSetUp
    @Published var discordMe: String? = nil
    @Published var discordVoice: DiscordVoice? = nil
    @Published var discordSelfMute = false
    @Published var discordSelfDeaf = false
    @Published var discordDevices = DiscordDevices()
    @Published var discordLastCall: DiscordCallSummary? = nil
    @Published var discordTranscript: String? = nil
    @Published var discordTalkingMuted = false
    @Published var discordEvent: DiscordEvent? = nil
    /// Custom Mochis' latest news (CustomMochis.push), by pill id.
    @Published var customStatus: [String: CustomStatus] = [:]
    /// Calendar, Mac and weather pills (Extras).
    @Published var calendarNext: CalendarEvent? = nil
    @Published var calendarError: String? = nil
    @Published var system: SystemSnapshot? = nil
    @Published var weather: WeatherNow? = nil
    @Published var weatherError: String? = nil
    /// Levels, streaks and trophies (MochiPet).
    @Published var pet = MochiPet.load()
    /// A level-up or trophy, for Mochi to celebrate (MochiExtrasSync).
    @Published var petEvent: UUID? = nil
    @Published var discordNotes: [DiscordNote] = []
    /// Mochis on the network (LanService): the peers, what one of them asks,
    /// and who the chat is writing to.
    @Published var lanSnapshot = LanSnapshot()
    @Published var lanPrompt: LanPrompt? = nil
    @Published var peerChat: PeerChat? = nil
    #endif
    @Published var resendTotal: Int? = nil

    // GitHub pull requests (populated by GithubPoller)
    @Published var githubSummary: GitHubSummary? = nil
    @Published var githubAuthSource: GitHubAuthSource? = nil   // nil = no token found
    @Published var githubError: String? = nil

    // Stripe (populated by StripePoller)
    @Published var stripePayments: [StripePayment] = []
    @Published var stripeBalance: Int = 0           // raw balance in cents
    @Published var stripeDisplayBalance: Int = 0    // animated balance target
    @Published var stripeCurrency: String = "eur"
    @Published var stripeLoaded: Bool = false       // true after first successful poll
    @Published var stripeError: String? = nil      // last API error (nil = ok)

    // Cal.com (populated by CalcomPoller)
    @Published var calcomBookings: [CalcomBooking] = []
    @Published var calcomLoaded: Bool = false
    @Published var calcomError: String? = nil

    // Notion (populated by NotionPoller)
    @Published var notionPages: [NotionPage] = []
    @Published var notionLoaded: Bool = false
    @Published var notionError: String? = nil

    // Chat conversation history
    @Published var chatHistory: [ChatMessage] = []

    // Which AI answers the chat — persisted. nil until the user picks one or the
    // first chat auto-picks the first installed CLI.
    @Published var chatEngine: ChatEngine? = nil {
        didSet { UserDefaults.standard.set(chatEngine?.rawValue, forKey: "chatEngine") }
    }

    // AI CLIs found on this Mac (filled by LocalCLI.detectAll, from Settings or the first chat)
    @Published var detectedCLIs: [ChatEngine: CLIInfo] = [:]
    @Published var cliDetectionDone: Bool = false

    /// Re-scans for the AI CLIs in the background.
    func detectCLIs() async {
        let found = await Task.detached { LocalCLI.detectAll() }.value
        detectedCLIs = found
        cliDetectionDone = true
    }

    // Pending approval request from Claude Code hook
    @Published var pendingApproval: ApprovalInfo? = nil

    // MARK: - Init (loads persisted settings)

    private init() {
        let ud = UserDefaults.standard

        if let v = ud.object(forKey: "soundEnabled") as? Bool   { soundEnabled = v }
        if let v = ud.object(forKey: "idleAnimationsEnabled") as? Bool { idleAnimationsEnabled = v }
        if let v = ud.object(forKey: "soundVolume")  as? Double { soundVolume  = v }
        // Migrate old 60s default → 15s
        if let v = ud.object(forKey: "autoCloseInterval") as? Double {
            autoCloseInterval = (v == 60) ? 15 : v
        }
        if let v = ud.object(forKey: "absenceInterval")   as? Double { absenceInterval   = v }
        if let v = ud.object(forKey: "greetThreshold")    as? Double { greetThresholdSeconds = v }
        if let v = ud.object(forKey: "hotkeyEnabled") as? Bool  { hotkeyEnabled = v }
        if let v = ud.object(forKey: "hotkeyFlags")   as? Int   { hotkeyFlags = UInt(v) }
        if let v = ud.object(forKey: "hotkeyCode")    as? Int   { hotkeyCode = UInt16(v) }
        if let v = ud.string(forKey: "chatEngine") { chatEngine = ChatEngine(rawValue: v) }
        if let d = ud.data(forKey: "vercelProjectFilter"),
           let a = try? JSONDecoder().decode([String].self, from: d) { vercelProjectFilter = Set(a) }
        if let d = ud.data(forKey: "n8nWorkflowFilter"),
           let a = try? JSONDecoder().decode([String].self, from: d) { n8nWorkflowFilter = Set(a) }
        if let d = ud.data(forKey: "activeIntegrations"),
           let a = try? JSONDecoder().decode([String].self, from: d) { activeIntegrations = Set(a) }

        // Sync SoundEngine volume on launch
        SoundEngine.shared.volume = Float(soundVolume)

        // Always load integration pills
        loadIntegrationTasks()
    }

    // MARK: - Computed

    var focusTask: AgentTask? {
        tasks.first { $0.id == focusId } ?? tasks.first
    }

    var effectiveState: BotState {
        stateOverride ?? focusTask?.state ?? .idle
    }

    // MARK: - Task management

    func addTask(_ task: AgentTask) {
        guard !tasks.contains(where: { $0.id == task.id }) else { return }
        tasks.append(task)
        if focusId == nil { focusId = task.id }
        syncMode()
        syncView()
    }

    func removeTask(id: String) {
        tasks.removeAll { $0.id == id }
        if focusId == id { focusId = tasks.first?.id }
        syncMode()
        syncView()
    }

    func updateTask(id: String, state: BotState) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[idx].state = state
    }

    func setFocus(_ id: String) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        focusId = id
        tasks[idx].pillBadge = nil  // clear badge when user brings task to focus
    }

    func syncMode() {
        // If no tasks and not expanded/peek, go hidden
        if tasks.isEmpty && mode == .compact {
            mode = .hidden
        } else if !tasks.isEmpty && mode == .hidden && isPresent {
            mode = .compact
        }
    }

    func syncView() {
        guard mode == .expanded else { return }
        if view == .empty && !tasks.isEmpty { view = .overview }
        else if view == .overview && tasks.isEmpty { view = .empty }
    }

    /// Load integration pills respecting activeIntegrations. VS Code always loads. Safe to call multiple times.
    /// Agent pills (Codex, opencode) shown because their hooks sent something.
    var liveAgents: Set<String> = []

    func loadIntegrationTasks() {
        for task in AgentTask.integrationAgents {
            let shouldLoad = task.id == "integration_claude" || liveAgents.contains(task.id)
                || activeIntegrations.contains(task.id)
            let loaded = tasks.contains(where: { $0.id == task.id })
            if shouldLoad && !loaded { tasks.append(task) }
            if !shouldLoad && loaded { tasks.removeAll { $0.id == task.id } }
        }
        if focusId == nil { focusId = "integration_claude" }
        syncMode()
    }

    /// Toggle an integration pill on/off. VS Code cannot be toggled. Max 4 active at once.
    func toggleIntegration(_ id: String) {
        guard id != "integration_claude" else { return }
        if activeIntegrations.contains(id) {
            activeIntegrations.remove(id)
            tasks.removeAll { $0.id == id }
            if focusId == id { focusId = "integration_claude" }
        } else {
            guard activeIntegrations.count < 4 else { return }
            activeIntegrations.insert(id)
            if let task = AgentTask.integrationAgents.first(where: { $0.id == id }),
               !tasks.contains(where: { $0.id == id }) {
                tasks.append(task)
            }
        }
        syncMode()
    }

}

// MARK: - Supporting types

enum PromptContext {
    case window(appName: String, title: String, url: String?)
    case file(name: String, fileURL: URL?)
}

struct DroppedFile {
    var url: URL
    var name: String
}

struct SearchResult {
    var title: String
    var items: [ResultItem]
    var note: String?
}

struct ResultItem {
    var label: String
    var detail: String
    var url: String?
}

// MARK: - Vercel

struct VercelDeployment: Identifiable {
    let id: String
    let projectName: String
    let url: String
    let state: String        // "READY", "ERROR", "CANCELED"
    let createdAt: Date
    let commitMessage: String?
    let branch: String?

    var isSuccess: Bool { state == "READY" }
    var statusLabel: String { isSuccess ? "Ready" : (state == "CANCELED" ? "Canceled" : "Error") }
    var timeAgo: String {
        let diff = Date().timeIntervalSince(createdAt)
        if diff < 60    { return "just now" }
        if diff < 3600  { return "\(Int(diff/60))m" }
        if diff < 86400 { return "\(Int(diff/3600))h" }
        return "\(Int(diff/86400))d"
    }
}

// MARK: - Resend

struct ResendEmail: Identifiable {
    let id: String
    let to: [String]
    let subject: String
    let createdAt: Date
    let lastEvent: String   // "delivered", "bounced", "complained", "opened", etc.

    var recipientShort: String {
        guard let first = to.first else { return "?" }
        return first.components(separatedBy: "@").first ?? first
    }
    var timeAgo: String {
        let diff = Date().timeIntervalSince(createdAt)
        if diff < 60    { return "just now" }
        if diff < 3600  { return "\(Int(diff/60))m" }
        if diff < 86400 { return "\(Int(diff/3600))h" }
        return "\(Int(diff/86400))d"
    }
    var isDelivered: Bool { lastEvent == "delivered" }
}

// MARK: - GitHub

/// Where the GitHub token comes from: pasted in Settings, or the local `gh` login.
enum GitHubAuthSource: Equatable, Sendable {
    case manual
    case gh
}

enum GitHubCIState: Equatable, Sendable {
    case success, failure, pending

    /// Maps GraphQL `StatusState` (SUCCESS, FAILURE, ERROR, PENDING, EXPECTED).
    init?(rollup: String?) {
        switch rollup {
        case "SUCCESS": self = .success
        case "FAILURE", "ERROR": self = .failure
        case "PENDING", "EXPECTED": self = .pending
        default: return nil
        }
    }
}

struct GitHubPR: Identifiable, Equatable, Sendable {
    let url: String
    let number: Int
    let title: String
    let repo: String          // owner/name
    let author: String?
    let ci: GitHubCIState?
    let reviewDecision: String?   // APPROVED, CHANGES_REQUESTED, REVIEW_REQUIRED
    let isDraft: Bool

    var id: String { url }
    var repoShort: String { repo.split(separator: "/").last.map(String.init) ?? repo }
}

struct GitHubSummary: Equatable, Sendable {
    let login: String
    let reviewCount: Int
    let reviewRequests: [GitHubPR]   // PRs waiting for the user's review
    let mineCount: Int
    let mine: [GitHubPR]             // the user's own open PRs, most recently updated first
}

// MARK: - Stripe

struct StripePayment: Identifiable, Equatable {
    let id: String
    let amount: Int         // in cents/smallest unit
    let currency: String
    let description: String?
    let createdAt: Date
    let status: String      // "succeeded", "pending", "failed"

    var amountFormatted: String { String(format: "%.2f", Double(amount) / 100.0) }
    var isSuccess: Bool { status == "succeeded" }
    var timeAgo: String {
        let diff = Date().timeIntervalSince(createdAt)
        if diff < 60    { return "just now" }
        if diff < 3600  { return "\(Int(diff/60))m" }
        if diff < 86400 { return "\(Int(diff/3600))h" }
        return "\(Int(diff/86400))d"
    }
}

// MARK: - Cal.com

struct CalcomBooking: Identifiable, Equatable {
    let id: Int
    let title: String
    let startTime: Date
    let endTime: Date
    let status: String
    let attendeeName: String?
    let attendeeEmail: String?
    let attendeeNotes: String?

    var isActive: Bool { status == "ACCEPTED" || status == "PENDING" }
    var timeLabel: String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: startTime)
    }
    var dayKey: String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: startTime)
        return "\(c.year!)-\(String(format: "%02d", c.month!))-\(String(format: "%02d", c.day!))"
    }
}

// MARK: - Notion

struct NotionPage: Identifiable {
    let id: String
    let title: String
    let emoji: String?
    let lastEditedAt: Date
    let url: String

    var timeAgo: String {
        let diff = Date().timeIntervalSince(lastEditedAt)
        if diff < 60 { return "now" }
        if diff < 3600 { return "\(Int(diff/60))m" }
        if diff < 86400 { return "\(Int(diff/3600))h" }
        return "\(Int(diff/86400))d"
    }
}

// MARK: - Chat

enum ChatRole { case user, assistant }

struct ChatMessage: Identifiable {
    let id = UUID()
    let role: ChatRole
    let content: String
}
