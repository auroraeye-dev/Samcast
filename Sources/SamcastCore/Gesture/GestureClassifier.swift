import Foundation

/// Tunable thresholds for gesture classification. All distances are expressed
/// as multiples of `palmSpan` (wrist→middle-knuckle) so the classifier is
/// invariant to how close the hand is to the camera.
public struct GestureThresholds: Sendable {
    /// Minimum tracking confidence to attempt classification at all.
    public var minConfidence: Double = 0.5
    /// Number of the four non-thumb fingers that must be extended to count as
    /// an open hand.
    public var openHandMinExtendedFingers: Int = 4
    /// Number of the four non-thumb fingers that must be curled to count as a
    /// closed hand (fist).
    public var closedHandMaxExtendedFingers: Int = 0

    public init() {}
}

/// Pure, stateless classification of a single `HandLandmarks` frame into a
/// `HandGesture`. Contains only geometry — no platform code — so it is fully
/// unit-testable and portable.
public struct GestureClassifier: Sendable {
    public var thresholds: GestureThresholds

    public init(thresholds: GestureThresholds = GestureThresholds()) {
        self.thresholds = thresholds
    }

    /// The four non-thumb fingers, as (tip, pip) joint pairs used for the
    /// "extended" test.
    private static let fingers: [(tip: HandJoint, pip: HandJoint)] = [
        (.indexTip, .indexPIP),
        (.middleTip, .middlePIP),
        (.ringTip, .ringPIP),
        (.littleTip, .littlePIP)
    ]

    /// Which of the four non-thumb fingers are extended.
    public struct ExtendedFingers: Equatable, Sendable {
        public var index = false
        public var middle = false
        public var ring = false
        public var little = false
        public var count: Int { [index, middle, ring, little].filter { $0 }.count }
        public init() {}
    }

    /// Per-finger extension, used to recognise specific shapes like the V sign.
    public func extendedFingers(_ hand: HandLandmarks) -> ExtendedFingers {
        var result = ExtendedFingers()
        guard let wrist = hand[.wrist] else { return result }
        func isExtended(_ tip: HandJoint, _ pip: HandJoint) -> Bool {
            guard let t = hand[tip], let p = hand[pip] else { return false }
            return t.distance(to: wrist) > p.distance(to: wrist)
        }
        result.index = isExtended(.indexTip, .indexPIP)
        result.middle = isExtended(.middleTip, .middlePIP)
        result.ring = isExtended(.ringTip, .ringPIP)
        result.little = isExtended(.littleTip, .littlePIP)
        return result
    }

    /// A non-thumb finger is considered extended when its tip is farther from
    /// the wrist than its middle (PIP) joint — true for a straight finger,
    /// false for a curled one, regardless of hand rotation.
    public func extendedFingerCount(_ hand: HandLandmarks) -> Int {
        guard let wrist = hand[.wrist] else { return 0 }
        var count = 0
        for finger in Self.fingers {
            guard let tip = hand[finger.tip], let pip = hand[finger.pip] else { continue }
            if tip.distance(to: wrist) > pip.distance(to: wrist) {
                count += 1
            }
        }
        return count
    }

    public func classify(_ hand: HandLandmarks) -> HandGesture {
        guard hand.confidence >= thresholds.minConfidence else { return .none }

        let fingers = extendedFingers(hand)

        // V sign: index + middle out, ring + little tucked.
        if fingers.index && fingers.middle && !fingers.ring && !fingers.little {
            return .peace
        }
        if fingers.count >= thresholds.openHandMinExtendedFingers {
            return .openHand
        }
        if fingers.count <= thresholds.closedHandMaxExtendedFingers {
            return .closedHand
        }
        return .none
    }
}
