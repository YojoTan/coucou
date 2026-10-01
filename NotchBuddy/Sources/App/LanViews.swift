import SwiftUI
import AppKit

// MARK: - Mochis on the network — island views (GitHub build)
// LanPromptView: what a paired (or pairing) Mochi asks of this one — the code
// to compare, a file to accept, a message. Every answer is a click.
// LanCardView: the Mochis pill — paired Mochis, their status, Message / Ask.

#if !APPSTORE
private func peerStatusText(_ p: LanPeer) -> String {
    guard p.online else { return String(localized: "offline") }
    // The peer's state is one of a few known words; anything else shows as online.
    let state: String
    switch p.state {
    case "working": state = String(localized: "working")
    case "thinking": state = String(localized: "thinking")
    case "approval": state = String(localized: "needs permission")
    case "finished": state = String(localized: "finished")
    case "error": state = String(localized: "error")
    case "idle": state = String(localized: "idle")
    default: state = String(localized: "online")
    }
    return p.label.isEmpty ? state : "\(state) · \(p.label)"
}

private func peerColor(_ p: LanPeer) -> Color {
    guard p.online else { return Color(hex: "#5F646D") }
    switch p.state {
    case "working": return Color(hex: "#38BDF8")
    case "thinking": return Color(hex: "#A78BFA")
    case "approval": return Color(hex: "#F5A524")
    case "finished": return Color(hex: "#22C55E")
    case "error": return Color(hex: "#F4505E")
    default: return Color(hex: "#8E939C")
    }
}

@MainActor
func composeToPeer(_ p: LanPeer, asking: Bool) {
    let state = AppState.shared
    state.peerChat = PeerChat(id: p.id, name: p.name, asking: asking)
    state.droppedFile = nil
    state.promptContext = nil
    state.chatHistory = []
    state.isPinned = false
    state.view = .prompt
}

struct LanPromptView: View {
    @ObservedObject var state: AppState
    @State private var waiting = false

    var body: some View {
        ZStack(alignment: .leading) {
            CardBackground(wash: nil)
            VStack(alignment: .leading, spacing: 6) { content }
                .padding(.leading, 98)
                .padding(.trailing, 18)
            // The sender's Mochi walks in to deliver it.
            if let from = visitor {
                GuestMochiView(name: from)
                    .id(from + "\(String(describing: state.lanPrompt))")
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, 22)
            }
        }
        .onChange(of: state.lanPrompt) { _, _ in waiting = false }
    }

    /// Who's visiting: the peer behind a file, a message or a pairing.
    private var visitor: String? {
        switch state.lanPrompt {
        case .file(_, let peer, _, _)?, .message(let peer, _, _)?, .received(let peer, _, _)?, .pair(_, let peer, _)?: return peer
        default: return nil
        }
    }

    private func done() {
        state.lanPrompt = nil
        state.isPinned = false
        state.view = state.tasks.isEmpty ? .empty : .overview
    }

    private var titleFont: Font { .system(size: 14, weight: .semibold) }
    private var subColor: Color { Color(hex: "#9398A1") }

    @ViewBuilder private var content: some View {
        switch state.lanPrompt {
        case .pair(let token, let peer, let code)?:
            Text("Pair with \(peer)?").font(titleFont)
            Group {
                if waiting {
                    Text("Waiting for \(peer) to confirm…")
                } else {
                    Text("Pair only if \(peer)'s screen shows this same code:")
                }
            }
            .font(.system(size: 12)).foregroundColor(subColor)
            Text(verbatim: "\(code.prefix(3)) \(code.suffix(3))")
                .font(.system(size: 22, weight: .semibold, design: .monospaced))
                .foregroundColor(Color(hex: "#F9A8D4"))
            if !waiting {
                HStack(spacing: 8) {
                    PrimaryButton("The codes match") {
                        LanService.shared.decide(token: token, ok: true)
                        waiting = true
                    }
                    SecondaryButton("Cancel") {
                        LanService.shared.decide(token: token, ok: false)
                        done()
                    }
                }
            }
        case .file(let token, let peer, let name, let size)?:
            Text("\(peer) wants to send you a file").font(titleFont)
            Text(verbatim: "\(name) · \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))")
                .font(.system(size: 12)).foregroundColor(subColor).lineLimit(1).truncationMode(.middle)
            if waiting {
                Text("Receiving \(name)…").font(.system(size: 12)).foregroundColor(subColor)
            } else {
                HStack(spacing: 8) {
                    PrimaryButton("Accept") {
                        LanService.shared.decide(token: token, ok: true)
                        waiting = true
                    }
                    SecondaryButton("Decline") {
                        LanService.shared.decide(token: token, ok: false)
                        done()
                    }
                }
            }
        case .message(let peer, let peerId, let text)?:
            Text(verbatim: peer).font(titleFont)
            Text(verbatim: text).font(.system(size: 12.5)).foregroundColor(Color(hex: "#C5C8CD")).lineLimit(3)
            HStack(spacing: 8) {
                PrimaryButton("Reply") {
                    state.lanPrompt = nil
                    composeToPeer(LanPeer(id: peerId, name: peer, paired: true, online: true, state: "", label: ""), asking: false)
                }
                SecondaryButton("OK") { done() }
            }
        case .received(let peer, let name, let path)?:
            Text("\(name) received").font(titleFont)
            Text("From \(peer), in Downloads › Coucou.").font(.system(size: 12)).foregroundColor(subColor)
            HStack(spacing: 8) {
                PrimaryButton("Show in Finder") {
                    let url = URL(fileURLWithPath: path).standardizedFileURL
                    // Only inside Downloads/Coucou, where received files land.
                    if url.path.hasPrefix(LanService.downloadsDir.standardizedFileURL.path + "/") {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                    done()
                }
                SecondaryButton("OK") { done() }
            }
        case .paired(let peer, let ok)?:
            if ok {
                Text("Paired with \(peer) ✓").font(titleFont)
                Text("You can now see each other's Mochi, send messages and files.").font(.system(size: 12)).foregroundColor(subColor)
            } else {
                Text("Not paired with \(peer)").font(titleFont)
                Text("One of you cancelled, or the codes didn't match.").font(.system(size: 12)).foregroundColor(subColor)
            }
            SecondaryButton("OK") { done() }
        case .asked(let peer)?:
            Text("\(peer)'s Mochi asked yours a question").font(titleFont)
            Text("Mochi answers it with web search only — never your files.").font(.system(size: 12)).foregroundColor(subColor)
            SecondaryButton("OK") { done() }
        case nil:
            EmptyView()
        }
    }
}

struct LanCardView: View {
    @ObservedObject private var appState = AppState.shared

    var body: some View {
        let peers = Array(appState.lanSnapshot.peers.filter(\.paired).prefix(3))
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(Color(hex: "#F472B6")).frame(width: 7, height: 7)
                Text("Mochis").font(.system(size: 12, weight: .semibold)).foregroundColor(Color(hex: "#F5F6F8"))
                Text("On this network").font(.system(size: 11)).foregroundColor(Color(hex: "#8E939C"))
                Spacer(minLength: 2)
            }
            .padding(.top, 6)
            if peers.isEmpty {
                Text("No paired Mochis yet. Pair one in Settings → Mochis.")
                    .font(.system(size: 11)).foregroundColor(Color(hex: "#6B7079"))
            }
            ForEach(peers) { p in
                HStack(spacing: 6) {
                    Circle().fill(peerColor(p)).frame(width: 5, height: 5)
                    Text(verbatim: p.name)
                        .font(.system(size: 11, weight: .medium)).foregroundColor(Color(hex: "#C5C8CD"))
                        .lineLimit(1).layoutPriority(1)
                    Text(verbatim: peerStatusText(p))
                        .font(.system(size: 10)).foregroundColor(Color(hex: "#6B7079")).lineLimit(1)
                    Spacer(minLength: 2)
                    if p.online {
                        Button { composeToPeer(p, asking: false) } label: {
                            Image(systemName: "bubble.left.fill").font(.system(size: 8))
                                .frame(width: 20, height: 16).background(Color.white.opacity(0.07)).clipShape(Capsule())
                        }
                        .buttonStyle(.plain).help("Message")
                        Button { composeToPeer(p, asking: true) } label: {
                            Text(verbatim: "?").font(.system(size: 10, weight: .semibold))
                                .frame(width: 20, height: 16).background(Color.white.opacity(0.07)).clipShape(Capsule())
                        }
                        .buttonStyle(.plain).help("Ask their Mochi")
                    }
                }
                .foregroundColor(Color(hex: "#C5C8CD"))
            }
        }
        .padding(.leading, 108)
        .padding(.trailing, 36)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

/// Settings → Mochis.
struct LanSettingsSection: View {
    @ObservedObject var state: AppState
    @AppStorage(LanService.enabledKey) private var enabled = false
    @AppStorage(LanService.nameKey) private var name = ""
    @AppStorage(LanService.shareKey) private var shareLabel = false
    @AppStorage(LanService.asksKey) private var allowAsks = false
    @State private var message = ""

    var body: some View {
        GroupBox("Mochis on this network") {
            VStack(alignment: .leading, spacing: 8) {
                Text("See the Mochis of the people around you, send them messages and files, and ask their Mochi. Off by default; a Mochi is trusted only after you both compared the same code, and everything between paired Mochis is encrypted end to end.")
                    .font(.system(size: 11)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                Toggle("Mochis on the network", isOn: $enabled)
                    .onChange(of: enabled) { _, _ in LanService.shared.apply() }
                TextField("This Mac's name", text: $name).textFieldStyle(.roundedBorder)
                Toggle("Share what Mochi is doing", isOn: $shareLabel)
                Toggle("Paired Mochis may ask mine", isOn: $allowAsks)
                Text("Their questions use your chat engine, with web search only: it never reads your files. Codex, Gemini and opencode can't answer them.")
                    .font(.system(size: 10)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                if enabled {
                    let peers = state.lanSnapshot.peers
                    if peers.isEmpty {
                        Text("No other Mochi found yet. Turn this on, on the other computer too.")
                            .font(.system(size: 11)).foregroundColor(.secondary)
                    }
                    ForEach(peers) { p in
                        HStack(spacing: 8) {
                            Circle().fill(p.online ? Color.green : Color.gray).frame(width: 7, height: 7)
                            Text(verbatim: p.name).font(.system(size: 12, weight: .medium))
                            Text(p.paired ? (p.online ? String(localized: "paired") : String(localized: "paired, offline")) : String(localized: "nearby"))
                                .font(.system(size: 11)).foregroundColor(.secondary)
                            Spacer()
                            if p.paired {
                                Button("Forget") { LanService.shared.forget(id: p.id) }
                            } else {
                                Button("Pair…") { pair(p) }
                            }
                        }
                    }
                }
                if !message.isEmpty {
                    Text(verbatim: message).font(.system(size: 11)).foregroundColor(.secondary)
                }
            }
            .padding(6)
        }
    }

    private func pair(_ p: LanPeer) {
        message = String(localized: "Compare the code in the island with the one on \(p.name)'s screen.")
        let id = p.id
        Task {
            let result = await LanService.run { try LanService.shared.pair(id: id) }
            if case .failure(let e) = result { message = e.localizedDescription }
        }
    }
}

/// A paired Mochi, in its owner's colour, walking in from the right edge.
private struct GuestMochiView: View {
    let name: String
    @StateObject private var engine = BotEngine()
    @State private var arrived = false

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                let now = timeline.date.timeIntervalSinceReferenceDate
                engine.update(dt: min(0.05, now - engine.lastTime))
                engine.draw(context: context, size: size)
                engine.drawHandsAndExtras(context: context, size: size)
            }
        }
        .frame(width: 54, height: 54)
        .offset(x: arrived ? 0 : 260)
        .onAppear {
            engine.bodyColor = cgColorFromHex(IslandConst.colorForProject(name))
            engine.setState(.idle, force: true)
            engine.lookX = -0.7
            engine.anim("oy", keys: (0..<6).flatMap { _ in
                [TweenKey(target: -0.12, duration: 120, ease: Ease.out), TweenKey(target: 0, duration: 120, ease: Ease.inOut)]
            })
            withAnimation(.easeOut(duration: 1.2)) { arrived = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { engine.greet() }
        }
        .help(Text(verbatim: name))
    }
}

/// The island header's paired Mochis: a tiny Mochi each, in the owner's colour,
/// dimmed when offline; a click opens what you can do with it. Works with the
/// Mochis pill on or off.
struct NearbyMochisView: View {
    @ObservedObject var state: AppState

    var body: some View {
        let peers = Array(state.lanSnapshot.peers.filter(\.paired).sorted { $0.online && !$1.online }.prefix(4))
        if state.lanSnapshot.enabled && !peers.isEmpty {
            HStack(spacing: 2) {
                ForEach(peers) { p in
                    Menu {
                        Text(verbatim: p.online ? "\(p.name) · \(peerStatusText(p))" : String(localized: "\(p.name) · offline"))
                        if p.online {
                            Button("Message") { composeToPeer(p, asking: false) }
                            Button("Ask their Mochi") { composeToPeer(p, asking: true) }
                            Button("Send a file…") { sendFile(to: p) }
                        }
                    } label: {
                        MiniBotCanvasView(task: AgentTask(id: "peer_" + p.id, name: p.name, color: IslandConst.colorForProject(p.name),
                                                          state: peerBotState(p), steps: [], source: .n8n, isIntegration: true))
                            .frame(width: 22, height: 22)
                            .frame(width: 18, height: 18)
                            .opacity(p.online ? 1 : 0.35)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help(Text(verbatim: p.name))
                }
            }
        }
    }

    private func peerBotState(_ p: LanPeer) -> BotState {
        guard p.online else { return .sleeping }
        return BotState(rawValue: p.state) ?? .idle
    }

    /// A file picker, then the same trip as dropping a file on Mochi.
    private func sendFile(to p: LanPeer) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let id = p.id, name = p.name, fileName = url.lastPathComponent
        state.noteMessage = String(localized: "Waiting for \(name) to accept \(fileName)…")
        state.view = .note
        NotificationCenter.default.post(name: .botTravel, object: nil)
        Task {
            let result = await LanService.run { try LanService.shared.sendFile(id: id, url: url) }
            switch result {
            case .success: state.noteMessage = String(localized: "\(fileName) sent to \(name) ✓")
            case .failure(let e): state.noteMessage = e.localizedDescription
            }
        }
    }
}
#endif
