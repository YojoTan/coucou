import AppKit
import ApplicationServices
import Darwin

// MARK: - SessionJump (GitHub build) — jump to the app a session runs in
// After upstream PR #11 (the Windows jump.rs). When a hook arrives, nb-hook is
// still connected, so its process is known (LOCAL_PEERPID) and so are its
// ancestors: the agent → the shell → whatever hosts the shell. The first of
// them that is a regular app (Terminal, iTerm, VS Code, Cursor, Orca…) is where
// the session lives. With Accessibility, the window naming the project is
// raised too. Computed here from the socket, never read from the payload.

#if !APPSTORE
struct SessionHost: Sendable, Equatable {
    let pid: pid_t
    let bundleId: String
}

enum SessionJump {
    // <sys/un.h>: SOL_LOCAL = 0, LOCAL_PEERPID = 0x002 (stable ABI).
    private static let solLocal: Int32 = 0
    private static let localPeerPID: Int32 = 0x002

    private static func peerPID(_ fd: Int32) -> pid_t? {
        var pid: pid_t = 0
        var len = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, solLocal, localPeerPID, &pid, &len) == 0, pid > 0 else { return nil }
        return pid
    }

    private static func parent(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let ppid = info.kp_eproc.e_ppid
        return ppid > 1 ? ppid : nil
    }

    /// The app hosting the hook client on `fd`. Any thread; call it while connected.
    static func host(ofPeer fd: Int32) -> SessionHost? {
        guard var pid = peerPID(fd) else { return nil }
        for _ in 0..<16 {
            guard let p = parent(of: pid) else { return nil }
            if let app = NSRunningApplication(processIdentifier: p),
               app.activationPolicy == .regular,
               let id = app.bundleIdentifier {
                return SessionHost(pid: p, bundleId: id)
            }
            pid = p
        }
        return nil
    }

    /// Brings the session's app (and, with Accessibility, its window) forward.
    /// False when that app is gone, so the caller falls back.
    @MainActor
    static func jump(to host: SessionHost?, cwd: String) -> Bool {
        guard let host,
              let app = NSRunningApplication(processIdentifier: host.pid),
              !app.isTerminated, app.bundleIdentifier == host.bundleId else { return false }
        raiseWindow(of: host.pid, naming: URL(fileURLWithPath: cwd).lastPathComponent)
        return app.activate(options: .activateIgnoringOtherApps)
    }

    @MainActor
    private static func raiseWindow(of pid: pid_t, naming folder: String) {
        guard !folder.isEmpty, AXIsProcessTrusted() else { return }
        let axApp = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return }
        let needle = folder.lowercased()
        for window in windows {
            var title: CFTypeRef?
            if AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title) == .success,
               let t = title as? String, t.lowercased().contains(needle) {
                AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                return
            }
        }
    }
}
#endif
