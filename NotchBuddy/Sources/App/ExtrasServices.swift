import Foundation
import AppKit
import EventKit
import IOKit.ps
import Darwin

// MARK: - Extras: the Calendar, Mac and Weather pills (GitHub build)
// Each one works only while its pill is on.
//
// • Calendar — the Mac's own calendars (EventKit, one permission, no account):
//   the next meeting, a Join button for Meet/Zoom/Teams/Webex links, a toast
//   5 minutes before and a sweating Mochi at 1.
// • Mac — CPU, battery, free disk and running builds, read locally every 5 s:
//   Mochi sweats over 85 % CPU, gets sleepy on a low battery, panics on a full
//   disk and puts a hard hat on while xcodebuild, cargo, swift… run.
// • Weather — Open-Meteo (free, no key) for the city typed in Settings, every
//   15 minutes: an umbrella when rain is likely within two hours, a scarf in
//   the cold, sunglasses on a hot clear day. Only that city's coordinates go out.

#if !APPSTORE
private func pillOn(_ id: String) -> Bool {
    MainActor.assumeIsolated { AppState.shared.tasks.contains { $0.id == id } }
}

// MARK: Calendar

struct CalendarEvent: Equatable, Sendable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let link: URL?
}

@MainActor
final class CalendarMochi {
    static let shared = CalendarMochi()
    static let taskId = "integration_calendar"
    private let store = EKEventStore()
    private var timer: Timer?
    private var alerted: Set<String> = []

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { _ in
            MainActor.assumeIsolated { CalendarMochi.shared.tick() }
        }
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { _ in
            MainActor.assumeIsolated { CalendarMochi.shared.tick() }
        }
    }

    static var authorized: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }

    func requestAccess() async -> Bool {
        let ok = (try? await store.requestFullAccessToEvents()) ?? false
        tick()
        return ok
    }

    func tick() {
        let state = AppState.shared
        guard state.tasks.contains(where: { $0.id == Self.taskId }) else { return }
        guard Self.authorized else {
            state.calendarError = String(localized: "Allow calendar access in Settings › Extras.")
            return
        }
        state.calendarError = nil
        let now = Date()
        let events = store.events(matching: store.predicateForEvents(withStart: now.addingTimeInterval(-3600),
                                                                      end: now.addingTimeInterval(86_400), calendars: nil))
            .filter { !$0.isAllDay && $0.endDate > now && $0.status != .canceled }
            .sorted { $0.startDate < $1.startDate }
        // The meeting in progress if it started under 10 min ago, else the next one.
        let e = events.first { $0.startDate > now.addingTimeInterval(-600) } ?? events.first
        let next = e.map {
            CalendarEvent(id: $0.calendarItemIdentifier + "\($0.startDate.timeIntervalSince1970)",
                          title: $0.title ?? String(localized: "Event"), start: $0.startDate, end: $0.endDate,
                          link: ExtrasParse.meetingLink(in: [$0.url?.absoluteString, $0.location, $0.notes]))
        }
        if state.calendarNext != next { state.calendarNext = next }
        guard let next, let i = state.tasks.firstIndex(where: { $0.id == Self.taskId }) else { return }
        let minutes = next.start.timeIntervalSince(now) / 60
        state.tasks[i].steps = [next.title]
        if minutes <= 5.5, minutes > 1.5, !alerted.contains(next.id + "5") {
            alerted.insert(next.id + "5")
            state.showToast(String(localized: "In 5 min: \(next.title)"), color: "#FF6B6B", icon: "calendar", seconds: 5)
            MochiVoice.say(String(localized: "\(next.title) starts in five minutes"))
            if state.focusId != Self.taskId { state.tasks[i].pillBadge = .approval }
            SoundEngine.shared.play("tick")
        } else if minutes <= 1.5, minutes > -1, !alerted.contains(next.id + "1") {
            alerted.insert(next.id + "1")
            state.showToast(String(localized: "Starting now: \(next.title)"), color: "#FF6B6B", icon: "video.fill", seconds: 6)
            MochiVoice.say(String(localized: "Your meeting is starting"))
            SoundEngine.shared.play("approval")
            NotificationCenter.default.post(name: .hookReveal, object: nil)
        }
    }

    static func join(_ e: CalendarEvent) {
        if let link = e.link { NSWorkspace.shared.open(link) }
        else if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") { NSWorkspace.shared.open(app) }
    }
}

// MARK: Mac

struct SystemSnapshot: Equatable, Sendable {
    var cpu: Int
    var battery: Int?
    var charging: Bool
    var diskFreeGB: Double
    var diskFreePercent: Double
    var building: String?
}

final class SystemMochi: @unchecked Sendable {
    static let shared = SystemMochi()
    static let taskId = "integration_system"
    /// Processes that mean "something is building".
    static let builders = ["xcodebuild", "swift-build", "swift-frontend", "cargo", "rustc", "clang", "gradle", "go", "tsc", "esbuild", "webpack", "vite", "make", "ninja", "msbuild", "dotnet"]
    private let q = DispatchQueue(label: "coucou.system")
    private var timer: DispatchSourceTimer?
    private var prevTicks: [UInt32]? = nil
    private var warnedDisk = false
    private var warnedBattery = false

    func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now() + 2, repeating: 5)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private func tick() {
        guard DispatchQueue.main.sync(execute: { pillOn(Self.taskId) }) else { prevTicks = nil; return }
        let (level, charging) = battery(), (freeGB, freePct) = disk()
        let snap = SystemSnapshot(cpu: cpu(), battery: level, charging: charging,
                                  diskFreeGB: freeGB, diskFreePercent: freePct, building: building())
        let lowBattery = (snap.battery ?? 100) <= 10 && !snap.charging
        let fullDisk = snap.diskFreePercent < 5
        let toastBattery = lowBattery && !warnedBattery, toastDisk = fullDisk && !warnedDisk
        warnedBattery = lowBattery
        if fullDisk { warnedDisk = true }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let state = AppState.shared
                if state.system != snap { state.system = snap }
                if let i = state.tasks.firstIndex(where: { $0.id == Self.taskId }) {
                    state.tasks[i].state = snap.building != nil ? .working : (snap.cpu > 85 ? .thinking : .idle)
                }
                if toastBattery { state.showToast(String(localized: "Battery at \(snap.battery ?? 0) % — plug me in"), color: "#F87171", icon: "battery.25") }
                if toastDisk { state.showToast(String(localized: "Disk almost full: \(Int(snap.diskFreeGB)) GB left"), color: "#F87171", icon: "internaldrive.fill") }
            }
        }
    }

    /// All cores, since the last tick.
    private func cpu() -> Int {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count) }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        let t = [info.cpu_ticks.0, info.cpu_ticks.1, info.cpu_ticks.2, info.cpu_ticks.3]   // user, system, idle, nice
        defer { prevTicks = t }
        guard let p = prevTicks else { return 0 }
        let d = zip(t, p).map { Double($0 &- $1) }
        let total = d.reduce(0, +)
        return total > 0 ? Int(((total - d[2]) / total * 100).rounded()) : 0
    }

    private func battery() -> (Int?, Bool) {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let list = IOPSCopyPowerSourcesList(info).takeRetainedValue() as [CFTypeRef]
        for src in list {
            guard let d = IOPSGetPowerSourceDescription(info, src)?.takeUnretainedValue() as? [String: Any],
                  let cur = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            let charging = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            return (cur * 100 / max, charging)
        }
        return (nil, true)   // a desktop Mac
    }

    private func disk() -> (Double, Double) {
        let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
        let free = Double(v?.volumeAvailableCapacityForImportantUsage ?? 0), total = Double(v?.volumeTotalCapacity ?? 1)
        return (free / 1e9, total > 0 ? free / total * 100 : 100)
    }

    /// The first builder process found, by name.
    private func building() -> String? {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return nil }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        var name = [CChar](repeating: 0, count: 256)
        for pid in pids.prefix(Int(max(0, n))) where pid > 0 {
            guard proc_name(pid, &name, UInt32(name.count)) > 0 else { continue }
            let s = String(cString: name)
            if Self.builders.contains(s) { return s }
        }
        return nil
    }
}

// MARK: Weather

struct WeatherNow: Equatable, Sendable {
    let place: String
    let temperature: Double
    let code: Int
    let day: Bool
    let rainChance: Int          // highest in the next two hours, %
    var accessory: MochiAccessory {
        ExtrasParse.weatherAccessory(code: code, temperature: temperature, day: day, rainChance: rainChance)
    }
}

@MainActor
final class WeatherMochi {
    static let shared = WeatherMochi()
    static let taskId = "integration_weather"
    static let placeKey = "weather-place"        // {"name", "lat", "lon"}
    private var timer: Timer?
    private var lastFetch = Date.distantPast

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            MainActor.assumeIsolated { WeatherMochi.shared.tick() }
        }
    }

    static var place: (name: String, lat: Double, lon: Double)? {
        guard let d = UserDefaults.standard.dictionary(forKey: placeKey),
              let name = d["name"] as? String, let lat = d["lat"] as? Double, let lon = d["lon"] as? Double else { return nil }
        return (name, lat, lon)
    }

    func tick(force: Bool = false) {
        let state = AppState.shared
        guard state.tasks.contains(where: { $0.id == Self.taskId }) || force else { return }
        guard let place = Self.place else {
            state.weatherError = String(localized: "Type your city in Settings › Extras.")
            return
        }
        guard force || Date().timeIntervalSince(lastFetch) > 15 * 60 else { return }
        lastFetch = Date()
        Task {
            let w = await Self.fetch(place)
            guard let w else { state.weatherError = String(localized: "api.open-meteo.com can't be reached."); return }
            let wasDry = (state.weather?.rainChance ?? 0) < 50 && !(state.weather.map { ExtrasParse.isWet($0.code) } ?? false)
            state.weatherError = nil
            state.weather = w
            if let i = state.tasks.firstIndex(where: { $0.id == Self.taskId }) {
                state.tasks[i].steps = ["\(Int(w.temperature.rounded()))° · \(ExtrasParse.weather(code: w.code, day: w.day).0)"]
            }
            if wasDry && w.accessory == .umbrella {
                state.showToast(String(localized: "☔️ Rain likely soon in \(w.place)"), color: "#38BDF8", icon: "umbrella.fill", seconds: 5)
            }
        }
    }

    /// Looks the city up (Settings); nil when Open-Meteo doesn't know it.
    static func geocode(_ city: String) async -> (String, Double, Double)? {
        var c = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        c.queryItems = [.init(name: "name", value: city), .init(name: "count", value: "1"),
                        .init(name: "language", value: Bundle.main.preferredLocalizations.first ?? "en")]
        guard let url = c.url, let (data, _) = try? await URLSession.shared.data(from: url),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let r = (json["results"] as? [[String: Any]])?.first,
              let lat = r["latitude"] as? Double, let lon = r["longitude"] as? Double else { return nil }
        let name = [r["name"] as? String, r["country_code"] as? String].compactMap { $0 }.joined(separator: ", ")
        return (name, lat, lon)
    }

    private static func fetch(_ p: (name: String, lat: Double, lon: Double)) async -> WeatherNow? {
        var c = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        c.queryItems = [.init(name: "latitude", value: String(format: "%.3f", p.lat)),
                        .init(name: "longitude", value: String(format: "%.3f", p.lon)),
                        .init(name: "current", value: "temperature_2m,weather_code,is_day"),
                        .init(name: "hourly", value: "precipitation_probability"),
                        .init(name: "forecast_hours", value: "3"), .init(name: "timezone", value: "auto")]
        guard let url = c.url, let (data, _) = try? await URLSession.shared.data(from: url),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let cur = json["current"] as? [String: Any],
              let temp = (cur["temperature_2m"] as? NSNumber)?.doubleValue,
              let code = (cur["weather_code"] as? NSNumber)?.intValue else { return nil }
        let rain = ((json["hourly"] as? [String: Any])?["precipitation_probability"] as? [NSNumber] ?? []).prefix(3).map(\.intValue).max() ?? 0
        return WeatherNow(place: p.name, temperature: temp, code: code, day: (cur["is_day"] as? NSNumber)?.intValue == 1, rainChance: rain)
    }
}
#endif
