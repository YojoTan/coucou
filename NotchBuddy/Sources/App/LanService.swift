import Foundation
import CryptoKit
import Darwin
import AppKit

// MARK: - LanService (GitHub build) — Mochis on the local network (docs/LAN.md)
// The macOS side of windows/src-tauri/src/lan/mod.rs: find the other Coucous on
// this network, pair by comparing a six-digit code, then see their status, send
// messages and files, and ask their Mochi.
//
// Off until the user turns it on. Nothing is accepted from an unpaired Mochi but
// a pairing request, which only shows a prompt. Files arrive only after a click;
// a peer may ask this Mochi only if the user allowed it, and the answer comes
// from an engine that can't read this Mac's files.
//
// Threads: the network runs on its own threads; AppState is touched only on the
// main queue.

#if !APPSTORE
struct LanPeer: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let paired: Bool
    let online: Bool
    let state: String
    let label: String
}

struct LanSnapshot: Equatable, Sendable {
    var enabled = false
    var running = false
    var name = ""
    var peers: [LanPeer] = []
}

enum LanPrompt: Equatable, Sendable {
    case pair(token: String, peer: String, code: String)
    case file(token: String, peer: String, name: String, size: Int64)
    case message(peer: String, peerId: String, text: String)
    case received(peer: String, name: String, path: String)
    case paired(peer: String, ok: Bool)
    case asked(peer: String)

    var needsDecision: Bool {
        switch self {
        case .pair, .file: return true
        default: return false
        }
    }
}

struct PeerChat: Equatable, Sendable {
    let id: String
    let name: String
    var asking: Bool
}

final class LanService: @unchecked Sendable {
    static let shared = LanService()
    static let udpPort: UInt16 = 47801
    private static let maxFile: Int64 = 512 * 1024 * 1024
    private static let chunk = 48 * 1024
    private static let decideTimeout: TimeInterval = 120

    // Preferences (Settings → Mochis)
    static let enabledKey = "lanEnabled", nameKey = "lanName", shareKey = "lanShareLabel", asksKey = "lanAllowAsks"
    static var enabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }
    static var shareLabel: Bool { UserDefaults.standard.bool(forKey: shareKey) }
    static var allowAsks: Bool { UserDefaults.standard.bool(forKey: asksKey) }
    static var displayName: String {
        let n = (UserDefaults.standard.string(forKey: nameKey) ?? "").trimmingCharacters(in: .whitespaces)
        return String((n.isEmpty ? (Host.current().localizedName ?? "Mac") : n).prefix(40))
    }

    private struct Seen {
        let name: String
        let addr: in_addr
        let port: UInt16
        let key: Data
        let at: Date
    }

    struct Trusted: Codable, Equatable {
        let id: String
        let name: String
        let key: String
    }

    private final class Decision: @unchecked Sendable {
        let semaphore = DispatchSemaphore(value: 0)
        var ok = false
    }

    private let lock = NSLock()
    private var me: Curve25519.Signing.PrivateKey?
    private var port: UInt16 = 0
    private var listenFD: Int32 = -1
    private var generation = 0
    private var seen: [String: Seen] = [:]
    private var status: [String: (state: String, label: String)] = [:]
    private var pending: [String: Decision] = [:]
    private var asking = false
    private var lastAsk: [String: Date] = [:]

    private init() {}

    // MARK: Files

    private static var trustedURL: URL { HookServer.supportDir.appendingPathComponent("lan-peers.json") }

    static func loadTrusted() -> [Trusted] {
        guard let data = try? Data(contentsOf: trustedURL) else { return [] }
        return (try? JSONDecoder().decode([Trusted].self, from: data)) ?? []
    }

    private static func saveTrusted(_ list: [Trusted]) {
        try? FileManager.default.createDirectory(at: HookServer.supportDir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(list) { try? data.write(to: trustedURL, options: .atomic) }
    }

    static var downloadsDir: URL {
        (FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads"))
            .appendingPathComponent("Coucou")
    }

    /// The long-term key, in the Keychain.
    private static func identity() -> Curve25519.Signing.PrivateKey? {
        if let s = Keychain.load(key: "lan-identity"), let raw = Data(base64Encoded: s),
           let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) {
            return key
        }
        let fresh = Curve25519.Signing.PrivateKey()
        Keychain.save(key: "lan-identity", value: fresh.rawRepresentation.base64EncodedString())
        return fresh
    }

    // MARK: Start / stop

    /// Settings changed (or the app started): start or stop to match.
    func apply() {
        let want = Self.enabled
        let running = lock.withLock { me != nil }
        if want && !running { start() }
        if !want && running { stop() }
        publish()
    }

    private func start() {
        guard let key = Self.identity() else { return }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = INADDR_ANY
        addr.sin_port = 0
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, Darwin.listen(fd, 8) == 0 else { close(fd); return }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        let gen: Int = lock.withLock {
            me = key
            port = UInt16(bigEndian: addr.sin_port)
            listenFD = fd
            generation += 1
            return generation
        }
        Thread.detachNewThread { [self] in serve(fd: fd, generation: gen) }
        Thread.detachNewThread { [self] in discover(generation: gen) }
        Thread.detachNewThread { [self] in pollStatus(generation: gen) }
    }

    private func stop() {
        let fd: Int32 = lock.withLock {
            generation += 1
            me = nil
            port = 0
            seen = [:]
            status = [:]
            for d in pending.values { d.semaphore.signal() }
            pending = [:]
            let fd = listenFD
            listenFD = -1
            return fd
        }
        if fd >= 0 { close(fd) }
    }

    private func alive(_ gen: Int) -> Bool { lock.withLock { generation == gen && me != nil } }

    // MARK: Publishing to the island

    func snapshot() -> LanSnapshot {
        let trusted = Self.loadTrusted()
        return lock.withLock {
            var peers = trusted.map { t in
                LanPeer(id: t.id, name: seen[t.id]?.name ?? t.name, paired: true, online: seen[t.id] != nil,
                        state: status[t.id]?.state ?? "", label: status[t.id]?.label ?? "")
            }
            for (id, s) in seen where !trusted.contains(where: { $0.id == id }) {
                peers.append(LanPeer(id: id, name: s.name, paired: false, online: true, state: "", label: ""))
            }
            peers.sort { ($0.paired ? 0 : 1, $0.online ? 0 : 1, $0.name.lowercased()) < ($1.paired ? 0 : 1, $1.online ? 0 : 1, $1.name.lowercased()) }
            return LanSnapshot(enabled: Self.enabled, running: me != nil, name: Self.displayName, peers: peers)
        }
    }

    private func publish() {
        let snap = snapshot()
        DispatchQueue.main.async { Self.show(snap) }
    }

    @MainActor private static func show(_ snap: LanSnapshot) {
        if AppState.shared.lanSnapshot != snap { AppState.shared.lanSnapshot = snap }
    }

    private func prompt(_ p: LanPrompt) {
        DispatchQueue.main.async { Self.raise(p) }
    }

    @MainActor private static func raise(_ p: LanPrompt) {
        let state = AppState.shared
        state.lanPrompt = p
        if p.needsDecision { state.isPinned = true }
        SoundEngine.shared.play(p.needsDecision ? "approval" : "pop")
        NotificationCenter.default.post(name: .hookExpand, object: IslandView.lan)
    }

    /// What Mochi is doing, read on the main queue when a peer asks.
    private func localStatus() -> (String, String) {
        DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                let state = AppState.shared
                let task = state.focusTask
                let s = state.stateOverride?.rawValue ?? task?.state.rawValue ?? "idle"
                let label = (task.map { $0.state != .idle } ?? false) ? (task?.name ?? "") : ""
                return (s, label)
            }
        }
    }

    // MARK: Decisions (pairing codes, file offers)

    func decide(token: String, ok: Bool) {
        let d = lock.withLock { pending.removeValue(forKey: token) }
        d?.ok = ok
        d?.semaphore.signal()
    }

    private func waitDecision(_ token: String) -> Bool {
        let d = Decision()
        lock.withLock { pending[token] = d }
        let timedOut = d.semaphore.wait(timeout: .now() + Self.decideTimeout) == .timedOut
        lock.withLock { _ = pending.removeValue(forKey: token) }
        return !timedOut && d.ok
    }

    func forget(id: String) {
        var list = Self.loadTrusted()
        list.removeAll { $0.id == id }
        Self.saveTrusted(list)
        lock.withLock { status[id] = nil }
        publish()
    }

    // MARK: Discovery — UDP 47801

    private func beacon() -> Data? {
        lock.withLock {
            guard let me else { return nil }
            let key = me.publicKey.rawRepresentation
            return try? LanWire.json(["coucou": 1, "id": LanWire.id(of: key), "name": Self.displayName,
                                      "port": Int(port), "key": key.base64EncodedString()])
        }
    }

    static func parseBeacon(_ data: Data, ownId: String) -> (id: String, name: String, port: UInt16, key: Data)? {
        guard data.count <= 1024, let o = try? LanWire.object(data), o["coucou"] as? Int == 1,
              let k = o["key"] as? String, let key = Data(base64Encoded: k), key.count == 32,
              let id = o["id"] as? String, id == LanWire.id(of: key), id != ownId,
              let p = o["port"] as? Int, p > 0, p < 65536 else { return nil }
        return (id, LanWire.cleanText(o["name"], 40), UInt16(p), key)
    }

    private func discover(generation gen: Int) {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var yes: Int32 = 1
        for opt in [SO_REUSEADDR, SO_REUSEPORT, SO_BROADCAST] {
            setsockopt(fd, SOL_SOCKET, opt, &yes, socklen_t(MemoryLayout<Int32>.size))
        }
        var tv = timeval(tv_sec: 0, tv_usec: 500_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = INADDR_ANY
        addr.sin_port = Self.udpPort.bigEndian
        _ = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        func send(_ data: Data, to dest: sockaddr_in) {
            var d = dest
            _ = data.withUnsafeBytes { raw in
                withUnsafePointer(to: &d) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(fd, raw.baseAddress, raw.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
        }
        var broadcast = sockaddr_in()
        broadcast.sin_family = sa_family_t(AF_INET)
        broadcast.sin_addr.s_addr = INADDR_BROADCAST
        broadcast.sin_port = Self.udpPort.bigEndian

        var lastBeacon = Date.distantPast
        var buf = [UInt8](repeating: 0, count: 1500)
        while alive(gen) {
            if Date().timeIntervalSince(lastBeacon) >= 4, let b = beacon() {
                send(b, to: broadcast)
                lastBeacon = Date()
            }
            var changed = false
            var from = sockaddr_in()
            var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buf, buf.count, 0, $0, &fromLen) }
            }
            if n > 0 {
                let own = lock.withLock { me.map { LanWire.id(of: $0.publicKey.rawRepresentation) } ?? "" }
                if let b = Self.parseBeacon(Data(buf[0..<n]), ownId: own) {
                    let isNew: Bool = lock.withLock {
                        let old = seen[b.id]
                        seen[b.id] = Seen(name: b.name, addr: from.sin_addr, port: b.port, key: b.key, at: Date())
                        changed = old == nil || old?.name != b.name || old?.port != b.port || old?.addr.s_addr != from.sin_addr.s_addr
                        return old == nil
                    }
                    // Answer a newcomer straight away so it sees us without waiting.
                    if isNew, let mine = beacon() {
                        var back = from
                        back.sin_port = Self.udpPort.bigEndian
                        send(mine, to: back)
                    }
                }
            }
            lock.withLock {
                let before = seen.count
                seen = seen.filter { Date().timeIntervalSince($0.value.at) < 15 }
                if seen.count != before { changed = true }
            }
            if changed { publish() }
        }
    }

    // MARK: Server

    private func serve(fd: Int32, generation gen: Int) {
        while alive(gen) {
            let client = Darwin.accept(fd, nil, nil)
            if client < 0 {
                if !alive(gen) { return }
                Thread.sleep(forTimeInterval: 0.2)
                continue
            }
            Thread.detachNewThread { [self] in
                handle(fd: client)
                close(client)
            }
        }
    }

    private static func setTimeout(_ fd: Int32, _ seconds: Int) {
        var tv = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    private static func isTrusted(_ key: Data) -> Bool {
        let k = key.base64EncodedString()
        return loadTrusted().contains { $0.key == k }
    }

    private func handle(fd: Int32) {
        Self.setTimeout(fd, 15)
        guard let me = lock.withLock({ me }) else { return }
        do {
            let (ch, mode) = try LanWire.accept(fd: fd, me: me, name: Self.displayName, trusted: Self.isTrusted)
            if mode == "pair" { try pairFlow(ch, initiator: false); return }
            let request = try ch.recv()
            switch request["t"] as? String ?? "" {
            case "status?":
                let (s, label) = localStatus()
                try ch.send(["t": "status", "state": s, "label": Self.shareLabel ? label : ""])
            case "msg":
                let text = String((request["text"] as? String ?? "").prefix(2000))
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    try ch.send(["t": "error", "text": "empty"]); return
                }
                prompt(.message(peer: ch.peerName, peerId: ch.peerId, text: text))
                try ch.send(["t": "ok"])
            case "ask":
                try serveAsk(ch, request)
            case "file":
                try receiveFile(ch, request)
            default:
                try ch.send(["t": "error", "text": "unknown request"])
            }
        } catch {
            NSLog("Coucou LAN: \(error)")
        }
    }

    private final class AnswerBox: @unchecked Sendable {
        var ok = false
        var text = ""
    }

    private func serveAsk(_ ch: LanWire.Channel, _ request: [String: Any]) throws {
        let text = String((request["text"] as? String ?? "").prefix(4000))
        func refuse(_ why: String) throws { try ch.send(["t": "answer", "ok": false, "text": why]) }
        guard Self.allowAsks else { return try refuse("This Mochi doesn't take questions from other Mochis.") }
        let refusal: String? = lock.withLock {
            if asking { return "This Mochi is answering another question — try again in a moment." }
            if let last = lastAsk[ch.peerId], Date().timeIntervalSince(last) < 10 { return "One question every 10 seconds, please." }
            asking = true
            lastAsk[ch.peerId] = Date()
            return nil
        }
        if let refusal { return try refuse(refusal) }
        defer { lock.withLock { asking = false } }
        prompt(.asked(peer: ch.peerName))
        let box = AnswerBox()
        let done = DispatchSemaphore(value: 0)
        let peer = ch.peerName
        Task { @MainActor in
            let r = await ClaudeService.shared.answerForPeer(from: peer, text: text)
            box.ok = r.ok
            box.text = r.text
            done.signal()
        }
        if done.wait(timeout: .now() + 190) == .timedOut { return try refuse("This Mochi took too long to answer.") }
        try ch.send(["t": "answer", "ok": box.ok, "text": box.text])
    }

    private static func uniqueURL(in dir: URL, name: String) -> URL {
        var url = dir.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return url }
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        for i in 2..<1000 {
            url = dir.appendingPathComponent(ext.isEmpty ? "\(stem) (\(i))" : "\(stem) (\(i)).\(ext)")
            if !FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return dir.appendingPathComponent("\(stem)-\(LanWire.randomHex(4))\(ext.isEmpty ? "" : ".\(ext)")")
    }

    private func receiveFile(_ ch: LanWire.Channel, _ request: [String: Any]) throws {
        let name = LanWire.safeFileName(request["name"] as? String ?? "")
        let size = (request["size"] as? NSNumber)?.int64Value ?? Int64.max
        guard size >= 0, size <= Self.maxFile else {
            return try ch.send(["t": "file", "ok": false, "text": "Too large (512 MB at most)."])
        }
        let token = LanWire.randomHex(8)
        prompt(.file(token: token, peer: ch.peerName, name: name, size: size))
        ch.setTimeout(Int(Self.decideTimeout) + 5)
        let ok = waitDecision(token)
        try ch.send(["t": "file", "ok": ok])
        guard ok else { return }
        ch.setTimeout(30)

        let dir = Self.downloadsDir
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let part = dir.appendingPathComponent(".\(LanWire.randomHex(6)).part")
        FileManager.default.createFile(atPath: part.path, contents: nil)
        let out = try FileHandle(forWritingTo: part)
        var hash = SHA256()
        var got: Int64 = 0
        var failure: String? = nil
        loop: while true {
            let msg = try ch.recv()
            switch msg["t"] as? String {
            case "chunk":
                guard let s = msg["data"] as? String, let data = Data(base64Encoded: s) else { failure = "bad chunk"; break loop }
                got += Int64(data.count)
                if got > size { failure = "more data than announced"; break loop }
                hash.update(data: data)
                try out.write(contentsOf: data)
            case "end":
                let want = msg["sha256"] as? String ?? ""
                if got != size || LanWire.hex(Data(hash.finalize())) != want { failure = "the file arrived damaged" }
                break loop
            default:
                failure = "unexpected message"
                break loop
            }
        }
        try? out.close()
        if let failure {
            try? FileManager.default.removeItem(at: part)
            try? ch.send(["t": "error", "text": failure])
            return
        }
        let dest = Self.uniqueURL(in: dir, name: name)
        try FileManager.default.moveItem(at: part, to: dest)
        prompt(.received(peer: ch.peerName, name: name, path: dest.path))
        try ch.send(["t": "ok"])
    }

    // MARK: Pairing

    private func pairFlow(_ ch: LanWire.Channel, initiator: Bool) throws {
        let token = LanWire.randomHex(8)
        prompt(.pair(token: token, peer: ch.peerName, code: ch.code))
        ch.setTimeout(Int(Self.decideTimeout) * 2)
        let mine = waitDecision(token)
        try ch.send(["t": "pair", "ok": mine])
        let theirs = ((try? ch.recv())?["ok"] as? Bool) ?? false
        let paired = mine && theirs
        if paired {
            var list = Self.loadTrusted()
            list.removeAll { $0.id == ch.peerId }
            list.append(Trusted(id: ch.peerId, name: ch.peerName, key: ch.peerKey.base64EncodedString()))
            Self.saveTrusted(list)
        }
        prompt(.paired(peer: ch.peerName, ok: paired))
        publish()
    }

    // MARK: Client side (blocking — call off the main thread)

    struct Failure: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private func dial(_ id: String, mode: String) throws -> LanWire.Channel {
        let (me, peer): (Curve25519.Signing.PrivateKey?, Seen?) = lock.withLock { (self.me, seen[id]) }
        guard let me else { throw Failure(message: String(localized: "Turn on Mochis on the network in Settings first.")) }
        guard let peer else { throw Failure(message: String(localized: "That Mochi isn't on the network right now.")) }
        var expect: Data? = nil
        if mode == "session" {
            guard let t = Self.loadTrusted().first(where: { $0.id == id }), let k = Data(base64Encoded: t.key) else {
                throw Failure(message: String(localized: "Pair with that Mochi first."))
            }
            expect = k
        }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure(message: "socket") }
        // Non-blocking connect with a 5 s limit, then back to blocking I/O.
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr = peer.addr
        addr.sin_port = peer.port.bigEndian
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if rc != 0 {
            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            var err: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            guard errno == EINPROGRESS, poll(&pfd, 1, 5000) == 1,
                  getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len) == 0, err == 0 else {
                close(fd)
                throw Failure(message: String(localized: "Can't reach that Mochi."))
            }
        }
        _ = fcntl(fd, F_SETFL, flags)
        Self.setTimeout(fd, 15)
        do {
            return try LanWire.connect(fd: fd, me: me, name: Self.displayName, mode: mode, expect: expect)
        } catch {
            close(fd)
            throw Failure(message: String(localized: "Secure connection failed: \(String(describing: error))"))
        }
    }

    func pair(id: String) throws {
        let ch = try dial(id, mode: "pair")
        defer { close(ch.fd) }
        try pairFlow(ch, initiator: true)
    }

    private func request(_ id: String, _ message: [String: Any], wait: Int) throws -> [String: Any] {
        let ch = try dial(id, mode: "session")
        defer { close(ch.fd) }
        ch.setTimeout(wait)
        try ch.send(message)
        return try ch.recv()
    }

    func sendMessage(id: String, text: String) throws {
        let reply = try request(id, ["t": "msg", "text": String(text.prefix(2000))], wait: 15)
        guard reply["t"] as? String == "ok" else { throw Failure(message: String(localized: "That Mochi didn't take the message.")) }
    }

    func ask(id: String, text: String) throws -> String {
        let reply = try request(id, ["t": "ask", "text": String(text.prefix(4000))], wait: 200)
        let answer = reply["text"] as? String ?? ""
        guard reply["ok"] as? Bool == true else { throw Failure(message: answer) }
        return answer
    }

    func sendFile(id: String, url: URL) throws {
        let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        guard size <= Self.maxFile else { throw Failure(message: String(localized: "Too large to send (512 MB at most).")) }
        let ch = try dial(id, mode: "session")
        defer { close(ch.fd) }
        try ch.send(["t": "file", "name": LanWire.safeFileName(url.lastPathComponent), "size": size])
        ch.setTimeout(Int(Self.decideTimeout) + 10)
        let answer = try ch.recv()
        guard answer["ok"] as? Bool == true else {
            throw Failure(message: answer["text"] as? String ?? String(localized: "They declined the file."))
        }
        ch.setTimeout(60)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: Self.chunk), !data.isEmpty {
            hash.update(data: data)
            try ch.send(["t": "chunk", "data": data.base64EncodedString()])
        }
        try ch.send(["t": "end", "sha256": LanWire.hex(Data(hash.finalize()))])
        let done = try ch.recv()
        guard done["t"] as? String == "ok" else {
            throw Failure(message: done["text"] as? String ?? String(localized: "The transfer failed."))
        }
    }

    /// Runs a blocking call off the main thread, for SwiftUI buttons.
    static func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async -> Result<T, Error> {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: Result { try work() })
            }
        }
    }

    private func pollStatus(generation gen: Int) {
        var last = Date.distantPast
        while alive(gen) {
            Thread.sleep(forTimeInterval: 0.5)
            guard Date().timeIntervalSince(last) >= 10 else { continue }
            last = Date()
            let online: [String] = lock.withLock { Self.loadTrusted().map(\.id).filter { seen[$0] != nil } }
            var changed = false
            for id in online {
                let reply = try? request(id, ["t": "status?"], wait: 5)
                let next = reply.map { (state: LanWire.cleanText($0["state"], 16), label: LanWire.cleanText($0["label"], 80)) }
                lock.withLock {
                    let before = status[id]
                    status[id] = next
                    if before?.state != next?.state || before?.label != next?.label { changed = true }
                }
            }
            if changed { publish() }
        }
    }
}
#endif
