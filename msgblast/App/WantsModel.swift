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
        var grantID: UUID?
        /// `events/poll` cursor per event type.
        var cursors: [String: String] = [:]
        /// The newest blast for each item, so its replies show under it.
        var blasts: [String: Blast] = [:]

        init() {}
        /// Each field is optional on disk, so a file from a build that knew fewer of them still loads.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            grantID = try c.decodeIfPresent(UUID.self, forKey: .grantID)
            cursors = try c.decodeIfPresent([String: String].self, forKey: .cursors) ?? [:]
            blasts = try c.decodeIfPresent([String: Blast].self, forKey: .blasts) ?? [:]
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
    private var callback: WantOAuthCallback?
    private var authorization: Task<Void, Never>?
    private var refreshing: Task<String, Error>?
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
            if credential?.grantID == nil || saved.grantID != credential?.grantID {
                saved = Saved()
                saved.grantID = credential?.grantID
            }
            signedIn = credential != nil
            service = liveService()
        }
    }

    private func liveService() -> WantMCPClient {
        let generation = session
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        return WantMCPClient(endpoint: Self.endpoint, version: version) { [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.token(for: generation)
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
        let service = self.service!
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
        guard !signingIn else { return }
        signingIn = true; error = nil
        let callback = WantOAuthCallback()
        self.callback = callback
        let task = Task {
            do {
                let grant = try await authorize(callback)
                try Task.checkCancellation()
                store(grant)
            } catch is CancellationError {
            } catch { if !Task.isCancelled { fail(error) } }
        }
        authorization = task
        await task.value
        if self.callback === callback { cancelSignIn() }
    }

    private func authorize(_ callback: WantOAuthCallback) async throws -> WantCredential {
        let resource = Self.endpoint
        let redirect = try await callback.start()
        let server = try await WantOAuth.discover(resource: resource, hint: nil)
        try Task.checkCancellation()
        let clientID = try await WantOAuth.register(server, redirect: redirect)
        try Task.checkCancellation()
        let pkce = WantOAuth.PKCE()
        NSWorkspace.shared.open(WantOAuth.authorizeURL(server, clientID: clientID, redirect: redirect, pkce: pkce, resource: resource))
        let answer = try await callback.wait()
        try Task.checkCancellation()
        NSApp.activate()
        return try await WantOAuth.exchange(callback: answer, server: server, clientID: clientID, redirect: redirect, pkce: pkce, resource: resource)
    }

    func cancelSignIn() {
        authorization?.cancel(); authorization = nil
        callback?.stop(); callback = nil
        signingIn = false
    }

    /// Returns false when the text is not a write key.
    func useWriteKey(_ text: String) -> Bool {
        guard let credential = WantCredential.writeKey(text) else { return false }
        error = nil
        store(credential)
        return true
    }

    func signOut() {
        poller?.cancel(); poller = nil; session += 1
        refreshing?.cancel(); refreshing = nil
        keychain.delete(); credential = nil
        signedIn = false; lists = []; comments = [:]; suggestions = [:]; entries = [:]
        resetSaved(for: nil)
    }

    private func resetSaved(for grantID: UUID?) {
        var clean = Saved()
        clean.grantID = grantID
        update { $0 = clean }
        saved = clean
    }

    private func store(_ grant: WantCredential) {
        var credential = grant
        credential.grantID = UUID()
        guard keychain.save(credential) else { error = "msgblast could not save your sign-in to the Keychain."; return }
        self.credential = credential
        resetSaved(for: credential.grantID)
        if !app.demo { service = liveService() }
        signedIn = true
        start()
    }

    /// The bearer token, refreshed first when an OAuth token is about to expire.
    private func token(for generation: Int) async throws -> String {
        guard generation == session, let credential else { throw CancellationError() }
        guard let expiry = credential.expiresAt, expiry < Date().addingTimeInterval(60), credential.refreshToken != nil else { return credential.accessToken }
        if let refreshing { return try await refreshing.value }
        let task = Task {
            defer { if session == generation { refreshing = nil } }
            var next = try await WantOAuth.refresh(credential, resource: Self.endpoint)
            guard session == generation else { throw CancellationError() }
            next.grantID = credential.grantID
            self.credential = next
            guard keychain.save(next) else { throw WantError.server("msgblast could not save your refreshed sign-in to the Keychain.") }
            return next.accessToken
        }
        refreshing = task
        return try await task.value
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
        let generation = session
        let service = self.service!
        do {
            _ = try await service.addItem(listID: list.id, text: text)
            guard generation == session else { return }
            let refreshed = try await service.list(list.id)
            guard generation == session, let index = lists.firstIndex(where: { $0.id == list.id }) else { return }
            lists[index] = refreshed
        } catch { if generation == session { fail(error) } }
    }

    /// Agents msgblast can send to, by their `msgblast_agents_list` id.
    var agents: [AgentControlAgent] {
        app.controlAgents().filter { $0.kind != "report" && $0.visible && AgentControlSend.remoteID($0.id) != nil }
    }

    func answer(_ question: WantQuestion, with text: String) async {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let generation = session
        do {
            try await service.answer(questionID: question.id, text: text)
            if generation == session { await reload() }
        } catch { if generation == session { fail(error) } }
    }

    /// Sends the item to the chosen agents in a new conversation and remembers it for the item.
    func blast(_ item: WantItem, in list: WantList, to agentIDs: [String]) async {
        let generation = session
        if entries[item.id] == nil { await loadEntries(item) }
        guard generation == session, signedIn, entries[item.id] != nil else { return }
        let prompt = WantPrompt.ask(item: item, list: list, posted: entries[item.id] ?? item.entries ?? [])
        guard let result = await send(.createConversation(text: prompt, agentIDs: agentIDs.compactMap(AgentControlSend.remoteID), attachmentIDs: [])), generation == session else { return }
        update { $0.blasts[item.id] = .init(comparisonID: result.conversationID, agents: agentIDs) }
    }

    /// The agents' replies to the newest blast for an item.
    func replies(for item: WantItem) -> (comparison: UUID, turns: [AgentControlTurn])? {
        guard let id = saved.blasts[item.id]?.comparisonID, let comparison = app.comparison(id) else { return nil }
        return (id, app.controlTranscript(comparison).filter { !$0.outgoing })
    }

    func openConversation(_ id: UUID) { app.coordinator?.open(id) }

    private func send(_ action: RemoteAction) async -> RemoteCommandResult? {
        sendsInFlight += 1
        defer { sendsInFlight -= 1 }
        let generation = session
        let result = await sends.send(RemoteCommand(action: action), client: "Wants") { self.signedIn && self.session == generation }
        guard session == generation else { return nil }
        guard result.outcome != .rejected else {
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
                update { $0.cursors[Self.activity] = page.cursor }
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
