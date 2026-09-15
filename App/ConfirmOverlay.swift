import AppKit

/// Asks, over whatever app you are actually looking at, before handing over
/// something that would hurt to lose.
///
/// Two deliberate choices:
///
/// * **It is not part of the app's window.** When you make a fist you are in
///   your browser, not in QuackCast, so a prompt inside the app window would
///   be asked where nobody is looking — the same mistake the glow originally
///   made. This is a floating panel above every other app.
/// * **Doing nothing means "no".** It times out into a cancel. If the fist
///   was misread, the most likely thing for the user to do is nothing at all,
///   and that must be the outcome that keeps them in their meeting.
final class ConfirmOverlay {

    /// A borderless panel still has to be allowed to take the keyboard, or
    /// Return and Escape do nothing.
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    private var panel: Panel?
    private var countdown: Timer?
    private var onDecision: ((Bool) -> Void)?
    private var remaining = 0
    private var countdownLabel: NSTextField?

    /// Seconds before the prompt gives up and cancels itself.
    private let timeout = 12

    /// - Parameters:
    ///   - title: the question, e.g. "Hand over your Google Meet?"
    ///   - detail: the consequence, spelled out.
    ///   - confirmTitle: label for the affirmative button.
    ///   - decision: true to proceed, false to leave everything alone.
    func ask(title: String,
             detail: String,
             confirmTitle: String = "Hand it over",
             decision: @escaping (Bool) -> Void) {
        dismiss(answering: nil)
        onDecision = decision
        remaining = timeout

        let width: CGFloat = 460
        let height: CGFloat = 196
        let panel = Panel(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                          styleMask: [.borderless, .nonactivatingPanel],
                          backing: .buffered,
                          defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .screenSaver                  // above normal and full-screen apps
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary,
                                    .ignoresCycle]
        panel.hidesOnDeactivate = false

        let card = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        card.material = .hudWindow
        card.state = .active
        card.blendingMode = .behindWindow
        card.wantsLayer = true
        card.layer?.cornerRadius = 16
        card.layer?.borderWidth = 1
        card.layer?.borderColor = NSColor(calibratedRed: 0.96, green: 0.65,
                                          blue: 0.14, alpha: 0.55).cgColor
        card.layer?.masksToBounds = true

        let heading = label(title, size: 16, weight: .semibold, colour: .labelColor)
        heading.frame = NSRect(x: 24, y: height - 58, width: width - 48, height: 24)
        card.addSubview(heading)

        let body = label(detail, size: 12.5, weight: .regular, colour: .secondaryLabelColor)
        body.frame = NSRect(x: 24, y: height - 108, width: width - 48, height: 44)
        body.maximumNumberOfLines = 3
        card.addSubview(body)

        let stay = NSButton(title: "Stay here", target: self, action: #selector(cancelTapped))
        stay.bezelStyle = .rounded
        stay.keyEquivalent = "\u{1b}"                       // Escape
        stay.frame = NSRect(x: width - 300, y: 22, width: 130, height: 32)
        card.addSubview(stay)

        let go = NSButton(title: confirmTitle, target: self, action: #selector(confirmTapped))
        go.bezelStyle = .rounded
        go.keyEquivalent = "\r"                             // Return
        go.frame = NSRect(x: width - 160, y: 22, width: 136, height: 32)
        card.addSubview(go)

        let ticker = label("", size: 11, weight: .regular, colour: .tertiaryLabelColor)
        ticker.frame = NSRect(x: 24, y: 28, width: 160, height: 20)
        card.addSubview(ticker)
        countdownLabel = ticker

        panel.contentView = card
        if let screen = NSScreen.main {
            let frame = screen.frame
            panel.setFrameOrigin(NSPoint(x: frame.midX - width / 2,
                                         y: frame.midY - height / 2))
        }
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel

        tick()
        countdown = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    /// True while a question is on screen, so gestures can be ignored rather
    /// than stacking a second prompt behind the first.
    var isAsking: Bool { panel != nil }

    func cancel() { dismiss(answering: false) }

    // MARK: - Internals

    private func tick() {
        countdownLabel?.stringValue = remaining > 0
            ? "Staying put in \(remaining)s"
            : ""
        if remaining <= 0 {
            // Silence means no. Someone who did not mean to make that gesture
            // is unlikely to reach for a button.
            dismiss(answering: false)
            return
        }
        remaining -= 1
    }

    @objc private func confirmTapped() { dismiss(answering: true) }
    @objc private func cancelTapped() { dismiss(answering: false) }

    private func dismiss(answering answer: Bool?) {
        countdown?.invalidate()
        countdown = nil
        countdownLabel = nil
        panel?.orderOut(nil)
        panel = nil
        let callback = onDecision
        onDecision = nil
        if let answer { callback?(answer) }
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight,
                       colour: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = colour
        field.lineBreakMode = .byWordWrapping
        field.cell?.wraps = true
        return field
    }
}
