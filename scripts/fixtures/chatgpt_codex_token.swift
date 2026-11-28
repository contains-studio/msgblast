import Foundation
@testable import msgblastCore

/// Stands in for the app's support-folder lookup with the fixture's own folder.
enum AgentControlCommand {
    static var socket: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["CHATGPT_FIXTURE_SUPPORT"]!).appendingPathComponent("agent-control.sock")
    }
}

final class Box: @unchecked Sendable { var items: [String: Data] = [:] }

/// Run with `__chatgpt-token CLIENT_ID` it is Codex's auth command, exactly as the app runs it. Otherwise it
/// serves the actual token listener for a fixture account and prints the launch config for Codex.
@main enum ChatGPTCodexTokenFixture {
    @MainActor static func main() throws {
        ChatGPTTokenCommand.runIfRequested()
        let support = AgentControlCommand.socket.deletingLastPathComponent(), box = Box()
        let tokens = ChatGPTRegistration.Tokens(accessToken: "fixture-access-token", refreshToken: nil, idToken: "fixture-id-token",
                                                expiresAt: Date().addingTimeInterval(3600), earliestRefreshAt: nil, scopes: [ChatGPTTokenSharing.sharingScope])
        box.items["registration.oaiapp_fixture"] = try JSONEncoder().encode(ChatGPTRegistration(clientID: "oaiapp_fixture", subject: "fixture", tokens: tokens))
        box.items["index"] = try JSONEncoder().encode(ChatGPTAccounts.Index(hostID: "urn:uuid:fixture", active: "oaiapp_fixture", clientIDs: ["oaiapp_fixture"]))
        let accounts = ChatGPTAccounts(storage: .init(read: { box.items[$0] }, write: { box.items[$0] = $1 }))
        let listener = ChatGPTTokenListener(supportDirectory: support, accounts: accounts)
        listener.start()
        Task {
            guard let launch = try? await ChatGPTCodex.launch(supportDirectory: support, executable: CommandLine.arguments[0], accounts: accounts) else { exit(1) }
            print(String(data: try! JSONSerialization.data(withJSONObject: ["codexHome": launch.codexHome.path, "launchConfig": launch.launchConfig]), encoding: .utf8)!)
            fflush(stdout)
        }
        withExtendedLifetime(listener) { RunLoop.main.run() }
    }
}
