import SwiftUI

// MARK: - Discord card and settings (GitHub build) — DiscordService

#if !APPSTORE
private let blurple = Color(hex: "#5865F2")
private let dim = Color(hex: "#8E939C")

struct DiscordCardView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(blurple).frame(width: 7, height: 7)
                Text("Discord").font(.system(size: 12, weight: .semibold)).foregroundColor(Color(hex: "#F5F6F8"))
                Text(verbatim: subtitle).font(.system(size: 11)).foregroundColor(dim).lineLimit(1)
                Spacer(minLength: 2)
            }
            .padding(.top, 6)
            if let voice = state.discordVoice {
                voiceRows(voice)
            } else {
                noteRows
            }
        }
        .padding(.leading, 108)
        .padding(.trailing, 36)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var subtitle: String {
        if !state.discordRunning { return String(localized: "Not running") }
        if let v = state.discordVoice { return v.name.isEmpty ? String(localized: "In a call") : "🔊 \(v.name)" }
        if state.discordUnread > 0 {
            return state.discordUnread == 1 ? String(localized: "1 mention") : String(localized: "\(state.discordUnread) mentions")
        }
        return state.discordUnreadDot ? String(localized: "Unread messages") : String(localized: "All read")
    }

    // In a call: who's in (lit while speaking), then mute, deafen, open.
    @ViewBuilder private func voiceRows(_ v: DiscordVoice) -> some View {
        if state.discordTalkingMuted {
            HStack(spacing: 6) {
                Image(systemName: "mic.slash.fill").font(.system(size: 9, weight: .bold))
                Text("You're muted!").font(.system(size: 11, weight: .semibold))
                Button("Unmute") {
                    DiscordService.shared.setMute(false)
                    state.discordTalkingMuted = false
                }
                .font(.system(size: 11, weight: .bold)).buttonStyle(.plain).underline()
            }
            .foregroundColor(.white)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Color(hex: "#DA373C"))
            .clipShape(Capsule())
        }
        HStack(spacing: 4) {
            ForEach(v.members.prefix(7)) { m in
                MemberDot(member: m, speaking: v.speaking.contains(m.id))
            }
            if v.members.count > 7 {
                Text(verbatim: "+\(v.members.count - 7)").font(.system(size: 10)).foregroundColor(dim)
            }
        }
        .padding(.vertical, 2)
        HStack(spacing: 6) {
            toggle(state.discordSelfMute ? "mic.slash.fill" : "mic.fill", on: state.discordSelfMute,
                   help: state.discordSelfMute ? "Unmute" : "Mute") {
                DiscordService.shared.setMute(!state.discordSelfMute)
            }
            toggle(state.discordSelfDeaf ? "speaker.slash.fill" : "headphones", on: state.discordSelfDeaf,
                   help: state.discordSelfDeaf ? "Undeafen" : "Deafen") {
                DiscordService.shared.setDeaf(!state.discordSelfDeaf)
            }
            if !state.discordDevices.inputs.isEmpty { deviceMenu }
            Button("Open Discord") { DiscordService.shared.open(channel: nil) }
                .font(.system(size: 11, weight: .medium)).foregroundColor(blurple).buttonStyle(.plain)
        }
        .padding(.top, 2)
    }

    /// Microphone and output, as Discord lists them.
    private var deviceMenu: some View {
        let d = state.discordDevices
        return Menu {
            Section("Microphone") {
                ForEach(d.inputs) { dev in
                    Button { DiscordService.shared.setInput(dev.id) } label: { check(dev.id == d.input, dev.name) }
                }
            }
            Section("Output") {
                ForEach(d.outputs) { dev in
                    Button { DiscordService.shared.setOutput(dev.id) } label: { check(dev.id == d.output, dev.name) }
                }
            }
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(Color(hex: "#C5C8CD"))
                .frame(width: 30, height: 20)
                .background(Color.white.opacity(0.07))
                .clipShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(Text("Microphone and output"))
    }

    private func check(_ on: Bool, _ title: String) -> Text {
        Text(verbatim: on ? "✓ \(title)" : title)
    }

    // Not in a call: the latest DMs and mentions, or what's missing to get them.
    @ViewBuilder private var noteRows: some View {
        let summary = state.discordLastCall.flatMap { Date().timeIntervalSince($0.endedAt) < 30 * 60 ? $0 : nil }
        if let summary { lastCallRow(summary) }
        if state.discordNotes.isEmpty && summary == nil {
            Text(hint).font(.system(size: 10.5)).foregroundColor(dim).lineLimit(2)
        }
        ForEach(state.discordNotes.prefix(summary == nil ? 2 : 1)) { n in
            HStack(spacing: 5) {
                Text(verbatim: n.author).font(.system(size: 11, weight: .semibold)).foregroundColor(Color(hex: "#E8E9EC"))
                    .lineLimit(1).fixedSize()
                Text(verbatim: n.text).font(.system(size: 11)).foregroundColor(Color(hex: "#C5C8CD"))
                    .lineLimit(1).truncationMode(.tail)
            }
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(blurple.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
            .onTapGesture { DiscordService.shared.open(channel: n.channelId) }
            .help(Text("Open in Discord"))
        }
        Button("Open Discord") { DiscordService.shared.open(channel: nil) }
            .font(.system(size: 11, weight: .medium)).foregroundColor(blurple).buttonStyle(.plain)
            .padding(.top, 2)
    }

    /// The call that just ended: length, who talked how much, and a summary on demand.
    @ViewBuilder private func lastCallRow(_ c: DiscordCallSummary) -> some View {
        HStack(spacing: 6) {
            Text(verbatim: callLine(c)).font(.system(size: 11)).foregroundColor(Color(hex: "#C5C8CD")).lineLimit(1)
            if state.discordTranscript != nil {
                Button("Summarize") { summarize() }
                    .font(.system(size: 11, weight: .semibold)).foregroundColor(blurple).buttonStyle(.plain)
                    .help(Text("Your side of the call goes to your chat engine, which writes a summary and to-dos."))
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    private func callLine(_ c: DiscordCallSummary) -> String {
        var parts = ["📞 " + String(localized: "\(c.minutes) min")]
        if c.myShare > 0 || c.top != nil {
            parts.append(String(localized: "you \(Int((c.myShare * 100).rounded())) %") + (c.myShare > 0.6 && c.top != nil ? " 🎤" : ""))
        }
        if let top = c.top, c.topShare > 0 { parts.append("\(top) \(Int((c.topShare * 100).rounded())) %") }
        if c.missed > 0 { parts.append(String(localized: "\(c.missed) alerts")) }
        return parts.joined(separator: " · ")
    }

    /// The transcript leaves only on this click, to the user's chat engine.
    private func summarize() {
        guard let text = state.discordTranscript else { return }
        state.discordTranscript = nil
        let ask = String(localized: "Summarize this call for me in a few lines, then list the to-dos and decisions. It's only my side of the conversation, transcribed automatically, so expect mistakes.")
        state.chatHistory.append(ChatMessage(role: .user, content: String(localized: "Summarize the call")))
        state.stateOverride = .thinking
        state.view = .prompt
        Task {
            await ClaudeService.shared.chat(query: "\(ask)\n\n<transcript>\n\(text)\n</transcript>", context: nil, state: state)
        }
    }

    private var hint: LocalizedStringKey {
        switch state.discordLink {
        case .connected: return "DMs and mentions show up here, calls too."
        case .waitingApproval: return "Approve Coucou in the Discord window."
        case .failed: return "Discord connection failed — see Settings › Discord."
        default: return "Connect Discord in Settings for calls, mute and DMs."
        }
    }

    private func toggle(_ icon: String, on: Bool, help: LocalizedStringKey, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(on ? Color(hex: "#F87171") : Color(hex: "#C5C8CD"))
                .frame(width: 30, height: 20)
                .background(on ? Color(hex: "#F87171").opacity(0.16) : Color.white.opacity(0.07))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(Text(help))
    }
}

/// One person in the call, as a tiny Mochi of their own colour: it talks when
/// they talk, keeps its mouth shut when muted, sleeps when deafened.
private struct MemberDot: View {
    let member: DiscordMember
    let speaking: Bool
    @StateObject private var engine: BotEngine

    init(member: DiscordMember, speaking: Bool) {
        self.member = member
        self.speaking = speaking
        _engine = StateObject(wrappedValue: {
            let e = BotEngine()
            e.isMini = true
            e.mouthAlways = true
            e.bodyColor = cgColorFromHex(IslandConst.colorForProject(member.name))
            return e
        }())
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            TimelineView(.animation) { timeline in
                Canvas { context, size in
                    let now = timeline.date.timeIntervalSinceReferenceDate
                    engine.update(dt: min(0.05, now - engine.lastTime))
                    engine.draw(context: context, size: size)
                }
            }
            .frame(width: 26, height: 26)
            .frame(width: 22, height: 22)
            .background(Circle().fill(Color(hex: "#23A55A").opacity(speaking ? 0.28 : 0)).frame(width: 24, height: 24))
            .onAppear(perform: sync)
            .onChange(of: speaking) { _, _ in sync() }
            .onChange(of: member) { _, _ in sync() }
            if member.muted || member.deafened {
                Image(systemName: member.deafened ? "speaker.slash.fill" : "mic.slash.fill")
                    .font(.system(size: 6.5, weight: .bold))
                    .foregroundColor(.white)
                    .padding(1.5)
                    .background(Circle().fill(Color(hex: "#DA373C")))
                    .offset(x: 3, y: 2)
            }
        }
        .help(Text(verbatim: member.name))
        .animation(.easeOut(duration: 0.12), value: speaking)
    }

    private func sync() {
        engine.micMuted = member.muted || member.deafened
        engine.deafened = member.deafened
        engine.talking = speaking && !engine.micMuted
    }
}

struct DiscordSettingsSection: View {
    @ObservedObject var state: AppState
    @State private var clientId = KeychainStore.shared.get("discord-client-id") ?? ""
    @State private var clientSecret = KeychainStore.shared.get("discord-client-secret") ?? ""
    @State private var webhook = KeychainStore.shared.get("discord-webhook") ?? ""
    @AppStorage("discord-post-finished") private var postFinished = false
    @AppStorage("discord-post-permission") private var postPermission = false
    @AppStorage(DiscordCall.pauseSpotifyKey) private var pauseSpotify = true
    @AppStorage(DiscordCall.quietKey) private var quietCalls = true
    @AppStorage(DiscordCall.lockMuteKey) private var lockMute = true
    @AppStorage(DiscordCall.presenceKey) private var presence = false
    @AppStorage(DiscordMic.alertKey) private var mutedAlert = false
    @AppStorage(DiscordMic.transcribeKey) private var transcribe = false
    @State private var message = ""
    @State private var testing = false

    var body: some View {
        GroupBox("Calls, mute and DMs") {
            VStack(alignment: .leading, spacing: 8) {
                Text("The mention count needs nothing. For calls, mute and DMs, Coucou talks to the Discord app on this Mac through an application of your own: create it at discord.com/developers/applications, copy its Client ID and Client Secret from OAuth2, and add http://127.0.0.1 as a redirect there.")
                    .font(.system(size: 11)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                TextField("Client ID", text: $clientId).textFieldStyle(.roundedBorder)
                SecureField("Client Secret", text: $clientSecret).textFieldStyle(.roundedBorder)
                HStack(spacing: 8) {
                    Button(isConnected ? "Reconnect" : "Connect to Discord") { connect() }
                        .buttonStyle(.borderedProminent)
                        .disabled(clientId.isEmpty || clientSecret.isEmpty)
                    if isConnected {
                        Button("Disconnect") { DiscordService.shared.signOut() }
                    }
                }
                Text(status).font(.system(size: 11)).foregroundColor(statusIsError ? .red : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Turn the Discord pill on in Integrations › Active pills.")
                    .font(.system(size: 10)).foregroundColor(.secondary)
            }
            .padding(6)
        }

        GroupBox("During calls") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Pause Spotify during calls", isOn: $pauseSpotify)
                Toggle("Call mode: Coucou stays quiet, and sums up after", isOn: $quietCalls)
                Toggle("Mute me when the screen locks", isOn: $lockMute)
                Toggle("Warn me when I talk while muted", isOn: $mutedAlert)
                    .onChange(of: mutedAlert) { _, on in askMic(on, speech: false) }
                Text("Coucou listens to the microphone's level only — while you're muted in a call, never recorded, never sent. macOS shows its orange dot meanwhile.")
                    .font(.system(size: 10)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                Toggle("Transcribe my voice to summarize the call", isOn: $transcribe)
                    .onChange(of: transcribe) { _, on in askMic(on, speech: true) }
                Text("Only your side, on this Mac (Apple's on-device recognition); the text is kept until the call ends, for the Summarize button, and goes to your chat engine only if you click it.")
                    .font(.system(size: 10)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                Toggle("Show what Mochi is doing on my Discord profile", isOn: $presence)
                    .onChange(of: presence) { _, _ in DiscordCall.pushPresence() }
                Text("Your friends see \"🤖 Claude Code is working on coucou\" or the song Spotify plays, under the Coucou app.")
                    .font(.system(size: 10)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(6)
        }

        GroupBox("Webhook") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Send-only, to one channel: in Discord, Channel settings › Integrations › Webhooks › New webhook › Copy URL. Then a dropped file can go to that channel, and Coucou can post there when Claude Code finishes or asks for permission (project and tool names, and the start of Claude's last reply).")
                    .font(.system(size: 11)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                SecureField("https://discord.com/api/webhooks/…", text: $webhook).textFieldStyle(.roundedBorder)
                Toggle("Post when Claude Code finishes", isOn: $postFinished)
                Toggle("Post when Claude Code asks for permission", isOn: $postPermission)
                HStack(spacing: 8) {
                    Button("Save webhook") { saveWebhook() }
                    Button(testing ? "Sending…" : "Send a test") { test() }
                        .disabled(testing || !DiscordParse.isWebhook(webhook))
                }
                if !message.isEmpty {
                    Text(message).font(.system(size: 11)).foregroundColor(message.hasPrefix("❌") ? .red : .secondary)
                }
            }
            .padding(6)
        }
    }

    /// Turning a mic option on asks macOS first; a refusal turns it back off.
    private func askMic(_ on: Bool, speech: Bool) {
        guard on else { DiscordCall.shared.refreshMic(); return }
        Task {
            var ok = await DiscordMic.requestMic()
            if ok && speech { ok = await DiscordMic.requestSpeech() }
            if !ok {
                if speech { transcribe = false } else { mutedAlert = false }
                message = String(localized: "❌ macOS refused: allow Coucou in System Settings › Privacy & Security.")
            }
            DiscordCall.shared.refreshMic()
        }
    }

    private var isConnected: Bool {
        if case .connected = state.discordLink { return true }
        return false
    }

    private var statusIsError: Bool {
        if case .failed = state.discordLink { return true }
        return false
    }

    private var status: String {
        switch state.discordLink {
        case .notSetUp: return String(localized: "Not set up.")
        case .offline: return String(localized: "Discord isn't running (or the pill is off).")
        case .needsApproval: return String(localized: "Not connected yet: click Connect, then approve in Discord.")
        case .waitingApproval: return String(localized: "Waiting for your approval in the Discord window…")
        case .connected(let name): return String(localized: "✓ Connected as \(name).")
        case .failed(let why): return "❌ \(why)"
        }
    }

    private func connect() {
        let id = clientId.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard id.allSatisfy(\.isNumber) else {
            message = String(localized: "❌ The Client ID is a number.")
            return
        }
        KeychainStore.shared.set("discord-client-id", value: id)
        KeychainStore.shared.set("discord-client-secret", value: secret)
        if !state.activeIntegrations.contains(DiscordService.taskId) && state.activeIntegrations.count < 4 {
            state.toggleIntegration(DiscordService.taskId)
        }
        DiscordService.shared.requestApproval()
    }

    private func saveWebhook() {
        let url = webhook.trimmingCharacters(in: .whitespacesAndNewlines)
        if url.isEmpty {
            KeychainStore.shared.remove("discord-webhook")
            message = String(localized: "Webhook removed.")
        } else if DiscordParse.isWebhook(url) {
            KeychainStore.shared.set("discord-webhook", value: url)
            message = String(localized: "✓ Webhook saved.")
        } else {
            message = String(localized: "❌ That isn't a Discord webhook URL.")
        }
    }

    private func test() {
        saveWebhook()
        guard DiscordWebhook.url != nil else { return }
        testing = true
        Task {
            let error = await DiscordWebhook.send(text: String(localized: "👋 Coucou is connected to this channel."), file: nil)
            testing = false
            message = error.map { "❌ \($0)" } ?? String(localized: "✓ Sent — check the channel.")
        }
    }
}
#endif
