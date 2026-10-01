import AppKit
import SwiftUI

// MARK: - PetMenu — the desktop pet's own menu
// A dark card that pops out beside the pet, in the island's style: shortcuts
// to the island, the chat, Worktrees and Settings; then each repo's worktrees
// with their state — a tap on one unfolds its actions. Opened by a click (or a
// right click) on the pet; closed by a choice, a click elsewhere, or Escape.

@MainActor
final class PetMenu {
    static let shared = PetMenu()
    private var panel: NSPanel?
    private var monitors: [Any] = []
    static let width: CGFloat = 300

    var isOpen: Bool { panel?.isVisible == true }

    func toggle(beside pet: NSRect, on screen: NSScreen) {
        isOpen ? close() : open(beside: pet, on: screen)
    }

    func open(beside pet: NSRect, on screen: NSScreen) {
        close()
        let host = NSHostingView(rootView: PetMenuView().environmentObject(AppState.shared))
        let size = host.fittingSize
        let w = Self.width, h = min(size.height, screen.visibleFrame.height - 40)
        let v = screen.visibleFrame
        let right = pet.maxX + w + 8 <= v.maxX
        var origin = NSPoint(x: right ? pet.maxX + 6 : pet.minX - w - 6, y: pet.midY - h + 40)
        origin.y = min(max(origin.y, v.minY + 8), v.maxY - h - 8)
        let p = MenuPanel(contentRect: NSRect(origin: origin, size: NSSize(width: w, height: h)),
                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        host.frame = NSRect(origin: .zero, size: NSSize(width: w, height: h))
        p.contentView = host
        p.alphaValue = 0
        p.orderFrontRegardless()
        p.makeKey()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            p.animator().alphaValue = 1
        }
        panel = p
        // A click in another app, or Escape, closes it.
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { _ in
            MainActor.assumeIsolated { PetMenu.shared.close() }
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if e.keyCode == 53 { MainActor.assumeIsolated { PetMenu.shared.close() }; return nil }
            return e
        } as Any)
        Worktrees.shared.refresh(force: true)
    }

    func close() {
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors = []
        guard let p = panel else { return }
        panel = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            p.animator().alphaValue = 0
        }, completionHandler: { p.orderOut(nil) })
    }

    /// Runs a choice: the menu closes, the island comes to the pet's screen first.
    func choose(_ then: @escaping @MainActor () -> Void) {
        close()
        DesktopMochi.shared.bringIslandHere()
        then()
    }
}

/// Takes the keyboard only for the question field; never becomes the main window.
private final class MenuPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: View

private let card = Color(red: 0.06, green: 0.065, blue: 0.075)
private let dim = Color(hex: "#8E939C")
private let soft = Color(hex: "#C5C8CD")
private let orange = Color(hex: "#F97316")

private struct PetMenuView: View {
    @EnvironmentObject var state: AppState
    @State private var openRow: String? = nil
    @State private var question = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            ask
            shortcuts
            #if !APPSTORE
            ForEach(Worktrees.repos) { repo in worktrees(repo) }
            #endif
            HStack {
                Button { PetMenu.shared.close(); PetBrain.shared.hide(for: 15 * 60) } label: {
                    Label("Hide 15 min", systemImage: "eye.slash").font(.system(size: 10.5))
                }
                .buttonStyle(.plain).foregroundColor(dim)
                Spacer()
                Button { PetMenu.shared.close(); DesktopMochi.shared.dock() } label: {
                    Label("Back to the notch", systemImage: "arrow.up.to.line").font(.system(size: 10.5))
                }
                .buttonStyle(.plain).foregroundColor(dim)
            }
        }
        .padding(14)
        .frame(width: PetMenu.width, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 18).fill(card.opacity(0.97)))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.white.opacity(0.09)))
        .fixedSize(horizontal: false, vertical: true)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle().fill(Color(hex: state.focusTask?.color ?? "#F5F6F8")).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text("Mochi").font(.system(size: 13, weight: .semibold)).foregroundColor(.white)
                Text(verbatim: status).font(.system(size: 10.5)).foregroundColor(dim).lineLimit(1)
            }
            Spacer()
        }
    }

    /// A quick question; the answer shows in the pet's bubble.
    private var ask: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles").font(.system(size: 11)).foregroundColor(Color(hex: "#A5B4FC"))
            TextField("Ask Mochi…", text: $question)
                .textFieldStyle(.plain).font(.system(size: 12)).foregroundColor(.white)
                .onSubmit {
                    let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !q.isEmpty else { return }
                    question = ""
                    PetMenu.shared.close()
                    DesktopMochi.shared.ask(q)
                }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.07)))
    }

    private var status: String {
        if let t = state.compactToast { return t.text }
        if let task = state.focusTask, let step = task.steps.last, !step.isEmpty { return "\(task.name) · \(step)" }
        return state.focusTask?.name ?? ""
    }

    private var shortcuts: some View {
        HStack(spacing: 0) {
            shortcut("rectangle.topthird.inset.filled", "Island") { PetMenu.shared.choose { DesktopMochi.shared.openIslandHere() } }
            shortcut("bubble.left.fill", "Chat") {
                PetMenu.shared.choose { NotificationCenter.default.post(name: .hookExpand, object: IslandView.prompt) }
            }
            #if !APPSTORE
            if !Worktrees.repos.isEmpty {
                shortcut("arrow.triangle.branch", "Worktrees") {
                    PetMenu.shared.choose {
                        AppState.shared.wtRun = nil
                        NotificationCenter.default.post(name: .hookExpand, object: IslandView.worktrees)
                    }
                }
            }
            #endif
            shortcut("gearshape.fill", "Settings") {
                PetMenu.shared.close()
                NotificationCenter.default.post(name: .openFullSettings, object: nil)
            }
        }
    }

    private func shortcut(_ icon: String, _ label: LocalizedStringKey, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 15, weight: .medium)).foregroundColor(.white)
                    .frame(width: 42, height: 42)
                    .background(Circle().fill(Color.white.opacity(0.08)))
                    .overlay(Circle().stroke(Color.white.opacity(0.06)))
                Text(label).font(.system(size: 10)).foregroundColor(soft)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScale())
    }

    #if !APPSTORE
    @ViewBuilder private func worktrees(_ repo: WTRepo) -> some View {
        let st = state.wtState[repo.id]
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch").font(.system(size: 10, weight: .semibold)).foregroundColor(orange)
                Text(verbatim: repo.name).font(.system(size: 11.5, weight: .semibold)).foregroundColor(.white)
                Text(verbatim: "\(st?.worktrees.count ?? 0)").font(.system(size: 10.5)).foregroundColor(dim)
                Spacer()
                ForEach(st?.description.actions.filter { $0.scope == .repo } ?? []) { a in
                    Button { PetMenu.shared.choose { Worktrees.shared.begin(repoId: repo.id, action: a, worktree: nil) } } label: {
                        Text(verbatim: "+ " + a.label).font(.system(size: 10.5, weight: .semibold)).foregroundColor(.white)
                            .padding(.horizontal, 9).padding(.vertical, 4)
                            .background(Capsule().fill(orange))
                    }
                    .buttonStyle(PressScale())
                }
            }
            if let err = st?.error {
                Text(verbatim: err).font(.system(size: 10)).foregroundColor(Color(hex: "#F87171")).lineLimit(2)
            }
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(st?.worktrees ?? []) { w in row(w, repo: repo, st: st!) }
                }
            }
            .frame(maxHeight: 250)
        }
    }

    private func row(_ w: WTWorktree, repo: WTRepo, st: WTRepoState) -> some View {
        let s = st.status[w.path]
        let open = openRow == w.path
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) { openRow = open ? nil : w.path }
            } label: {
                HStack(spacing: 6) {
                    Circle().fill(Color(hex: (s?.atRisk ?? false) ? "#F5A524" : "#30A46C")).frame(width: 6, height: 6)
                    Text(verbatim: w.slug).font(.system(size: 11.5, weight: .medium)).foregroundColor(.white).lineLimit(1)
                    Spacer(minLength: 4)
                    if let s {
                        if s.dirty > 0 { mark("✎ \(s.dirty)", "#F5A524") }
                        if s.unpushed > 0 { mark("↑ \(s.unpushed)", "#60A5FA") }
                    }
                    Image(systemName: open ? "chevron.up" : "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundColor(dim)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                if let note = w.note, !note.isEmpty {
                    Text(verbatim: note).font(.system(size: 9.5)).foregroundColor(dim).lineLimit(2)
                }
                HStack(spacing: 6) {
                    ForEach(st.description.actions.filter { $0.scope == .worktree }) { a in
                        pill(a.danger == true ? a.label + "…" : a.label, danger: a.danger == true) {
                            PetMenu.shared.choose { Worktrees.shared.begin(repoId: repo.id, action: a, worktree: w) }
                        }
                    }
                    pill("Finder", danger: false) {
                        PetMenu.shared.close()
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: w.path)])
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(open ? 0.08 : 0.045)))
    }
    #endif

    private func mark(_ text: String, _ color: String) -> some View {
        Text(verbatim: text).font(.system(size: 9.5, weight: .semibold)).foregroundColor(Color(hex: color))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Capsule().fill(Color(hex: color).opacity(0.15)))
    }

    private func pill(_ title: String, danger: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(verbatim: title).font(.system(size: 10.5, weight: .semibold))
                .foregroundColor(danger ? Color(hex: "#F87171") : .white)
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(Capsule().fill(danger ? Color(hex: "#E5484D").opacity(0.16) : Color.white.opacity(0.1)))
        }
        .buttonStyle(PressScale())
    }
}

/// A small press-down for the menu's buttons.
private struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}
