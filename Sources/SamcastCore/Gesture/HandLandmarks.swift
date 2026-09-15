import Foundation

/// A 2D point in the normalized image coordinate space (0...1 on each axis).
/// We use our own type instead of CGPoint so the core stays free of any
/// platform framework import and remains portable.
public struct Point2D: Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public func distance(to other: Point2D) -> Double {
        let dx = x - other.x
        let dy = y - other.y
        return (dx * dx + dy * dy).squareRoot()
    }
}

/// The 21 hand joints Vision (and MediaPipe) report, named for clarity.
/// A platform adapter is responsible for populating these from whatever
/// hand-tracking API it uses; the core only ever sees this neutral struct.
public enum HandJoint: Int, CaseIterable, Sendable {
    case wrist

    case thumbCMC, thumbMP, thumbIP, thumbTip
    case indexMCP, indexPIP, indexDIP, indexTip
    case middleMCP, middlePIP, middleDIP, middleTip
    case ringMCP, ringPIP, ringDIP, ringTip
    case littleMCP, littlePIP, littleDIP, littleTip
}

/// A single-frame observation of one hand: the 21 joints plus a tracking
/// confidence. Missing joints (low confidence / occluded) are simply absent.
public struct HandLandmarks: Sendable {
    public var points: [HandJoint: Point2D]
    public var confidence: Double

    public init(points: [HandJoint: Point2D], confidence: Double) {
        self.points = points
        self.confidence = confidence
    }

    public subscript(_ joint: HandJoint) -> Point2D? {
        points[joint]
    }

    /// A rough hand-scale reference used to make thresholds size-invariant:
    /// the distance from the wrist to the middle-finger base knuckle.
    public var palmSpan: Double? {
        guard let wrist = self[.wrist], let mid = self[.middleMCP] else { return nil }
        return wrist.distance(to: mid)
    }
}
