import Foundation

/// Gets Connect with ChatGPT tokens to Codex without `~/.codex`: a `CODEX_HOME` in this build's support
/// folder, and a model provider whose auth command (`msgblast __chatgpt-token`) asks the running app for
/// the active account's current token over an owner-only socket.
public enum ChatGPTCodex {
    public static let tokenCommand = "__chatgpt-token"
    /// Codex saves the provider id with each conversation and needs it unchanged to resume one.
    public static let provider = "msgblast_chatgpt"
    /// How long Codex waits for the command. A refresh is bounded well below this.
    static let commandTimeout = 60_000

    public static func home(supportDirectory: URL) -> URL { supportDirectory.appendingPathComponent("chatgpt-codex", isDirectory: true) }
    /// Inside an owner-only folder, so only this user can connect.
    public static func socket(supportDirectory: URL) -> URL { supportDirectory.appendingPathComponent("chatgpt/token.sock") }

    /// The `-c` overrides for `codex app-server`. Codex runs the command for each token it needs.
    public static func launchConfig(executable: String, clientID: String) -> [String] {
        func toml(_ text: String) -> String { "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        let auth = "{command=\(toml(executable)),args=[\(toml(tokenCommand)),\(toml(clientID))],timeout_ms=\(commandTimeout),refresh_interval_ms=0}"
        return ["model_provider=\(toml(provider))",
                "model_providers.\(provider)={name=\"ChatGPT plan\",base_url=\(toml(ChatGPTTokenSharing.resource)),model_catalog_url=\(toml(ChatGPTTokenSharing.resource + "/models")),wire_api=\"responses\",requires_openai_auth=false,supports_websockets=false,auth=\(auth)}",
                "features.api_key_model_discovery=true"]
    }

    /// The `codexHome` and `launchConfig` for a Codex session on the active account. Throws when no
    /// account is connected with plan usage allowed.
    public static func launch(supportDirectory: URL, executable: String, accounts: ChatGPTAccounts) async throws -> (codexHome: URL, launchConfig: [String]) {
        _ = try await accounts.accessToken()
        guard let clientID = try await accounts.current()?.clientID else { throw ChatGPTSignInError.signedOut }
        let home = home(supportDirectory: supportDirectory)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return (home, launchConfig(executable: executable, clientID: clientID))
    }

    public static func request(clientID: String) -> Data {
        (try! JSONSerialization.data(withJSONObject: ["version": 1, "client": clientID])) + Data([0x0A])
    }

    /// The app's answer to one request line. A session started on another account gets no token.
    public static func reply(to line: Data, accounts: ChatGPTAccounts) async -> Data {
        let request = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
        let body: [String: String]
        if request?["version"] as? Int != 1 || request?.count != 2 {
            body = ["error": "msgblast did not understand this token request."]
        } else if let client = request?["client"] as? String, (try? await accounts.current())??.clientID == client {
            do { body = ["token": try await accounts.accessToken()] } catch { body = ["error": error.localizedDescription] }
        } else {
            body = ["error": "The ChatGPT connection changed. Start a new msgblast agent chat."]
        }
        return (try! JSONSerialization.data(withJSONObject: body)) + Data([0x0A])
    }

    /// The token from a reply, or the app's message.
    public static func token(from reply: Data) -> Result<String, ChatGPTCodexError> {
        let body = try? JSONSerialization.jsonObject(with: reply) as? [String: String]
        if let token = body?["token"], !token.isEmpty { return .success(token) }
        return .failure(ChatGPTCodexError(message: body?["error"] ?? "msgblast did not return a ChatGPT token."))
    }
}

public struct ChatGPTCodexError: Error, Equatable { public let message: String }
