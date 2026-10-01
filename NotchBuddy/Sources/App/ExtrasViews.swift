import SwiftUI
import AppKit

// MARK: - Extras: cards and settings (GitHub build)

#if !APPSTORE
private let dim = Color(hex: "#8E939C")
private let soft = Color(hex: "#C5C8CD")

/// The header every Extras card shares: a coloured dot, a name, a subtitle.
private struct CardHeader: View {
    let color: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(Color(hex: color)).frame(width: 7, height: 7)
            Text(verbatim: title).font(.system(size: 12, weight: .semibold)).foregroundColor(Color(hex: "#F5F6F8"))
            Text(verbatim: subtitle).font(.system(size: 11)).foregroundColor(dim).lineLimit(1)
            Spacer(minLength: 2)
        }
        .padding(.top, 6)
    }
}

private func chip(_ text: String, _ color: String) -> some View {
    Text(verbatim: text)
        .font(.system(size: 11, weight: .medium)).foregroundColor(soft)
        .lineLimit(1).truncationMode(.tail)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Color(hex: color).opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 5))
}

private func linkButton(_ title: LocalizedStringKey, _ color: String, _ action: @escaping () -> Void) -> some View {
    Button(title, action: action)
        .font(.system(size: 11, weight: .medium)).foregroundColor(Color(hex: color)).buttonStyle(.plain)
}

private func ago(_ d: Date) -> String {
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .short
    return f.localizedString(for: d, relativeTo: Date())
}

// MARK: Custom

struct CustomCardView: View {
    let mochi: CustomMochi
    @ObservedObject var state: AppState

    var body: some View {
        let status = state.customStatus[mochi.id]
        VStack(alignment: .leading, spacing: 4) {
            CardHeader(color: mochi.color, title: mochi.name,
                       subtitle: status.map { ago($0.at) } ?? String(localized: "Waiting for news"))
            if let status, !status.text.isEmpty {
                chip(status.text, mochi.color)
            } else {
                Text(mochi.command.isEmpty ? "Send it news by URL or Shortcuts (Settings › Extras)." : "Runs its command every \(mochi.interval) s.")
                    .font(.system(size: 10.5)).foregroundColor(dim).lineLimit(2)
            }
            HStack(spacing: 12) {
                if !mochi.command.isEmpty {
                    linkButton("Run now", mochi.color) { CustomMochiRunner.shared.run(mochi) }
                }
                linkButton("Edit", "#8E939C") { NotificationCenter.default.post(name: .openFullSettings, object: "extras") }
            }
            .padding(.top, 2)
        }
        .padding(.leading, 108).padding(.trailing, 36)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

// MARK: Calendar

struct CalendarCardView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let e = state.calendarNext {
                CardHeader(color: "#FF6B6B", title: String(localized: "Calendar"), subtitle: when(e))
                chip(e.title, "#FF6B6B")
                Text(verbatim: e.start.formatted(date: .omitted, time: .shortened) + " – " + e.end.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 10)).foregroundColor(Color(hex: "#6B7079")).padding(.leading, 8)
                HStack(spacing: 12) {
                    if e.link != nil {
                        Button { CalendarMochi.join(e) } label: {
                            Label("Join", systemImage: "video.fill").font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.white).padding(.horizontal, 10).padding(.vertical, 3)
                                .background(Color(hex: "#23A55A")).clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                    linkButton("Open Calendar", "#FF6B6B") { CalendarMochi.join(CalendarEvent(id: "", title: "", start: e.start, end: e.end, link: nil)) }
                }
                .padding(.top, 2)
            } else {
                CardHeader(color: "#FF6B6B", title: String(localized: "Calendar"), subtitle: "")
                Text(state.calendarError.map { LocalizedStringKey($0) } ?? "Nothing in the next 24 hours. 🌴")
                    .font(.system(size: 10.5)).foregroundColor(dim).lineLimit(2)
            }
        }
        .padding(.leading, 108).padding(.trailing, 36)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func when(_ e: CalendarEvent) -> String {
        let m = Int((e.start.timeIntervalSinceNow / 60).rounded(.up))
        if m <= 0 { return String(localized: "Now") }
        if m < 60 { return String(localized: "In \(m) min") }
        return String(localized: "In \(m / 60) h \(m % 60) min")
    }
}

// MARK: Mac

struct SystemCardView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            let s = state.system
            CardHeader(color: "#94A3B8", title: "Mac",
                       subtitle: s?.building.map { String(localized: "Building · \($0)") } ?? String(localized: "All calm"))
            if let s {
                HStack(spacing: 10) {
                    gauge("cpu", "\(s.cpu) %", s.cpu > 85 ? "#F87171" : "#94A3B8")
                    if let b = s.battery {
                        gauge(s.charging ? "battery.100.bolt" : (b < 20 ? "battery.25" : "battery.75"), "\(b) %", b < 15 && !s.charging ? "#F87171" : "#94A3B8")
                    }
                    gauge("internaldrive", String(format: "%.0f GB", s.diskFreeGB), s.diskFreePercent < 5 ? "#F87171" : "#94A3B8")
                }
            } else {
                Text("Reading the Mac…").font(.system(size: 10.5)).foregroundColor(dim)
            }
        }
        .padding(.leading, 108).padding(.trailing, 36)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func gauge(_ icon: String, _ value: String, _ color: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 10))
            Text(verbatim: value).font(.system(size: 11, weight: .medium)).monospacedDigit()
        }
        .foregroundColor(Color(hex: color))
    }
}

// MARK: Weather

struct WeatherCardView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let w = state.weather {
                let (words, icon) = ExtrasParse.weather(code: w.code, day: w.day)
                CardHeader(color: "#38BDF8", title: String(localized: "Weather"), subtitle: w.place)
                HStack(spacing: 8) {
                    Image(systemName: icon).symbolRenderingMode(.multicolor).font(.system(size: 18))
                    Text(verbatim: "\(Int(w.temperature.rounded()))°").font(.system(size: 20, weight: .semibold)).foregroundColor(.white)
                    Text(verbatim: words).font(.system(size: 11)).foregroundColor(soft)
                }
                if w.rainChance > 0 {
                    Text("☔️ \(w.rainChance) % chance of rain in the next 2 h").font(.system(size: 10.5)).foregroundColor(dim)
                }
            } else {
                CardHeader(color: "#38BDF8", title: String(localized: "Weather"), subtitle: "")
                Text(state.weatherError.map { LocalizedStringKey($0) } ?? "Looking at the sky…")
                    .font(.system(size: 10.5)).foregroundColor(dim).lineLimit(2)
            }
        }
        .padding(.leading, 108).padding(.trailing, 36)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

// MARK: - Settings › Extras

struct ExtrasSettingsSection: View {
    @ObservedObject var state: AppState
    @State private var mochis = CustomMochis.all
    @State private var editing: String? = nil
    @State private var city = WeatherMochi.place?.name ?? ""
    @State private var message = ""
    @AppStorage(MochiVoice.key) private var voice = false
    @AppStorage(DesktopMochi.enabledKey) private var desktopMochi = false
    @AppStorage(DesktopMochi.followKey) private var petFollows = true
    @AppStorage(IslandWindowController.followScreenKey) private var islandFollows = true
    @AppStorage(PetBrain.walkerKey) private var petWalker = false
    @AppStorage(PetBrain.shakeKey) private var petShake = true
    @AppStorage(PetBrain.hideKey) private var petHides = true
    @AppStorage(MochiExtrasSync.seasonalKey) private var seasonal = true
    @AppStorage(MochiExtrasSync.birthdayKey) private var birthday = ""

    var body: some View {
        GroupBox("Desktop Mochi") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Mochi out of the notch, as a companion on your desktop: drag it anywhere, it follows you from screen to screen, says its news in a bubble. Click it to open the island there, double-click to send it home. You can also drag Mochi out of the island and drop it where there's no window.")
                    .font(.system(size: 11)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                Toggle("Mochi on the desktop", isOn: $desktopMochi)
                    .onChange(of: desktopMochi) { _, _ in DesktopMochi.shared.apply() }
                Toggle("It follows me to the screen I'm on", isOn: $petFollows)
                Toggle("It walks on top of my windows", isOn: $petWalker)
                Toggle("Shake the mouse to call it", isOn: $petShake)
                Toggle("It hides while I present or share my screen", isOn: $petHides)
                Text("Throw it: let go of a drag with speed. Leave it against a side edge and it peeks. Wiggle the cursor over it to pet it. Drop a file on it. Right-click or click it for its menu.")
                    .font(.system(size: 10)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                Toggle("The island follows me to the screen I'm on", isOn: $islandFollows)
            }
            .padding(6)
        }

        WorktreesSettingsSection()

        GroupBox("Custom Mochis") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Make your own: a name, a colour, something to wear, and where its news comes from — a command it runs, a local URL your scripts call, or Shortcuts.")
                    .font(.system(size: 11)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                ForEach($mochis) { $m in
                    CustomMochiEditor(mochi: $m, open: editing == m.id,
                                      toggle: { editing = editing == m.id ? nil : m.id },
                                      remove: { remove(m.id) })
                }
                HStack {
                    Button("Add a Mochi") {
                        let m = CustomMochi.new()
                        mochis.append(m)
                        editing = m.id
                    }
                    Button("Save") { save() }.buttonStyle(.borderedProminent)
                }
                if !mochis.isEmpty {
                    Text("From a script (the token is this Mac's own):").font(.system(size: 10)).foregroundColor(.secondary)
                    Text(verbatim: "curl -H \"X-Coucou-Token: \(CustomMochis.token)\" -d \"Build OK\" http://127.0.0.1:\(CustomMochis.port)/mochi/\(mochis[0].slug)")
                        .font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Output or body may start with ok:, working:, warning: or error: to set the mood. Turn the pills on in Integrations › Active pills.")
                        .font(.system(size: 10)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(6)
        }

        GroupBox("Calendar") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Your next meeting from the Mac's calendars, with a Join button, a heads-up 5 minutes before and a nervous Mochi at 1.")
                    .font(.system(size: 11)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                if CalendarMochi.authorized {
                    Text("✓ Calendar access allowed.").font(.system(size: 11)).foregroundColor(.secondary)
                } else {
                    Button("Allow calendar access") {
                        Task { message = await CalendarMochi.shared.requestAccess() ? "" : String(localized: "❌ macOS refused: allow Coucou in System Settings › Privacy & Security › Calendars.") }
                    }
                }
            }
            .padding(6)
        }

        GroupBox("Weather") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Open-Meteo (free, no account) for your city: an umbrella when rain is coming, a scarf in the cold, sunglasses in the sun.")
                    .font(.system(size: 11)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    TextField("City", text: $city).textFieldStyle(.roundedBorder).onSubmit { setCity() }
                    Button("Set") { setCity() }
                }
            }
            .padding(6)
        }

        GroupBox("Mochi") {
            VStack(alignment: .leading, spacing: 8) {
                let p = state.pet
                Text("Level \(p.level) · \(p.sessions) sessions · 🔥 \(p.streak)-day streak (best \(p.bestStreak))")
                    .font(.system(size: 12, weight: .semibold))
                if let next = p.nextTrophy {
                    Text("Next trophy: \(next.1.label) at \(next.0) sessions.").font(.system(size: 11)).foregroundColor(.secondary)
                }
                Picker("Wears", selection: Binding<MochiAccessory?>(get: { p.wearing }, set: { v in
                    state.pet.wearing = v
                    state.pet.save()
                })) {
                    Text("Best trophy").tag(MochiAccessory?.none)
                    ForEach([MochiAccessory.none] + p.unlocked, id: \.self) { a in Text(a.label).tag(Optional(a)) }
                }
                .disabled(p.unlocked.isEmpty)
                Toggle("Mochi speaks (finished sessions, meetings, DMs)", isOn: $voice)
                Toggle("Seasonal outfits (pumpkin in late October, Santa hat in December)", isOn: $seasonal)
                HStack {
                    Text("Your birthday (party hat and confetti)")
                    Spacer()
                    TextField("MM-dd", text: $birthday).textFieldStyle(.roundedBorder).frame(width: 70)
                }
            }
            .padding(6)
        }

        GroupBox("Focus modes") {
            VStack(alignment: .leading, spacing: 8) {
                Text("macOS doesn't tell apps which Focus is on, so a Shortcuts automation does: in Shortcuts › Automation › New › Focus, pick e.g. Do Not Disturb › When turning on › \"Set Mochi's mode\" (Do Not Disturb), and another for turning off (Normal). Do Not Disturb and Sleep put a mask on Mochi and keep Coucou quiet; Work puts glasses on.")
                    .font(.system(size: 11)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                Picker("Mode now", selection: $state.focusMode) {
                    Text("Normal").tag(FocusMode.normal)
                    Text("Do Not Disturb").tag(FocusMode.doNotDisturb)
                    Text("Work").tag(FocusMode.work)
                    Text("Sleep").tag(FocusMode.sleep)
                }
                .pickerStyle(.segmented)
            }
            .padding(6)
        }

        if !message.isEmpty {
            Text(message).font(.system(size: 11)).foregroundColor(message.hasPrefix("❌") ? .red : .secondary)
        }
    }

    private func save() {
        for i in mochis.indices {
            mochis[i].name = mochis[i].name.trimmingCharacters(in: .whitespaces)
            if mochis[i].name.isEmpty { mochis[i].name = "Mochi" }
            mochis[i].interval = max(5, mochis[i].interval)
        }
        CustomMochis.save(mochis)
        // Renamed or recoloured pills: reload their tasks.
        let ids = Set(mochis.map(\.id))
        state.tasks.removeAll { $0.id.hasPrefix("custom_") }
        state.activeIntegrations = state.activeIntegrations.filter { !$0.hasPrefix("custom_") || ids.contains($0) }
        state.loadIntegrationTasks()
        message = String(localized: "✓ Saved.")
    }

    private func remove(_ id: String) {
        mochis.removeAll { $0.id == id }
        save()
    }

    private func setCity() {
        let c = city.trimmingCharacters(in: .whitespaces)
        guard !c.isEmpty else { return }
        Task {
            guard let (name, lat, lon) = await WeatherMochi.geocode(c) else {
                message = String(localized: "❌ City not found.")
                return
            }
            UserDefaults.standard.set(["name": name, "lat": lat, "lon": lon], forKey: WeatherMochi.placeKey)
            city = name
            message = String(localized: "✓ Weather for \(name).")
            WeatherMochi.shared.tick(force: true)
        }
    }
}

/// One custom Mochi in Settings: a row that opens into its fields.
private struct CustomMochiEditor: View {
    @Binding var mochi: CustomMochi
    let open: Bool
    let toggle: () -> Void
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle().fill(Color(hex: mochi.color)).frame(width: 10, height: 10)
                Text(verbatim: mochi.name).font(.system(size: 12, weight: .medium))
                Text(verbatim: mochi.command.isEmpty ? String(localized: "URL / Shortcuts") : String(localized: "every \(mochi.interval) s"))
                    .font(.system(size: 10)).foregroundColor(.secondary)
                Spacer()
                Button(open ? "Done" : "Edit", action: toggle)
            }
            if open {
                TextField("Name", text: $mochi.name).textFieldStyle(.roundedBorder)
                HStack {
                    ColorPicker("Colour", selection: Binding(get: { Color(hex: mochi.color) }, set: { mochi.color = $0.hexString }),
                                supportsOpacity: false)
                    Picker("Wears", selection: $mochi.accessory) {
                        ForEach(MochiAccessory.wearable, id: \.self) { Text($0.label).tag($0) }
                    }
                }
                TextField("Command (optional) — e.g. curl -s https://my.app/health", text: $mochi.command)
                    .textFieldStyle(.roundedBorder).font(.system(size: 11, design: .monospaced))
                if !mochi.command.isEmpty {
                    Stepper("Every \(mochi.interval) s", value: $mochi.interval, in: 5...3600, step: 5)
                }
                Button("Delete \(mochi.name)", role: .destructive, action: remove)
            }
        }
        .padding(8)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

extension Color {
    /// #RRGGBB, for saving a ColorPicker's choice.
    var hexString: String {
        let c = NSColor(self).usingColorSpace(.sRGB) ?? .gray
        return String(format: "#%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }
}
#endif
