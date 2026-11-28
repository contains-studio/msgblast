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

    /// The agent's reply as the phone draws it: Markdown blocks with no raw `msgblast://` addresses,
    /// and the comparisons it linked, each shown once as a card. A link to one agent's reply
    /// stays inline as that agent's name.
    public static func reply(_ markdown: String, agentName: (String) -> String?) -> AgentReply {
        var comparisons: [UUID] = []
        func note(_ url: String) -> Bool {
            guard let link = URL(string: url).flatMap(comparison) else { return false }
            if link.agentID == nil, !comparisons.contains(link.id) { comparisons.append(link.id) }
            return link.agentID == nil
        }
        var text = markdown
        // Markdown links: a whole-comparison link becomes a card; an agent link keeps its text.
        text = replace(#"\[([^\]]*)\]\((msgblast://comparison/[^)\s]+)\)"#, in: text) { groups in note(groups[2]) ? "" : groups[0] }
        // Bare addresses: a whole comparison becomes a card; an agent's becomes its name as a link.
        text = replace(#"(?<!\()msgblast://comparison/[^\s)\]]+"#, in: text) { groups in
            if note(groups[0]) { return "" }
            let agent = URL(string: groups[0]).flatMap(comparison)?.agentID
            return "[\(agent.flatMap(agentName) ?? agent ?? "Reply")](\(groups[0]))"
        }
        return AgentReply(blocks: blocks(text), comparisons: comparisons)
    }

    /// Paragraphs, headings and list items, nested by indent. Inline Markdown stays in each block's text.
    static func blocks(_ text: String) -> [AgentBlock] {
        var blocks: [AgentBlock] = [], paragraph: [String] = []
        func flush() { if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] } }
        for raw in text.components(separatedBy: "\n") {
            let line = tidy(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { flush(); continue }
            if let match = trimmed.firstMatch(of: /^#{1,6}\s+(.+)$/) { flush(); blocks.append(.heading(String(match.1))); continue }
            if let match = line.firstMatch(of: /^(\s*)([-*+•]|\d+[.)])\s+(.+)$/) {
                flush()
                let marker = match.2.first?.isNumber == true ? String(match.2) : "•"
                blocks.append(.item(String(match.3), marker: marker, level: match.1.count / 2))
                continue
            }
            paragraph.append(trimmed)
        }
        flush()
        return blocks
    }

    /// Drops the separators a removed link leaves behind ("Open · Claude" becomes "Claude").
    private static func tidy(_ line: String) -> String {
        var line = line.replacing(/(\s*·\s*){2,}/, with: " · ")
        line = line.replacing(/^(\s*)·\s*/) { "\($0.1)" }
        line = replace(#"(?<=\S) {2,}"#, in: line) { _ in " " }
        return line.replacing(/\s*·\s*$/, with: "")
    }

    private static func replace(_ pattern: String, in text: String, with transform: ([String]) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        var result = text
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            let groups = (0..<match.numberOfRanges).map { Range(match.range(at: $0), in: text).map { String(text[$0]) } ?? "" }
            if let range = Range(match.range, in: result) { result.replaceSubrange(range, with: transform(groups)) }
        }
        return result
    }
}

public struct AgentReply: Equatable, Sendable {
    public var blocks: [AgentBlock]
    public var comparisons: [UUID]
}

public enum AgentBlock: Equatable, Sendable {
    case paragraph(String)
    case heading(String)
    /// A list item: "•" or its number, and how deep it is nested.
    case item(String, marker: String, level: Int)
}
