import CryptoKit
import Foundation

/// Keys that let the built-in msgblast agent's `msgblast mcp` act as `MsgblastAgent.clientName`.
/// Only each key's SHA-256 hash is kept, in memory, so every key ends when msgblast quits.
@MainActor public final class AgentSessionKeys {
    private var hashes: Set<Data> = []
    /// Called after a key is issued or revoked, so the socket can start or stop.
    public var changed: (() -> Void)?

    public init() {}

    public var hasLive: Bool { !hashes.isEmpty }

    /// A new key: 32 random bytes as base64url.
    public func issue() -> String {
        let key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        hashes.insert(Self.hash(key))
        changed?()
        return key
    }

    public func isLive(_ key: String) -> Bool { hashes.contains(Self.hash(key)) }

    public func revoke(_ key: String) {
        guard hashes.remove(Self.hash(key)) != nil else { return }
        changed?()
    }

    public func revokeAll() {
        guard !hashes.isEmpty else { return }
        hashes = []
        changed?()
    }

    private static func hash(_ key: String) -> Data { Data(SHA256.hash(data: Data(key.utf8))) }
}
