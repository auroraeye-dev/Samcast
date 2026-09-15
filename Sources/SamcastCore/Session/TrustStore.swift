import Foundation

/// Remembers which devices you have already accepted content from, so the
/// approval is asked once rather than every single time.
///
/// Trust is keyed on the peer's stable name/id rather than anything transient,
/// and is deliberately explicit: a device only becomes trusted when the user
/// actively accepts something from it.
public final class TrustStore {
    // Still quackcast: this is where the list of already-approved devices
    // lives, and renaming the key would silently empty it.
    private let key = "quackcast.trusted.peers"
    private let blockedKey = "quackcast.blocked.peers"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Trusted peer ids mapped to the name last seen for them.
    public var trusted: [String: String] {
        defaults.dictionary(forKey: key) as? [String: String] ?? [:]
    }

    public func isTrusted(_ peerID: String) -> Bool {
        trusted[peerID] != nil
    }

    public func trust(_ peerID: String, name: String) {
        var current = trusted
        current[peerID] = name
        defaults.set(current, forKey: key)
        // Changing your mind must actually change it.
        var stillBlocked = blocked
        if stillBlocked.removeValue(forKey: peerID) != nil {
            defaults.set(stillBlocked, forKey: blockedKey)
        }
    }

    public func untrust(_ peerID: String) {
        var current = trusted
        current.removeValue(forKey: peerID)
        defaults.set(current, forKey: key)
    }

    public func untrustAll() {
        defaults.removeObject(forKey: key)
    }

    // MARK: - Refusal
    //
    // A device that was offered and turned down is remembered as refused,
    // not merely left unknown. Otherwise every single offer from it asks
    // again, and a prompt that reappears after you have already said no is
    // how people learn to click through prompts without reading them.
    //
    // Refusal is reversible from the interface; it is a decision, not a
    // punishment.

    public var blocked: [String: String] {
        defaults.dictionary(forKey: blockedKey) as? [String: String] ?? [:]
    }

    public func isBlocked(_ peerID: String) -> Bool {
        blocked[peerID] != nil
    }

    public func block(_ peerID: String, name: String) {
        var current = blocked
        current[peerID] = name
        defaults.set(current, forKey: blockedKey)
        untrust(peerID)          // the two states are mutually exclusive
    }

    public func unblock(_ peerID: String) {
        var current = blocked
        current.removeValue(forKey: peerID)
        defaults.set(current, forKey: blockedKey)
    }

    public func unblockAll() {
        defaults.removeObject(forKey: blockedKey)
    }

    /// Has this device been decided about at all?
    public func isKnown(_ peerID: String) -> Bool {
        isTrusted(peerID) || isBlocked(peerID)
    }
}
