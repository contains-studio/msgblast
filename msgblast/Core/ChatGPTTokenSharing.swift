import CryptoKit
import Foundation
import LocalAuthentication
import Security

/// One ChatGPT account's registration with OpenAI: the `oaiapp_…` client id issued to it, its verified
/// identity, and its tokens until the person disconnects. Disconnecting keeps the client id for the next sign-in.
public struct ChatGPTRegistration: Codable, Equatable, Sendable {
    public struct Tokens: Codable, Equatable, Sendable {
        public var accessToken: String, refreshToken: String?, idToken: String
        public var expiresAt: Date, earliestRefreshAt: Date?
        public var scopes: [String]
    }
    public var clientID: String
    /// The ID token's `sub`. Nil only when OpenAI issued the client but the sign-in never finished.
    public var subject: String?
    public var email: String?
    public var tokens: Tokens?
    /// The person let msgblast use their ChatGPT plan.
    public var sharesPlan: Bool { tokens?.scopes.contains(ChatGPTTokenSharing.sharingScope) == true }
}

public enum ChatGPTSignInError: LocalizedError, Equatable, Sendable {
    case unavailable, declined, unverified, incomplete, codeExpired, differentAccount, signedOut, sharingOff, expired, notYet, rejectedClient, storage, storageUnavailable
    public var errorDescription: String? {
        switch self {
        case .unavailable: "ChatGPT sign-in is unavailable right now. Try again."
        case .declined: "ChatGPT sign-in was declined."
        case .unverified: "ChatGPT sign-in could not be verified. Start again."
        case .incomplete: "ChatGPT sign-in did not finish. Start again."
        case .codeExpired: "This sign-in expired. Start again."
        case .differentAccount: "That is a different ChatGPT account. Your saved connection is unchanged."
        case .signedOut: "Connect with ChatGPT in Settings first."
        case .sharingOff: "ChatGPT plan usage is off for msgblast. Connect again and allow it."
        case .expired: "Your ChatGPT connection ended. Connect again."
        case .notYet: "ChatGPT cannot renew this connection yet. Try again shortly."
        case .rejectedClient: "OpenAI rejected msgblast's registration. Connect again."
        case .storage: "The ChatGPT connection could not be read or saved securely."
        case .storageUnavailable: "This copy of msgblast can’t save a ChatGPT connection. Sign in to Codex CLI above instead."
        }
    }
}

/// Sign in with ChatGPT through OpenAI's token sharing for open-source apps: a public client registered
/// on first sign-in (`dynamic_agent_client`), PKCE with a loopback redirect, and plan-billed access tokens.
public enum ChatGPTTokenSharing {
    public static let issuer = "https://auth.openai.com"
    public static let resource = "https://api.openai.com/v1"
    public static let sharingScope = "chatgpt.tokens.use.direct"
    public static let scope = "openid profile email offline_access resource.invoke \(sharingScope)"
    public static let callbackPath = "/auth/callback"
    /// Where people set per-app usage limits.
    public static let usageSettings = URL(string: "https://chatgpt.com/settings/usage")!
    static let discovery = URL(string: "\(issuer)/.well-known/openid-configuration")!

    public struct Server: Codable, Equatable, Sendable {
        public var issuer: String, authorizationEndpoint: URL, tokenEndpoint: URL, jwksUri: URL, revocationEndpoint: URL?
    }

    /// One sign-in attempt. Its secrets live only until the callback is handled.
    public struct Attempt: Sendable {
        public let state = WantOAuth.random(), nonce = WantOAuth.random(), verifier = WantOAuth.random() + WantOAuth.random()
        public let redirect: URL
        /// The saved account signing in again, or nil to register another account.
        public let registration: ChatGPTRegistration?
        var challenge: String { WantOAuth.base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))) }

        /// The client id and code from the loopback callback, after checking `state`. A reauthorization
        /// keeps its saved client id; a new registration must return the `oaiapp_` id OpenAI issued.
        func clientAndCode(_ callback: URL) throws -> (clientID: String, code: String) {
            let query = Dictionary(URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems?.map { ($0.name, $0.value ?? "") } ?? [], uniquingKeysWith: { a, _ in a })
            guard query["state"] == state else { throw ChatGPTSignInError.unverified }
            if let error = query["error"] { throw error == "access_denied" ? ChatGPTSignInError.declined : .incomplete }
            if let saved = registration?.clientID, let issued = query["client_id"], issued != saved { throw ChatGPTSignInError.incomplete }
            guard let clientID = registration?.clientID ?? query["client_id"], clientID.hasPrefix("oaiapp_"), let code = query["code"] else { throw ChatGPTSignInError.incomplete }
            return (clientID, code)
        }
    }

    public static func authorizeURL(_ server: Server, attempt: Attempt, hostID: String) -> URL {
        var items: [URLQueryItem] = [.init(name: "client_id", value: attempt.registration?.clientID ?? "dynamic_agent_client")]
        if let saved = attempt.registration {
            items += [saved.email.map { URLQueryItem(name: "login_hint", value: $0) }, saved.tokens.map { URLQueryItem(name: "id_token_hint", value: $0.idToken) },
                      saved.tokens != nil && !saved.sharesPlan ? URLQueryItem(name: "prompt", value: "consent") : nil].compactMap { $0 }
        } else {
            items.append(.init(name: "agent_name_hint", value: "msgblast"))
        }
        items += [("ext_agent_host_id", hostID), ("response_type", "code"), ("redirect_uri", attempt.redirect.absoluteString), ("scope", scope),
                  ("resource", resource), ("state", attempt.state), ("nonce", attempt.nonce), ("code_challenge_method", "S256"),
                  ("code_challenge", attempt.challenge)].map { URLQueryItem(name: $0.0, value: $0.1) }
        var components = URLComponents(url: server.authorizationEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = items
        // URLComponents leaves `+` alone, which a form decoder reads as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url!
    }

    static func discover(session: URLSession) async throws -> Server {
        guard let (data, response) = try? await session.data(from: discovery), (response as? HTTPURLResponse)?.statusCode == 200 else { throw ChatGPTSignInError.unavailable }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let server = try? decoder.decode(Server.self, from: data), server.issuer == issuer,
              ([server.authorizationEndpoint, server.tokenEndpoint, server.jwksUri] + [server.revocationEndpoint].compactMap { $0 })
                .allSatisfy({ $0.scheme == "https" && $0.host == "auth.openai.com" }) else { throw ChatGPTSignInError.unverified }
        return server
    }

    static func keys(_ server: Server, session: URLSession) async throws -> ChatGPTIDToken.KeySet {
        guard let (data, response) = try? await session.data(from: server.jwksUri), (response as? HTTPURLResponse)?.statusCode == 200,
              let keys = try? JSONDecoder().decode(ChatGPTIDToken.KeySet.self, from: data) else { throw ChatGPTSignInError.unavailable }
        return keys
    }

    /// A form POST. Returns the status and JSON body, or nil for a network failure.
    static func post(_ url: URL, _ form: [String: String], session: URLSession) async -> (Int, [String: Any])? {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        var allowed = CharacterSet.alphanumerics; allowed.insert(charactersIn: "-._~")
        request.httpBody = Data(form.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }.joined(separator: "&").utf8)
        guard let (data, response) = try? await session.data(for: request), let http = response as? HTTPURLResponse else { return nil }
        return (http.statusCode, (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:])
    }

    /// Reads a 200 token response. Nil when it is not a bearer token set.
    static func tokens(_ json: [String: Any], now: Date, previous: ChatGPTRegistration.Tokens? = nil) -> ChatGPTRegistration.Tokens? {
        guard let access = json["access_token"] as? String, !access.isEmpty, (json["token_type"] as? String)?.lowercased() == "bearer",
              let lifetime = json["expires_in"] as? Double, lifetime > 0, let scope = json["scope"] as? String,
              let idToken = previous?.idToken ?? json["id_token"] as? String else { return nil }
        let earliest: Date? = switch json["earliest_refresh_at"] {
        case let seconds as Double: Date(timeIntervalSince1970: seconds)
        case let text as String: ISO8601DateFormatter().date(from: text)
        default: nil
        }
        return .init(accessToken: access, refreshToken: json["refresh_token"] as? String ?? previous?.refreshToken, idToken: idToken,
                     expiresAt: now.addingTimeInterval(lifetime), earliestRefreshAt: earliest, scopes: scope.split(separator: " ").map(String.init))
    }

    static let terminalRefreshErrors: Set<String> = ["invalid_grant", "invalid_refresh_token", "token_expired", "refresh_token_expired",
                                                     "refresh_token_invalidated", "refresh_token_reused"]
}
