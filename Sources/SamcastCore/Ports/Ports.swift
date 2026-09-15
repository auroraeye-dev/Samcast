import Foundation

/// The "ports" (in the hexagonal-architecture sense) that platform code must
/// implement. The macOS app supplies Vision / AVFoundation / ScreenCaptureKit /
/// MultipeerConnectivity adapters; a future Windows app supplies its own.
/// SamcastCore depends only on these abstractions.

// MARK: - Hand tracking

/// Produces neutral `HandLandmarks` from the camera. The adapter owns the
/// camera session and any ML model; it hands the core only normalized points.
public protocol HandTracker: AnyObject {
    /// Called for every processed frame with all hands found (empty if none).
    /// Two hands are needed for the T-pose screenshot gesture.
    var onHands: (([HandLandmarks], TimeInterval) -> Void)? { get set }
    func start() throws
    func stop()
}

// MARK: - Screen capture

/// Captures the local screen (or a chosen window) and emits frames. The frame
/// payload type is platform-specific, so it is intentionally opaque here.
public protocol ScreenSource: AnyObject {
    /// Emits an opaque, platform-defined frame plus its presentation time.
    var onFrame: ((Any, TimeInterval) -> Void)? { get set }
    func startCapture() throws
    func stopCapture()
    /// A one-shot still capture used for the snap-to-screenshot feature.
    /// Returns a platform path/URL to the saved image, or throws.
    func captureStill() async throws -> URL
}

// MARK: - Peer transport

/// Discovery + messaging + media streaming between nearby devices running the
/// app. On Apple platforms this is backed by MultipeerConnectivity (Bluetooth +
/// peer-to-peer Wi-Fi), which is exactly the "nearby devices that also have my
/// app" behaviour the product needs.
public protocol PeerTransport: AnyObject {
    var delegate: PeerTransportDelegate? { get set }
    var connectedPeers: [Peer] { get }

    func start()
    func stop()

    /// Send a small control message, optionally carrying a payload (for
    /// handoff this is the URL being moved).
    func send(_ message: ControlMessage, payload: String?, to peer: Peer)

    /// Begin/stop streaming previously-captured screen frames to a peer. The
    /// concrete frame type flows through `ScreenSource.onFrame`.
    func startStreaming(to peer: Peer)
    func stopStreaming(to peer: Peer)
}

/// Control-plane messages exchanged between peers. These map onto
/// `SessionInput.remote…` cases on the receiving device.
public enum ControlMessage: String, Codable, Sendable {
    case sourceAvailable
    case sourceWithdrawn
    case requestCast
    case endCast
    /// Hand the *content itself* to the peer — the payload carries a URL the
    /// receiver opens natively. This is fundamentally different from casting:
    /// nothing is streamed, the thing simply moves.
    case handoff
}

public extension PeerTransport {
    /// Convenience for the many messages that carry no payload.
    func send(_ message: ControlMessage, to peer: Peer) {
        send(message, payload: nil, to: peer)
    }
}

public protocol PeerTransportDelegate: AnyObject {
    func transport(_ transport: PeerTransport, didUpdate peers: [Peer])
    func transport(_ transport: PeerTransport, didReceive message: ControlMessage, payload: String?, from peer: Peer)
    /// A remote screen frame arrived (opaque platform type) for display.
    func transport(_ transport: PeerTransport, didReceiveFrame frame: Any, from peer: Peer)
}
