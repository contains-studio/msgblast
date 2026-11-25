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
        var forwardActivity = false
        var forwardAgents: [String] = []
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
    @Published private(set) var sending = false
    @Published var error: String?

    private unowned let app: AppModel
    private let fileURL: URL
    /// False when `wants.json` exists but could not be read: it is kept, not overwritten.
    private var canSave = true
    private var credential: WantCredential?
    private var service: WantService!
    private var poller: Task<Void, Never>?
    private var callback: WantOAuthCallback?
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
        do {
            var loaded: [WantList] = []
            for id in try await service.writableListIDs() { loaded.append(try await service.list(id)) }
            lists = loaded
            for list in loaded {
                comments[list.id] = try await service.comments(listID: list.id)
                suggestions[list.id] = try await service.suggestions(listID: list.id)
            }
            for id in entries.keys { entries[id] = try await service.entries(itemID: id) }
        } catch { fail(error) }
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
        poller?.cancel(); poller = nil
        keychain.delete(); credential = nil
        signedIn = false; lists = []; comments = [:]; suggestions = [:]; entries = [:]
        update { $0.cursors = [:] }
    }

    private func store(_ credential: WantCredential) {
        self.credential = credential
        guard keychain.save(credential) else { error = "msgblast could not save your sign-in to the Keychain."; return }
        signedIn = true
        start()
    }

    /// The bearer token, refreshed first when an OAuth token is about to expire.
    private func token() async -> String? {
        guard var credential else { return nil }
        if let expiry = credential.expiresAt, expiry < Date().addingTimeInterval(60), credential.refreshToken != nil,
           let next = try? await WantOAuth.refresh(credential, resource: Self.endpoint) {
            credential = next
            self.credential = next
            _ = keychain.save(next)
        }
        return credential.accessToken
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

    /// Sends the item to the chosen agents in a new conversation and remembers it for the item.
    /// Loads an item's entries when it is opened, and again when the event feed reports changes.
    func loadEntries(_ item: WantItem) async {
        do { entries[item.id] = try await service.entries(itemID: item.id) } catch { fail(error) }
    }

    func answer(_ question: WantQuestion, with text: String) async {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        do {
            try await service.answer(questionID: question.id, text: text)
            await reload()
        } catch { fail(error) }
    }

    func blast(_ item: WantItem, in list: WantList, to agentIDs: [String]) async {
        if entries[item.id] == nil { await loadEntries(item) }
        let prompt = WantPrompt.ask(item: item, list: list, posted: entries[item.id] ?? item.entries ?? [])
        guard let result = await send(.createConversation(text: prompt, agentIDs: agentIDs.compactMap(AgentControlSend.remoteID), attachmentIDs: [])) else { return }
        update { $0.blasts[item.id] = .init(comparisonID: result.conversationID, agents: agentIDs) }
    }

    func setForwarding(_ on: Bool, agents: [String]? = nil) {
        update { saved in
            saved.forwardActivity = on
            if let agents { saved.forwardAgents = agents }
        }
    }

    /// The agents' replies to the newest blast for an item.
    func replies(for item: WantItem) -> (comparison: UUID, turns: [AgentControlTurn])? {
        guard let id = saved.blasts[item.id]?.comparisonID, let comparison = app.comparison(id) else { return nil }
        return (id, app.controlTranscript(comparison).filter { !$0.outgoing })
    }

    func openConversation(_ id: UUID) { app.coordinator?.open(id) }

    private func send(_ action: RemoteAction, quietly: Bool = false) async -> RemoteCommandResult? {
        sending = true
        defer { sending = false }
        let result = await sends.send(RemoteCommand(action: action), client: "Wants")
        guard result.outcome != .rejected else {
            guard !quietly else { return nil }
            let reasons = result.agentReasons.values.sorted()
            error = ([result.message ?? "msgblast did not send it."] + reasons).joined(separator: " ")
            return nil
        }
        return result
    }

    // MARK: Events

    /// One round of `events/poll`. Returns the seconds until the next round.
    private func poll() async -> TimeInterval {
        var delay: TimeInterval = 30, changed = false
        do {
            for _ in 0..<10 {
                let page = try await service.poll(Self.activity, cursor: saved.cursors[Self.activity])
                // Saved before forwarding, so a crash mid-send never forwards the same event twice.
                update { $0.cursors[Self.activity] = page.cursor }
                changed = changed || !page.events.isEmpty
                for event in page.events { await forward(event) }
                delay = max(page.nextPoll ?? delay, 5)
                if !page.hasMore { break }
            }
        } catch {
            fail(error)
            return 60
        }
        if changed { await reload() }
        return delay
    }

    /// Tells the item's agents about a new comment or outside suggestion, in the item's open conversation when there is one.
    private func forward(_ event: WantEvent) async {
        let itemID = event.item?.id ?? event.entry?.itemId
        let blast = itemID.flatMap { saved.blasts[$0] }
        let targets = WantForwarding.recipients(for: event, enabled: saved.forwardActivity, itemAgents: blast?.agents,
                                                defaults: saved.forwardAgents, sendable: Set(agents.map(\.id)))
        guard !targets.isEmpty else { return }
        if !lists.contains(where: { $0.id == event.listId }) { await reload() }
        guard let list = lists.first(where: { $0.id == event.listId }), let text = WantPrompt.activity(event, list: list) else { return }
        let remote = targets.compactMap(AgentControlSend.remoteID)
        if let id = blast?.comparisonID, app.comparison(id)?.endedAt == nil,
           await send(.sendShared(conversationID: id, text: text, agentIDs: remote, attachmentIDs: []), quietly: true) != nil { return }
        if let result = await send(.createConversation(text: text, agentIDs: remote, attachmentIDs: []), quietly: true), let itemID {
            update { $0.blasts[itemID] = .init(comparisonID: result.conversationID, agents: targets) }
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

    private func update(_ change: (inout Saved) -> Void) {
        var next = saved
        change(&next)
        guard next != saved else { return }
        saved = next
        guard canSave else { return }
        do {
            try JSONEncoder().encode(next).write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch { self.error = "msgblast could not save Wants settings." }
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
