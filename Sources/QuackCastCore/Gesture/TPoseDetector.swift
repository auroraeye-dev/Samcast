import Foundation

/// Detects a two-handed "T" (the sports time-out signal): one hand held
/// upright as the stem, the other laid horizontally across its fingertips.
///
/// This is a purely visual trigger, which is why it replaced the finger snap:
/// it needs no microphone, can't be faked by a table tap or any other noise,
/// and — because it requires *two* hands in perpendicular orientations — it
/// can't be confused with the one-handed open/closed casting gestures.
///
/// All geometry is normalized by palm span, so it works at any distance from
/// the camera.
public struct TPoseDetector: Sendable {
    /// Minimum per-hand tracking confidence.
    public var minConfidence: Double = 0.6
    /// How strongly a hand must align to an axis (0…1). Higher = stricter.
    public var axisTolerance: Double = 0.55
    /// Max gap between the crossbar hand and the stem's fingertips, in palm
    /// spans. In a real T the crossbar rests on the fingertips, so this stays
    /// tight — a loose value would match a hand anywhere in the frame.
    public var maxSeparation: Double = 1.5
    /// How long the T must be held before it fires.
    public var holdDuration: TimeInterval = 0.35

    private var candidateSince: TimeInterval?
    private var fired = false

    public init() {}

    /// Unit direction the hand points, from wrist to middle fingertip.
    /// In image coordinates (top-left origin) "up" is negative y.
    public static func axis(of hand: HandLandmarks) -> Point2D? {
        guard let wrist = hand[.wrist], let tip = hand[.middleTip] else { return nil }
        let dx = tip.x - wrist.x
        let dy = tip.y - wrist.y
        let len = (dx * dx + dy * dy).squareRoot()
        guard len > 1e-6 else { return nil }
        return Point2D(x: dx / len, y: dy / len)
    }

    /// True when hands `a` and `b` form a T in either arrangement.
    public static func isTPose(_ a: HandLandmarks,
                               _ b: HandLandmarks,
                               axisTolerance: Double = 0.55,
                               maxSeparation: Double = 1.5,
                               minConfidence: Double = 0.6) -> Bool {
        guard a.confidence >= minConfidence, b.confidence >= minConfidence else { return false }
        // Either hand may be the upright stem.
        return formsT(stem: a, bar: b, axisTolerance: axisTolerance, maxSeparation: maxSeparation)
            || formsT(stem: b, bar: a, axisTolerance: axisTolerance, maxSeparation: maxSeparation)
    }

    private static func formsT(stem: HandLandmarks,
                               bar: HandLandmarks,
                               axisTolerance: Double,
                               maxSeparation: Double) -> Bool {
        guard let stemAxis = axis(of: stem), let barAxis = axis(of: bar) else { return false }
        guard let stemSpan = stem.palmSpan, let barSpan = bar.palmSpan,
              stemSpan > 0, barSpan > 0 else { return false }

        // Stem points up; crossbar points sideways.
        guard stemAxis.y <= -axisTolerance else { return false }
        guard abs(barAxis.x) >= axisTolerance else { return false }

        // The crossbar must sit near the stem's fingertips.
        guard let stemTip = stem[.middleTip] else { return false }
        let barAnchor = bar[.middleMCP] ?? bar[.wrist]
        guard let anchor = barAnchor else { return false }

        let scale = max(stemSpan, barSpan)
        return anchor.distance(to: stemTip) <= maxSeparation * scale
    }

    /// Feed every frame's detected hands. Returns true once, on the frame the
    /// held T is recognized; it won't fire again until the pose is released.
    public mutating func update(_ hands: [HandLandmarks], at time: TimeInterval) -> Bool {
        guard hands.count >= 2,
              Self.isTPose(hands[0], hands[1],
                           axisTolerance: axisTolerance,
                           maxSeparation: maxSeparation,
                           minConfidence: minConfidence) else {
            candidateSince = nil
            fired = false
            return false
        }

        if candidateSince == nil { candidateSince = time }
        if !fired, let since = candidateSince, time - since >= holdDuration {
            fired = true
            return true
        }
        return false
    }

    public mutating func reset() {
        candidateSince = nil
        fired = false
    }
}
