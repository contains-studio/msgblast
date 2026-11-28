import AppKit
import msgblastCore

/// Settings' Connect with ChatGPT: signs in through the system browser and shows the account in use.
/// Demo simulates the sign-in and never opens the browser or the Keychain.
@MainActor final class ChatGPTConnection: ObservableObject {
    struct Status: Equatable {
        var email: String?
        var sharesPlan: Bool
    }
    @Published private(set) var status: Status?
    @Published private(set) var signingIn = false
    @Published private(set) var message: String?
    /// A sign-in came back with another account than the saved one.
    @Published private(set) var offerNewAccount = false
    /// OpenAI asks apps to say once, after the first sign-in, that usage now comes from the plan.
    @Published var welcome = false
    let demo: Bool
    private let accounts: ChatGPTAccounts
    private weak var model: AppModel?
    private var callback: WantOAuthCallback?
    private static let welcomedKey = "chatGPTPlanWelcomeShown"

    init(accounts: ChatGPTAccounts, demo: Bool, model: AppModel) {
        self.accounts = accounts; self.demo = demo; self.model = model
    }

    func load() async {
        guard !demo else { return }
        do { status = try await accounts.current().flatMap(Self.status) } catch { message = error.localizedDescription }
    }

    private static func status(_ account: ChatGPTRegistration) -> Status? {
        account.tokens == nil ? nil : Status(email: account.email, sharesPlan: account.sharesPlan)
    }

    func connect(newAccount: Bool = false) {
        guard !signingIn else { return }
        message = nil; offerNewAccount = false; signingIn = true
        let started = Date()
        Task {
            defer { signingIn = false; callback = nil }
            do {
                let status = demo ? try await simulatedSignIn() : try await signIn(newAccount: newAccount)
                self.status = status
                model?.recordOperation(.setup, success: true, started: started)
                if status?.sharesPlan == true, !UserDefaults.standard.bool(forKey: Self.welcomedKey) {
                    UserDefaults.standard.set(true, forKey: Self.welcomedKey)
                    welcome = true
                }
            } catch is CancellationError {
            } catch {
                message = error.localizedDescription
                offerNewAccount = error as? ChatGPTSignInError == .differentAccount
                model?.recordOperation(.setup, success: false, started: started)
            }
        }
    }

    /// The loopback listener starts before the browser opens, and stops when the sign-in ends.
    private func signIn(newAccount: Bool) async throws -> Status? {
        let callback = WantOAuthCallback(path: ChatGPTTokenSharing.callbackPath)
        self.callback = callback
        defer { callback.stop() }
        let (url, attempt) = try await accounts.signInURL(redirect: try await callback.start(), newAccount: newAccount)
        NSWorkspace.shared.open(url)
        return Self.status(try await accounts.finishSignIn(try await callback.wait(), attempt: attempt))
    }

    private func simulatedSignIn() async throws -> Status {
        try await Task.sleep(for: .seconds(1.5))
        return Status(email: "demo@example.com", sharesPlan: true)
    }

    func cancel() { callback?.stop() }

    func disconnect() {
        message = nil
        Task {
            guard !demo else { status = nil; return }
            do {
                let confirmed = try await accounts.disconnect()
                status = nil
                if !confirmed { message = "Disconnected on this Mac, but OpenAI did not confirm it. Also remove msgblast in ChatGPT Settings." }
            } catch { message = error.localizedDescription }
        }
    }
}
