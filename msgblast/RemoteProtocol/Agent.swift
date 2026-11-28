import Foundation

/// The msgblast agent's conversation and status on the Mac, sent as `RemoteMessage.agent` after
/// each subscribe and whenever either changes. It stays out of the event journal, so an older
/// phone ignores it, and a phone that never receives one is paired with a Mac without the agent.
public struct RemoteAgentChat: Codable, Hashable, Sendable {
    public struct State: RemoteOpenValue {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public static let idle: Self = "idle"
        public static let working: Self = "working"
        public static let failed: Self = "failed"
    }
    /// The account the Mac thinks with ("Claude Code", "ChatGPT"); nil until one is set up on the Mac.
    public var account: String?
    public var state: State
    /// One short line: the current step while working, what went wrong when failed.
    public var line: String?
    /// The Mac's full text when `line` was shortened.
    public var detail: String?
    /// The newest messages' ids, oldest first.
    public var messageIDs: [UUID]
    /// The listed messages that are new or changed since the previous update; all of them in the first after a subscribe.
    public var messages: [RemoteAgentMessage]
    public init(account: String?, state: State, line: String? = nil, detail: String? = nil, messageIDs: [UUID], messages: [RemoteAgentMessage]) {
        self.account = account; self.state = state; self.line = line; self.detail = detail; self.messageIDs = messageIDs; self.messages = messages
    }
    /// The most messages one update lists.
    public static let maximumMessages = 100
}

public struct RemoteAgentMessage: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    /// True for what the person asked; false for the agent's reply.
    public var fromPerson: Bool
    /// Markdown. Comparison links are `msgblast://comparison/<id>`, optionally with `?agent=<agent id>`.
    public var text: String
    /// When it was written on the Mac; nil when the Mac did not record it.
    public var created: Date?
    /// A small centred status line, such as "Stopped", rather than a bubble. Older Macs never set it.
    public var note: Bool?
    public init(id: UUID, fromPerson: Bool, text: String, created: Date? = nil, note: Bool? = nil) {
        self.id = id; self.fromPerson = fromPerson; self.text = text; self.created = created; self.note = note
    }
}
