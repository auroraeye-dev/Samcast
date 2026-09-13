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
    private let audioSnap = AudioSnapDetector()
    private let ciContext = CIContext()

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
    /// Diagnostic for the last sharp sound heard: its measured tone and whether
    /// it was bright enough to count as a snap. Lets the threshold be tuned.
    @Published private(set) var lastSoundInfo: String = ""
    @Published private(set) var receivedImage: NSImage?
    @Published private(set) var lastScreenshot: URL?
    @Published private(set) var statusLine: String = "Starting…"

    func start() {
        transport.delegate = self
        transport.start()

        handTracker.onHand = { [weak self] hand, time in
            guard let self else { return }
            let raw = hand.map { self.classifier.classify($0) } ?? .none
            Task { @MainActor in self.handleFrame(hand, raw: raw, at: time) }
        }
        do { try handTracker.start() } catch { statusLine = "Camera error: \(error)" }

        // Snap is detected by sound (a sharp transient), which is robust and
        // never confused with the fist cast gesture.
        audioSnap.onSnap = { [weak self] in self?.handleAudioSnap() }
        audioSnap.onSound = { [weak self] accepted, tone in
            guard let self else { return }
            self.lastSoundInfo = String(format: accepted ? "sound tone %.1f → snap" : "sound tone %.1f → too dull, ignored", tone)
        }
        try? audioSnap.start()

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

    private func handleFrame(_ hand: HandLandmarks?, raw: HandGesture, at time: TimeInterval) {
        // Is a real hand on camera right now?
        let visible = isRealHand(hand)
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
            apply(coordinator.reduce(.localGesture(confirmed)))
        }
    }

    /// A click was heard. Take the screenshot only if a hand is on camera.
    private func handleAudioSnap() {
        let now = Date()
        guard now.timeIntervalSince(lastSnapFired) > snapCooldown else { return }
        guard now.timeIntervalSince(lastHandSeen) < handVisibleWindow else {
            statusLine = "Heard a click — but no hand in view, so it was ignored."
            return
        }

        lastSnapFired = now
        // After a screenshot, ignore open/close gestures for 2s so the fist the
        // hand lands in as the snap finishes can't arm a cast.
        snapSuppressUntil = now.addingTimeInterval(2.0)
        debouncer.reset()
        currentGesture = .snap
        apply(coordinator.reduce(.localGesture(.snap)))
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
            do {
                try screenSource.startCapture()
            } catch {
                statusLine = "Enable Screen Recording for QuackCast in System Settings ▸ Privacy & Security, then relaunch."
            }
        case .stopScreenCapture:
            screenSource.stopCapture()
        case .advertiseSourceAvailable:
            broadcast(.sourceAvailable)
        case .withdrawSourceAvailable:
            broadcast(.sourceWithdrawn)
        case .requestCastFromPeer(let peer):
            transport.send(.requestCast, to: peer)
        case .startStreaming(let peer):
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
                    self.statusLine = "📸 Screenshot saved to Desktop: \(url.lastPathComponent)"
                } catch {
                    // Show the real underlying error so failures are diagnosable
                    // rather than always blamed on permissions.
                    self.statusLine = "Snap heard — screenshot failed: \(error.localizedDescription)"
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

    private func jpeg(from pixelBuffer: CVPixelBuffer, quality: CGFloat = 0.5) -> Data? {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        return ciContext.jpegRepresentation(of: image, colorSpace: colorSpace,
                                             options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: quality])
    }

    private func updateStatus() {
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

    nonisolated func transport(_ transport: PeerTransport, didReceive message: ControlMessage, from peer: Peer) {
        Task { @MainActor in
            let input: SessionInput
            switch message {
            case .sourceAvailable: input = .remoteSourceBecameAvailable(peer)
            case .sourceWithdrawn: input = .remoteSourceWithdrawn(peer)
            case .requestCast:     input = .remoteRequestedCast(peer)
            case .endCast:         input = .remoteEndedCast(peer)
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
