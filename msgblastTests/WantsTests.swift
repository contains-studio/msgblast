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
            _ = try await client().comments(listID: "lst_1")
            XCTFail("expected an error")
        } catch { XCTAssertEqual(error as? WantError, .server("Item text is too long")) }
    }

    func testUnauthorizedReportsTheChallengeMetadata() async {
        WantStub.handler = { _ in
            (401, ["WWW-Authenticate": #"Bearer resource_metadata="https://mcp.wantmcp.test/.well-known/oauth-protected-resource/mcp""#], Data())
        }
        do {
            _ = try await client(token: nil).comments(listID: "lst_1")
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
            return self.reply(["events": [["data": "unknown"], ["eventId": "42", "name": "comment.created", "timestamp": "2026-11-27T08:00:00Z", "data": event]],
                               "cursor": "42", "hasMore": false, "nextPollMs": 15000], to: request)
        }
        let page = try await client().poll("comment.created", cursor: "41")
        XCTAssertEqual(page.cursor, "42")
        XCTAssertEqual(page.nextPoll, 15)
        XCTAssertEqual(page.events.count, 1)
        XCTAssertEqual(page.events.first?.comment?.body, "Folds flat?")
        WantStub.handler = { self.reply(["events": [["data": ["type": "future"]]], "cursor": "43"], to: $0) }
        let unknown = try await client().poll("list.activity", cursor: "42")
        XCTAssertTrue(unknown.hasActivity && unknown.events.isEmpty)
        XCTAssertEqual(unknown.cursor, "43")
    }

    private func taskList() throws -> WantList {
        var json = listJSON
        json["format"] = "tasks"; json["visibility"] = "private"
        var item = (json["items"] as! [[String: Any]])[0]
        var entry = (item["entries"] as! [[String: Any]])[0]
        entry["product_url"] = NSNull(); entry["current_price"] = NSNull(); entry["retailer"] = ""; entry["links"] = ["https://example.com/quote"]
        item["entries"] = [entry]; item["status"] = "in_progress"; item["claimed_by"] = entry["author"]; item["details"] = "Saturday, 8am."
        json["items"] = [item]
        return try WantJSON.decoder.decode(WantList.self, from: JSONSerialization.data(withJSONObject: json))
    }

    func testTaskEntriesNeedNoProductAndItemsShowWhoClaimedThem() throws {
        let list = try taskList()
        let task = try XCTUnwrap(list.items?.first)
        XCTAssertEqual(list.kind, .tasks)
        XCTAssertTrue(list.isPrivate)
        XCTAssertEqual(task.entries?.first?.link, "https://example.com/quote")
        XCTAssertEqual(task.claimedBy?.label, "Claude")
    }

    func testCompactListIsPagedAndItemsCarryQuestionsWithoutEntries() async throws {
        var summary = listJSON; summary["items"] = nil
        let compact: [String: Any] = ["id": "itm_2", "url": "https://wantmcp.com/l/lst_1#itm_2", "text": "Kettle", "details_preview": "Under £80",
                                      "status": "waiting_on_owner", "entry_counts": ["listed": 0, "suggested": 0], "comment_count": 0,
                                      "open_question": ["id": "qst_1", "item_id": "itm_2", "text": "Electric or stovetop?", "options": ["Electric", "Stovetop"],
                                                        "asked_by": ["kind": "agent", "agent_id": "agt_1", "name": "Claude", "owner_handle": "quiet-otter-4821"],
                                                        "asked_at": "2026-11-26T08:00:00Z", "answer": NSNull()]]
        var calls: [[String: Any]] = []
        WantStub.handler = { request in
            let arguments = ((try! JSONSerialization.jsonObject(with: WantStub.body(request)) as! [String: Any])["params"] as! [String: Any])["arguments"] as! [String: Any]
            calls.append(arguments)
            let page: [String: Any] = ["list": summary, "items": [compact], "next_cursor": calls.count < 21 ? String(calls.count) as Any : NSNull()]
            return self.reply(["structuredContent": page], to: request)
        }
        let list = try await client().list("lst_1")
        XCTAssertEqual(calls.map { $0["cursor"] as? String }, [nil] + (1...20).map { String($0) })
        XCTAssertEqual(Set(calls.flatMap(\.keys)), ["list", "cursor"], "only arguments the tool lists")
        XCTAssertEqual(list.title, "Gifts")
        XCTAssertEqual(list.items?.count, 21)
        XCTAssertEqual(list.items?.first?.openQuestion?.options, ["Electric", "Stovetop"])
        XCTAssertNil(list.items?.first?.entries)
    }

    func testPricesCarryProvenance() throws {
        let price = try WantJSON.decoder.decode(WantPrice.self, from: JSONSerialization.data(withJSONObject: [
            "price": "59.00", "currency": "GBP", "original_price": NSNull(), "posted_by": ["kind": "user", "handle": "x"], "posted_at": "2026-11-26T09:00:00Z",
            "source": "search", "verified": false, "checked_at": "2026-11-26T08:00:00Z"] as [String: Any]))
        XCTAssertFalse(price.isVerified)
        var legacy = price; legacy.verified = nil
        XCTAssertFalse(legacy.isVerified)
        XCTAssertNotNil(price.checkedAt)
    }

    func testSavedWriteKeyBelongsOnlyToItsEndpoint() throws {
        var key = WantCredential(accessToken: "wk_fixture")
        XCTAssertNil(WantCredential.restore(try JSONEncoder().encode(key), for: endpoint))
        key.endpoint = endpoint
        let data = try JSONEncoder().encode(key)
        XCTAssertEqual(WantCredential.restore(data, for: endpoint), key)
        XCTAssertNil(WantCredential.restore(data, for: URL(string: "https://different.test/mcp")!))
        XCTAssertFalse(WantMCPClient.allowsEndpoint(URL(string: "http://example.com/mcp")!))
        XCTAssertTrue(WantMCPClient.allowsEndpoint(URL(string: "http://127.0.0.1:8787/mcp")!))
    }

    func testOnlyWebLinksCanOpen() {
        for link in ["file:///tmp/item", "custom:open", "/relative", "https://"] { XCTAssertNil(WantJSON.webURL(link)) }
        XCTAssertEqual(WantJSON.webURL("https://shop.example/item")?.host, "shop.example")
    }

    func testWriteKeyValidation() {
        XCTAssertNotNil(WantCredential.writeKey("  wk_" + String(repeating: "a", count: 32) + "\n"))
        XCTAssertNil(WantCredential.writeKey("wk_short"))
        XCTAssertNil(WantCredential.writeKey("sk_" + String(repeating: "a", count: 32)))
    }
}

/// Runs only against a real server: set WANT_LIVE_MCP (for example http://localhost:8787/mcp) and
/// WANT_LIVE_KEY (a write key) for the test process, e.g. as TEST_RUNNER_WANT_LIVE_MCP with xcodebuild.
final class WantsLiveTests: XCTestCase {
    private func keyed() throws -> WantMCPClient {
        let env = ProcessInfo.processInfo.environment
        guard let raw = env["WANT_LIVE_MCP"], let endpoint = URL(string: raw), let key = env["WANT_LIVE_KEY"] else {
            throw XCTSkip("Set WANT_LIVE_MCP and WANT_LIVE_KEY to run against a live Want MCP server")
        }
        return WantMCPClient(endpoint: endpoint, version: "test") { key }
    }

    func testReadAndPollAgainstALiveServer() async throws {
        let client = try keyed()
        let ids = try await client.writableListIDs()
        let list = try await client.list(try XCTUnwrap(ids.first))
        _ = try await client.comments(listID: list.id)
        _ = try await client.suggestions(listID: list.id)
        if let item = list.items?.first { _ = try await client.entries(itemID: item.id) }
        _ = try await client.poll("list.activity", cursor: nil)
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
