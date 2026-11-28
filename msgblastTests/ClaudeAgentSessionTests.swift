import XCTest
@testable import msgblastCore

final class ClaudeAgentSessionTests: XCTestCase {
    func testOlderClaudeCodeIsRefusedBeforeLaunch() async throws {
        let agent = try fixture("[ \"$1\" = \"--help\" ] && echo 'Older CLI help' && exit 0\ntouch launched")
        do {
            _ = try await start(agent)
            XCTFail("expected the version check to refuse")
        } catch PersonalAgentError.conversationVersionRequired {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("work/launched").path))
    }

    func testRejectedFlagReportsTheRequiredVersion() async throws {
        let agent = try fixture("echo 'error: unknown option --include-partial-messages' >&2\nexit 1")
        let session = try await start(agent)
        let events = await collect(session.send("Hello"))
        XCTAssertEqual(events, [.failed(PersonalAgentError.conversationVersionRequired.localizedDescription)])
        await session.close()
    }

    func testDisconnectedMsgblastToolsEndTheSession() async throws {
        let record = #"{"type":"system","subtype":"init","session_id":"x","tools":[],"mcp_servers":[{"name":"msgblast","status":"failed"}]}"#
        let agent = try fixture("read line\necho '\(record)'\nsleep 30")
        let session = try await start(agent)
        let events = await collect(session.send("Hello"))
        XCTAssertEqual(events, [.failed("msgblast's tools did not connect to Claude Code. Nothing was sent.")])
        let later = await collect(session.send("Hello again"))
        XCTAssertEqual(later, [.failed(ClaudeAgentSession.endedMessage)])
        await session.close()
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path).filter { $0.hasPrefix("msgblast-Agent-") }
        XCTAssertEqual(leftovers, [])
    }

    func testArgumentsAllowOnlyMsgblastToolsWithoutPrompts() {
        let arguments = ClaudeAgentSession.arguments(configuration: URL(fileURLWithPath: "/tmp/mcp.json"), instructions: "Be brief", sessionID: nil)
        XCTAssertEqual(arguments[arguments.firstIndex(of: "--tools")! + 1], "")
        XCTAssertEqual(arguments[arguments.firstIndex(of: "--allowedTools")! + 1], "mcp__msgblast__*")
        XCTAssertEqual(arguments[arguments.firstIndex(of: "--permission-prompts")! + 1], "none")
        XCTAssertFalse(arguments.contains("--resume"))
        XCTAssertEqual(ClaudeAgentSession.arguments(configuration: URL(fileURLWithPath: "/tmp/mcp.json"), instructions: "", sessionID: "id").suffix(2), ["--resume", "id"])
    }

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("msgblast-ClaudeAgentTest-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    private func fixture(_ body: String) throws -> InstalledPersonalAgent {
        let url = directory.appendingPathComponent("claude")
        let help = "[ \"$1\" = \"--help\" ] && echo '--permission-prompts <target>' && exit 0\n"
        try Data(("#!/bin/sh\n" + (body.hasPrefix("[ \"$1\"") ? "" : help) + body + "\n").utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return InstalledPersonalAgent(provider: .claude, executableURL: url, path: "/usr/bin:/bin")
    }

    private func start(_ agent: InstalledPersonalAgent) async throws -> ClaudeAgentSession {
        try await ClaudeAgentSession.start(using: agent, msgblastExecutable: "/fixture/msgblast", sessionKey: "key",
                                           instructions: "Fixture", workingDirectory: directory.appendingPathComponent("work"))
    }

    private func collect(_ stream: AsyncStream<MsgblastAgentEvent>) async -> [MsgblastAgentEvent] {
        var events: [MsgblastAgentEvent] = []
        for await event in stream { events.append(event) }
        return events
    }
}
