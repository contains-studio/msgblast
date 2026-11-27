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
        /// The newest blast for each item, so its replies show and activity goes to the same agents.
        var blasts: [String: Blast] = [:]
        var forwardedConversations: [String: UUID] = [:]
        var forwardActivity = false
        var forwardAgents: [String] = []

        init() {}
        /// Each field is optional on disk, so a file from a build that knew fewer of them still loads.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            grantID = try c.decodeIfPresent(UUID.self, forKey: .grantID)
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
    private var accessMonitor: Task<Void, Never>?
    private var removedLists: Set<String> = []
    private var poller: Task<Void, Never>?
    private var latestReload = UUID()
    private var reloadPending = false
    /// Bumped on sign-out so requests still in flight from the old sign-in are discarded.
    private var session = 0
    private var forwardingRevision = 0
    private var callback: WantOAuthCallback?
    private var authorization: Task<Void, Never>?
    private var refreshing: Task<String, Error>?
    private lazy var sends = AgentControlSends(model: app, source: .wants)
    private let keychain: WantKeychain
    private var forwardingGrant: String { saved.grantID?.uuidString ?? "unbound" }
    private var forwardingRevoked: Bool {
        UserDefaults.standard.string(forKey: keychain.forwardingRevocationKey) == forwardingGrant
    }

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
            removedLists = credential?.removedLists ?? []
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
        if forwardingRevoked { saved.forwardActivity = false }
    }

    func start() {
        guard signedIn, poller == nil else { return }
        if keychain.endpoint == WantOAuth.resource, let client = service as? WantMCPClient {
            let generation = session
            accessMonitor = Task { await followAccess(client, generation: generation) }
        }
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
            for id in try await service.writableListIDs() where !removedLists.contains(id) {
                guard latestReload == reloadID else { return false }
                loaded.append(try await service.list(id))
            }
            for list in loaded {
                guard latestReload == reloadID else { return false }
                loadedComments[list.id] = try await service.comments(listID: list.id)
                guard latestReload == reloadID else { return false }
                loadedSuggestions[list.id] = try await service.suggestions(listID: list.id)
            }
            let visible = Set(loaded.flatMap { ($0.items ?? []).map(\.id) })
            for id in entries.keys where visible.contains(id) {
                guard latestReload == reloadID else { return false }
                loadedEntries[id] = try await service.entries(itemID: id)
            }
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

    var claim: WantClaim? { credential?.claim.flatMap { removedLists.contains($0.listID) ? nil : $0 } }

    func startList(title: String, format: WantFormat) async throws {
        guard !signedIn, !signingIn else { throw CancellationError() }
        if app.demo {
            let fixture = WantFixture()
            service = fixture
            let grant = await fixture.startList(title: title, format: format)
            guard store(grant) else { throw WantError.server("The list could not be saved.") }
        } else {
            guard keychain.endpoint == WantOAuth.resource else { throw WantError.server("Start a list requires The Want MCP.") }
            let grant = try await WantClaim.start(title: title, format: format)
            guard store(grant) else { throw WantError.server("The list key could not be saved.") }
        }
    }

    func keepList(_ claim: WantClaim) {
        guard self.claim == claim, claim.active else { return }
        if app.demo { credential?.claim = nil; objectWillChange.send() }
        else { NSWorkspace.shared.open(claim.url) }
    }

    func useWriteKey(_ text: String) -> Bool {
        guard !signedIn, !signingIn else { return false }
        guard let credential = WantCredential.writeKey(text) else { error = "That isn't a write key. Keys start with wk_."; return false }
        error = nil
        return store(credential)
    }

    func signOut() {
        accessMonitor?.cancel(); accessMonitor = nil; removedLists.removeAll()
        poller?.cancel(); poller = nil; session += 1; latestReload = UUID()
        refreshing?.cancel(); refreshing = nil
        if !app.demo, !keychain.delete() { error = "Signed out on this Mac. The Keychain could not remove the saved key." }
        credential = nil; reloadPending = false; answering = []
        signedIn = false; lists = []; comments = [:]; suggestions = [:]; entries = [:]
        if !update({ $0 = Saved() }) { saved = Saved() }
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
        service = WantMCPClient(endpoint: keychain.endpoint, version: version, renew: { [weak self] refused in
            guard let self else { throw CancellationError() }
            return try await self.token(for: generation, refused: refused)
        }) { [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.token(for: generation)
        }
    }

    /// The bearer token, refreshed first when an OAuth token is about to expire.
    private func token(for generation: Int, refused: String? = nil) async throws -> String {
        guard generation == session, let credential else { throw CancellationError() }
        if let refused {
            guard refused == credential.accessToken else { return credential.accessToken }
            guard credential.refreshToken != nil else { throw WantError.unauthorized(resourceMetadata: nil) }
        } else if credential.refreshToken == nil || (credential.expiresAt ?? .distantFuture) >= Date().addingTimeInterval(60) {
            return credential.accessToken
        }
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
            next.removedLists = self.credential?.removedLists
            next.claim = self.credential?.claim
            guard keychain.save(next) else { throw WantError.server("msgblast could not save your refreshed sign-in to the Keychain.") }
            self.credential = next
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
            if session == self.session, lists.contains(where: { $0.items?.contains(where: { $0.id == item.id }) == true }) { entries[item.id] = loaded }
        } catch { if session == self.session { fail(error) } }
    }

    // MARK: Items and blasts

    func addItem(_ text: String, to list: WantList) async -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, signedIn, !removedLists.contains(list.id), let service else { return false }
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
        guard signedIn, !text.isEmpty, lists.contains(where: { $0.items?.contains(where: { $0.openQuestion?.id == question.id }) == true }), answering.insert(question.id).inserted else { return false }
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
        guard signedIn, !removedLists.contains(list.id), !sending else { return }
        sendsInFlight += 1
        defer { sendsInFlight -= 1 }
        let generation = session
        if entries[item.id] == nil { await loadEntries(item) }
        guard generation == session, !removedLists.contains(list.id), let posted = entries[item.id] else { return }
        let prompt = WantPrompt.ask(item: item, list: list, posted: posted)
        let action = RemoteAction.createConversation(text: prompt, agentIDs: agentIDs.compactMap(AgentControlSend.remoteID), attachmentIDs: [])
        let authorized: @MainActor () -> Bool = { !self.removedLists.contains(list.id) }
        guard let result = await send(action, isAuthorized: authorized), generation == session, authorized() else { return }
        update { $0.blasts[item.id] = .init(comparisonID: result.conversationID, agents: agentIDs) }
    }

    /// The agents' replies to the newest blast for an item.
    func replies(for item: WantItem) -> (comparison: UUID, turns: [AgentControlTurn])? {
        guard let id = saved.blasts[item.id]?.comparisonID ?? saved.forwardedConversations[item.id], let comparison = app.comparison(id) else { return nil }
        return (id, app.controlTranscript(comparison).filter { !$0.outgoing })
    }

    func openConversation(_ id: UUID) { app.coordinator?.open(id) }

    private func send(_ action: RemoteAction, quietly: Bool = false, isAuthorized: @MainActor () -> Bool = { true }) async -> RemoteCommandResult? {
        let generation = session
        let result = await sends.send(RemoteCommand(action: action), client: "Wants") { self.signedIn && self.session == generation && isAuthorized() }
        guard session == generation else { return nil }
        guard result.outcome != .rejected else {
            guard !quietly else { return result }
            let reasons = result.agentReasons.values.sorted()
            error = ([result.message ?? "msgblast did not send it."] + reasons).joined(separator: " ")
            return nil
        }
        return result
    }

    // MARK: Events

    private func followAccess(_ client: WantMCPClient, generation: Int) async {
        var cursor = 0
        while !Task.isCancelled, session == generation {
            var delay: TimeInterval = 60
            do {
                let page = try await client.accessEvents(after: cursor)
                guard !Task.isCancelled, session == generation else { return }
                guard var next = credential else { return }
                next.apply(page)
                for id in next.removedLists ?? [] { removeAccess(to: id) }
                if next != credential {
                    guard keychain.save(next) else { throw WantError.server("The list connection could not be saved.") }
                    credential = next
                    objectWillChange.send()
                }
                if page.next > cursor && !page.events.isEmpty { delay = 0 }
                cursor = max(cursor, page.next)
            } catch WantError.unavailable(let seconds) { delay = max(seconds, delay) }
            catch { if session == generation { fail(error) } }
            try? await Task.sleep(for: .seconds(delay))
        }
    }

    private func removeAccess(to id: String) {
        guard removedLists.insert(id).inserted else { return }
        latestReload = UUID()
        reloadPending = true
        forwardingRevision += 1
        for item in lists.first(where: { $0.id == id })?.items ?? [] { entries[item.id] = nil }
        lists.removeAll { $0.id == id }
        comments[id] = nil
        suggestions[id] = nil
    }

    /// One round of `events/poll`. Returns the seconds until the next round.
    private func poll() async -> TimeInterval {
        let session = self.session
        let revision = forwardingRevision
        var pages: [WantEventPage] = []
        var delay: TimeInterval = 30, changed = reloadPending
        var cursor = saved.cursors[Self.activity]
        do {
            for _ in 0..<10 {
                let page = try await service.poll(Self.activity, cursor: cursor)
                guard session == self.session else { return delay }
                pages.append(page)
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
        for page in pages {
            guard session == self.session, await take(page, observedRevision: revision) else { return delay }
        }
        return delay
    }

    /// Saves the cursor before forwarding, so a crash mid-send never forwards the same event twice.
    func take(_ page: WantEventPage, observedRevision: Int? = nil) async -> Bool {
        let session = self.session
        let revision = observedRevision ?? forwardingRevision
        guard let cursor = page.cursor, saved.cursors[Self.activity] != cursor else { return page.events.isEmpty }
        guard update({ $0.cursors[Self.activity] = cursor }) else { reloadPending = true; return false }
        for event in page.events {
            guard session == self.session else { return false }
            guard saved.forwardActivity, revision == forwardingRevision else { break }
            await forward(event, session: session, revision: revision)
        }
        return session == self.session
    }

    func setForwarding(_ on: Bool, agents: [String]? = nil) {
        forwardingRevision += 1
        if !on { UserDefaults.standard.set(forwardingGrant, forKey: keychain.forwardingRevocationKey) }
        let persisted = update { saved in
            saved.forwardActivity = on
            if let agents { saved.forwardAgents = agents }
        }
        if persisted && on { UserDefaults.standard.removeObject(forKey: keychain.forwardingRevocationKey) }
        if !persisted && !on { saved.forwardActivity = false }
    }

    private func forward(_ event: WantEvent, session: Int, revision: Int) async {
        guard let list = lists.first(where: { $0.id == event.listId }), let text = WantPrompt.activity(event, list: list) else { return }
        let itemID = event.item?.id ?? event.entry?.itemId
        let asked = itemID.flatMap { saved.blasts[$0] }
        let targets = WantForwarding.recipients(for: event, enabled: saved.forwardActivity, itemAgents: asked?.agents,
                                                defaults: saved.forwardAgents, sendable: Set(agents.map(\.id)))
        let remote = targets.compactMap(AgentControlSend.remoteID)
        let authorized: @MainActor () -> Bool = {
            session == self.session && revision == self.forwardingRevision && self.saved.forwardActivity && !self.forwardingRevoked
                && itemID.flatMap { self.saved.blasts[$0] } == asked
        }
        guard !remote.isEmpty, remote.count == targets.count, authorized() else { return }
        sendsInFlight += 1
        defer { sendsInFlight -= 1 }
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
    var forwardingRevocationKey: String { "WantMCPForwardingRevoked." + account }
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
