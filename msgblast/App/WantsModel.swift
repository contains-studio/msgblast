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
    @Published private(set) var answering: Set<String> = []
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
    private var latestReload = UUID()
    private var reloadPending = false
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
        keychain = WantKeychain(directory: directory, endpoint: Self.endpoint)
        do { saved = try JSONDecoder().decode(Saved.self, from: Data(contentsOf: fileURL)) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile {}
        catch { canSave = false; self.error = "Wants settings could not be read. The existing file has been preserved." }
        if app.demo {
            signedIn = true
            service = WantFixture(activityDelay: 60)
        } else {
            credential = keychain.read()
            signedIn = credential != nil
            if var existing = credential, existing.grantID == nil {
                existing.grantID = UUID()
                if keychain.save(existing) { credential = existing }
            }
            if credential?.grantID == nil || saved.grantID != credential?.grantID {
                saved = Saved()
                saved.grantID = credential?.grantID
            }
            connectService()
        }
    }

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

    @discardableResult func reload() async -> Bool {
        guard signedIn, let service else { return false }
        let reloadID = UUID()
        latestReload = reloadID
        let session = self.session
        do {
            var loaded: [WantList] = [], loadedComments: [String: [WantComment]] = [:], loadedSuggestions: [String: [WantEntry]] = [:]
            var loadedEntries: [String: [WantEntry]] = [:]
            for id in try await service.writableListIDs() { loaded.append(try await service.list(id)) }
            for list in loaded {
                loadedComments[list.id] = try await service.comments(listID: list.id)
                loadedSuggestions[list.id] = try await service.suggestions(listID: list.id)
            }
            let visible = Set(loaded.flatMap { ($0.items ?? []).map(\.id) })
            for id in entries.keys where visible.contains(id) { loadedEntries[id] = try await service.entries(itemID: id) }
            guard session == self.session, latestReload == reloadID else { return false }
            lists = loaded
            comments = loadedComments
            suggestions = loadedSuggestions
            entries = entries.filter { visible.contains($0.key) }.merging(loadedEntries) { _, new in new }
            reloadPending = false
            return true
        } catch {
            if session == self.session, latestReload == reloadID { reloadPending = true; fail(error) }
            return false
        }
    }

    // MARK: Sign-in

    func signIn() async {
        guard !signedIn, !signingIn else { return }
        if app.demo {
            store(WantCredential(accessToken: "demo"))
            return
        }
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
        let resource = keychain.endpoint
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

    func useWriteKey(_ text: String) -> Bool {
        guard !signedIn, !signingIn else { return false }
        guard let credential = WantCredential.writeKey(text) else { error = "That isn't a write key. Keys start with wk_."; return false }
        error = nil
        return store(credential)
    }

    func signOut() {
        poller?.cancel(); poller = nil; session += 1
        refreshing?.cancel(); refreshing = nil
        if !app.demo, !keychain.delete() { error = "Signed out on this Mac. The Keychain could not remove the saved key." }
        credential = nil; reloadPending = false; answering = []
        signedIn = false; lists = []; comments = [:]; suggestions = [:]; entries = [:]
        update { $0 = Saved() }
        saved = Saved()
    }

    @discardableResult private func store(_ grant: WantCredential) -> Bool {
        var credential = grant
        credential.grantID = UUID()
        guard app.demo || WantMCPClient.allowsEndpoint(keychain.endpoint) else { error = "Use an HTTPS Want MCP endpoint, or HTTP on localhost."; return false }
        var clean = Saved()
        clean.grantID = credential.grantID
        guard update({ $0 = clean }) else { return false }
        guard app.demo || keychain.save(credential) else { error = "msgblast could not save your sign-in to the Keychain."; return false }
        session += 1
        self.credential = credential
        if !app.demo { connectService() }
        signedIn = true
        start()
        return true
    }

    private func connectService() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let generation = session
        service = WantMCPClient(endpoint: keychain.endpoint, version: version) { [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.token(for: generation)
        }
    }

    /// The bearer token, refreshed first when an OAuth token is about to expire.
    private func token(for generation: Int) async throws -> String {
        guard generation == session, let credential else { throw CancellationError() }
        guard let expiry = credential.expiresAt, expiry < Date().addingTimeInterval(60), credential.refreshToken != nil else { return credential.accessToken }
        if let refreshing {
            let token = try await refreshing.value
            guard generation == session else { throw CancellationError() }
            return token
        }
        let task = Task {
            defer { if session == generation { refreshing = nil } }
            var next = try await WantOAuth.refresh(credential, resource: keychain.endpoint)
            guard session == generation else { throw CancellationError() }
            next.grantID = credential.grantID
            self.credential = next
            guard keychain.save(next) else { throw WantError.server("msgblast could not save your refreshed sign-in to the Keychain.") }
            return next.accessToken
        }
        refreshing = task
        let token = try await task.value
        guard generation == session else { throw CancellationError() }
        return token
    }

    /// Loads an item's entries when it is opened, and again when the event feed reports changes.
    func loadEntries(_ item: WantItem) async {
        guard signedIn, lists.contains(where: { $0.items?.contains(where: { $0.id == item.id }) == true }) else { return }
        let session = self.session
        do {
            let loaded = try await service.entries(itemID: item.id)
            if session == self.session { entries[item.id] = loaded }
        } catch { if session == self.session { fail(error) } }
    }

    // MARK: Items and blasts

    func addItem(_ text: String, to list: WantList) async -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, signedIn, let service else { return false }
        let generation = session
        do { _ = try await service.addItem(listID: list.id, text: text) }
        catch {
            if generation == session { fail(error) }
            return false
        }
        guard generation == session else { return false }
        await reload()
        return true
    }

    /// Agents msgblast can send to, by their `msgblast_agents_list` id.
    var agents: [AgentControlAgent] {
        app.controlAgents().filter { $0.kind != "report" && $0.visible && AgentControlSend.remoteID($0.id) != nil }
    }

    @discardableResult func answer(_ question: WantQuestion, with text: String) async -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard signedIn, !text.isEmpty, answering.insert(question.id).inserted else { return false }
        let generation = session
        defer { if generation == session { answering.remove(question.id) } }
        do {
            try await service.answer(questionID: question.id, text: text)
            guard generation == session else { return false }
            await reload()
            return true
        } catch {
            if generation == session { fail(error) }
            return false
        }
    }

    /// Sends the item to the chosen agents in a new conversation and remembers it for the item.
    func blast(_ item: WantItem, in list: WantList, to agentIDs: [String]) async {
        guard signedIn, !sending else { return }
        sendsInFlight += 1
        defer { sendsInFlight -= 1 }
        let generation = session
        if entries[item.id] == nil { await loadEntries(item) }
        guard generation == session, let posted = entries[item.id] else { return }
        let prompt = WantPrompt.ask(item: item, list: list, posted: posted)
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
        var delay: TimeInterval = 30, changed = reloadPending
        var cursor = saved.cursors[Self.activity]
        do {
            for _ in 0..<10 {
                let page = try await service.poll(Self.activity, cursor: cursor)
                guard session == self.session else { return delay }
                cursor = page.cursor
                changed = changed || page.hasActivity
                delay = max(page.nextPoll ?? delay, 5)
                if !page.hasMore { break }
            }
        } catch {
            if session == self.session { fail(error) }
            return 60
        }
        if changed, !(await reload()) { return 60 }
        guard session == self.session else { return delay }
        if !update({ $0.cursors[Self.activity] = cursor }) { reloadPending = true }
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

    @discardableResult private func update(_ change: (inout Saved) -> Void) -> Bool {
        var next = saved
        change(&next)
        guard next != saved else { return true }
        guard canSave else { error = "Wants settings could not be read. The existing file has been preserved."; return false }
        do {
            try JSONEncoder().encode(next).write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            saved = next
            return true
        } catch { self.error = "msgblast could not save Wants settings."; return false }
    }
}

/// The Want MCP credential in the data-protection Keychain, one per msgblast profile.
struct WantKeychain {
    let directory: URL
    let endpoint: URL
    private var account: String { SHA256.hash(data: Data(directory.standardizedFileURL.path.utf8)).map { String(format: "%02x", $0) }.joined() }
    private var signedOutKey: String { "WantMCPSignedOut." + account }

    func read() -> WantCredential? {
        guard !UserDefaults.standard.bool(forKey: signedOutKey) else { return nil }
        var query = self.query(); query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return WantCredential.restore(data, for: endpoint)
    }
    func save(_ credential: WantCredential) -> Bool {
        var bound = credential
        bound.endpoint = endpoint
        guard let data = try? JSONEncoder().encode(bound) else { return false }
        var item = query()
        var status = SecItemUpdate(item as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        if status == errSecSuccess { UserDefaults.standard.removeObject(forKey: signedOutKey) }
        return status == errSecSuccess
    }
    func delete() -> Bool {
        UserDefaults.standard.set(true, forKey: signedOutKey)
        let status = SecItemDelete(query() as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private func query() -> [String: Any] {
        let context = LAContext()
        context.interactionNotAllowed = true
        return [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.msgblast.wantmcp.\(Bundle.main.bundleIdentifier ?? "unknown")",
                kSecAttrAccount as String: account,
                kSecUseDataProtectionKeychain as String: true, kSecUseAuthenticationContext as String: context]
    }
}
