import SwiftUI

// MARK: - Mochi's hands — always there, and saying something
// The hands used to come out only to wave hello. Now (on Mochis big enough to
// show them) they're always peeking at the sides, and each moment has a pose:
//
//   working → typing          thinking → a hand to the chin
//   searching → shading eyes  approval / question → a hand raised
//   finished → both up        error → hands to the cheeks
//   music → pumping on beat   talking in a call → gesturing
//   hello → the wave (BotEngine.greet)
//
// A pose is a target; the hands ease towards it, so changes read as movement.
// Positions are in body units (fractions of the half-width / half-height), so
// they follow squash, tilt and the dance. Costumes put props in them
// (MochiThemes.swift): the outlaw's blasters spin on the beat, fire on every
// fourth one, cheer-fire when a session finishes, and now and then the outlaw
// does a quick draw.

struct HandPose: Equatable {
    var x: CGFloat        // ± half-widths from the centre (outward is +)
    var y: CGFloat        // half-heights, + is down
    var rot: CGFloat      // radians, the prop's direction (0 = pointing outward)
    var scale: CGFloat
    var front: Bool       // drawn over the body

    static let rest = HandPose(x: 1.24, y: 0.66, rot: 0.15, scale: 0.92, front: false)

    func lerp(to t: HandPose, _ k: CGFloat) -> HandPose {
        HandPose(x: x + (t.x - x) * k, y: y + (t.y - y) * k, rot: rot + (t.rot - rot) * k,
                 scale: scale + (t.scale - scale) * k, front: t.front)     // the layer switches at once
    }
}

extension BotEngine {
    /// Called from update(): picks each hand's pose and eases towards it; fires the props.
    func updateHands(dt: Double, now: Double) {
        guard !isMini else { return }
        if !locks.contains("hands") { hands += (1 - hands) * CGFloat(1 - pow(0.002, dt)) }
        let t = CGFloat(now)
        let k = CGFloat(1 - pow(0.0004, dt))
        handLeft = handLeft.lerp(to: targetPose(left: true, t: t, now: now), k)
        handRight = handRight.lerp(to: targetPose(left: false, t: t, now: now), k)
        firePropsIfDue(now: now)
    }

    private func targetPose(left: Bool, t: CGFloat, now: Double) -> HandPose {
        let phase: CGFloat = left ? 0 : .pi
        let waving = now >= waveStart && waveStart > 0 && now < waveUntil
        if waving {
            // The wave itself is drawn from waveStart in drawHands; keep the pose neutral.
            return left ? HandPose(x: 1.24, y: 0.66 + sin(6 * t) * 0.04, rot: 0.15, scale: 0.92, front: false)
                        : HandPose(x: 1.26, y: -0.15, rot: -0.5, scale: 0.92, front: false)
        }
        if theme == .outlaw && now < quickDrawUntil {
            return HandPose(x: 1.36, y: 0.12, rot: -0.12, scale: 0.92, front: false)     // blasters out, pointing away
        }
        if theme == .idol && groove > 0.3 {
            // Choreography, a four-beat set: a V up, point, cross in front, point the other way.
            let beats = max(0, (now - beatT0) * bpm / 60)
            let snap = 1 - pow(1 - min(1, CGFloat(beats.truncatingRemainder(dividingBy: 1)) * 2.2), 3)
            switch Int(beats) % 4 {
            case 0: return HandPose(x: 1.28, y: -0.75 * snap + 0.3 * (1 - snap), rot: -1.1, scale: 0.92, front: false)
            case 1: return left ? HandPose(x: 1.2, y: 0.45, rot: 0.6, scale: 0.92, front: false)
                                : HandPose(x: 1.3, y: -0.9, rot: -1.4, scale: 0.92, front: false)
            case 2: return HandPose(x: 0.35, y: 0.55, rot: 0.4, scale: 0.9, front: true)
            default: return left ? HandPose(x: 1.3, y: -0.9, rot: -1.4, scale: 0.92, front: false)
                                 : HandPose(x: 1.2, y: 0.45, rot: 0.6, scale: 0.92, front: false)
            }
        }
        if theme == .idol && now < fingerHeartUntil && !left {
            return HandPose(x: 0.62, y: 0.12, rot: -1.2, scale: 0.85, front: true)    // a finger heart by the cheek
        }
        if groove > 0.3 {
            let beats = max(0, (now - beatT0) * bpm / 60)
            let mine = (Int(beats) % 2 == 0) == left
            let hit = mine ? pow(1 - CGFloat(beats.truncatingRemainder(dividingBy: 1)), 2) : 0
            var p = HandPose(x: 1.28, y: 0.35 - hit * 0.55, rot: -0.4 - hit * 0.8, scale: 0.92, front: false)
            if theme == .outlaw { p.rot = -0.5 + sin(t * 9 + phase) * 0.4 }               // spinning blasters
            return p
        }
        if talk > 0.3 && !left {
            return HandPose(x: 1.22 + cos(t * 5) * 0.08, y: 0.3 + sin(t * 5) * 0.12, rot: -0.3, scale: 0.92, front: false)
        }
        switch state {
        case .working:
            return HandPose(x: 0.6, y: 0.56 + sin(t * 15 + phase) * 0.08, rot: 0.35, scale: 0.95, front: true)     // typing
        case .thinking:
            return left ? .rest : HandPose(x: 0.4, y: 0.42 + sin(t * 4) * 0.03, rot: -0.9, scale: 0.85, front: true)
        case .searching:
            return left ? .rest : HandPose(x: 0.22, y: -0.62, rot: -1.5, scale: 0.9, front: true)              // shading the eyes
        case .approval, .question:
            return left ? .rest : HandPose(x: 1.28, y: -0.78 + sin(t * 3) * 0.06, rot: -1.2, scale: 0.92, front: false)
        case .finished:
            return HandPose(x: 1.22, y: -0.82 - abs(sin(t * 7)) * 0.1, rot: -1.0, scale: 0.92, front: false)
        case .error:
            return HandPose(x: 0.78 + sin(t * 30) * 0.015, y: 0.12, rot: -1.3, scale: 0.9, front: true)
        case .sleeping:
            return HandPose(x: 1.16, y: 0.74, rot: 0.3, scale: 0.75, front: false)
        default:
            break
        }
        // The outlaw keeps the cursor covered: the blaster on that side follows it.
        if theme == .outlaw && state == .idle && groove < 0.1 && hypot(lookX, lookY) > 0.55 && (lookX < 0) == left {
            let rot = left ? atan2(-lookY, -lookX) : atan2(-lookY, lookX)
            return HandPose(x: 1.34, y: max(-0.55, min(0.6, 0.1 - lookY * 0.5)), rot: rot, scale: 0.92, front: false)
        }
        switch theme {
        case .outlaw: return HandPose(x: 1.28, y: 0.58, rot: 1.15, scale: 0.92, front: false)   // blasters pointing down, at the hips
        case .wizard where !left: return HandPose(x: 1.26, y: 0.4, rot: -0.95, scale: 0.92, front: false)
        case .pirate where !left: return HandPose(x: 1.26, y: 0.5, rot: -0.7, scale: 0.92, front: false)
        default: return .rest
        }
    }

    /// The outlaw's shots, the wizard's sparkles.
    private func firePropsIfDue(now: Double) {
        switch theme {
        case .outlaw:
            if groove > 0.3 {
                let beat = Int(max(0, (now - beatT0) * bpm / 60))
                if beat != lastBoltBeat && beat % 4 == 0 {
                    lastBoltBeat = beat
                    shoot(left: (beat / 4) % 2 == 0, up: true)
                }
                if beat != lastTrickBeat {
                    lastTrickBeat = beat
                    if beat % 8 == 6 { spinStart[(beat / 8) % 2] = now }                  // a gunslinger's twirl
                    if beat % 16 == 8 {                                                    // the chorus: a moonwalk
                        let b = 60 / bpm * 1000
                        anim("ox", keys: [TweenKey(target: 0.22, duration: CGFloat(b), ease: Ease.inOut),
                                          TweenKey(target: -0.22, duration: CGFloat(b), ease: Ease.inOut),
                                          TweenKey(target: 0, duration: CGFloat(b) * 0.8, ease: Ease.out)])
                    }
                }
            }
            // Too many shots too fast: the barrels glow and steam.
            shotTimes.removeAll { now - $0 > 8 }
            heat += ((shotTimes.count >= 6 ? 1 : 0) - heat) * 0.03
            if heat > 0.5 && now - lastSteam > 0.45 {
                lastSteam = now
                for left in [true, false] { puff(left: left) }
            }
            if state == .finished && lastHandState != .finished {
                shoot(left: true, up: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in self?.shoot(left: false, up: true) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.36) { [weak self] in self?.shoot(left: true, up: true) }
            }
            if state == .idle && groove < 0.1 && now > nextQuickDraw {
                nextQuickDraw = now + Double.random(in: 14...28)
                quickDrawUntil = now + 1.3
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                    self?.shoot(left: true, up: false)
                    self?.shoot(left: false, up: false)
                }
            }
        case .idol:
            if state == .idle && groove < 0.1 && now > nextFingerHeart {
                nextFingerHeart = now + Double.random(in: 10...20)
                fingerHeartUntil = now + 1.8
                for i in 0..<3 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35 + Double(i) * 0.3) { [weak self] in
                        guard let self else { return }
                        let tip = self.handPoint(left: false)
                        self.particles.append(Particle(type: .heart, x: tip.x, y: tip.y - 0.1, vx: CGFloat.random(in: -0.15...0.15), vy: -0.5,
                                                       age: 0.001, life: 1.2, rot: 0, size: 0.12))
                    }
                }
            }
            if state == .finished && lastHandState != .finished {
                emit(.confetti, count: 14)
                emit(.heart, count: 5)
            }
        case .wizard:
            if (state == .working || state == .thinking || groove > 0.3) && now - lastSparkle > 0.3 {
                lastSparkle = now
                let tip = propTip(left: false)
                particles.append(Particle(type: .spark, x: tip.x, y: tip.y, vx: CGFloat.random(in: -0.3...0.3), vy: -0.4,
                                          age: 0, life: 0.8, rot: 0, size: 0.1))
            }
            if state == .finished && lastHandState != .finished { emit(.star, count: 8) }
        default:
            break
        }
        lastHandState = state
    }

    /// A bolt from one blaster: out of the barrel's mouth, along the barrel.
    func shoot(left: Bool, up: Bool) {
        let (tip, dir) = muzzle(left: left)
        let speed: CGFloat = 3.6
        particles.append(Particle(type: .bolt, x: tip.x, y: tip.y, vx: dir.dx * speed, vy: dir.dy * speed,
                                  age: 0.001, life: 0.5, rot: 0, size: 0.2))
        let now = CACurrentMediaTime()
        muzzleUntil[left ? 0 : 1] = now + 0.09
        lastShot[left ? 0 : 1] = now
        shotTimes.append(now)
    }

    /// A bolt in a given direction (the fan on a new track).
    func shoot(left: Bool, direction d: CGVector) {
        let (tip, _) = muzzle(left: left)
        particles.append(Particle(type: .bolt, x: tip.x, y: tip.y, vx: d.dx * 3.4, vy: d.dy * 3.4,
                                  age: 0.001, life: 0.55, rot: 0, size: 0.2))
        let now = CACurrentMediaTime()
        muzzleUntil[left ? 0 : 1] = now + 0.09
        lastShot[left ? 0 : 1] = now
        shotTimes.append(now)
    }

    /// A puff of smoke out of a barrel.
    func puff(left: Bool) {
        let (tip, dir) = muzzle(left: left)
        particles.append(Particle(type: .smoke, x: tip.x, y: tip.y, vx: dir.dx * 0.15, vy: -0.35,
                                  age: 0.001, life: 1.1, rot: 0, size: 0.07))
    }

    enum MusicEvent { case newTrack, paused, resumed }

    /// What Spotify just did, for a costume that cares (MusicSync).
    func musicEvent(_ e: MusicEvent) {
        guard theme == .outlaw else { return }
        switch e {
        case .newTrack:
            // A spin, blasters out, and a fan of bolts at the sky.
            doRoll(duration: 700, turns: 1)
            quickDrawUntil = CACurrentMediaTime() + 1.3
            for (i, a) in [-2.3, -1.9, -1.57, -1.25, -0.85].enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25 + Double(i) * 0.07) { [weak self] in
                    self?.shoot(left: i % 2 == 0, direction: CGVector(dx: cos(a), dy: sin(a)))
                }
            }
        case .paused:
            // Blow the smoke off the barrels, with a wink.
            eyeOverride = .wink
            eyeOverrideUntil = CACurrentMediaTime() + 1.3
            for i in 0..<4 {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.28) { [weak self] in
                    self?.puff(left: true)
                    self?.puff(left: false)
                }
            }
        case .resumed:
            let now = CACurrentMediaTime()
            spinStart = [now, now]
            quickDrawUntil = now + 0.9
        }
    }

    /// The barrel's mouth and direction, in particle units (R·1.3 from the body centre) —
    /// the same transform drawHands uses: mirror, scale, rotate, place.
    private func muzzle(left: Bool) -> (CGPoint, CGVector) {
        let pose = left ? handLeft : handRight
        let sd: CGFloat = left ? -1 : 1
        let theta = sd * pose.rot + tilt + danceTilt
        // In R units: hand ellipse 0.264 × 0.229 R; the mouth at 2.45 × −0.35 of those.
        let lx = sd * pose.scale * 2.45 * 0.264, ly = pose.scale * -0.35 * 0.229
        let mx = cos(theta) * lx - sin(theta) * ly, my = sin(theta) * lx + cos(theta) * ly
        let hx = sd * pose.x * 1.14 * sx * danceSx, hy = pose.y * 0.88 * sy * danceSy
        let hx2 = cos(tilt + danceTilt) * hx - sin(tilt + danceTilt) * hy
        let hy2 = sin(tilt + danceTilt) * hx + cos(tilt + danceTilt) * hy
        let tip = CGPoint(x: (hx2 + mx) / 1.3, y: (hy2 + my) / 1.3)
        return (tip, CGVector(dx: cos(theta) * sd, dy: sin(theta) * sd))
    }

    private func propTip(left: Bool) -> CGPoint { muzzle(left: left).0 }

    /// The hand's own centre, in particle units.
    func handPoint(left: Bool) -> CGPoint {
        let p = left ? handLeft : handRight
        let sd: CGFloat = left ? -1 : 1
        return CGPoint(x: sd * p.x * 1.14 * sx / 1.3, y: p.y * 0.88 * sy / 1.3)
    }

    /// Draws the hands (and props) that belong behind, or in front of, the body.
    func drawHands(context: GraphicsContext, size: CGSize, front: Bool) {
        guard hands > 0.01, !isMini else { return }
        let W = size.width, H = size.height
        let R = W * 0.3
        guard R > 14 else { return }
        let rx = R * 1.14, ry = R * 0.88
        let cx = W / 2 + ox * R
        let cy = H / 2 + particleOverhang / 2 + (oy + danceOy) * R + R * 0.06
        let tiltNow = tilt + danceTilt
        let hwB = rx * sx * danceSx, hhB = ry * sy * danceSy
        let hew = 0.30 * ry * hands, heh = 0.26 * ry * hands
        let now = CACurrentMediaTime()
        let waving = now >= waveStart && waveStart > 0 && now < waveUntil
        let props = theme.props

        for (left, pose) in [(true, handLeft), (false, handRight)] {
            guard pose.front == front else { continue }
            let sd: CGFloat = left ? -1 : 1
            var lx = sd * pose.x * hwB, ly = pose.y * hhB
            var rot = sd * pose.rot
            if waving && !left {
                // The hello wave: rises in 180 ms, then swings.
                let wt = CGFloat(now - waveStart)
                let rise = 1 - pow(1 - min(1, wt / 0.18), 3)
                let bodyH = 2 * ry
                lx = hwB * 1.24 + (hwB * 1.26 + cos(13 * wt) * 0.06 * bodyH - hwB * 1.24) * rise
                ly = hhB * 0.66 + (-hhB * 0.15 - sin(13 * wt) * 0.14 * bodyH - hhB * 0.66) * rise
                rot = (-0.5 + sin(13 * wt) * 0.35) * rise
            }
            // A twirl spins the prop round the finger; a shot kicks the hand back, muzzle up.
            let i = left ? 0 : 1
            let spinK = (now - spinStart[i]) / 0.45
            if spinK >= 0 && spinK < 1 { rot += sd * 2 * .pi * CGFloat(1 - pow(1 - spinK, 3)) }
            let kick = CGFloat(max(0, 1 - (now - lastShot[i]) / 0.14))
            if kick > 0 { rot -= sd * kick * 0.45; lx -= sd * kick * hwB * 0.07 }
            let wx = cx + cos(tiltNow) * lx - sin(tiltNow) * ly
            let wy = cy + sin(tiltNow) * lx + cos(tiltNow) * ly
            var c = context
            c.translateBy(x: wx, y: wy)
            c.rotate(by: .radians(rot + tiltNow))
            c.scaleBy(x: sd * pose.scale, y: pose.scale)   // mirrored for the left hand: props point outward
            if let prop = left ? props.left : props.right {
                drawProp(prop, ctx: c, hew: hew, heh: heh, flash: now < muzzleUntil[left ? 0 : 1])
            }
            let hand = Path(ellipseIn: CGRect(x: -hew, y: -heh, width: hew * 2, height: heh * 2))
            if let bc = bodyColor {
                let pal = palette(for: bc)     // the body's own material
                c.fill(hand, with: .linearGradient(Gradient(colors: [pal.light, pal.mid, pal.dark]),
                                                   startPoint: CGPoint(x: hew * 0.7, y: -heh * 0.85), endPoint: CGPoint(x: -hew * 0.8, y: heh * 0.9)))
                c.fill(Path(ellipseIn: CGRect(x: -hew * 0.1, y: -heh * 0.75, width: hew * 0.8, height: heh * 0.6)),
                       with: .radialGradient(Gradient(colors: [Color.white.opacity(0.45), .clear]),
                                             center: CGPoint(x: hew * 0.3, y: -heh * 0.45), startRadius: 0, endRadius: hew * 0.45))
            } else {
                c.fill(hand, with: .linearGradient(Gradient(colors: [Color(cgColor: MochiConst.baseTop), Color(cgColor: MochiConst.baseBottom)]),
                                                   startPoint: CGPoint(x: hew * 0.7, y: -heh * 0.85), endPoint: CGPoint(x: -hew * 0.8, y: heh * 0.9)))
            }
            c.stroke(hand, with: .color(Color.black.opacity(front ? 0.16 : 0.08)), lineWidth: 1)
        }
    }

    /// A prop in hand-local space, pointing along +x.
    private func drawProp(_ prop: HandProp, ctx c: GraphicsContext, hew: CGFloat, heh: CGFloat, flash: Bool) {
        switch prop {
        case .blaster:
            c.fill(Path(roundedRect: CGRect(x: -hew * 0.2, y: -heh * 0.1, width: hew * 0.55, height: heh * 1.25), cornerRadius: hew * 0.12),
                   with: .color(Color(hex: "#2A2D33")))
            let body = Path(roundedRect: CGRect(x: -hew * 0.35, y: -heh * 0.75, width: hew * 2.3, height: heh * 0.8), cornerRadius: heh * 0.3)
            c.fill(body, with: .linearGradient(Gradient(colors: [Color(hex: "#B8C0CC"), Color(hex: "#4B5563")]),
                                               startPoint: CGPoint(x: 0, y: -heh * 0.75), endPoint: CGPoint(x: 0, y: heh * 0.05)))
            c.fill(Path(CGRect(x: hew * 0.3, y: -heh * 0.42, width: hew * 1.1, height: heh * 0.14)), with: .color(Color(hex: "#F97316")))
            c.fill(Path(roundedRect: CGRect(x: hew * 1.85, y: -heh * 0.6, width: hew * 0.45, height: heh * 0.5), cornerRadius: heh * 0.12),
                   with: .color(Color(hex: "#374151")))
            if heat > 0.05 {
                c.fill(Path(roundedRect: CGRect(x: hew * 0.9, y: -heh * 0.75, width: hew * 1.45, height: heh * 0.8), cornerRadius: heh * 0.3),
                       with: .linearGradient(Gradient(colors: [.clear, Color(hex: "#EF4444").opacity(Double(heat) * 0.75)]),
                                             startPoint: CGPoint(x: hew * 0.9, y: 0), endPoint: CGPoint(x: hew * 2.35, y: 0)))
            }
            if flash {
                c.fill(Path(ellipseIn: CGRect(x: hew * 2.15, y: -heh * 0.95, width: hew * 1.0, height: heh * 1.1)),
                       with: .radialGradient(Gradient(colors: [.white, Color(hex: "#FB923C"), .clear]),
                                             center: CGPoint(x: hew * 2.65, y: -heh * 0.4), startRadius: 0, endRadius: hew * 0.6))
            }
        case .wand:
            c.stroke(Path { p in p.move(to: CGPoint(x: -hew * 0.2, y: 0)); p.addLine(to: CGPoint(x: hew * 2.6, y: 0)) },
                     with: .color(Color(hex: "#5B3A1E")), style: StrokeStyle(lineWidth: max(1.2, heh * 0.32), lineCap: .round))
            let r = heh * 0.5
            c.fill(Path(ellipseIn: CGRect(x: hew * 2.6 - r, y: -r, width: r * 2, height: r * 2)),
                   with: .radialGradient(Gradient(colors: [.white, Color(hex: "#FDE68A"), .clear]),
                                         center: CGPoint(x: hew * 2.6, y: 0), startRadius: 0, endRadius: r))
        case .cutlass:
            c.fill(Path(roundedRect: CGRect(x: -hew * 0.1, y: -heh * 0.55, width: hew * 0.25, height: heh * 1.1), cornerRadius: hew * 0.05),
                   with: .color(Color(hex: "#D4A017")))
            let blade = Path { p in
                p.move(to: CGPoint(x: hew * 0.15, y: -heh * 0.22))
                p.addQuadCurve(to: CGPoint(x: hew * 3.0, y: -heh * 0.75), control: CGPoint(x: hew * 1.8, y: -heh * 0.1))
                p.addQuadCurve(to: CGPoint(x: hew * 0.15, y: heh * 0.2), control: CGPoint(x: hew * 1.6, y: heh * 0.35))
                p.closeSubpath()
            }
            c.fill(blade, with: .linearGradient(Gradient(colors: [Color(hex: "#F3F4F6"), Color(hex: "#9CA3AF")]),
                                                startPoint: CGPoint(x: 0, y: -heh * 0.5), endPoint: CGPoint(x: 0, y: heh * 0.3)))
        }
    }
}
