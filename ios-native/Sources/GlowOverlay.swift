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

    func makeUIView(context: Context) -> ShidokuGlowView {
        let v = ShidokuGlowView()
        v.isUserInteractionEnabled = false
        return v
    }

    func updateUIView(_ uiView: ShidokuGlowView, context: Context) {
        uiView.apply(mode)
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
        case .bloom:
            reshuffleColors() // a different light every capture, like the real thing
            resumeClock()
            runEnvelope(values: [0.0, 1.0, 0.85, 0.0], times: [0.0, 0.18, 0.52, 1.0],
                        duration: 1.1, maxStagger: 0.12)
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

    // MARK: - geometry

    private func rebuild() {
        for b in blobs { b.removeFromSuperlayer() }
        blobs = []
        let w = bounds.width
        let h = bounds.height
        let side = min(w, h)
        let colors = ShidokuGlowView.palette.shuffled()
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
            addDrift(to: g, side: side)
        }
        if currentMode == .idle { pauseClock() }
    }

    private func addDrift(to g: CAGradientLayer, side: CGFloat) {
        let moveDur = CFTimeInterval.random(in: 1.6...3.4)
        let move = CABasicAnimation(keyPath: "position")
        move.byValue = NSValue(cgPoint: CGPoint(x: CGFloat.random(in: -0.10...0.10) * side,
                                                y: CGFloat.random(in: -0.10...0.10) * side))
        move.duration = moveDur
        move.autoreverses = true
        move.repeatCount = .infinity
        move.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        move.timeOffset = CFTimeInterval.random(in: 0.0..<moveDur)
        g.add(move, forKey: "drift")

        let scaleDur = CFTimeInterval.random(in: 1.2...2.6)
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = NSNumber(value: 0.92)
        scale.toValue = NSNumber(value: 1.15)
        scale.duration = scaleDur
        scale.autoreverses = true
        scale.repeatCount = .infinity
        scale.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        scale.timeOffset = CFTimeInterval.random(in: 0.0..<scaleDur)
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
