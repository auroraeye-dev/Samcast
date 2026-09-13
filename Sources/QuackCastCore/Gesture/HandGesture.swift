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
    /// Thumb + index pinched together — a secondary trigger (reserved).
    case pinch
    /// A finger snap. NOTE: reliably detecting a snap from hand pose alone is
    /// hard (it is a fast transient better sensed via audio). This is emitted
    /// only by the best-effort snap heuristic and is intended to trigger a
    /// screenshot.
    case snap
}
