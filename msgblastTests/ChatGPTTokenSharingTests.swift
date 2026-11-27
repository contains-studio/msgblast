import XCTest
@testable import msgblastCore

/// Sign in with ChatGPT against a fixture of OpenAI's endpoints, with ID tokens signed by a key made for
/// the test. The callback goes through the real loopback listener. No real account or token is used.
final class ChatGPTTokenSharingTests: XCTestCase {
    private let fixture = ChatGPTFixtureKey()
    private var requests: [(path: String, form: [String: String])] = []
    private var tokenReplies: [(Int, [String: Any])] = []
    private var saved: [String: Data] = [:]
    private var clock = Date(timeIntervalSince1970: 2_000_000_000)

    private func accounts() -> ChatGPTAccounts {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [WantStub.self]
        WantStub.handler = { [unowned self] request in self.serve(request) }
        let store = Storage(self)
        return ChatGPTAccounts(storage: .init(read: { store.owner.saved[$0] }, write: { store.owner.saved[$0] = $1 }),
                               session: URLSession(configuration: config), now: { store.owner.clock })
    }
    private final class Storage: @unchecked Sendable { unowned let owner: ChatGPTTokenSharingTests; init(_ owner: ChatGPTTokenSharingTests) { self.owner = owner } }

    private func serve(_ request: URLRequest) -> (Int, [String: String], Data) {
        let path = request.url!.path
        let form = Dictionary(uniqueKeysWithValues: (URLComponents(string: "?" + String(decoding: WantStub.body(request), as: UTF8.self))?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        requests.append((path, form))
        func json(_ status: Int, _ body: Any) -> (Int, [String: String], Data) { (status, ["Content-Type": "application/json"], try! JSONSerialization.data(withJSONObject: body)) }
        switch path {
        case "/.well-known/openid-configuration":
            return json(200, ["issuer": "https://auth.openai.com", "authorization_endpoint": "https://auth.openai.com/api/accounts/authorize",
                              "token_endpoint": "https://auth.openai.com/api/accounts/oauth/token", "jwks_uri": "https://auth.openai.com/.well-known/jwks.json",
                              "revocation_endpoint": "https://auth.openai.com/api/accounts/oauth/revoke"])
        case "/.well-known/jwks.json":
            return json(200, ["keys": [fixture.jwk]])
        default:
            let (status, body) = tokenReplies.removeFirst()
            return json(status, body)
        }
    }

    private func idToken(audience: String, nonce: String, subject: String = "user-1") -> String {
        fixture.sign(ChatGPTFixtureKey.claims(audience: audience, nonce: nonce, at: clock, subject: subject))
    }

    private func tokens(_ id: String, refresh: String = "r1", scope: String = ChatGPTTokenSharing.scope) -> [String: Any] {
        ["access_token": "a-" + refresh, "refresh_token": refresh, "id_token": id, "token_type": "Bearer", "expires_in": 3600, "scope": scope]
    }

    private func query(_ url: URL) -> [String: String] {
        Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
    }

    /// Signs in through the loopback listener; the "browser" answers with `reply(authorize query)`.
    @MainActor private func signIn(_ accounts: ChatGPTAccounts, newAccount: Bool = false, reply: ([String: String]) -> String) async throws -> (ChatGPTRegistration, [String: String]) {
        let callback = WantOAuthCallback(path: ChatGPTTokenSharing.callbackPath)
        defer { callback.stop() }
        let redirect = try await callback.start()
        let (url, attempt) = try await accounts.signInURL(redirect: redirect, newAccount: newAccount)
        let sent = query(url)
        let browser = URL(string: redirect.absoluteString + "?" + reply(sent))!
        Task { _ = try? await URLSession.shared.data(from: browser) }
        return (try await accounts.finishSignIn(try await callback.wait(), attempt: attempt), sent)
    }

    @MainActor func testFirstSignInRegistersThenReusesTheIssuedClient() async throws {
        let accounts = accounts()
        var nonce = ""
        let (account, first) = try await signIn(accounts) { sent in
            nonce = sent["nonce"]!
            tokenReplies = [(200, tokens(idToken(audience: "oaiapp_1", nonce: nonce)))]
            return "code=c1&state=\(sent["state"]!)&client_id=oaiapp_1&scope=openid"
        }
        XCTAssertEqual(first["client_id"], "dynamic_agent_client")
        XCTAssertEqual(first["agent_name_hint"], "msgblast")
        XCTAssertTrue(first["ext_agent_host_id"]!.hasPrefix("urn:uuid:"))
        XCTAssertEqual(first["scope"], "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct")
        XCTAssertEqual(first["resource"], "https://api.openai.com/v1")
        XCTAssertEqual(first["code_challenge_method"], "S256")
        XCTAssertTrue(first["redirect_uri"]!.hasPrefix("http://127.0.0.1:"))
        XCTAssertTrue(first["redirect_uri"]!.hasSuffix("/auth/callback"))
        XCTAssertEqual(account.subject, "user-1")
        XCTAssertTrue(account.sharesPlan)
        let exchange = try XCTUnwrap(requests.last { $0.path == "/api/accounts/oauth/token" }).form
        XCTAssertEqual(exchange["client_id"], "oaiapp_1")
        XCTAssertEqual(exchange["redirect_uri"], first["redirect_uri"])
        XCTAssertNotNil(exchange["code_verifier"])

        let (_, again) = try await signIn(accounts) { sent in
            tokenReplies = [(200, tokens(idToken(audience: "oaiapp_1", nonce: sent["nonce"]!), refresh: "r2"))]
            return "code=c2&state=\(sent["state"]!)"
        }
        XCTAssertEqual(again["client_id"], "oaiapp_1")
        XCTAssertNil(again["agent_name_hint"])
        XCTAssertEqual(again["login_hint"], "person@example.com")
        XCTAssertNotNil(again["id_token_hint"])
        XCTAssertEqual(again["ext_agent_host_id"], first["ext_agent_host_id"])
        XCTAssertNotEqual(again["state"], first["state"])
        XCTAssertNotEqual(again["nonce"], nonce)
    }

    @MainActor func testRejectsUnverifiedIdentitiesAndAnotherAccount() async throws {
        let accounts = accounts()
        do {
            _ = try await signIn(accounts) { sent in
                tokenReplies = [(200, tokens(idToken(audience: "oaiapp_1", nonce: "replayed")))]
                return "code=c&state=\(sent["state"]!)&client_id=oaiapp_1"
            }
            XCTFail("Accepted another sign-in's ID token")
        } catch { XCTAssertEqual(error as? ChatGPTSignInError, .unverified) }
        do { _ = try await signIn(accounts) { "error=access_denied&state=\($0["state"]!)" }; XCTFail() } catch { XCTAssertEqual(error as? ChatGPTSignInError, .declined) }
        do { _ = try await signIn(accounts) { _ in "code=c&state=forged&client_id=oaiapp_1" }; XCTFail() } catch { XCTAssertEqual(error as? ChatGPTSignInError, .unverified) }

        let (first, _) = try await signIn(accounts) { sent in
            tokenReplies = [(200, tokens(idToken(audience: "oaiapp_1", nonce: sent["nonce"]!)))]
            return "code=c&state=\(sent["state"]!)&client_id=oaiapp_1"
        }
        do {
            _ = try await signIn(accounts) { sent in
                tokenReplies = [(200, tokens(idToken(audience: "oaiapp_1", nonce: sent["nonce"]!, subject: "user-2"), refresh: "r9"))]
                return "code=c&state=\(sent["state"]!)"
            }
            XCTFail("Accepted another account")
        } catch { XCTAssertEqual(error as? ChatGPTSignInError, .differentAccount) }
        let current = try await accounts.current()
        XCTAssertEqual(current, first)
    }

    func testUnreadableStorageIsNotReplaced() async {
        let accounts = ChatGPTAccounts(storage: .init(read: { _ in throw ChatGPTSignInError.storage }, write: { _, _ in XCTFail("overwrote storage") }))
        do { _ = try await accounts.current(); XCTFail() } catch { XCTAssertEqual(error as? ChatGPTSignInError, .storage) }
    }
}
