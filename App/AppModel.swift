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
    // A snap only counts if a hand was seen within this window of the sound.
    private var lastHandSeen = Date.distantPast
    private let handVisibleWindow: TimeInterval = 0.6

    // MARK: Published UI state
    @Published private(set) var state: SessionState = .idle
    @Published private(set) var peers: [Peer] = []
    @Published private(set) var currentGesture: HandGesture = .none
    @Published private(set) var receivedImage: NSImage?
    @Published private(set) var lastScreenshot: URL?
    @Published private(set) var statusLine: String = "Starting…"

    func start() {
        transport.delegate = self
        transport.start()

        handTracker.onHand = { [weak self] hand, time in
            guard let self else { return }
            let raw = hand.map { self.classifier.classify($0) } ?? .none
            let handVisible = (hand != nil)
            Task { @MainActor in self.handleGesture(raw, handVisible: handVisible, at: time) }
        }
        do { try handTracker.start() } catch { statusLine = "Camera error: \(error)" }

        // Snap is detected by sound (a sharp transient), which is robust and
        // never confused with the fist cast gesture.
        audioSnap.onSnap = { [weak self] in self?.handleSnap() }
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

    private func handleGesture(_ raw: HandGesture, handVisible: Bool, at time: TimeInterval) {
        // Remember when a hand was last actually seen, so a snap requires the
        // hand to be in view (audio + vision), not just any sound in the room.
        if handVisible { lastHandSeen = Date() }

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

    private func handleSnap() {
        // Sensor fusion: only treat the sound as a snap if a hand is visible in
        // the camera right now — this rejects claps, knocks, typing, and talking.
        guard Date().timeIntervalSince(lastHandSeen) < handVisibleWindow else {
            statusLine = "Snap heard — hold your hand up to the camera and snap to take a screenshot."
            return
        }
        snapSuppressUntil = Date().addingTimeInterval(0.7)
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
                    self.statusLine = "Snap heard — but Screen Recording permission is needed to save a screenshot (System Settings ▸ Privacy & Security)."
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
