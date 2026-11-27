import Foundation

public struct WantClaim: Codable, Equatable, Sendable {
    public let listID: String
    public let url: URL
    public let expiresAt: Date

    public var active: Bool { expiresAt > Date() }

    public static func start(title: String, format: WantFormat, session: URLSession = WantOAuth.network) async throws -> WantCredential {
        struct Reply: Decodable {
            struct List: Decodable { let id: String }
            let list: List, key: String, claimUrl: URL, expiresAt: Date
        }
        var request = URLRequest(url: URL(string: "https://api.wantmcp.com/v1/lists/unclaimed")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["title": title, "agent_name": "msgblast", "format": format.rawValue])
        let (data, response) = try await session.data(for: request, delegate: WantRedirectPolicy())
        guard let http = response as? HTTPURLResponse else { throw WantError.invalidResponse }
        if http.statusCode == 429 { throw WantError.server("The list limit has been reached. Try later or connect an existing list.") }
        guard http.statusCode == 201 else { throw WantError.server("The list could not be started. Check your connection.") }
        let reply = try WantJSON.decoder.decode(Reply.self, from: data)
        let url = reply.claimUrl
        guard url.scheme == "https", url.host == "wantmcp.com", url.user == nil, url.password == nil,
              url.port == nil, url.path.hasPrefix("/claim/"), var grant = WantCredential.writeKey(reply.key) else { throw WantError.invalidResponse }
        grant.claim = WantClaim(listID: reply.list.id, url: url, expiresAt: reply.expiresAt)
        return grant
    }
}

public struct WantAccessPage: Decodable, Sendable {
    public struct Event: Decodable, Sendable {
        public let type: String, listId: String
    }
    public let events: [Event]
    public let next: Int
}

public extension WantCredential {
    mutating func apply(_ page: WantAccessPage) {
        for event in page.events {
            switch event.type {
            case "access.removed":
                removedLists = (removedLists ?? []).union([event.listId])
            case "list.claimed": break
            default: continue
            }
            if event.listId == claim?.listID { claim = nil }
        }
    }
}
