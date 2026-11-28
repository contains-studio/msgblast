import XCTest
@testable import msgblastMobileKit
import msgblastRemoteProtocol

final class AgentChatTests: XCTestCase {
    private let question = RemoteAgentMessage(id: UUID(), fromPerson: true, text: "Compare plans")

    func testUpdatesMergeChangedMessagesIntoTheCachedOrder() {
        var reply = RemoteAgentMessage(id: UUID(), fromPerson: false, text: "Sub")
        let first = AgentChat.merge(RemoteAgentChat(account: "Claude Code", state: .working, line: "Sending…", messageIDs: [question.id, reply.id], messages: [question, reply]), into: nil)
        reply.text = "Submitted to Claude."
        let next = AgentChat.merge(RemoteAgentChat(account: "Claude Code", state: .idle, messageIDs: [question.id, reply.id], messages: [reply]), into: first)
        XCTAssertEqual(next.messages, [question, reply])
        XCTAssertEqual(next.state, .idle)
        XCTAssertNil(next.line)
        let trimmed = AgentChat.merge(RemoteAgentChat(account: nil, state: .idle, messageIDs: [reply.id], messages: []), into: next)
        XCTAssertEqual(trimmed.messages, [reply], "Messages the Mac no longer lists go")
        XCTAssertNil(trimmed.account)
    }

    func testSummaryLinksNameAComparisonAndOptionallyAnAgent() throws {
        let id = UUID()
        let link = try XCTUnwrap(AgentChat.comparison(URL(string: "msgblast://comparison/\(id.uuidString)?agent=claude")!))
        XCTAssertEqual(link.id, id)
        XCTAssertEqual(link.agentID, "claude")
        XCTAssertNil(AgentChat.comparison(URL(string: "msgblast://comparison/\(id.uuidString)")!)?.agentID)
        XCTAssertNil(AgentChat.comparison(URL(string: "https://example.com/comparison/\(id.uuidString)")!))
        XCTAssertNil(AgentChat.comparison(URL(string: "msgblast://pair?offer=x")!))
    }

    func testRepliesHideAddressesAndCardEachComparisonOnce() {
        let id = UUID(), other = UUID()
        let link = "msgblast://comparison/\(id.uuidString)"
        let text = "**Claude** and Codex replied.\n\n[Open the comparison](\(link)) · [Claude](\(link)?agent=claude) · \(link)?agent=codexCLI\n\nAlso msgblast://comparison/\(other.uuidString) and \(link)"
        let reply = AgentChat.reply(text) { $0 == "codexCLI" ? "Codex CLI" : nil }
        XCTAssertEqual(reply.comparisons, [id, other])
        XCTAssertEqual(reply.blocks, [
            .paragraph("**Claude** and Codex replied."),
            .paragraph("[Claude](\(link)?agent=claude) · [Codex CLI](\(link)?agent=codexCLI)"),
            .paragraph("Also and"),
        ])
    }

    func testRepliesKeepHeadingsAndNestedNumberedLists() {
        let blocks = AgentChat.reply("## Summary\n- **Trofie** wins\n  - twists hold sauce\n2. Linguine\nPlain - not a list", agentName: { _ in nil }).blocks
        XCTAssertEqual(blocks, [
            .heading("Summary"),
            .item("**Trofie** wins", marker: "•", level: 0),
            .item("twists hold sauce", marker: "•", level: 1),
            .item("Linguine", marker: "2.", level: 0),
            .paragraph("Plain - not a list"),
        ])
    }

    @MainActor func testTheChatIsCachedTheDraftClearsOnceAskedAndForgetClearsBoth() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mobile-agent-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try MobileStore(database: try LocalDatabase(url: url))
        XCTAssertNil(store.agentChat, "No agent until a Mac with one sends it")
        store.handle(.agent(RemoteAgentChat(account: "ChatGPT", state: .idle, messageIDs: [question.id], messages: [question])))
        store.setDraft("Ask again", for: MobileStore.agentDraftKey)
        let ask = RemoteCommand(action: .sendToAgent(text: "Ask again"))
        try store.recordSent(ask)
        XCTAssertEqual(store.commands[ask.clientCommandID]?.text, "Ask again")
        store.handle(.commandResult(RemoteCommandResult(clientCommandID: ask.clientCommandID, outcome: .applied)))
        XCTAssertEqual(store.draft(MobileStore.agentDraftKey), "")
        store.saveNow()
        let reopened = try MobileStore(database: try LocalDatabase(url: url))
        XCTAssertEqual(reopened.agentChat?.messages, [question], "Shown from the cache before the Mac answers")
        XCTAssertEqual(reopened.agentChat?.account, "ChatGPT")
        reopened.forgetMac()
        XCTAssertNil(reopened.agentChat)
        XCTAssertNil(try MobileStore(database: try LocalDatabase(url: url)).agentChat)
    }
}
