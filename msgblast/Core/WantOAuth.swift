import Foundation

/// What msgblast keeps in the Keychain for The Want MCP: a pasted write key for one list.
public struct WantCredential: Codable, Equatable, Sendable {
    public var accessToken: String
    public var endpoint: URL?

    public init(accessToken: String) { self.accessToken = accessToken }
    public static func restore(_ data: Data, for endpoint: URL) -> Self? {
        guard let key = try? JSONDecoder().decode(Self.self, from: data), key.endpoint == endpoint else { return nil }
        return key
    }
    /// A pasted `wk_` key, or nil when it does not look like one.
    public static func writeKey(_ text: String) -> WantCredential? {
        let key = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.hasPrefix("wk_"), key.count >= 35, key.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }) else { return nil }
        return WantCredential(accessToken: key)
    }
}

public enum WantOAuth {
    /// `resource_metadata` from a `WWW-Authenticate: Bearer ...` challenge.
    public static func resourceMetadata(_ header: String?) -> URL? {
        guard let header, let range = header.range(of: "resource_metadata=\"") else { return nil }
        return URL(string: String(header[range.upperBound...].prefix { $0 != "\"" }))
    }
}
