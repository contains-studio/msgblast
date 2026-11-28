import Foundation
import LocalAuthentication
import Security

/// The ChatGPT accounts this build has signed in, in the Keychain: one item per registration and an
/// index with this Mac's host id and the active account.
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

    public init(storage: Storage, session: URLSession = .shared, now: @escaping @Sendable () -> Date = Date.init) {
        self.storage = storage; self.session = session; self.now = now
    }

    /// The account in use, or the last one used. Its `tokens` are nil after disconnecting.
    public func current() throws -> ChatGPTRegistration? {
        try savedIndex()?.active.flatMap(registration)
    }

    /// The browser URL for a sign-in. Signs the current account in again unless `newAccount` is set.
    public func signInURL(redirect: URL, newAccount: Bool = false) async throws -> (url: URL, attempt: ChatGPTTokenSharing.Attempt) {
        let hostID = try index().hostID
        let attempt = ChatGPTTokenSharing.Attempt(redirect: redirect, registration: newAccount ? nil : try current())
        return (ChatGPTTokenSharing.authorizeURL(try await endpoints(), attempt: attempt, hostID: hostID), attempt)
    }

    /// Exchanges the loopback callback's code, verifies the identity, and makes the account active.
    public func finishSignIn(_ callback: URL, attempt: ChatGPTTokenSharing.Attempt) async throws -> ChatGPTRegistration {
        let (clientID, code) = try attempt.clientAndCode(callback)
        let saved = attempt.registration
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
        let identity = try await verify(tokens.idToken, clientID: clientID, nonce: attempt.nonce, server: server)
        let expected = try saved?.subject ?? registration(clientID)?.subject
        guard expected == nil || expected == identity.subject else { throw ChatGPTSignInError.differentAccount }
        let account = ChatGPTRegistration(clientID: clientID, subject: identity.subject, email: identity.email, tokens: tokens)
        try save(account)
        return account
    }

    private func verify(_ idToken: String, clientID: String, nonce: String, server: ChatGPTTokenSharing.Server) async throws -> ChatGPTIDToken.Identity {
        var keys = try await ChatGPTTokenSharing.keys(server, session: session)
        if ChatGPTIDToken.needsNewKeys(idToken, keys: keys) { keys = try await ChatGPTTokenSharing.keys(server, session: session) }
        guard let identity = try? ChatGPTIDToken.verify(idToken, keys: keys, issuer: server.issuer, audience: clientID, nonce: nonce, now: now())
        else { throw ChatGPTSignInError.unverified }
        return identity
    }

    private func endpoints() async throws -> ChatGPTTokenSharing.Server {
        if let server { return server }
        let found = try await ChatGPTTokenSharing.discover(session: session)
        server = found
        return found
    }

    /// The index, created with a new host id before the first sign-in. A failed read throws rather than starting over.
    func index() throws -> Index {
        if let index = try savedIndex() { return index }
        let index = Index(hostID: "urn:uuid:\(UUID().uuidString.lowercased())", active: nil, clientIDs: [])
        try write("index", index)
        return index
    }

    /// The index if one was saved. Reading never writes, so showing the account works without storage access.
    private func savedIndex() throws -> Index? {
        guard let data = try storage.read("index") else { return nil }
        guard let index = try? JSONDecoder().decode(Index.self, from: data) else { throw ChatGPTSignInError.storage }
        return index
    }

    private func registration(_ clientID: String) throws -> ChatGPTRegistration? {
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
        do { try storage.write(key, try JSONEncoder().encode(value)) } catch let error as ChatGPTSignInError { throw error } catch { throw ChatGPTSignInError.storage }
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
            // An app without a Keychain access group entitlement gets errSecMissingEntitlement (-34018).
            if status == errSecMissingEntitlement { throw ChatGPTSignInError.storageUnavailable }
            guard status == errSecSuccess else { throw ChatGPTSignInError.storage }
        })
    }
}
