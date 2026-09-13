import Foundation

/// Best-effort finger-snap detection from hand landmarks over time.
///
/// A snap is hard to detect from vision alone (it is a fast transient, and
/// audio is a more reliable signal). This heuristic approximates it as the
/// thumb and middle fingertip being in contact and then separating rapidly:
///
///   contact (thumb≈middle)  ──within maxSnapInterval──▶  quick release  ⇒ snap
///
/// Distances are normalized by palm span so they are size-invariant. A cooldown
/// prevents a single snap from firing repeatedly.
public struct SnapDetector: Sendable {
    /// Thumb–middle distance (÷ palm span) below which they count as touching.
    public var contactDistance: Double = 0.35
    /// Distance above which they count as released.
    public var releaseDistance: Double = 0.75
    /// Max time from first contact to release to still count as a snap.
    public var maxSnapInterval: TimeInterval = 0.35
    /// Minimum gap between two reported snaps.
    public var cooldown: TimeInterval = 0.6

    private var contactSince: TimeInterval?
    private var lastSnap: TimeInterval = -.greatestFiniteMagnitude

    public init() {}

    /// Feed every frame's landmarks (nil if no hand). Returns true on the frame
    /// a snap is recognized.
    public mutating func update(_ hand: HandLandmarks?, at time: TimeInterval) -> Bool {
        guard let hand,
              let thumb = hand[.thumbTip],
              let middle = hand[.middleTip],
              let span = hand.palmSpan, span > 0 else {
            contactSince = nil
            return false
        }

        let d = thumb.distance(to: middle) / span

        if d < contactDistance {
            // In/entering contact: remember when contact began.
            if contactSince == nil { contactSince = time }
        } else if d > releaseDistance {
            // Released: was it a quick release after recent contact?
            if let since = contactSince,
               (time - since) <= maxSnapInterval,
               (time - lastSnap) > cooldown {
                contactSince = nil
                lastSnap = time
                return true
            }
            contactSince = nil
        }
        // Intermediate distances leave the contact state untouched.
        return false
    }

    public mutating func reset() {
        contactSince = nil
        lastSnap = -.greatestFiniteMagnitude
    }
}
