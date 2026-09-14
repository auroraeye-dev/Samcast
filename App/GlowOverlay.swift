import AppKit
import SwiftUI

/// Shows the handoff glow across the whole screen, above every other app.
///
/// The in-window animation was effectively invisible on the sending machine:
/// when you grab a page you are looking at your browser, and QuackCast is
/// behind it. A borderless, transparent, click-through window floating above
/// everything means the effect happens where you are actually looking.
@MainActor
final class GlowOverlay {
    private var window: NSWindow?
    private var hideTask: Task<Void, Never>?

    /// Slightly longer than the animation so it can finish before we hide.
    private let visibleFor: TimeInterval = 2.9

    func flash(_ direction: GlowDirection) {
        guard let screen = NSScreen.main else { return }
        hideTask?.cancel()

        let overlay = window ?? makeWindow()
        window = overlay
        // Cover the whole screen including the menu bar area.
        overlay.setFrame(screen.frame, display: false)

        // Show the window *before* installing the view, so the burst animates
        // in a window that is already on screen.
        overlay.orderFrontRegardless()

        // A fresh view each time so the animation replays from the start.
        let host = NSHostingView(rootView: GlowBurst(trigger: 1, direction: direction))
        host.frame = overlay.contentLayoutRect
        host.autoresizingMask = [.width, .height]
        overlay.contentView = host

        hideTask = Task { @MainActor [weak overlay] in
            try? await Task.sleep(nanoseconds: UInt64(visibleFor * 1_000_000_000))
            guard !Task.isCancelled else { return }
            overlay?.orderOut(nil)
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
        // Above normal windows, but it never takes focus or swallows clicks.
        overlay.level = .screenSaver
        overlay.ignoresMouseEvents = true
        overlay.isReleasedWhenClosed = false
        overlay.collectionBehavior = [.canJoinAllSpaces, .stationary,
                                      .ignoresCycle, .fullScreenAuxiliary]
        return overlay
    }
}
