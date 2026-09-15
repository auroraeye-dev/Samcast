import Foundation
import SwiftUI
import UIKit
import QuackCastCore
import QuackCastPlatform

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
    /// True while a live window is being streamed here. Apps can't be handed
    /// over the way a link can — a running process stays on its own machine —
    /// so what arrives is a live picture of that window instead.
    @Published private(set) var isReceivingStream = false
    /// True when the clipboard holds a link that could be sent.
    ///
    /// Checked with `hasURLs`, which does not read the clipboard and so does
    /// not trigger the system "pasted from" banner; the contents are only
    /// actually read when you deliberately make a fist to send.
    @Published private(set) var clipboardHasLink = false
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
    /// The page currently being shown. Rendered as part of the main view, so
    /// there is no modal presentation to fail.
    @Published var currentPage: URL?
    /// The last page received, kept so it can be reopened from the UI.
    @Published private(set) var lastReceivedURL: URL?
    /// Kept after the browser is dismissed, so there is always evidence of
    /// what this device received and from whom.
    @Published private(set) var lastReceived: String?
    /// Bumped to play the glow when something leaves or arrives.
    @Published private(set) var glowTrigger = 0
    @Published private(set) var glowDirection: GlowDirection = .inward

    func start() {
        print("QC: started as \(identity.name)")
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
    /// A request that gets no answer must not leave this device stuck waiting;
    /// it returns to idle so you can simply try again.
    private var requestTimeout: Task<Void, Never>?
    private let requestDeadline: TimeInterval = 5

    /// On iPad we act on: open hand → receive; close hand (while receiving) →
    /// dismiss. The iPad is never a source.
    private func handleGesture(_ raw: HandGesture, at time: TimeInterval) {
        guard let confirmed = debouncer.update(raw, at: time) else { return }
        print("QC: gesture \(confirmed.rawValue) | state=\(state) | source=\(coordinator.preferredSource?.displayName ?? "none")")
        currentGesture = confirmed
        switch (state, confirmed) {
        case (.idle, .openHand), (.armedSource, .openHand):
            requestReceive()
        case (.idle, .closedHand):
            // Only become a sender if there is actually something to send.
            // Arming with nothing made this device refuse incoming handoffs —
            // a fist caught from across the room silently stopped it being
            // able to receive at all.
            guard clipboardURL() != nil else {
                clipboardHasLink = false
                statusLine = "Copy a link first, then close your hand to send it"
                print("QC: fist ignored — nothing on the clipboard to send")
                return
            }
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

    /// Called when the app comes to the foreground.
    ///
    /// iOS suspends a backgrounded app's camera and networking, so QuackCast
    /// must be open on this device to send or receive at all — nothing can be
    /// done about that. What it can do is be immediately ready: notice a
    /// copied link straight away rather than making you discover that a fist
    /// does nothing.
    func didBecomeActive() {
        clipboardHasLink = UIPasteboard.general.hasURLs || UIPasteboard.general.hasStrings
        // Keep the iPad awake while QuackCast is in front. Auto-lock was
        // quietly ending sessions: the screen sleeps, iOS suspends the app,
        // and the device drops off the network — so a handoff sent moments
        // later had nowhere to land. A device left open as a target should
        // stay a target.
        UIApplication.shared.isIdleTimerDisabled = true
        updateStatus()
    }

    /// Let the iPad sleep normally again once QuackCast is not in front.
    func didResignActive() {
        UIApplication.shared.isIdleTimerDisabled = false
    }

    /// Accept a link handed in from elsewhere, e.g. quackcast://send?url=…
    /// so a Shortcut or share action can pass a page without the clipboard.
    func handleIncoming(_ url: URL) {
        guard url.scheme?.lowercased() == "quackcast" else { return }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let raw = components.queryItems?.first(where: { $0.name == "url" })?.value,
              let target = URL(string: raw),
              target.scheme?.hasPrefix("http") == true else { return }

        pendingHandoff = target
        apply(coordinator.reduce(.localGesture(.closedHand)))
        armedAt = Date()
        statusLine = "Holding \(target.host ?? "link") — open your hand at the device you want it on"
        pulseGlow(.outward)
        print("QC: incoming link \(target.absoluteString)")
    }

    /// Reopen the most recent page after closing it.
    func reopenLastPage() {
        currentPage = lastReceivedURL
    }

    func closePage() {
        currentPage = nil
    }

    /// Stop watching a streamed window and tell the sender.
    func stopWatching() {
        isReceivingStream = false
        receivedImage = nil
        if case .receiving(let peer) = state {
            transport.send(.endCast, to: peer)
            apply(coordinator.reduce(.remoteEndedCast(peer)))
        }
        statusLine = "Stopped watching"
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
        // Armed with nothing to send? Then an open hand plainly means
        // "receive", so step out of sender mode rather than ignoring it.
        if case .armedSource = state, pendingHandoff == nil {
            apply(coordinator.reduce(.localGesture(.closedHand)))
        }
        guard case .idle = state else {
            print("QC: ignoring open hand — busy in state \(state)")
            return
        }

        if let source = coordinator.preferredSource {
            // Accepting from a device is what establishes trust with it.
            trust.trust(source.id, name: source.displayName)
            trustedNames = Array(trust.trusted.values).sorted()
            apply(coordinator.reduce(.localGesture(.openHand)))
            startRequestDeadline()
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
        print("QC: -> requestCast to \(candidates.map(\.displayName))")
        statusLine = "Asking \(candidates.map(\.displayName).joined(separator: ", "))…"
        for peer in candidates {
            transport.send(.requestCast, to: peer)
        }
        startRequestDeadline()
    }

    /// Give up on an unanswered request rather than waiting forever.
    private func startRequestDeadline() {
        requestTimeout?.cancel()
        requestTimeout = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(5 * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            // Something arrived in time, nothing to undo.
            guard self.currentPage == nil, !self.isReceivingStream else { return }
            if case .receiving(let peer) = self.state {
                self.apply(self.coordinator.reduce(.remoteEndedCast(peer)))
            }
            self.statusLine = "Nothing arrived — open your hand again to retry"
            print("QC: request timed out, back to \(self.state)")
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
            isReceivingStream = false
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
            } else if clipboardHasLink {
                statusLine = peers.isEmpty
                    ? "A link is on your clipboard — waiting for a device to send it to"
                    : "A link is on your clipboard — close your hand to send it"
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
            print("QC: peers now \(peers.map(\.displayName))")
            self.peers = peers
            self.updateStatus()
        }
    }

    nonisolated func transport(_ transport: PeerTransport, didReceive message: ControlMessage, payload: String?, from peer: Peer) {
        Task { @MainActor in
            print("QC: <- \(message.rawValue) from \(peer.displayName)\(payload.map { " payload=\($0)" } ?? "")")
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
                print("QC: HANDOFF received \(url.absoluteString)")
                self.requestTimeout?.cancel()
                self.lastReceived = "\(url.host ?? url.absoluteString) — from \(peer.displayName)"
                self.lastReceivedURL = url
                self.currentPage = url
                // A handoff is complete the moment it arrives. Without this the
                // session stayed in "receiving" and every later attempt was
                // refused, so only the first handoff of a session ever worked.
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
        // Both failures below used to return silently, which made "frames are
        // not arriving" and "frames arrive but won't decode" look identical
        // from the iPad — two very different bugs.
        guard let data = frame as? Data else {
            print("QC: frame from \(peer.displayName) was not Data")
            return
        }
        guard let image = UIImage(data: data) else {
            print("QC: frame of \(data.count / 1024) KB from \(peer.displayName) failed to decode")
            return
        }
        Task { @MainActor in
            // Frames only arrive because this device asked for them, and the
            // session may already have settled back to idle, so don't require
            // an exact state match — that silently discarded valid frames.
            if !self.isReceivingStream {
                self.isReceivingStream = true
                self.requestTimeout?.cancel()
                self.currentPage = nil          // a live window takes over
                self.statusLine = "Watching \(peer.displayName)'s window"
                self.pulseGlow(.inward)
                print("QC: stream started from \(peer.displayName)")
            }
            self.receivedImage = image
        }
    }
}
