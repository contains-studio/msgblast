import AppKit
import XCTest
@testable import msgblastCore

private final class ScriptedRunner: MsgblastAgentRunner {
    var events: [MsgblastAgentEvent]
    var sent: [String] = []
    var closed = false
    var closePause = Duration.zero
    init(_ events: [MsgblastAgentEvent]) { self.events = events }
    func send(_ text: String) -> AsyncStream<MsgblastAgentEvent> {
        sent.append(text)
        return AsyncStream { continuation in events.forEach { continuation.yield($0) }; continuation.finish() }
    }
    func interrupt() async {}
    func close() async { try? await Task.sleep(for: closePause); closed = true }
}

@MainActor
final class MsgblastAgentTests: XCTestCase {
    private var directory: URL!
    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("MsgblastAgentTests-\(UUID())")
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: directory) }

    private func settle(_ controller: MsgblastAgentController) async {
        for _ in 0..<200 where controller.isWorking { try? await Task.sleep(for: .milliseconds(10)) }
    }

    func testTurnSavesRepliesAndSessionForTheChosenAccount() async throws {
        let runner = ScriptedRunner([.tool(name: "msgblast_blast_start", finished: false, failed: false), .text("Submitted "), .text("to Codex."), .completed(sessionID: "s1")])
        var resumed: [String?] = []
        let store = MsgblastAgentStore(directory: directory)
        let controller = MsgblastAgentController(store: store) { _, session in resumed.append(session); return runner }
        controller.send("ignored without an account")
        XCTAssertTrue(runner.sent.isEmpty)
        await controller.choose(.claude)
        controller.send("  Ask Codex  ")
        await settle(controller)
        XCTAssertEqual(controller.status, .idle)
        XCTAssertEqual(runner.sent, ["Ask Codex"])
        XCTAssertEqual(controller.conversation.messages.map(\.text), ["Ask Codex", "Submitted to Codex."])
        XCTAssertEqual(try store.load(), controller.conversation)
        XCTAssertEqual(try store.load().sessionID, "s1")

        await controller.choose(.chatGPT)
        XCTAssertTrue(runner.closed)
        XCTAssertNil(controller.conversation.sessionID)
        XCTAssertEqual(controller.conversation.messages.count, 2)
        XCTAssertEqual(resumed, [nil])
    }

    func testSendWhileTheOldRunnerClosesStartsTheNewAccount() async {
        let old = ScriptedRunner([.completed(sessionID: "old")])
        old.closePause = .milliseconds(200)
        var made: [(MsgblastAgentAccount, String?)] = []
        let controller = MsgblastAgentController(store: MsgblastAgentStore(directory: directory)) { account, session in
            made.append((account, session))
            return made.count == 1 ? old : ScriptedRunner([.completed(sessionID: "new")])
        }
        await controller.choose(.claude)
        controller.send("First")
        await settle(controller)
        let switching = Task { await controller.choose(.codexLogin) }
        await Task.yield()
        controller.send("Second")
        await settle(controller)
        await switching.value
        XCTAssertTrue(old.closed)
        XCTAssertEqual(made.map(\.0), [.claude, .codexLogin])
        XCTAssertNil(made[1].1)
        XCTAssertEqual(controller.conversation.account, .codexLogin)
        XCTAssertEqual(controller.conversation.sessionID, "new")
    }

    func testTurnThatEndsWithoutCompletionFailsWithoutResending() async {
        let runner = ScriptedRunner([.text("Partial")])
        let controller = MsgblastAgentController(store: MsgblastAgentStore(directory: directory)) { _, _ in runner }
        await controller.choose(.codexLogin)
        controller.send("Ask")
        await settle(controller)
        XCTAssertEqual(controller.status, .failed("The agent stopped before finishing."))
        XCTAssertEqual(runner.sent, ["Ask"])
    }

    func testStopEndsTheDemoTurnWithoutAFailure() async {
        let demo = DemoAgentRunner(agents: [.init(id: "web:chatgpt", name: "ChatGPT")], comparisonID: UUID(), pause: .seconds(30))
        let controller = MsgblastAgentController(store: MsgblastAgentStore(directory: directory)) { _, _ in demo }
        await controller.choose(.claude)
        controller.send("Ask")
        XCTAssertTrue(controller.isWorking)
        await controller.stop()
        XCTAssertEqual(controller.status, .idle)
        XCTAssertEqual(controller.conversation.messages.last?.note, true)
        XCTAssertNotNil(controller.conversation.messages.last?.created)
        XCTAssertEqual(controller.conversation.messages.map(\.role), [.person, .agent])
    }

    func testRepliesRenderMarkdownListsHeadingsAndLinks() {
        let link = "msgblast://comparison/\(UUID().uuidString)"
        let text = MsgblastAgentText.render("## Summary\n- **Codex** agrees\n  - nested\n2. [Open](\(link))\nPlain - not a list")
        XCTAssertEqual(text.string, "Summary\n•\tCodex agrees\n•\tnested\n2.\tOpen\nPlain - not a list")
        let codex = (text.string as NSString).range(of: "Codex")
        let font = text.attribute(.font, at: codex.location, effectiveRange: nil) as? NSFont
        XCTAssertTrue(font?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        let open = (text.string as NSString).range(of: "Open")
        XCTAssertEqual((text.attribute(.link, at: open.location, effectiveRange: nil) as? URL)?.absoluteString, link)
        let nested = (text.attribute(.paragraphStyle, at: (text.string as NSString).range(of: "nested").location, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertGreaterThan(nested?.firstLineHeadIndent ?? 0, 0)
    }

    func testDemoScriptLinksTheComparisonAndCompletes() {
        let id = UUID()
        let script = DemoAgentRunner(agents: [.init(id: "web:chatgpt", name: "ChatGPT"), .init(id: "web:claude", name: "Claude")], comparisonID: id).script
        XCTAssertEqual(script.last, .completed(sessionID: "demo-session"))
        XCTAssertTrue(script.contains { if case .text(let text) = $0 { text.contains("[Claude](msgblast://comparison/\(id.uuidString)?agent=web:claude)") } else { false } })
    }

    func testUnreadableOrNewerConversationIsNeverReplaced() async throws {
        let store = MsgblastAgentStore(directory: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for bytes in [Data("not json".utf8), Data(#"{"version":99,"messages":[]}"#.utf8)] {
            try bytes.write(to: store.url)
            let runner = ScriptedRunner([.completed(sessionID: "s")])
            let controller = MsgblastAgentController(store: store) { _, _ in runner }
            XCTAssertNotNil(controller.loadError)
            await controller.choose(.claude)
            controller.send("Ask")
            XCTAssertTrue(runner.sent.isEmpty)
            XCTAssertEqual(try Data(contentsOf: store.url), bytes)
        }
    }

    func testOlderFormatKeepsABackup() throws {
        let store = MsgblastAgentStore(directory: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bytes = Data(#"{"version":0,"messages":[{"id":"9C1F1F0E-7B44-4F5C-9C4E-2B9F1F7B3A10","role":"person","text":"Hi"}]}"#.utf8)
        try bytes.write(to: store.url)
        let loaded = try store.load()
        XCTAssertEqual(loaded.version, MsgblastAgentConversation.currentVersion)
        XCTAssertEqual(loaded.messages.map(\.text), ["Hi"])
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("msgblast-agent.v0.json")), bytes)
    }
}
