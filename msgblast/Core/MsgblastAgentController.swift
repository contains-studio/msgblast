import Combine
import Foundation

public enum MsgblastAgentStatus: Equatable, Sendable {
    case idle
    /// `tool` is the msgblast tool the agent is running, if any.
    case working(tool: String?)
    case failed(String)
}

/// Owns the built-in agent's conversation and its current runner.
@MainActor
public final class MsgblastAgentController: ObservableObject {
    public typealias RunnerFactory = @MainActor (MsgblastAgentAccount, _ sessionID: String?) throws -> MsgblastAgentRunner
    @Published public private(set) var conversation = MsgblastAgentConversation()
    @Published public private(set) var status = MsgblastAgentStatus.idle
    /// Set when the saved conversation could not be read; nothing is sent or saved until it is repaired.
    public let loadError: String?
    private let store: MsgblastAgentStore
    private let makeRunner: RunnerFactory
    private var runner: MsgblastAgentRunner?
    private var turn: Task<Void, Never>?
    private var stopping = false

    public init(store: MsgblastAgentStore, makeRunner: @escaping RunnerFactory) {
        self.store = store
        self.makeRunner = makeRunner
        do { conversation = try store.load(); loadError = nil }
        catch { loadError = "The msgblast agent conversation could not be loaded: \(error.localizedDescription)" }
    }

    public var isWorking: Bool {
        if case .working = status { return true }
        return false
    }

    /// A session id belongs to one CLI, so a new account starts a new session.
    public func choose(_ account: MsgblastAgentAccount) async {
        guard loadError == nil, !isWorking, conversation.account != account else { return }
        conversation.account = account
        conversation.sessionID = nil
        save()
        await closeRunner()
    }

    public func send(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard loadError == nil, !isWorking, !text.isEmpty, let account = conversation.account else { return }
        conversation.messages.append(MsgblastAgentMessage(role: .person, text: text))
        // Check storage before a turn that spends the person's plan.
        do { try store.save(conversation) } catch { conversation.messages.removeLast(); fail(error); return }
        let current: MsgblastAgentRunner
        do { current = try runner ?? makeRunner(account, conversation.sessionID) } catch { fail(error); return }
        runner = current
        status = .working(tool: nil)
        stopping = false
        let events = current.send(text)
        turn = Task { [weak self] in
            var ended = false
            for await event in events {
                guard let self else { return }
                ended = self.apply(event) || ended
            }
            guard let self, !ended else { return }
            self.finish(self.stopping ? .idle : .failed("The agent stopped before finishing."))
        }
    }

    /// Stops the current turn. Anything already submitted stays submitted.
    public func stop() async {
        guard isWorking, let runner else { return }
        stopping = true
        await Self.call(RunnerBox(runner)) { await $0.interrupt() }
        await turn?.value
    }

    public func close() async {
        await stop()
        await closeRunner()
    }

    /// Returns true once the turn has ended.
    private func apply(_ event: MsgblastAgentEvent) -> Bool {
        switch event {
        case .text(let text):
            if let last = conversation.messages.last, last.role == .agent, last.stopped != true {
                conversation.messages[conversation.messages.count - 1].text += text
            }
            else { conversation.messages.append(MsgblastAgentMessage(role: .agent, text: text)) }
            return false
        case .tool(let name, let finished, _):
            status = .working(tool: finished ? nil : name)
            return false
        case .completed(let sessionID):
            conversation.sessionID = sessionID
            finish(.idle)
        case .failed(let message):
            finish(stopping ? .idle : .failed(message))
        }
        return true
    }

    private func finish(_ next: MsgblastAgentStatus) {
        if stopping { conversation.messages.append(MsgblastAgentMessage(role: .agent, text: "Stopped", stopped: true)) }
        status = next
        stopping = false
        turn = nil
        save()
    }

    private func save() {
        do { try store.save(conversation) } catch { fail(error) }
    }

    private func fail(_ error: Error) { status = .failed(error.localizedDescription) }

    private func closeRunner() async {
        guard let closing = runner else { return }
        runner = nil
        await Self.call(RunnerBox(closing)) { await $0.close() }
    }

    /// The controller is a runner's only caller, one call at a time, so it can hand the runner to its own executor.
    private struct RunnerBox: @unchecked Sendable {
        let runner: MsgblastAgentRunner
        init(_ runner: MsgblastAgentRunner) { self.runner = runner }
    }
    private nonisolated static func call(_ box: RunnerBox, _ body: @Sendable (MsgblastAgentRunner) async -> Void) async {
        await body(box.runner)
    }
}
