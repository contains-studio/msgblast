import Foundation

public enum WantError: Error, Equatable, LocalizedError {
    /// No credential, or the server refused it. `resourceMetadata` is the challenge's discovery URL.
    case unauthorized(resourceMetadata: URL?)
    case server(String)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .unauthorized: "Sign in to The Want MCP again."
        case .server(let message): message
        case .invalidResponse: "The Want MCP sent a reply msgblast could not read."
        }
    }
}

public protocol WantService: Sendable {
    func writableListIDs() async throws -> [String]
    /// The list and its items, every page. Items carry entries only from servers that still send them.
    func list(_ id: String) async throws -> WantList
    func entries(itemID: String) async throws -> [WantEntry]
    func comments(listID: String) async throws -> [WantComment]
    func suggestions(listID: String) async throws -> [WantEntry]
    /// New events of one type since `cursor` (nil starts from now). `list.activity` is every type.
    func poll(_ type: String, cursor: String?) async throws -> WantEventPage
}

public struct WantEventPage: Equatable, Sendable {
    public var events: [WantEvent], cursor: String?, hasMore: Bool, nextPoll: TimeInterval?, hasActivity: Bool
    public init(events: [WantEvent], cursor: String?, hasMore: Bool = false, nextPoll: TimeInterval? = nil, hasActivity: Bool? = nil) {
        self.hasActivity = hasActivity ?? !events.isEmpty
        self.events = events; self.cursor = cursor; self.hasMore = hasMore; self.nextPoll = nextPoll
    }
}

/// A stateless MCP 2026-07-28 client for `https://mcp.wantmcp.com/mcp`: one JSON-RPC POST per
/// call, with the protocol version and client in `_meta` and headers, and the Events extension
/// declared so `events/poll` is allowed. Replies may be JSON or a request-scoped SSE stream.
public struct WantMCPClient: WantService {
    public static let protocolVersion = "2026-07-28"
    public static let eventsExtension = "io.modelcontextprotocol/events"
    public let endpoint: URL
    private let token: @Sendable () async throws -> String?
    private let session: URLSession
    private let version: String

    public init(endpoint: URL, session: URLSession = .shared, version: String = "dev", token: @escaping @Sendable () async throws -> String?) {
        self.endpoint = endpoint; self.session = session; self.version = version; self.token = token
    }

    /// From `whoami`. An anonymous answer means the credential is gone, so it is treated as signed out.
    public func writableListIDs() async throws -> [String] {
        struct Identity: Decodable { struct Ref: Decodable { var id: String }; var kind: String; var writableLists: [Ref]? }
        let identity = try decode(Identity.self, try await tool("whoami", [:]))
        guard identity.kind != "anonymous" else { throw WantError.unauthorized(resourceMetadata: nil) }
        return (identity.writableLists ?? []).map(\.id)
    }
    public func list(_ id: String) async throws -> WantList {
        var list: WantList?, cursor: String?
        var seen: Set<String> = []
        repeat {
            let content = try await tool("get_list", cursor.map { ["list": id, "cursor": $0] } ?? ["list": id]) as? [String: Any] ?? [:]
            // The compact read may nest the list's own fields under `list`.
            let fields = (content["list"] as? [String: Any] ?? [:]).merging(content) { _, page in page }
            let page = try decode(WantList.self, fields)
            if var merged = list { merged.items = (merged.items ?? []) + (page.items ?? []); list = merged } else { list = page }
            cursor = content["next_cursor"] as? String
            if let cursor, !seen.insert(cursor).inserted { throw WantError.invalidResponse }
        } while cursor != nil
        guard let list else { throw WantError.invalidResponse }
        return list
    }
    public func entries(itemID: String) async throws -> [WantEntry] {
        var entries: [WantEntry] = [], cursor: String?
        var seen: Set<String> = []
        repeat {
            let content = try await tool("get_item_entries", cursor.map { ["item_id": itemID, "cursor": $0] } ?? ["item_id": itemID])
            entries += try decode([WantEntry].self, content, key: "entries")
            cursor = (content as? [String: Any])?["next_cursor"] as? String
            if let cursor, !seen.insert(cursor).inserted { throw WantError.invalidResponse }
        } while cursor != nil
        return entries
    }
    public func comments(listID: String) async throws -> [WantComment] {
        try decode([WantComment].self, try await tool("get_comments", ["list": listID]), key: "comments")
    }
    public func suggestions(listID: String) async throws -> [WantEntry] {
        struct Row: Decodable { var entry: WantEntry }
        return try decode([Row].self, try await tool("list_pending_suggestions", ["list": listID]), key: "suggestions").map(\.entry)
    }

    public func poll(_ type: String, cursor: String?) async throws -> WantEventPage {
        let result = try await request("events/poll", ["name": type, "arguments": [String: Any](), "cursor": cursor ?? NSNull(), "maxEvents": 50])
        let rows = result["events"] as? [Any] ?? []
        let events = rows.compactMap { row -> WantEvent? in
            guard let data = (row as? [String: Any])?["data"] as? [String: Any] else { return nil }
            return try? WantJSON.decoder.decode(WantEvent.self, from: JSONSerialization.data(withJSONObject: data))
        }
        return WantEventPage(events: events, cursor: result["cursor"] as? String ?? cursor, hasMore: result["hasMore"] as? Bool ?? false,
                             nextPoll: (result["nextPollMs"] as? Double).map { $0 / 1000 }, hasActivity: !rows.isEmpty)
    }

    /// A tool's `structuredContent`. A result with `isError` throws its text.
    func tool(_ name: String, _ arguments: [String: Any]) async throws -> Any {
        let result = try await request("tools/call", ["name": name, "arguments": arguments])
        if result["isError"] as? Bool == true {
            let text = (result["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined(separator: " ")
            throw WantError.server(text ?? "\(name) failed")
        }
        guard let content = result["structuredContent"] else { throw WantError.invalidResponse }
        return content
    }

    private func decode<T: Decodable>(_ type: T.Type, _ content: Any) throws -> T {
        try WantJSON.decoder.decode(T.self, from: JSONSerialization.data(withJSONObject: content))
    }
    /// `structuredContent` is an object, so an array comes wrapped: under `key`, `data`, or its only array field.
    private func decode<T: Decodable>(_ type: [T].Type, _ content: Any, key: String) throws -> [T] {
        let object = content as? [String: Any]
        let value = object.flatMap { $0[key] ?? $0["data"] ?? $0.values.first { $0 is [Any] } } ?? content
        return try WantJSON.decoder.decode([T].self, from: JSONSerialization.data(withJSONObject: value))
    }

    public static func allowsEndpoint(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased(), !host.isEmpty, url.user == nil, url.password == nil else { return false }
        return url.scheme?.lowercased() == "https" || (url.scheme?.lowercased() == "http" && ["localhost", "127.0.0.1", "[::1]"].contains(host))
    }

    func request(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        guard Self.allowsEndpoint(endpoint) else { throw WantError.server("Use an HTTPS Want MCP endpoint, or HTTP on localhost.") }
        var params = params
        params["_meta"] = [
            "io.modelcontextprotocol/protocolVersion": Self.protocolVersion,
            "io.modelcontextprotocol/clientInfo": ["name": "msgblast", "version": version],
            "io.modelcontextprotocol/clientCapabilities": ["extensions": [Self.eventsExtension: [String: Any]()]],
        ]
        let id = UUID().uuidString
        var request = URLRequest(url: endpoint, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(Self.protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        request.setValue(method, forHTTPHeaderField: "Mcp-Method")
        if method == "tools/call" || method.hasPrefix("events/"), let name = params["name"] as? String { request.setValue(name, forHTTPHeaderField: "Mcp-Name") }
        if let token = try await token() { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await session.data(for: request, delegate: WantRedirectPolicy())
        guard let http = response as? HTTPURLResponse else { throw WantError.invalidResponse }
        if http.statusCode == 403 { throw WantError.server("The Want MCP did not allow that request.") }
        if http.statusCode == 401 {
            throw WantError.unauthorized(resourceMetadata: WantOAuth.resourceMetadata(http.value(forHTTPHeaderField: "WWW-Authenticate")))
        }
        let message = try Self.message(data, contentType: http.value(forHTTPHeaderField: "Content-Type"), id: id)
        if let error = message["error"] as? [String: Any] { throw WantError.server(error["message"] as? String ?? "The Want MCP refused the request") }
        guard (200..<300).contains(http.statusCode), let result = message["result"] as? [String: Any] else { throw WantError.invalidResponse }
        return result
    }

    /// The JSON-RPC response for `id`, from a JSON body or the `data:` lines of an SSE stream.
    static func message(_ data: Data, contentType: String?, id: String) throws -> [String: Any] {
        guard contentType?.lowercased().hasPrefix("text/event-stream") == true else {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw WantError.invalidResponse }
            return object
        }
        let text = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
        for block in text.components(separatedBy: "\n\n") {
            let payload = block.split(separator: "\n").filter { $0.hasPrefix("data:") }.map { $0.dropFirst(5).trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
            guard let object = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any], object["id"] as? String == id else { continue }
            return object
        }
        throw WantError.invalidResponse
    }
}


private final class WantRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? { nil }
}
