import Foundation

/// The msgblast agent on the person's own account. It opens the Claude Code or Codex session on the
/// first turn with a new session key, and revokes that key when the session closes, when Stop ends a
/// turn, or when msgblast quits. After Stop, the next turn opens a new session that resumes the conversation.
public actor LiveAgentRunner: MsgblastAgentRunner {
    public typealias Open = @Sendable (_ sessionKey: String, _ sessionID: String?) async throws -> MsgblastAgentRunner
    private let open: Open
    private let keys: AgentSessionKeys
    private var session: (runner: MsgblastAgentRunner, key: String)?
    private var sessionID: String?
    private var interrupted = false

    public init(keys: AgentSessionKeys, sessionID: String?, open: @escaping Open) {
        self.keys = keys; self.sessionID = sessionID; self.open = open
    }

    public nonisolated func send(_ text: String) -> AsyncStream<MsgblastAgentEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: MsgblastAgentEvent.self)
        Task { await run(text, continuation) }
        return stream
    }

    private func run(_ text: String, _ continuation: AsyncStream<MsgblastAgentEvent>.Continuation) async {
        interrupted = false
        var failed = false
        do {
            let runner = try await opened()
            if !interrupted {
                for await event in runner.send(text) {
                    if case .completed(let id) = event { sessionID = id }
                    if case .failed = event { failed = true }
                    continuation.yield(event)
                }
            }
        } catch { continuation.yield(.failed(error.localizedDescription)) }
        if interrupted || failed { await end() }
        continuation.finish()
    }

    private func opened() async throws -> MsgblastAgentRunner {
        if let session { return session.runner }
        let key = await keys.issue()
        do {
            let runner = try await open(key, sessionID)
            session = (runner, key)
            return runner
        } catch {
            await keys.revoke(key)
            throw error
        }
    }

    public func interrupt() async {
        interrupted = true
        guard let runner = session?.runner else { return }
        await Self.call(Box(runner: runner)) { await $0.interrupt() }
    }

    public func close() async {
        interrupted = true
        await end()
    }

    private func end() async {
        guard let ending = session else { return }
        session = nil
        await Self.call(Box(runner: ending.runner)) { await $0.close() }
        await keys.revoke(ending.key)
    }

    /// This actor is a session's only caller, one call at a time, so it can hand the session to its own executor.
    private struct Box: @unchecked Sendable { let runner: MsgblastAgentRunner }
    private nonisolated static func call(_ box: Box, _ body: @Sendable (MsgblastAgentRunner) async -> Void) async {
        await body(box.runner)
    }
}
