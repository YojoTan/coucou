import Foundation
import AppKit

// MARK: - Worktrees (GitHub build) — manage a repo's worktrees from Mochi
// Repos are added in Settings › Extras (path + optional provider command, kept in
// this Mac's preferences — nothing about them ships with Coucou). For each repo:
//
// • the provider (docs/WORKTREES.md) says which actions exist and what they ask
//   for; Coucou draws the forms, runs them, streams their progress, and asks for
//   a typed confirmation before anything forced;
// • without a provider, plain git: the list, and a terminal in a worktree —
//   never a removal, since `git worktree remove` can lose submodule commits;
// • whatever the provider, Coucou reads each worktree's state with git itself:
//   changed files and commits on no remote, submodules included.
//
// Polls every 30 s only while the Worktrees pill is on or its view is open.

#if !APPSTORE
struct WTRepo: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var path: String
    var provider: String        // empty: plain git
}

struct WTRepoState: Equatable, Sendable {
    var description = WTDescription()
    var worktrees: [WTWorktree] = []
    var status: [String: WTStatus] = [:]    // by path
    var error: String? = nil
    var loaded = Date.distantPast
}

/// A form being filled, or an action running, in the Worktrees view.
struct WTRun: Equatable {
    let repoId: String
    let action: WTAction
    let worktree: WTWorktree?
    var values: [String: WTValue] = [:]
    var stage: Stage = .form
    var log: [String] = []
    var result: WTEvent? = nil

    enum Stage: Equatable { case form, running, finished, confirmForce }
}

@MainActor
final class Worktrees {
    static let shared = Worktrees()
    static let taskId = "integration_worktrees"
    static let reposKey = "worktree-repos"
    private var timer: Timer?
    private var process: Process?

    static var repos: [WTRepo] {
        guard let d = UserDefaults.standard.data(forKey: reposKey),
              let r = try? JSONDecoder().decode([WTRepo].self, from: d) else { return [] }
        return r
    }

    static func save(_ repos: [WTRepo]) {
        if let d = try? JSONEncoder().encode(repos) { UserDefaults.standard.set(d, forKey: reposKey) }
    }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            MainActor.assumeIsolated { Worktrees.shared.refresh() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { Worktrees.shared.refresh() }
    }

    private var wanted: Bool {
        let s = AppState.shared
        return s.tasks.contains { $0.id == Self.taskId } || (s.mode == .expanded && s.view == .worktrees)
    }

    /// Re-reads every repo: actions (every 10 min), worktrees and their git state.
    func refresh(force: Bool = false) {
        guard force || wanted else { return }
        for repo in Self.repos {
            let old = AppState.shared.wtState[repo.id]
            let needDescribe = force || old == nil || Date().timeIntervalSince(old!.loaded) > 600
            Task.detached(priority: .utility) {
                var st = old ?? WTRepoState()
                if needDescribe {
                    if repo.provider.isEmpty {
                        st.description = WTDescription(version: 1, actions: [
                            WTAction(id: "session", label: String(localized: "Open a terminal"), scope: .worktree)])
                    } else if let d = Self.call(repo, ["describe"]).flatMap(WorktreeParse.describe) {
                        st.description = d
                    } else {
                        st.error = String(localized: "The provider didn't describe itself (docs/WORKTREES.md).")
                    }
                    st.loaded = Date()
                }
                let list: [WTWorktree]? = repo.provider.isEmpty
                    ? Self.git(repo.path, ["worktree", "list", "--porcelain"]).map(WorktreeParse.gitWorktrees)
                    : Self.call(repo, ["list"]).flatMap(WorktreeParse.list)?.worktrees
                if let list {
                    st.worktrees = list
                    st.error = nil
                    var status: [String: WTStatus] = [:]
                    for w in list { status[w.path] = Self.status(of: w.path) }
                    st.status = status
                } else if st.error == nil {
                    st.error = String(localized: "Couldn't list the worktrees of \(repo.name).")
                }
                let result = st
                await MainActor.run { AppState.shared.wtState[repo.id] = result }
            }
        }
    }

    // MARK: Running actions

    /// From a row's menu, the pet's menu or "+": a form when the action asks for
    /// something, else straight to running (a danger action still confirms in the view).
    func begin(repoId: String, action: WTAction, worktree: WTWorktree?) {
        var run = WTRun(repoId: repoId, action: action, worktree: worktree)
        for f in action.fields ?? [] { if let d = f.defaultValue { run.values[f.id] = d } }
        let needsForm = !(action.fields ?? []).isEmpty || action.danger == true
        AppState.shared.wtRun = run
        NotificationCenter.default.post(name: .hookExpand, object: IslandView.worktrees)
        if !needsForm { execute() }
    }

    /// Runs the current form's action; `confirm` is the typed slug after a refusal.
    func execute(force: Bool = false, confirm: String? = nil) {
        let state = AppState.shared
        guard var run = state.wtRun, let repo = Self.repos.first(where: { $0.id == run.repoId }) else { return }
        run.stage = .running
        run.log = []
        run.result = nil
        state.wtRun = run
        state.isPinned = true
        if repo.provider.isEmpty {
            // Plain git: the one action is a terminal in the worktree.
            if let w = run.worktree { Self.openTerminal(command: nil, cwd: w.path, worktreePath: w.path) }
            finish(.done(ok: true, text: String(localized: "Terminal opened."), risk: [], canForce: false))
            return
        }
        let args = WorktreeParse.arguments(values: run.values, worktree: run.worktree, force: force, confirm: confirm)
        let p = Self.makeProcess(repo, ["run", run.action.id, args], env: ["COUCOU_ARGS": args])
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        let lines = LineSplitter()
        out.fileHandleForReading.readabilityHandler = { h in
            for line in lines.feed(h.availableData) {
                if let e = WorktreeParse.event(line) {
                    DispatchQueue.main.async { MainActor.assumeIsolated { Worktrees.shared.handle(e) } }
                }
            }
        }
        p.terminationHandler = { proc in
            out.fileHandleForReading.readabilityHandler = nil
            let code = proc.terminationStatus
            DispatchQueue.main.async {
                MainActor.assumeIsolated { Worktrees.shared.ended(exitCode: code) }
            }
        }
        do { try p.run(); process = p } catch {
            finish(.done(ok: false, text: error.localizedDescription, risk: [], canForce: false))
        }
    }

    private func handle(_ e: WTEvent) {
        guard var run = AppState.shared.wtRun, run.stage == .running else { return }
        switch e {
        case .progress(let t):
            run.log.append(t)
            if run.log.count > 200 { run.log.removeFirst(run.log.count - 200) }
            AppState.shared.wtRun = run
        case .terminal(let cmd, let cwd, _):
            Self.openTerminal(command: cmd, cwd: cwd, worktreePath: run.worktree?.path ?? cwd)
            run.log.append(String(localized: "Opened a terminal: \(cmd)"))
            AppState.shared.wtRun = run
        case .done:
            finish(e)
        }
    }

    /// The provider exited: if it said nothing final, its exit code decides.
    private func ended(exitCode: Int32) {
        process = nil
        guard let run = AppState.shared.wtRun, run.stage == .running else { return }
        let tail = run.log.suffix(3).joined(separator: "\n")
        finish(.done(ok: exitCode == 0, text: exitCode == 0 ? String(localized: "Done.") : tail, risk: [], canForce: false))
    }

    private func finish(_ e: WTEvent) {
        let state = AppState.shared
        guard var run = state.wtRun else { return }
        run.result = e
        run.stage = .finished
        state.wtRun = run
        state.isPinned = false
        if case .done(let ok, let text, _, _) = e {
            let name = run.worktree?.slug ?? run.action.label
            state.showToast(ok ? "✓ \(name)" : "✗ \(name): \(text.prefix(60))", color: ok ? "#30A46C" : "#E5484D",
                            icon: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            SoundEngine.shared.play(ok ? "finish" : "error")
        }
        refresh(force: true)
    }

    func cancel() {
        process?.terminate()
        process = nil
        AppState.shared.wtRun = nil
        AppState.shared.isPinned = false
    }

    // MARK: Processes

    /// The provider through the user's login shell, in the repo, with a verb and args.
    nonisolated private static func makeProcess(_ repo: WTRepo, _ args: [String], env: [String: String] = [:]) -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
        p.arguments = ["-lc", repo.provider + " \"$@\"", "coucou"] + args
        p.currentDirectoryURL = URL(fileURLWithPath: repo.path)
        var e = ProcessInfo.processInfo.environment
        e["COUCOU"] = "1"
        for (k, v) in env { e[k] = v }
        p.environment = e
        return p
    }

    /// A short call (describe, list): its stdout, nil on failure or after 20 s.
    nonisolated private static func call(_ repo: WTRepo, _ args: [String]) -> Data? {
        let p = makeProcess(repo, args)
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: killer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        return p.terminationStatus == 0 ? data : nil
    }

    nonisolated private static func git(_ path: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", path] + args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }

    /// Changed files and commits on no remote, the worktree and its submodules; the last commit's date.
    nonisolated private static func status(of path: String) -> WTStatus {
        let script = #"""
        cd "$1" 2>/dev/null || exit 0
        d=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')
        u=$(git rev-list --count HEAD --not --remotes 2>/dev/null || echo 0)
        t=$(git log -1 --format=%ct 2>/dev/null || echo 0)
        s=$(git submodule foreach --quiet 'printf "%s %s\n" "$(git status --porcelain | wc -l | tr -d " ")" "$(git rev-list --count HEAD --not --remotes 2>/dev/null || echo 0)"' 2>/dev/null)
        echo "$d $u $t"
        printf '%s\n' "$s"
        """#
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script, "sh", path]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return WTStatus() }
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        var st = WTStatus()
        for (i, line) in text.split(separator: "\n").enumerated() {
            let n = line.split(separator: " ").compactMap { Int($0) }
            guard n.count >= 2 else { continue }
            st.dirty += n[0]
            st.unpushed += n[1]
            if i == 0, n.count >= 3, n[2] > 0 { st.lastCommit = Date(timeIntervalSince1970: TimeInterval(n[2])) }
        }
        return st
    }

    // MARK: Terminals

    /// In Orca when it runs (a tab in that worktree), else Terminal.app.
    static func openTerminal(command: String?, cwd: String?, worktreePath: String?) {
        let cmd = command ?? ""
        if NSRunningApplication.runningApplications(withBundleIdentifier: "com.stablyai.orca").first != nil,
           let wt = worktreePath, let orca = orcaCLI {
            let p = Process()
            p.executableURL = orca
            var args = ["terminal", "create", "--worktree", "path:\(wt)", "--focus", "--json"]
            if !cmd.isEmpty { args += ["--command", cwd.map { "cd \(shellQuote($0)) && \(cmd)" } ?? cmd] }
            p.arguments = args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            if (try? p.run()) != nil {
                OrcaPoller.openOrca()
                return
            }
        }
        let line = [cwd.map { "cd \(shellQuote($0))" }, cmd.isEmpty ? nil : cmd].compactMap { $0 }.joined(separator: " && ")
        let escaped = line.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        var error: NSDictionary?
        NSAppleScript(source: "tell application \"Terminal\"\nactivate\ndo script \"\(escaped)\"\nend tell")?.executeAndReturnError(&error)
    }

    private static var orcaCLI: URL? {
        let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.stablyai.orca") ?? URL(fileURLWithPath: "/Applications/Orca.app")
        let bin = app.appendingPathComponent("Contents/Resources/bin/orca")
        return FileManager.default.isExecutableFile(atPath: bin.path) ? bin : nil
    }

    static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

/// Bytes from a pipe, out as whole lines (the pipe's handler runs on its own thread).
private final class LineSplitter: @unchecked Sendable {
    private var buffer = Data()
    private let lock = NSLock()

    func feed(_ chunk: Data) -> [String] {
        lock.withLock {
            buffer.append(chunk)
            var out: [String] = []
            while let nl = buffer.firstIndex(of: 0x0A) {
                out.append(String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self))
                buffer.removeSubrange(buffer.startIndex...nl)
            }
            return out
        }
    }
}
#endif
