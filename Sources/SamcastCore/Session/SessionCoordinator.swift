import Foundation

/// What the app is currently doing on THIS device. Each device runs its own
/// coordinator; they coordinate by exchanging `SessionInput.remote…` messages
/// over the transport.
public enum SessionState: Equatable, Sendable {
    /// Doing nothing; may know about remote sources it could receive.
    case idle
    /// User closed their hand here: this device's screen is captured and
    /// offered to peers, waiting for someone to open their hand elsewhere.
    case armedSource
    /// Actively streaming this device's screen to `peer`.
    case casting(to: Peer)
    /// Actively displaying `peer`'s screen in our window.
    case receiving(from: Peer)
}

/// Inputs that drive the state machine: local gestures plus messages relayed
/// from peers by the transport layer.
public enum SessionInput: Sendable {
    case localGesture(HandGesture)
    case remoteSourceBecameAvailable(Peer)
    case remoteSourceWithdrawn(Peer)
    /// A peer opened their hand at their camera and is requesting our armed
    /// screen.
    case remoteRequestedCast(Peer)
    /// A peer told us the cast we were part of has ended.
    case remoteEndedCast(Peer)
}

/// Side effects the platform layer must carry out. Keeping these as plain data
/// (rather than calling frameworks directly) is what makes the coordinator a
/// pure, unit-testable reducer.
public enum SessionEffect: Equatable, Sendable {
    case startScreenCapture
    case stopScreenCapture
    case advertiseSourceAvailable
    case withdrawSourceAvailable
    /// Tell `peer` to begin streaming its screen to us.
    case requestCastFromPeer(Peer)
    case startStreaming(to: Peer)
    case stopStreaming(to: Peer)
    case showRemoteScreen(from: Peer)
    case hideRemoteScreen
    /// Tell `peer` that the cast has ended on our side.
    case notifyEndedCast(to: Peer)
    case takeScreenshot
}

/// The portable state machine. `reduce` is deterministic and free of side
/// effects beyond mutating `self`, returning the list of effects to perform.
public struct SessionCoordinator: Sendable {
    public private(set) var state: SessionState = .idle

    /// Remote sources currently on offer, most-recently-announced last. When
    /// the user opens their hand we cast-request the most recent one.
    public private(set) var availableSources: [Peer] = []

    public init() {}

    /// The source we would target if the user opened their hand right now.
    public var preferredSource: Peer? { availableSources.last }

    public mutating func reduce(_ input: SessionInput) -> [SessionEffect] {
        switch input {
        case .localGesture(let gesture):
            return handleLocalGesture(gesture)
        case .remoteSourceBecameAvailable(let peer):
            availableSources.removeAll { $0 == peer }
            availableSources.append(peer)
            return []
        case .remoteSourceWithdrawn(let peer):
            availableSources.removeAll { $0 == peer }
            return []
        case .remoteRequestedCast(let peer):
            // Someone opened their hand at their device wanting our armed screen.
            guard state == .armedSource else { return [] }
            state = .casting(to: peer)
            return [.startStreaming(to: peer), .withdrawSourceAvailable]
        case .remoteEndedCast(let peer):
            switch state {
            case .casting(let target) where target == peer:
                state = .idle
                return [.stopStreaming(to: peer), .stopScreenCapture]
            case .receiving(let source) where source == peer:
                state = .idle
                return [.hideRemoteScreen]
            default:
                availableSources.removeAll { $0 == peer }
                return []
            }
        }
    }

    private mutating func handleLocalGesture(_ gesture: HandGesture) -> [SessionEffect] {
        // Snap always takes a screenshot and never changes session state.
        if gesture == .peace {
            return [.takeScreenshot]
        }

        switch state {
        case .idle:
            switch gesture {
            case .closedHand:
                // Arm this device as the source.
                state = .armedSource
                return [.startScreenCapture, .advertiseSourceAvailable]
            case .openHand:
                // Receive from the most recently offered remote source, if any.
                guard let source = preferredSource else { return [] }
                state = .receiving(from: source)
                return [.requestCastFromPeer(source), .showRemoteScreen(from: source)]
            default:
                return []
            }

        case .armedSource:
            // Closing again disarms.
            if gesture == .closedHand {
                state = .idle
                return [.stopScreenCapture, .withdrawSourceAvailable]
            }

            // An open hand while armed used to do nothing — the reasoning being
            // that you cannot cast to yourself. That held only while exactly one
            // device could ever be a source. Between two Macs both ends can arm
            // themselves, and then NEITHER can receive: one sits offering, the
            // other ignores every open hand, and the page closes on the sender
            // and arrives nowhere.
            //
            // So if somebody else is offering, an open hand means what it always
            // means — give it to me — and this device stops being a source to
            // take it. Own offer withdrawn first, so the peer is not left
            // holding a request against a device that has moved on.
            if gesture == .openHand, let source = preferredSource {
                state = .receiving(from: source)
                return [.stopScreenCapture, .withdrawSourceAvailable,
                        .requestCastFromPeer(source), .showRemoteScreen(from: source)]
            }
            return []

        case .casting(let target):
            // Closing your hand while casting stops the cast.
            if gesture == .closedHand {
                state = .idle
                return [.stopStreaming(to: target), .stopScreenCapture, .notifyEndedCast(to: target)]
            }
            return []

        case .receiving(let source):
            // Closing your hand while receiving dismisses the remote screen.
            if gesture == .closedHand {
                state = .idle
                return [.hideRemoteScreen, .notifyEndedCast(to: source)]
            }
            return []
        }
    }
}
