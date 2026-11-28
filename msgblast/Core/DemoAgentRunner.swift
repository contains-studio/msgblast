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
    /// Called when the scripted blast is sent, so the app can note it as it does for a real one.
    private let sent: @Sendable () -> Void
    private var playing: Task<Void, Never>?

    public init(agents: [Agent], comparisonID: UUID, pause: Duration = .milliseconds(900), sent: @escaping @Sendable () -> Void = {}) {
        self.agents = agents; self.comparisonID = comparisonID; self.pause = pause; self.sent = sent
    }

    public var script: [MsgblastAgentEvent] {
        let link = "msgblast://comparison/\(comparisonID.uuidString)"
        let replies = agents.map { "- **[\($0.name)](\(link)?agent=\($0.id))** replied." }.joined(separator: "\n")
        return [
            .tool(name: "msgblast_agents_list", finished: false, failed: false),
            .tool(name: "msgblast_agents_list", finished: true, failed: false),
            .tool(name: "msgblast_blast_start", finished: false, failed: false),
            .tool(name: "msgblast_blast_start", finished: true, failed: false),
            .tool(name: "msgblast_blast_wait", finished: false, failed: false),
            .tool(name: "msgblast_blast_wait", finished: true, failed: false),
            .tool(name: "msgblast_comparison_read", finished: false, failed: false),
            .tool(name: "msgblast_comparison_read", finished: true, failed: false),
            .text("They agree on comparing clarity, cost and reversibility; one suggests a small trial first.\n\n"
                + "\(replies)\n\n[Open the comparison](\(link)) · Demo, simulated replies."),
            .completed(sessionID: "demo-session"),
        ]
    }

    public func send(_ text: String) -> AsyncStream<MsgblastAgentEvent> {
        let (stream, continuation) = AsyncStream<MsgblastAgentEvent>.makeStream()
        playing = Task { [script, pause, sent] in
            for event in script {
                do { try await Task.sleep(for: pause) } catch { continuation.yield(.failed("Stopped.")); break }
                continuation.yield(event)
                if event == .tool(name: "msgblast_blast_start", finished: true, failed: false) { sent() }
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
