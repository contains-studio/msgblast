import AppKit
import CryptoKit
import LocalAuthentication
import Security
import msgblastCore
import msgblastRemoteProtocol

/// The Wants panel's state: the person's Want MCP lists, sign-in, the event feed, and the blasts
/// that ask their agents for offers. Sends run through the same executor as outside agents and
/// the phone, so they get every readiness and duplicate-send check and are never retried.
@MainActor final class WantsModel: ObservableObject {
    /// What msgblast remembers between launches, in `wants.json` beside `state.json`.
    struct Saved: Codable, Equatable {
        struct Blast: Codable, Equatable {
            var comparisonID: UUID?
            var agents: [String]
        }
        /// `events/poll` cursor per event type.
        var cursors: [String: String] = [:]
        /// The newest blast for each item, so its replies show and activity goes to the same agents.
        var blasts: [String: Blast] = [:]
        var forwardedConversations: [String: UUID] = [:]
        var forwardActivity = false
        var forwardAgents: [String] = []

        init() {}
        /// Each field is optional on disk, so a file from a build that knew fewer of them still loads.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            cursors = try c.decodeIfPresent([String: String].self, forKey: .cursors) ?? [:]
            blasts = try c.decodeIfPresent([String: Blast].self, forKey: .blasts) ?? [:]
            forwardedConversations = try c.decodeIfPresent([String: UUID].self, forKey: .forwardedConversations) ?? [:]
            forwardActivity = try c.decodeIfPresent(Bool.self, forKey: .forwardActivity) ?? false
            forwardAgents = try c.decodeIfPresent([String].self, forKey: .forwardAgents) ?? []
        }
    }
    /// Every event type on the lists this credential writes, in one poll.
    static let activity = "list.activity"
    static var endpoint: URL {
        UserDefaults.standard.string(forKey: "WantMCPURL").flatMap(URL.init(string:)) ?? URL(string: "https://mcp.wantmcp.com/mcp")!
    }

    @Published private(set) var signedIn: Bool
    @Published private(set) var lists: [WantList] = []
    @Published private(set) var comments: [String: [WantComment]] = [:]
    @Published private(set) var suggestions: [String: [WantEntry]] = [:]
    /// Each opened item's entries by item id, from `get_item_entries`.
    @Published private(set) var entries: [String: [WantEntry]] = [:]
    @Published private(set) var saved = Saved()
    @Published private(set) var signingIn = false
    /// Sends in flight; a background forward and a blast can overlap.
    @Published private(set) var sendsInFlight = 0
    var sending: Bool { sendsInFlight > 0 }
    @Published var error: String?

    private unowned let app: AppModel
    private let fileURL: URL
    /// False when `wants.json` exists but could not be read: it is kept, not overwritten.
    private var canSave = true
    private var credential: WantCredential?
    private var service: WantService!
    private var poller: Task<Void, Never>?
    /// Bumped on sign-out so requests still in flight from the old sign-in are discarded.
    private var session = 0
    private var forwardingRevision = 0
    private var callback: WantOAuthCallback?
    private var refreshing: Task<WantCredential?, Never>?
    private lazy var sends = AgentControlSends(model: app, source: .wants)
    private let keychain: WantKeychain

    init(app: AppModel) {
        self.app = app
        let directory = app.local.url.deletingLastPathComponent()
        fileURL = directory.appendingPathComponent("wants.json")
        keychain = WantKeychain(directory: directory)
        if let data = try? Data(contentsOf: fileURL) {
            if let decoded = try? JSONDecoder().decode(Saved.self, from: data) { saved = decoded } else { canSave = false }
        }
        if app.demo {
            signedIn = true
            service = WantFixture(activityDelay: 60)
        } else {
            credential = keychain.read()
            signedIn = credential != nil
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
            service = WantMCPClient(endpoint: Self.endpoint, version: version) { [weak self] in await self?.token() }
        }
    }

    /// Loads the lists and starts the event feed. Called at launch; does nothing while signed out.
    func start() {
        guard signedIn, poller == nil else { return }
        poller = Task { [weak self] in
            await self?.reload()
            while !Task.isCancelled, let self {
                let delay = await self.poll()
                try? await Task.sleep(for: .seconds(delay))
            }
        }
    }

    func reload() async {
        let session = self.session
        do {
            var loaded: [WantList] = [], loadedComments: [String: [WantComment]] = [:], loadedSuggestions: [String: [WantEntry]] = [:]
            var loadedEntries: [String: [WantEntry]] = [:]
            for id in try await service.writableListIDs() { loaded.append(try await service.list(id)) }
            for list in loaded {
                loadedComments[list.id] = try await service.comments(listID: list.id)
                loadedSuggestions[list.id] = try await service.suggestions(listID: list.id)
            }
            for id in entries.keys { loadedEntries[id] = try await service.entries(itemID: id) }
            guard session == self.session else { return }
            lists = loaded
            comments.merge(loadedComments) { $1 }
            suggestions.merge(loadedSuggestions) { $1 }
            entries.merge(loadedEntries) { $1 }
        } catch { if session == self.session { fail(error) } }
    }

    // MARK: Sign-in

    func signIn() async {
        signingIn = true; error = nil
        let callback = WantOAuthCallback()
        self.callback = callback
        defer { callback.stop(); self.callback = nil; signingIn = false }
        do {
            let resource = Self.endpoint
            let redirect = try await callback.start()
            let server = try await WantOAuth.discover(resource: resource, hint: nil)
            let clientID = try await WantOAuth.register(server, redirect: redirect)
            let pkce = WantOAuth.PKCE()
            NSWorkspace.shared.open(WantOAuth.authorizeURL(server, clientID: clientID, redirect: redirect, pkce: pkce, resource: resource))
            let answer = try await callback.wait()
            NSApp.activate()
            store(try await WantOAuth.exchange(callback: answer, server: server, clientID: clientID, redirect: redirect, pkce: pkce, resource: resource))
        } catch is CancellationError {
        } catch { fail(error) }
    }

    func cancelSignIn() { callback?.stop() }

    /// Returns false when the text is not a write key.
    func useWriteKey(_ text: String) -> Bool {
        guard let credential = WantCredential.writeKey(text) else { return false }
        error = nil
        store(credential)
        return true
    }

    func signOut() {
        poller?.cancel(); poller = nil; session += 1
        keychain.delete(); credential = nil
        signedIn = false; lists = []; comments = [:]; suggestions = [:]; entries = [:]
        if !update({ $0 = Saved() }) { saved = Saved() }
    }

    private func store(_ credential: WantCredential) {
        self.credential = credential
        guard keychain.save(credential) else { error = "msgblast could not save your sign-in to the Keychain."; return }
        signedIn = true
        start()
    }

    /// The bearer token, refreshed first when an OAuth token is about to expire.
    private func token() async -> String? {
        guard let credential else { return nil }
        guard let expiry = credential.expiresAt, expiry < Date().addingTimeInterval(60), credential.refreshToken != nil else { return credential.accessToken }
        // One refresh at a time: overlapping calls wait for it, since a rotated refresh token works only once.
        let refresh = refreshing ?? Task { try? await WantOAuth.refresh(credential, resource: Self.endpoint) }
        refreshing = refresh
        let session = self.session
        let next = await refresh.value
        refreshing = nil
        guard let next, session == self.session else { return self.credential?.accessToken }
        self.credential = next
        _ = keychain.save(next)
        return next.accessToken
    }

    /// Loads an item's entries when it is opened, and again when the event feed reports changes.
    func loadEntries(_ item: WantItem) async {
        let session = self.session
        do {
            let loaded = try await service.entries(itemID: item.id)
            if session == self.session { entries[item.id] = loaded }
        } catch { if session == self.session { fail(error) } }
    }

    // MARK: Items and blasts

    func addItem(_ text: String, to list: WantList) async {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        do {
            _ = try await service.addItem(listID: list.id, text: text)
            if let index = lists.firstIndex(where: { $0.id == list.id }) { lists[index] = try await service.list(list.id) }
        } catch { fail(error) }
    }

    /// Agents msgblast can send to, by their `msgblast_agents_list` id.
    var agents: [AgentControlAgent] {
        app.controlAgents().filter { $0.kind != "report" && $0.visible && AgentControlSend.remoteID($0.id) != nil }
    }

    func answer(_ question: WantQuestion, with text: String) async {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        do {
            try await service.answer(questionID: question.id, text: text)
            await reload()
        } catch { fail(error) }
    }

    /// Sends the item to the chosen agents in a new conversation and remembers it for the item.
    func blast(_ item: WantItem, in list: WantList, to agentIDs: [String]) async {
        if entries[item.id] == nil { await loadEntries(item) }
        let prompt = WantPrompt.ask(item: item, list: list, posted: entries[item.id] ?? item.entries ?? [])
        guard let result = await send(.createConversation(text: prompt, agentIDs: agentIDs.compactMap(AgentControlSend.remoteID), attachmentIDs: [])) else { return }
        update { $0.blasts[item.id] = .init(comparisonID: result.conversationID, agents: agentIDs) }
    }

    /// The agents' replies to the newest blast for an item.
    func replies(for item: WantItem) -> (comparison: UUID, turns: [AgentControlTurn])? {
        guard let id = saved.blasts[item.id]?.comparisonID ?? saved.forwardedConversations[item.id], let comparison = app.comparison(id) else { return nil }
        return (id, app.controlTranscript(comparison).filter { !$0.outgoing })
    }

    func openConversation(_ id: UUID) { app.coordinator?.open(id) }

    private func send(_ action: RemoteAction, quietly: Bool = false, isAuthorized: @MainActor () -> Bool = { true }) async -> RemoteCommandResult? {
        sendsInFlight += 1
        defer { sendsInFlight -= 1 }
        let result = await sends.send(RemoteCommand(action: action), client: "Wants", isAuthorized: isAuthorized)
        guard result.outcome != .rejected else {
            guard !quietly else { return result }
            let reasons = result.agentReasons.values.sorted()
            error = ([result.message ?? "msgblast did not send it."] + reasons).joined(separator: " ")
            return nil
        }
        return result
    }

    // MARK: Events

    /// One round of `events/poll`. Returns the seconds until the next round.
    private func poll() async -> TimeInterval {
        let session = self.session
        var delay: TimeInterval = 30, changed = false
        do {
            for _ in 0..<10 {
                let page = try await service.poll(Self.activity, cursor: saved.cursors[Self.activity])
                guard session == self.session else { return delay }
                guard await take(page) else { return delay }
                changed = changed || !page.events.isEmpty
                delay = max(page.nextPoll ?? delay, 5)
                if !page.hasMore { break }
            }
        } catch {
            if session == self.session { fail(error) }
            return 60
        }
        if changed { await reload() }
        return delay
    }

    /// Saves the cursor before forwarding, so a crash mid-send never forwards the same event twice.
    func take(_ page: WantEventPage) async -> Bool {
        let session = self.session
        let revision = forwardingRevision
        guard let cursor = page.cursor, saved.cursors[Self.activity] != cursor else { return page.events.isEmpty }
        guard update({ $0.cursors[Self.activity] = cursor }) else { return false }
        for event in page.events {
            guard session == self.session else { return false }
            guard saved.forwardActivity, revision == forwardingRevision else { break }
            await forward(event, session: session, revision: revision)
        }
        return session == self.session
    }

    func setForwarding(_ on: Bool, agents: [String]? = nil) {
        forwardingRevision += 1
        let persisted = update { saved in
            saved.forwardActivity = on
            if let agents { saved.forwardAgents = agents }
        }
        if !persisted && !on { saved.forwardActivity = false }
    }

    private func forward(_ event: WantEvent, session: Int, revision: Int) async {
        if !lists.contains(where: { $0.id == event.listId }) { await reload() }
        guard let list = lists.first(where: { $0.id == event.listId }), let text = WantPrompt.activity(event, list: list) else { return }
        let itemID = event.item?.id ?? event.entry?.itemId
        let asked = itemID.flatMap { saved.blasts[$0] }
        let targets = WantForwarding.recipients(for: event, enabled: saved.forwardActivity, itemAgents: asked?.agents,
                                                defaults: saved.forwardAgents, sendable: Set(agents.map(\.id)))
        let authorized: @MainActor () -> Bool = {
            session == self.session && revision == self.forwardingRevision && self.saved.forwardActivity
                && itemID.flatMap { self.saved.blasts[$0] } == asked
        }
        guard !targets.isEmpty, authorized() else { return }
        let remote = targets.compactMap(AgentControlSend.remoteID)
        if let id = asked?.comparisonID, let comparison = app.comparison(id), comparison.endedAt == nil {
            let result = await send(.sendShared(conversationID: id, text: text, agentIDs: remote, attachmentIDs: []), quietly: true, isAuthorized: authorized)
            guard let result, result.outcome == .rejected,
                  result.code == .unknownConversation || result.code == .conversationEnded, authorized() else { return }
        }
        let result = await send(.createConversation(text: text, agentIDs: remote, attachmentIDs: []), quietly: true, isAuthorized: authorized)
        guard authorized(), let itemID, let id = result?.conversationID, result?.outcome == .applied else { return }
        update { saved in
            if asked != nil { saved.blasts[itemID]?.comparisonID = id }
            else { saved.forwardedConversations[itemID] = id }
        }
    }

    private func fail(_ error: Error) {
        if case WantError.unauthorized = error, credential != nil {
            self.error = "Your Want MCP sign-in has expired. Sign in again."
            signOut()
        } else if !(error is CancellationError) {
            self.error = error.localizedDescription
        }
    }

    @discardableResult private func update(_ change: (inout Saved) -> Void) -> Bool {
        var next = saved
        change(&next)
        guard canSave else { return false }
        guard next != saved else { return true }
        do {
            try JSONEncoder().encode(next).write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            saved = next
            return true
        } catch {
            self.error = "msgblast could not save Wants settings."
            return false
        }
    }
}

/// The Want MCP credential in the data-protection Keychain, one per msgblast profile.
struct WantKeychain {
    let directory: URL

    func read() -> WantCredential? {
        var query = self.query(); query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(WantCredential.self, from: data)
    }
    func save(_ credential: WantCredential) -> Bool {
        guard let data = try? JSONEncoder().encode(credential) else { return false }
        var item = query()
        SecItemDelete(item as CFDictionary)
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }
    func delete() { SecItemDelete(query() as CFDictionary) }

    private func query() -> [String: Any] {
        let context = LAContext()
        context.interactionNotAllowed = true
        return [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.msgblast.wantmcp.\(Bundle.main.bundleIdentifier ?? "unknown")",
                kSecAttrAccount as String: SHA256.hash(data: Data(directory.standardizedFileURL.path.utf8)).map { String(format: "%02x", $0) }.joined(),
                kSecUseDataProtectionKeychain as String: true, kSecUseAuthenticationContext as String: context]
    }
}
