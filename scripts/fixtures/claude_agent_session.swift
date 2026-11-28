import Foundation
import msgblastCore

@main struct ClaudeAgentSessionFixture {
    static func events(_ session: ClaudeAgentSession, _ text: String, interruptAfter delay: Duration? = nil) async -> [MsgblastAgentEvent] {
        let stream = session.send(text)
        if let delay { Task { try? await Task.sleep(for: delay); await session.interrupt() } }
        var events: [MsgblastAgentEvent] = []
        for await event in stream { events.append(event) }
        print("\(text) -> \(events)")
        return events
    }

    static func main() async throws {
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1])
        let working = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let log = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MSGBLAST_CLI_FIXTURE_LOG"]!)
        print("DETERMINISTIC LOCAL FIXTURE — no Claude account, connector, network, or model request")
        let agent = InstalledPersonalAgent(provider: .claude, executableURL: fixture, path: "/usr/bin:/bin")
        func start(_ id: String? = nil, idle: TimeInterval = 60) async throws -> ClaudeAgentSession {
            try await ClaudeAgentSession.start(using: agent, msgblastExecutable: "/fixture/msgblast", sessionKey: "fixture-session-key",
                                               instructions: "Fixture instructions", resuming: id, workingDirectory: working, idleTimeout: idle)
        }
        func launches() throws -> [[String: Any]] {
            try String(contentsOf: log, encoding: .utf8).split(separator: "\n")
                .compactMap { try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }.filter { $0["pid"] != nil }
        }

        let session = try await start()
        let first = await events(session, "Compare the fixture agents")
        guard case .completed(let id) = first.last else { fatalError("first turn did not complete") }
        precondition(first.dropLast() == [.tool(name: "msgblast_agents_list", finished: false, failed: false),
                                          .tool(name: "msgblast_agents_list", finished: true, failed: false),
                                          .text("Fixture summary of: Compare the fixture agents")])
        let stopped = await events(session, "HANG", interruptAfter: .milliseconds(300))
        precondition(stopped.count == 1 && { if case .failed(let text) = stopped[0] { text.hasPrefix("Stopped.") } else { false } }())
        let again = await events(session, "Still running after the interrupt")
        precondition(again.last == .completed(sessionID: id))
        await session.close()
        let launch = try launches()[0]
        precondition(!FileManager.default.fileExists(atPath: launch["config"] as! String))
        precondition(kill(launch["pid"] as! pid_t, 0) != 0)
        print("closed: process ended and MCP config file removed")

        let resumed = try await start(id)
        let resumedEvents = await events(resumed, "Resume the saved conversation"), relaunch = try launches()[1]
        precondition(resumedEvents.last == .completed(sessionID: id) && relaunch["resumed"] as? String == id)
        await resumed.close()

        let foreign = try await start()
        let refused = await events(foreign, "FOREIGN")
        precondition(refused == [.failed("Claude Code offered tools other than msgblast's, so msgblast stopped it. Nothing was sent.")])
        let silent = try await start(idle: 1)
        let idle = await events(silent, "SILENT")
        precondition(idle.count == 1 && { if case .failed(let text) = idle[0] { text.hasPrefix("Claude Code stopped responding") } else { false } }())
        let afterClose = await events(silent, "After close"), silentLaunch = try launches()[3]
        precondition(afterClose == [.failed("This msgblast agent conversation has ended. Start a new one.")])
        // The idle limit closes the session in the background; give the process group time to end.
        for _ in 0..<60 where kill(silentLaunch["pid"] as! pid_t, 0) == 0 { try await Task.sleep(for: .milliseconds(50)) }
        precondition(kill(silentLaunch["pid"] as! pid_t, 0) != 0)
        print("\nPASS: streamed turn, protocol interrupt, close cleanup, resume, foreign-tool refusal and idle limit")
    }
}
