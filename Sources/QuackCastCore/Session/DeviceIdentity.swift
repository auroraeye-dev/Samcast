import Foundation

/// A stable, friendly identity for this device.
///
/// Device names like "Satvik's iPad" are not dependable: they change, they
/// collide, and on some platforms they aren't readable at all. QuackCast
/// instead generates a random name once, stores it, and uses it forever — so
/// peers can recognise each other across restarts and remember who they trust.
public struct DeviceIdentity: Equatable, Sendable {
    /// Stable identifier used for trust decisions.
    public let id: String
    /// Human-readable name shown to the user, e.g. "amber-otter-4821".
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    private static let idKey = "quackcast.device.id"
    private static let nameKey = "quackcast.device.name"

    /// Loads the saved identity, creating and persisting one on first run.
    public static func loadOrCreate(
        defaults: UserDefaults = .standard,
        kind: Peer.Kind = .unknown
    ) -> DeviceIdentity {
        if let id = defaults.string(forKey: idKey),
           let name = defaults.string(forKey: nameKey) {
            return DeviceIdentity(id: id, name: name)
        }
        let identity = DeviceIdentity(id: UUID().uuidString, name: randomName(kind: kind))
        defaults.set(identity.id, forKey: idKey)
        defaults.set(identity.name, forKey: nameKey)
        return identity
    }

    /// Replace the generated name with one the user chose.
    public static func rename(to newName: String, defaults: UserDefaults = .standard) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        defaults.set(String(trimmed.prefix(40)), forKey: nameKey)
    }

    private static let adjectives = [
        "amber", "brisk", "calm", "clever", "dusky", "eager", "fleet", "gentle",
        "hazel", "jolly", "keen", "lucky", "mellow", "noble", "quiet", "rapid",
        "silver", "swift", "teal", "vivid", "witty", "zesty"
    ]
    private static let animals = [
        "otter", "falcon", "heron", "lynx", "marten", "osprey", "panda", "quail",
        "raven", "seal", "tapir", "vole", "walrus", "yak", "zebu", "badger",
        "cobra", "dingo", "egret", "ferret"
    ]

    /// e.g. "swift-heron-3172" — easy to say aloud and unlikely to collide.
    public static func randomName(kind: Peer.Kind = .unknown) -> String {
        let adjective = adjectives.randomElement() ?? "swift"
        let animal = animals.randomElement() ?? "otter"
        let number = Int.random(in: 1000...9999)
        return "\(adjective)-\(animal)-\(number)"
    }
}
