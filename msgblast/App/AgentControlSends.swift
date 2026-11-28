import Foundation
import msgblastCore
import msgblastRemoteProtocol

/// Runs outside agents' sends through the iPhone controller's command executor and the
/// Mac's own send paths, so they get every duplicate-send guard and are never retried.
/// Agent sends take turns. While the phone or the Mac UI is sending, an agent's send is
/// refused as "Mac busy" rather than waiting behind it.
///
/// Full access is what allows an agent to message Messages contacts, so the phone's
/// "Send iMessages from the phone" setting does not apply here.
@MainActor final class AgentControlSends {
    let executor: RemoteCommandExecutor
    private let activity: AgentControlActivity
    private unowned let model: AppModel
    private let host: AppRemoteHost
    private let availability: AvailabilityModel

    init(model: AppModel, source: TelemetryProperties.Source = .outsideAgent) {
        self.model = model
        let remote = model.remote
        // AppRemoteHost reads settings only on the main actor.
        let settings = { () -> RemoteSettings in
            var settings = MainActor.assumeIsolated { remote.settings }
            settings.allowMessagesSends = true
            return settings
        }
        let availability = AvailabilityModel(sessions: { [unowned model] in model.webAgents.sessions },
                                             inputs: { [unowned model] in model.remoteAvailabilityInputs(settings: settings()) })
        self.availability = availability
        host = AppRemoteHost(model: model, availability: availability, avatars: remote.avatars, keepAwake: remote.keepAwake, power: remote.power, source: source, settings: settings)
        executor = RemoteCommandExecutor(host: host)
        activity = model.agentSendActivity
    }

    /// Shows the send in the banner and the activity list, and refuses new sends while the person has stopped them.
    /// A new send waits for earlier agent sends, then refreshes permissions and app installs, as the phone's
    /// probe loop does while it is connected, so readiness is current. A repeat returns its stored result.
    func send(_ command: RemoteCommand, client: String, isAuthorized: @MainActor () -> Bool = { true }) async -> RemoteCommandResult {
        let id = command.clientCommandID
        let result = await activity.run(command, client: client, isKnown: { self.executor.status(of: id).code != .unknownCommand },
                                        prepare: { await self.model.remoteAvailabilityProbe(slow: false) }) { command in
            guard isAuthorized() else { return .rejected(id, .invalidCommand, "The account or send selection changed.") }
            return await self.executor.execute(command)
        }
        // The person asked the msgblast agent, so note who it sent to and show the comparison its blast or follow-up went to.
        if client == MsgblastAgent.clientName, result.outcome == .applied, !result.replayed {
            model.noteAgentSend(command.action, comparison: result.conversationID)
            switch command.action {
            case .createConversation, .sendShared: result.conversationID.map(model.showAgentComparison)
            default: break
            }
        }
        return result
    }
}

extension AppModel {
    /// Adds "Sent to Codex CLI and Claude Code" to the msgblast agent's conversation for one of its sends.
    func noteAgentSend(_ action: RemoteAction, comparison: UUID?) {
        let ids: [String]
        switch action {
        case .createConversation(_, let agents, _): ids = agents
        case .sendShared(_, _, let agents, _):
            ids = agents.isEmpty ? (comparison.flatMap(self.comparison)?.resolvedWebAgentIDs.map(\.id) ?? []) : agents
        case .sendPrivate(_, let agent, _, _): ids = [agent]
        default: return
        }
        let names = ids.compactMap { id in webAgents.sessions.first { $0.id.id == id || $0.id.gridID.id == id }?.name }
        guard !names.isEmpty else { return }
        msgblastAgent.note("Sent to \(names.formatted(.list(type: .and)))")
    }
    func controlSend(_ command: RemoteCommand, client: String) async -> RemoteCommandResult { await agentSends.send(command, client: client) }
    func controlSendStatus(_ id: UUID) -> RemoteCommandResult { agentSends.executor.status(of: id) }
}
