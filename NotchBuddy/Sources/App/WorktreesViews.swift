import SwiftUI
import AppKit

// MARK: - Worktrees: the pill's card, the island view, the settings (GitHub build)

#if !APPSTORE
private let accent = "#F97316"
private let dim = Color(hex: "#8E939C")
private let soft = Color(hex: "#C5C8CD")

/// The repo the views show: the one picked, else the first.
@MainActor
private func currentRepo(_ state: AppState) -> WTRepo? {
    let repos = Worktrees.repos
    return repos.first { $0.id == state.wtRepoId } ?? repos.first
}

private func chips(_ s: WTStatus?) -> some View {
    HStack(spacing: 4) {
        if let s {
            if s.dirty > 0 { chip("✎ \(s.dirty)", "#F5A524") }
            if s.unpushed > 0 { chip("↑ \(s.unpushed)", "#60A5FA") }
            if !s.atRisk { chip("✓", "#30A46C") }
        }
    }
}

private func chip(_ text: String, _ color: String) -> some View {
    Text(verbatim: text).font(.system(size: 9.5, weight: .semibold)).foregroundColor(Color(hex: color))
        .padding(.horizontal, 5).padding(.vertical, 1)
        .background(Color(hex: color).opacity(0.14)).clipShape(Capsule())
}

private func ago(_ d: Date?) -> String {
    guard let d else { return "" }
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .abbreviated
    return f.localizedString(for: d, relativeTo: Date())
}

// MARK: Pill card

struct WorktreesCardView: View {
    @ObservedObject var state: AppState

    var body: some View {
        let repo = currentRepo(state)
        let st = repo.flatMap { state.wtState[$0.id] }
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(Color(hex: accent)).frame(width: 7, height: 7)
                Text("Worktrees").font(.system(size: 12, weight: .semibold)).foregroundColor(Color(hex: "#F5F6F8"))
                Text(verbatim: repo.map { "\($0.name) · \(st?.worktrees.count ?? 0)" } ?? "")
                    .font(.system(size: 11)).foregroundColor(dim).lineLimit(1)
                Spacer(minLength: 2)
            }
            .padding(.top, 6)
            if repo == nil {
                Text("Add a repo in Settings › Extras › Worktrees.").font(.system(size: 10.5)).foregroundColor(dim)
            } else if let err = st?.error {
                Text(verbatim: err).font(.system(size: 10.5)).foregroundColor(Color(hex: "#F87171")).lineLimit(2)
            }
            ForEach((st?.worktrees ?? []).prefix(3)) { w in
                HStack(spacing: 6) {
                    Text(verbatim: w.slug).font(.system(size: 11, weight: .medium)).foregroundColor(soft).lineLimit(1)
                    chips(st?.status[w.path])
                    Spacer(minLength: 2)
                }
            }
            HStack(spacing: 12) {
                Button("Open") { NotificationCenter.default.post(name: .hookExpand, object: IslandView.worktrees) }
                if let repo, let create = st?.description.actions.first(where: { $0.scope == .repo }) {
                    Button("+ \(create.label)") { Worktrees.shared.begin(repoId: repo.id, action: create, worktree: nil) }
                }
            }
            .font(.system(size: 11, weight: .medium)).foregroundColor(Color(hex: accent)).buttonStyle(.plain)
            .padding(.top, 2)
        }
        .padding(.leading, 108).padding(.trailing, 36)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

/// The island header's shortcut, shown when a repo is set up: no pill slot needed.
struct WorktreesHeaderButton: View {
    @ObservedObject var state: AppState

    var body: some View {
        if !Worktrees.repos.isEmpty {
            Button {
                state.wtRun = nil
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { state.view = .worktrees }
                Worktrees.shared.refresh(force: true)
            } label: {
                Image(systemName: "arrow.triangle.branch").font(.system(size: 13))
                    .foregroundColor(state.view == .worktrees ? Color(hex: "#F5F6F8") : dim)
            }
            .buttonStyle(.plain)
            .help(Text("Worktrees"))
        }
    }
}

// MARK: Island view

struct WorktreesView: View {
    @ObservedObject var state: AppState
    @State private var typed = ""
    @State private var problem: String? = nil

    var body: some View {
        ZStack(alignment: .topLeading) {
            CardBackground(wash: nil)
            VStack(alignment: .leading, spacing: 6) {
                if let run = state.wtRun {
                    switch run.stage {
                    case .form: form(run)
                    case .running: running(run)
                    case .finished: finished(run)
                    case .confirmForce: confirmForce(run)
                    }
                } else {
                    list
                }
            }
            .padding(.leading, 98).padding(.trailing, 16).padding(.top, 10).padding(.bottom, 10)
        }
        .onAppear { Worktrees.shared.refresh(force: true) }
    }

    // List of worktrees, with the repo's own actions on top.
    @ViewBuilder private var list: some View {
        let repos = Worktrees.repos
        let repo = currentRepo(state)
        let st = repo.flatMap { state.wtState[$0.id] }
        HStack(spacing: 8) {
            if repos.count > 1 {
                Picker("", selection: Binding(get: { repo?.id ?? "" }, set: { state.wtRepoId = $0 })) {
                    ForEach(repos) { Text(verbatim: $0.name).tag($0.id) }
                }
                .labelsHidden().fixedSize()
            } else {
                Text(verbatim: repo?.name ?? String(localized: "Worktrees")).font(.system(size: 13, weight: .semibold))
            }
            Text(verbatim: "\(st?.worktrees.count ?? 0)").font(.system(size: 11)).foregroundColor(dim)
            Spacer()
            if let repo {
                ForEach(st?.description.actions.filter { $0.scope == .repo } ?? []) { a in
                    Button("+ \(a.label)") { Worktrees.shared.begin(repoId: repo.id, action: a, worktree: nil) }
                        .font(.system(size: 11, weight: .semibold)).foregroundColor(Color(hex: accent)).buttonStyle(.plain)
                }
            }
        }
        if repo == nil {
            Text("Add a repo in Settings › Extras › Worktrees.").font(.system(size: 11)).foregroundColor(dim)
        } else if let err = st?.error {
            Text(verbatim: err).font(.system(size: 11)).foregroundColor(Color(hex: "#F87171"))
        }
        ScrollView {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(st?.worktrees ?? []) { w in row(w, repo: repo!, st: st!) }
            }
        }
    }

    private func row(_ w: WTWorktree, repo: WTRepo, st: WTRepoState) -> some View {
        let s = st.status[w.path]
        return HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: w.slug).font(.system(size: 11.5, weight: .medium)).foregroundColor(.white).lineLimit(1)
                Text(verbatim: [w.branch, w.note, ago(s?.lastCommit)].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 9.5)).foregroundColor(dim).lineLimit(1)
            }
            Spacer(minLength: 4)
            chips(s)
            Menu {
                ForEach(st.description.actions.filter { $0.scope == .worktree }) { a in
                    Button(a.danger == true ? "\(a.label)…" : a.label) {
                        Worktrees.shared.begin(repoId: repo.id, action: a, worktree: w)
                    }
                }
                Divider()
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: w.path)]) }
                Button("Open in VS Code") {
                    NSWorkspace.shared.open([URL(fileURLWithPath: w.path)],
                                            withApplicationAt: NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.VSCode")
                                                ?? URL(fileURLWithPath: "/Applications/Visual Studio Code.app"),
                                            configuration: NSWorkspace.OpenConfiguration())
                }
            } label: {
                Image(systemName: "ellipsis.circle").font(.system(size: 13)).foregroundColor(soft)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Color.white.opacity(0.04)).clipShape(RoundedRectangle(cornerRadius: 7))
    }

    // A form drawn from the action's fields.
    @ViewBuilder private func form(_ run: WTRun) -> some View {
        title(run)
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(run.action.fields ?? []) { f in field(f, run) }
                if run.action.danger == true && (run.action.fields ?? []).isEmpty {
                    Text("This removes \(run.worktree?.slug ?? "") — the provider checks nothing is lost first.")
                        .font(.system(size: 11)).foregroundColor(soft)
                }
            }
        }
        if let problem { Text(verbatim: problem).font(.system(size: 10.5)).foregroundColor(Color(hex: "#F87171")) }
        buttons(run)
    }

    private func title(_ run: WTRun) -> some View {
        HStack(spacing: 6) {
            Text(verbatim: run.action.label).font(.system(size: 13, weight: .semibold))
            if let w = run.worktree { Text(verbatim: w.slug).font(.system(size: 11)).foregroundColor(dim) }
            Spacer()
        }
    }

    @ViewBuilder private func field(_ f: WTField, _ run: WTRun) -> some View {
        let label = Text(verbatim: f.label + (f.required == true ? " *" : "")).font(.system(size: 10.5)).foregroundColor(dim)
        switch f.type {
        case .text:
            label
            TextField(f.placeholder ?? "", text: Binding(
                get: { if case .text(let s)? = state.wtRun?.values[f.id] { return s }; return "" },
                set: { state.wtRun?.values[f.id] = .text($0) }))
                .textFieldStyle(.roundedBorder).font(.system(size: 12))
        case .choice:
            HStack {
                label
                Picker("", selection: Binding(
                    get: { if case .text(let s)? = state.wtRun?.values[f.id] { return s }; return f.options?.first?.value ?? "" },
                    set: { state.wtRun?.values[f.id] = .text($0) })) {
                    ForEach(f.options ?? [], id: \.self) { Text(verbatim: $0.label).tag($0.value) }
                }
                .labelsHidden().fixedSize()
            }
        case .multi:
            label
            let picked: [String] = { if case .list(let l)? = run.values[f.id] { return l }; return [] }()
            FlowChips(options: f.options ?? [], picked: picked) { value in
                var l = picked
                if let i = l.firstIndex(of: value) { l.remove(at: i) } else { l.append(value) }
                state.wtRun?.values[f.id] = .list(l)
            }
        case .bool:
            Toggle(f.label, isOn: Binding(
                get: { if case .flag(let b)? = state.wtRun?.values[f.id] { return b }; return false },
                set: { state.wtRun?.values[f.id] = .flag($0) }))
                .font(.system(size: 11)).toggleStyle(.switch).controlSize(.small)
        }
    }

    private func buttons(_ run: WTRun) -> some View {
        HStack(spacing: 8) {
            SecondaryButton("Cancel") { state.wtRun = nil; problem = nil }
            Button {
                if let p = (run.action.fields ?? []).lazy.compactMap({ $0.problem(with: run.values[$0.id]) }).first {
                    problem = p
                } else {
                    problem = nil
                    Worktrees.shared.execute()
                }
            } label: {
                Text(verbatim: run.action.label).font(.system(size: 12.5, weight: .semibold)).foregroundColor(.white)
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(Color(hex: run.action.danger == true ? "#E5484D" : accent)).clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    // Live progress.
    @ViewBuilder private func running(_ run: WTRun) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            title(run)
        }
        log(run.log.suffix(9))
        SecondaryButton("Stop") { Worktrees.shared.cancel() }
    }

    private func log<S: Sequence>(_ lines: S) -> some View where S.Element == String {
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, l in
                    Text(verbatim: l).font(.system(size: 9.5, design: .monospaced)).foregroundColor(soft)
                        .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(6).background(Color.black.opacity(0.35)).clipShape(RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder private func finished(_ run: WTRun) -> some View {
        if case .done(let ok, let text, let risk, let canForce)? = run.result {
            HStack(spacing: 6) {
                Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundColor(Color(hex: ok ? "#30A46C" : "#E5484D"))
                title(run)
            }
            Text(verbatim: text).font(.system(size: 11)).foregroundColor(soft).lineLimit(4)
            if !risk.isEmpty { log(risk) } else if !ok { log(run.log.suffix(6)) }
            HStack(spacing: 8) {
                SecondaryButton("Back to the list") { state.wtRun = nil }
                if canForce, run.worktree != nil {
                    Button("Force…") { typed = ""; state.wtRun?.stage = .confirmForce }
                        .font(.system(size: 11.5, weight: .semibold)).foregroundColor(Color(hex: "#F87171")).buttonStyle(.plain)
                }
            }
        }
    }

    /// Forcing loses work: the user types the worktree's name to go on.
    @ViewBuilder private func confirmForce(_ run: WTRun) -> some View {
        let slug = run.worktree?.slug ?? ""
        Text("Forcing loses what isn't pushed or committed in \(slug).").font(.system(size: 12, weight: .semibold))
            .foregroundColor(Color(hex: "#F87171"))
        Text("Type \(slug) to confirm:").font(.system(size: 11)).foregroundColor(soft)
        TextField(slug, text: $typed).textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
        HStack(spacing: 8) {
            SecondaryButton("Cancel") { state.wtRun?.stage = .finished }
            Button("Force \(run.action.label.lowercased())") { Worktrees.shared.execute(force: true, confirm: typed) }
                .font(.system(size: 12, weight: .semibold)).foregroundColor(.white)
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(Color(hex: "#E5484D").opacity(typed == slug ? 1 : 0.35)).clipShape(Capsule())
                .buttonStyle(.plain).disabled(typed != slug)
        }
    }
}

/// Toggle chips that wrap onto as many lines as they need.
private struct FlowChips: View {
    let options: [WTOption]
    let picked: [String]
    let toggle: (String) -> Void

    var body: some View {
        WrapLayout(spacing: 4) {
            ForEach(options, id: \.self) { o in
                let on = picked.contains(o.value)
                Button { toggle(o.value) } label: {
                    Text(verbatim: o.label).font(.system(size: 10.5, weight: on ? .semibold : .regular))
                        .foregroundColor(on ? .white : soft)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(on ? Color(hex: accent).opacity(0.85) : Color.white.opacity(0.07))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// A minimal flow layout: left to right, wrapping.
private struct WrapLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 400
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0
        for s in subviews {
            let d = s.sizeThatFits(.unspecified)
            if x > 0 && x + d.width > width { x = 0; y += line + spacing; line = 0 }
            x += d.width + spacing
            line = max(line, d.height)
        }
        return CGSize(width: width, height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for s in subviews {
            let d = s.sizeThatFits(.unspecified)
            if x > bounds.minX && x + d.width > bounds.maxX { x = bounds.minX; y += line + spacing; line = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += d.width + spacing
            line = max(line, d.height)
        }
    }
}

// MARK: Settings

struct WorktreesSettingsSection: View {
    @State private var repos = Worktrees.repos
    @State private var message = ""

    var body: some View {
        GroupBox("Worktrees") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Manage a repo's worktrees from Mochi — the island, the pill or the desktop pet. Without a provider: the list and a terminal in each. With one, its own actions (create, tear down…) as forms — see docs/WORKTREES.md to write one for your repo. Everything here stays in this Mac's preferences.")
                    .font(.system(size: 11)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                ForEach($repos) { $r in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            TextField("Name", text: $r.name).textFieldStyle(.roundedBorder).frame(width: 140)
                            Text(verbatim: r.path).font(.system(size: 10)).foregroundColor(.secondary).lineLimit(1).truncationMode(.head)
                            Spacer()
                            Button("Remove") { repos.removeAll { $0.id == r.id }; save() }
                        }
                        TextField("Provider command (optional) — e.g. bash tools/worktrees-provider.sh", text: $r.provider)
                            .textFieldStyle(.roundedBorder).font(.system(size: 11, design: .monospaced))
                    }
                    .padding(6).background(Color.primary.opacity(0.04)).clipShape(RoundedRectangle(cornerRadius: 6))
                }
                HStack {
                    Button("Add a repo…") { add() }
                    Button("Save") { save() }.buttonStyle(.borderedProminent)
                }
                if !message.isEmpty { Text(message).font(.system(size: 11)).foregroundColor(.secondary) }
            }
            .padding(6)
        }
    }

    private func add() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = String(localized: "Choose")
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) else {
            message = String(localized: "❌ That folder isn't a git repository.")
            return
        }
        repos.append(WTRepo(id: UUID().uuidString, name: url.lastPathComponent, path: url.path, provider: ""))
        save()
    }

    private func save() {
        Worktrees.save(repos)
        message = String(localized: "✓ Saved.")
        Worktrees.shared.refresh(force: true)
    }
}
#endif
