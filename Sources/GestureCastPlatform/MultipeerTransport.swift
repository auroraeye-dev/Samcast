import Foundation
import MultipeerConnectivity
import GestureCastCore

/// Apple adapter for `PeerTransport`, backed by MultipeerConnectivity. It
/// advertises and browses for the `gesturecast` service over Bluetooth +
/// peer-to-peer Wi-Fi simultaneously, so any nearby device also running the
/// app is discovered and auto-connected. This is the "my nearby devices that
/// have the app" layer.
///
/// Control messages are sent reliably as a small JSON envelope; screen frames
/// are sent as raw (e.g. JPEG) data unreliably. On receipt we try to decode the
/// control envelope first and treat anything else as a frame.
public final class MultipeerTransport: NSObject, PeerTransport {
    public weak var delegate: PeerTransportDelegate?

    private static let serviceType = "gesturecast" // 1–15 chars, [a-z0-9-]

    private let localKind: Peer.Kind
    private let localPeerID: MCPeerID
    private let session: MCSession
    private let advertiser: MCNearbyServiceAdvertiser
    private let browser: MCNearbyServiceBrowser

    private var peersByMCID: [MCPeerID: Peer] = [:]

    public init(displayName: String? = nil, kind: Peer.Kind = .mac) {
        self.localKind = kind
        let name = String((displayName ?? Host.current().localizedName ?? "Mac").prefix(63))
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
        session.connectedPeers.compactMap { peersByMCID[$0] }
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

    public func send(_ message: ControlMessage, to peer: Peer) {
        guard let mcID = mcID(for: peer) else { return }
        guard let data = try? JSONEncoder().encode(ControlEnvelope(control: message)) else { return }
        try? session.send(data, toPeers: [mcID], with: .reliable)
    }

    /// Send an encoded screen frame (e.g. JPEG) to a peer. Unreliable so a
    /// dropped frame is simply skipped rather than delaying the stream.
    public func sendFrameData(_ frame: Data, to peer: Peer) {
        guard let mcID = mcID(for: peer) else { return }
        try? session.send(frame, toPeers: [mcID], with: .unreliable)
    }

    public func startStreaming(to peer: Peer) { /* streaming is push-driven via sendFrameData */ }
    public func stopStreaming(to peer: Peer) { /* no-op: sender simply stops calling sendFrameData */ }

    // MARK: - Helpers

    private func mcID(for peer: Peer) -> MCPeerID? {
        peersByMCID.first(where: { $0.value.id == peer.id })?.key
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

    private struct ControlEnvelope: Codable { let control: ControlMessage }
}

// MARK: - MCSessionDelegate

extension MultipeerTransport: MCSessionDelegate {
    public func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        notifyPeersChanged()
    }

    public func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        let sender = peer(for: peerID)
        if let envelope = try? JSONDecoder().decode(ControlEnvelope.self, from: data) {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.transport(self, didReceive: envelope.control, from: sender)
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
        // Auto-accept invitations from other GestureCast instances.
        invitationHandler(true, session)
    }
}

extension MultipeerTransport: MCNearbyServiceBrowserDelegate {
    public func browser(_ browser: MCNearbyServiceBrowser,
                        foundPeer peerID: MCPeerID,
                        withDiscoveryInfo info: [String: String]?) {
        let kind = Peer.Kind(rawValue: info?["kind"] ?? "") ?? .unknown
        _ = peer(for: peerID, kind: kind)
        browser.invitePeer(peerID, to: session, withContext: nil, timeout: 15)
    }

    public func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        peersByMCID.removeValue(forKey: peerID)
        notifyPeersChanged()
    }
}
