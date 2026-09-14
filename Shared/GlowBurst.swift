import SwiftUI

/// Which way the moment should feel: something leaving this device, or
/// arriving on it.
enum GlowDirection {
    case outward   // handed away — rings bloom out and fade
    case inward    // arrived here — rings rush in and settle

    /// Warm for leaving, cool for arriving, so the two read differently at a
    /// glance without needing to read any text.
    var tint: Color {
        switch self {
        case .outward: return Color(red: 1.0, green: 0.72, blue: 0.35)
        case .inward:  return Color(red: 0.45, green: 0.85, blue: 1.0)
        }
    }
}

/// A soft concentric glow that blooms from the centre of the screen when a
/// page or window changes hands. Deliberately brief and low contrast: it
/// should register as "that worked" in peripheral vision, not demand
/// attention or obscure what is underneath.
///
/// Driven by a counter so the same event can replay: bump `trigger` to play.
struct GlowBurst: View {
    let trigger: Int
    let direction: GlowDirection

    @State private var ringScale: CGFloat = 0.2
    @State private var bloomScale: CGFloat = 0.4
    @State private var opacity: Double = 0

    private let duration: Double = 1.1

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height) * 0.55
            ZStack {
                // Soft core bloom.
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [direction.tint.opacity(0.55), direction.tint.opacity(0.0)],
                            center: .center,
                            startRadius: 0,
                            endRadius: size / 2
                        )
                    )
                    .frame(width: size, height: size)
                    .scaleEffect(bloomScale)
                    .blur(radius: 18)
                    .opacity(opacity)

                // Concentric rings, each slightly behind the last so it ripples.
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .strokeBorder(
                            LinearGradient(
                                colors: [direction.tint.opacity(0.9), direction.tint.opacity(0.15)],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 2.5 - Double(index) * 0.6
                        )
                        .frame(width: size, height: size)
                        .scaleEffect(ringScale)
                        .opacity(opacity)
                        .blur(radius: Double(index) * 0.8)
                        .animation(.easeOut(duration: duration).delay(Double(index) * 0.13),
                                   value: ringScale)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .allowsHitTesting(false)   // purely decorative; never eat a click
        .onChange(of: trigger) { _ in play() }
    }

    private func play() {
        // Snap to the start of the gesture without animating, then animate out.
        ringScale = direction == .outward ? 0.18 : 1.75
        bloomScale = direction == .outward ? 0.35 : 1.4
        opacity = 0.95

        withAnimation(.easeOut(duration: duration)) {
            ringScale = direction == .outward ? 1.8 : 0.22
            bloomScale = direction == .outward ? 1.5 : 0.3
            opacity = 0
        }
    }
}
