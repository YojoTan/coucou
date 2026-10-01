import AppKit
import SwiftUI
import Combine

// MARK: - DesktopMochi — Mochi out of the notch, as a desktop companion
// Turned on in Settings › Extras, or by dragging Mochi out of the island and
// dropping it where there's no window. It floats above the windows, anywhere:
//
// • drag it wherever you like; it remembers the spot (per screen);
// • it follows you: when the cursor settles on another screen, it hops over to
//   the same spot there (Settings › Extras, "follows me");
// • it looks at the cursor, wears what the main Mochi wears, dances to
//   Spotify, talks in a Discord call — the same engine and syncs as the notch;
// • toasts appear in a speech bubble beside it;
// • a click opens the island on its screen; a double click sends it home.
//
// While it's out, the island keeps its pills and cards but not its Mochi in
// compact mode (Mochi can't be in two places). Its animation runs at 30 fps
// while visible; it stops when the screen locks.

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}

extension Notification.Name {
    /// The pet asks the island to open on this screen (object: CGDirectDisplayID).
    static let petOpenIsland = Notification.Name("coucou.petOpenIsland")
    /// The pet asks the island to come to this screen, without opening (object: CGDirectDisplayID).
    static let petBringIsland = Notification.Name("coucou.petBringIsland")
    /// The pet hopped to another screen: a squash and happy eyes.
    static let petHop = Notification.Name("coucou.petHop")
    /// The pet teleports: sparkles (object: true on arrival, false on leaving).
    static let petTeleport = Notification.Name("coucou.petTeleport")
    /// A file is being dragged over the pet / was dropped on it.
    static let petHungry = Notification.Name("coucou.petHungry")
    static let petGulp = Notification.Name("coucou.petGulp")
}

/// Which side of the pet the bubble is on.
@MainActor
final class PetLayout: ObservableObject {
    static let shared = PetLayout()
    @Published var leftSide = false
}

@MainActor
final class DesktopMochi {
    static let shared = DesktopMochi()
    static let enabledKey = "desktop-mochi"
    static let followKey = "desktop-mochi-follow"
    private static let positionKey = "desktop-mochi-position"     // [displayID: [x, y]] relative, 0…1
    /// The pet's window; Mochi itself is drawn `body` wide in its middle, the rest is
    /// room for its hands, props and bolts.
    static let size: CGFloat = 120
    static let body: CGFloat = 92

    private var panel: NSPanel?
    private var bubble: NSPanel?
    private var timer: Timer?
    private var otherScreen: (id: CGDirectDisplayID, since: Date)? = nil
    // A hop in progress, stepped at 60 fps (window frames don't animate through animator()).
    private var flight: Timer?
    private var flightFrom: NSPoint = .zero
    private var flightTo: NSPoint = .zero
    private var flightStart: Double = 0
    private var flightDuration: Double = 0.6
    private var flightLift: CGFloat = 80

    /// The pet's centre in global AppKit coordinates (for its eyes).
    private(set) var center: CGPoint = .zero
    private var watches: [AnyCancellable] = []
    private var outOfSight = false
    private var awaitingReply: Int? = nil
    var dragging = false

    var petPanel: NSPanel? { panel }
    var isVisible: Bool { panel?.isVisible == true && !outOfSight }
    /// Moving on its own (a hop, a throw) or being dragged.
    var busy: Bool { flight != nil || PetBrain.shared.flying || dragging }

    static var enabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }
    static var follows: Bool { UserDefaults.standard.object(forKey: followKey) as? Bool ?? true }

    /// At launch, and whenever the setting changes.
    func apply() {
        if Self.enabled { show(at: nil) } else { hide() }
        AppState.shared.desktopMochiOn = Self.enabled
    }

    /// Dropped out of the island where there's no window: out it comes, right there.
    func release(at point: NSPoint) {
        UserDefaults.standard.set(true, forKey: Self.enabledKey)
        show(at: point)
        AppState.shared.desktopMochiOn = true
        NotificationCenter.default.post(name: .petHop, object: nil)
    }

    /// Double click: back to the notch.
    func dock() {
        UserDefaults.standard.set(false, forKey: Self.enabledKey)
        hide()
        AppState.shared.desktopMochiOn = false
        NotificationCenter.default.post(name: .botGreet, object: nil)
    }

    // MARK: Windows

    private func show(at point: NSPoint?) {
        let s = Self.size
        if panel == nil {
            let p = PetPanel(contentRect: NSRect(x: 0, y: 0, width: s, height: s),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.backgroundColor = .clear
            p.isOpaque = false
            p.hasShadow = false
            p.level = .floating
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            p.acceptsMouseMovedEvents = true
            let drag = PetDragView(frame: NSRect(x: 0, y: 0, width: s, height: s))
            drag.registerForDraggedTypes([.fileURL])
            drag.toolTip = String(localized: "Click: Mochi's menu (island, chat, worktrees…) · Double click: back to the notch")
            let host = NSHostingView(rootView: DesktopMochiView().environmentObject(AppState.shared))
            host.frame = drag.bounds
            host.autoresizingMask = [.width, .height]
            drag.addSubview(host)
            p.contentView = drag
            panel = p

            let b = PetPanel(contentRect: NSRect(x: 0, y: 0, width: 260, height: 110),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            b.backgroundColor = .clear
            b.isOpaque = false
            b.hasShadow = false
            b.ignoresMouseEvents = true
            b.level = .floating
            b.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            b.contentView = NSHostingView(rootView: PetBubbleView(layout: PetLayout.shared).environmentObject(AppState.shared))
            p.addChildWindow(b, ordered: .above)
            bubble = b
        }
        guard let panel else { return }
        let origin: NSPoint
        if let point {
            origin = NSPoint(x: point.x - s / 2, y: point.y - s / 2)
        } else {
            let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main!
            origin = savedOrigin(on: screen)
        }
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
        outOfSight = false
        moved()
        watch()
        PetBrain.shared.start()
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { _ in
                MainActor.assumeIsolated { DesktopMochi.shared.tick() }
            }
        }
    }

    private func hide() {
        PetMenu.shared.close()
        PetBrain.shared.stop()
        PetHUD.shared.hideApproval()
        watches = []
        panel?.orderOut(nil)
        bubble?.orderOut(nil)
        timer?.invalidate()
        timer = nil
    }

    /// After a drag or a hop: remember the spot, keep the bubble beside it.
    func moved(save: Bool = true) {
        guard let panel, let screen = panel.screen ?? NSScreen.main else { return }
        let f = panel.frame
        center = CGPoint(x: f.midX, y: f.midY)
        if save {
            let v = screen.visibleFrame
            var all = UserDefaults.standard.dictionary(forKey: Self.positionKey) as? [String: [Double]] ?? [:]
            all[String(screen.displayID)] = [Double((f.minX - v.minX) / max(1, v.width - f.width)),
                                             Double((f.minY - v.minY) / max(1, v.height - f.height))]
            UserDefaults.standard.set(all, forKey: Self.positionKey)
        }
        placeBubble()
        PetHUD.shared.place()
    }

    /// The bubble goes on whichever side has room.
    private func placeBubble() {
        guard let panel, let bubble, let screen = panel.screen else { return }
        let f = panel.frame, w = bubble.frame.width
        let leftSide = f.maxX + w > screen.visibleFrame.maxX
        bubble.setFrameOrigin(NSPoint(x: leftSide ? f.minX - w + 6 : f.maxX - 6, y: f.midY - bubble.frame.height / 2 + 10))
        if PetLayout.shared.leftSide != leftSide { PetLayout.shared.leftSide = leftSide }
    }

    private func savedOrigin(on screen: NSScreen) -> NSPoint {
        let v = screen.visibleFrame, s = Self.size
        let all = UserDefaults.standard.dictionary(forKey: Self.positionKey) as? [String: [Double]] ?? [:]
        let rel = all[String(screen.displayID)] ?? [0.92, 0.08]      // default: bottom right
        return NSPoint(x: v.minX + CGFloat(rel[0]) * (v.width - s), y: v.minY + CGFloat(rel[1]) * (v.height - s))
    }

    // MARK: Following

    /// The cursor settled on another screen (1.2 s): hop over to the same spot there.
    private func tick() {
        PetHUD.shared.refreshSquad()
        guard Self.follows, !busy, PetBrain.shared.peek == nil, let panel, let current = panel.screen, NSScreen.screens.count > 1,
              let target = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }),
              target.displayID != current.displayID
        else { otherScreen = nil; return }
        guard let o = otherScreen, o.id == target.displayID else {
            otherScreen = (target.displayID, Date())
            return
        }
        guard Date().timeIntervalSince(o.since) > 1.2 else { return }
        otherScreen = nil
        travel(to: savedOrigin(on: target))
    }

    /// Off to another spot: a hop in an arc (`lift` overrides its height; a small
    /// one reads as walking), or a teleport when it's far.
    func travel(to: NSPoint, allowTeleport: Bool = true, lift: CGFloat? = nil) {
        guard let panel else { return }
        let from = panel.frame.origin
        let distance = hypot(to.x - from.x, to.y - from.y)
        if allowTeleport && distance > 1400 { teleport(to: to); return }
        flightFrom = from
        flightTo = to
        flightStart = CACurrentMediaTime()
        flightDuration = lift.map { _ in 0.35 + min(1.2, Double(distance) / 260) } ?? (0.45 + min(0.4, Double(distance) / 3000))
        flightLift = lift ?? min(150, 40 + distance * 0.12)
        NotificationCenter.default.post(name: .petHop, object: nil)
        flight?.invalidate()
        flight = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { _ in
            MainActor.assumeIsolated { DesktopMochi.shared.flightStep() }
        }
    }

    private func flightStep() {
        guard let panel else { flight?.invalidate(); flight = nil; return }
        let k = min(1, (CACurrentMediaTime() - flightStart) / flightDuration)
        let e = CGFloat(k < 0.5 ? 2 * k * k : 1 - pow(-2 * k + 2, 2) / 2)      // ease in-out
        let arc = flightLift * 4 * CGFloat(k) * CGFloat(1 - k)                  // up and down
        panel.setFrameOrigin(NSPoint(x: flightFrom.x + (flightTo.x - flightFrom.x) * e,
                                     y: flightFrom.y + (flightTo.y - flightFrom.y) * e + arc))
        moved(save: false)
        if k >= 1 {
            flight?.invalidate()
            flight = nil
            NotificationCenter.default.post(name: .petHop, object: nil)      // the landing
        }
    }

    /// Too far to hop: fade out in sparkles, reappear there in sparkles.
    private func teleport(to: NSPoint) {
        guard let panel else { return }
        NotificationCenter.default.post(name: .petTeleport, object: false)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                guard let panel = DesktopMochi.shared.panel else { return }
                panel.setFrameOrigin(to)
                DesktopMochi.shared.moved(save: false)
                NotificationCenter.default.post(name: .petTeleport, object: true)
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.28
                    panel.animator().alphaValue = 1
                }
            }
        })
    }

    /// A short slide (into a peek, out of it): no hop, no sound.
    func glide(to: NSPoint) {
        guard let panel else { return }
        flightFrom = panel.frame.origin
        flightTo = to
        flightStart = CACurrentMediaTime()
        flightDuration = 0.28
        flightLift = 0
        flight?.invalidate()
        flight = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { _ in
            MainActor.assumeIsolated { DesktopMochi.shared.flightStep() }
        }
    }

    /// Out of sight for a presentation or on request, without turning the pet off.
    func setOutOfSight(_ hidden: Bool) {
        guard hidden != outOfSight, let panel else { return }
        outOfSight = hidden
        if hidden { PetMenu.shared.close(); panel.orderOut(nil) } else { panel.orderFrontRegardless() }
    }

    // MARK: Reacting to Coucou

    private func watch() {
        guard watches.isEmpty else { return }
        let state = AppState.shared
        watches.append(state.$compactToast.sink { t in
            if t != nil { MainActor.assumeIsolated { PetBrain.shared.news() } }
        })
        // A permission from any source: Coucou's own hooks, or an Orca agent — for
        // whichever pill is focused. @Published speaks *before* the value changes,
        // so the state is read on the next turn of the run loop, once it has.
        watches.append(state.$pendingApproval.sink { _ in
            DispatchQueue.main.async { DesktopMochi.shared.permissionChanged() }
        })
        #if !APPSTORE
        watches.append(state.$orcaWorktrees.sink { _ in
            DispatchQueue.main.async { DesktopMochi.shared.permissionChanged() }
        })
        #endif
        #if !APPSTORE
        watches.append(state.$lanPrompt.sink { p in
            MainActor.assumeIsolated {
                switch p {
                case .file(_, let peer, let name, _)?: PetHUD.shared.visit(from: peer, saying: String(localized: "\(peer) brought you \(name) 📦"))
                case .message(let peer, _, _)?: PetHUD.shared.visit(from: peer, saying: String(localized: "\(peer) left you a message ✉️"))
                default: break
                }
            }
        })
        #endif
        watches.append(state.$chatHistory.sink { history in
            MainActor.assumeIsolated { DesktopMochi.shared.replyArrived(history) }
        })
    }

    private var wasAsking = false

    /// The permission card follows whoever is asking; the pet hops when a new ask arrives.
    func permissionChanged() {
        let state = AppState.shared
        var asking = state.pendingApproval != nil
        #if !APPSTORE
        asking = asking || state.orcaWorktrees.contains { $0.status == "permission" }
        #endif
        if asking {
            PetHUD.shared.showApproval()
            if !wasAsking { NotificationCenter.default.post(name: .petHop, object: nil) }
        } else {
            PetHUD.shared.hideApproval()
        }
        wasAsking = asking
    }

    /// The pet's menu asked something: the answer shows in its bubble.
    func ask(_ text: String) {
        let state = AppState.shared
        state.promptContext = nil
        state.chatHistory.append(ChatMessage(role: .user, content: text))
        awaitingReply = state.chatHistory.count
        state.stateOverride = .thinking
        state.petSay(String(localized: "Thinking…"), seconds: 30)
        Task { await ClaudeService.shared.chat(query: text, context: nil, state: state) }
    }

    private func replyArrived(_ history: [ChatMessage]) {
        guard let n = awaitingReply, history.count > n, let last = history.last, last.role == .assistant else { return }
        awaitingReply = nil
        AppState.shared.petSay(String(last.content.prefix(280)), seconds: 14)
        PetBrain.shared.news()
    }

    /// A file dropped on the pet: it gulps it, and the island asks what to do with it.
    func dropped(_ url: URL) {
        let state = AppState.shared
        let name = url.lastPathComponent
        state.droppedFile = DroppedFile(url: url, name: name)
        state.promptContext = .file(name: name, fileURL: url)
        NotificationCenter.default.post(name: .petGulp, object: nil)
        SoundEngine.shared.play("gulp")
        let inbox = HookServer.supportDir.appendingPathComponent("inbox")
        Task.detached {
            try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
            let dest = inbox.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: dest)
            if (try? FileManager.default.copyItem(at: url, to: dest)) != nil {
                await MainActor.run {
                    state.droppedFile = DroppedFile(url: dest, name: name)
                    state.promptContext = .file(name: name, fileURL: dest)
                }
            }
        }
        bringIslandHere()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            NotificationCenter.default.post(name: .hookExpand, object: IslandView.choose)
        }
    }

    /// The island to the pet's screen, without opening it (a menu choice opens what it needs).
    func bringIslandHere() {
        if let id = panel?.screen?.displayID { NotificationCenter.default.post(name: .petBringIsland, object: id) }
    }

    func openIslandHere() { openIsland() }

    /// The pet's menu, beside it (PetMenu.swift).
    func toggleMenu() {
        guard let panel, let screen = panel.screen else { return }
        PetMenu.shared.toggle(beside: panel.frame, on: screen)
    }

    /// Click: open the island on the pet's screen.
    func openIsland() {
        guard let screen = panel?.screen else { return }
        NotificationCenter.default.post(name: .petOpenIsland, object: screen.displayID)
    }
}

/// A panel that never takes focus from the app you're in, and may sit half off
/// the screen (peeking).
private final class PetPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Takes every mouse event over the pet: drag to move, click to open, double click to dock.
private final class PetDragView: NSView {
    private var start: NSPoint = .zero
    private var origin: NSPoint = .zero
    private var dragged = false

    private var samples: [(t: Double, p: NSPoint)] = []

    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // Hovering: petting is a few quick back-and-forths over Mochi.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        MainActor.assumeIsolated { PetBrain.shared.strokeOverPet(at: NSEvent.mouseLocation.x) }
    }

    override func mouseExited(with event: NSEvent) {
        MainActor.assumeIsolated { PetBrain.shared.cursorLeftPet() }
    }

    override func mouseDown(with event: NSEvent) {
        start = NSEvent.mouseLocation
        origin = window?.frame.origin ?? .zero
        dragged = false
        samples = [(CACurrentMediaTime(), start)]
        MainActor.assumeIsolated {
            PetBrain.shared.grabbed()
            DesktopMochi.shared.dragging = true
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = NSEvent.mouseLocation
        if hypot(p.x - start.x, p.y - start.y) > 3 { dragged = true }
        window?.setFrameOrigin(NSPoint(x: origin.x + p.x - start.x, y: origin.y + p.y - start.y))
        samples.append((CACurrentMediaTime(), p))
        if samples.count > 8 { samples.removeFirst() }
        MainActor.assumeIsolated { DesktopMochi.shared.moved(save: false) }
    }

    /// How fast the drag was going when let go (last ~0.1 s).
    private var releaseVelocity: CGVector {
        let now = CACurrentMediaTime()
        let recent = samples.filter { now - $0.t < 0.1 }
        guard let a = recent.first, let b = recent.last, b.t > a.t else { return .zero }
        return CGVector(dx: (b.p.x - a.p.x) / CGFloat(b.t - a.t), dy: (b.p.y - a.p.y) / CGFloat(b.t - a.t))
    }

    // Files dropped on Mochi.
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        MainActor.assumeIsolated { NotificationCenter.default.post(name: .petHungry, object: nil) }
        return .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL])?.first else { return false }
        var dir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &dir), !dir.boolValue else { return false }
        MainActor.assumeIsolated { DesktopMochi.shared.dropped(url) }
        return true
    }

    private var pendingClick: DispatchWorkItem?

    /// Right click: the menu straight away.
    override func rightMouseDown(with event: NSEvent) {
        MainActor.assumeIsolated { DesktopMochi.shared.toggleMenu() }
    }

    override func mouseUp(with event: NSEvent) {
        MainActor.assumeIsolated {
            pendingClick?.cancel()
            DesktopMochi.shared.dragging = false
            if dragged {
                DesktopMochi.shared.moved()
                PetBrain.shared.released(velocity: releaseVelocity)
            } else if event.clickCount >= 2 {
                PetMenu.shared.close()
                DesktopMochi.shared.dock()
            } else {
                // A click opens the menu — once it's clear no second click is coming.
                let open = DispatchWorkItem { MainActor.assumeIsolated { DesktopMochi.shared.toggleMenu() } }
                pendingClick = open
                DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: open)
            }
        }
    }
}

// MARK: - Views

/// The pet itself: the main Mochi's engine setup, eyes on the cursor.
private struct DesktopMochiView: View {
    @EnvironmentObject var state: AppState
    @StateObject private var engine = BotEngine()

    var body: some View {
        pet.shadow(color: .black.opacity(0.3), radius: 4, x: 0, y: 2)
    }

    private var pet: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
            Canvas { context, size in
                let now = timeline.date.timeIntervalSinceReferenceDate
                let c = DesktopMochi.shared.center
                let mouse = NSEvent.mouseLocation
                if let side = PetBrain.shared.peek {
                    engine.lookX = side == .left ? 0.85 : -0.85      // peeking: eyes on the screen
                    engine.lookY = 0.1
                } else if engine.glance == nil {
                    engine.lookX = max(-1, min(1, (mouse.x - c.x) / 320))
                    engine.lookY = max(-1, min(1, (mouse.y - c.y) / 260))
                }
                engine.bodyColor = state.focusTask?.isIntegration == true ? cgColorFromHex(state.focusTask!.color) : nil
                engine.update(dt: min(0.05, now - engine.lastTime))
                // A halo in Mochi's own colour, deeper, so it stands out on any page
                // (a white Mochi on a white page most of all) without a black smudge.
                let halo = engine.haloColor
                let mid = CGPoint(x: size.width / 2, y: size.height / 2 + DesktopMochi.body * 0.03)
                let hr = DesktopMochi.body * 0.5
                context.fill(Path(ellipseIn: CGRect(x: mid.x - hr, y: mid.y - hr, width: hr * 2, height: hr * 2)),
                             with: .radialGradient(Gradient(stops: [
                                .init(color: halo.opacity(0.8), location: 0), .init(color: halo.opacity(0.5), location: 0.55),
                                .init(color: halo.opacity(0), location: 1)]), center: mid, startRadius: 0, endRadius: hr))
                // Mochi at its usual size in the middle; hands and bolts use the margin.
                var inner = context
                inner.translateBy(x: (size.width - DesktopMochi.body) / 2, y: (size.height - DesktopMochi.body) / 2)
                let body = CGSize(width: DesktopMochi.body, height: DesktopMochi.body)
                engine.drawHandsBehind(context: inner, size: body)
                engine.draw(context: inner, size: body)
                engine.drawHandsAndExtras(context: inner, size: body)
            }
        }
        .onAppear { engine.setState(state.effectiveState, force: true) }
        .onChange(of: state.effectiveState) { _, s in engine.setState(s) }
        .onReceive(NotificationCenter.default.publisher(for: .triggerEmote)) { n in
            if let e = n.object as? BotEmote { engine.triggerEmote(e) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .botGreet)) { _ in engine.greet() }
        .onReceive(NotificationCenter.default.publisher(for: .petHop)) { _ in
            engine.jetUntil = CACurrentMediaTime() + 0.8      // the outlaw's rocket boots
            engine.squash()
            engine.eyeOverride = .happy
            engine.eyeOverrideUntil = CACurrentMediaTime() + 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .petBump)) { _ in engine.squash() }
        .onReceive(NotificationCenter.default.publisher(for: .petPetted)) { _ in
            engine.emit(.heart, count: 5)
            engine.eyeOverride = .happy
            engine.eyeOverrideUntil = CACurrentMediaTime() + 1.6
            engine.anim("blush", keys: [TweenKey(target: 1, duration: 200, ease: Ease.out),
                                        TweenKey(target: 1, duration: 900, ease: Ease.lin),
                                        TweenKey(target: 0, duration: 500, ease: Ease.inOut)])
        }
        .onReceive(NotificationCenter.default.publisher(for: .petHungry)) { _ in
            engine.triggerEmote(.surprised, silent: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: .petGulp)) { _ in
            engine.squash()
            engine.eyeOverride = .happy
            engine.eyeOverrideUntil = CACurrentMediaTime() + 1.2
        }
        .onReceive(NotificationCenter.default.publisher(for: .petTeleport)) { n in
            engine.emit(.spark, count: 10)
            if n.object as? Bool == true { engine.squash() } else {
                engine.eyeOverride = .closed
                engine.eyeOverrideUntil = CACurrentMediaTime() + 0.4
            }
        }
        #if !APPSTORE
        .background(MusicSync(engine: engine, active: state.focusTask?.id == "integration_spotify"))
        .background(DiscordSync(engine: engine, active: state.focusTask?.id == DiscordService.taskId))
        .background(MochiExtrasSync(engine: engine, taskId: state.focusTask?.id, isMain: true))
        #endif
    }
}

/// What Mochi has to say: the current toast, in a speech bubble.
private struct PetBubbleView: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var layout: PetLayout
    private var leftSide: Bool { layout.leftSide }

    var body: some View {
        HStack {
            if !leftSide { Spacer(minLength: 0).frame(width: 0) }
            if let say = state.petSays {
                Text(verbatim: say.text).font(.system(size: 11.5, weight: .medium)).foregroundColor(.white)
                    .lineLimit(5).multilineTextAlignment(.leading)
                    .padding(.horizontal, 11).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.88)))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.12)))
                    .frame(maxWidth: 250, alignment: leftSide ? .trailing : .leading)
                    .transition(.scale(scale: 0.6, anchor: leftSide ? .trailing : .leading).combined(with: .opacity))
            } else if state.pendingApproval == nil, let t = state.compactToast {
                HStack(spacing: 6) {
                    if let icon = t.icon {
                        Image(systemName: icon).font(.system(size: 10, weight: .bold)).foregroundColor(Color(hex: t.color))
                    } else {
                        Circle().fill(Color(hex: t.color)).frame(width: 6, height: 6)
                    }
                    Text(verbatim: t.text).font(.system(size: 11.5, weight: .medium)).foregroundColor(.white)
                        .lineLimit(1).truncationMode(.tail)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Capsule().fill(Color.black.opacity(0.85)))
                .overlay(Capsule().stroke(Color.white.opacity(0.12)))
                .transition(.scale(scale: 0.6, anchor: leftSide ? .trailing : .leading).combined(with: .opacity))
            }
            if leftSide { Spacer(minLength: 0).frame(width: 0) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: leftSide ? .trailing : .leading)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: state.compactToast?.id)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: state.petSays?.id)
    }
}
