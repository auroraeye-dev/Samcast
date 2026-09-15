import Foundation

/// Temporal smoothing for raw per-frame classifications. A gesture must be held
/// steadily for `holdDuration` seconds before it becomes the confirmed stable
/// gesture, which prevents flicker between frames from firing spurious events.
///
/// Feed it every frame's raw gesture with a monotonic timestamp; it returns a
/// non-nil value only on the frame where the *stable* gesture changes.
public struct GestureDebouncer: Sendable {
    public var holdDuration: TimeInterval

    private var stable: HandGesture = .none
    private var candidate: HandGesture = .none
    private var candidateSince: TimeInterval = 0

    public init(holdDuration: TimeInterval = 0.25) {
        self.holdDuration = holdDuration
    }

    /// The currently confirmed gesture.
    public var current: HandGesture { stable }

    /// Update with the latest raw classification. Returns the new stable
    /// gesture on the frame it changes, otherwise nil.
    public mutating func update(_ raw: HandGesture, at time: TimeInterval) -> HandGesture? {
        if raw != candidate {
            candidate = raw
            candidateSince = time
            return nil
        }

        // Same candidate as last frame: has it been held long enough?
        if candidate != stable && (time - candidateSince) >= holdDuration {
            stable = candidate
            return stable
        }
        return nil
    }

    public mutating func reset() {
        stable = .none
        candidate = .none
        candidateSince = 0
    }
}
