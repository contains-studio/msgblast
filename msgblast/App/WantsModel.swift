import Combine
import CryptoKit
import LocalAuthentication
import Security
import msgblastCore

/// The Wants panel's state: the person's Want MCP lists, sign-in, and the event feed that keeps
/// them current.
@MainActor final class WantsModel: ObservableObject {
    /// What msgblast remembers between launches, in `wants.json` beside `state.json`.
    struct Saved: Codable, Equatable {
        /// `events/poll` cursor per event type.
        var cursors: [String: String] = [:]

        init() {}
        /// Each field is optional on disk, so a file from a build that knew fewer of them still loads.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            cursors = try c.decodeIfPresent([String: String].self, forKey: .cursors) ?? [:]
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
    @Published var error: String?

    private unowned let app: AppModel
    private let fileURL: URL
    /// False when `wants.json` exists but could not be read: it is kept, not overwritten.
    private var canSave = true
    private var credential: WantCredential?
    private var service: WantService!
    private var poller: Task<Void, Never>?
    private var reloadPending = false
    /// Bumped on sign-out so requests still in flight from the old sign-in are discarded.
    private var session = 0
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
            connectService()
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

    @discardableResult func reload() async -> Bool {
        guard signedIn, let service else { return false }
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
            guard session == self.session else { return false }
            lists = loaded
            comments = loadedComments
            suggestions = loadedSuggestions
            entries = entries.filter { visible.contains($0.key) }.merging(loadedEntries) { _, new in new }
            reloadPending = false
            return true
        } catch {
            if session == self.session { reloadPending = true; fail(error) }
            return false
        }
    }

    // MARK: Sign-in

    func useWriteKey(_ text: String) -> Bool {
        guard !signedIn else { return false }
        guard let credential = WantCredential.writeKey(text) else { error = "That isn't a write key. Keys start with wk_."; return false }
        error = nil
        guard update({ $0.cursors = [:] }) else { return false }
        return store(credential)
    }

    func signOut() {
        poller?.cancel(); poller = nil; session += 1
        if !app.demo, !keychain.delete() { error = "Signed out on this Mac. The Keychain could not remove the saved key." }
        credential = nil; reloadPending = false
        signedIn = false; lists = []; comments = [:]; suggestions = [:]; entries = [:]
        update { $0.cursors = [:] }
    }

    @discardableResult private func store(_ credential: WantCredential) -> Bool {
        guard app.demo || WantMCPClient.allowsEndpoint(keychain.endpoint) else { error = "Use an HTTPS Want MCP endpoint, or HTTP on localhost."; return false }
        guard app.demo || keychain.save(credential) else { error = "msgblast could not save your sign-in to the Keychain."; return false }
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

    private func token(for generation: Int) throws -> String? {
        guard session == generation else { throw CancellationError() }
        return credential?.accessToken
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
                changed = changed || !page.events.isEmpty
                delay = max(page.nextPoll ?? delay, 5)
                if !page.hasMore { break }
            }
        } catch {
            if session == self.session { fail(error) }
            return 60
        }
        if changed, !(await reload()) { return 60 }
        guard session == self.session else { return delay }
        update { $0.cursors[Self.activity] = cursor }
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
        guard canSave else { return false }
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
