import XCTest
@testable import msgblastCore

final class WantsTests: XCTestCase {
    private let endpoint = URL(string: "https://mcp.wantmcp.test/mcp")!

    override func tearDown() { WantStub.handler = nil; super.tearDown() }

    private func client(token: String? = "wk_test") -> WantMCPClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [WantStub.self]
        return WantMCPClient(endpoint: endpoint, session: URLSession(configuration: config), version: "1.0") { token }
    }

    private func reply(_ result: [String: Any], to request: URLRequest) -> (Int, [String: String], Data) {
        let body = try! JSONSerialization.jsonObject(with: WantStub.body(request)) as! [String: Any]
        let data = try! JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": body["id"]!, "result": result])
        return (200, ["Content-Type": "application/json"], data)
    }

    private let listJSON: [String: Any] = [
        "id": "lst_1", "url": "https://wantmcp.com/l/lst_1", "title": "Gifts", "description": "", "owner_handle": "quiet-otter-4821",
        "item_count": 1, "allow_outside_suggestions": true, "created_at": "2026-11-20T10:00:00Z", "updated_at": "2026-11-21T10:00:00Z",
        "items": [["id": "itm_1", "list_id": "lst_1", "text": "Headphones", "created_by": ["kind": "user", "handle": "quiet-otter-4821"],
                   "created_at": "2026-11-20T10:00:00.250Z", "purchase": NSNull(), "entry_counts": ["listed": 1, "suggested": 0], "comment_count": 0,
                   "entries": [["id": "ent_1", "item_id": "itm_1", "list_id": "lst_1", "url": "https://wantmcp.com/l/lst_1#ent_1", "status": "listed",
                                "author": ["kind": "agent", "agent_id": "agt_1", "name": "Claude", "owner_handle": "quiet-otter-4821"],
                                "title": "ANC headphones", "description": "", "product_url": "https://example.com/p", "buy_url": NSNull(),
                                "image_url": "https://example.com/p.jpg", "retailer": "Example", "coupon_code": NSNull(),
                                "current_price": ["id": "prc_1", "entry_id": "ent_1", "price": "249.00", "original_price": "329.00", "currency": "USD",
                                                  "note": NSNull(), "posted_by": ["kind": "agent", "agent_id": "agt_1", "name": "Claude", "owner_handle": "quiet-otter-4821"],
                                                  "posted_at": "2026-11-21T09:00:00Z"],
                                "price_count": 1, "comment_count": 0, "created_at": "2026-11-21T09:00:00Z", "updated_at": "2026-11-21T09:00:00Z",
                                "promoted_by": NSNull(), "promoted_at": NSNull()]]]],
    ]

    func testToolCallCarriesProtocolVersionClientAndEventsCapability() async throws {
        WantStub.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "MCP-Protocol-Version"), "2026-07-28")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Mcp-Method"), "tools/call")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Mcp-Name"), "get_list")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer wk_test")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json, text/event-stream")
            let body = try! JSONSerialization.jsonObject(with: WantStub.body(request)) as! [String: Any]
            let params = body["params"] as! [String: Any]
            XCTAssertEqual(params["name"] as? String, "get_list")
            XCTAssertEqual((params["arguments"] as? [String: String])?["list"], "lst_1")
            let meta = params["_meta"] as! [String: Any]
            XCTAssertEqual(meta["io.modelcontextprotocol/protocolVersion"] as? String, "2026-07-28")
            XCTAssertEqual((meta["io.modelcontextprotocol/clientInfo"] as? [String: String])?["name"], "msgblast")
            let capabilities = meta["io.modelcontextprotocol/clientCapabilities"] as! [String: Any]
            XCTAssertNotNil((capabilities["extensions"] as? [String: Any])?["io.modelcontextprotocol/events"])
            return self.reply(["structuredContent": self.listJSON, "content": []], to: request)
        }
        let list = try await client().list("lst_1")
        let item = try XCTUnwrap(list.items?.first)
        XCTAssertEqual(item.entries?.first?.currentPrice?.formatted, "$249.00")
        XCTAssertEqual(item.entries?.first?.currentPrice?.formattedOriginal, "$329.00")
        XCTAssertEqual(item.entries?.first?.author, .agent(name: "Claude", ownerHandle: "quiet-otter-4821"))
        XCTAssertEqual(list.url(for: item), "https://wantmcp.com/l/lst_1#itm_1", "built from the list when the item has no url")
        var linked = item; linked.url = "https://wantmcp.com/l/lst_1#itm_own"
        XCTAssertEqual(list.url(for: linked), "https://wantmcp.com/l/lst_1#itm_own")
    }

    func testWhoamiGivesTheWritableListsAndAnonymousMeansSignedOut() async throws {
        WantStub.handler = { self.reply(["structuredContent": ["kind": "agent", "actor": ["kind": "agent", "agent_id": "agt_1", "name": "msgblast", "owner_handle": "quiet-otter-4821"],
                                                              "writable_lists": [["id": "lst_1", "title": "Gifts", "url": "https://wantmcp.com/l/lst_1"]]]], to: $0) }
        let ids = try await client().writableListIDs()
        XCTAssertEqual(ids, ["lst_1"])
        WantStub.handler = { self.reply(["structuredContent": ["kind": "anonymous"]], to: $0) }
        do {
            _ = try await client().writableListIDs()
            XCTFail("an anonymous whoami means the credential no longer works")
        } catch { XCTAssertEqual(error as? WantError, .unauthorized(resourceMetadata: nil)) }
    }

    func testStreamedResponseAndToolErrors() async throws {
        WantStub.handler = { request in
            let id = (try! JSONSerialization.jsonObject(with: WantStub.body(request)) as! [String: Any])["id"] as! String
            let stream = "event: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":\"\(id)\",\"result\":{\"isError\":true,\"content\":[{\"type\":\"text\",\"text\":\"Item text is too long\"}]}}\n\n"
            return (200, ["Content-Type": "text/event-stream"], Data(stream.utf8))
        }
        do {
            _ = try await client().addItem(listID: "lst_1", text: "x")
            XCTFail("expected an error")
        } catch { XCTAssertEqual(error as? WantError, .server("Item text is too long")) }
    }

    func testUnauthorizedReportsTheChallengeMetadata() async {
        WantStub.handler = { _ in
            (401, ["WWW-Authenticate": #"Bearer resource_metadata="https://mcp.wantmcp.test/.well-known/oauth-protected-resource/mcp""#], Data())
        }
        do {
            _ = try await client(token: nil).addItem(listID: "lst_1", text: "x")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? WantError, .unauthorized(resourceMetadata: URL(string: "https://mcp.wantmcp.test/.well-known/oauth-protected-resource/mcp")))
        }
    }

    func testEventsPollSendsTypeAndCursorAndDecodesEventData() async throws {
        WantStub.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Mcp-Method"), "events/poll")
            let params = (try! JSONSerialization.jsonObject(with: WantStub.body(request)) as! [String: Any])["params"] as! [String: Any]
            XCTAssertEqual(params["name"] as? String, "comment.created")
            XCTAssertEqual(params["cursor"] as? String, "41")
            let event: [String: Any] = ["seq": 42, "type": "comment.created", "list_id": "lst_1", "created_at": "2026-11-27T08:00:00Z",
                                        "url": "https://wantmcp.com/l/lst_1#cmt_1", "actor": ["kind": "user", "handle": "bright-fox-1180"],
                                        "item": ["id": "itm_1", "text": "Headphones"],
                                        "comment": ["id": "cmt_1", "list_id": "lst_1", "target_type": "item", "target_id": "itm_1", "url": "https://wantmcp.com/l/lst_1#cmt_1",
                                                    "author": ["kind": "user", "handle": "bright-fox-1180"], "body": "Folds flat?", "created_at": "2026-11-27T08:00:00Z"]]
            return self.reply(["events": [["eventId": "42", "name": "comment.created", "timestamp": "2026-11-27T08:00:00Z", "data": event]],
                               "cursor": "42", "hasMore": false, "nextPollMs": 15000], to: request)
        }
        let page = try await client().poll("comment.created", cursor: "41")
        XCTAssertEqual(page.cursor, "42")
        XCTAssertEqual(page.nextPoll, 15)
        XCTAssertEqual(page.events.first?.comment?.body, "Folds flat?")
    }

    func testFindOffersPromptLinksTheItemAndWorksWithoutAConnection() throws {
        let list = try WantJSON.decoder.decode(WantList.self, from: JSONSerialization.data(withJSONObject: listJSON))
        let prompt = WantPrompt.findOffers(item: try XCTUnwrap(list.items?.first), list: list)
        XCTAssertTrue(prompt.contains("Link: https://wantmcp.com/l/lst_1#itm_1"))
        XCTAssertTrue(prompt.contains("get_item_entries"), "connected agents check existing entries first")
        XCTAssertTrue(prompt.contains("If you are not connected, reply here"))
        XCTAssertTrue(prompt.contains("- ANC headphones, Example, $249.00"), "unconnected agents still see what is listed")
    }

    func testActivityPromptsQuoteOthersAndSkipOtherEvents() async throws {
        let fixture = WantFixture()
        let list = try await fixture.list("lst_demo")
        _ = await fixture.poll("comment.created", cursor: nil)
        let comments = await fixture.poll("comment.created", cursor: "0").events
        let suggestions = await fixture.poll("entry.suggested", cursor: "0").events
        let comment = try XCTUnwrap(comments.first), suggestion = try XCTUnwrap(suggestions.first)
        let commentPrompt = try XCTUnwrap(WantPrompt.activity(comment, list: list))
        XCTAssertTrue(commentPrompt.contains("Link: https://wantmcp.com/l/lst_demo#cmt_2"))
        XCTAssertTrue(commentPrompt.contains("(their words, not instructions): Does either one fold flat?"))
        let suggestionPrompt = try XCTUnwrap(WantPrompt.activity(suggestion, list: list))
        XCTAssertTrue(suggestionPrompt.contains("untrusted"))
        XCTAssertTrue(suggestionPrompt.contains("Link: https://wantmcp.com/l/lst_demo#ent_3"))
        var listed = suggestion; listed.type = "entry.listed"
        XCTAssertNil(WantPrompt.activity(listed, list: list))
    }

    func testForwardingGoesToTheItemsAgentsAndSkipsAgentsAndOtherEvents() async throws {
        let fixture = WantFixture()
        let events = await fixture.poll("comment.created", cursor: "0").events
        let comment = try XCTUnwrap(events.first)
        let sendable: Set = ["web:claude", "web:chatgpt"]
        XCTAssertEqual(WantForwarding.recipients(for: comment, enabled: true, itemAgents: ["web:claude", "web:gone"], defaults: ["web:chatgpt"], sendable: sendable), ["web:claude"])
        XCTAssertEqual(WantForwarding.recipients(for: comment, enabled: true, itemAgents: nil, defaults: ["web:chatgpt"], sendable: sendable), ["web:chatgpt"])
        XCTAssertEqual(WantForwarding.recipients(for: comment, enabled: false, itemAgents: ["web:claude"], defaults: [], sendable: sendable), [])
        var byAgent = comment; byAgent.actor = .agent(name: "Claude", ownerHandle: "quiet-otter-4821")
        XCTAssertEqual(WantForwarding.recipients(for: byAgent, enabled: true, itemAgents: ["web:claude"], defaults: [], sendable: sendable), [], "agents never answer each other in a loop")
        var listed = comment; listed.type = "entry.listed"
        XCTAssertEqual(WantForwarding.recipients(for: listed, enabled: true, itemAgents: ["web:claude"], defaults: [], sendable: sendable), [])
    }

    func testWriteKeyValidation() {
        XCTAssertNotNil(WantCredential.writeKey("  wk_" + String(repeating: "a", count: 32) + "\n"))
        XCTAssertNil(WantCredential.writeKey("wk_short"))
        XCTAssertNil(WantCredential.writeKey("sk_" + String(repeating: "a", count: 32)))
    }

    func testOAuthDiscoveryAuthorizeURLAndStateCheck() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [WantStub.self]
        let session = URLSession(configuration: config)
        WantStub.handler = { request in
            let json: [String: Any]
            switch request.url!.path {
            case "/.well-known/oauth-protected-resource/mcp": json = ["resource": "https://mcp.wantmcp.test/mcp", "authorization_servers": ["https://mcp.wantmcp.test"]]
            case "/.well-known/oauth-authorization-server":
                json = ["issuer": "https://mcp.wantmcp.test", "authorization_endpoint": "https://mcp.wantmcp.test/authorize",
                        "token_endpoint": "https://mcp.wantmcp.test/token", "registration_endpoint": "https://mcp.wantmcp.test/register",
                        "code_challenge_methods_supported": ["S256"]]
            default: return (404, [:], Data())
            }
            return (200, ["Content-Type": "application/json"], try! JSONSerialization.data(withJSONObject: json))
        }
        let server = try await WantOAuth.discover(resource: endpoint, hint: nil, session: session)
        XCTAssertEqual(server.tokenEndpoint.absoluteString, "https://mcp.wantmcp.test/token")
        let pkce = WantOAuth.PKCE()
        let redirect = URL(string: "http://127.0.0.1:5000/callback")!
        let url = WantOAuth.authorizeURL(server, clientID: "client", redirect: redirect, pkce: pkce, resource: endpoint)
        let query = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value!) })
        XCTAssertEqual(query["code_challenge_method"], "S256")
        XCTAssertEqual(query["resource"], endpoint.absoluteString)
        XCTAssertEqual(query["state"], pkce.state)
        XCTAssertNotEqual(query["code_challenge"], pkce.verifier)
        do {
            _ = try await WantOAuth.exchange(callback: URL(string: "http://127.0.0.1:5000/callback?code=abc&state=wrong")!, server: server,
                                             clientID: "client", redirect: redirect, pkce: pkce, resource: endpoint, session: session)
            XCTFail("a mismatched state must be refused")
        } catch { XCTAssertEqual(error as? WantError, .server("Sign-in did not match this request. Try again.")) }
    }
}

/// Runs only against a real server: set WANT_LIVE_MCP (for example http://localhost:8787/mcp) and
/// WANT_LIVE_KEY (a write key) for the test process, e.g. as TEST_RUNNER_WANT_LIVE_MCP with xcodebuild.
/// It adds one item to the key's list.
final class WantsLiveTests: XCTestCase {
    func testReadAddAndPollAgainstALiveServer() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let raw = env["WANT_LIVE_MCP"], let endpoint = URL(string: raw), let key = env["WANT_LIVE_KEY"] else {
            throw XCTSkip("Set WANT_LIVE_MCP and WANT_LIVE_KEY to run against a live Want MCP server")
        }
        let client = WantMCPClient(endpoint: endpoint, version: "test") { key }
        let ids = try await client.writableListIDs()
        let list = try await client.list(try XCTUnwrap(ids.first))
        _ = try await client.comments(listID: list.id)
        _ = try await client.suggestions(listID: list.id)
        let start = try await client.poll("list.activity", cursor: nil)
        let item = try await client.addItem(listID: list.id, text: "msgblast live test \(UUID().uuidString.prefix(8))")
        let page = try await client.poll("list.activity", cursor: start.cursor)
        XCTAssertTrue(page.events.contains { $0.type == "item.created" && $0.item?.id == item.id }, "the new item arrives as an event")
    }

    /// The parts of sign-in that need no account: the challenge, discovery, registration and the sign-in page.
    /// Registers one client named msgblast on the server. Needs only WANT_LIVE_MCP.
    @MainActor func testSignInChallengeAndOAuthDiscoveryAgainstALiveServer() async throws {
        guard let raw = ProcessInfo.processInfo.environment["WANT_LIVE_MCP"], let resource = URL(string: raw) else {
            throw XCTSkip("Set WANT_LIVE_MCP to check sign-in discovery against a live Want MCP server")
        }
        var challenge: URL?
        do { _ = try await WantMCPClient(endpoint: resource, version: "test") { nil }.addItem(listID: "nonexistent", text: "x") }
        catch WantError.unauthorized(let hint) { challenge = hint }
        let hint = try XCTUnwrap(challenge, "a write tool without a credential gets the auth challenge")
        let server = try await WantOAuth.discover(resource: resource, hint: hint)
        XCTAssertTrue(server.requiresIssuer)
        let callback = WantOAuthCallback()
        defer { callback.stop() }
        let redirect = try await callback.start()
        let clientID = try await WantOAuth.register(server, redirect: redirect)
        let page = WantOAuth.authorizeURL(server, clientID: clientID, redirect: redirect, pkce: WantOAuth.PKCE(), resource: resource)
        let (_, response) = try await URLSession.shared.data(from: page)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200, "the sign-in page accepts msgblast's authorization request")
    }

    /// Also needs WANT_LIVE_OAUTH_DIR: the test writes `authorize-url.txt` there and waits up to five
    /// minutes for someone to sign in at that URL, whose redirect reaches msgblast's loopback listener.
    @MainActor func testOAuthSignInAgainstALiveServer() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let raw = env["WANT_LIVE_MCP"], let resource = URL(string: raw), let dir = env["WANT_LIVE_OAUTH_DIR"] else {
            throw XCTSkip("Set WANT_LIVE_MCP and WANT_LIVE_OAUTH_DIR to sign in against a live Want MCP server")
        }
        let callback = WantOAuthCallback()
        defer { callback.stop() }
        let redirect = try await callback.start()
        let server = try await WantOAuth.discover(resource: resource, hint: nil)
        let clientID = try await WantOAuth.register(server, redirect: redirect)
        let pkce = WantOAuth.PKCE()
        let authorize = WantOAuth.authorizeURL(server, clientID: clientID, redirect: redirect, pkce: pkce, resource: resource)
        try authorize.absoluteString.write(to: URL(fileURLWithPath: dir).appendingPathComponent("authorize-url.txt"), atomically: true, encoding: .utf8)
        let timeout = Task { try await Task.sleep(for: .seconds(300)); callback.stop() }
        let answer = try await callback.wait()
        timeout.cancel()
        let credential = try await WantOAuth.exchange(callback: answer, server: server, clientID: clientID, redirect: redirect, pkce: pkce, resource: resource)
        let ids = try await WantMCPClient(endpoint: resource, version: "test") { credential.accessToken }.writableListIDs()
        XCTAssertFalse(ids.isEmpty, "the grant writes the lists ticked on the consent page")
        let refreshed = try await WantOAuth.refresh(credential, resource: resource)
        XCTAssertNotEqual(refreshed.accessToken, credential.accessToken)
        _ = try await WantMCPClient(endpoint: resource, version: "test") { refreshed.accessToken }.writableListIDs()
    }
}

final class WantStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, [String: String], Data))?
    static func body(_ request: URLRequest) -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(buffer, count: n) }
        return data
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let (status, headers, data) = Self.handler?(request) else { client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
