import Foundation
import Network
import msgblastCore

/// The socket `msgblast __chatgpt-token` asks for Codex's ChatGPT token. It sits in an owner-only folder
/// in this build's support folder, takes one short request per connection, and answers once.
@MainActor final class ChatGPTTokenListener {
    private let socket: URL, accounts: ChatGPTAccounts
    private var listener: NWListener?
    private var open = 0

    init(supportDirectory: URL, accounts: ChatGPTAccounts) {
        socket = ChatGPTCodex.socket(supportDirectory: supportDirectory)
        self.accounts = accounts
    }

    func start() {
        guard listener == nil else { return }
        let folder = socket.deletingLastPathComponent(), files = FileManager.default
        do {
            try files.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
            try? files.removeItem(at: socket)
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .unix(path: socket.path)
            let listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { [weak self] connection in Task { @MainActor in self?.serve(connection) } }
            listener.stateUpdateHandler = { [socket] state in
                if case .ready = state { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: socket.path) }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            listener = nil
        }
    }

    private func serve(_ connection: NWConnection) {
        guard open < 16 else { return connection.cancel() }
        open += 1
        connection.start(queue: .main)
        let deadline = Task { try await Task.sleep(for: .seconds(5)); connection.cancel() }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] data, _, _, _ in
            Task { @MainActor in
                deadline.cancel()
                guard let self, let data, data.last == 0x0A else { self?.open -= 1; return connection.cancel() }
                let reply = await ChatGPTCodex.reply(to: data.dropLast(), accounts: self.accounts)
                connection.send(content: reply, completion: .contentProcessed { _ in connection.cancel() })
                self.open -= 1
            }
        }
    }
}

/// `msgblast __chatgpt-token <client id>`: Codex's auth command. Prints the running app's current token
/// for that account and exits, or explains why there is none.
enum ChatGPTTokenCommand {
    static func runIfRequested() {
        let arguments = CommandLine.arguments.dropFirst()
        guard arguments.first == ChatGPTCodex.tokenCommand else { return }
        guard arguments.count == 2, let clientID = arguments.last else { fail("usage: msgblast \(ChatGPTCodex.tokenCommand) CLIENT_ID") }
        let socket = ChatGPTCodex.socket(supportDirectory: AgentControlCommand.socket.deletingLastPathComponent())
        guard let reply = try? AgentControlSocketClient.exchange(ChatGPTCodex.request(clientID: clientID), socket: socket.path) else {
            fail("msgblast is not running, so it cannot give Codex a ChatGPT token.")
        }
        switch ChatGPTCodex.token(from: reply) {
        case .success(let token): FileHandle.standardOutput.write(Data((token + "\n").utf8)); exit(0)
        case .failure(let error): fail(error.message)
        }
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(1)
    }
}
