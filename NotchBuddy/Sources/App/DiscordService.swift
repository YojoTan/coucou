import Foundation
import Darwin
import AppKit
import Combine

// MARK: - DiscordService (GitHub build) — the Discord pill
// Three sources, from no setup to some:
//
// 1. Mentions: the number on Discord's Dock icon, read with `lsappinfo` every
//    5 s while the pill is on. No key, no permission.
// 2. Calls and DMs: Discord's local RPC socket ($TMPDIR/discord-ipc-N, frames of
//    op + length + JSON). It needs a Discord application of the user's own (the
//    client id and secret are in the Keychain) and one approval in Discord; the
//    token comes back from discord.com and lives in the Keychain too. Then the
//    pill follows the voice channel (who's in, who's speaking), mutes and
//    deafens on a click, and shows DMs and mentions as they arrive.
// 3. A webhook (DiscordWebhook below): send-only, to a channel the user picked.
//
// The socket is only opened while the pill is on, and only to a peer running
// as this same user (getpeereid).

#if !APPSTORE
struct DiscordMember: Sendable, Identifiable, Equatable {
    let id: String
    var name: String
    var muted: Bool
    var deafened: Bool
}

struct DiscordVoice: Sendable, Equatable {
    var channelId: String
    var name: String
    var members: [DiscordMember]
    var speaking: Set<String>
}

struct DiscordNote: Sendable, Identifiable, Equatable {
    let id: String
    let channelId: String
    let author: String
    let text: String
}

struct DiscordDevice: Sendable, Identifiable, Equatable {
    let id: String
    let name: String
}

/// Discord's microphones and outputs, and the ones in use.
struct DiscordDevices: Sendable, Equatable {
    var inputs: [DiscordDevice] = []
    var outputs: [DiscordDevice] = []
    var input = ""
    var output = ""
}

enum DiscordLink: Sendable, Equatable {
    case notSetUp          // no client id/secret in Settings
    case offline           // Discord isn't running, or its socket refused us
    case needsApproval     // set up, never approved (or the token was revoked)
    case waitingApproval   // the approval window is open in Discord
    case connected(String) // as this user
    case failed(String)
}

final class DiscordService: @unchecked Sendable {
    static let shared = DiscordService()
    static let taskId = "integration_discord"
    static let bundleId = "com.hnc.Discord"
    private static let scopes = ["rpc", "rpc.voice.read", "rpc.voice.write", "rpc.notifications.read", "identify"]

    private let q = DispatchQueue(label: "coucou.discord")
    private var timer: DispatchSourceTimer?
    // Everything below is touched on `q` only.
    private var fd: Int32 = -1
    private var ready = false
    private var wantsApproval = false
    private var nonce = 0
    private var pending: [String: ([String: Any]) -> Void] = [:]
    private var me: String? = nil
    private var channelId: String? = nil
    private var lastBadge: Int? = nil
    private var activity: (String, String?)? = nil  // what presence should say
    private var sentActivity: String? = nil
    private let activityStart = Int(Date().timeIntervalSince1970)

    private init() {}

    func start() {
        guard timer == nil else { return }
        MainActor.assumeIsolated { DiscordCall.shared.start() }
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now() + 3, repeating: 5)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    // MARK: Poll

    private func tick() {
        let on = DispatchQueue.main.sync {
            MainActor.assumeIsolated { AppState.shared.tasks.contains { $0.id == Self.taskId } }
        }
        let running = !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleId).isEmpty
        guard on, running else {
            if fd >= 0 { disconnect() }
            publish { s in
                s.discordRunning = running
                s.discordVoice = nil
                if case .connected = s.discordLink { s.discordLink = .offline }
            }
            lastBadge = nil
            return
        }
        let badge = Self.dockBadge()
        let rpcUp = fd >= 0 && me != nil
        let previous = lastBadge
        lastBadge = badge.count
        publish { s in
            s.discordRunning = true
            s.discordUnread = badge.count
            s.discordUnreadDot = badge.dot
            // Without the socket, a rising count is the only news there is.
            if !rpcUp, let previous, badge.count > previous { Self.alert(String(localized: "New mention on Discord"), nil) }
        }
        if fd < 0, credentials != nil, KeychainStore.shared.get("discord-access-token") != nil || wantsApproval {
            connect()
        } else if credentials == nil {
            publish { $0.discordLink = .notSetUp }
        } else if fd < 0 {
            publish { $0.discordLink = .needsApproval }
        }
    }

    /// The number on Discord's Dock icon; `dot` when it shows a dot (unread, no mention).
    static func dockBadge() -> (count: Int, dot: Bool) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/lsappinfo")
        p.arguments = ["info", "-only", "StatusLabel", "Discord"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return (0, false) }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return DiscordParse.badge(String(decoding: data, as: UTF8.self))
    }

    // MARK: Approval (Settings)

    private var credentials: (id: String, secret: String)? {
        guard let id = KeychainStore.shared.get("discord-client-id"), !id.isEmpty,
              let secret = KeychainStore.shared.get("discord-client-secret"), !secret.isEmpty else { return nil }
        return (id, secret)
    }

    /// "Connect to Discord": opens the approval window in the Discord app.
    func requestApproval() {
        q.async {
            self.wantsApproval = true
            if self.fd >= 0 && self.ready { self.authorize() } else { self.disconnect(); self.connect() }
        }
    }

    /// Forget the token (Settings → Disconnect).
    func signOut() {
        q.async {
            KeychainStore.shared.remove("discord-access-token")
            KeychainStore.shared.remove("discord-refresh-token")
            self.disconnect()
            self.publish { $0.discordLink = .needsApproval; $0.discordVoice = nil; $0.discordNotes = [] }
        }
    }

    // MARK: Socket

    private func connect() {
        guard let creds = credentials else { return }
        let dir = NSTemporaryDirectory()
        for i in 0..<10 {
            let path = (dir as NSString).appendingPathComponent("discord-ipc-\(i)")
            let s = socket(AF_UNIX, SOCK_STREAM, 0)
            guard s >= 0 else { return }
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            let cpath = Array(path.utf8CString)
            guard cpath.count <= MemoryLayout.size(ofValue: addr.sun_path) else { close(s); continue }
            withUnsafeMutableBytes(of: &addr.sun_path) { raw in
                for (j, c) in cpath.enumerated() where j < raw.count { raw[j] = UInt8(bitPattern: c) }
            }
            let rc = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            var uid = uid_t(0), gid = gid_t(0)
            guard rc == 0, getpeereid(s, &uid, &gid) == 0, uid == getuid() else { close(s); continue }
            var one: Int32 = 1
            setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            fd = s
            ready = false
            write(op: 0, ["v": 1, "client_id": creds.id])
            let reader = Thread { [weak self] in self?.readLoop(s) }
            reader.name = "coucou.discord.read"
            reader.start()
            return
        }
        publish { $0.discordLink = .offline }
    }

    private func disconnect() {
        if fd >= 0 { close(fd) }
        fd = -1
        ready = false
        me = nil
        channelId = nil
        pending = [:]
        sentActivity = nil
    }

    /// Blocking reads on its own thread; each frame is handled on `q`.
    private func readLoop(_ s: Int32) {
        func readExactly(_ n: Int) -> Data? {
            var data = Data(count: n)
            var got = 0
            while got < n {
                let r = data.withUnsafeMutableBytes { recv(s, $0.baseAddress! + got, n - got, 0) }
                if r <= 0 { return nil }
                got += r
            }
            return data
        }
        while true {
            guard let header = readExactly(8) else { break }
            let op = header.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self).littleEndian }
            let len = Int(header.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self).littleEndian })
            guard len >= 0, len < 4_000_000, let body = len == 0 ? Data() : readExactly(len) else { break }
            q.async { [weak self] in
                guard let self, self.fd == s else { return }
                let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
                switch op {
                case 1: self.handle(json)
                case 3: self.write(op: 4, json)          // ping → pong
                case 2: self.closed(json)                // Discord closed us, with a reason
                default: break
                }
            }
        }
        q.async { [weak self] in
            guard let self, self.fd == s else { return }
            self.disconnect()
            self.publish { s in
                s.discordVoice = nil
                if case .connected = s.discordLink { s.discordLink = .offline }
            }
        }
    }

    private func write(op: UInt32, _ payload: [String: Any]) {
        guard fd >= 0, let body = try? JSONSerialization.data(withJSONObject: payload) else { return }
        var frame = Data()
        withUnsafeBytes(of: op.littleEndian) { frame.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(body.count).littleEndian) { frame.append(contentsOf: $0) }
        frame.append(body)
        let sent = frame.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        if sent != frame.count { disconnect() }
    }

    /// One command; `reply` gets the whole response frame (check `evt == "ERROR"`).
    private func send(_ cmd: String, args: [String: Any] = [:], evt: String? = nil,
                      reply: (([String: Any]) -> Void)? = nil) {
        nonce += 1
        let n = "coucou-\(nonce)"
        var frame: [String: Any] = ["cmd": cmd, "args": args, "nonce": n]
        if let evt { frame["evt"] = evt }
        if let reply { pending[n] = reply }
        write(op: 1, frame)
    }

    private func closed(_ json: [String: Any]) {
        let message = json["message"] as? String ?? "Discord closed the connection."
        disconnect()
        // 4000 range: a bad client id; nothing will work until Settings change.
        publish { $0.discordLink = .failed(message) }
        wantsApproval = false
    }

    // MARK: Protocol

    private func handle(_ f: [String: Any]) {
        if let n = f["nonce"] as? String, let reply = pending.removeValue(forKey: n) {
            reply(f)
            return
        }
        guard f["cmd"] as? String == "DISPATCH" else { return }
        let data = f["data"] as? [String: Any] ?? [:]
        switch f["evt"] as? String {
        case "READY":
            ready = true
            pushActivity()
            if let token = KeychainStore.shared.get("discord-access-token"), !wantsApproval {
                authenticate(token)
            } else if wantsApproval {
                authorize()
            }
        case "VOICE_CHANNEL_SELECT":
            follow(channel: data["channel_id"] as? String)
        case "VOICE_STATE_CREATE", "VOICE_STATE_UPDATE":
            let m = Self.member(data)
            publish { s in
                guard var v = s.discordVoice, let m else { return }
                if let i = v.members.firstIndex(where: { $0.id == m.id }) { v.members[i] = m } else { v.members.append(m) }
                s.discordVoice = v
            }
        case "VOICE_STATE_DELETE":
            let id = (data["user"] as? [String: Any])?["id"] as? String
            publish { s in
                s.discordVoice?.members.removeAll { $0.id == id }
                if let id { s.discordVoice?.speaking.remove(id) }
            }
        case "SPEAKING_START", "SPEAKING_STOP":
            guard let id = data["user_id"] as? String else { return }
            let on = f["evt"] as? String == "SPEAKING_START"
            publish { s in
                if on { s.discordVoice?.speaking.insert(id) } else { s.discordVoice?.speaking.remove(id) }
            }
        case "VOICE_SETTINGS_UPDATE":
            let mute = data["mute"] as? Bool, deaf = data["deaf"] as? Bool
            let devices = Self.devices(data)
            publish { s in
                if let mute { s.discordSelfMute = mute }
                if let deaf { s.discordSelfDeaf = deaf }
                if let devices { s.discordDevices = devices }
            }
        case "NOTIFICATION_CREATE":
            let message = data["message"] as? [String: Any] ?? [:]
            let author = message["author"] as? [String: Any] ?? [:]
            let name = (author["global_name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? author["username"] as? String ?? data["title"] as? String ?? "Discord"
            let text = (message["content"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? data["body"] as? String ?? ""
            let note = DiscordNote(id: message["id"] as? String ?? UUID().uuidString,
                                   channelId: data["channel_id"] as? String ?? "",
                                   author: name, text: Self.oneLine(text, 140))
            publish { s in
                s.discordNotes.insert(note, at: 0)
                if s.discordNotes.count > 5 { s.discordNotes.removeLast() }
                Self.alert(String(localized: "\(name) on Discord"), note.text)
                s.showToast("\(name): \(note.text)", color: "#5865F2", icon: "at")
                MochiVoice.say(String(localized: "\(name) wrote to you"))
            }
        default:
            break
        }
    }

    private func authorize() {
        guard let creds = credentials else { return }
        wantsApproval = false
        publish { $0.discordLink = .waitingApproval }
        send("AUTHORIZE", args: ["client_id": creds.id, "scopes": Self.scopes]) { [weak self] f in
            guard let self else { return }
            guard f["evt"] as? String != "ERROR",
                  let code = (f["data"] as? [String: Any])?["code"] as? String else {
                let why = Self.errorMessage(f)
                self.publish { $0.discordLink = .failed(why) }
                return
            }
            Task {
                let result = await Self.token(["grant_type": "authorization_code", "code": code], creds)
                self.q.async {
                    switch result {
                    case .success(let token): self.authenticate(token)
                    case .failure(let e): self.publish { $0.discordLink = .failed(e.message) }
                    }
                }
            }
        }
    }

    private func authenticate(_ token: String, retried: Bool = false) {
        send("AUTHENTICATE", args: ["access_token": token]) { [weak self] f in
            guard let self else { return }
            if f["evt"] as? String == "ERROR" {
                // Expired or revoked: one refresh, else the user approves again.
                guard !retried, let creds = self.credentials,
                      let refresh = KeychainStore.shared.get("discord-refresh-token") else {
                    KeychainStore.shared.remove("discord-access-token")
                    self.publish { $0.discordLink = .needsApproval }
                    return
                }
                Task {
                    let result = await Self.token(["grant_type": "refresh_token", "refresh_token": refresh], creds)
                    self.q.async {
                        if case .success(let t) = result { self.authenticate(t, retried: true) } else {
                            KeychainStore.shared.remove("discord-access-token")
                            self.publish { $0.discordLink = .needsApproval }
                        }
                    }
                }
                return
            }
            let user = (f["data"] as? [String: Any])?["user"] as? [String: Any] ?? [:]
            self.me = user["id"] as? String
            let name = (user["global_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? user["username"] as? String ?? ""
            let meId = self.me
            self.publish { $0.discordLink = .connected(name); $0.discordMe = meId }
            self.send("SUBSCRIBE", evt: "VOICE_CHANNEL_SELECT")
            self.send("SUBSCRIBE", evt: "VOICE_SETTINGS_UPDATE")
            self.send("SUBSCRIBE", evt: "NOTIFICATION_CREATE")
            self.send("GET_VOICE_SETTINGS") { f in
                let d = f["data"] as? [String: Any] ?? [:]
                let mute = d["mute"] as? Bool ?? false, deaf = d["deaf"] as? Bool ?? false
                let devices = Self.devices(d)
                self.publish { s in
                    s.discordSelfMute = mute
                    s.discordSelfDeaf = deaf
                    if let devices { s.discordDevices = devices }
                }
            }
            self.send("GET_SELECTED_VOICE_CHANNEL") { f in
                self.follow(channel: (f["data"] as? [String: Any])?["id"] as? String)
            }
        }
    }

    /// Subscribes to the voice channel's events (and drops the previous one's).
    private func follow(channel id: String?) {
        if let old = channelId, old != id {
            for evt in ["VOICE_STATE_CREATE", "VOICE_STATE_UPDATE", "VOICE_STATE_DELETE", "SPEAKING_START", "SPEAKING_STOP"] {
                send("UNSUBSCRIBE", args: ["channel_id": old], evt: evt)
            }
        }
        channelId = id
        guard let id else {
            publish { $0.discordVoice = nil }
            return
        }
        for evt in ["VOICE_STATE_CREATE", "VOICE_STATE_UPDATE", "VOICE_STATE_DELETE", "SPEAKING_START", "SPEAKING_STOP"] {
            send("SUBSCRIBE", args: ["channel_id": id], evt: evt)
        }
        send("GET_CHANNEL", args: ["channel_id": id]) { [weak self] f in
            let d = f["data"] as? [String: Any] ?? [:]
            let members = (d["voice_states"] as? [[String: Any]] ?? []).compactMap(Self.member)
            let voice = DiscordVoice(channelId: id, name: d["name"] as? String ?? "", members: members, speaking: [])
            self?.publish { $0.discordVoice = voice }
        }
    }

    // MARK: Actions (all on a click)

    func setMute(_ on: Bool) { q.async { self.send("SET_VOICE_SETTINGS", args: ["mute": on]) } }
    func setDeaf(_ on: Bool) { q.async { self.send("SET_VOICE_SETTINGS", args: ["deaf": on]) } }
    func setInput(_ id: String) { q.async { self.send("SET_VOICE_SETTINGS", args: ["input": ["device_id": id]]) } }
    func setOutput(_ id: String) { q.async { self.send("SET_VOICE_SETTINGS", args: ["output": ["device_id": id]]) } }

    /// From DiscordMic, on the main queue.
    @MainActor
    static func talkingWhileMuted() { DiscordCall.shared.talkingWhileMuted() }

    /// Rich Presence (DiscordCall.pushPresence): details and state lines, nil clears.
    func setActivity(_ a: (String, String?)?) {
        q.async {
            self.activity = a
            self.pushActivity()
        }
    }

    /// Sends the wanted activity once per change (Discord rate-limits it).
    private func pushActivity() {
        guard fd >= 0, ready else { return }
        let key = activity.map { "\($0.0)|\($0.1 ?? "")" } ?? ""
        guard key != sentActivity else { return }
        sentActivity = key
        var args: [String: Any] = ["pid": Int(getpid())]
        if let (details, state) = activity {
            var a: [String: Any] = ["details": String(details.prefix(120)), "timestamps": ["start": activityStart]]
            if let state { a["state"] = String(state.prefix(120)) }
            args["activity"] = a
        }
        send("SET_ACTIVITY", args: args)
    }

    /// Discord to the front, on that channel when the socket is up.
    func open(channel: String?) {
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleId) {
            NSWorkspace.shared.open(app)
        }
        guard let channel, !channel.isEmpty else { return }
        q.async { self.send("SELECT_TEXT_CHANNEL", args: ["channel_id": channel]) }
    }

    // MARK: Helpers

    struct Failure: Error { let message: String }

    /// The OAuth token exchange (code or refresh); stores both tokens on success.
    private static func token(_ grant: [String: String], _ creds: (id: String, secret: String)) async -> Result<String, Failure> {
        var form = grant
        form["client_id"] = creds.id
        form["client_secret"] = creds.secret
        func post(_ form: [String: String]) async -> (Int, [String: Any])? {
            var req = URLRequest(url: URL(string: "https://discord.com/api/oauth2/token")!)
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            var allowed = CharacterSet.alphanumerics
            allowed.insert(charactersIn: "-._~")
            req.httpBody = form.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
                .joined(separator: "&").data(using: .utf8)
            guard let (data, resp) = try? await URLSession.shared.data(for: req) else { return nil }
            return ((resp as? HTTPURLResponse)?.statusCode ?? 0, (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:])
        }
        guard var (status, json) = await post(form) else { return .failure(Failure(message: String(localized: "discord.com can't be reached."))) }
        // Some apps want the redirect the code was issued for: the one Settings asks to add.
        if status == 400, grant["grant_type"] == "authorization_code", (json["error_description"] as? String ?? "").contains("redirect") {
            form["redirect_uri"] = "http://127.0.0.1"
            if let again = await post(form) { (status, json) = again }
        }
        guard status == 200, let access = json["access_token"] as? String else {
            let why = json["error_description"] as? String ?? json["error"] as? String ?? "HTTP \(status)"
            return .failure(Failure(message: why))
        }
        KeychainStore.shared.set("discord-access-token", value: access)
        if let refresh = json["refresh_token"] as? String { KeychainStore.shared.set("discord-refresh-token", value: refresh) }
        return .success(access)
    }

    /// `input`/`output` of a voice settings payload; nil when it carries none.
    private static func devices(_ d: [String: Any]) -> DiscordDevices? {
        guard let input = d["input"] as? [String: Any], let output = d["output"] as? [String: Any] else { return nil }
        func list(_ io: [String: Any]) -> [DiscordDevice] {
            (io["available_devices"] as? [[String: Any]] ?? []).compactMap { dev in
                guard let id = dev["id"] as? String else { return nil }
                return DiscordDevice(id: id, name: dev["name"] as? String ?? id)
            }
        }
        return DiscordDevices(inputs: list(input), outputs: list(output),
                              input: input["device_id"] as? String ?? "", output: output["device_id"] as? String ?? "")
    }

    private static func member(_ d: [String: Any]) -> DiscordMember? {
        guard let user = d["user"] as? [String: Any], let id = user["id"] as? String else { return nil }
        let state = d["voice_state"] as? [String: Any] ?? [:]
        let nick = (d["nick"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let name = nick ?? (user["global_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? user["username"] as? String ?? "?"
        return DiscordMember(id: id, name: name,
                             muted: (state["self_mute"] as? Bool ?? false) || (state["mute"] as? Bool ?? false),
                             deafened: (state["self_deaf"] as? Bool ?? false) || (state["deaf"] as? Bool ?? false))
    }

    private static func errorMessage(_ f: [String: Any]) -> String {
        let d = f["data"] as? [String: Any] ?? [:]
        let message = d["message"] as? String ?? "Discord refused."
        // RPC is in a closed beta: Discord grants it to the app's owner and testers.
        if message.lowercased().contains("scope") {
            return String(localized: "Discord refused the scopes (\(message)). The app must be yours, or list you as an App Tester.")
        }
        return message
    }

    static func oneLine(_ s: String, _ max: Int) -> String {
        String(s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").prefix(max))
    }

    private func publish(_ change: @escaping @MainActor @Sendable (AppState) -> Void) {
        DispatchQueue.main.async { MainActor.assumeIsolated { change(AppState.shared) } }
    }

    /// The pill's own alert: a sound, and a badge unless it is the focused one.
    @MainActor
    private static func alert(_ title: String, _ detail: String?) {
        let state = AppState.shared
        guard let i = state.tasks.firstIndex(where: { $0.id == taskId }) else { return }
        state.tasks[i].steps = [title, detail ?? ""].filter { !$0.isEmpty }
        state.tasks[i].stepIndex = max(0, state.tasks[i].steps.count - 1)
        if state.focusId != taskId { state.tasks[i].pillBadge = .approval }
        SoundEngine.shared.play("pop")
    }
}

// MARK: - DiscordWebhook — send-only, to the channel the user's webhook points at

enum DiscordWebhook {

    static var url: URL? {
        guard let s = KeychainStore.shared.get("discord-webhook"), DiscordParse.isWebhook(s) else { return nil }
        return URL(string: s)
    }

    /// Claude Code events the user opted into (Settings, off by default).
    static func notify(_ key: String, _ text: String) {
        guard UserDefaults.standard.bool(forKey: key), url != nil else { return }
        Task { _ = await send(text: text, file: nil) }
    }

    static let maxFileSize = 10 * 1024 * 1024

    /// Posts a message, with a file if given; nil on success, else why not.
    static func send(text: String, file: URL?) async -> String? {
        guard let url else { return String(localized: "No Discord webhook in Settings.") }
        // No @everyone, @here or role pings from Coucou.
        let payload: [String: Any] = ["content": String(text.prefix(1900)), "allowed_mentions": ["parse": []]]
        guard let json = try? JSONSerialization.data(withJSONObject: payload) else { return "JSON" }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        if let file {
            guard let data = try? Data(contentsOf: file) else { return String(localized: "The file can't be read.") }
            guard data.count <= maxFileSize else { return String(localized: "Discord takes files up to 10 MB.") }
            let boundary = "coucou-\(UUID().uuidString)"
            req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            var body = Data()
            func part(_ header: String, _ content: Data) {
                body.append("--\(boundary)\r\n\(header)\r\n\r\n".data(using: .utf8)!)
                body.append(content)
                body.append("\r\n".data(using: .utf8)!)
            }
            part("Content-Disposition: form-data; name=\"payload_json\"\r\nContent-Type: application/json", json)
            let name = file.lastPathComponent.replacingOccurrences(of: "\"", with: "")
            part("Content-Disposition: form-data; name=\"files[0]\"; filename=\"\(name)\"\r\nContent-Type: application/octet-stream", data)
            body.append("--\(boundary)--\r\n".data(using: .utf8)!)
            req.httpBody = body
        } else {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = json
        }
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else {
            return String(localized: "discord.com can't be reached.")
        }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        return (200..<300).contains(status) ? nil : "Discord: HTTP \(status)"
    }
}
#endif
