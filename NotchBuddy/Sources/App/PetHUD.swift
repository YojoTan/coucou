import AppKit
import SwiftUI

// MARK: - PetHUD — the clickable things around the desktop pet
// • Permission: when a coding agent asks, a card beside the pet shows the
//   command with Deny / Allow / Always — the island's rules exactly: Allow is
//   live only 0.7 s after the card appears, anything too long to show goes to
//   "Review in VS Code", and nothing is decided without a click.
// • Squad: a tiny Mochi per live session (Claude Code, Codex, opencode) and per
//   busy Orca worktree, above the pet; a click goes to that session.
// • Visitors: when a paired LAN Mochi sends something, its Mochi walks in from
//   the screen's edge to the pet, hands it over, and walks back out.

@MainActor
final class PetHUD {
    static let shared = PetHUD()
    private var approval: NSPanel?
    private var squad: NSPanel?
    private var visitor: NSPanel?
    private var visitorTimer: Timer?
    private var visitorFrom: NSPoint = .zero
    private var visitorTo: NSPoint = .zero
    private var visitorStart = 0.0
    private var visitorLeg = 0

    private func makePanel(_ size: NSSize, clicks: Bool) -> NSPanel {
        let p = HUDPanel(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = clicks
        p.ignoresMouseEvents = !clicks
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        return p
    }

    // MARK: Permission card

    func showApproval() {
        guard let pet = DesktopMochi.shared.petPanel, DesktopMochi.shared.isVisible else { return }
        if approval == nil {
            let p = makePanel(NSSize(width: 300, height: 150), clicks: true)
            p.contentView = NSHostingView(rootView: PetApprovalView().environmentObject(AppState.shared))
            pet.addChildWindow(p, ordered: .above)
            approval = p
        }
        place()
        approval?.orderFrontRegardless()
        PetBrain.shared.news()
    }

    func hideApproval() {
        guard let p = approval else { return }
        p.parent?.removeChildWindow(p)
        p.orderOut(nil)
        approval = nil
    }

    // MARK: Squad

    func refreshSquad() {
        guard let pet = DesktopMochi.shared.petPanel, DesktopMochi.shared.isVisible else { hideSquad(); return }
        let members = SquadMember.current()
        guard !members.isEmpty else { hideSquad(); return }
        let size = NSSize(width: CGFloat(min(members.count, 8)) * 24 + 10, height: 30)
        if squad == nil {
            let p = makePanel(size, clicks: true)
            p.contentView = NSHostingView(rootView: PetSquadView().environmentObject(AppState.shared))
            pet.addChildWindow(p, ordered: .above)
            squad = p
        }
        squad?.setContentSize(size)
        place()
        squad?.orderFrontRegardless()
    }

    private func hideSquad() {
        guard let p = squad else { return }
        p.parent?.removeChildWindow(p)
        p.orderOut(nil)
        squad = nil
    }

    /// Keeps the cards where they belong after the pet moves: the squad over its
    /// head, the permission card on the side with room.
    func place() {
        guard let pet = DesktopMochi.shared.petPanel, let screen = pet.screen else { return }
        let f = pet.frame, v = screen.visibleFrame
        if let s = squad {
            let w = s.frame.width
            let y = f.maxY + s.frame.height < v.maxY ? f.maxY - 8 : f.minY - s.frame.height + 4
            s.setFrameOrigin(NSPoint(x: min(max(f.midX - w / 2, v.minX), v.maxX - w), y: y))
        }
        if let a = approval {
            let w = a.frame.width, h = a.frame.height
            let left = f.maxX + w > v.maxX
            let x = left ? f.minX - w - 4 : f.maxX + 4
            a.setFrameOrigin(NSPoint(x: x, y: min(max(f.midY - h / 2 + 24, v.minY), v.maxY - h)))
        }
    }

    // MARK: Visitors

    /// A paired Mochi brings something: in from the nearest edge, a hello, out again.
    func visit(from name: String, saying: String) {
        guard let pet = DesktopMochi.shared.petPanel, let screen = pet.screen, DesktopMochi.shared.isVisible else { return }
        visitorTimer?.invalidate()
        visitor?.orderOut(nil)
        let s: CGFloat = 64
        let p = makePanel(NSSize(width: s, height: s), clicks: false)
        p.contentView = NSHostingView(rootView: VisitorView(name: name))
        let v = screen.frame, f = pet.frame
        let fromLeft = f.midX - v.minX > v.maxX - f.midX
        visitorFrom = NSPoint(x: fromLeft ? v.minX - s : v.maxX, y: f.minY)
        visitorTo = NSPoint(x: fromLeft ? f.minX - s + 6 : f.maxX - 6, y: f.minY)
        p.setFrameOrigin(visitorFrom)
        p.orderFrontRegardless()
        visitor = p
        visitorLeg = 0
        startLeg()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.9) {
            NotificationCenter.default.post(name: .botGreet, object: nil)
            AppState.shared.petSay(saying, seconds: 4)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.6) {
            PetHUD.shared.visitorLeg = 1
            swap(&PetHUD.shared.visitorFrom, &PetHUD.shared.visitorTo)
            PetHUD.shared.startLeg()
        }
    }

    private func startLeg() {
        visitorStart = CACurrentMediaTime()
        visitorTimer?.invalidate()
        visitorTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { _ in
            MainActor.assumeIsolated { PetHUD.shared.visitorStep() }
        }
    }

    private func visitorStep() {
        guard let p = visitor else { visitorTimer?.invalidate(); return }
        let k = min(1, (CACurrentMediaTime() - visitorStart) / 1.6)
        let hop = abs(sin(CGFloat(k) * .pi * 6)) * 10          // little steps
        p.setFrameOrigin(NSPoint(x: visitorFrom.x + (visitorTo.x - visitorFrom.x) * CGFloat(k), y: visitorFrom.y + hop))
        guard k >= 1 else { return }
        visitorTimer?.invalidate()
        visitorTimer = nil
        if visitorLeg == 1 { p.orderOut(nil); visitor = nil }
    }
}

private final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: Squad members

struct SquadMember: Identifiable {
    let id: String
    let name: String
    let color: String
    let state: BotState
    let open: @MainActor () -> Void

    /// Live coding-agent sessions, then Orca worktrees that are working or waiting.
    @MainActor
    static func current() -> [SquadMember] {
        var out: [SquadMember] = []
        #if !APPSTORE
        for s in AgentSessions.shared.liveSessions() {
            let host = s.host, cwd = s.cwd
            out.append(SquadMember(id: s.key, name: "\(s.agent.displayName) · \(s.project)",
                                   color: IslandConst.colorForProject(s.project), state: s.state,
                                   open: { _ = SessionJump.jump(to: host, cwd: cwd) }))
        }
        for w in AppState.shared.orcaWorktrees where ["working", "permission"].contains(w.status) {
            out.append(SquadMember(id: "orca:" + w.id, name: "Orca · \(w.name)", color: "#8B5CF6",
                                   state: w.status == "permission" ? .approval : .working,
                                   open: { OrcaPoller.focus(w) }))
        }
        #endif
        return Array(out.prefix(8))
    }
}

// MARK: Views

/// The permission card: a request from Coucou's own hooks, or an Orca agent's.
private struct PetApprovalView: View {
    @EnvironmentObject var state: AppState
    @State private var armedID: String? = nil
    @State private var busy = false
    @State private var error: String? = nil

    #if !APPSTORE
    private var orcaRequest: OrcaWorktree? {
        state.pendingApproval == nil ? state.orcaWorktrees.first { $0.status == "permission" } : nil
    }
    #endif

    private var requestID: String? {
        if let a = state.pendingApproval { return a.id.uuidString }
        #if !APPSTORE
        if let w = orcaRequest { return w.id + w.paneKey }
        #endif
        return nil
    }

    var body: some View {
        let shownID = requestID
        let live = armedID != nil && armedID == shownID && !busy
        VStack(alignment: .leading, spacing: 8) {
            if let a = state.pendingApproval {
                header((CodingAgent(rawValue: a.agent)?.displayName ?? "Claude Code") + " · " + String(localized: "needs permission"))
                command(a.command.isEmpty ? a.tool : a.command)
                let id = a.id
                if HookServer.needsFullReview(a.command) {
                    HStack(spacing: 6) {
                        choice("Deny", icon: "xmark", style: .deny, live: true) { HookServer.shared.sendApprovalDecision("deny", for: id) }
                        choice("Review in VS Code", icon: "arrow.up.forward.app", style: .primary, live: true) {
                            HookServer.shared.sendApprovalDecision("ask", for: id)
                        }
                    }
                } else {
                    HStack(spacing: 6) {
                        choice("Deny", icon: "xmark", style: .deny, live: true) { HookServer.shared.sendApprovalDecision("deny", for: id) }
                        choice("Allow", icon: "checkmark", style: .primary, live: live) { HookServer.shared.sendApprovalDecision("allow", for: id) }
                        choice("Always", icon: "checkmark.circle", style: .neutral, live: live) { HookServer.shared.sendApprovalDecision("always", for: id) }
                    }
                }
            }
            #if !APPSTORE
            if let w = orcaRequest {
                header("Orca · " + String(localized: "needs permission"))
                Text(verbatim: w.name).font(.system(size: 11)).foregroundColor(Color(hex: "#A1A6AE")).lineLimit(1).truncationMode(.middle)
                command([w.tool, w.toolInput].filter { !$0.isEmpty }.joined(separator: " · "))
                if w.agent == "claude" {
                    HStack(spacing: 6) {
                        choice("Deny", icon: "xmark", style: .deny, live: !busy) { decide(w, .deny) }
                        choice("Allow", icon: "checkmark", style: .primary, live: live) { decide(w, .allow) }
                        choice("Always", icon: "checkmark.circle", style: .neutral, live: live) { decide(w, .always) }
                    }
                }
                HStack(spacing: 6) {
                    if busy {
                        ProgressView().controlSize(.mini)
                        Text("Answering in its terminal…").font(.system(size: 10)).foregroundColor(Color(hex: "#8E939C"))
                    } else if let error {
                        Text(verbatim: error).font(.system(size: 10)).foregroundColor(Color(hex: "#F87171")).lineLimit(2)
                    }
                    Spacer(minLength: 4)
                    Button { OrcaPoller.focus(w) } label: {
                        Label("Open in Orca", systemImage: "arrow.up.right").font(.system(size: 10.5, weight: .medium))
                    }
                    .buttonStyle(.plain).foregroundColor(Color(hex: "#A78BFA"))
                }
            }
            #endif
        }
        .padding(12)
        .frame(width: 300, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(red: 0.06, green: 0.065, blue: 0.075).opacity(0.97)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color(hex: "#F5A524").opacity(0.45)))
        .task(id: shownID) {
            armedID = nil
            error = nil
            do { try await Task.sleep(nanoseconds: 700_000_000) } catch { return }
            armedID = shownID
        }
    }

    #if !APPSTORE
    private func decide(_ w: OrcaWorktree, _ d: OrcaPoller.Decision) {
        busy = true
        error = nil
        OrcaPoller.answer(w, d) { err in
            busy = false
            error = err
        }
    }
    #endif

    private func header(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "hand.raised.fill").font(.system(size: 11, weight: .bold)).foregroundColor(Color(hex: "#F5A524"))
            Text(verbatim: text).font(.system(size: 11.5, weight: .semibold)).foregroundColor(.white).lineLimit(1)
        }
    }

    private func command(_ text: String) -> some View {
        Text(verbatim: text.isEmpty ? "…" : text)
            .font(.system(size: 11, design: .monospaced)).foregroundColor(Color(hex: "#E8E9EC"))
            .lineLimit(2).truncationMode(.middle)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.07)))
    }

    enum ChoiceStyle { case deny, primary, neutral }

    /// One of the card's answers: equal widths, an icon, the island's colours.
    private func choice(_ title: LocalizedStringKey, icon: String, style: ChoiceStyle, live: Bool,
                        _ action: @escaping () -> Void) -> some View {
        let (fg, bg, stroke): (Color, Color, Color) = {
            switch style {
            case .deny: return (Color(hex: "#FCA5A5"), Color(hex: "#E5484D").opacity(0.14), Color(hex: "#E5484D").opacity(0.35))
            case .primary: return (.white, Color(hex: "#30A46C"), .clear)
            case .neutral: return (Color(hex: "#E8E9EC"), Color.white.opacity(0.08), Color.white.opacity(0.12))
            }
        }()
        return Button { if live { action() } } label: {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 10, weight: .bold))
                Text(title).font(.system(size: 11.5, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .foregroundColor(fg)
            .frame(maxWidth: .infinity, minHeight: 28)
            .background(RoundedRectangle(cornerRadius: 9).fill(bg))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(stroke))
            .opacity(live ? 1 : 0.45)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct PetSquadView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        TimelineView(.periodic(from: .now, by: 2)) { _ in
            HStack(spacing: 2) {
                ForEach(SquadMember.current()) { m in
                    MiniBotCanvasView(task: AgentTask(id: "squad_" + m.id, name: m.name, color: m.color,
                                                      state: m.state, steps: [], source: .n8n, isIntegration: true))
                        .id(m.id + m.state.rawValue)
                        .frame(width: 26, height: 26)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                        .onTapGesture { m.open() }
                        .help(Text(verbatim: m.name))
                }
            }
            .padding(.horizontal, 5).padding(.vertical, 4)
            .background(Capsule().fill(Color.black.opacity(0.55)))
        }
    }
}

private struct VisitorView: View {
    let name: String
    @StateObject private var engine = BotEngine()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
            Canvas { context, size in
                let now = timeline.date.timeIntervalSinceReferenceDate
                engine.update(dt: min(0.05, now - engine.lastTime))
                engine.draw(context: context, size: size)
                engine.drawHandsAndExtras(context: context, size: size)
            }
        }
        .onAppear {
            engine.bodyColor = cgColorFromHex(IslandConst.colorForProject(name))
            engine.setState(.idle, force: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.7) { engine.greet() }
        }
    }
}
