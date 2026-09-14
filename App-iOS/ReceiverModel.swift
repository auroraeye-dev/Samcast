import Foundation
import SwiftUI
import UIKit
import QuackCastCore
import QuackCastPlatform

/// iOS/iPadOS receiver. Discovers a Mac running QuackCast, and when you open
/// your hand at the iPad's camera (or tap the button) it pulls the Mac's screen
/// and displays it. iOS can't capture its own screen for casting, so this
/// device is receive-only for now.
@MainActor
final class ReceiverModel: ObservableObject {
    private var coordinator = SessionCoordinator()
    private let classifier = GestureClassifier()
    private var debouncer = GestureDebouncer(holdDuration: 0.3)

    let handTracker = VisionHandTracker()
    private let transport = MultipeerTransport(kind: .iPad)

    @Published private(set) var state: SessionState = .idle
    @Published private(set) var peers: [Peer] = []
    @Published private(set) var currentGesture: HandGesture = .none
    @Published private(set) var receivedImage: UIImage?
    @Published private(set) var statusLine = "Looking for a Mac…"
    @Published private(set) var availableSource: Peer?

    func start() {
        transport.delegate = self
        transport.start()

        handTracker.onHands = { [weak self] hands, time in
            guard let self else { return }
            let raw = hands.first.map { self.classifier.classify($0) } ?? .none
            Task { @MainActor in self.handleGesture(raw, at: time) }
        }
        try? handTracker.start()

        updateStatus()
    }

    /// On iPad we act on: open hand → receive; close hand (while receiving) →
    /// dismiss. The iPad is never a source.
    private func handleGesture(_ raw: HandGesture, at time: TimeInterval) {
        guard let confirmed = debouncer.update(raw, at: time) else { return }
        currentGesture = confirmed
        switch (state, confirmed) {
        case (.idle, .openHand):
            requestReceive()
        case (.receiving, .closedHand):
            apply(coordinator.reduce(.localGesture(.closedHand)))
        default:
            break
        }
    }

    /// Touch fallback so it works on a device with no usable camera (e.g. the
    /// Simulator) and as a convenience.
    func tapToReceive() { requestReceive() }

    private func requestReceive() {
        guard case .idle = state, coordinator.preferredSource != nil else { return }
        apply(coordinator.reduce(.localGesture(.openHand)))
    }

    private func apply(_ effects: [SessionEffect]) {
        for effect in effects { perform(effect) }
        state = coordinator.state
        updateStatus()
    }

    private func perform(_ effect: SessionEffect) {
        switch effect {
        case .requestCastFromPeer(let peer):
            transport.send(.requestCast, to: peer)
        case .showRemoteScreen:
            receivedImage = nil // populated as frames arrive
        case .hideRemoteScreen:
            receivedImage = nil
        case .notifyEndedCast(let peer):
            transport.send(.endCast, to: peer)
        // The iPad can't be a source; ignore capture/advertise/stream effects.
        case .startScreenCapture, .stopScreenCapture, .advertiseSourceAvailable,
             .withdrawSourceAvailable, .startStreaming, .stopStreaming, .takeScreenshot:
            break
        }
    }

    private func updateStatus() {
        availableSource = coordinator.preferredSource
        switch state {
        case .idle:
            if let src = coordinator.preferredSource {
                statusLine = "Open your hand (or tap) to view \(src.displayName)"
            } else {
                statusLine = peers.isEmpty ? "Looking for a Mac running QuackCast…"
                                           : "Connected — waiting for a shared screen"
            }
        case .receiving(let p):
            statusLine = "Receiving from \(p.displayName)"
        case .armedSource, .casting:
            statusLine = ""
        }
    }
}

extension ReceiverModel: PeerTransportDelegate {
    nonisolated func transport(_ transport: PeerTransport, didUpdate peers: [Peer]) {
        Task { @MainActor in
            self.peers = peers
            self.updateStatus()
        }
    }

    nonisolated func transport(_ transport: PeerTransport, didReceive message: ControlMessage, payload: String?, from peer: Peer) {
        Task { @MainActor in
            // A handed-over page opens in this device's own browser.
            if message == .handoff {
                guard let payload, let url = URL(string: payload) else { return }
                UIApplication.shared.open(url)
                self.statusLine = "Opened a page from \(peer.displayName)"
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
                self.receivedImage = UIImage(data: data)
            }
        }
    }
}
