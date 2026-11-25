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
    /// Bumped on sign-out so requests still in flight from the old sign-in are discarded.
    private var session = 0
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
        update { $0.cursors = [:] }
    }

    private func store(_ credential: WantCredential) {
        self.credential = credential
        guard keychain.save(credential) else { error = "msgblast could not save your sign-in to the Keychain."; return }
        signedIn = true
        start()
    }

    private func token() -> String? { credential?.accessToken }

    /// Loads an item's entries when it is opened, and again when the event feed reports changes.
    func loadEntries(_ item: WantItem) async {
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
