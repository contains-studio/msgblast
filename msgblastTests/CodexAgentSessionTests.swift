import XCTest
@testable import msgblastCore

/// Drives the real session against `scripts/fixtures/codex_app_server.py`, a recorded app-server. No live Codex account.
final class CodexAgentSessionTests: XCTestCase {
    private let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("scripts/fixtures/codex_app_server.py")

    func testTurnStreamsRepliesAndToolsWithLockedDownConfigAndResumesTheThread() async throws {
        let directory = try makeDirectory(), home = directory.appendingPathComponent("managed-home")
        defer { try? FileManager.default.removeItem(at: directory) }
        setenv("OPENAI_API_KEY", "fixture-key", 0)
        let session = CodexAgentSession(agent: try codex(in: directory), codexHome: home, launchConfig: ["model_provider=\"fixture\""],
                                        instructions: "Only message AI agents.", sessionKey: "session-secret")
        let tool = "msgblast_agents_list"
        let reply = await events(session.send("reply"))
        XCTAssertEqual(reply, [.tool(name: tool, finished: false, failed: false), .tool(name: tool, finished: true, failed: false),
                               .text("Codex "), .text("replied"), .text("\n\n"), .text("Codex "), .text("replied"),
                               .completed(sessionID: "thread-fixture")])
        await session.close()

        let log = try requests(in: directory)
        XCTAssertEqual(log[0]["argv"] as? [String], ["app-server", "-c", "model_provider=\"fixture\""])
        XCTAssertEqual(log[0]["codexHome"] as? String, home.path)
        XCTAssertEqual(log[0]["openAIKey"] as? Bool, false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(log[0]["cwd"] as? String)))
        let start = try XCTUnwrap(log.first { $0["method"] as? String == "thread/start" }?["params"] as? [String: Any])
        XCTAssertEqual(start["approvalPolicy"] as? String, "never")
        XCTAssertEqual(start["sandbox"] as? String, "read-only")
        XCTAssertEqual(start["developerInstructions"] as? String, "Only message AI agents.")
        let config = try XCTUnwrap(start["config"] as? [String: Any])
        let server = try XCTUnwrap(config["mcp_servers.msgblast"] as? [String: Any])
        XCTAssertEqual(server["args"] as? [String], ["mcp"])
        XCTAssertEqual(server["env"] as? [String: String], [MsgblastAgent.sessionKeyEnvironment: "session-secret"])
        XCTAssertEqual(server["default_tools_approval_mode"] as? String, "approve")
        XCTAssertEqual(config["mcp_servers.user-tools.enabled"] as? Bool, false)
        XCTAssertEqual(config["web_search"] as? String, "disabled")
        for feature in ["shell_tool", "unified_exec", "view_image", "apps", "plugins", "hooks", "computer_use", "browser_use"] {
            XCTAssertEqual(config["features.\(feature)"] as? Bool, false, feature)
        }

        let resumed = CodexAgentSession(agent: try codex(in: directory), instructions: "Only message AI agents.",
                                        sessionKey: "session-secret", sessionID: "thread-saved")
        let resumedEvents = await events(resumed.send("reply"))
        XCTAssertEqual(resumedEvents.last, .completed(sessionID: "thread-saved"))
        await resumed.close()
        let second = try requests(in: directory).filter { $0["argv"] != nil }.last
        XCTAssertNil(second?["codexHome"] as? String)
        XCTAssertEqual(second?["openAIKey"] as? Bool, true)
        let resume = try requests(in: directory).first { $0["method"] as? String == "thread/resume" }?["params"] as? [String: Any]
        XCTAssertEqual(resume?["threadId"] as? String, "thread-saved")
    }

    func testOnlyMsgblastToolsAreApprovedAndEverythingElseIsDeclined() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = CodexAgentSession(agent: try codex(in: directory), instructions: "", sessionKey: "key")
        let approvalEvents = await events(session.send("approvals"))
        XCTAssertEqual(approvalEvents.last, .completed(sessionID: "thread-fixture"))
        await session.close()
        let replies = Dictionary(try requests(in: directory).compactMap { entry in
            (entry["id"] as? String).map { ($0, entry) }
        }, uniquingKeysWith: { first, _ in first })
        XCTAssertEqual((replies["server-0"]?["result"] as? [String: Any])?["action"] as? String, "accept")
        XCTAssertEqual((replies["server-1"]?["result"] as? [String: Any])?["action"] as? String, "decline")
        XCTAssertEqual((replies["server-2"]?["result"] as? [String: Any])?["decision"] as? String, "decline")
        XCTAssertNotNil(replies["server-3"]?["error"])
    }

    func testInterruptFailureAndExitEndTurnsWithoutRetryingAndTheNextTurnResumes() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = CodexAgentSession(agent: try codex(in: directory), instructions: "", sessionKey: "key")
        // The fixture streams "Waiting" after `turn/started`, so the turn ID is known when Stop is pressed.
        let busy = Received()
        let interrupted = await events(session.send("wait")) { event in
            guard event == .text("Waiting") else { return }
            for await event in session.send("reply") { await busy.append(event) }
            await session.interrupt()
            await session.interrupt()
        }
        XCTAssertEqual(interrupted, [.text("Waiting"), .completed(sessionID: "thread-fixture")])
        let busyEvents = await busy.events
        XCTAssertEqual(busyEvents, [.failed(CodexAgentSessionError.busy.errorDescription!)])
        let failed = await events(session.send("fail"))
        XCTAssertEqual(failed, [.failed("Usage limit reached.")])
        guard case .failed(let stopped) = await events(session.send("exit")).last else { return XCTFail("exit did not fail") }
        XCTAssertTrue(stopped.contains("Codex stopped before the reply finished"))
        let recovered = await events(session.send("reply"))
        XCTAssertEqual(recovered.last, .completed(sessionID: "thread-fixture"))
        await session.close()
        let afterClose = await events(session.send("reply"))
        XCTAssertEqual(afterClose, [.failed(CodexAgentSessionError.closed.errorDescription!)])
        let methods = try requests(in: directory).compactMap { $0["method"] as? String }
        XCTAssertEqual(methods.filter { $0 == "turn/interrupt" }.count, 1)
        XCTAssertEqual(methods.filter { $0 == "turn/start" }.count, 4)
        XCTAssertEqual(methods.filter { $0 == "thread/resume" }.count, 1)
    }

    func testCodexWithoutAppServerExplainsTheUpdate() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try script("codex", "echo \"error: unrecognized subcommand 'app-server'\" >&2\nexit 2", in: directory)
        let session = CodexAgentSession(agent: InstalledPersonalAgent(provider: .codex, executableURL: url, path: "/usr/bin:/bin"),
                                        instructions: "", sessionKey: "key")
        guard case .failed(let message) = await events(session.send("reply")).last else { return XCTFail("no failure") }
        XCTAssertTrue(message.contains("needs a Codex version with `codex app-server`"), message)
        XCTAssertTrue(message.contains("unrecognized subcommand"), message)
    }

    /// Collects a turn's events. A turn that doesn't end within 20 seconds fails the test instead of hanging it.
    private func events(_ stream: AsyncStream<MsgblastAgentEvent>, file: StaticString = #filePath, line: UInt = #line,
                        onEach: @escaping @Sendable (MsgblastAgentEvent) async -> Void = { _ in }) async -> [MsgblastAgentEvent] {
        let received = Received()
        let ended = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await event in stream { await received.append(event); await onEach(event) }
                return true
            }
            group.addTask { try? await Task.sleep(for: .seconds(20)); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        let events = await received.events
        if !ended { XCTFail("The turn didn't end within 20 seconds. Events so far: \(events)", file: file, line: line) }
        return events
    }

    private func codex(in directory: URL) throws -> InstalledPersonalAgent {
        let url = try script("codex", "exec /usr/bin/python3 '\(fixture.path)' '\(directory.path)' \"$@\"", in: directory)
        return InstalledPersonalAgent(provider: .codex, executableURL: url, path: "/usr/bin:/bin")
    }

    private func script(_ name: String, _ body: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("msgblast-CodexAgent-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    private func requests(in directory: URL) throws -> [[String: Any]] {
        let url = directory.appendingPathComponent("requests.jsonl")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").compactMap {
            try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
    }
}

private actor Received {
    var events: [MsgblastAgentEvent] = []
    func append(_ event: MsgblastAgentEvent) { events.append(event) }
}
