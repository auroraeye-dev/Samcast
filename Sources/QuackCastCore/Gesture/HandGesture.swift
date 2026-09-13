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
    /// Index + middle extended, ring + little curled — the "peace"/V sign,
    /// used to take a screenshot. Chosen because it is exactly two extended
    /// fingers, which no fist (zero) or open palm (four) can be mistaken for,
    /// and it needs only one hand with nothing overlapping.
    case peace
}
