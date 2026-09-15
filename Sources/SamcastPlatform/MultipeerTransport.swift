import Foundation
import MultipeerConnectivity
import SamcastCore
#if os(iOS)
import UIKit
#endif

/// This device's persistent Samcast name. Devices are discovered and trusted
/// by this rather than by the OS device name, which can change or be
/// unreadable.
private func quackCastName() -> String {
    DeviceIdentity.loadOrCreate().name
}

/// Apple adapter for `PeerTransport`, backed by MultipeerConnectivity. It
/// advertises and browses for the `samcast` service over Bluetooth +
/// peer-to-peer Wi-Fi simultaneously, so any nearby device also running the
/// app is discovered and auto-connected. This is the "my nearby devices that
/// have the app" layer.
///
/// Control messages are sent reliably as a small JSON envelope; screen frames
/// are sent as raw (e.g. JPEG) data unreliably. On receipt we try to decode the
/// control envelope first and treat anything else as a frame.
public final class MultipeerTransport: NSObject, PeerTransport {
    public weak var delegate: PeerTransportDelegate?

    /// Where this transport's diagnostics go. The app points it at its log
    /// file; without it these messages went to stdout, which is nowhere at
    /// all for an app launched from Finder — so network faults were invisible
    /// exactly when they mattered.
    public static var log: ((String) -> Void)?

    private func note(_ message: String) {
        Self.log?(message)
        print(message)
    }

    // Still quackcast: this is the name devices find each other by, so both
    // ends must agree. Changing it makes older installs invisible to newer
    // ones for no user-visible gain.
    private static let serviceType = "quackcast" // 1–15 chars, [a-z0-9-]

    private let localKind: Peer.Kind
    private let localPeerID: MCPeerID
    private let session: MCSession
    private let advertiser: MCNearbyServiceAdvertiser
    private let browser: MCNearbyServiceBrowser

    private var peersByMCID: [MCPeerID: Peer] = [:]
    /// Peers we have an invitation outstanding to. Browsing reports the same
    /// peer repeatedly, and inviting again each time builds overlapping
    /// sessions that tear each other down — the connection then survives only
    /// a few seconds at a time.
    private var pendingInvites: Set<MCPeerID> = []

    public init(displayName: String? = nil, kind: Peer.Kind = .mac) {
        self.localKind = kind
        let name = String((displayName ?? quackCastName()).prefix(63))
        self.localPeerID = MCPeerID(displayName: name)
        self.session = MCSession(peer: localPeerID, securityIdentity: nil, encryptionPreference: .required)
        self.advertiser = MCNearbyServiceAdvertiser(peer: localPeerID,
                                                    discoveryInfo: ["kind": kind.rawValue],
                                                    serviceType: Self.serviceType)
        self.browser = MCNearbyServiceBrowser(peer: localPeerID, serviceType: Self.serviceType)
        super.init()
        session.delegate = self
        advertiser.delegate = self
        browser.delegate = self
    }

    public var connectedPeers: [Peer] {
        // Register on demand: a peer can be connected without having gone
        // through discovery in this process (e.g. after a reconnect), and
        // dropping those made connected peers invisible in the UI.
        session.connectedPeers.map { peer(for: $0) }
    }

    public func start() {
        advertiser.startAdvertisingPeer()
        browser.startBrowsingForPeers()
    }

    public func stop() {
        advertiser.stopAdvertisingPeer()
        browser.stopBrowsingForPeers()
        session.disconnect()
    }

    public func send(_ message: ControlMessage, payload: String?, to peer: Peer) {
        // Failures here were swallowed, which hid a one-directional link: the
        // other side's messages arrived while ours silently went nowhere.
        guard let mcID = mcID(for: peer) else {
            note("QC-net: send \(message.rawValue) FAILED — no peer id for \(peer.displayName)")
            return
        }
        guard session.connectedPeers.contains(where: { $0.displayName == mcID.displayName }) else {
            note("QC-net: send \(message.rawValue) FAILED — \(peer.displayName) not in session (connected: \(session.connectedPeers.map(\.displayName)))")
            return
        }
        let envelope = ControlEnvelope(control: message, payload: payload)
        guard let data = try? JSONEncoder().encode(envelope) else { return }
        do {
            try session.send(data, toPeers: [mcID], with: .reliable)
            note("QC-net: sent \(message.rawValue) to \(peer.displayName)")
        } catch {
            note("QC-net: send \(message.rawValue) to \(peer.displayName) THREW \(error.localizedDescription)")
        }
    }

    /// Send an encoded screen frame (e.g. JPEG) to a peer.
    ///
    /// Sent **reliably**, despite a stale frame being worth little. Unreliable
    /// mode is datagram-based and silently refuses payloads past a size
    /// ceiling, and a JPEG of a window is easily 100–300 KB — so every frame
    /// disappeared with no error anywhere. A dropped frame you can see beats a
    /// fast one you cannot.
    ///
    /// Failures are reported rather than swallowed, but only once a second:
    /// at twelve frames a second a broken stream would otherwise bury every
    /// other line in the log.
    public func sendFrameData(_ frame: Data, to peer: Peer) {
        guard let mcID = mcID(for: peer),
              session.connectedPeers.contains(where: { $0.displayName == mcID.displayName })
        else {
            throttledFrameNote("QC-net: frame dropped — \(peer.displayName) not connected")
            return
        }
        do {
            try session.send(frame, toPeers: [mcID], with: .reliable)
        } catch {
            throttledFrameNote("QC-net: frame of \(frame.count / 1024) KB FAILED — \(error.localizedDescription)")
        }
    }

    private var lastFrameNote = Date.distantPast
    private func throttledFrameNote(_ message: String) {
        guard Date().timeIntervalSince(lastFrameNote) >= 1 else { return }
        lastFrameNote = Date()
        note(message)
    }

    public func startStreaming(to peer: Peer) { /* streaming is push-driven via sendFrameData */ }
    public func stopStreaming(to peer: Peer) { /* no-op: sender simply stops calling sendFrameData */ }

    // MARK: - Helpers

    /// Deterministic, and identical on both sides, so exactly one of any pair
    /// ever sends an invitation.
    private func shouldInitiate(to peerID: MCPeerID) -> Bool {
        localPeerID.displayName < peerID.displayName
    }

    private func invite(_ peerID: MCPeerID) {
        guard !session.connectedPeers.contains(peerID) else { return }
        guard !pendingInvites.contains(peerID) else { return }   // one at a time
        pendingInvites.insert(peerID)
        browser.invitePeer(peerID, to: session, withContext: nil, timeout: 15)
        // Allow a retry once the invitation can no longer be accepted.
        DispatchQueue.main.asyncAfter(deadline: .now() + 16) { [weak self] in
            self?.pendingInvites.remove(peerID)
        }
    }

    /// Resolve a peer to the MCPeerID the *session* is using.
    ///
    /// MCPeerID identity is not its display name: two instances describing the
    /// same device — one from discovery, one from the session — compare as
    /// different objects. Addressing a send with a cached instance therefore
    /// failed silently, so one direction of the link went nowhere while the
    /// other worked. Always prefer the session's own instance.
    private func mcID(for peer: Peer) -> MCPeerID? {
        if let live = session.connectedPeers.first(where: { $0.displayName == peer.id }) {
            return live
        }
        return peersByMCID.first(where: { $0.value.id == peer.id })?.key
    }

    private func peer(for mcID: MCPeerID, kind: Peer.Kind = .unknown) -> Peer {
        if let existing = peersByMCID[mcID] { return existing }
        let p = Peer(id: mcID.displayName, displayName: mcID.displayName, kind: kind)
        peersByMCID[mcID] = p
        return p
    }

    private func notifyPeersChanged() {
        let peers = connectedPeers
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.transport(self, didUpdate: peers)
        }
    }

    private struct ControlEnvelope: Codable {
        let control: ControlMessage
        var payload: String?
    }
}

// MARK: - MCSessionDelegate

extension MultipeerTransport: MCSessionDelegate {
    public func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        if state == .connected {
            // Make sure the peer is known, so it shows up as nearby.
            _ = peer(for: peerID)
            pendingInvites.remove(peerID)
        }
        if state == .notConnected {
            // Forget the peer so a later discovery is treated as fresh. Holding
            // a stale entry made us refuse the reconnect invitation, which is
            // why restarting one side left both stuck on "no nearby devices".
            peersByMCID.removeValue(forKey: peerID)
            pendingInvites.remove(peerID)
            // Only the designated initiator retries, for the same reason it is
            // the only one that invites in the first place.
            if shouldInitiate(to: peerID) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                    self?.invite(peerID)
                }
            }
        }
        notifyPeersChanged()
    }

    public func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        let sender = peer(for: peerID)
        if let envelope = try? JSONDecoder().decode(ControlEnvelope.self, from: data) {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.transport(self, didReceive: envelope.control, payload: envelope.payload, from: sender)
            }
        } else {
            // Treat as an opaque screen frame.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.transport(self, didReceiveFrame: data, from: sender)
            }
        }
    }

    public func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    public func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    public func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

// MARK: - Advertiser / Browser

extension MultipeerTransport: MCNearbyServiceAdvertiserDelegate {
    public func advertiser(_ advertiser: MCNearbyServiceAdvertiser,
                           didReceiveInvitationFromPeer peerID: MCPeerID,
                           withContext context: Data?,
                           invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        // Accept invitations from other Samcast instances, unless we are
        // already connected to that peer (which would create a second session).
        invitationHandler(!session.connectedPeers.contains(peerID), session)
    }

    public func advertiser(_ advertiser: MCNearbyServiceAdvertiser,
                           didNotStartAdvertisingPeer error: Error) {
        // Same reasoning as browsing: retry rather than going silently dark.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.advertiser.startAdvertisingPeer()
        }
    }
}

extension MultipeerTransport: MCNearbyServiceBrowserDelegate {
    public func browser(_ browser: MCNearbyServiceBrowser,
                        foundPeer peerID: MCPeerID,
                        withDiscoveryInfo info: [String: String]?) {
        let kind = Peer.Kind(rawValue: info?["kind"] ?? "") ?? .unknown
        _ = peer(for: peerID, kind: kind)

        // Exactly one side may invite. Every peer both advertises and
        // browses, so if both invite they build two competing sessions which
        // immediately tear each other down — the connection then flaps on and
        // off every few milliseconds. The peer with the lower id invites; the
        // other waits to be invited and never initiates.
        guard shouldInitiate(to: peerID) else { return }
        invite(peerID)
    }

    public func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        peersByMCID.removeValue(forKey: peerID)
        notifyPeersChanged()
    }

    public func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        // Browsing can fail transiently (e.g. the network changing). Without a
        // retry the app silently never discovers anything again.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.browser.startBrowsingForPeers()
        }
    }
}
