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
    private var snapDetector = SnapDetector()

    // Platform adapters.
    let handTracker = VisionHandTracker()
    private let transport = MultipeerTransport(kind: .mac)
    private let screenSource = ScreenCaptureKitSource()
    private let ciContext = CIContext()

    // Where captured frames are currently being streamed (if casting).
    private var streamingTarget: Peer?

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
            Task { @MainActor in self.handleFrame(hand: hand, raw: raw, at: time) }
        }
        do { try handTracker.start() } catch { statusLine = "Camera error: \(error)" }

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

    private func handleFrame(hand: HandLandmarks?, raw: HandGesture, at time: TimeInterval) {
        // Snap (thumb–middle quick release) fires a screenshot independently of
        // the open/close casting gesture.
        if snapDetector.update(hand, at: time) {
            currentGesture = .snap
            apply(coordinator.reduce(.localGesture(.snap)))
            return
        }
        if let confirmed = debouncer.update(raw, at: time) {
            currentGesture = confirmed
            apply(coordinator.reduce(.localGesture(confirmed)))
        }
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
            try? screenSource.startCapture()
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
            lastScreenshot = try? screenSource.captureStill()
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
