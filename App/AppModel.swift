import Foundation
import SwiftUI
import CoreImage
import CoreVideo
import AppKit
import QuackCastCore
import QuackCastPlatform

/// The app-level integration layer: it owns the platform adapters and the
/// portable `SessionCoordinator`, feeds gestures + peer messages into the
/// coordinator, and carries out the `SessionEffect`s it returns by calling the
/// real frameworks. All published state is read by SwiftUI.
@MainActor
final class AppModel: ObservableObject {
    // Portable brain.
    private var coordinator = SessionCoordinator()
    private let classifier = GestureClassifier()
    private var debouncer = GestureDebouncer(holdDuration: 0.3)

    // Platform adapters.
    let handTracker = VisionHandTracker()
    private let transport = MultipeerTransport(kind: .mac)
    private let screenSource = ScreenCaptureKitSource()
    private let ciContext = CIContext()

    /// Tracks macOS privacy permissions so the UI can guide setup.
    let permissions = Permissions()

    private let trust = TrustStore()
    /// Plays the glow over the whole screen, since the app window is usually
    /// behind whatever you are grabbing from.
    private let glowOverlay = GlowOverlay()
    /// This device's persistent QuackCast name — how other devices see it.
    let identity = DeviceIdentity.loadOrCreate(kind: .mac)

    // Where captured frames are currently being streamed (if casting).
    private var streamingTarget: Peer?
    /// Ignore open/close gestures until this time, just after a screenshot, so
    /// hands returning to rest can't accidentally arm a cast.
    private var gestureSuppressUntil = Date.distantPast
    /// When the current grab was made. A second fist cancels a grab, but hand
    /// tracking flickers closed→none→closed, and that re-fire would cancel the
    /// grab a moment after making it — putting the page straight back on this
    /// machine. Cancelling is therefore only allowed after a deliberate pause.
    private var armedAt = Date.distantPast
    private let cancelGuard: TimeInterval = 5

    // MARK: Gesture timing
    /// When a hand was last seen, used to keep the indicator steady across
    /// dropped tracking frames.
    private var lastHandSeen = Date.distantPast
    /// Screenshots are rate limited so one held gesture fires once.
    private var lastScreenshotAt = Date.distantPast
    private let screenshotCooldown: TimeInterval = 1.0

    // MARK: Published UI state
    @Published private(set) var state: SessionState = .idle
    @Published private(set) var peers: [Peer] = []
    @Published private(set) var currentGesture: HandGesture = .none
    /// Live: is the camera seeing a real hand right now? Shown in the UI so the
    /// gating is visible rather than a black box.
    @Published private(set) var handDetected: Bool = false
    /// Live readout of which fingers the camera sees extended, so gesture
    /// recognition is observable instead of a black box.
    @Published private(set) var fingerReadout: String = "—" 
    @Published private(set) var receivedImage: NSImage?
    @Published private(set) var lastScreenshot: URL?
    @Published private(set) var statusLine: String = "Starting…"
    /// What is currently being cast, e.g. "Safari — Example Page".
    @Published private(set) var castTarget: String = ""
    /// Devices already accepted from; their offers are taken automatically.
    @Published private(set) var trustedNames: [String] = []
    /// Bumped to play the glow; direction says whether something left or
    /// arrived, so the animation reads correctly without any text.
    @Published private(set) var glowTrigger = 0
    @Published private(set) var glowDirection: GlowDirection = .outward

    /// A page grabbed by the fist gesture, waiting to be dropped on another
    /// device. When set, arming hands this over instead of streaming pixels.
    private var pendingHandoff: BrowserLink.Page?

    /// Important messages (why a handoff failed, where a screenshot went) must
    /// survive the routine status refresh that follows every effect, otherwise
    /// they are overwritten before they can be read.
    private var statusHoldUntil = Date.distantPast

    func start() {
        QCLog.write("=== QuackCast started as \(identity.name) ===")
        transport.delegate = self
        transport.start()

        handTracker.onHands = { [weak self] hands, time in
            guard let self else { return }
            // A low-quality detection must not drive a gesture: at launch a
            // phantom "fist" armed a handoff with no input from the user.
            let hand = hands.first
            let raw = self.isRealHand(hand) ? (hand.map { self.classifier.classify($0) } ?? .none) : .none
            let fingers = hands.first.map { self.classifier.extendedFingers($0) }
            Task { @MainActor in
                self.updateFingerReadout(fingers)
                self.handleFrame(hands, raw: raw, at: time)
            }
        }
        do { try handTracker.start() } catch { statusLine = "Camera error: \(error)" }


        screenSource.onCaptureTarget = { [weak self] label in
            self?.castTarget = label
        }

        screenSource.onCaptureError = { [weak self] message in
            guard let self else { return }
            self.setStatus(message, hold: 12)
            self.permissions.screenRecordingFailed = true
            self.permissions.refresh()
        }

        screenSource.onFrame = { [weak self] frame, _ in
            guard let self else { return }
            // `frame` is an opaque CVPixelBuffer (a CoreFoundation type, so a
            // plain `as?` always "succeeds" — check the CF type id instead).
            guard CFGetTypeID(frame as CFTypeRef) == CVPixelBufferGetTypeID() else { return }
            self.forwardFrame(frame as! CVPixelBuffer)
        }

        trustedNames = Array(trust.trusted.values).sorted()
        updateStatus()
    }

    // MARK: Gesture pipeline

    /// A detection only counts as a real hand if it's confident, has most of
    /// its 21 joints, and is big enough in frame — this filters out the
    /// low-quality phantom detections that were letting plain sounds through.
    /// Forgiving on purpose — hand tracking drops frames, and treating every
    /// miss as "no hand" makes the indicator flicker and resets gesture timing.
    private func isRealHand(_ hand: HandLandmarks?) -> Bool {
        guard let hand else { return false }
        guard hand.confidence >= 0.5 else { return false }
        guard hand.points.count >= 10 else { return false }
        guard let span = hand.palmSpan, span >= 0.03 else { return false }
        return true
    }

    private func handleFrame(_ hands: [HandLandmarks], raw: HandGesture, at time: TimeInterval) {
        // Is a real hand on camera right now?
        if isRealHand(hands.first) { lastHandSeen = Date() }
        // Bridge dropped frames so the badge is steady rather than strobing.
        let present = Date().timeIntervalSince(lastHandSeen) < 0.5
        if handDetected != present { handDetected = present }

        // Briefly after a screenshot, ignore open/close so a hand returning to
        // rest can't arm a cast.
        if Date() < gestureSuppressUntil {
            debouncer.reset()
            return
        }
        if let confirmed = debouncer.update(raw, at: time) {
            QCLog.write("gesture \(confirmed.rawValue) | state=\(coordinator.state) | pending=\(pendingHandoff?.url.absoluteString ?? "none")")
            currentGesture = confirmed

            // Once a page is grabbed and waiting to be dropped, this camera
            // stops deciding anything. You are walking to another device and
            // gesturing at *that* one; hands this camera happens to catch on
            // the way were cancelling the grab before it could be delivered.
            if pendingHandoff != nil {
                QCLog.write("ignored \(confirmed.rawValue): holding a grabbed page")
                return
            }
            if confirmed == .peace {
                fireScreenshot()
                return
            }
            // Don't let a flickering fist cancel the grab it just made.
            if confirmed == .closedHand, coordinator.state == .armedSource,
               Date().timeIntervalSince(armedAt) < cancelGuard {
                QCLog.write("ignored repeat fist within cancel guard")
                return
            }
            let wasIdle = coordinator.state == .idle
            apply(coordinator.reduce(.localGesture(confirmed)))
            if wasIdle, coordinator.state == .armedSource { armedAt = Date() }
        }
    }

    /// Readable summary of the extended fingers, e.g. "index+middle (2)".
    private func updateFingerReadout(_ fingers: GestureClassifier.ExtendedFingers?) {
        guard let f = fingers else {
            if fingerReadout != "—" { fingerReadout = "—" }
            return
        }
        var names: [String] = []
        if f.index { names.append("index") }
        if f.middle { names.append("middle") }
        if f.ring { names.append("ring") }
        if f.little { names.append("little") }
        let text = names.isEmpty ? "none (0)" : "\(names.joined(separator: "+")) (\(f.count))"
        if fingerReadout != text { fingerReadout = text }
    }

    /// The peace sign was held: take a screenshot.
    private func fireScreenshot() {
        let now = Date()
        guard now.timeIntervalSince(lastScreenshotAt) > screenshotCooldown else { return }
        lastScreenshotAt = now
        // Ignore open/close for 2s so hands returning to rest can't arm a cast.
        gestureSuppressUntil = now.addingTimeInterval(2.0)
        debouncer.reset()
        currentGesture = .peace
        apply(coordinator.reduce(.localGesture(.peace)))
        NSSound(named: "Tink")?.play() // audible confirmation
    }

    /// Restore a grabbed page if it is never dropped anywhere.
    private func scheduleHandoffRecovery(for page: BrowserLink.Page) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000_000)
            guard let self, let pending = self.pendingHandoff,
                  pending.url == page.url else { return }
            QCLog.write("PUT BACK (timeout) \(pending.url.absoluteString)")
            BrowserLink.open(pending.url)
            self.pendingHandoff = nil
            // Leave the armed state too, so a later request doesn't find an
            // armed source with nothing behind it.
            if case .armedSource = self.coordinator.state {
                self.apply(self.coordinator.reduce(.localGesture(.closedHand)))
            }
            self.setStatus("Nobody took “\(pending.title)” — put it back")
            self.pulseGlow(.inward, message: "Put back — nobody took it")
        }
    }

    // MARK: Effect execution

    private func apply(_ effects: [SessionEffect]) {
        if !effects.isEmpty {
            QCLog.write("effects \(effects) | state before=\(coordinator.state)")
        }
        for effect in effects { perform(effect) }
        state = coordinator.state
        updateStatus()
    }

    private func perform(_ effect: SessionEffect) {
        switch effect {
        case .startScreenCapture:
            // Prefer handing the *content* over to streaming a picture of it.
            // A page travels as a URL: instant, pixel-perfect, and it opens in
            // the other person's own browser without touching their tabs.
            do {
                let page = try BrowserLink.frontmostPage()
                QCLog.write("GRABBED \(page.url.absoluteString)")
                pendingHandoff = page
                BrowserLink.closeFrontmostTab()
                // If no device takes it, put the page back rather than leaving
                // the user with a closed tab and nothing to show for it.
                scheduleHandoffRecovery(for: page)
                castTarget = "\(page.browserName) — \(page.title)"
                setStatus("Grabbed “\(page.title)” — now open your hand at the device you want it on")
                pulseGlow(.outward, message: "Grabbed — open your hand at another device")
                return
            } catch {
                // Say why the page couldn't be grabbed instead of silently
                // streaming, which looks like the feature is broken.
                setStatus("Streaming the window — \(error.localizedDescription)", hold: 12)
            }
            pendingHandoff = nil
            do {
                try screenSource.startCapture()
            } catch {
                statusLine = "Enable Screen Recording for QuackCast in System Settings ▸ Privacy & Security, then relaunch."
            }
        case .stopScreenCapture:
            // Cancelled before dropping it — put the page back where it was.
            if let page = pendingHandoff {
                QCLog.write("PUT BACK (cancelled) \(page.url.absoluteString)")
                BrowserLink.open(page.url)
                setStatus("Put “\(page.title)” back")
                pulseGlow(.inward, message: "Put back — nothing took it")
                pendingHandoff = nil
            }
            screenSource.stopCapture()
        case .advertiseSourceAvailable:
            broadcast(.sourceAvailable)
        case .withdrawSourceAvailable:
            broadcast(.sourceWithdrawn)
        case .requestCastFromPeer(let peer):
            trust.trust(peer.id, name: peer.displayName)
            trustedNames = Array(trust.trusted.values).sorted()
            transport.send(.requestCast, to: peer)
        case .startStreaming(let peer):
            if let page = pendingHandoff {
                QCLog.write("-> handoff \(page.url.absoluteString) to \(peer.displayName)")
                transport.send(.handoff, payload: page.url.absoluteString, to: peer)
                setStatus("✅ Handed “\(page.title)” to \(peer.displayName)")
                pulseGlow(.outward, message: "Sent to \(peer.displayName)")
                pendingHandoff = nil
                streamingTarget = nil
                return
            }
            // No held page: stream instead. Capture may not be running (the
            // handoff path skips it), so make sure it is started.
            streamingTarget = peer
            do {
                try screenSource.startCapture()
                setStatus("Streaming to \(peer.displayName)")
            } catch {
                setStatus("Couldn't start streaming: \(error.localizedDescription)")
            }
        case .stopStreaming:
            streamingTarget = nil
        case .showRemoteScreen:
            receivedImage = nil // frames will populate it
            pulseGlow(.inward)
        case .hideRemoteScreen:
            receivedImage = nil
        case .notifyEndedCast(let peer):
            transport.send(.endCast, to: peer)
        case .takeScreenshot:
            Task { [weak self] in
                guard let self else { return }
                do {
                    let url = try await self.screenSource.captureStill()
                    self.lastScreenshot = url
                    self.permissions.screenRecordingFailed = false
                    self.setStatus("📸 Screenshot saved to Desktop: \(url.lastPathComponent)")
                } catch {
                    // Show the real underlying error so failures are diagnosable
                    // rather than always blamed on permissions.
                    self.statusLine = "✌️ Peace sign seen — screenshot failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private func broadcast(_ message: ControlMessage) {
        for peer in transport.connectedPeers { transport.send(message, to: peer) }
    }

    // MARK: Streaming

    private func forwardFrame(_ pixelBuffer: CVPixelBuffer) {
        guard let target = streamingTarget else { return }
        guard let data = jpeg(from: pixelBuffer) else { return }
        transport.sendFrameData(data, to: target)
    }

    private func jpeg(from pixelBuffer: CVPixelBuffer, quality: CGFloat = 0.75) -> Data? {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        return ciContext.jpegRepresentation(of: image, colorSpace: colorSpace,
                                             options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: quality])
    }

    /// Put a grabbed page back, from the UI. Gestures deliberately cannot do
    /// this while a page is held, so there has to be an explicit way.
    func cancelGrab() {
        guard pendingHandoff != nil else { return }
        apply(coordinator.reduce(.localGesture(.closedHand)))
    }

    /// True while a page is grabbed and waiting for a device to take it.
    var isHoldingPage: Bool { pendingHandoff != nil }

    /// Play the glow for something leaving or arriving.
    private func pulseGlow(_ direction: GlowDirection, message: String? = nil) {
        glowDirection = direction
        glowTrigger &+= 1
        glowOverlay.flash(direction, message: message)
    }

    /// Show a message and protect it from being overwritten for a moment.
    private func setStatus(_ text: String, hold: TimeInterval = 6) {
        statusLine = text
        statusHoldUntil = Date().addingTimeInterval(hold)
    }

    private func updateStatus() {
        guard Date() >= statusHoldUntil else { return }
        switch state {
        case .idle:
            statusLine = peers.isEmpty ? "Waiting for nearby devices…" : "Ready — close your hand to share this screen"
        case .armedSource:
            statusLine = "Screen armed — open your hand at another device to cast"
        case .casting(let p):
            statusLine = "Casting to \(p.displayName)"
        case .receiving(let p):
            statusLine = "Receiving from \(p.displayName)"
        }
    }
}

// MARK: - PeerTransportDelegate

extension AppModel: PeerTransportDelegate {
    nonisolated func transport(_ transport: PeerTransport, didUpdate peers: [Peer]) {
        Task { @MainActor in
            QCLog.write("peers now: \(peers.map(\.displayName))")
            self.peers = peers
            // Keep newly-joined peers informed if we are currently a source.
            if case .armedSource = self.state { self.broadcast(.sourceAvailable) }
            self.updateStatus()
        }
    }

    nonisolated func transport(_ transport: PeerTransport, didReceive message: ControlMessage, payload: String?, from peer: Peer) {
        Task { @MainActor in
            QCLog.write("<- \(message.rawValue) from \(peer.displayName)\(payload.map { " payload=\($0)" } ?? "")")
            // A handed-over page opens natively here; there is no session state
            // to advance, the thing has simply arrived.
            if message == .handoff {
                guard let payload, let url = URL(string: payload) else { return }
                BrowserLink.open(url)
                self.setStatus("📬 Opened a page from \(peer.displayName)")
                self.pulseGlow(.inward, message: "Received from \(peer.displayName)")
                self.apply(self.coordinator.reduce(.remoteEndedCast(peer)))
                return
            }
            let input: SessionInput
            switch message {
            case .sourceAvailable: input = .remoteSourceBecameAvailable(peer)
            case .sourceWithdrawn: input = .remoteSourceWithdrawn(peer)
            case .requestCast:     input = .remoteRequestedCast(peer)
            case .endCast:         input = .remoteEndedCast(peer)
            case .handoff:         return
            }
            self.apply(self.coordinator.reduce(input))
        }
    }

    nonisolated func transport(_ transport: PeerTransport, didReceiveFrame frame: Any, from peer: Peer) {
        guard let data = frame as? Data else { return }
        Task { @MainActor in
            if case .receiving(let source) = self.state, source == peer {
                self.receivedImage = NSImage(data: data)
            }
        }
    }
}
