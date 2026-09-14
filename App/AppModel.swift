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

    // Where captured frames are currently being streamed (if casting).
    private var streamingTarget: Peer?
    // Ignore open/close gestures until this time, right after a snap, so the
    // fist that naturally forms as you finish snapping doesn't arm a cast.
    private var snapSuppressUntil = Date.distantPast

    // MARK: Snap gating
    // Simple rule: a hand must be VISIBLE in the camera when the click is
    // heard. No motion analysis — just "is a real hand on screen right now".
    private var lastHandSeen = Date.distantPast
    private var lastSnapFired = Date.distantPast
    private let handVisibleWindow: TimeInterval = 0.5
    private let snapCooldown: TimeInterval = 1.0

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

    /// A page grabbed by the fist gesture, waiting to be dropped on another
    /// device. When set, arming hands this over instead of streaming pixels.
    private var pendingHandoff: BrowserLink.Page?

    /// Important messages (why a handoff failed, where a screenshot went) must
    /// survive the routine status refresh that follows every effect, otherwise
    /// they are overwritten before they can be read.
    private var statusHoldUntil = Date.distantPast

    func start() {
        transport.delegate = self
        transport.start()

        handTracker.onHands = { [weak self] hands, time in
            guard let self else { return }
            let raw = hands.first.map { self.classifier.classify($0) } ?? .none
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

        updateStatus()
    }

    // MARK: Gesture pipeline

    /// A detection only counts as a real hand if it's confident, has most of
    /// its 21 joints, and is big enough in frame — this filters out the
    /// low-quality phantom detections that were letting plain sounds through.
    private func isRealHand(_ hand: HandLandmarks?) -> Bool {
        guard let hand else { return false }
        guard hand.confidence >= 0.75 else { return false }
        guard hand.points.count >= 15 else { return false }
        guard let span = hand.palmSpan, span >= 0.04 else { return false }
        return true
    }

    private func handleFrame(_ hands: [HandLandmarks], raw: HandGesture, at time: TimeInterval) {
        // Is a real hand on camera right now?
        let visible = isRealHand(hands.first)
        if visible { lastHandSeen = Date() }
        if handDetected != visible { handDetected = visible }

        // Briefly after a snap, ignore open/close so the fist that forms as you
        // finish snapping doesn't arm a cast.
        if Date() < snapSuppressUntil {
            debouncer.reset()
            return
        }
        if let confirmed = debouncer.update(raw, at: time) {
            currentGesture = confirmed
            if confirmed == .peace {
                fireScreenshot()
                return
            }
            apply(coordinator.reduce(.localGesture(confirmed)))
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

    /// The V sign was held: take a screenshot.
    private func fireScreenshot() {
        let now = Date()
        guard now.timeIntervalSince(lastSnapFired) > snapCooldown else { return }
        lastSnapFired = now
        // Ignore open/close for 2s so hands returning to rest can't arm a cast.
        snapSuppressUntil = now.addingTimeInterval(2.0)
        debouncer.reset()
        currentGesture = .peace
        apply(coordinator.reduce(.localGesture(.peace)))
        NSSound(named: "Tink")?.play() // audible confirmation
    }

    // MARK: Effect execution

    private func apply(_ effects: [SessionEffect]) {
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
                pendingHandoff = page
                BrowserLink.closeFrontmostTab()
                castTarget = "\(page.browserName) — \(page.title)"
                setStatus("Grabbed “\(page.title)” — open your hand at another device to drop it")
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
                BrowserLink.open(page.url)
                setStatus("Put “\(page.title)” back")
                pendingHandoff = nil
            }
            screenSource.stopCapture()
        case .advertiseSourceAvailable:
            broadcast(.sourceAvailable)
        case .withdrawSourceAvailable:
            broadcast(.sourceWithdrawn)
        case .requestCastFromPeer(let peer):
            transport.send(.requestCast, to: peer)
        case .startStreaming(let peer):
            if let page = pendingHandoff {
                transport.send(.handoff, payload: page.url.absoluteString, to: peer)
                setStatus("Handed “\(page.title)” to \(peer.displayName)")
                pendingHandoff = nil
                streamingTarget = nil
                return
            }
            streamingTarget = peer
        case .stopStreaming:
            streamingTarget = nil
        case .showRemoteScreen:
            receivedImage = nil // frames will populate it
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
            self.peers = peers
            // Keep newly-joined peers informed if we are currently a source.
            if case .armedSource = self.state { self.broadcast(.sourceAvailable) }
            self.updateStatus()
        }
    }

    nonisolated func transport(_ transport: PeerTransport, didReceive message: ControlMessage, payload: String?, from peer: Peer) {
        Task { @MainActor in
            // A handed-over page opens natively here; there is no session state
            // to advance, the thing has simply arrived.
            if message == .handoff {
                guard let payload, let url = URL(string: payload) else { return }
                BrowserLink.open(url)
                self.setStatus("📬 Opened a page from \(peer.displayName)")
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
