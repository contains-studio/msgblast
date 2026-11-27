import CryptoKit
import Foundation
import Network

/// What msgblast keeps in the Keychain for The Want MCP: an OAuth grant for the lists the
/// person ticked, or a pasted write key for one list.
public struct WantCredential: Codable, Equatable, Sendable {
    public var accessCursor: Int?
    public var removedLists: Set<String>?
    public var claim: WantClaim?
    public var grantID: UUID?
    public var accessToken: String
    public var endpoint: URL?
    public var refreshToken: String?
    public var expiresAt: Date?
    /// Set for OAuth grants, so the token can be refreshed.
    public var clientID: String?, tokenEndpoint: URL?

    public init(accessToken: String, refreshToken: String? = nil, expiresAt: Date? = nil, clientID: String? = nil, tokenEndpoint: URL? = nil) {
        self.accessToken = accessToken; self.refreshToken = refreshToken; self.expiresAt = expiresAt; self.clientID = clientID; self.tokenEndpoint = tokenEndpoint
    }
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

/// OAuth 2.1 authorization code + PKCE (S256) as MCP 2026-07-28 describes it: protected resource
/// metadata, then the authorization server's metadata, Dynamic Client Registration as a native
/// app with a loopback redirect, and the MCP server as the `resource`.
public enum WantOAuth {
    public static var checkHeaders: [String: String] {
        ProcessInfo.processInfo.arguments.contains("--wants-integration-check") ? ["x-wantmcp-check": "1"] : [:]
    }
    public static let network: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpAdditionalHeaders = checkHeaders
        return URLSession(configuration: config)
    }()
    public static let resource = URL(string: "https://mcp.wantmcp.com/mcp")!
    public static let keyPage = URL(string: "https://wantmcp.com/connect/key?app=msgblast")!

    public struct Server: Equatable, Sendable {
        public var issuer: String, authorizationEndpoint: URL, tokenEndpoint: URL, registrationEndpoint: URL?
        /// The resource's scopes, plus `offline_access` when offered so the grant can be refreshed.
        public var scope: String?
        /// The server promised `iss` on its redirect, so a redirect without it is refused.
        public var requiresIssuer = false
    }

    /// `resource_metadata` from a `WWW-Authenticate: Bearer ...` challenge.
    public static func resourceMetadata(_ header: String?) -> URL? {
        guard let header, let range = header.range(of: "resource_metadata=\"") else { return nil }
        return URL(string: String(header[range.upperBound...].prefix { $0 != "\"" }))
    }

    public static func discover(resource: URL, hint: URL?, session: URLSession = WantOAuth.network) async throws -> Server {
        guard WantMCPClient.allowsEndpoint(resource) else { throw WantError.server("Use an HTTPS Want MCP endpoint, or HTTP on localhost.") }
        var origin = URLComponents(url: resource, resolvingAgainstBaseURL: false)!
        origin.path = ""; origin.query = nil
        let base = origin.url!
        let candidates = [hint, base.appendingPathComponent(".well-known/oauth-protected-resource" + resource.path),
                          base.appendingPathComponent(".well-known/oauth-protected-resource")].compactMap { $0 }
        guard let metadata = await firstJSON(candidates, session: session),
              let issuer = (metadata["authorization_servers"] as? [String])?.first, let issuerURL = URL(string: issuer) else { throw WantError.server("The Want MCP did not say where to sign in.") }
        let wellKnown = [".well-known/oauth-authorization-server", ".well-known/openid-configuration"].map { issuerURL.appendingPathComponent($0) }
        guard let server = await firstJSON(wellKnown, session: session), server["issuer"] as? String == issuer,
              let authorize = (server["authorization_endpoint"] as? String).flatMap(URL.init(string:)),
              let token = (server["token_endpoint"] as? String).flatMap(URL.init(string:)) else { throw WantError.server("The Want MCP's sign-in server could not be found.") }
        guard WantMCPClient.allowsEndpoint(authorize), WantMCPClient.allowsEndpoint(token) else { throw WantError.server("The sign-in server returned an invalid endpoint.") }
        guard (server["code_challenge_methods_supported"] as? [String])?.contains("S256") == true else { throw WantError.server("The Want MCP's sign-in server does not support PKCE.") }
        let offline = (server["scopes_supported"] as? [String])?.contains("offline_access") == true ? ["offline_access"] : []
        let scopes = (metadata["scopes_supported"] as? [String] ?? []) + offline
        return Server(issuer: issuer, authorizationEndpoint: authorize, tokenEndpoint: token,
                      registrationEndpoint: (server["registration_endpoint"] as? String).flatMap(URL.init(string:)),
                      scope: scopes.isEmpty ? nil : scopes.joined(separator: " "),
                      requiresIssuer: server["authorization_response_iss_parameter_supported"] as? Bool == true)
    }

    /// Registers msgblast and returns its client id. The loopback redirect is registered without its port,
    /// which the server accepts on any port at authorization time (RFC 8252 section 7.3).
    public static func register(_ server: Server, redirect: URL, session: URLSession = WantOAuth.network) async throws -> String {
        guard let endpoint = server.registrationEndpoint, WantMCPClient.allowsEndpoint(endpoint) else { throw WantError.server("The Want MCP does not accept new apps yet.") }
        let body: [String: Any] = ["client_name": "msgblast", "client_uri": "https://github.com/contains-studio/msgblast", "application_type": "native",
                                   "redirect_uris": [portless(redirect)], "grant_types": ["authorization_code", "refresh_token"],
                                   "response_types": ["code"], "token_endpoint_auth_method": "none"]
        let json = try await post(endpoint, json: body, session: session)
        guard let id = json["client_id"] as? String else { throw WantError.invalidResponse }
        return id
    }

    static func portless(_ url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.port = nil
        return components.string!
    }

    public struct PKCE: Sendable {
        public let verifier: String, challenge: String, state: String
        public init() {
            verifier = WantOAuth.random(); state = WantOAuth.random()
            challenge = WantOAuth.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        }
    }

    public static func authorizeURL(_ server: Server, clientID: String, redirect: URL, pkce: PKCE, resource: URL) -> URL {
        var components = URLComponents(url: server.authorizationEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = (components.queryItems ?? []) + [
            .init(name: "response_type", value: "code"), .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirect.absoluteString), .init(name: "code_challenge", value: pkce.challenge),
            .init(name: "code_challenge_method", value: "S256"), .init(name: "state", value: pkce.state),
            .init(name: "resource", value: resource.absoluteString),
        ] + (server.scope.map { [.init(name: "scope", value: $0)] } ?? [])
        return components.url!
    }

    /// Exchanges the callback's code. Checks `state`, and `iss` when the server sends it.
    public static func exchange(callback: URL, server: Server, clientID: String, redirect: URL, pkce: PKCE, resource: URL,
                                session: URLSession = WantOAuth.network) async throws -> WantCredential {
        let query = Dictionary(URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems?.map { ($0.name, $0.value ?? "") } ?? [], uniquingKeysWith: { a, _ in a })
        guard query["state"] == pkce.state, query["iss"].map({ $0 == server.issuer }) ?? !server.requiresIssuer else { throw WantError.server("Sign-in did not match this request. Try again.") }
        guard let code = query["code"] else { throw WantError.server(query["error_description"] ?? query["error"] ?? "Sign-in was cancelled.") }
        return try await token(server.tokenEndpoint, clientID: clientID, form: [
            "grant_type": "authorization_code", "code": code, "redirect_uri": redirect.absoluteString,
            "code_verifier": pkce.verifier, "client_id": clientID, "resource": resource.absoluteString,
        ], session: session)
    }

    public static func refresh(_ credential: WantCredential, resource: URL, session: URLSession = WantOAuth.network) async throws -> WantCredential {
        guard let clientID = credential.clientID, let endpoint = credential.tokenEndpoint, let refresh = credential.refreshToken else { throw WantError.unauthorized(resourceMetadata: nil) }
        var next = try await token(endpoint, clientID: clientID, form: ["grant_type": "refresh_token", "refresh_token": refresh,
                                                                         "client_id": clientID, "resource": resource.absoluteString], session: session)
        next.accessCursor = credential.accessCursor
        next.removedLists = credential.removedLists
        next.claim = credential.claim
        next.refreshToken = next.refreshToken ?? refresh
        return next
    }

    private actor Backoff {
        var deadlines: [String: Date] = [:]
        func wait(for host: String, mayWait: Bool) async throws {
            while let deadline = deadlines[host], deadline > Date() {
                let delay = max(0, deadline.timeIntervalSinceNow)
                guard mayWait else { throw WantError.unavailable(retryAfter: delay) }
                try await Task.sleep(for: .seconds(delay))
            }
        }
        func postpone(_ host: String, seconds: TimeInterval) {
            deadlines[host] = max(deadlines[host] ?? .distantPast, Date().addingTimeInterval(seconds))
        }
    }
    private static let backoff = Backoff()

    static func retryDelay(_ header: String?, now: Date = Date()) -> TimeInterval {
        guard let header else { return 60 }
        if let seconds = UInt32(header) { return TimeInterval(seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        for format in ["EEE, dd MMM yyyy HH:mm:ss 'GMT'", "EEEE, dd-MMM-yy HH:mm:ss 'GMT'", "EEE MMM d HH:mm:ss yyyy"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: header) { return max(0, date.timeIntervalSince(now)) }
        }
        return 60
    }

    static func transmit(_ input: URLRequest, session: URLSession, retryUnavailable: Bool = false,
                         bearer: (@Sendable () async throws -> String?)? = nil) async throws -> (Data, HTTPURLResponse, String?) {
        let host = input.url?.host ?? ""
        var original: String?
        for attempt in 0...1 {
            try await backoff.wait(for: host, mayWait: retryUnavailable)
            var request = input
            let current = try await bearer?()
            guard attempt == 0 || original == current else { throw CancellationError() }
            original = current
            if let current { request.setValue("Bearer \(current)", forHTTPHeaderField: "Authorization") }
            try Task.checkCancellation()
            let (data, response) = try await session.data(for: request, delegate: WantRedirectPolicy())
            guard let http = response as? HTTPURLResponse else { throw WantError.invalidResponse }
            guard http.statusCode == 503 || http.statusCode == 429 else { return (data, http, current) }
            let delay = retryDelay(http.value(forHTTPHeaderField: "Retry-After"))
            await backoff.postpone(host, seconds: delay)
            guard retryUnavailable, attempt == 0 else { throw WantError.unavailable(retryAfter: delay) }
        }
        throw WantError.invalidResponse
    }

    private static func token(_ endpoint: URL, clientID: String, form: [String: String], session: URLSession) async throws -> WantCredential {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.urlQueryAllowed; allowed.remove(charactersIn: "+&=")
        request.httpBody = Data(form.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }.joined(separator: "&").utf8)
        let (data, response, _) = try await transmit(request, session: session)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw WantError.invalidResponse }
        guard response.statusCode == 200, let access = json["access_token"] as? String else {
            if json["error"] as? String == "invalid_grant", form["grant_type"] == "refresh_token" { throw WantError.unauthorized(resourceMetadata: nil) }
            throw WantError.server(json["error_description"] as? String ?? "The Want MCP did not accept the sign-in.")
        }
        return WantCredential(accessToken: access, refreshToken: json["refresh_token"] as? String,
                              expiresAt: (json["expires_in"] as? Double).map { Date().addingTimeInterval($0) }, clientID: clientID, tokenEndpoint: endpoint)
    }

    private static func post(_ url: URL, json: [String: Any], session: URLSession) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: json)
        let (data, response) = try await session.data(for: request, delegate: WantRedirectPolicy())
        guard (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw WantError.server("The Want MCP did not register msgblast.") }
        return object
    }

    private static func firstJSON(_ urls: [URL], session: URLSession) async -> [String: Any]? {
        for url in urls where WantMCPClient.allowsEndpoint(url) {
            guard let (data, response) = try? await session.data(for: URLRequest(url: url), delegate: WantRedirectPolicy()), (response as? HTTPURLResponse)?.statusCode == 200,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            return object
        }
        return nil
    }

    static func random() -> String { base64URL(Data((0..<32).map { _ in UInt8.random(in: 0...255) })) }
    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

/// The sign-in redirect: one GET to `http://127.0.0.1:<port>/callback` on loopback only. It answers
/// with a short page and hands back the URL; anything else gets 404.
@MainActor public final class WantOAuthCallback {
    private var listener: NWListener?
    private var startup: CheckedContinuation<URL, Error>?
    private var waiter: CheckedContinuation<URL, Error>?
    private var stopped = false
    public private(set) var redirect: URL?
    public init() {}

    public func start() async throws -> URL {
        guard !stopped else { throw CancellationError() }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in Task { @MainActor in self?.accept(connection) } }
        let url: URL = try await withCheckedThrowingContinuation { continuation in
            startup = continuation
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                Task { @MainActor in
                    guard let self, let startup = self.startup else { return }
                    switch state {
                    case .ready: self.startup = nil; startup.resume(returning: URL(string: "http://127.0.0.1:\(listener?.port?.rawValue ?? 0)/callback")!)
                    case .failed, .cancelled: self.startup = nil; startup.resume(throwing: CancellationError())
                    default: break
                    }
                }
            }
            listener.start(queue: .main)
        }
        redirect = url
        return url
    }

    public func wait() async throws -> URL {
        guard !stopped else { throw CancellationError() }
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }

    public func stop() {
        stopped = true
        listener?.cancel(); listener = nil
        startup?.resume(throwing: CancellationError()); startup = nil
        waiter?.resume(throwing: CancellationError()); waiter = nil
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            Task { @MainActor in
                let line = data.flatMap { String(data: $0, encoding: .utf8) }?.components(separatedBy: "\r\n").first ?? ""
                let parts = line.split(separator: " ")
                let found = parts.count == 3 && parts[0] == "GET" && parts[1].hasPrefix("/callback?")
                let body = found ? "<!doctype html><title>msgblast</title><p style=\"font:16px -apple-system;margin:3em\">Signed in. You can close this tab and return to msgblast.</p>" : "Not found"
                let head = "HTTP/1.1 \(found ? "200 OK" : "404 Not Found")\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n"
                connection.send(content: Data((head + body).utf8), completion: .contentProcessed { _ in connection.cancel() })
                guard found, let self, let redirect = self.redirect, let url = URL(string: String(parts[1]), relativeTo: redirect)?.absoluteURL else { return }
                self.waiter?.resume(returning: url); self.waiter = nil
            }
        }
    }
}
