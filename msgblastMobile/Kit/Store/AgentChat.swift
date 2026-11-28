import Foundation
import msgblastRemoteProtocol

/// The phone's copy of the Mac's msgblast agent conversation. Each update lists the messages in
/// order and carries only those that changed, so it is merged into the cached copy.
public enum AgentChat {
    public static func merge(_ update: RemoteAgentChat, into cached: RemoteAgentChat?) -> RemoteAgentChat {
        let known = Dictionary((cached?.messages ?? []).map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
            .merging(update.messages.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        var next = update
        next.messages = update.messageIDs.compactMap { known[$0] }
        return next
    }

    /// A summary link the agent wrote: `msgblast://comparison/<id>`, optionally `?agent=<agent id>`.
    public static func comparison(_ url: URL) -> (id: UUID, agentID: String?)? {
        guard url.scheme == "msgblast", url.host == "comparison", let id = UUID(uuidString: url.lastPathComponent) else { return nil }
        return (id, URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "agent" }?.value)
    }
}
