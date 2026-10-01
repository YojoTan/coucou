import SwiftUI

// MARK: - Mochi themes — costumes per pill
// A theme dresses a Mochi from head to hands: headwear, something on its body
// or behind it, and props it holds (MochiHands.swift animates them). Each pill
// can wear its own (Settings › Extras › Costumes); the main Mochi and the
// desktop pet wear the focused pill's. Drawn in code like everything else, and
// original designs — no character from anyone's film or comic.

enum MochiTheme: String, CaseIterable, Codable, Sendable {
    case none
    case outlaw      // galactic outlaw: leather jacket, copper retro headphones, twin blasters
    case wizard      // starry hat, cape, a wand that sparkles
    case pirate      // bandana, eye patch, a cutlass
    case astronaut   // glass helmet, backpack, little stars
    case idol        // K-pop stage look: lavender hair with a fringe, a headset mic, a sequinned jacket; choreography

    var label: String {
        switch self {
        case .none: return String(localized: "No costume")
        case .outlaw: return String(localized: "Galactic outlaw")
        case .wizard: return String(localized: "Wizard")
        case .pirate: return String(localized: "Pirate")
        case .astronaut: return String(localized: "Astronaut")
        case .idol: return String(localized: "K-pop idol")
        }
    }

    /// Covers the head: the pill's accessory (cap, trophy…) steps aside.
    var hasHeadwear: Bool { self != .none }

    /// What each hand holds.
    var props: (left: HandProp?, right: HandProp?) {
        switch self {
        case .outlaw: return (.blaster, .blaster)
        case .wizard: return (nil, .wand)
        case .pirate: return (nil, .cutlass)
        case .none, .astronaut, .idol: return (nil, nil)
        }
    }
}

enum HandProp: Sendable { case blaster, wand, cutlass }

enum MochiThemes {
    static let key = "mochi-themes"     // [pill id: theme raw value]

    /// By default only Spotify wears one: the galactic outlaw, for the music.
    static var assignments: [String: String] {
        UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? ["integration_spotify": MochiTheme.outlaw.rawValue]
    }

    static func theme(for taskId: String?) -> MochiTheme {
        guard let taskId else { return .none }
        return assignments[taskId].flatMap(MochiTheme.init) ?? .none
    }

    static func set(_ theme: MochiTheme, for taskId: String) {
        var a = assignments
        a[taskId] = theme == .none ? nil : theme.rawValue
        UserDefaults.standard.set(a, forKey: key)
        NotificationCenter.default.post(name: .mochiThemeChanged, object: nil)
    }
}

extension Notification.Name {
    /// A pill's costume changed (Settings): every Mochi re-dresses at once.
    static let mochiThemeChanged = Notification.Name("coucou.mochiThemeChanged")
}

// MARK: - Drawing the costumes (body space; see BotEngine.draw)

extension BotEngine {
    /// Behind the body: the wizard's cape, the astronaut's backpack.
    func drawThemeBehind(ctx: GraphicsContext, R: CGFloat, rx: CGFloat, ry: CGFloat) {
        guard morph < 0.05 else { return }
        if theme == .outlaw && CACurrentMediaTime() < jetUntil {
            // Rocket boots: two flickering flames under the body.
            let t = CGFloat(CACurrentMediaTime())
            for sd in [-1.0, 1.0] as [CGFloat] {
                let len = ry * (0.8 + 0.25 * abs(sin(t * 31 + sd * 2)))
                let x = sd * rx * 0.38, top = ry * 0.8
                let flame = Path { p in
                    p.move(to: CGPoint(x: x - R * 0.18, y: top))
                    p.addQuadCurve(to: CGPoint(x: x, y: top + len), control: CGPoint(x: x - R * 0.17, y: top + len * 0.6))
                    p.addQuadCurve(to: CGPoint(x: x + R * 0.18, y: top), control: CGPoint(x: x + R * 0.17, y: top + len * 0.6))
                    p.closeSubpath()
                }
                ctx.fill(flame, with: .linearGradient(Gradient(colors: [Color(hex: "#FFF7D6"), Color(hex: "#FB923C"), Color(hex: "#EF4444").opacity(0)]),
                                                      startPoint: CGPoint(x: x, y: top), endPoint: CGPoint(x: x, y: top + len)))
            }
        }
        switch theme {
        case .wizard:
            let t = CGFloat(CACurrentMediaTime())
            let flutter = sin(t * 2.2) * R * 0.05
            let cape = Path { p in
                p.move(to: CGPoint(x: -rx * 0.8, y: -ry * 0.1))
                p.addQuadCurve(to: CGPoint(x: -rx * 1.15 - flutter, y: ry * 1.05), control: CGPoint(x: -rx * 1.2, y: ry * 0.4))
                p.addQuadCurve(to: CGPoint(x: rx * 1.15 + flutter, y: ry * 1.05), control: CGPoint(x: 0, y: ry * 1.25))
                p.addQuadCurve(to: CGPoint(x: rx * 0.8, y: -ry * 0.1), control: CGPoint(x: rx * 1.2, y: ry * 0.4))
                p.closeSubpath()
            }
            ctx.fill(cape, with: .linearGradient(Gradient(colors: [Color(hex: "#312E81"), Color(hex: "#1E1B4B")]),
                                                 startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 0, y: ry * 1.1)))
        case .astronaut:
            ctx.fill(Path(roundedRect: CGRect(x: -rx * 0.95, y: -ry * 0.55, width: rx * 1.9, height: ry * 1.1), cornerRadius: R * 0.25),
                     with: .linearGradient(Gradient(colors: [Color(hex: "#D1D5DB"), Color(hex: "#6B7280")]),
                                           startPoint: CGPoint(x: 0, y: -ry * 0.55), endPoint: CGPoint(x: 0, y: ry * 0.55)))
        default:
            break
        }
    }

    /// How far the face has turned from straight ahead: the eyes' shift, so the
    /// costume can turn with it (clothes fully, headwear half way).
    func faceShift(rx: CGFloat, ry: CGFloat) -> CGSize {
        let restY = -sin(MochiConst.eyeP) * ry
        let p = MochiConst.eyeP + pitch + roll
        return CGSize(width: sin(yaw) * cos(p) * rx * 0.9, height: -sin(p) * ry - restY)
    }

    /// On top: clothes clipped to the body, then headwear — both turning with the face.
    func drawThemeFront(ctx: GraphicsContext, bodyPath: Path, R: CGFloat, rx: CGFloat, ry: CGFloat) {
        guard theme != .none, morph < 0.05 else { return }
        let shift = faceShift(rx: rx, ry: ry)
        var clipped = ctx
        clipped.clip(to: bodyPath)
        clipped.translateBy(x: shift.width, y: shift.height)
        let skull = ctx       // hair sits on the head itself, which doesn't turn
        var ctx = ctx
        ctx.translateBy(x: shift.width * 0.5, y: shift.height * 0.35)
        let line = max(1, R * 0.05)
        switch theme {
        case .outlaw:
            // A leather jacket: dark red-brown, lighter lapels, a dark shirt in the V —
            // starting below the mouth, so the whistle and the talking still show.
            let top = ry * 0.6
            clipped.fill(Path(CGRect(x: -rx * 1.6, y: top, width: rx * 3.2, height: ry)),
                         with: .linearGradient(Gradient(colors: [Color(hex: "#8A2B1A"), Color(hex: "#4A150C")]),
                                               startPoint: CGPoint(x: 0, y: top), endPoint: CGPoint(x: 0, y: ry)))
            let v = Path { p in
                p.move(to: CGPoint(x: -rx * 0.22, y: top - ry * 0.02))
                p.addLine(to: CGPoint(x: 0, y: ry * 0.95))
                p.addLine(to: CGPoint(x: rx * 0.22, y: top - ry * 0.02))
                p.closeSubpath()
            }
            clipped.fill(v, with: .color(Color(hex: "#2B2F36")))
            for sd in [-1.0, 1.0] as [CGFloat] {
                let lapel = Path { p in
                    p.move(to: CGPoint(x: sd * rx * 0.22, y: top - ry * 0.02))
                    p.addLine(to: CGPoint(x: sd * rx * 0.55, y: top + ry * 0.05))
                    p.addLine(to: CGPoint(x: sd * rx * 0.05, y: ry * 0.9))
                    p.closeSubpath()
                }
                clipped.fill(lapel, with: .color(Color(hex: "#A33A22")))
            }
            clipped.stroke(Path { p in
                p.move(to: CGPoint(x: -rx * 1.2, y: top)); p.addLine(to: CGPoint(x: rx * 1.2, y: top))
            }, with: .color(.black.opacity(0.25)), lineWidth: line * 0.6)
            // A tape player clipped to the jacket; its reels turn while the music plays.
            let wm = CGRect(x: -rx * 0.78, y: top + ry * 0.08, width: R * 0.42, height: R * 0.28)
            clipped.fill(Path(roundedRect: wm, cornerRadius: R * 0.05), with: .color(Color(hex: "#1F2937")))
            clipped.fill(Path(roundedRect: wm.insetBy(dx: R * 0.04, dy: R * 0.05), cornerRadius: R * 0.03), with: .color(Color(hex: "#F59E0B").opacity(0.85)))
            let spin = musicPlaying ? CGFloat(CACurrentMediaTime()) * 6 : 0
            for cxr in [wm.minX + wm.width * 0.3, wm.minX + wm.width * 0.7] {
                let c = CGPoint(x: cxr, y: wm.midY), r = R * 0.055
                clipped.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)), with: .color(Color(hex: "#111827")))
                for k in 0..<3 {
                    let a = spin + CGFloat(k) * 2.094
                    clipped.stroke(Path { p in p.move(to: c); p.addLine(to: CGPoint(x: c.x + cos(a) * r * 0.85, y: c.y + sin(a) * r * 0.85)) },
                                   with: .color(.white.opacity(0.7)), lineWidth: max(0.6, R * 0.015))
                }
            }
        case .wizard:
            let t = CGFloat(CACurrentMediaTime())
            let tipX = rx * 0.55 + sin(t * 1.6) * R * 0.05
            let hat = Path { p in
                p.move(to: CGPoint(x: -rx * 0.72, y: -ry * 0.78))
                p.addQuadCurve(to: CGPoint(x: tipX, y: -ry * 2.0), control: CGPoint(x: -rx * 0.1, y: -ry * 1.5))
                p.addQuadCurve(to: CGPoint(x: rx * 0.72, y: -ry * 0.78), control: CGPoint(x: rx * 0.35, y: -ry * 1.35))
                p.closeSubpath()
            }
            ctx.fill(hat, with: .linearGradient(Gradient(colors: [Color(hex: "#6D28D9"), Color(hex: "#3B0764")]),
                                                startPoint: CGPoint(x: 0, y: -ry * 2), endPoint: CGPoint(x: 0, y: -ry * 0.78)))
            ctx.fill(Path(ellipseIn: CGRect(x: -rx * 1.05, y: -ry * 0.92, width: rx * 2.1, height: ry * 0.3)),
                     with: .color(Color(hex: "#4C1D95")))
            for (x, y, r) in [(-0.2, -1.2, 0.07), (0.15, -1.55, 0.05), (0.05, -1.0, 0.045)] as [(CGFloat, CGFloat, CGFloat)] {
                let twinkle = 0.6 + 0.4 * abs(sin(t * 3 + x * 10))
                ctx.fill(Path(ellipseIn: CGRect(x: rx * x - R * r, y: ry * y - R * r, width: R * r * 2, height: R * r * 2)),
                         with: .color(Color(hex: "#FDE68A").opacity(twinkle)))
            }
        case .pirate:
            // A red bandana with white dots, knotted on the side; a patch on one eye.
            let band = Path { p in
                p.move(to: CGPoint(x: -rx * 0.86, y: -ry * 0.55))
                p.addCurve(to: CGPoint(x: rx * 0.86, y: -ry * 0.55),
                           control1: CGPoint(x: -rx * 0.8, y: -ry * 1.3), control2: CGPoint(x: rx * 0.8, y: -ry * 1.3))
                p.closeSubpath()
            }
            ctx.fill(band, with: .color(Color(hex: "#C81E1E")))
            for (x, y) in [(-0.45, -0.8), (-0.05, -0.98), (0.35, -0.82), (0.15, -0.68), (-0.3, -0.64)] as [(CGFloat, CGFloat)] {
                ctx.fill(Path(ellipseIn: CGRect(x: rx * x - R * 0.04, y: ry * y - R * 0.04, width: R * 0.08, height: R * 0.08)),
                         with: .color(.white.opacity(0.85)))
            }
            for (dx, dy) in [(0.18, 0.1), (0.32, 0.28)] as [(CGFloat, CGFloat)] {
                ctx.fill(Path(roundedRect: CGRect(x: rx * (0.82 + dx * 0.4), y: -ry * 0.62 + ry * dy, width: R * 0.12, height: R * 0.26),
                              cornerRadius: R * 0.05), with: .color(Color(hex: "#A51616")))
            }
            if let eye = eyePositions(rx: rx, ry: ry).first {
                var clipped = clipped
                clipped.translateBy(x: -shift.width, y: -shift.height)     // the eyes already moved
                clipped.stroke(Path { p in
                    p.move(to: CGPoint(x: -rx * 1.1, y: eye.y - R * 0.32)); p.addLine(to: CGPoint(x: rx * 1.1, y: eye.y + R * 0.05))
                }, with: .color(.black.opacity(0.85)), lineWidth: line)
                clipped.fill(Path(ellipseIn: CGRect(x: eye.x - R * 0.17, y: eye.y - R * 0.15, width: R * 0.34, height: R * 0.3)),
                             with: .color(Color(hex: "#111111")))
            }
        case .astronaut:
            // The suit's collar ring, then the glass helmet over everything.
            clipped.fill(Path(CGRect(x: -rx * 1.2, y: ry * 0.8, width: rx * 2.4, height: ry * 0.4)),
                         with: .linearGradient(Gradient(colors: [Color(hex: "#9CA3AF"), Color(hex: "#4B5563")]),
                                               startPoint: CGPoint(x: 0, y: ry * 0.8), endPoint: CGPoint(x: 0, y: ry)))
            let r = max(rx, ry) * 1.16
            let dome = Path(ellipseIn: CGRect(x: -r, y: -r - ry * 0.02, width: r * 2, height: r * 2))
            ctx.fill(dome, with: .color(Color(hex: "#BFDBFE").opacity(0.12)))
            ctx.stroke(dome, with: .color(.white.opacity(0.55)), lineWidth: max(1, R * 0.05))
            ctx.stroke(Path { p in
                p.addArc(center: CGPoint(x: 0, y: -ry * 0.02), radius: r * 0.82, startAngle: .degrees(200), endAngle: .degrees(245), clockwise: false)
            }, with: .color(.white.opacity(0.6)), style: StrokeStyle(lineWidth: max(1, R * 0.06), lineCap: .round))
        case .idol:
            // Hair on the skull: it never slides down off the crown; it only lifts when
            // Mochi looks up, so the fringe stays clear of the eyes.
            var hair = skull
            hair.translateBy(x: shift.width * 0.25, y: min(0, shift.height) * 0.55)
            drawIdol(clipped: clipped, head: hair, bodyPath: bodyPath, R: R, rx: rx, ry: ry, shift: shift)
        case .none:
            break
        }
    }

    /// The K-pop stage look. The jacket turns with the face (clipped), the hair
    /// half as much (on the head), the mic sits by the mouth wherever it is.
    private func drawIdol(clipped: GraphicsContext, head: GraphicsContext, bodyPath: Path, R: CGFloat, rx: CGFloat, ry: CGFloat, shift: CGSize) {
        let t = CGFloat(CACurrentMediaTime())
        // Jacket: black, silver sequins that glint in turn, purple lapels — below the mouth.
        let top = ry * 0.6
        clipped.fill(Path(CGRect(x: -rx * 1.6, y: top, width: rx * 3.2, height: ry)),
                     with: .linearGradient(Gradient(colors: [Color(hex: "#1F1B2E"), Color(hex: "#0B0912")]),
                                           startPoint: CGPoint(x: 0, y: top), endPoint: CGPoint(x: 0, y: ry)))
        for i in 0..<14 {
            let x = -rx * 0.95 + CGFloat(i % 7) * rx * 0.32 + (i >= 7 ? rx * 0.16 : 0)
            let y = top + ry * (i >= 7 ? 0.24 : 0.1)
            let glint = 0.35 + 0.65 * max(0, sin(t * 4 + CGFloat(i) * 1.7))
            clipped.fill(Path(ellipseIn: CGRect(x: x, y: y, width: R * 0.07, height: R * 0.07)),
                         with: .color(Color(hex: "#E5E7EB").opacity(Double(glint))))
        }
        for sd in [-1.0, 1.0] as [CGFloat] {
            clipped.fill(Path { p in
                p.move(to: CGPoint(x: sd * rx * 0.18, y: top - ry * 0.02))
                p.addLine(to: CGPoint(x: sd * rx * 0.5, y: top + ry * 0.04))
                p.addLine(to: CGPoint(x: sd * rx * 0.04, y: ry * 0.92))
                p.closeSubpath()
            }, with: .color(Color(hex: "#7C3AED")))
        }
        // Hair: a soft lavender cap with a swept fringe that sways a little.
        let sway = sin(t * 1.8) * R * 0.03
        let hair = Path { p in
            p.move(to: CGPoint(x: -rx * 0.98, y: -ry * 0.18))
            p.addCurve(to: CGPoint(x: rx * 0.98, y: -ry * 0.22),
                       control1: CGPoint(x: -rx * 1.05, y: -ry * 1.35), control2: CGPoint(x: rx * 1.08, y: -ry * 1.35))
            // the fringe, in three locks, swept to one side, stopping above the eyes
            p.addQuadCurve(to: CGPoint(x: rx * 0.55 + sway, y: -ry * 0.3), control: CGPoint(x: rx * 0.85, y: -ry * 0.55))
            p.addQuadCurve(to: CGPoint(x: rx * 0.12 + sway, y: -ry * 0.36), control: CGPoint(x: rx * 0.4, y: -ry * 0.6))
            p.addQuadCurve(to: CGPoint(x: -rx * 0.35 + sway, y: -ry * 0.32), control: CGPoint(x: -rx * 0.08, y: -ry * 0.62))
            p.addQuadCurve(to: CGPoint(x: -rx * 0.98, y: -ry * 0.18), control: CGPoint(x: -rx * 0.75, y: -ry * 0.55))
            p.closeSubpath()
        }
        var h = head
        h.clip(to: bodyPath.applying(CGAffineTransform(scaleX: 1.04, y: 1.04)))   // hair hugs the head
        h.fill(hair, with: .linearGradient(Gradient(colors: [Color(hex: "#E9D5FF"), Color(hex: "#A78BFA"), Color(hex: "#7C3AED")]),
                                           startPoint: CGPoint(x: -rx * 0.6, y: -ry * 1.1), endPoint: CGPoint(x: rx * 0.6, y: -ry * 0.2)))
        h.stroke(Path { p in
            p.move(to: CGPoint(x: -rx * 0.3, y: -ry * 1.0)); p.addQuadCurve(to: CGPoint(x: rx * 0.35, y: -ry * 0.9), control: CGPoint(x: 0, y: -ry * 1.12))
        }, with: .color(.white.opacity(0.45)), style: StrokeStyle(lineWidth: max(1, R * 0.05), lineCap: .round))
        // Headset mic: an ear piece, a thin boom to beside the mouth.
        let ear = CGPoint(x: rx * 0.96, y: ry * 0.02)
        let mouth = mouthSpot(rx: rx, ry: ry).map { CGPoint(x: $0.0 + R * 0.24, y: $0.1 + ry * 0.04) } ?? CGPoint(x: R * 0.35, y: ry * 0.5)
        clipped.fill(Path(ellipseIn: CGRect(x: ear.x - R * 0.09 - shift.width, y: ear.y - R * 0.12 - shift.height, width: R * 0.18, height: R * 0.24)),
                     with: .color(Color(hex: "#D1D5DB")))
        var m = clipped
        m.translateBy(x: -shift.width, y: -shift.height)     // the mouth already moved
        m.stroke(Path { p in
            p.move(to: CGPoint(x: ear.x - R * 0.04, y: ear.y + R * 0.06))
            p.addQuadCurve(to: mouth, control: CGPoint(x: rx * 0.7, y: ry * 0.55))
        }, with: .color(Color(hex: "#9CA3AF")), style: StrokeStyle(lineWidth: max(1, R * 0.035), lineCap: .round))
        m.fill(Path(roundedRect: CGRect(x: mouth.x - R * 0.06, y: mouth.y - R * 0.04, width: R * 0.12, height: R * 0.08), cornerRadius: R * 0.04),
               with: .color(Color(hex: "#374151")))
    }
}
