import Foundation

/// The built-in msgblast agent: a chat that drives msgblast through its own MCP tools,
/// thinking with the person's Claude Code or ChatGPT account.
public enum MsgblastAgent {
    /// The MCP client name reserved for the built-in agent. Only a caller with a live session key gets it.
    public static let clientName = "msgblast agent"
    /// The environment variable `msgblast mcp` reads the session key from.
    public static let sessionKeyEnvironment = "MSGBLAST_AGENT_SESSION_KEY"

    /// The stdio MCP server entry a runner gives its CLI as server `msgblast`.
    public static func mcpServer(executable: String, sessionKey: String) -> [String: Any] {
        ["command": executable, "args": ["mcp"], "env": [sessionKeyEnvironment: sessionKey]]
    }
}

public enum MsgblastAgentAccount: String, Codable, Sendable { case claude, codexLogin, chatGPT }

public enum MsgblastAgentEvent: Equatable, Sendable {
    /// Streamed reply text from the agent.
    case text(String)
    /// The agent called a tool; `finished` is false when it starts.
    case tool(name: String, finished: Bool, failed: Bool)
    /// The turn ended. `sessionID` resumes the conversation later.
    case completed(sessionID: String)
    case failed(String)
}

/// One conversation with the agent. `send` starts a turn whose events end with `.completed` or `.failed`.
public protocol MsgblastAgentRunner: AnyObject {
    func send(_ text: String) -> AsyncStream<MsgblastAgentEvent>
    func interrupt() async
    func close() async
}
