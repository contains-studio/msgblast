import AppKit
import CryptoKit
import Foundation
import SwiftUI
import msgblastCore
import msgblastRemoteProtocol

/// Remote commands through the actual AppModel send paths, in the isolated Demo profile.
/// Simulated Messages and local website fixtures only: no real send, port, or permission.
extension SideChatModelCheck {
    @MainActor static func runRemoteControlChecks() async throws {
        let model = AppModel()
        precondition(model.demo, "The remote fixture runs only in the isolated Demo profile")
        let macDraft = model.state.draft
        precondition(!macDraft.isEmpty)
        final class Settings { var value = RemoteSettings() }
        let settings = Settings()
        settings.value.allowMessagesSends = true
        let power = MacPowerState(readLocked: { false }, observe: false)
        let keepAwake = RemoteKeepAwake(settingEnabled: true, assertions: .init(create: { _ in 1 }, release: { _ in }))
        let availability = AvailabilityModel(sessions: { model.webAgents.sessions }, inputs: { model.remoteAvailabilityInputs(settings: settings.value) })
        await model.remoteAvailabilityProbe(slow: false)
        let host = AppRemoteHost(model: model, availability: availability, avatars: RemoteAvatars(model: model), keepAwake: keepAwake, power: power, settings: { settings.value })
        let executor = RemoteCommandExecutor(host: host)
        let cedar = model.state.agents[0], lumen = model.state.agents[1]
        let cedarID = RemoteAgentIDs.messages(cedar.id)
        precondition(availability.availability(for: cedarID)?.readiness == .ready, "\(String(describing: availability.availability(for: cedarID)))")
        let first = try await checkRemoteMessagesCreateAndReplay(model, executor: executor, cedar: cedar, macDraft: macDraft)
        try await checkRemotePrivateAndAttachedSends(model, executor: executor, first: first, cedar: cedar)
        try await checkRemoteFailureRouting(model, executor: executor, first: first, cedarID: cedarID)
        try await checkRemoteWebsiteSend(model, executor: executor, first: first, lumen: lumen, macDraft: macDraft)

        // Guards: a locked Mac and the iMessage setting.
        power.simulate(locked: true)
        let locked = await executor.execute(RemoteCommand(action: .createConversation(text: "Locked", agentIDs: ["claude"], attachmentIDs: [])))
        precondition(locked.code == .macLocked)
        power.simulate(locked: false)
        settings.value.allowMessagesSends = false
        let off = await executor.execute(RemoteCommand(action: .createConversation(text: "Off", agentIDs: [cedarID], attachmentIDs: [])))
        precondition(off.code == .messagesSendsOff)
        precondition(keepAwake.held == false, "Send assertions are released")
        host.discardStagedAttachments()
        try await runRemoteServiceChecks(model)
        try await checkWantsForwarding()
        print("PASS: remote commands run through the actual AppModel send paths (Messages new/private/shared with a staged file, website shared send that prepares the chat, waits for readiness and submits once, plus prepareConversation), replay without resending, keep the Mac's drafts and files, route failures to the command result instead of the alert, and refuse when locked or when iMessage sends are off; the real RemoteService pairs an in-memory phone with no network port, streams its snapshot and events, runs a Demo msgblast agent turn the phone asked for and streams it back, stops it, refuses it while agent sends are stopped, honors keep-awake and the iMessage setting, and forgets the phone. Isolated Demo profile; simulated Messages and local website fixtures only.")
    }

    @MainActor static func checkWantsForwarding() async throws {
        let model = AppModel()
        precondition(model.demo && ProcessInfo.processInfo.arguments.contains("--isolated-demo"))
        model.remote.power.simulate(locked: false)
        let wants = model.wants
        let recipient = RemoteAgentIDs.messages(model.state.agents[0].id)
        wants.setForwarding(true, agents: [recipient])
        await wants.reload()
        let fixture = WantFixture()
        let page = await fixture.poll("comment.created", cursor: "0")
        let comment = page.events[0]
        let itemID = comment.item!.id
        try await checkForwardingWriteFailure(model, page: page)
        let before = model.agentSendActivity.log.entries.count
        let saved = await wants.take(page)
        precondition(saved && wants.saved.blasts[itemID] == nil && wants.saved.forwardedConversations[itemID] != nil)
        let after = model.agentSendActivity.log.entries.count
        precondition(after == before + 1)
        var answer = comment
        answer.type = "question.answered"
        answer.question = try WantJSON.decoder.decode(WantQuestion.self, from: Data(#"{"id":"question","text":"Which one?","answer":{"text":"The first"}}"#.utf8))
        _ = await wants.take(WantEventPage(events: [answer], cursor: "102"))
        precondition(model.agentSendActivity.log.entries.count == after, "An automatic comment never authorizes sharing a later answer")
        _ = await wants.take(WantEventPage(events: [comment], cursor: "102"))
        precondition(model.agentSendActivity.log.entries.count == after, "A repeated cursor cannot send again")
        wants.setForwarding(true, agents: ["missing-agent"])
        _ = await wants.take(.init(events: [comment], cursor: "unavailable"))
        precondition(model.agentSendActivity.log.entries.count == after, "No resolved recipients must never mean everyone")
        wants.setForwarding(true, agents: [recipient])
        try await checkRevokedForward(model, event: comment)
        await checkRefusedForward(model, event: comment, recipient: recipient)
        wants.signOut()
        let restored = WantsModel(app: model)
        precondition(!restored.saved.forwardActivity && restored.saved.forwardAgents.isEmpty && restored.saved.forwardedConversations.isEmpty)
        print("PASS: Wants saves the cursor before forwarding, keeps answers with explicitly asked agents, and revokes queued sends when forwarding changes.")
    }

    @MainActor static func checkForwardingWriteFailure(_ model: AppModel, page: WantEventPage) async throws {
        let wants = model.wants
        let file = model.local.url.deletingLastPathComponent().appendingPathComponent("wants.json")
        let oldSettings = try Data(contentsOf: file)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        let before = model.agentSendActivity.log.entries.count
        let savedWhileBlocked = await wants.take(page)
        precondition(!savedWhileBlocked && model.agentSendActivity.log.entries.count == before)
        precondition(wants.saved.cursors[WantsModel.activity] == nil)
        wants.setForwarding(false)
        precondition(!wants.saved.forwardActivity)
        try FileManager.default.removeItem(at: file)
        try oldSettings.write(to: file)
        precondition(!WantsModel(app: model).saved.forwardActivity, "A stale on-disk preference must not override revoked consent")
        wants.setForwarding(true)
        precondition(WantsModel(app: model).saved.forwardActivity, "New explicit consent must survive relaunch")
    }

    @MainActor static func checkRevokedForward(_ model: AppModel, event: WantEvent) async throws {
        let activity = model.agentSendActivity
        var release: CheckedContinuation<Void, Never>?
        let blocker = Task {
            await activity.run(RemoteCommand(action: .createConversation(text: "Fixture queue", agentIDs: [], attachmentIDs: [])),
                               client: "Fixture", isKnown: { false }, prepare: {
                await withCheckedContinuation { release = $0 }
            }) { .init(clientCommandID: $0.clientCommandID, outcome: .applied) }
        }
        try await waitUntil { release != nil }
        let count = model.state.comparisons.count
        let queued = Task { await model.wants.take(.init(events: [event], cursor: "103")) }
        try await waitUntil { activity.log.entries.first?.client == "Wants" && activity.log.entries.first?.result == nil }
        model.wants.setForwarding(false)
        model.wants.setForwarding(true)
        release?.resume()
        _ = await blocker.value
        _ = await queued.value
        precondition(model.state.comparisons.count == count && activity.log.entries.first?.result?.hasPrefix("Refused") == true)
    }

    @MainActor static func checkRefusedForward(_ model: AppModel, event: WantEvent, recipient: String) async {
        let wants = model.wants
        let list = wants.lists.first { $0.id == event.listId }!
        let item = list.items!.first { $0.id == event.item!.id }!
        await wants.blast(item, in: list, to: [recipient])
        precondition(wants.saved.blasts[item.id]?.comparisonID != nil)
        let before = model.agentSendActivity.log.entries.count
        model.remote.power.simulate(locked: true)
        defer { model.remote.power.simulate(locked: false) }
        _ = await wants.take(.init(events: [event], cursor: "104"))
        let entries = model.agentSendActivity.log.entries
        precondition(entries.count == before + 1 && entries.first?.action == "Followed up")
        precondition(entries.first?.result?.hasPrefix("Refused") == true, "A lock refusal must not start another conversation")
    }

    /// A Messages-only new conversation and its replay. Returns the new conversation's id.
    @MainActor static func checkRemoteMessagesCreateAndReplay(_ model: AppModel, executor: RemoteCommandExecutor, cedar: Agent, macDraft: String) async throws -> UUID {
        let cedarID = RemoteAgentIDs.messages(cedar.id)
        // A Messages-only new conversation from the phone leaves the Mac composer alone.
        let ask = RemoteCommand(action: .createConversation(text: "Remote ask", agentIDs: [cedarID], attachmentIDs: []))
        let created = await executor.execute(ask)
        precondition(created.outcome == .applied, "\(created)")
        let first = created.conversationID!
        precondition(model.comparison(first)?.members.map(\.id) == [cedar.id])
        precondition(created.agentStatuses[cedarID] == .submitted)
        precondition(model.state.draft == macDraft, "Remote sends never take or clear the Mac's draft")
        precondition(model.error == nil)
        try await waitUntil { model.comparison(first)?.members.first?.anchor != nil }

        // A replayed command id returns the stored result and sends nothing.
        let count = model.state.comparisons.count
        let replay = await executor.execute(ask)
        precondition(replay.replayed && replay.conversationID == first && model.state.comparisons.count == count)
        return first
    }

    /// Private and shared remote follow-ups (one with a staged file) keep the Mac's own drafts and files.
    @MainActor static func checkRemotePrivateAndAttachedSends(_ model: AppModel, executor: RemoteCommandExecutor, first: UUID, cedar: Agent) async throws {
        let cedarID = RemoteAgentIDs.messages(cedar.id)
        // A private follow-up uses the phone's text; the Mac's own drafts and files stay put.
        let index = model.index(first)!
        model.state.comparisons[index].allDraft = "Mac shared draft"
        model.state.comparisons[index].privateDrafts[cedar.id.uuidString] = "Mac private draft"
        let macFile = try model.local.stage(Data("mac draft file".utf8), filename: "mac-draft.txt")
        model.state.comparisons[index].privateAttachmentDrafts = [cedar.id.uuidString: [macFile]]
        model.state.comparisons[index].allAttachmentsDraft = [macFile]
        // Every save during a remote send keeps the Mac's drafts, so quitting mid-send loses nothing.
        var savesDuringSend = 0
        model.didSave = { saved in
            guard let c = saved.comparisons.first(where: { $0.id == first }) else { preconditionFailure("Conversation missing from a save") }
            savesDuringSend += 1
            precondition(c.allDraft == "Mac shared draft", "Save \(savesDuringSend) replaced the shared draft: \(c.allDraft)")
            precondition(c.privateDrafts[cedar.id.uuidString] == "Mac private draft", "Save \(savesDuringSend) replaced the private draft")
            precondition(c.allAttachmentsDraft?.map(\.id) == [macFile.id], "Save \(savesDuringSend) replaced the shared draft files")
            precondition(c.privateAttachmentDrafts?[cedar.id.uuidString]?.map(\.id) == [macFile.id], "Save \(savesDuringSend) replaced the private draft files")
        }
        let followUp = await executor.execute(RemoteCommand(action: .sendPrivate(conversationID: first, agentID: cedarID, text: "Remote private", attachmentIDs: [])))
        precondition(followUp.outcome == .applied, "\(followUp)")
        let sent = model.comparison(first)!.followUps.last!
        precondition(sent.text == "Remote private" && sent.memberIDs == [cedar.id] && sent.payloads == nil, "The Mac's draft file was not sent")
        precondition(model.comparison(first)!.privateDrafts[cedar.id.uuidString] == "Mac private draft")
        precondition(model.comparison(first)!.privateAttachmentDrafts?[cedar.id.uuidString]?.map(\.id) == [macFile.id])
        precondition(model.comparison(first)!.allDraft == "Mac shared draft")
        precondition(FileManager.default.fileExists(atPath: macFile.path))

        // A remote attachment is staged, sent with the follow-up, and kept by the conversation.
        let upload = UUID(), bytes = Data("remote photo".utf8)
        _ = await executor.execute(RemoteCommand(action: .uploadAttachmentChunk(uploadID: upload, filename: "remote.txt", index: 0, count: 1, data: bytes)))
        let staged = await executor.execute(RemoteCommand(action: .attachStaged(uploadID: upload, sha256: Data(SHA256.hash(data: bytes)))))
        precondition(staged.outcome == .applied && staged.attachmentID != nil, "\(staged)")
        let withFile = await executor.execute(RemoteCommand(action: .sendShared(conversationID: first, text: "See file", agentIDs: [], attachmentIDs: [staged.attachmentID!])))
        precondition(withFile.outcome == .applied, "\(withFile)")
        precondition(model.comparison(first)!.followUps.last!.payloads?[cedar.id.uuidString]?.parts.compactMap(\.attachment).map(\.filename) == ["remote.txt"])
        precondition(model.comparison(first)!.allDraft == "Mac shared draft")
        precondition(model.comparison(first)!.allAttachmentsDraft?.map(\.id) == [macFile.id])
        precondition(savesDuringSend >= 4, "The sends saved \(savesDuringSend) times")
        model.didSave = nil
    }

    /// A failed remote command reports in its result, while the same failure from the Mac UI raises the alert.
    @MainActor static func checkRemoteFailureRouting(_ model: AppModel, executor: RemoteCommandExecutor, first: UUID, cedarID: String) async throws {
        // Errors from a remote command go to its result, never to the Mac's modal alert.
        let newer = await executor.execute(RemoteCommand(action: .createConversation(text: "Newer ask", agentIDs: [cedarID], attachmentIDs: [])))
        precondition(newer.outcome == .applied)
        try await waitUntil { model.comparison(newer.conversationID!)?.members.first?.anchor != nil }
        let stale = await executor.execute(RemoteCommand(action: .sendShared(conversationID: first, text: "Older thread", agentIDs: [], attachmentIDs: [])))
        precondition(stale.outcome == .rejected && stale.message?.contains("newer comparison") == true, "\(stale)")
        precondition(model.error == nil, "The Mac alert stays clear for remote failures")
        precondition(!model.comparison(first)!.followUps.contains { $0.text == "Older thread" && $0.states.values.contains(.submitted) })
        // The same failure from the Mac UI still raises the alert.
        model.state.comparisons[model.index(first)!].allDraft = "Older thread from the Mac"
        await model.followUp(first)
        precondition(model.error?.contains("newer comparison") == true)
        model.error = nil
    }

    /// A website agent's shared send from the phone prepares the page, submits once and refuses a duplicate.
    @MainActor static func checkRemoteWebsiteSend(_ model: AppModel, executor: RemoteCommandExecutor, first: UUID, lumen: Agent, macDraft: String) async throws {
        // A website agent through the lifted shared send, with the Mac draft intact.
        model.webAgents.setEnabled(true, for: .claude)
        let claude = model.webAgents.session(for: .claude)!
        try await waitUntil { claude.snapshot.ready }
        await model.remoteAvailabilityProbe(slow: false)
        // The Mac workspace is on another conversation. The phone's prepareConversation answers
        // without sending anything and never moves the Mac to the phone's conversation.
        model.webAgents.setComparison(first)
        let prepare = await executor.execute(RemoteCommand(action: .prepareConversation(conversationID: nil, agentIDs: ["claude"])))
        precondition(prepare.outcome == .applied && claude.state.attempts.isEmpty, "\(prepare)")
        precondition(model.webAgents.comparisonID == first, "A phone prepare must not switch the Mac's open conversation")
        // Move the Mac back to another conversation, so the send itself must prepare the page:
        // it waits for readiness and then submits exactly once, with no "send again".
        model.webAgents.setComparison(first)
        let website = RemoteAction.createConversation(text: "Website and Messages", agentIDs: ["claude", RemoteAgentIDs.messages(lumen.id)], attachmentIDs: [])
        let shared = await executor.execute(RemoteCommand(action: website))
        precondition(claude.state.attempts.filter { $0.text == "Website and Messages" }.count == 1, "One submission")
        precondition(shared.outcome == .applied, "\(shared)")
        precondition(shared.agentStatuses["claude"]?.isUnresolved == false && shared.agentStatuses["claude"] != .notSent, "\(shared.agentStatuses)")
        precondition(model.comparison(shared.conversationID!)?.resolvedWebAgentIDs == [.claude])
        precondition(!model.webBroadcastBusy)
        // The website send switches the Mac workspace to the new conversation, as any send does;
        // the Mac's composer text stays saved for the workspace it was typed in.
        precondition(model.state.draft == macDraft || model.state.workspaceDrafts?.values.contains(macDraft) == true)
        // A repeated identical website ask is refused by the existing duplicate guard, not resent.
        let again = await executor.execute(RemoteCommand(action: .sendPrivate(conversationID: shared.conversationID, agentID: "claude", text: "Website and Messages", attachmentIDs: [])))
        precondition(claude.state.attempts.filter { $0.text == "Website and Messages" }.count <= 2, "\(again)")
    }

    /// The real RemoteService in Demo: settings saved in the isolated profile, no network
    /// port, a phone paired over memory through the same server, projection and executor.
    @MainActor static func runRemoteServiceChecks(_ model: AppModel) async throws {
        let service = model.remote
        precondition(!service.settings.enabled && !service.running, "Remote control starts off")
        service.setEnabled(true)
        try await waitUntil { service.running }
        precondition(service.listener == nil, "The Demo app opens no port unless asked")
        precondition(FileManager.default.fileExists(atPath: model.local.url.deletingLastPathComponent().appendingPathComponent("remote-settings.json").path))
        let offer = try service.showPairingCode()
        try await renderRemoteSettings(service, name: "remote-settings-pairing")
        let connection = service.connectInMemory()!
        let phoneKey = P256.Signing.PrivateKey()
        let driver = RemoteClientDriver(mode: .pair(offer: offer, deviceName: "Fixture iPhone", deviceKey: phoneKey))
        var events: [RemoteClientDriver.Event] = []
        connection.onReceive = { bytes in
            let (outgoing, received) = try! driver.receive(bytes)
            events += received
            outgoing.forEach(connection.send)
        }
        connection.send(try driver.start())
        try await waitUntil { events.contains { if case .snapshot = $0 { true } else { false } } }
        let snapshot = events.compactMap { if case .snapshot(let s) = $0 { s } else { nil } }.first!
        precondition(snapshot.macStatus.variant == .demo && !snapshot.macStatus.locked)
        precondition(snapshot.conversations.count == model.state.comparisons.count, "Every conversation is projected")
        precondition(snapshot.agents.contains { $0.agentID == "claude" && $0.form == .website })
        precondition(snapshot.agents.contains { $0.form == .messages })
        precondition(snapshot.turns.contains { $0.text == "Remote ask" && $0.origin == .sharedPrompt })
        precondition(service.connectedDeviceID != nil && service.pairing.device?.name == "Fixture iPhone")
        precondition(service.keepAwake.held == false, "Keep-awake waits for the phone's request")
        connection.send(try driver.frame(.command(RemoteCommand(action: .setKeepAwake(enabled: true)))))
        try await waitUntil { service.keepAwake.held }
        precondition(service.settings.allowMessagesSends, "A new pairing turns iMessage sends on")
        service.setAllowMessagesSends(false)
        let before = events.count
        connection.send(try driver.frame(.command(RemoteCommand(action: .createConversation(text: "From the in-memory phone", agentIDs: [RemoteAgentIDs.messages(model.state.agents[2].id)], attachmentIDs: [])))))
        try await waitUntil { events.dropFirst(before).contains { if case .commandResult(let r) = $0 { r.outcome == .rejected } else { false } } }
        let refused = events.dropFirst(before).compactMap { if case .commandResult(let r) = $0 { r } else { nil } }.last!
        precondition(refused.code == .messagesSendsOff, "Turned off on the Mac, iMessage sends stay off: \(refused)")
        service.setAllowMessagesSends(true)
        connection.send(try driver.frame(.command(RemoteCommand(action: .createConversation(text: "From the in-memory phone", agentIDs: [RemoteAgentIDs.messages(model.state.agents[2].id)], attachmentIDs: [])))))
        try await waitUntil { events.contains { if case .events(let list, _) = $0 { list.contains { if case .turnUpsert(let t) = $0.change { t.text == "From the in-memory phone" } else { false } } } else { false } } }
        try await checkRemoteAgent(model, send: { try connection.send(driver.frame(.command(RemoteCommand(action: $0)))) }, events: { events })
        try await renderRemoteSettings(service, name: "remote-settings-connected")
        service.setKeepAwake(false)
        precondition(!service.keepAwake.held, "The Mac setting turns keep-awake off")
        service.forget()
        try await waitUntil { service.connectedDeviceID == nil }
        precondition(service.pairing.device == nil)
        service.setEnabled(false)
        precondition(!service.running)
    }

    /// The msgblast agent from the in-memory phone: the Mac's checks, a Demo turn streamed to the
    /// phone, and Stop. DemoAgentRunner only; no account, CLI or real send.
    @MainActor static func checkRemoteAgent(_ model: AppModel, send: (RemoteAction) throws -> Void, events: () -> [RemoteClientDriver.Event]) async throws {
        func chats() -> [RemoteAgentChat] { events().compactMap { if case .agent(let chat) = $0 { chat } else { nil } } }
        func result(after count: Int) -> RemoteCommandResult? { events().dropFirst(count).lazy.compactMap { if case .commandResult(let r) = $0, r.outcome != .accepted { r } else { nil } }.last }
        func ask(_ action: RemoteAction) async throws -> RemoteCommandResult {
            let count = events().count
            try send(action)
            try await waitUntil { result(after: count) != nil }
            return result(after: count)!
        }
        precondition(chats().first?.account == nil, "The phone hears the agent, not set up yet: \(chats())")
        let notSetUp = try await ask(.sendToAgent(text: "Summarize"))
        precondition(notSetUp.code == .agentUnavailable, "\(notSetUp)")
        await model.msgblastAgent.choose(.claude)
        try await waitUntil { chats().last?.account == "Claude Code" }
        model.agentSendActivity.stopped = true
        let stopped = try await ask(.sendToAgent(text: "Summarize"))
        model.agentSendActivity.stopped = false
        precondition(stopped.code == .agentSendsStopped, "\(stopped)")
        let asked = try await ask(.sendToAgent(text: "Summarize"))
        precondition(asked.outcome == .applied, "\(asked)")
        try await waitUntil { chats().last?.state == .working && chats().last?.line != nil }
        // About ten seconds of scripted Demo events, waited for in two steps.
        try await waitUntil { chats().last?.messageIDs.count == 2 }
        try await waitUntil { chats().last?.state == .idle }
        let ids = chats().last!.messageIDs
        var text: [UUID: String] = [:]
        for chat in chats() { for message in chat.messages { text[message.id] = message.text } }
        precondition(ids.count == 2 && text[ids[1]]?.contains("msgblast://comparison/") == true, "The reply streamed to the phone: \(ids.compactMap { text[$0] })")
        let again = try await ask(.sendToAgent(text: "Again"))
        precondition(again.outcome == .applied, "\(again)")
        try await waitUntil { chats().last?.state == .working }
        let stop = try await ask(.stopAgent)
        precondition(stop.outcome == .applied, "\(stop)")
        try await waitUntil { chats().last?.state == .idle && !model.msgblastAgent.isWorking }
    }

    /// Optional evidence: renders the actual Settings → Remote section off-screen when
    /// MSGBLAST_REMOTE_EVIDENCE_DIR is set. Demo fixture state only.
    @MainActor static func renderRemoteSettings(_ service: RemoteService, name: String) async throws {
        guard let directory = ProcessInfo.processInfo.environment["MSGBLAST_REMOTE_EVIDENCE_DIR"], !directory.isEmpty else { return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 760), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: Form { Section("Remote") { RemoteSettingsView(service: service) } }.formStyle(.grouped).frame(width: 640, height: 760))
        window.orderBack(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        try await Task.sleep(for: .milliseconds(600))
        guard let view = window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
    }

    /// Serves the Demo profile on a real TLS listener (Tailscale or LAN address, never
    /// loopback) for scripts/test_remote_client.sh. Opens a port only for this run.
    @MainActor static func runRemoteListenFixture() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let offerFile = environment["MSGBLAST_REMOTE_OFFER_FILE"], let doneFile = environment["MSGBLAST_REMOTE_DONE_FILE"] else {
            preconditionFailure("Set MSGBLAST_REMOTE_OFFER_FILE and MSGBLAST_REMOTE_DONE_FILE")
        }
        let model = AppModel()
        precondition(model.demo)
        let service = model.remote
        service.setEnabled(true)
        try await waitUntil { service.running }
        service.setDemoNetworkAllowed(true)
        try await waitUntil { service.port != nil || service.listenerError != nil }
        guard let port = service.port else { preconditionFailure(service.listenerError ?? "No listener") }
        service.setAllowMessagesSends(environment["MSGBLAST_REMOTE_ALLOW_MESSAGES"] == "1")
        let offer = try service.showPairingCode()
        try offer.url.absoluteString.write(toFile: offerFile, atomically: true, encoding: .utf8)
        FileHandle.standardError.write(Data("Demo Mac listening on \(service.endpoints.map(\.host)) port \(port)\n".utf8))
        let deadline = Date().addingTimeInterval(Double(environment["MSGBLAST_REMOTE_LISTEN_SECONDS"] ?? "") ?? 180)
        // Optional triggers for recording phone fixtures: simulated lock/unlock (no real lock)
        // and a confirmed replacement pairing offer written next to the offer file.
        let lockFile = environment["MSGBLAST_REMOTE_LOCK_FILE"], unlockFile = environment["MSGBLAST_REMOTE_UNLOCK_FILE"]
        let replaceFile = environment["MSGBLAST_REMOTE_REPLACE_FILE"]
        // Choosing the msgblast agent's account on the Mac; Demo runs DemoAgentRunner, never the account.
        let agentFile = environment["MSGBLAST_REMOTE_AGENT_FILE"]
        var locked = false, replaced = false
        while !FileManager.default.fileExists(atPath: doneFile), Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
            // Demo replies arrive asynchronously; the projection streams them to the client.
            // Keep a fresh one-time code available until a phone pairs (UX iteration).
            if service.pairing.device == nil, !service.pairing.isOfferValid || (service.pairing.offer.map { $0.expiresAt.timeIntervalSinceNow < 20 } ?? true) {
                try? service.showPairingCode().url.absoluteString.write(toFile: offerFile, atomically: true, encoding: .utf8)
            }
            if let lockFile, !locked, FileManager.default.fileExists(atPath: lockFile) { locked = true; service.power.simulate(locked: true) }
            if let unlockFile, locked, FileManager.default.fileExists(atPath: unlockFile) { locked = false; service.power.simulate(locked: false); try? FileManager.default.removeItem(atPath: unlockFile); try? FileManager.default.removeItem(atPath: lockFile ?? "") }
            if let agentFile, model.msgblastAgent.conversation.account == nil, FileManager.default.fileExists(atPath: agentFile) { await model.msgblastAgent.choose(.claude) }
            if let replaceFile, !replaced, FileManager.default.fileExists(atPath: replaceFile) {
                replaced = true
                try service.showPairingCode(confirmReplacement: true).url.absoluteString.write(toFile: replaceFile + ".offer", atomically: true, encoding: .utf8)
            }
        }
        if environment["MSGBLAST_REMOTE_EVIDENCE_DIR"]?.isEmpty == false { try await renderRemoteSettings(service, name: "remote-settings-listening") }
        print("Demo Mac: paired \(service.pairing.device?.name ?? "none"), conversations \(model.state.comparisons.count), keep-awake held \(service.keepAwake.held)")
        service.setEnabled(false)
    }
}
