import Foundation

/// The built-in msgblast agent on the person's installed Claude Code: one long-lived
/// `claude --print` process speaking stream-json whose only tools are msgblast's MCP tools.
/// Claude Code keeps its own login; `LocalPersonalAgent.accountStatus` reports which account it bills.
public final class ClaudeAgentSession: MsgblastAgentRunner, @unchecked Sendable {
    static let toolPrefix = "mcp__msgblast__"
    static let endedMessage = "This msgblast agent conversation has ended. Start a new one."
    private let process = Process()
    private let input = Pipe(), output = Pipe()
    private let directory: URL
    private let idleTimeout: TimeInterval
    private let lock = NSLock(), stopping = NSLock()
    private var group: pid_t?
    private var turn: AsyncStream<MsgblastAgentEvent>.Continuation?
    private var interrupted = false, closed = false
    private var ended: String?
    private var lastOutput = Date()
    private var pending = Data()
    private var tools: [String: String] = [:]

    public static func start(using agent: InstalledPersonalAgent, msgblastExecutable: String, sessionKey: String,
                             instructions: String, resuming sessionID: String? = nil, workingDirectory: URL,
                             idleTimeout: TimeInterval = 20 * 60) async throws -> ClaudeAgentSession {
        guard agent.provider == .claude else { throw PersonalAgentError.unsupportedProvider(agent.provider) }
        if let sessionID, UUID(uuidString: sessionID) == nil { throw PersonalAgentError.invalidResponse(agent.provider.name) }
        guard await LocalPersonalAgent.supportsConfiguredConversation(using: agent) else { throw PersonalAgentError.conversationVersionRequired }
        return try ClaudeAgentSession(agent: agent, msgblastExecutable: msgblastExecutable, sessionKey: sessionKey, instructions: instructions,
                                      sessionID: sessionID, workingDirectory: workingDirectory, idleTimeout: idleTimeout)
    }

    static func arguments(configuration: URL, instructions: String, sessionID: String?) -> [String] {
        ["--print", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
         "--tools", "", "--strict-mcp-config", "--mcp-config", configuration.path, "--allowedTools", toolPrefix + "*",
         "--permission-mode", "dontAsk", "--permission-prompts", "none", "--disable-slash-commands",
         "--setting-sources", "", "--settings", "{\"disableAllHooks\":true}", "--append-system-prompt", instructions]
            + (sessionID.map { ["--resume", $0] } ?? [])
    }

    private init(agent: InstalledPersonalAgent, msgblastExecutable: String, sessionKey: String, instructions: String,
                 sessionID: String?, workingDirectory: URL, idleTimeout: TimeInterval) throws {
        let files = FileManager.default
        self.idleTimeout = idleTimeout
        directory = files.temporaryDirectory.appendingPathComponent("msgblast-Agent-\(UUID())", isDirectory: true)
        try files.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            // The session key lives only in this owner-only file, never in argv or this process's environment.
            let configuration = directory.appendingPathComponent("mcp.json"), errors = directory.appendingPathComponent("stderr.txt")
            let body = try JSONSerialization.data(withJSONObject: ["mcpServers": ["msgblast": MsgblastAgent.mcpServer(executable: msgblastExecutable, sessionKey: sessionKey)]])
            guard files.createFile(atPath: configuration.path, contents: body, attributes: [.posixPermissions: 0o600]),
                  files.createFile(atPath: errors.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw PersonalAgentError.unavailable(agent.provider.name)
            }
            try files.createDirectory(at: workingDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = agent.path
            environment["NO_COLOR"] = "1"
            environment["ENABLE_CLAUDEAI_MCP_SERVERS"] = "false"
            environment.removeValue(forKey: "CLAUDECODE")
            environment.removeValue(forKey: MsgblastAgent.sessionKeyEnvironment)
            process.executableURL = agent.executableURL
            process.arguments = Self.arguments(configuration: configuration, instructions: instructions, sessionID: sessionID)
            process.currentDirectoryURL = workingDirectory
            process.environment = environment
            process.standardInput = input; process.standardOutput = output
            process.standardError = try FileHandle(forWritingTo: errors)
            _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
            do { try process.run() } catch { throw PersonalAgentError.unavailable(agent.provider.name) }
        } catch {
            try? files.removeItem(at: directory)
            throw error
        }
        group = AgentProcess.group(of: process)
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in self?.receive(handle.availableData) }
        Task.detached { [weak self] in
            while let interval = self.map({ min(5, $0.idleTimeout) }) {
                try? await Task.sleep(for: .seconds(interval))
                guard let self, self.continueAfterIdleCheck() else { return }
            }
        }
    }

    deinit { shutdown() }

    public func send(_ text: String) -> AsyncStream<MsgblastAgentEvent> {
        AsyncStream { continuation in
            let refusal: String? = lock.withLock {
                if let ended { return ended }
                if turn != nil { return "Claude Code is still answering the previous request." }
                turn = continuation; interrupted = false; lastOutput = Date()
                return nil
            }
            if let refusal { continuation.yield(.failed(refusal)); continuation.finish(); return }
            let message: [String: Any] = ["type": "user", "message": ["role": "user", "content": [["type": "text", "text": text]]],
                                          "parent_tool_use_id": NSNull(), "session_id": ""]
            // A failed write means Claude Code exited; its end of output finishes this turn.
            write(message)
        }
    }

    /// Claude Code's stream-json interrupt ends the turn with an error result and keeps the conversation.
    public func interrupt() async {
        guard lock.withLock({ interrupted = turn != nil; return interrupted }) else { return }
        write(["type": "control_request", "request_id": UUID().uuidString, "request": ["subtype": "interrupt"]])
    }

    public func close() async {
        await Task.detached { [self] in shutdown() }.value
    }

    /// Ends the turn, stops Claude Code's whole process group (the msgblast MCP server included) and deletes the key file.
    /// A second caller waits until the first has finished.
    private func shutdown() {
        stopping.withLock {
            guard lock.withLock({ defer { closed = true }; return !closed }) else { return }
            finish(.failed(Self.endedMessage), ending: Self.endedMessage)
            try? input.fileHandleForWriting.close()
            AgentProcess.stop(process, group: group)
            output.fileHandleForReading.readabilityHandler = nil
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func write(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        try? input.fileHandleForWriting.write(contentsOf: data + [10])
    }

    private func continueAfterIdleCheck() -> Bool {
        let idle: Bool? = lock.withLock { closed ? nil : turn != nil && Date().timeIntervalSince(lastOutput) >= idleTimeout }
        guard let idle else { return false }
        guard idle else { return true }
        // A hung CLI may never answer an interrupt, so end the whole session; the saved id resumes it.
        finish(.failed("Claude Code stopped responding, so msgblast stopped it. Your conversation is saved."))
        shutdown()
        return false
    }

    private func receive(_ data: Data) {
        guard !data.isEmpty else {
            output.fileHandleForReading.readabilityHandler = nil
            process.waitUntilExit()
            let message = exitMessage()
            finish(.failed(message), ending: message)
            return
        }
        let lines: [Data] = lock.withLock {
            lastOutput = Date()
            pending.append(data)
            var lines: [Data] = []
            while let end = pending.firstIndex(of: 10) {
                lines.append(pending[pending.startIndex..<end])
                pending.removeSubrange(pending.startIndex...end)
            }
            return lines
        }
        lines.forEach(handle)
    }

    private func handle(_ line: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        switch object["type"] as? String {
        case "system" where object["subtype"] as? String == "init":
            let servers = object["mcp_servers"] as? [[String: Any]] ?? []
            let connected = servers.contains { $0["name"] as? String == "msgblast" && $0["status"] as? String == "connected" }
            let foreign = (object["tools"] as? [String] ?? []).contains { !$0.hasPrefix(Self.toolPrefix) }
            if connected && !foreign { return }
            finish(.failed(connected ? "Claude Code offered tools other than msgblast's, so msgblast stopped it. Nothing was sent."
                                     : "msgblast's tools did not connect to Claude Code. Nothing was sent."), ending: Self.endedMessage)
            shutdown()
        case "stream_event":
            let event = object["event"] as? [String: Any] ?? [:]
            if let delta = event["delta"] as? [String: Any], delta["type"] as? String == "text_delta", let text = delta["text"] as? String {
                yield(.text(text))
            }
            if let block = event["content_block"] as? [String: Any], block["type"] as? String == "tool_use",
               let id = block["id"] as? String, let name = block["name"] as? String {
                let tool = name.hasPrefix(Self.toolPrefix) ? String(name.dropFirst(Self.toolPrefix.count)) : name
                lock.withLock { tools[id] = tool }
                yield(.tool(name: tool, finished: false, failed: false))
            }
        case "user":
            let content = (object["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            for block in content where block["type"] as? String == "tool_result" {
                guard let id = block["tool_use_id"] as? String, let tool = lock.withLock({ tools.removeValue(forKey: id) }) else { continue }
                yield(.tool(name: tool, finished: true, failed: block["is_error"] as? Bool == true))
            }
        case "result":
            if object["is_error"] as? Bool == false, let id = object["session_id"] as? String, UUID(uuidString: id) != nil {
                finish(.completed(sessionID: id))
            } else if lock.withLock({ interrupted }) {
                finish(.failed("Stopped. Claude Code may have finished some tool calls before it stopped."))
            } else {
                let detail = (object["result"] as? String).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
                finish(.failed(detail.isEmpty ? "Claude Code could not finish this request." : detail))
            }
        default: break
        }
    }

    private func exitMessage() -> String {
        let errors = (try? AgentProcess.readOutput(directory.appendingPathComponent("stderr.txt")))?.lowercased() ?? ""
        if ["unknown option", "unrecognized option", "unexpected argument"].contains(where: errors.contains) {
            return PersonalAgentError.conversationVersionRequired.localizedDescription
        }
        return PersonalAgentError.failed(PersonalAgentProvider.claude.name, process.terminationStatus).localizedDescription
    }

    private func yield(_ event: MsgblastAgentEvent) { _ = lock.withLock { turn }?.yield(event) }

    private func finish(_ event: MsgblastAgentEvent, ending: String? = nil) {
        let current = lock.withLock {
            defer { turn = nil; tools = [:] }
            if ended == nil { ended = ending }
            return turn
        }
        current?.yield(event)
        current?.finish()
    }
}
