import XCTest
@testable import msgblastCore

/// How Codex gets Connect with ChatGPT tokens. Accounts are seeded fixtures; no token leaves the test.
final class ChatGPTCodexTests: XCTestCase {
    private final class Box: @unchecked Sendable { var items: [String: Data] = [:] }

    private func accounts(scopes: [String] = ChatGPTTokenSharing.scope.split(separator: " ").map(String.init), signedIn: Bool = true) throws -> ChatGPTAccounts {
        let box = Box()
        let tokens = ChatGPTRegistration.Tokens(accessToken: "fixture-access", refreshToken: "fixture-refresh", idToken: "fixture-id",
                                                expiresAt: Date().addingTimeInterval(3600), earliestRefreshAt: nil, scopes: scopes)
        box.items["registration.oaiapp_1"] = try JSONEncoder().encode(ChatGPTRegistration(clientID: "oaiapp_1", subject: "user-1", tokens: signedIn ? tokens : nil))
        box.items["index"] = try JSONEncoder().encode(ChatGPTAccounts.Index(hostID: "urn:uuid:fixture", active: "oaiapp_1", clientIDs: ["oaiapp_1"]))
        return ChatGPTAccounts(storage: .init(read: { box.items[$0] }, write: { box.items[$0] = $1 }))
    }

    func testLaunchConfigPointsCodexAtTheTokenCommand() {
        let config = ChatGPTCodex.launchConfig(executable: "/Applications/msgblast \"Dev\".app/Contents/MacOS/msgblast", clientID: "oaiapp_1")
        XCTAssertEqual(config, [
            #"model_provider="msgblast_chatgpt""#,
            #"model_providers.msgblast_chatgpt={name="ChatGPT plan",base_url="https://api.openai.com/v1",model_catalog_url="https://api.openai.com/v1/models",wire_api="responses",requires_openai_auth=false,supports_websockets=false,auth={command="/Applications/msgblast \"Dev\".app/Contents/MacOS/msgblast",args=["__chatgpt-token","oaiapp_1"],timeout_ms=60000,refresh_interval_ms=0}}"#,
            "features.api_key_model_discovery=true",
        ])
    }

    func testLaunchUsesAnOwnerOnlyHomeInTheSupportFolder() async throws {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("chatgpt-codex-\(UUID())")
        defer { try? FileManager.default.removeItem(at: support) }
        let launch = try await ChatGPTCodex.launch(supportDirectory: support, executable: "/bin/msgblast", accounts: try accounts())
        XCTAssertEqual(launch.codexHome, support.appendingPathComponent("chatgpt-codex", isDirectory: true))
        let mode = try FileManager.default.attributesOfItem(atPath: launch.codexHome.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o700)
        XCTAssertTrue(launch.launchConfig[1].contains(#"args=["__chatgpt-token","oaiapp_1"]"#))

        do { _ = try await ChatGPTCodex.launch(supportDirectory: support, executable: "/bin/msgblast", accounts: try accounts(scopes: ["openid"])); XCTFail() }
        catch { XCTAssertEqual(error as? ChatGPTSignInError, .sharingOff) }
    }

    func testRepliesWithATokenOnlyForTheSessionsAccount() async throws {
        let accounts = try accounts()
        let reply = await ChatGPTCodex.reply(to: ChatGPTCodex.request(clientID: "oaiapp_1").dropLast(), accounts: accounts)
        XCTAssertEqual(ChatGPTCodex.token(from: reply), .success("fixture-access"))
        XCTAssertEqual(reply.last, 0x0A)

        let other = await ChatGPTCodex.reply(to: ChatGPTCodex.request(clientID: "oaiapp_2").dropLast(), accounts: accounts)
        XCTAssertEqual(ChatGPTCodex.token(from: other), .failure(.init(message: "The ChatGPT connection changed. Start a new msgblast agent chat.")))
        for line in [Data("{}".utf8), Data(#"{"version":1,"client":"oaiapp_1","extra":1}"#.utf8), Data("not json".utf8)] {
            if case .success = ChatGPTCodex.token(from: await ChatGPTCodex.reply(to: line, accounts: accounts)) { XCTFail("Answered \(line)") }
        }
        let signedOut = await ChatGPTCodex.reply(to: ChatGPTCodex.request(clientID: "oaiapp_1").dropLast(), accounts: try self.accounts(signedIn: false))
        XCTAssertEqual(ChatGPTCodex.token(from: signedOut), .failure(.init(message: ChatGPTSignInError.signedOut.errorDescription!)))
    }
}
