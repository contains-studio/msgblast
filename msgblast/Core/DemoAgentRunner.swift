import Foundation

/// Plays a scripted turn for Demo. It starts no CLI and uses no account.
public final class DemoAgentRunner: MsgblastAgentRunner {
    public struct Agent: Sendable {
        public let id: String, name: String
        public init(id: String, name: String) { self.id = id; self.name = name }
    }
    private let agents: [Agent]
    private let comparisonID: UUID
    private let pause: Duration
    private var playing: Task<Void, Never>?

    public init(agents: [Agent], comparisonID: UUID, pause: Duration = .milliseconds(900)) {
        self.agents = agents; self.comparisonID = comparisonID; self.pause = pause
    }

    public var script: [MsgblastAgentEvent] {
        let names = agents.map(\.name).formatted(.list(type: .and))
        let link = "msgblast://comparison/\(comparisonID.uuidString)"
        let replies = agents.map { "[\($0.name)](\(link)?agent=\($0.id))" }.joined(separator: " · ")
        return [
            .tool(name: "msgblast_agents_list", finished: false, failed: false),
            .tool(name: "msgblast_agents_list", finished: true, failed: false),
            .tool(name: "msgblast_blast_start", finished: false, failed: false),
            .tool(name: "msgblast_blast_start", finished: true, failed: false),
            .text("Submitted to \(names).\n\n"),
            .tool(name: "msgblast_blast_wait", finished: false, failed: false),
            .tool(name: "msgblast_blast_wait", finished: true, failed: false),
            .tool(name: "msgblast_comparison_read", finished: false, failed: false),
            .tool(name: "msgblast_comparison_read", finished: true, failed: false),
            .text("\(names) replied. They agree on comparing clarity, cost and reversibility; one suggests a small trial first.\n\n"
                + "[Open the comparison](\(link)) · \(replies)\n\nDemo · simulated replies."),
            .completed(sessionID: "demo-session"),
        ]
    }

    public func send(_ text: String) -> AsyncStream<MsgblastAgentEvent> {
        let (stream, continuation) = AsyncStream<MsgblastAgentEvent>.makeStream()
        playing = Task { [script, pause] in
            for event in script {
                do { try await Task.sleep(for: pause) } catch { continuation.yield(.failed("Stopped.")); break }
                continuation.yield(event)
            }
            continuation.finish()
        }
        return stream
    }

    public func interrupt() async {
        playing?.cancel()
        await playing?.value
    }

    public func close() async { await interrupt() }
}
