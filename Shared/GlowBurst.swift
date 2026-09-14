import SwiftUI

/// Which way the moment should feel: something leaving this device, or
/// arriving on it.
enum GlowDirection {
    case outward   // handed away — rings bloom out and fade
    case inward    // arriving here — rings sweep in and settle

    /// Warm for leaving, cool for arriving, so the two read differently at a
    /// glance without needing to read any text.
    var tint: Color {
        switch self {
        case .outward: return Color(red: 1.0, green: 0.72, blue: 0.35)
        case .inward:  return Color(red: 0.45, green: 0.85, blue: 1.0)
        }
    }
}

/// A slow concentric glow that sweeps from the centre of the screen when a
/// page or window changes hands.
///
/// It runs for a couple of seconds on purpose. Partly so it can actually be
/// seen and enjoyed, and partly because it starts the moment the gesture is
/// recognised and plays *through* the network round-trip — so the wait reads
/// as part of the effect rather than as lag.
struct GlowBurst: View {
    let trigger: Int
    let direction: GlowDirection

    /// Total travel time of the rings.
    private let duration: Double = 2.2
    /// Gap between successive rings setting off.
    private let stagger: Double = 0.16
    private let ringCount = 5

    @State private var ringScale: CGFloat = 0.2
    @State private var bloomScale: CGFloat = 0.4
    @State private var haloScale: CGFloat = 0.5
    @State private var opacity: Double = 0

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height) * 0.55
            ZStack {
                // Broad, very soft halo — gives the effect presence without
                // hard edges over whatever is underneath.
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [direction.tint.opacity(0.28), .clear],
                            center: .center,
                            startRadius: 0,
                            endRadius: size * 0.9
                        )
                    )
                    .frame(width: size * 1.8, height: size * 1.8)
                    .scaleEffect(haloScale)
                    .blur(radius: 40)
                    .opacity(opacity * 0.8)

                // Core bloom.
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [direction.tint.opacity(0.6), direction.tint.opacity(0.0)],
                            center: .center,
                            startRadius: 0,
                            endRadius: size / 2
                        )
                    )
                    .frame(width: size, height: size)
                    .scaleEffect(bloomScale)
                    .blur(radius: 22)
                    .opacity(opacity)

                // Concentric rings, each setting off a little after the last
                // so the effect ripples rather than pulsing all at once.
                ForEach(0..<ringCount, id: \.self) { index in
                    Circle()
                        .strokeBorder(
                            LinearGradient(
                                colors: [direction.tint.opacity(0.95), direction.tint.opacity(0.2)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 3.0 - Double(index) * 0.45
                        )
                        .frame(width: size, height: size)
                        .scaleEffect(ringScale)
                        .opacity(opacity * (1.0 - Double(index) * 0.12))
                        .blur(radius: Double(index) * 0.9)
                        .animation(
                            .easeInOut(duration: duration).delay(Double(index) * stagger),
                            value: ringScale
                        )
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .allowsHitTesting(false)   // purely decorative; never eat a click
        .onChange(of: trigger) { _ in play() }
        // A freshly presented burst plays immediately, which is how the
        // full-screen overlay window uses it.
        .onAppear { play() }
    }

    private func play() {
        // Jump to the start of the gesture without animating.
        ringScale = direction == .outward ? 0.16 : 2.0
        bloomScale = direction == .outward ? 0.3 : 1.6
        haloScale = direction == .outward ? 0.4 : 1.5
        opacity = 0

        // Appear quickly so the gesture feels instantly acknowledged…
        withAnimation(.easeOut(duration: 0.22)) {
            opacity = 0.95
        }
        // …then travel slowly across the screen…
        withAnimation(.easeInOut(duration: duration)) {
            ringScale = direction == .outward ? 2.05 : 0.2
            bloomScale = direction == .outward ? 1.7 : 0.28
            haloScale = direction == .outward ? 1.9 : 0.45
        }
        // …and fade out over the back half, so it never cuts off abruptly.
        withAnimation(.easeIn(duration: duration * 0.55).delay(duration * 0.45)) {
            opacity = 0
        }
    }
}
