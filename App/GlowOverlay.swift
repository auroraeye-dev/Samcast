import AppKit

/// Shows the handoff glow across the whole screen, above every other app.
///
/// When you grab a page you are looking at your browser, not at Samcast, so
/// an animation inside the app window is never seen. This is a borderless,
/// transparent, click-through window floating above everything.
///
/// It is drawn with CoreAnimation rather than SwiftUI on purpose: a SwiftUI
/// view hosted in a freshly shown borderless window is unreliable about
/// running an entrance animation (state animated in the same pass the view
/// appears gets collapsed to its final value), whereas explicit CAAnimations
/// always run.
@MainActor
final class GlowOverlay {
    private var window: NSWindow?
    private var hideTask: Task<Void, Never>?

    private let duration: CFTimeInterval = 2.2
    private let stagger: CFTimeInterval = 0.16
    private let ringCount = 5

    /// - Parameter message: shown with the glow. The app window is usually
    ///   behind whatever you are working in, so without this the user has no
    ///   idea whether a page was grabbed, delivered or put back.
    func flash(_ direction: GlowDirection, message: String? = nil) {
        guard let screen = NSScreen.main else { return }
        hideTask?.cancel()

        let overlay = window ?? makeWindow()
        window = overlay
        overlay.setFrame(screen.frame, display: false)
        overlay.orderFrontRegardless()

        guard let host = overlay.contentView else { return }
        host.layer?.sublayers?.forEach { $0.removeFromSuperlayer() }
        addGlowLayers(to: host, direction: direction)
        if let message { addLabel(message, to: host, direction: direction) }

        hideTask = Task { @MainActor [weak overlay] in
            let total = duration + stagger * Double(ringCount) + 0.2
            try? await Task.sleep(nanoseconds: UInt64(total * 1_000_000_000))
            guard !Task.isCancelled else { return }
            overlay?.orderOut(nil)
        }
    }

    // MARK: - Drawing

    private func addGlowLayers(to view: NSView, direction: GlowDirection) {
        let bounds = view.bounds
        guard bounds.width > 1, bounds.height > 1 else { return }
        let radius = min(bounds.width, bounds.height) * 0.26
        let centre = CGPoint(x: bounds.midX, y: bounds.midY)
        let colour = tint(for: direction).cgColor

        // Soft central bloom.
        let bloom = CALayer()
        bloom.frame = CGRect(x: centre.x - radius, y: centre.y - radius,
                             width: radius * 2, height: radius * 2)
        bloom.cornerRadius = radius
        bloom.backgroundColor = colour.copy(alpha: 0.22)
        bloom.shadowColor = colour
        bloom.shadowOpacity = 0.9
        bloom.shadowRadius = radius * 0.7
        bloom.shadowOffset = .zero
        bloom.opacity = 0
        view.layer?.addSublayer(bloom)
        animate(bloom, direction: direction, delay: 0)

        // Concentric rings, each setting off after the last so it ripples.
        for index in 0..<ringCount {
            let ring = CAShapeLayer()
            let box = CGRect(x: 0, y: 0, width: radius * 2, height: radius * 2)
            ring.path = CGPath(ellipseIn: box, transform: nil)
            ring.frame = CGRect(x: centre.x - radius, y: centre.y - radius,
                                width: radius * 2, height: radius * 2)
            ring.fillColor = NSColor.clear.cgColor
            ring.strokeColor = colour
            ring.lineWidth = 3.0 - CGFloat(index) * 0.45
            ring.shadowColor = colour
            ring.shadowOpacity = 0.8
            ring.shadowRadius = 12
            ring.shadowOffset = .zero
            ring.opacity = 0
            view.layer?.addSublayer(ring)
            animate(ring, direction: direction, delay: Double(index) * stagger)
        }
    }

    /// A short caption under the glow saying what just happened.
    private func addLabel(_ text: String, to view: NSView, direction: GlowDirection) {
        let bounds = view.bounds
        let radius = min(bounds.width, bounds.height) * 0.26

        let label = CATextLayer()
        label.string = text
        label.font = NSFont.systemFont(ofSize: 22, weight: .semibold)
        label.fontSize = 22
        label.alignmentMode = .center
        label.truncationMode = .middle
        label.foregroundColor = NSColor.white.cgColor
        label.shadowColor = NSColor.black.cgColor
        label.shadowOpacity = 0.85
        label.shadowRadius = 8
        label.shadowOffset = .zero
        label.contentsScale = view.window?.backingScaleFactor ?? 2
        let width = min(bounds.width * 0.7, 760)
        label.frame = CGRect(x: bounds.midX - width / 2,
                             y: bounds.midY - radius - 64,
                             width: width,
                             height: 34)
        label.opacity = 0
        view.layer?.addSublayer(label)

        // Lingers a little longer than the rings so it stays readable.
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0.0, 1.0, 1.0, 0.0]
        fade.keyTimes = [0.0, 0.08, 0.72, 1.0]
        fade.duration = duration + 0.5
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        fade.fillMode = .backwards
        label.add(fade, forKey: "caption")
    }

    private func animate(_ layer: CALayer, direction: GlowDirection, delay: CFTimeInterval) {
        let from: CGFloat = direction == .outward ? 0.15 : 2.1
        let to: CGFloat = direction == .outward ? 2.1 : 0.18

        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = from
        scale.toValue = to

        // Quick to appear so the gesture is acknowledged at once, then a long
        // gentle fade so it never cuts off abruptly.
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0.0, 0.95, 0.85, 0.0]
        fade.keyTimes = [0.0, 0.10, 0.45, 1.0]

        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = duration
        group.beginTime = CACurrentMediaTime() + delay
        group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        group.fillMode = .backwards
        layer.add(group, forKey: "glow")
    }

    /// Warm for leaving, cool for arriving.
    private func tint(for direction: GlowDirection) -> NSColor {
        switch direction {
        case .outward: return NSColor(calibratedRed: 1.0, green: 0.72, blue: 0.35, alpha: 1)
        case .inward:  return NSColor(calibratedRed: 0.45, green: 0.85, blue: 1.0, alpha: 1)
        }
    }

    private func makeWindow() -> NSWindow {
        let overlay = NSWindow(contentRect: .zero,
                               styleMask: [.borderless],
                               backing: .buffered,
                               defer: false)
        overlay.isOpaque = false
        overlay.backgroundColor = .clear
        overlay.hasShadow = false
        overlay.level = .screenSaver          // above normal and full-screen apps
        overlay.ignoresMouseEvents = true     // never intercept a click
        overlay.isReleasedWhenClosed = false
        overlay.collectionBehavior = [.canJoinAllSpaces, .stationary,
                                      .ignoresCycle, .fullScreenAuxiliary]

        let content = NSView()
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.clear.cgColor
        content.autoresizingMask = [.width, .height]
        overlay.contentView = content
        return overlay
    }
}
