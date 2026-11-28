import XCTest
@testable import msgblastCore

private final class RecordingSession: MsgblastAgentRunner, @unchecked Sendable {
    let events: [MsgblastAgentEvent]
    var closed = false
    var sent: [String] = []
    private var held: AsyncStream<MsgblastAgentEvent>.Continuation?
    init(_ events: [MsgblastAgentEvent]) { self.events = events }
    /// "Wait" holds the turn open until it is interrupted.
    func send(_ text: String) -> AsyncStream<MsgblastAgentEvent> {
        sent.append(text)
        return AsyncStream { continuation in
            if text == "Wait" { held = continuation; return }
            events.forEach { continuation.yield($0) }; continuation.finish()
        }
    }
    func interrupt() async { held?.yield(.failed("Stopped.")); held?.finish(); held = nil }
    func close() async { closed = true }
}

private final class Opens: @unchecked Sendable {
    var calls: [(key: String, sessionID: String?)] = []
    var sessions: [RecordingSession] = []
}

@MainActor
final class LiveAgentRunnerTests: XCTestCase {
    private func events(_ stream: AsyncStream<MsgblastAgentEvent>) async -> [MsgblastAgentEvent] {
        var all: [MsgblastAgentEvent] = []
        for await event in stream { all.append(event) }
        return all
    }

    func testKeyLivesForTheSessionAndAStoppedTurnResumesWithANewKey() async {
        let keys = AgentSessionKeys(), opens = Opens()
        let runner = LiveAgentRunner(keys: keys, sessionID: "saved") { key, sessionID in
            opens.calls.append((key, sessionID))
            let session = RecordingSession([.text("Hi"), .completed(sessionID: "s\(opens.calls.count)")])
            opens.sessions.append(session)
            return session
        }
        XCTAssertFalse(keys.hasLive)
        _ = await events(runner.send("One"))
        _ = await events(runner.send("Two"))
        XCTAssertEqual(opens.calls.count, 1)
        XCTAssertEqual(opens.calls[0].sessionID, "saved")
        XCTAssertTrue(keys.isLive(opens.calls[0].key))

        let stopped = Task { await events(runner.send("Wait")) }
        try? await Task.sleep(for: .milliseconds(50))
        await runner.interrupt()
        _ = await stopped.value
        _ = await events(runner.send("Three"))
        XCTAssertTrue(opens.sessions[0].closed)
        XCTAssertFalse(keys.isLive(opens.calls[0].key))
        XCTAssertEqual(opens.calls.count, 2)
        XCTAssertEqual(opens.calls[1].sessionID, "s1")
        XCTAssertNotEqual(opens.calls[1].key, opens.calls[0].key)

        _ = await events(runner.send("Four"))
        await runner.close()
        XCTAssertTrue(opens.sessions[1].closed)
        XCTAssertFalse(keys.hasLive)
    }

    func testStopWhileTheSessionOpensSendsNothingAndRevokesTheKey() async {
        let keys = AgentSessionKeys(), opens = Opens()
        let runner = LiveAgentRunner(keys: keys, sessionID: nil) { key, sessionID in
            opens.calls.append((key, sessionID))
            try await Task.sleep(for: .milliseconds(200))
            let session = RecordingSession([.completed(sessionID: "s")])
            opens.sessions.append(session)
            return session
        }
        let turn = Task { await events(runner.send("Hi")) }
        try? await Task.sleep(for: .milliseconds(50))
        await runner.interrupt()
        let result = await turn.value
        XCTAssertEqual(result, [.failed("Stopped.")])
        XCTAssertEqual(opens.sessions.first?.sent, [])
        XCTAssertTrue(opens.sessions.first?.closed == true)
        XCTAssertFalse(keys.hasLive)
    }

    func testAFailedTurnClosesTheSessionAndTheNextOneResumes() async {
        let keys = AgentSessionKeys(), opens = Opens()
        let runner = LiveAgentRunner(keys: keys, sessionID: "saved") { key, sessionID in
            opens.calls.append((key, sessionID))
            let session = RecordingSession(opens.calls.count == 1 ? [.failed("Claude Code stopped.")] : [.completed(sessionID: "s2")])
            opens.sessions.append(session)
            return session
        }
        _ = await events(runner.send("One"))
        XCTAssertTrue(opens.sessions[0].closed)
        XCTAssertFalse(keys.hasLive)
        let next = await events(runner.send("Two"))
        XCTAssertEqual(next.last, .completed(sessionID: "s2"))
        XCTAssertEqual(opens.calls.map(\.sessionID), ["saved", "saved"])
    }

    func testAFailedOpenRevokesItsKeyAndFailsTheTurn() async {
        let keys = AgentSessionKeys()
        let runner = LiveAgentRunner(keys: keys, sessionID: nil) { _, _ in throw PersonalAgentError.unavailable("Codex") }
        let result = await events(runner.send("Hi"))
        XCTAssertEqual(result.count, 1)
        guard case .failed = result.first else { return XCTFail("Expected a failure, got \(result)") }
        XCTAssertFalse(keys.hasLive)
    }
}
