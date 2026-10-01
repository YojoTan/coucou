import AppKit
import SwiftUI

// MARK: - PetBrain — what the desktop pet does on its own
// Kept apart from DesktopMochi (the windows) so each behaviour reads on its own:
//
// • fling: let go of a drag with speed and Mochi flies — gravity, bounces off
//   the screen's edges with a squash, slides to a stop on the floor;
// • peek: left against a side edge, it hides half of itself and peeks; news
//   (a toast, a question, a permission) brings it out for a moment;
// • petting: wiggle the cursor over it — hearts;
// • "come here": shake the mouse and it hops over to the cursor;
// • window walker (opt-in): it sits on the top edge of the front window, rides
//   along when you move it, strolls along it now and then, falls ("ouch!")
//   when the window goes away;
// • presentations: it steps out of sight while you present or share on its
//   screen (Keynote/PowerPoint/a browser in full screen, Zoom/Teams/Webex
//   sharing), or for 15 minutes on request.

@MainActor
final class PetBrain {
    static let shared = PetBrain()
    static let walkerKey = "desktop-mochi-walker"        // off by default
    static let shakeKey = "desktop-mochi-shake"          // on
    static let hideKey = "desktop-mochi-hide-fullscreen" // on

    enum Side { case left, right }
    private(set) var peek: Side? = nil
    private var physics: Timer?
    private var velocity = CGVector.zero
    private var monitors: [Any] = []
    private var timer: Timer?
    private var strokes: [(t: Double, dir: CGFloat)] = []
    private var lastStrokeX: CGFloat? = nil
    private var lastPetted = 0.0
    private var shakes: [(t: Double, x: CGFloat)] = []
    private var lastSummon = 0.0
    private var perch: (id: CGWindowID, dx: CGFloat)? = nil
    private var nextPerch = 0.0
    private var nextStroll = 0.0
    private var popOutUntil = 0.0
    private(set) var hiddenUntil = Date.distantPast
    private var coveredByFullScreen = false

    var flying: Bool { physics != nil }

    static func on(_ key: String) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? (key != walkerKey)
    }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            MainActor.assumeIsolated { PetBrain.shared.tick() }
        }
        let shake: (NSEvent) -> Void = { _ in MainActor.assumeIsolated { PetBrain.shared.mouseMoved(NSEvent.mouseLocation) } }
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved, handler: shake) as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { e in shake(e); return e } as Any)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors = []
        physics?.invalidate()
        physics = nil
        perch = nil
    }

    // MARK: Grab, fling, peek

    /// A drag began: whatever it was doing stops.
    func grabbed() {
        physics?.invalidate()
        physics = nil
        perch = nil
        peek = nil
        nextPerch = CACurrentMediaTime() + 20
    }

    /// Let go: fast enough, it flies; else it stays (and may peek at an edge).
    func released(velocity v: CGVector) {
        if hypot(v.dx, v.dy) > 700 {
            NotificationCenter.default.post(name: .petHop, object: nil)
            velocity = CGVector(dx: max(-4000, min(4000, v.dx)), dy: max(-4000, min(4000, v.dy)))
            physics = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { _ in
                MainActor.assumeIsolated { PetBrain.shared.step() }
            }
        } else {
            settle()
        }
    }

    private func step() {
        guard let panel = DesktopMochi.shared.petPanel else { physics?.invalidate(); physics = nil; return }
        let dt: CGFloat = 1.0 / 60, s = DesktopMochi.size
        let screen = Self.screen(containing: CGPoint(x: panel.frame.midX, y: panel.frame.midY))
        let v = screen.visibleFrame
        velocity.dy -= 2600 * dt
        var p = panel.frame.origin
        p.x += velocity.dx * dt
        p.y += velocity.dy * dt
        var bumped = false
        if p.x < v.minX { p.x = v.minX; velocity.dx = -velocity.dx * 0.55; bumped = abs(velocity.dx) > 150 }
        if p.x > v.maxX - s { p.x = v.maxX - s; velocity.dx = -velocity.dx * 0.55; bumped = abs(velocity.dx) > 150 }
        if p.y > v.maxY - s { p.y = v.maxY - s; velocity.dy = -velocity.dy * 0.4; bumped = true }
        var grounded = false
        if p.y < v.minY {
            p.y = v.minY
            if abs(velocity.dy) < 240 { velocity.dy = 0; velocity.dx *= 0.86; grounded = true }
            else { velocity.dy = -velocity.dy * 0.5; bumped = true }
        }
        if bumped { NotificationCenter.default.post(name: .petBump, object: nil) }
        panel.setFrameOrigin(p)
        DesktopMochi.shared.moved(save: false)
        if grounded && abs(velocity.dx) < 25 {
            physics?.invalidate()
            physics = nil
            settle()
        }
    }

    /// At rest: remember the spot; against a side edge, hide half and peek.
    private func settle() {
        guard let panel = DesktopMochi.shared.petPanel else { return }
        let v = Self.screen(containing: CGPoint(x: panel.frame.midX, y: panel.frame.midY)).visibleFrame
        let s = DesktopMochi.size, x = panel.frame.minX
        if x <= v.minX + 14 {
            peek = .left
            DesktopMochi.shared.glide(to: NSPoint(x: v.minX - s * 0.42, y: panel.frame.minY))
        } else if x >= v.maxX - s - 14 {
            peek = .right
            DesktopMochi.shared.glide(to: NSPoint(x: v.maxX - s * 0.58, y: panel.frame.minY))
        } else {
            peek = nil
        }
        DesktopMochi.shared.moved()
    }

    /// News while peeking: out for a few seconds, then back to peeking.
    func news() {
        guard let side = peek, let panel = DesktopMochi.shared.petPanel else { return }
        let v = Self.screen(containing: CGPoint(x: panel.frame.midX, y: panel.frame.midY)).visibleFrame
        let s = DesktopMochi.size
        popOutUntil = CACurrentMediaTime() + 5
        DesktopMochi.shared.glide(to: NSPoint(x: side == .left ? v.minX + 4 : v.maxX - s - 4, y: panel.frame.minY))
    }

    // MARK: Petting and "come here"

    /// The cursor moving over the pet: a few quick back-and-forths are a caress.
    func strokeOverPet(at x: CGFloat) {
        let now = CACurrentMediaTime()
        defer { lastStrokeX = x }
        guard let last = lastStrokeX, abs(x - last) > 2 else { return }
        let dir: CGFloat = x > last ? 1 : -1
        if strokes.last?.dir != dir { strokes.append((now, dir)) }
        strokes.removeAll { now - $0.t > 1.2 }
        if strokes.count >= 5 && now - lastPetted > 2 {
            lastPetted = now
            strokes.removeAll()
            NotificationCenter.default.post(name: .petPetted, object: nil)
            SoundEngine.shared.play("love")
        }
    }

    func cursorLeftPet() { lastStrokeX = nil; strokes.removeAll() }

    /// Anywhere on screen: five quick, wide back-and-forths call Mochi over.
    private func mouseMoved(_ p: NSPoint) {
        guard Self.on(Self.shakeKey), DesktopMochi.shared.isVisible else { return }
        let now = CACurrentMediaTime()
        shakes.append((now, p.x))
        shakes.removeAll { now - $0.t > 0.8 }
        guard shakes.count > 6, now - lastSummon > 3 else { return }
        var turns = 0, dir: CGFloat = 0, anchor = shakes[0].x
        for s in shakes.dropFirst() {
            let d = s.x - anchor
            guard abs(d) > 22 else { continue }
            let nd: CGFloat = d > 0 ? 1 : -1
            if nd != dir { turns += 1; dir = nd }
            anchor = s.x
        }
        guard turns >= 5 else { return }
        lastSummon = now
        shakes.removeAll()
        grabbed()
        let v = Self.screen(containing: p).visibleFrame, s = DesktopMochi.size
        let to = NSPoint(x: min(max(p.x + 30, v.minX), v.maxX - s), y: min(max(p.y - s - 20, v.minY), v.maxY - s))
        DesktopMochi.shared.travel(to: to, allowTeleport: true)
    }

    // MARK: The window walker, and hiding

    private func tick() {
        guard DesktopMochi.shared.petPanel != nil else { return }
        hideCheck()
        let now = CACurrentMediaTime()
        if let side = peek, popOutUntil > 0, now > popOutUntil, !DesktopMochi.shared.busy {
            popOutUntil = 0
            peek = nil
            if let panel = DesktopMochi.shared.petPanel {
                let v = Self.screen(containing: CGPoint(x: panel.frame.midX, y: panel.frame.midY)).visibleFrame
                peek = side
                DesktopMochi.shared.glide(to: NSPoint(x: side == .left ? v.minX - DesktopMochi.size * 0.42
                                                                     : v.maxX - DesktopMochi.size * 0.58, y: panel.frame.minY))
            }
        }
        guard Self.on(Self.walkerKey), DesktopMochi.shared.isVisible, !DesktopMochi.shared.busy, peek == nil,
              let panel = DesktopMochi.shared.petPanel else { return }
        let s = DesktopMochi.size
        if let p = perch {
            guard let b = Self.windowFrame(p.id) else { perch = nil; fall(); return }
            let dx = min(max(p.dx, 0), max(0, b.width - s))
            let target = NSPoint(x: b.minX + dx, y: b.maxY - 4)
            if hypot(target.x - panel.frame.minX, target.y - panel.frame.minY) > 0.5 {
                panel.setFrameOrigin(target)
                DesktopMochi.shared.moved(save: false)
            }
            if now > nextStroll {
                nextStroll = now + Double.random(in: 6...14)
                let ndx = CGFloat.random(in: 0...max(0, b.width - s))
                perch = (p.id, ndx)
                DesktopMochi.shared.travel(to: NSPoint(x: b.minX + ndx, y: b.maxY - 4), lift: 10)
            }
        } else if now > nextPerch {
            nextPerch = now + Double.random(in: 10...25)
            let screen = Self.screen(containing: CGPoint(x: panel.frame.midX, y: panel.frame.midY))
            guard let (id, b) = Self.frontWindow(on: screen) else { return }
            let dx = CGFloat.random(in: 0...max(0, b.width - s))
            perch = (id, dx)
            nextStroll = now + Double.random(in: 6...14)
            DesktopMochi.shared.travel(to: NSPoint(x: b.minX + dx, y: b.maxY - 4))
        }
    }

    /// Its window went away: down it goes, with a word about it.
    private func fall() {
        AppState.shared.petSay(String(localized: "Ouch!"), seconds: 2)
        released(velocity: CGVector(dx: 0, dy: -900))
        nextPerch = CACurrentMediaTime() + 8
    }

    /// "Hide for 15 minutes" in the pet's menu.
    func hide(for seconds: TimeInterval) {
        hiddenUntil = Date().addingTimeInterval(seconds)
        DesktopMochi.shared.setOutOfSight(true)
    }

    private func hideCheck() {
        let manual = Date() < hiddenUntil
        var covered = false
        if Self.on(Self.hideKey), let panel = DesktopMochi.shared.petPanel {
            let screen = Self.screen(containing: CGPoint(x: panel.frame.midX, y: panel.frame.midY))
            covered = Self.fullScreenWindow(on: screen)
        }
        coveredByFullScreen = covered
        DesktopMochi.shared.setOutOfSight(manual || covered)
    }

    // MARK: Screens and windows (CoreGraphics: top-left origin on the primary screen)

    static func screen(containing p: CGPoint) -> NSScreen {
        NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) }
            ?? NSScreen.screens.min { hypot($0.frame.midX - p.x, $0.frame.midY - p.y) < hypot($1.frame.midX - p.x, $1.frame.midY - p.y) }
            ?? NSScreen.main!
    }

    private static func appKitRect(_ b: [String: Any]) -> NSRect? {
        guard let x = b["X"] as? CGFloat, let y = b["Y"] as? CGFloat, let w = b["Width"] as? CGFloat, let h = b["Height"] as? CGFloat,
              let top = NSScreen.screens.first?.frame.maxY else { return nil }
        return NSRect(x: x, y: top - y - h, width: w, height: h)
    }

    private static func windows() -> [[String: Any]] {
        (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
    }

    /// The front-most ordinary window on that screen with room above its top edge for Mochi.
    private static func frontWindow(on screen: NSScreen) -> (CGWindowID, NSRect)? {
        let me = ProcessInfo.processInfo.processIdentifier
        let v = screen.visibleFrame
        for w in windows() {
            guard (w[kCGWindowLayer as String] as? Int) == 0, (w[kCGWindowOwnerPID as String] as? Int32) != me,
                  (w[kCGWindowAlpha as String] as? CGFloat ?? 1) > 0.2,
                  let id = w[kCGWindowNumber as String] as? CGWindowID,
                  let b = (w[kCGWindowBounds as String] as? [String: Any]).flatMap(appKitRect),
                  b.width >= 240, b.height >= 120, v.contains(CGPoint(x: b.midX, y: b.midY)) else { continue }
            if b.maxY + DesktopMochi.size < v.maxY { return (id, b) }
            return nil      // the front window fills the screen: nowhere to sit
        }
        return nil
    }

    private static func windowFrame(_ id: CGWindowID) -> NSRect? {
        guard let w = (CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]])?.first,
              (w[kCGWindowIsOnscreen as String] as? Bool) == true else { return nil }
        return (w[kCGWindowBounds as String] as? [String: Any]).flatMap(appKitRect)
    }

    /// Apps whose full-screen window means presenting (slides, a video).
    private static let presenters: Set<String> = ["Keynote", "Microsoft PowerPoint", "Pitch", "QuickTime Player",
        "Google Chrome", "Safari", "Arc", "Firefox", "Brave Browser", "Microsoft Edge"]
    /// Apps that draw a screen-wide border (any layer) while you share your screen.
    private static let sharers: Set<String> = ["zoom.us", "Microsoft Teams", "Webex", "Cisco Webex Meetings"]

    /// Presenting or sharing on that screen: a presenter app's full-screen window, or a
    /// sharing app's screen-wide overlay. A full-screen editor doesn't count.
    private static func fullScreenWindow(on screen: NSScreen) -> Bool {
        let me = ProcessInfo.processInfo.processIdentifier
        let f = screen.frame
        return windows().contains { w in
            guard (w[kCGWindowOwnerPID as String] as? Int32) != me,
                  let owner = w[kCGWindowOwnerName as String] as? String,
                  let b = (w[kCGWindowBounds as String] as? [String: Any]).flatMap(appKitRect),
                  abs(b.minX - f.minX) < 2, abs(b.minY - f.minY) < 2, abs(b.width - f.width) < 2, abs(b.height - f.height) < 2
            else { return false }
            let layer = w[kCGWindowLayer as String] as? Int ?? 0
            return (layer == 0 && presenters.contains(owner)) || sharers.contains(owner)
        }
    }
}

extension Notification.Name {
    static let petBump = Notification.Name("coucou.petBump")
    static let petPetted = Notification.Name("coucou.petPetted")
}
