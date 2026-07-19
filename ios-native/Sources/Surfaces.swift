import SwiftUI

// Shared surfaces and metrics, taken from the HTML demo the owner approved
// (Desktop\shidoku\demo\index.html) — which is itself measured 1:1 against
// his real Visual Intelligence recording. Numbers here are pt on a 390x844
// screen; the demo is the spec, this file is the port.

enum VI {
    // answer card
    static let cardMargin: CGFloat = 12.5
    static let cardRadius: CGFloat = 22
    static let cardPadding: CGFloat = 20
    static let cardTextSize: CGFloat = 19
    static let cardLineHeight: CGFloat = 26

    // status pill (morphs into the card — same surface, so the swap is seamless)
    static let pillWidth: CGFloat = 201
    static let pillHeight: CGFloat = 36
    static let pillRadius: CGFloat = 18
    static let pillTextSize: CGFloat = 17

    // follow-up row
    static let capsuleWidth: CGFloat = 313
    static let capsuleHeight: CGFloat = 50
    static let capsuleSideMargin: CGFloat = 11.5
    static let markSize: CGFloat = 34
    static let closeDiscSize: CGFloat = 43
    static let rowBottomInset: CGFloat = 3      // 37 pt from the screen edge, 34 of it safe area

    // ink
    static let ink = Color.black.opacity(0.86)
    static let placeholder = Color(red: 142.0/255.0, green: 142.0/255.0, blue: 147.0/255.0)
    static let pillInk = Color(red: 58.0/255.0, green: 58.0/255.0, blue: 60.0/255.0)
    static let brand = Color(red: 200.0/255.0, green: 97.0/255.0, blue: 63.0/255.0)
}

// The light post-capture surface: a warm near-white over a heavy blur of the
// photo. Apple's own rule (WWDC25 "Meet Liquid Glass") reserves Liquid Glass
// for the navigation/control layer — the answer card is CONTENT, so it is a
// material, not glass. The camera-bar controls stay real .glassEffect.
struct LightSurface: ViewModifier {
    var radius: CGFloat

    func body(content: Content) -> some View {
        content
            .background {
                // back to front: the material blurs the photo, then a warm
                // near-white tints it. Stacking these the other way round
                // renders a flat opaque card — the photo must still bleed
                // through as colour, as it does in the recording.
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(.regularMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .fill(Color(red: 252.0/255.0, green: 249.0/255.0, blue: 247.0/255.0)
                                .opacity(0.30))   // tuning knob for card warmth
                    }
            }
            .environment(\.colorScheme, .light)
            .shadow(color: .black.opacity(0.10), radius: 9, x: 0, y: 3)
    }
}

extension View {
    func lightSurface(radius: CGFloat) -> some View {
        modifier(LightSurface(radius: radius))
    }
}

// Claude's mark — a burst of tapered rays. Replaces the SF "sparkle" the
// first native pass used as a stand-in; the demo draws the real thing.
struct ClaudeMark: View {
    var color: Color = .black

    private static let rays: [(angle: Double, length: CGFloat)] = (0..<11).map { i in
        let angle = Double(i) / 11.0 * 360.0 + (i % 2 == 0 ? -3.0 : 4.0)
        let length: CGFloat = i % 3 == 0 ? 0.50 : (i % 3 == 1 ? 0.45 : 0.41)
        return (angle, length)
    }

    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            ZStack {
                ForEach(Array(Self.rays.enumerated()), id: \.offset) { _, ray in
                    Capsule()
                        .fill(color)
                        .frame(width: s * 0.085, height: s * ray.length)
                        .frame(width: s, height: s, alignment: .top)
                        .rotationEffect(.degrees(ray.angle))
                }
            }
            .frame(width: s, height: s)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
