import Foundation

/// The discrete hand shapes the app reacts to.
public enum HandGesture: String, Equatable, Sendable {
    /// No hand detected, or a shape we don't recognise.
    case none
    /// All fingers extended, palm open — used to *deliver / cast* the screen
    /// to the device in front of you.
    case openHand
    /// Fingers curled into a fist — the "duck-mouth close" that *arms /
    /// captures* the current screen on the source device.
    case closedHand
    /// A two-handed "T" (time-out signal), used to take a screenshot. Purely
    /// visual, so no microphone is involved and no sound can trigger it.
    case tPose
}
