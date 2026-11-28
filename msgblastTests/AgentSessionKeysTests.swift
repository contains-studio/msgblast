import XCTest
@testable import msgblastCore
import msgblastRemoteProtocol

@MainActor final class AgentSessionKeysTests: XCTestCase {
    /// One AI agent and one Messages contact of each kind. Records who sent what.
    private final class Host: AgentControlHost {
        let controlEvents = AgentControlEvents()
        var commands: [RemoteCommand] = [], clients: [String] = []
        func controlStatus() -> AgentControlStatus { AgentControlStatus(version: "1.0", permissions: [:], busyAgents: []) }
        func controlAgents() -> [AgentControlAgent] {
            [AgentControlAgent(id: "web:chatgpt", name: "ChatGPT", kind: "app", visible: true, selected: true, busy: false),
             AgentControlAgent(id: Self.fo, name: "Fo", kind: "messages", visible: true, selected: true, busy: false),
             AgentControlAgent(id: "featured:szn", name: "szn", kind: "messages", visible: true, selected: false, busy: false)]
        }
        func controlComparisons() -> [Comparison] { [] }
        func controlTranscript(_ comparison: Comparison) -> [AgentControlTurn] { [] }
        func controlSend(_ command: RemoteCommand, client: String) async -> RemoteCommandResult {
            commands.append(command)
            clients.append(client)
            return .init(clientCommandID: command.clientCommandID, outcome: .applied)
        }
        static let fo = "messages:\(UUID().uuidString)"
    }

    private var file: URL!
    private var asked = 0

    override func setUp() async throws {
        file = FileManager.default.temporaryDirectory.appendingPathComponent("session-keys-\(UUID().uuidString).json")
        AgentControl.sendLimit = AgentControlSendLimit()
        asked = 0
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: file) }

    private func respond(_ body: [String: Any], host: Host = Host(), keys: AgentSessionKeys?, outsideAgents: Bool = true) async throws -> [String: Any] {
        var line = try JSONSerialization.data(withJSONObject: body.merging(["id": 1]) { $1 })
        line.append(0x0A)
        let reply = await AgentControlWire.respond(to: line, host: host, gate: AgentControlGate(file: file), approve: { _ in self.asked += 1; return .full },
                                                   sessionKeys: keys, outsideAgents: outsideAgents)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: reply) as? [String: Any])
    }

    private func call(_ tool: String, _ arguments: [String: Any], key: String, keys: AgentSessionKeys, host: Host) async throws -> [String: Any] {
        try await respond(["method": "tools/call", "name": tool, "arguments": arguments, "sessionKey": key], host: host, keys: keys)
    }

    private func code(_ reply: [String: Any]) -> String? { (reply["error"] as? [String: Any])?["code"] as? String }
    private func message(_ reply: [String: Any]) -> String { (reply["error"] as? [String: Any])?["message"] as? String ?? "" }

    func testKeysAreRandomBase64URLAndEndWhenRevoked() {
        let keys = AgentSessionKeys()
        var changes = 0
        keys.changed = { changes += 1 }
        let first = keys.issue(), second = keys.issue()
        XCTAssertEqual(first.count, 43)
        XCTAssertNil(first.rangeOfCharacter(from: CharacterSet(charactersIn: "+/=")))
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(keys.isLive(first) && keys.isLive(second) && keys.hasLive)
        keys.revoke(first)
        XCTAssertFalse(keys.isLive(first))
        XCTAssertTrue(keys.isLive(second))
        keys.revoke(first)
        keys.revokeAll()
        XCTAssertFalse(keys.isLive(second) || keys.hasLive)
        XCTAssertEqual(changes, 4)
    }

    func testALiveKeyIsTheMsgblastAgentWithFullAccessAndNoPrompt() async throws {
        let keys = AgentSessionKeys(), host = Host()
        let key = keys.issue()
        let reply = try await call("msgblast_blast_start", ["text": "Hi", "agents": ["web:chatgpt"], "requestId": "a"], key: key, keys: keys, host: host)
        XCTAssertEqual((reply["result"] as? [String: Any])?["outcome"] as? String, "done")
        XCTAssertEqual(host.clients, [MsgblastAgent.clientName])
        XCTAssertEqual(asked, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        // It works with Outside agents off, where other callers are refused before any prompt.
        let off = try await respond(["method": "tools/list", "sessionKey": key], keys: keys, outsideAgents: false)
        XCTAssertNotNil(off["result"])
        let outside = try await respond(["method": "tools/list", "client": "Codex"], keys: keys, outsideAgents: false)
        XCTAssertEqual(code(outside), "unavailable")
        XCTAssertEqual(asked, 0)
    }

    func testAKeyThatIsNotLiveRunsNothing() async throws {
        let keys = AgentSessionKeys(), host = Host()
        let key = keys.issue()
        keys.revoke(key)
        for given in [key as Any, "made-up", 42] {
            let reply = try await respond(["method": "tools/call", "name": "msgblast_status", "sessionKey": given, "client": "Codex"], host: host, keys: keys)
            XCTAssertEqual(code(reply), "notApproved")
        }
        // The Tailscale path has no keys, so it refuses even a live one.
        let live = keys.issue()
        let tailnet = try await respond(["method": "tools/list", "sessionKey": live], keys: nil)
        XCTAssertEqual(code(tailnet), "notApproved")
        XCTAssertEqual(asked, 0)
        XCTAssertEqual(host.commands, [])
    }

    func testNoOtherCallerMayUseTheAgentsName() async throws {
        for name in ["msgblast agent", "MSGBLAST AGENT", "msgblastagent", " Msg Blast  Agent ", "msgblast\u{200B}agent"] {
            let reply = try await respond(["method": "tools/list", "client": name], keys: AgentSessionKeys())
            XCTAssertEqual(code(reply), "notApproved", name)
        }
        XCTAssertEqual(asked, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testTheAgentSeesAndMessagesOnlyAIAgents() async throws {
        let keys = AgentSessionKeys(), host = Host()
        let key = keys.issue()
        let list = try await call("msgblast_agents_list", [:], key: key, keys: keys, host: host)
        XCTAssertEqual((list["result"] as? [[String: Any]])?.compactMap { $0["id"] as? String }, ["web:chatgpt"])
        let comparison = UUID().uuidString
        let refused: [(String, [String: Any])] = [
            ("msgblast_blast_start", ["text": "Hi", "agents": ["web:chatgpt", Host.fo]]),
            ("msgblast_blast_start", ["text": "Hi", "agents": ["featured:szn"]]),
            ("msgblast_agent_message", ["text": "Hi", "agent": Host.fo]),
            ("msgblast_agent_message", ["text": "Hi", "agent": "web-instance:\(Host.fo)"]),
            ("msgblast_blast_follow_up", ["text": "Hi", "comparisonId": comparison]),
            ("msgblast_blast_follow_up", ["text": "Hi", "comparisonId": comparison, "agents": []])
        ]
        for (tool, arguments) in refused {
            let reply = try await call(tool, arguments, key: key, keys: keys, host: host)
            XCTAssertEqual(code(reply), "invalidArguments", "\(tool) \(arguments)")
        }
        let contact = try await call("msgblast_agent_message", ["text": "Hi", "agent": Host.fo], key: key, keys: keys, host: host)
        XCTAssertTrue(message(contact).contains("only messages AI agents"))
        XCTAssertEqual(host.commands, [])
        _ = try await call("msgblast_blast_follow_up", ["text": "Hi", "comparisonId": comparison, "agents": ["web:chatgpt"]], key: key, keys: keys, host: host)
        XCTAssertEqual(host.commands.count, 1)
        // An outside agent keeps its Messages contacts.
        let outside = try await AgentControl.call("msgblast_agents_list", arguments: Data(), access: .full, host: host, client: "Codex")
        XCTAssertEqual(try JSONDecoder().decode([AgentControlAgent].self, from: outside).count, 3)
    }

    func testMcpForwardsTheKeyOnEveryRequest() async throws {
        actor Lines { var all: [Data] = []; func add(_ line: Data) { all.append(line) } }
        let lines = Lines()
        let server = AgentControlMCPServer(version: "1", client: nil, sessionKey: "k") { line in
            await lines.add(line)
            return Data(#"{"id":1,"result":{"tools":[]}}"#.utf8 + [0x0A])
        }
        _ = await server.handle(Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#.utf8))
        _ = await server.handle(Data(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"msgblast_status"}}"#.utf8))
        let keys = try await lines.all.map { try XCTUnwrap(JSONSerialization.jsonObject(with: $0) as? [String: Any])["sessionKey"] as? String }
        XCTAssertEqual(keys, ["k", "k"])
    }
}
