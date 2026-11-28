import Foundation
import msgblastRemoteProtocol

public extension MsgblastAgentAccount {
    /// The name the agent bar and the phone show.
    var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codexLogin: "ChatGPT · Codex"
        case .chatGPT: "ChatGPT plan"
        }
    }
}

public extension MsgblastAgent {
    /// One short line for the step the agent is on. `agentCount` is how many agents its newest send went to.
    static func stepLine(tool: String?, agentCount: Int?) -> String {
        switch tool {
        case "msgblast_agents_list": return "Looking at your agents…"
        case "msgblast_blast_start", "msgblast_blast_follow_up", "msgblast_agent_message": return "Sending…"
        case "msgblast_blast_wait":
            guard let agentCount else { return "Waiting for replies…" }
            return "Sent to \(agentCount == 1 ? "1 agent" : "\(agentCount) agents") · waiting for replies…"
        case "msgblast_comparison_read": return "Reading replies…"
        default: return "Thinking…"
        }
    }

    @MainActor static func latestAgentCount(_ activity: AgentControlActivity) -> Int? {
        activity.log.entries.first { $0.client == clientName }?.agentCount
    }
}

public extension MsgblastAgentController {
    /// The conversation and status as the phone shows them: its newest messages, all listed.
    func remoteChat(agentCount: Int?) -> RemoteAgentChat {
        let messages = conversation.messages.suffix(RemoteAgentChat.maximumMessages).map { RemoteAgentMessage(id: $0.id, fromPerson: $0.role == .person, text: $0.text, created: $0.created, note: $0.note) }
        var chat = RemoteAgentChat(account: conversation.account?.displayName, state: .idle, messageIDs: messages.map(\.id), messages: messages)
        if let loadError {
            chat.state = .failed
            (chat.line, chat.detail) = ("Can't read the agent conversation on your Mac", loadError)
            return chat
        }
        switch status {
        case .idle: break
        case .working(let tool): chat.state = .working; chat.line = MsgblastAgent.stepLine(tool: tool, agentCount: agentCount)
        case .failed(let message): chat.state = .failed; (chat.line, chat.detail) = RemotePhoneText.split(message)
        }
        return chat
    }
}
