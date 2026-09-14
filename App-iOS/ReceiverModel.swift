import Foundation
import SwiftUI
import UIKit
import QuackCastCore
import QuackCastPlatform

/// A received page, wrapped so SwiftUI can present it by identity.
struct ReceivedPage: Identifiable {
    let id = UUID()
    let url: URL
    let from: String
}

/// iOS/iPadOS peer. Works in both directions:
///
/// * **Receiving** — open your hand here to take a page or screen that another
///   device has grabbed. Devices you have accepted from before are trusted, so
///   it happens automatically without tapping anything.
/// * **Sending** — close your hand to grab the link currently on the clipboard
///   and offer it to other devices. iOS cannot read Safari's open tab the way
///   macOS can (there is no AppleScript), so the clipboard is the way a link
///   leaves an iPad.
@MainActor
final class ReceiverModel: ObservableObject {
    private var coordinator = SessionCoordinator()
    private let classifier = GestureClassifier()
    private var debouncer = GestureDebouncer(holdDuration: 0.6)

    let handTracker = VisionHandTracker()
    private let transport = MultipeerTransport(kind: .iPad)
    private let trust = TrustStore()

    /// A link grabbed here, waiting to be dropped on another device.
    private var pendingHandoff: URL?

    /// This device's persistent QuackCast name, shown so you know what to look
    /// for on the other device.
    let identity = DeviceIdentity.loadOrCreate(kind: .iPad)

    @Published private(set) var state: SessionState = .idle
    @Published private(set) var peers: [Peer] = []
    @Published private(set) var currentGesture: HandGesture = .none
    @Published private(set) var receivedImage: UIImage?
    @Published private(set) var statusLine = "Looking for a Mac…"
    @Published private(set) var availableSource: Peer?
    /// Live: is a real hand in front of this device's camera?
    @Published private(set) var handDetected = false
    /// Devices already accepted from, so they are not asked about again.
    @Published private(set) var trustedNames: [String] = []
    /// True when the device offering something has been approved before, in
    /// which case the gesture alone is enough and no button is shown.
    @Published private(set) var sourceIsKnown = false
    /// Live readout of the fingers this device's camera sees, so it is obvious
    /// whether an open hand is being recognised here.
    @Published private(set) var fingerReadout = "—"
    /// A page handed to this device, shown in an in-app browser.
    ///
    /// Opening it in Safari instead would background QuackCast, and iOS then
    /// suspends its networking and camera — so the device silently stops being
    /// able to receive anything until you switch back. Keeping the page inside
    /// the app keeps the connection and the gesture camera alive.
    @Published var receivedPage: ReceivedPage?
    /// Bumped to play the glow when something leaves or arrives.
    @Published private(set) var glowTrigger = 0
    @Published private(set) var glowDirection: GlowDirection = .inward

    func start() {
        transport.delegate = self
        transport.start()

        handTracker.onHands = { [weak self] hands, time in
            guard let self else { return }
            // Only a confident, properly sized hand counts. Receiving someone's
            // screen must never be triggered by a stray detection as you walk
            // past — with several devices nearby, the wrong one could grab it.
            let hand = hands.first
            let real = Self.isRealHand(hand)
            let raw = hand.map { self.classifier.classify($0) } ?? .none
            let fingers = hand.map { self.classifier.extendedFingers($0) }
            Task { @MainActor in
                let text = fingers.map { f -> String in
                    var names: [String] = []
                    if f.index { names.append("index") }
                    if f.middle { names.append("middle") }
                    if f.ring { names.append("ring") }
                    if f.little { names.append("little") }
                    return names.isEmpty ? "none (0)" : "\(names.joined(separator: "+")) (\(f.count))"
                } ?? "—"
                if self.fingerReadout != text { self.fingerReadout = text }
                if real { self.lastRealHand = Date() }
                let present = Date().timeIntervalSince(self.lastRealHand) < self.handGrace
                if self.handDetected != present { self.handDetected = present }
                self.handleGesture(present ? raw : .none, at: time)
            }
        }
        try? handTracker.start()

        trustedNames = Array(trust.trusted.values).sorted()
        updateStatus()
    }

    /// Deliberately forgiving: hand tracking drops frames constantly, and
    /// treating each miss as "no hand" made the indicator flicker and reset
    /// the gesture timer, so a held open hand never completed.
    private static func isRealHand(_ hand: HandLandmarks?) -> Bool {
        guard let hand else { return false }
        guard hand.confidence >= 0.5 else { return false }
        guard hand.points.count >= 10 else { return false }
        guard let span = hand.palmSpan, span >= 0.03 else { return false }
        return true
    }

    /// A hand counts as present for a short while after the last good frame,
    /// which bridges the gaps between detections.
    private var lastRealHand = Date.distantPast
    private let handGrace: TimeInterval = 0.5
    /// Same reasoning as on the Mac: a flickering fist must not cancel the
    /// grab it just made.
    private var armedAt = Date.distantPast
    private let cancelGuard: TimeInterval = 5

    /// On iPad we act on: open hand → receive; close hand (while receiving) →
    /// dismiss. The iPad is never a source.
    private func handleGesture(_ raw: HandGesture, at time: TimeInterval) {
        guard let confirmed = debouncer.update(raw, at: time) else { return }
        currentGesture = confirmed
        switch (state, confirmed) {
        case (.idle, .openHand):
            requestReceive()
        case (.idle, .closedHand):
            // Grab the clipboard link and offer it to other devices.
            apply(coordinator.reduce(.localGesture(.closedHand)))
            armedAt = Date()
        case (.armedSource, .closedHand):
            guard Date().timeIntervalSince(armedAt) >= cancelGuard else { return }
            apply(coordinator.reduce(.localGesture(.closedHand))) // cancel
        case (.receiving, .closedHand):
            apply(coordinator.reduce(.localGesture(.closedHand)))
        default:
            break
        }
    }

    /// Touch fallback so it works on a device with no usable camera (e.g. the
    /// Simulator) and as a convenience.
    func tapToReceive() { requestReceive() }

    /// Grab whatever link is on the clipboard so it can be sent elsewhere.
    func grabFromClipboard() {
        guard case .idle = state else { return }
        apply(coordinator.reduce(.localGesture(.closedHand)))
    }

    private func clipboardURL() -> URL? {
        if let url = UIPasteboard.general.url, url.scheme?.hasPrefix("http") == true { return url }
        if let text = UIPasteboard.general.string,
           let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
           url.scheme?.hasPrefix("http") == true { return url }
        return nil
    }

    private func requestReceive() {
        guard case .idle = state else { return }

        if let source = coordinator.preferredSource {
            // Accepting from a device is what establishes trust with it.
            trust.trust(source.id, name: source.displayName)
            trustedNames = Array(trust.trusted.values).sorted()
            apply(coordinator.reduce(.localGesture(.openHand)))
            return
        }

        // We may never have heard the offer: the announcement is sent once,
        // and a link that was re-establishing at that moment simply misses it,
        // leaving this device convinced nothing is on offer. Rather than rely
        // on that one message, ask every connected device — only one actually
        // holding something will answer.
        let candidates = transport.connectedPeers
        guard !candidates.isEmpty else {
            statusLine = "No devices nearby to take anything from"
            return
        }
        statusLine = "Asking \(candidates.map(\.displayName).joined(separator: ", "))…"
        for peer in candidates {
            transport.send(.requestCast, to: peer)
        }
    }

    private func pulseGlow(_ direction: GlowDirection) {
        glowDirection = direction
        glowTrigger &+= 1
    }

    private func broadcast(_ message: ControlMessage) {
        for peer in transport.connectedPeers { transport.send(message, to: peer) }
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
            pulseGlow(.inward)
        case .hideRemoteScreen:
            receivedImage = nil
        case .notifyEndedCast(let peer):
            transport.send(.endCast, to: peer)

        case .startScreenCapture:
            // iOS can't capture its own screen, so "grabbing" here means
            // taking the link on the clipboard.
            pendingHandoff = clipboardURL()
        case .stopScreenCapture:
            pendingHandoff = nil
        case .advertiseSourceAvailable:
            broadcast(.sourceAvailable)
        case .withdrawSourceAvailable:
            broadcast(.sourceWithdrawn)
        case .startStreaming(let peer):
            if let url = pendingHandoff {
                transport.send(.handoff, payload: url.absoluteString, to: peer)
                statusLine = "✅ Sent \(url.host ?? "link") to \(peer.displayName)"
                pulseGlow(.outward)
                pendingHandoff = nil
            }
        case .stopStreaming, .takeScreenshot:
            break
        }
    }

    private func updateStatus() {
        availableSource = coordinator.preferredSource
        sourceIsKnown = coordinator.preferredSource.map { trust.isTrusted($0.id) } ?? false
        switch state {
        case .idle:
            if let src = coordinator.preferredSource {
                statusLine = trust.isTrusted(src.id)
                    ? "🖐️ \(src.displayName) has something for you — open your hand here to take it"
                    : "\(src.displayName) wants to send you something — allow it once to continue"
            } else {
                statusLine = peers.isEmpty ? "Looking for a Mac running QuackCast…"
                                           : "Connected — waiting for something to be grabbed"
            }
        case .receiving(let p):
            statusLine = "Receiving from \(p.displayName)"
        case .armedSource:
            statusLine = pendingHandoff.map {
                "Grabbed \($0.host ?? "link") — open your hand at the device you want it on"
            } ?? "Copy a link first, then close your hand to send it"
        case .casting(let p):
            statusLine = "Sending to \(p.displayName)"
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
                guard let payload, let url = URL(string: payload) else {
                    self.statusLine = "Received something unreadable from \(peer.displayName)"
                    return
                }
                self.trust.trust(peer.id, name: peer.displayName)
                self.trustedNames = Array(self.trust.trusted.values).sorted()
                self.pulseGlow(.inward)
                self.statusLine = "📬 Received \(url.host ?? url.absoluteString) from \(peer.displayName)"
                self.receivedPage = ReceivedPage(url: url, from: peer.displayName)
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
