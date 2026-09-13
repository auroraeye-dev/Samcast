import Foundation

/// A neutral description of another device running GestureCast, discovered on
/// the local network / Bluetooth. The platform transport maps its own peer
/// handle (e.g. an `MCPeerID`) onto this.
public struct Peer: Hashable, Sendable, Identifiable {
    public let id: String
    public var displayName: String
    public var kind: Kind

    public enum Kind: String, Sendable {
        case mac, iPhone, iPad, windowsPC, unknown
    }

    public init(id: String, displayName: String, kind: Kind = .unknown) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
    }
}
