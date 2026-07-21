import SwiftUI
import UIKit

// The capture light — SETTLED by the owner on build #11 (2026-07-14) after
// eleven iterations; the visual parameters below are a verbatim port of the
// Capacitor-era native/ShidokuGlow.swift and must not drift. Geometry and
// timing were measured from the owner's real Apple Visual Intelligence
// recording: NOT a border ring — a few very large, very soft colored masses
// whose centers sit on the screen border, bleeding ~35% inward, drifting.
// Ignition ~0.2 s after the tap, peak ~0.5 s, gone by ~1 s.

enum GlowMode: Equatable {
    case idle
    case bloom(Int)   // the Int is a capture counter so consecutive blooms re-trigger
    case think
    case hello
}

struct GlowOverlay: UIViewRepresentable {
    let mode: GlowMode
    // PREVIEW-ONLY. Freeze the masses at their ignite peak so the CI capture
    // still shows them at full strength (the live shot otherwise catches an
    // arbitrary early frame). Never true in the shipped app; see PreviewMode.
    var pinPeak: Bool = false

    func makeUIView(context: Context) -> ShidokuGlowView {
        let v = ShidokuGlowView()
        v.isUserInteractionEnabled = false
        return v
    }

    func updateUIView(_ uiView: ShidokuGlowView, context: Context) {
        if pinPeak {
            uiView.pinAtIgnitePeak()
        } else {
            uiView.apply(mode)
        }
    }
}

final class ShidokuGlowView: UIView {

    // The seven documented Apple Intelligence colors.
    private static let palette: [UIColor] = [
        UIColor(red: 188.0/255.0, green: 130.0/255.0, blue: 243.0/255.0, alpha: 1.0), // #BC82F3
        UIColor(red: 245.0/255.0, green: 185.0/255.0, blue: 234.0/255.0, alpha: 1.0), // #F5B9EA
        UIColor(red: 141.0/255.0, green: 159.0/255.0, blue: 255.0/255.0, alpha: 1.0), // #8D9FFF
        UIColor(red: 170.0/255.0, green: 110.0/255.0, blue: 238.0/255.0, alpha: 1.0), // #AA6EEE
        UIColor(red: 255.0/255.0, green: 103.0/255.0, blue: 120.0/255.0, alpha: 1.0), // #FF6778
        UIColor(red: 255.0/255.0, green: 186.0/255.0, blue: 113.0/255.0, alpha: 1.0), // #FFBA71
        UIColor(red: 198.0/255.0, green: 134.0/255.0, blue: 255.0/255.0, alpha: 1.0)  // #C686FF
    ]

    // (x, y, diameter as a fraction of the short screen side, peak opacity)
    private struct Spot {
        let x: CGFloat
        let y: CGFloat
        let d: CGFloat
        let a: Float
    }
    private static let spots: [Spot] = [
        Spot(x: -0.06, y: 0.30, d: 1.20, a: 0.90),  // left edge, upper — the big mass
        Spot(x: 0.30, y: 1.05, d: 1.05, a: 0.80),   // bottom, left of center
        Spot(x: 0.80, y: 1.02, d: 0.90, a: 0.72),   // bottom, right
        Spot(x: 1.06, y: 0.45, d: 0.95, a: 0.78),   // right edge
        Spot(x: 0.55, y: -0.05, d: 0.85, a: 0.65),  // top, right of center
        Spot(x: 0.05, y: -0.04, d: 0.70, a: 0.60),  // top-left corner
        Spot(x: 1.03, y: 0.90, d: 0.65, a: 0.58)    // bottom-right corner
    ]

    private var currentMode = GlowMode.idle
    private var blobs: [CAGradientLayer] = []
    private var builtSize = CGSize.zero
    private var pending: DispatchWorkItem?
    private var wantPinPeak = false
    private var didPinPeak = false

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != builtSize, bounds.width > 0, bounds.height > 0 {
            builtSize = bounds.size
            rebuild()
        }
    }

    // MARK: - mode changes (same state machine the message channel drove)

    func apply(_ mode: GlowMode) {
        guard mode != currentMode else { return }
        let previous = currentMode
        currentMode = mode
        pending?.cancel()
        pending = nil
        if UIAccessibility.isReduceMotionEnabled { return }
        switch mode {
        case .bloom(let count):
            reshuffleColors() // a different light every capture, like the real thing
            resumeClock()
            // seeded by the capture counter: a DIFFERENT ignition choreography
            // every capture (mass order, stagger jitter, drift), deterministic
            // per count so it is reproducible and consecutive captures visibly
            // differ. Envelope shape/duration and the palette are unchanged.
            runBloomIgnite(seed: UInt64(bitPattern: Int64(count)))
            scheduleIdle(after: 1.4)
        case .hello:
            resumeClock()
            runEnvelope(values: [0.0, 0.7, 0.45, 0.0], times: [0.0, 0.22, 0.55, 1.0],
                        duration: 2.4, maxStagger: 0.25)
            scheduleIdle(after: 2.9)
        case .think:
            if case .bloom = previous {
                // let the capture light finish before the breathing starts
                let w = DispatchWorkItem { [weak self] in self?.startThink() }
                pending = w
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: w)
            } else {
                startThink()
            }
        case .idle:
            goIdle()
        }
    }

    private func startThink() {
        currentMode = .think
        resumeClock()
        for (i, b) in blobs.enumerated() {
            let base = ShidokuGlowView.spots[i % ShidokuGlowView.spots.count].a
            let a = CABasicAnimation(keyPath: "opacity")
            a.fromValue = NSNumber(value: 0.08 * base)
            a.toValue = NSNumber(value: 0.5 * base)
            a.duration = 1.1
            a.autoreverses = true
            a.repeatCount = .infinity
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            a.timeOffset = CFTimeInterval.random(in: 0.0..<2.2) // desynchronized breathing
            b.add(a, forKey: "env")
        }
    }

    private func goIdle() {
        for b in blobs { b.removeAnimation(forKey: "env") }
        pauseClock()
    }

    // MARK: - preview pin (screenshot harness only — never the live app)

    // Hold the masses at the ignite peak so a still capture shows them at full
    // strength. The live envelope peaks and fades in ~1 s, so a screenshot
    // catches a weak arbitrary frame; the approved demo pins its 38% keyframe
    // (0.38 × 1.15 s ≈ 0.44 s) at peak opacity, and this matches that. Nothing
    // here runs unless GlowOverlay.pinPeak is set from PreviewMode.
    func pinAtIgnitePeak() {
        wantPinPeak = true
        applyPinIfReady()
    }

    private func applyPinIfReady() {
        guard wantPinPeak, !didPinPeak, !blobs.isEmpty else { return }
        didPinPeak = true
        // stamp each mass at its peak opacity with no implicit animation, and
        // drop the drift/scale loops so the frame is static and deterministic
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, b) in blobs.enumerated() {
            b.removeAllAnimations()
            b.opacity = ShidokuGlowView.spots[i % ShidokuGlowView.spots.count].a
        }
        CATransaction.commit()
        // freeze the layer clock at the demo's ignite-peak instant (as briefed)
        layer.speed = 0.0
        layer.timeOffset = 0.38 * 1.15
    }

    private func scheduleIdle(after s: TimeInterval) {
        let w = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            switch self.currentMode {
            case .bloom, .hello: self.goIdle()
            default: break
            }
        }
        pending = w
        DispatchQueue.main.asyncAfter(deadline: .now() + s, execute: w)
    }

    // One envelope per blob, slightly staggered so the masses ignite
    // unevenly the way the recording does.
    private func runEnvelope(values: [Float], times: [NSNumber],
                             duration: CFTimeInterval, maxStagger: CFTimeInterval) {
        let now = layer.convertTime(CACurrentMediaTime(), from: nil)
        for (i, b) in blobs.enumerated() {
            let base = ShidokuGlowView.spots[i % ShidokuGlowView.spots.count].a
            let a = CAKeyframeAnimation(keyPath: "opacity")
            a.values = values.map { NSNumber(value: $0 * base) }
            a.keyTimes = times
            a.duration = duration
            a.beginTime = now + CFTimeInterval.random(in: 0.0...maxStagger)
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            b.add(a, forKey: "env")
        }
    }

    // The capture ignite, randomized per capture and seeded by the capture
    // counter. Randomized: the ORDER the seven masses light in, a small
    // per-mass stagger jitter, and each mass's drift direction/phase. NOT
    // touched: the spots table, the colour palette + its reshuffle, the ~1.1 s
    // envelope shape/duration, the breathing, Reduce Motion suppression. (The
    // preview pin never calls this — it stamps peaks directly, so it stays
    // deterministic no matter what order this would have chosen.)
    private func runBloomIgnite(seed: UInt64) {
        var rng = SeededRNG(seed: seed)
        let values: [Float] = [0.0, 1.0, 0.85, 0.0]
        let times: [NSNumber] = [0.0, 0.18, 0.52, 1.0]
        let duration: CFTimeInterval = 1.1
        let maxStagger: CFTimeInterval = 0.12   // keep the window ~1.1 s — do not stretch
        let side = min(bounds.width, bounds.height)
        let now = layer.convertTime(CACurrentMediaTime(), from: nil)
        let order = blobs.indices.shuffled(using: &rng)   // who lights first → last
        let span = Double(max(1, blobs.count - 1))
        for (rank, idx) in order.enumerated() {
            let b = blobs[idx]
            let base = ShidokuGlowView.spots[idx % ShidokuGlowView.spots.count].a
            let a = CAKeyframeAnimation(keyPath: "opacity")
            a.values = values.map { NSNumber(value: $0 * base) }
            a.keyTimes = times
            a.duration = duration
            // ordered start times across the stagger window + a little jitter,
            // so the sweep direction changes per capture but the window holds
            let slot = Double(rank) / span
            let jitter = Double.random(in: -0.02...0.02, using: &rng)
            a.beginTime = now + min(maxStagger, max(0.0, slot * maxStagger + jitter))
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            b.add(a, forKey: "env")
            // re-seed this mass's drift for the ignite — the masses are
            // invisible at t=0 (the envelope starts at 0), so the position
            // reset never shows
            addDrift(to: b, side: side, using: &rng)
        }
    }

    // MARK: - geometry

    private func rebuild() {
        for b in blobs { b.removeFromSuperlayer() }
        blobs = []
        let w = bounds.width
        let h = bounds.height
        let side = min(w, h)
        let colors = ShidokuGlowView.palette.shuffled()
        var sys = SystemRandomNumberGenerator()   // initial drift; the per-capture
                                                  // ignite re-seeds it deterministically
        for (i, s) in ShidokuGlowView.spots.enumerated() {
            let g = CAGradientLayer()
            g.type = .radial
            let c = colors[i % colors.count]
            g.colors = [c.cgColor,
                        c.withAlphaComponent(0.5).cgColor,
                        c.withAlphaComponent(0.0).cgColor]
            g.locations = [0.0, 0.38, 1.0]
            g.startPoint = CGPoint(x: 0.5, y: 0.5)
            g.endPoint = CGPoint(x: 1.0, y: 1.0)
            let d = s.d * side
            g.bounds = CGRect(x: 0.0, y: 0.0, width: d, height: d)
            g.position = CGPoint(x: s.x * w, y: s.y * h)
            g.opacity = 0.0
            // light adds, it does not paint over — blends with the photo below
            g.compositingFilter = "screenBlendMode"
            layer.addSublayer(g)
            blobs.append(g)
            addDrift(to: g, side: side, using: &sys)
        }
        if currentMode == .idle { pauseClock() }
        // if a preview pin was requested before the blobs existed (or a
        // re-layout rebuilt them), apply it now against the fresh blobs
        if wantPinPeak { didPinPeak = false; applyPinIfReady() }
    }

    // Drift + wobble for one mass. Takes the generator so rebuild can seed it
    // from the system RNG while a capture ignite seeds it deterministically
    // (per-capture drift variation, W1).
    private func addDrift<R: RandomNumberGenerator>(to g: CAGradientLayer, side: CGFloat, using rng: inout R) {
        let moveDur = CFTimeInterval.random(in: 1.6...3.4, using: &rng)
        let move = CABasicAnimation(keyPath: "position")
        move.byValue = NSValue(cgPoint: CGPoint(x: CGFloat.random(in: -0.10...0.10, using: &rng) * side,
                                                y: CGFloat.random(in: -0.10...0.10, using: &rng) * side))
        move.duration = moveDur
        move.autoreverses = true
        move.repeatCount = .infinity
        move.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        move.timeOffset = CFTimeInterval.random(in: 0.0..<moveDur, using: &rng)
        g.add(move, forKey: "drift")

        let scaleDur = CFTimeInterval.random(in: 1.2...2.6, using: &rng)
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = NSNumber(value: 0.92)
        scale.toValue = NSNumber(value: 1.15)
        scale.duration = scaleDur
        scale.autoreverses = true
        scale.repeatCount = .infinity
        scale.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        scale.timeOffset = CFTimeInterval.random(in: 0.0..<scaleDur, using: &rng)
        g.add(scale, forKey: "wobble")
    }

    private func reshuffleColors() {
        let colors = ShidokuGlowView.palette.shuffled()
        for (i, b) in blobs.enumerated() {
            let c = colors[i % colors.count]
            b.colors = [c.cgColor,
                        c.withAlphaComponent(0.5).cgColor,
                        c.withAlphaComponent(0.0).cgColor]
        }
    }

    // MARK: - layer clock (paused when idle so the drift loops cost nothing)

    private func pauseClock() {
        guard layer.speed != 0.0 else { return }
        let t = layer.convertTime(CACurrentMediaTime(), from: nil)
        layer.speed = 0.0
        layer.timeOffset = t
    }

    private func resumeClock() {
        guard layer.speed == 0.0 else { return }
        let paused = layer.timeOffset
        layer.speed = 1.0
        layer.timeOffset = 0.0
        layer.beginTime = 0.0
        let dt = layer.convertTime(CACurrentMediaTime(), from: nil) - paused
        layer.beginTime = dt
    }
}

// A tiny deterministic generator (SplitMix64) so each capture's ignite
// choreography is seeded by its counter: different every capture, and
// reproducible for the same count.
private struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed ^ 0x9E3779B97F4A7C15 }
    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
