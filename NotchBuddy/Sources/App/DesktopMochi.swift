import AppKit
import SwiftUI

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
    static let size: CGFloat = 92

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
            let drag = PetDragView(frame: NSRect(x: 0, y: 0, width: s, height: s))
            drag.toolTip = String(localized: "Click: Mochi's menu (island, chat, worktrees…) · Double click: back to the notch")
            let host = NSHostingView(rootView: DesktopMochiView().environmentObject(AppState.shared))
            host.frame = drag.bounds
            host.autoresizingMask = [.width, .height]
            drag.addSubview(host)
            p.contentView = drag
            panel = p

            let b = PetPanel(contentRect: NSRect(x: 0, y: 0, width: 260, height: 40),
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
        moved()
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { _ in
                MainActor.assumeIsolated { DesktopMochi.shared.tick() }
            }
        }
    }

    private func hide() {
        PetMenu.shared.close()
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
        guard Self.follows, flight == nil, let panel, let current = panel.screen, NSScreen.screens.count > 1,
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

    /// Off to another spot: a hop in an arc, or a teleport when it's far.
    private func travel(to: NSPoint) {
        guard let panel else { return }
        let from = panel.frame.origin
        let distance = hypot(to.x - from.x, to.y - from.y)
        if distance > 1400 { teleport(to: to); return }
        flightFrom = from
        flightTo = to
        flightStart = CACurrentMediaTime()
        flightDuration = 0.45 + min(0.4, Double(distance) / 3000)
        flightLift = min(150, 40 + distance * 0.12)
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

/// A panel that never takes focus from the app you're in.
private final class PetPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Takes every mouse event over the pet: drag to move, click to open, double click to dock.
private final class PetDragView: NSView {
    private var start: NSPoint = .zero
    private var origin: NSPoint = .zero
    private var dragged = false

    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        start = NSEvent.mouseLocation
        origin = window?.frame.origin ?? .zero
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        let p = NSEvent.mouseLocation
        if hypot(p.x - start.x, p.y - start.y) > 3 { dragged = true }
        window?.setFrameOrigin(NSPoint(x: origin.x + p.x - start.x, y: origin.y + p.y - start.y))
        MainActor.assumeIsolated { DesktopMochi.shared.moved(save: false) }
    }

    private var pendingClick: DispatchWorkItem?

    /// Right click: the menu straight away.
    override func rightMouseDown(with event: NSEvent) {
        MainActor.assumeIsolated { DesktopMochi.shared.toggleMenu() }
    }

    override func mouseUp(with event: NSEvent) {
        MainActor.assumeIsolated {
            pendingClick?.cancel()
            if dragged {
                DesktopMochi.shared.moved()
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
        ZStack {
            // On a white page the idle Mochi is white on white: a dark halo behind
            // it, fading out, reads on any background (and is nearly invisible on dark ones).
            Circle()
                .fill(RadialGradient(colors: [Color.black.opacity(0.62), Color.black.opacity(0.38), Color.black.opacity(0)],
                                     center: .center, startRadius: 6, endRadius: DesktopMochi.size * 0.48))
                .padding(2)
            pet
                .shadow(color: .black.opacity(0.35), radius: 4, x: 0, y: 2)
        }
    }

    private var pet: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
            Canvas { context, size in
                let now = timeline.date.timeIntervalSinceReferenceDate
                let c = DesktopMochi.shared.center
                let mouse = NSEvent.mouseLocation
                if engine.glance == nil {
                    engine.lookX = max(-1, min(1, (mouse.x - c.x) / 320))
                    engine.lookY = max(-1, min(1, (mouse.y - c.y) / 260))
                }
                engine.bodyColor = state.focusTask?.isIntegration == true ? cgColorFromHex(state.focusTask!.color) : nil
                engine.update(dt: min(0.05, now - engine.lastTime))
                engine.drawHandsBehind(context: context, size: size)
                engine.draw(context: context, size: size)
                engine.drawHandsAndExtras(context: context, size: size)
            }
        }
        .onAppear { engine.setState(state.effectiveState, force: true) }
        .onChange(of: state.effectiveState) { _, s in engine.setState(s) }
        .onReceive(NotificationCenter.default.publisher(for: .triggerEmote)) { n in
            if let e = n.object as? BotEmote { engine.triggerEmote(e) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .botGreet)) { _ in engine.greet() }
        .onReceive(NotificationCenter.default.publisher(for: .petHop)) { _ in
            engine.squash()
            engine.eyeOverride = .happy
            engine.eyeOverrideUntil = CACurrentMediaTime() + 1
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
            if let t = state.compactToast {
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
    }
}
