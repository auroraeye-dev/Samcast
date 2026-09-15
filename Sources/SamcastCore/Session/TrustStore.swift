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
    }

    public func untrust(_ peerID: String) {
        var current = trusted
        current.removeValue(forKey: peerID)
        defaults.set(current, forKey: key)
    }

    public func untrustAll() {
        defaults.removeObject(forKey: key)
    }
}
