import SwiftUI

// The idle bar — geometry is the owner-approved canon measured from his real
// VI recording: 48 pt dark glass discs with filled white glyphs, 15 pt
// labels, 78 pt shutter with ONE soft hue drifting on its ring (10 s/cycle),
// padding 26/56/24, no scrim. Material is now real system Liquid Glass.

struct PressScaleStyle: ButtonStyle {
    var scale: CGFloat = 0.9
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1.0)
            .animation(.easeOut(duration: 0.18), value: configuration.isPressed)
    }
}

private let discTint = Color(red: 28.0/255.0, green: 29.0/255.0, blue: 32.0/255.0).opacity(0.44)

struct SideButton: View {
    let label: String
    let action: () -> Void
    let icon: () -> AnyView

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack {
                    Circle().fill(Color.clear)
                    icon()
                }
                .frame(width: 48, height: 48)
                .glassEffect(.regular.tint(discTint).interactive(), in: .circle)
                // Glass adapts to what is behind it, so over a dark scene the
                // discs faded almost to nothing (seen in the first simulator
                // shots). Real VI's discs are a CONSTANT dark scrim, visible
                // on any subject — this base guarantees that under the glass.
                .background(Circle().fill(Color.black.opacity(0.30)))
                Text(label)
                    .font(.system(size: 15))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.7), radius: 3, x: 0, y: 1)
            }
        }
        .buttonStyle(PressScaleStyle())
        // center the DISC (not disc+label) against the shutter, like the
        // real bar where labels hang below the row axis
        .alignmentGuide(VerticalAlignment.center) { _ in 24 }
    }
}

struct ShutterButton: View {
    let action: () -> Void
    @State private var hueAngle: Double = 0

    var body: some View {
        Button(action: action) {
            ZStack {
                // the ring: colored light leaking from behind the core's edge —
                // peak brightness AT the rim, gone within ~8 pt; one hue at a
                // time, drifting (owner rule; Apple's own ring shifts over time)
                Circle()
                    .fill(RadialGradient(
                        gradient: Gradient(stops: [
                            .init(color: .clear, location: 0.70),
                            .init(color: Color(hue: 0.628, saturation: 0.50, brightness: 0.96).opacity(0.55), location: 0.79),
                            .init(color: Color(hue: 0.628, saturation: 0.50, brightness: 0.96).opacity(0.18), location: 0.90),
                            .init(color: .clear, location: 1.0)
                        ]),
                        center: .center, startRadius: 0, endRadius: 43))
                    .frame(width: 86, height: 86)
                    .blur(radius: 2)
                    .hueRotation(.degrees(hueAngle))
                // flat pale core with a soft top-left light
                Circle()
                    .fill(RadialGradient(
                        gradient: Gradient(colors: [
                            Color(red: 244.0/255.0, green: 242.0/255.0, blue: 239.0/255.0),
                            Color(red: 218.0/255.0, green: 215.0/255.0, blue: 211.0/255.0)
                        ]),
                        center: UnitPoint(x: 0.35, y: 0.28), startRadius: 0, endRadius: 46))
                    .frame(width: 66, height: 66)
                    .shadow(color: .black.opacity(0.25), radius: 3, x: 0, y: 1)
            }
            .frame(width: 78, height: 78)
        }
        .buttonStyle(PressScaleStyle(scale: 0.95))
        .onAppear {
            guard !UIAccessibility.isReduceMotionEnabled else { return }
            withAnimation(.linear(duration: 10).repeatForever(autoreverses: false)) {
                hueAngle = 360
            }
        }
    }
}

// The centre control has two faces. Frame analysis of the real recording
// (2026-07-16) found a THIRD bar mode the old spec missed: with the photo
// frozen and no question asked, VI shows Ask / ✕ / Search — same side discs,
// the shutter replaced by a dark ✕ disc (~72 pt, between the 48 pt discs and
// the 78 pt shutter in size).
enum BarCentre { case shutter, close }

struct CloseDisc: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.35), radius: 2, x: 0, y: 1)
                .frame(width: 72, height: 72)
                .glassEffect(.regular.tint(discTint).interactive(), in: .circle)
                .background(Circle().fill(Color.black.opacity(0.30)))
        }
        .buttonStyle(PressScaleStyle(scale: 0.95))
    }
}

struct BottomBar: View {
    var centre: BarCentre = .shutter
    let onAsk: () -> Void
    let onCentre: () -> Void
    let onSearch: () -> Void

    var body: some View {
        // ONE container for the whole bar: Liquid Glass cannot sample other
        // glass, so discs in separate containers render inconsistently
        // (WWDC25 session 323 / "Applying Liquid Glass to custom views").
        GlassEffectContainer(spacing: 20) {
            HStack(alignment: .center) {
                SideButton(label: "Ask", action: onAsk) {
                    AnyView(
                        Image(systemName: "text.bubble.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.4), radius: 2, x: 0, y: 1)
                    )
                }
                Spacer()
                if centre == .close {
                    CloseDisc(action: onCentre)
                } else {
                    ShutterButton(action: onCentre)
                }
                Spacer()
                SideButton(label: "Search", action: onSearch) {
                    AnyView(
                        ZStack(alignment: .bottomTrailing) {
                            Image(systemName: "photo.fill")
                                .font(.system(size: 18))
                                .foregroundStyle(.white)
                                .offset(x: -2, y: -2)
                            Image(systemName: "magnifyingglass.circle.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(.white)
                                .offset(x: 4, y: 4)
                        }
                        .shadow(color: .black.opacity(0.4), radius: 2, x: 0, y: 1)
                    )
                }
            }
        }
        .padding(.horizontal, 59)   // puts the disc centres at x 83 / 195 / 308
        .padding(.top, 26)
        .padding(.bottom, 24)
    }
}
