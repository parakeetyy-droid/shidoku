import SwiftUI
import UIKit

// The capture light. REDESIGNED on the owner's order (2026-07-21) to match the
// glow Chrome shows when Claude is controlling the browser: an edge-hugging
// INWARD terracotta glow that breathes. This SUPERSEDES the settled build-#11
// seven-mass edge bloom AND the build-#20 per-capture randomness (both remain
// in git history). The Chrome effect is deliberately IDENTICAL every capture.
//
// Spec, cloned 1:1 from the extension's #claude-agent-glow-border-inner
// (px used as pt — absolute thickness, not proportional):
//   three stacked INSET box-shadows, all rgb(217,119,87) (Claude terracotta):
//     blur 15 / alpha .70   (tight bright edge band)
//     blur 25 / alpha .50   (mid halo)
//     blur 35 / alpha .20   (wide soft bleed)
//   the whole glow breathes opacity 0.6 <-> 1.0, 2 s, ease-in-out, infinite
//   (0%/100% = 0.6, 50% = 1.0). No gradient, rotation, sweep or hue drift.

enum GlowMode: Equatable {
    case idle
    case bloom(Int)   // the Int is a capture counter so consecutive captures re-trigger
    case think
    case hello
}

struct GlowOverlay: UIViewRepresentable {
    let mode: GlowMode
    // PREVIEW-ONLY. Freeze the glow ON at the breathe peak (1.0) for the CI
    // capture screenshot. Never true in the shipped app; see PreviewMode.
    var pinPeak: Bool = false

    func makeUIView(context: Context) -> ShidokuGlowView {
        let v = ShidokuGlowView()
        v.isUserInteractionEnabled = false
        return v
    }

    func updateUIView(_ uiView: ShidokuGlowView, context: Context) {
        if pinPeak {
            uiView.pinAtPeak()
        } else {
            uiView.apply(mode)
        }
    }
}

final class ShidokuGlowView: UIView {

    // Claude terracotta — the Chrome agent-glow colour, rgb(217,119,87).
    private static let glowColor = UIColor(red: 217.0/255.0, green: 119.0/255.0,
                                           blue: 87.0/255.0, alpha: 1.0)
    // The three stacked inset shadows (blur pt, alpha), cloned 1:1.
    private static let shadows: [(blur: CGFloat, alpha: Float)] = [
        (15, 0.70),
        (25, 0.50),
        (35, 0.20),
    ]

    // Layer tree:  layer -> envelope -> breathe -> [glow x3]
    //   envelope: the birth/death fade (0 idle, 1 active), 0.30 s in/out.
    //   breathe:  the 0.6<->1.0 heartbeat; ALSO clips its children to the
    //             rounded screen so the glow follows the display corners.
    //   glow x3:  static inset-shadow layers (one per spec row).
    private let envelope = CALayer()
    private let breathe = CALayer()
    private var glowLayers: [CALayer] = []

    private var currentMode = GlowMode.idle
    private var builtSize = CGSize.zero
    private var pending: DispatchWorkItem?
    private var breathing = false
    private var wantPinPeak = false
    private var didPinPeak = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        envelope.opacity = 0
        breathe.opacity = 1
        envelope.addSublayer(breathe)
        layer.addSublayer(envelope)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != builtSize, bounds.width > 0, bounds.height > 0 {
            builtSize = bounds.size
            rebuild()
        }
    }

    private var reduceMotion: Bool { UIAccessibility.isReduceMotionEnabled }

    // The physical display's corner radius, so the glow hugs the screen shape.
    // _displayCornerRadius is private API read via KVC — acceptable for a
    // sideloaded personal app. Guarded by responds(to:) (a plain `try` can't
    // catch the ObjC unknown-key exception) with a 16e fallback.
    private var displayCornerRadius: CGFloat {
        let fallback: CGFloat = 55
        // KVC boxes the CGFloat as an NSNumber; read it as such (a direct
        // `as? CGFloat` bridge is unreliable and would silently force fallback).
        guard UIScreen.main.responds(to: NSSelectorFromString("_displayCornerRadius")),
              let n = UIScreen.main.value(forKey: "_displayCornerRadius") as? NSNumber else {
            return fallback
        }
        let r = CGFloat(n.doubleValue)
        return r > 0 ? r : fallback
    }

    // MARK: - geometry

    private func rebuild() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        envelope.frame = bounds
        breathe.frame = bounds
        let r = displayCornerRadius
        breathe.cornerRadius = r
        breathe.masksToBounds = true      // clip the child glows to the rounded screen
        glowLayers.forEach { $0.removeFromSuperlayer() }
        glowLayers = []
        for s in ShidokuGlowView.shadows {
            let g = CALayer()
            g.frame = bounds
            g.backgroundColor = UIColor.clear.cgColor
            g.shadowColor = ShidokuGlowView.glowColor.cgColor
            g.shadowOffset = .zero
            g.shadowRadius = s.blur
            g.shadowOpacity = s.alpha
            // A ring silhouette sitting OUTSIDE the screen shape: its blur
            // bleeds inward from the screen edge, and the parent's rounded clip
            // keeps only that inward band — an inset box-shadow that follows the
            // corners. shadowPath casts the shadow; the ring itself has no fill.
            let expand = s.blur + 12
            let path = UIBezierPath(roundedRect: bounds.insetBy(dx: -expand, dy: -expand),
                                    cornerRadius: r + expand)
            path.append(UIBezierPath(roundedRect: bounds, cornerRadius: r).reversing())
            g.shadowPath = path.cgPath
            breathe.addSublayer(g)
            glowLayers.append(g)
        }
        CATransaction.commit()
        // re-assert state against the fresh layers
        if wantPinPeak {
            didPinPeak = false
            applyPinIfReady()
        } else if currentMode == .idle {
            pauseClock()
        }
    }

    // MARK: - mode changes

    func apply(_ mode: GlowMode) {
        guard mode != currentMode else { return }
        currentMode = mode
        pending?.cancel()
        pending = nil
        switch mode {
        case .bloom:
            activate(startBright: true)
            scheduleIdle(after: 1.4)    // a shutter capture (no ask follows) fades out
        case .hello:
            activate(startBright: true)
            scheduleIdle(after: 2.5)    // one breathe cycle then fade out
        case .think:
            activate(startBright: false)   // seamless if .bloom already lit the breathe
        case .idle:
            deactivate()
        }
    }

    // Fade the glow in and get the breathe going. If the breathe is already
    // running (the .bloom -> .think seam), it is left untouched — the light is
    // visually continuous, no restart, no flicker.
    private func activate(startBright: Bool) {
        resumeClock()
        if reduceMotion {
            // static glow at 0.8, no pulse, instant in
            breathe.removeAnimation(forKey: "breathe")
            setOpacity(breathe, to: 0.8, duration: 0)
            setOpacity(envelope, to: 1.0, duration: 0)
            breathing = false
            return
        }
        if !breathing {
            breathing = true
            startBreathe(fromBright: startBright)
        }
        setOpacity(envelope, to: 1.0, duration: 0.30)
    }

    private func deactivate() {
        if reduceMotion {
            setOpacity(envelope, to: 0.0, duration: 0)
            breathe.removeAnimation(forKey: "breathe")
            breathing = false
            pauseClock()
            return
        }
        setOpacity(envelope, to: 0.0, duration: 0.30)
        let w = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.breathe.removeAnimation(forKey: "breathe")
            self.breathing = false
            self.pauseClock()
        }
        pending = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.30, execute: w)
    }

    private func scheduleIdle(after s: TimeInterval) {
        let w = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            switch self.currentMode {
            case .bloom, .hello: self.apply(.idle)
            default: break
            }
        }
        pending = w
        DispatchQueue.main.asyncAfter(deadline: .now() + s, execute: w)
    }

    // The 0.6<->1.0 heartbeat — one infinite keyframe animation, ease-in-out.
    // A capture starts it at the BRIGHT peak (ignition feel); a fresh .think
    // starts from the natural dip.
    private func startBreathe(fromBright: Bool) {
        let a = CAKeyframeAnimation(keyPath: "opacity")
        let vals: [Double] = fromBright ? [1.0, 0.6, 1.0] : [0.6, 1.0, 0.6]
        a.values = vals.map { NSNumber(value: $0) }
        a.keyTimes = [0.0, 0.5, 1.0].map { NSNumber(value: $0) }
        a.duration = 2.0
        a.repeatCount = .infinity
        let ease = CAMediaTimingFunction(name: .easeInEaseOut)
        a.timingFunctions = [ease, ease]
        breathe.opacity = fromBright ? 1.0 : 0.6
        breathe.add(a, forKey: "breathe")
    }

    // Set a layer's opacity, animated over `duration` (0 = instant, with
    // implicit actions disabled so no default fade sneaks in).
    private func setOpacity(_ l: CALayer, to target: Float, duration: CFTimeInterval) {
        let from = l.presentation()?.opacity ?? l.opacity
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        l.removeAnimation(forKey: "fade")
        l.opacity = target
        CATransaction.commit()
        guard duration > 0 else { return }
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = from
        a.toValue = target
        a.duration = duration
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        l.add(a, forKey: "fade")
    }

    // MARK: - preview pin (screenshot harness only — never the live app)

    // Freeze the glow fully ON at the breathe peak (1.0) so the CI capture
    // still shows it at full strength. Deterministic; nothing animating.
    func pinAtPeak() {
        wantPinPeak = true
        applyPinIfReady()
    }

    private func applyPinIfReady() {
        guard wantPinPeak, !didPinPeak, !glowLayers.isEmpty else { return }
        didPinPeak = true
        currentMode = .bloom
        pending?.cancel()
        pending = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        breathe.removeAnimation(forKey: "breathe")
        envelope.removeAnimation(forKey: "fade")
        breathe.opacity = 1.0     // breathe peak
        envelope.opacity = 1.0    // fully on
        breathing = false
        CATransaction.commit()
        pauseClock()
    }

    // MARK: - layer clock (paused when idle so the breathe costs nothing)

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
