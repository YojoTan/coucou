import SwiftUI

// MARK: - Mochi accessories and moods
// Things a Mochi can wear or feel, drawn in code like the rest of it, in body
// space (so they hop, tilt and squash with it). Who wears what is decided by
// MochiExtrasSync: a custom Mochi's pick, a trophy, the weather, the system, a
// Focus mode.

extension BotEngine {
    /// Called from draw(), in body space, after the eyes.
    func drawAccessory(ctx: GraphicsContext, bodyPath: Path, R: CGFloat, rx: CGFloat, ry: CGFloat) {
        guard morph < 0.05 else { return }
        if scruffy && accessory == .none {
            // Left alone for days: a few tufts sticking up.
            for (x, lean, h) in [(-0.3, -0.35, 0.28), (-0.05, 0.1, 0.36), (0.22, 0.4, 0.26)] as [(CGFloat, CGFloat, CGFloat)] {
                var tuft = Path()
                tuft.move(to: CGPoint(x: rx * x, y: -ry * 0.86))
                tuft.addQuadCurve(to: CGPoint(x: rx * (x + lean * 0.4), y: -ry * (0.86 + h)),
                                  control: CGPoint(x: rx * (x - lean * 0.2), y: -ry * (0.9 + h * 0.6)))
                ctx.stroke(tuft, with: .color(Color(hex: "#1B1D22").opacity(0.75)),
                           style: StrokeStyle(lineWidth: max(1, R * 0.05), lineCap: .round))
            }
        }
        guard accessory != .none else { return }
        let line = max(1, R * 0.06)
        let ink = Color(hex: "#1B1D22")
        switch accessory {
        case .none:
            break
        case .cap:
            let c = accessoryColor ?? Color(hex: "#E5484D")
            let dome = Path { p in
                p.move(to: CGPoint(x: -rx * 0.8, y: -ry * 0.62))
                p.addCurve(to: CGPoint(x: rx * 0.8, y: -ry * 0.62),
                           control1: CGPoint(x: -rx * 0.75, y: -ry * 1.42), control2: CGPoint(x: rx * 0.75, y: -ry * 1.42))
                p.closeSubpath()
            }
            ctx.fill(dome, with: .color(c))
            ctx.fill(Path(roundedRect: CGRect(x: rx * 0.25, y: -ry * 0.69, width: rx * 1.0, height: ry * 0.15),
                          cornerRadius: ry * 0.07), with: .color(c.opacity(0.8)))
            ctx.fill(Path(ellipseIn: CGRect(x: -R * 0.07, y: -ry * 1.22 - R * 0.07, width: R * 0.14, height: R * 0.14)),
                     with: .color(.white.opacity(0.8)))
        case .hardhat:
            let c = Color(hex: "#F5B90A")
            let dome = Path { p in
                p.move(to: CGPoint(x: -rx * 0.8, y: -ry * 0.62))
                p.addCurve(to: CGPoint(x: rx * 0.8, y: -ry * 0.62),
                           control1: CGPoint(x: -rx * 0.78, y: -ry * 1.48), control2: CGPoint(x: rx * 0.78, y: -ry * 1.48))
                p.closeSubpath()
            }
            ctx.fill(dome, with: .linearGradient(Gradient(colors: [Color(hex: "#FFD54A"), c]),
                                                 startPoint: CGPoint(x: 0, y: -ry * 1.1), endPoint: CGPoint(x: 0, y: -ry * 0.66)))
            ctx.fill(Path(roundedRect: CGRect(x: -rx * 0.98, y: -ry * 0.68, width: rx * 1.96, height: ry * 0.14),
                          cornerRadius: ry * 0.06), with: .color(c))
            var ridge = Path()
            ridge.move(to: CGPoint(x: 0, y: -ry * 1.24))
            ridge.addLine(to: CGPoint(x: 0, y: -ry * 0.68))
            ctx.stroke(ridge, with: .color(Color(hex: "#C98F00")), lineWidth: line * 1.4)
        case .crown:
            let gold = Color(hex: "#F7B32B")
            let w = rx * 0.82, base = -ry * 0.82, top = -ry * 1.3
            let crown = Path { p in
                p.move(to: CGPoint(x: -w / 2, y: base))
                p.addLine(to: CGPoint(x: -w / 2, y: top + ry * 0.12))
                p.addLine(to: CGPoint(x: -w / 4, y: base - ry * 0.16))
                p.addLine(to: CGPoint(x: 0, y: top))
                p.addLine(to: CGPoint(x: w / 4, y: base - ry * 0.16))
                p.addLine(to: CGPoint(x: w / 2, y: top + ry * 0.12))
                p.addLine(to: CGPoint(x: w / 2, y: base))
                p.closeSubpath()
            }
            ctx.fill(crown, with: .linearGradient(Gradient(colors: [Color(hex: "#FFE08A"), gold]),
                                                  startPoint: CGPoint(x: 0, y: top), endPoint: CGPoint(x: 0, y: base)))
            for (x, col) in [(-w / 4, "#E5484D"), (0, "#3E63DD"), (w / 4, "#30A46C")] {
                let r = R * 0.055
                ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: base - ry * 0.1 - r, width: r * 2, height: r * 2)),
                         with: .color(Color(hex: col)))
            }
        case .bow:
            let c = accessoryColor ?? Color(hex: "#F472B6")
            let cx = rx * 0.42, cy = -ry * 0.86, s = R * 0.26
            for sd in [-1.0, 1.0] {
                let wing = Path { p in
                    p.move(to: CGPoint(x: cx, y: cy))
                    p.addLine(to: CGPoint(x: cx + CGFloat(sd) * s, y: cy - s * 0.6))
                    p.addLine(to: CGPoint(x: cx + CGFloat(sd) * s, y: cy + s * 0.6))
                    p.closeSubpath()
                }
                ctx.fill(wing, with: .color(c))
            }
            ctx.fill(Path(ellipseIn: CGRect(x: cx - s * 0.25, y: cy - s * 0.25, width: s * 0.5, height: s * 0.5)),
                     with: .color(c.opacity(0.8)))
        case .antenna:
            let t = CGFloat(CACurrentMediaTime())
            let tip = CGPoint(x: rx * 0.15 + sin(t * 2.2) * R * 0.08, y: -ry * 1.5)
            var stalk = Path()
            stalk.move(to: CGPoint(x: 0, y: -ry * 0.9))
            stalk.addQuadCurve(to: tip, control: CGPoint(x: -rx * 0.05, y: -ry * 1.25))
            ctx.stroke(stalk, with: .color(ink), style: StrokeStyle(lineWidth: line, lineCap: .round))
            let r = R * 0.1
            let glow = 0.6 + 0.4 * Double(abs(sin(t * 3)))
            ctx.fill(Path(ellipseIn: CGRect(x: tip.x - r, y: tip.y - r, width: r * 2, height: r * 2)),
                     with: .color((accessoryColor ?? Color(hex: "#FF5D5D")).opacity(glow)))
        case .glasses, .sunglasses:
            let eyes = eyePositions(rx: rx, ry: ry)
            let r = R * 0.2
            for e in eyes {
                let lens = Path(roundedRect: CGRect(x: e.x - r, y: e.y - r * 0.85, width: r * 2, height: r * 1.7),
                                cornerRadius: r * 0.55)
                if accessory == .sunglasses {
                    ctx.fill(lens, with: .color(Color(hex: "#111318").opacity(0.92)))
                    var shine = Path()
                    shine.move(to: CGPoint(x: e.x - r * 0.5, y: e.y - r * 0.4))
                    shine.addLine(to: CGPoint(x: e.x - r * 0.1, y: e.y - r * 0.6))
                    ctx.stroke(shine, with: .color(.white.opacity(0.5)), style: StrokeStyle(lineWidth: line * 0.8, lineCap: .round))
                }
                ctx.stroke(lens, with: .color(ink), lineWidth: line)
            }
            if eyes.count == 2 {
                var bridge = Path()
                bridge.move(to: CGPoint(x: eyes[0].x + r, y: eyes[0].y - r * 0.2))
                bridge.addQuadCurve(to: CGPoint(x: eyes[1].x - r, y: eyes[1].y - r * 0.2),
                                    control: CGPoint(x: (eyes[0].x + eyes[1].x) / 2, y: eyes[0].y - r * 0.6))
                ctx.stroke(bridge, with: .color(ink), lineWidth: line)
            }
        case .sleepMask:
            var c = ctx
            c.clip(to: bodyPath)
            let y = eyePositions(rx: rx, ry: ry).first?.y ?? ry * 0.1
            c.fill(Path(roundedRect: CGRect(x: -rx * 1.1, y: y - R * 0.24, width: rx * 2.2, height: R * 0.54),
                        cornerRadius: R * 0.12), with: .color(Color(hex: "#4C3A8C")))
            for e in eyePositions(rx: rx, ry: ry) {
                var lid = Path()
                lid.move(to: CGPoint(x: e.x - R * 0.11, y: y))
                lid.addQuadCurve(to: CGPoint(x: e.x + R * 0.11, y: y), control: CGPoint(x: e.x, y: y + R * 0.1))
                c.stroke(lid, with: .color(.white.opacity(0.85)), style: StrokeStyle(lineWidth: line * 0.9, lineCap: .round))
            }
        case .umbrella:
            let t = CGFloat(CACurrentMediaTime())
            let cx = rx * 0.45, top = -ry * 1.55, r = rx * 0.78
            var shaft = Path()
            shaft.move(to: CGPoint(x: cx, y: top))
            shaft.addLine(to: CGPoint(x: cx + rx * 0.05, y: -ry * 0.25))
            shaft.addQuadCurve(to: CGPoint(x: cx + rx * 0.25, y: -ry * 0.22), control: CGPoint(x: cx + rx * 0.15, y: -ry * 0.05))
            ctx.stroke(shaft, with: .color(ink), style: StrokeStyle(lineWidth: line, lineCap: .round))
            let canopy = Path { p in
                p.move(to: CGPoint(x: cx - r, y: top + r * 0.45))
                p.addQuadCurve(to: CGPoint(x: cx + r, y: top + r * 0.45), control: CGPoint(x: cx, y: top - r * 0.75))
                for i in stride(from: 3, through: 0, by: -1) {
                    let x0 = cx - r + CGFloat(i) * r / 2
                    p.addQuadCurve(to: CGPoint(x: x0, y: top + r * 0.45),
                                   control: CGPoint(x: x0 + r / 4, y: top + r * 0.25))
                }
            }
            ctx.fill(canopy, with: .color(accessoryColor ?? Color(hex: "#3E63DD")))
            // Rain: three drops falling past it.
            for i in 0..<3 {
                let k = (t * 0.9 + CGFloat(i) / 3).truncatingRemainder(dividingBy: 1)
                let x = cx - r * 1.25 + CGFloat(i) * r * 1.2
                let y = top + k * ry * 1.6
                ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: R * 0.05, height: R * 0.12)),
                         with: .color(Color(hex: "#7CC7FF").opacity(Double(1 - k))))
            }
        case .pumpkin:
            // A carved pumpkin worn as a helmet: ribbed orange shell, a stalk, a grin.
            let top = -ry * 1.32, base = -ry * 0.6
            let shell = Path { p in
                p.move(to: CGPoint(x: -rx * 0.86, y: base))
                p.addCurve(to: CGPoint(x: rx * 0.86, y: base),
                           control1: CGPoint(x: -rx * 0.95, y: top), control2: CGPoint(x: rx * 0.95, y: top))
                p.closeSubpath()
            }
            ctx.fill(shell, with: .linearGradient(Gradient(colors: [Color(hex: "#FFA23A"), Color(hex: "#E8650C")]),
                                                  startPoint: CGPoint(x: 0, y: top), endPoint: CGPoint(x: 0, y: base)))
            for x in [-0.45, 0.0, 0.45] as [CGFloat] {
                var rib = Path()
                rib.move(to: CGPoint(x: rx * x * 0.6, y: top + ry * 0.12))
                rib.addQuadCurve(to: CGPoint(x: rx * x, y: base), control: CGPoint(x: rx * x * 1.25, y: (top + base) / 2))
                ctx.stroke(rib, with: .color(Color(hex: "#B84A06").opacity(0.55)), lineWidth: line * 0.8)
            }
            ctx.fill(Path(roundedRect: CGRect(x: -R * 0.05, y: top - R * 0.02, width: R * 0.1, height: R * 0.22), cornerRadius: R * 0.03),
                     with: .color(Color(hex: "#4D7C2A")))
            var grin = Path()
            grin.move(to: CGPoint(x: -rx * 0.32, y: base - ry * 0.18))
            grin.addQuadCurve(to: CGPoint(x: rx * 0.32, y: base - ry * 0.18), control: CGPoint(x: 0, y: base - ry * 0.02))
            ctx.stroke(grin, with: .color(Color(hex: "#3A1A00")), style: StrokeStyle(lineWidth: line * 1.2, lineCap: .round))
            for sd in [-1.0, 1.0] as [CGFloat] {
                let eye = Path { p in
                    p.move(to: CGPoint(x: sd * rx * 0.3, y: base - ry * 0.48))
                    p.addLine(to: CGPoint(x: sd * rx * 0.18, y: base - ry * 0.32))
                    p.addLine(to: CGPoint(x: sd * rx * 0.42, y: base - ry * 0.32))
                    p.closeSubpath()
                }
                ctx.fill(eye, with: .color(Color(hex: "#3A1A00")))
            }
        case .santaHat:
            let t = CGFloat(CACurrentMediaTime())
            // A tall cone that flops over to the right, its pompom swinging.
            let tip = CGPoint(x: rx * 1.05 + sin(t * 1.4) * R * 0.05, y: -ry * 1.22)
            let hat = Path { p in
                p.move(to: CGPoint(x: -rx * 0.7, y: -ry * 0.76))
                p.addCurve(to: tip, control1: CGPoint(x: -rx * 0.45, y: -ry * 1.75), control2: CGPoint(x: rx * 0.55, y: -ry * 2.05))
                p.addCurve(to: CGPoint(x: rx * 0.66, y: -ry * 0.78), control1: CGPoint(x: rx * 0.7, y: -ry * 1.5), control2: CGPoint(x: rx * 0.45, y: -ry * 1.15))
                p.closeSubpath()
            }
            ctx.fill(hat, with: .linearGradient(Gradient(colors: [Color(hex: "#F04848"), Color(hex: "#B91C1C")]),
                                                startPoint: CGPoint(x: 0, y: -ry * 1.6), endPoint: CGPoint(x: 0, y: -ry * 0.76)))
            ctx.fill(Path(roundedRect: CGRect(x: -rx * 0.8, y: -ry * 0.86, width: rx * 1.6, height: ry * 0.2), cornerRadius: ry * 0.1),
                     with: .color(.white))
            let r = R * 0.12
            ctx.fill(Path(ellipseIn: CGRect(x: tip.x - r, y: tip.y - r, width: r * 2, height: r * 2)), with: .color(.white))
        case .partyHat:
            let cone = Path { p in
                p.move(to: CGPoint(x: -rx * 0.38, y: -ry * 0.84))
                p.addLine(to: CGPoint(x: rx * 0.08, y: -ry * 1.7))
                p.addLine(to: CGPoint(x: rx * 0.46, y: -ry * 0.8))
                p.closeSubpath()
            }
            ctx.fill(cone, with: .linearGradient(Gradient(colors: [Color(hex: "#A78BFA"), Color(hex: "#7C3AED")]),
                                                 startPoint: CGPoint(x: 0, y: -ry * 1.7), endPoint: CGPoint(x: 0, y: -ry * 0.8)))
            for (i, c) in ["#FBBF24", "#34D399", "#F472B6"].enumerated() {
                let y = -ry * (0.98 + CGFloat(i) * 0.22)
                ctx.fill(Path(ellipseIn: CGRect(x: rx * (0.02 - CGFloat(i) * 0.04), y: y, width: R * 0.09, height: R * 0.09)),
                         with: .color(Color(hex: c)))
            }
            let r = R * 0.1
            ctx.fill(Path(ellipseIn: CGRect(x: rx * 0.08 - r, y: -ry * 1.7 - r, width: r * 2, height: r * 2)), with: .color(Color(hex: "#FBBF24")))
        case .scarf:
            var c = ctx
            c.clip(to: bodyPath)
            let col = accessoryColor ?? Color(hex: "#E5484D")
            c.fill(Path(CGRect(x: -rx * 1.2, y: ry * 0.5, width: rx * 2.4, height: ry * 0.24)), with: .color(col))
            for i in 0..<5 {
                let x = -rx + CGFloat(i) * rx * 0.5
                c.fill(Path(CGRect(x: x, y: ry * 0.5, width: rx * 0.12, height: ry * 0.24)), with: .color(.white.opacity(0.35)))
            }
            ctx.fill(Path(roundedRect: CGRect(x: rx * 0.45, y: ry * 0.6, width: rx * 0.22, height: ry * 0.5),
                          cornerRadius: rx * 0.05), with: .color(col))
        }
    }

    /// Where the eyes sit (same projection as drawEyes), for glasses and the mask.
    func eyePositions(rx: CGFloat, ry: CGFloat) -> [CGPoint] {
        [-1.0, 1.0].compactMap { sd in
            let eyeYaw = CGFloat(sd) * MochiConst.eyeSp + yaw
            let eyePitch = MochiConst.eyeP + pitch + roll
            let cp = cos(eyePitch)
            guard cos(eyeYaw) * cp > 0.04 else { return nil }
            return CGPoint(x: sin(eyeYaw) * cp * rx, y: -sin(eyePitch) * ry)
        }
    }

    /// Moods set by MochiExtrasSync: sweat, sleepy eyes, panic. Called from update().
    func updateMoods(now: Double) {
        if sweating && now - lastMoodSweat > 1.5 {
            lastMoodSweat = now
            emit(.sweat, count: 1)
        }
        if sleepy || accessory == .sleepMask {
            if eyeOverride == nil || eyeOverride == permanentEye || eyeOverride == .tired || eyeOverride == .closed {
                eyeOverride = accessory == .sleepMask ? .closed : .tired
                eyeOverrideUntil = now + 0.3
            }
        }
        if panicked {
            ox = sin(CGFloat(now) * 40) * 0.025
            if eyeOverride == nil || eyeOverride == permanentEye || eyeOverride == .wide {
                eyeOverride = .wide
                eyeOverrideUntil = now + 0.3
            }
        }
    }
}
