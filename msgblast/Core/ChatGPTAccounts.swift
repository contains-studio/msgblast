import Foundation
import LocalAuthentication
import Security

/// The ChatGPT accounts this build has signed in, in the Keychain: one item per registration and an
/// index with this Mac's host id and the active account. Only this actor refreshes tokens, one at a time.
public actor ChatGPTAccounts {
    public struct Storage: Sendable {
        public var read: @Sendable (String) throws -> Data?
        public var write: @Sendable (String, Data) throws -> Void
        public init(read: @escaping @Sendable (String) throws -> Data?, write: @escaping @Sendable (String, Data) throws -> Void) {
            self.read = read; self.write = write
        }
    }

    struct Index: Codable { var hostID: String, active: String?, clientIDs: [String] }

    private let storage: Storage, session: URLSession, now: @Sendable () -> Date
    private var server: ChatGPTTokenSharing.Server?
    /// Rotated tokens that could not be saved yet. The old refresh token no longer works.
    private var unsaved: [String: ChatGPTRegistration] = [:]
    private var refreshing: [String: Task<ChatGPTRegistration, Error>] = [:]

    public init(storage: Storage, session: URLSession = .shared, now: @escaping @Sendable () -> Date = Date.init) {
        self.storage = storage; self.session = session; self.now = now
    }

    /// The account in use, or the last one used. Its `tokens` are nil after disconnecting.
    public func current() throws -> ChatGPTRegistration? {
        try index().active.flatMap(registration)
    }

    /// The browser URL for a sign-in. Signs the current account in again unless `newAccount` is set.
    public func signInURL(redirect: URL, newAccount: Bool = false) async throws -> (url: URL, attempt: ChatGPTTokenSharing.Attempt) {
        let hostID = try index().hostID
        let attempt = ChatGPTTokenSharing.Attempt(redirect: redirect, registration: newAccount ? nil : try current())
        return (ChatGPTTokenSharing.authorizeURL(try await endpoints(), attempt: attempt, hostID: hostID), attempt)
    }

    /// Exchanges the loopback callback's code, verifies the identity, and makes the account active.
    public func finishSignIn(_ callback: URL, attempt: ChatGPTTokenSharing.Attempt) async throws -> ChatGPTRegistration {
        let query = Dictionary(URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems?.map { ($0.name, $0.value ?? "") } ?? [], uniquingKeysWith: { a, _ in a })
        guard query["state"] == attempt.state else { throw ChatGPTSignInError.unverified }
        if let error = query["error"] { throw error == "access_denied" ? ChatGPTSignInError.declined : .incomplete }
        let saved = attempt.registration
        if let saved, let issued = query["client_id"], issued != saved.clientID { throw ChatGPTSignInError.incomplete }
        guard let clientID = saved?.clientID ?? query["client_id"], clientID.hasPrefix("oaiapp_"), let code = query["code"] else { throw ChatGPTSignInError.incomplete }
        let server = try await endpoints()
        let form = ["grant_type": "authorization_code", "client_id": clientID, "code": code, "code_verifier": attempt.verifier,
                    "redirect_uri": attempt.redirect.absoluteString, "resource": ChatGPTTokenSharing.resource]
        guard let (status, json) = await ChatGPTTokenSharing.post(server.tokenEndpoint, form, session: session) else { throw ChatGPTSignInError.unavailable }
        guard status == 200 else {
            if json["error"] as? String == "invalid_grant" {
                // Keep a newly issued client id, so the next sign-in reuses it.
                if saved == nil { try save(ChatGPTRegistration(clientID: clientID)) }
                throw ChatGPTSignInError.codeExpired
            }
            throw json["error"] as? String == "invalid_client" ? ChatGPTSignInError.rejectedClient : .incomplete
        }
        guard let tokens = ChatGPTTokenSharing.tokens(json, now: now()) else { throw ChatGPTSignInError.unverified }
        var keys = try await ChatGPTTokenSharing.keys(server, session: session)
        if ChatGPTIDToken.needsNewKeys(tokens.idToken, keys: keys) { keys = try await ChatGPTTokenSharing.keys(server, session: session) }
        guard let identity = try? ChatGPTIDToken.verify(tokens.idToken, keys: keys, issuer: server.issuer, audience: clientID, nonce: attempt.nonce, now: now())
        else { throw ChatGPTSignInError.unverified }
        let expected = try saved?.subject ?? registration(clientID)?.subject
        guard expected == nil || expected == identity.subject else { throw ChatGPTSignInError.differentAccount }
        let account = ChatGPTRegistration(clientID: clientID, subject: identity.subject, email: identity.email, tokens: tokens)
        try save(account)
        unsaved[clientID] = nil
        return account
    }

    /// A current access token for the active account, refreshed when it is about to expire.
    public func accessToken() async throws -> String {
        guard let account = try current(), let tokens = account.tokens else { throw ChatGPTSignInError.signedOut }
        guard account.sharesPlan else { throw ChatGPTSignInError.sharingOff }
        let date = now()
        if tokens.expiresAt.timeIntervalSince(date) > 60 { return tokens.accessToken }
        if let earliest = tokens.earliestRefreshAt, earliest > date {
            guard tokens.expiresAt > date else { throw ChatGPTSignInError.notYet }
            return tokens.accessToken
        }
        let task = refreshing[account.clientID] ?? Task { try await refresh(account) }
        refreshing[account.clientID] = task
        defer { refreshing[account.clientID] = nil }
        guard let fresh = try await task.value.tokens, fresh.scopes.contains(ChatGPTTokenSharing.sharingScope) else { throw ChatGPTSignInError.sharingOff }
        return fresh.accessToken
    }

    private func refresh(_ account: ChatGPTRegistration) async throws -> ChatGPTRegistration {
        guard let tokens = account.tokens, let refreshToken = tokens.refreshToken else { throw clear(account, ChatGPTSignInError.expired) }
        let form = ["grant_type": "refresh_token", "client_id": account.clientID, "refresh_token": refreshToken, "resource": ChatGPTTokenSharing.resource]
        guard let (status, json) = await ChatGPTTokenSharing.post(try await endpoints().tokenEndpoint, form, session: session) else { throw ChatGPTSignInError.unavailable }
        guard status == 200 else {
            let error = json["error"] as? String ?? ""
            if ChatGPTTokenSharing.terminalRefreshErrors.contains(error) { throw clear(account, ChatGPTSignInError.expired) }
            throw error == "invalid_client" ? ChatGPTSignInError.rejectedClient : .unavailable
        }
        guard let next = ChatGPTTokenSharing.tokens(json, now: now(), previous: tokens) else { throw ChatGPTSignInError.unavailable }
        var renewed = account
        renewed.tokens = next
        unsaved[account.clientID] = renewed
        if (try? save(renewed)) != nil { unsaved[account.clientID] = nil }
        return renewed
    }

    /// Revokes the refresh token and forgets the tokens, keeping the account's client id.
    /// Returns false when OpenAI did not confirm the revocation, so the person can disconnect in ChatGPT Settings.
    public func disconnect() async throws -> Bool {
        guard let account = try current() else { return true }
        _ = try? await refreshing[account.clientID]?.value
        let latest = try registration(account.clientID) ?? account
        var confirmed = latest.tokens?.refreshToken == nil
        if let token = latest.tokens?.refreshToken, let endpoint = try? await endpoints().revocationEndpoint {
            let form = ["token": token, "token_type_hint": "refresh_token", "client_id": account.clientID]
            for delay in [0.25, 1, 0] {
                let status = await ChatGPTTokenSharing.post(endpoint, form, session: session)?.0
                confirmed = status == 200
                guard !confirmed, (status ?? 500) >= 500, delay > 0 else { break }
                try? await Task.sleep(for: .seconds(delay))
            }
        }
        var signedOut = latest
        signedOut.tokens = nil
        try save(signedOut)
        unsaved[account.clientID] = nil
        return confirmed
    }

    private func clear(_ account: ChatGPTRegistration, _ error: ChatGPTSignInError) -> ChatGPTSignInError {
        var cleared = account
        cleared.tokens = nil
        unsaved[account.clientID] = nil
        return (try? save(cleared)) == nil ? .storage : error
    }

    private func endpoints() async throws -> ChatGPTTokenSharing.Server {
        if let server { return server }
        let found = try await ChatGPTTokenSharing.discover(session: session)
        server = found
        return found
    }

    /// The index, created with a new host id before the first sign-in. A failed read throws rather than starting over.
    func index() throws -> Index {
        if let data = try storage.read("index") {
            guard let index = try? JSONDecoder().decode(Index.self, from: data) else { throw ChatGPTSignInError.storage }
            return index
        }
        let index = Index(hostID: "urn:uuid:\(UUID().uuidString.lowercased())", active: nil, clientIDs: [])
        try write("index", index)
        return index
    }

    private func registration(_ clientID: String) throws -> ChatGPTRegistration? {
        if let pending = unsaved[clientID] { return pending }
        guard let data = try storage.read("registration." + clientID) else { return nil }
        guard let account = try? JSONDecoder().decode(ChatGPTRegistration.self, from: data), account.clientID == clientID else { throw ChatGPTSignInError.storage }
        return account
    }

    private func save(_ account: ChatGPTRegistration) throws {
        try write("registration." + account.clientID, account)
        var index = try index()
        index.active = account.clientID
        if !index.clientIDs.contains(account.clientID) { index.clientIDs.append(account.clientID) }
        try write("index", index)
    }

    private func write(_ key: String, _ value: some Encodable) throws {
        do { try storage.write(key, try JSONEncoder().encode(value)) } catch { throw ChatGPTSignInError.storage }
    }
}

extension ChatGPTAccounts.Storage {
    /// Generic passwords in the data protection keychain, never shown in a prompt.
    public static func keychain(service: String) -> Self {
        @Sendable func query(_ key: String) -> [String: Any] {
            let context = LAContext()
            context.interactionNotAllowed = true
            return [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key,
                    kSecUseDataProtectionKeychain as String: true, kSecUseAuthenticationContext as String: context]
        }
        return Self(read: { key in
            var item = query(key); item[kSecReturnData as String] = true; item[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            let status = SecItemCopyMatching(item as CFDictionary, &result)
            if status == errSecItemNotFound { return nil }
            guard status == errSecSuccess, let data = result as? Data else { throw ChatGPTSignInError.storage }
            return data
        }, write: { key, data in
            var item = query(key)
            var status = SecItemUpdate(item as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            if status == errSecItemNotFound {
                item[kSecValueData as String] = data
                item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                status = SecItemAdd(item as CFDictionary, nil)
            }
            guard status == errSecSuccess else { throw ChatGPTSignInError.storage }
        })
    }
}
