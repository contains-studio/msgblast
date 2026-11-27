import Foundation

public enum CodexAgentSessionError: LocalizedError, Equatable {
    case appServerUnavailable(String), server(String), stopped(String), busy, closed
    public var errorDescription: String? {
        switch self {
        case .appServerUnavailable(let detail):
            "Codex couldn't start the msgblast agent. It needs a Codex version with `codex app-server`; update Codex in Terminal, then try again." + (detail.isEmpty ? "" : " Codex said: \(detail)")
        case .server(let message): message
        case .stopped(let detail):
            "Codex stopped before the reply finished. Check Codex in Terminal, then try again." + (detail.isEmpty ? "" : " Codex said: \(detail)")
        case .busy: "The msgblast agent is still answering. Wait for it or stop it first."
        case .closed: "The msgblast agent was closed."
        }
    }
}

/// The built-in msgblast agent on the person's Codex account, through `codex app-server` over stdio JSON-RPC.
/// It gets msgblast's MCP tools and nothing else: no shell, files, web search, apps, plugins or hooks.
public actor CodexAgentSession: MsgblastAgentRunner {
    private struct Message: @unchecked Sendable { let object: [String: Any] }
    static let disabledFeatures = ["shell_tool", "unified_exec", "view_image", "apps", "plugins", "remote_plugin", "hooks",
                                   "browser_use", "browser_use_external", "computer_use", "image_generation", "multi_agent",
                                   "tool_suggest", "skill_mcp_dependency_install"]

    private let agent: InstalledPersonalAgent, codexHome: URL?, launchConfig: [String], instructions: String, sessionKey: String
    private var threadID: String?
    private var process: Process?, group: pid_t?, input: FileHandle?, directory: URL?, launches = 0
    private var nextID = 0, pending: [Int: CheckedContinuation<Message, Error>] = [:], stderrTail = ""
    private var turn: AsyncStream<MsgblastAgentEvent>.Continuation?, turnNumber = 0, turnID: String?
    private var interruptRequested = false, wroteText = false, closed = false, opening = false

    /// `codexHome` and `launchConfig` (extra `-c` overrides) select a managed login; without them Codex uses `codex login`.
    /// `sessionID` resumes a saved conversation.
    public init(agent: InstalledPersonalAgent, codexHome: URL? = nil, launchConfig: [String] = [], instructions: String,
                sessionKey: String, sessionID: String? = nil) {
        self.agent = agent; self.codexHome = codexHome; self.launchConfig = launchConfig
        self.instructions = instructions; self.sessionKey = sessionKey; threadID = sessionID
    }

    public nonisolated func send(_ text: String) -> AsyncStream<MsgblastAgentEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: MsgblastAgentEvent.self)
        Task { await start(text, continuation) }
        return stream
    }

    public func interrupt() async {
        guard turn != nil else { return }
        interruptRequested = true
        await sendInterrupt()
    }

    public func close() async {
        closed = true
        shutDown(.closed)
    }

    static func threadConfig(executable: String, sessionKey: String, otherServers: [String]) -> [String: Any] {
        var server = MsgblastAgent.mcpServer(executable: executable, sessionKey: sessionKey)
        server["default_tools_approval_mode"] = "approve"
        var config: [String: Any] = ["mcp_servers.msgblast": server, "web_search": "disabled"]
        for feature in disabledFeatures { config["features.\(feature)"] = false }
        for name in otherServers where name != "msgblast" { config["mcp_servers.\(name).enabled"] = false }
        return config
    }

    /// Answers Codex's server requests: msgblast's own tools are approved, everything else is declined.
    static func answer(_ method: String, _ params: [String: Any]) -> [String: Any]? {
        switch method {
        case "mcpServer/elicitation/request":
            let kind = (params["_meta"] as? [String: Any])?["codex_approval_kind"] as? String
            return params["serverName"] as? String == "msgblast" && kind == "mcp_tool_call" ? ["action": "accept", "content": [:]] : ["action": "decline"]
        case "item/commandExecution/requestApproval", "item/fileChange/requestApproval": return ["decision": "decline"]
        case "item/permissions/requestApproval": return ["permissions": [:], "scope": "turn"]
        default: return nil
        }
    }

    private func start(_ text: String, _ continuation: AsyncStream<MsgblastAgentEvent>.Continuation) async {
        guard !closed, turn == nil else {
            continuation.yield(.failed((closed ? CodexAgentSessionError.closed : .busy).errorDescription ?? ""))
            return continuation.finish()
        }
        turnNumber += 1
        let number = turnNumber
        turn = continuation; turnID = nil; interruptRequested = false; wroteText = false
        do {
            if process == nil {
                do { try await open() } catch { shutDown(nil); throw error }
            }
            guard number == turnNumber else { return }
            guard let threadID else { throw CodexAgentSessionError.stopped(lastErrorLine) }
            if interruptRequested { return finishTurn(.completed(sessionID: threadID)) }
            let result = try await request("turn/start", ["threadId": threadID, "input": [["type": "text", "text": text]]])
            guard number == turnNumber, turn != nil else { return }
            turnID = turnID ?? (result.object["turn"] as? [String: Any])?["id"] as? String
            if interruptRequested { await sendInterrupt() }
        } catch {
            if number == turnNumber { finishTurn(.failed(error.localizedDescription)) }
        }
    }

    private func open() async throws {
        opening = true
        defer { opening = false }
        let (folder, errorReader) = try launch()
        do {
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1"
            _ = try await request("initialize", ["clientInfo": ["name": "msgblast", "title": "msgblast", "version": version]], timeout: 30)
        } catch {
            shutDown(nil)
            await errorReader.value
            throw CodexAgentSessionError.appServerUnavailable(lastErrorLine)
        }
        try write(["method": "initialized"])
        try await openThread(in: folder)
    }

    private func launch() throws -> (URL, Task<Void, Never>) {
        let files = FileManager.default
        // An empty owner-only folder, so no project config or instructions load.
        let folder = files.temporaryDirectory.appendingPathComponent("msgblast-agent-\(UUID())", isDirectory: true)
        try files.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = agent.path; environment["NO_COLOR"] = "1"
        environment.removeValue(forKey: "CLAUDECODE")
        if let codexHome {
            environment["CODEX_HOME"] = codexHome.path
            for key in ["OPENAI_API_KEY", "CODEX_API_KEY", "CODEX_ACCESS_TOKEN"] { environment.removeValue(forKey: key) }
        }
        let process = Process(), stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.executableURL = agent.executableURL
        process.arguments = ["app-server"] + launchConfig.flatMap { ["-c", $0] }
        process.currentDirectoryURL = folder; process.environment = environment
        process.standardInput = stdin; process.standardOutput = stdout; process.standardError = stderr
        // A write after Codex exits fails with EPIPE instead of signalling the app.
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        let output = Self.chunks(stdout), errors = Self.chunks(stderr)
        do { try process.run() } catch {
            try? files.removeItem(at: folder)
            throw PersonalAgentError.unavailable(agent.provider.name)
        }
        launches += 1
        let current = launches
        self.process = process; group = AgentProcess.processGroup(of: process)
        input = stdin.fileHandleForWriting; directory = folder; stderrTail = ""
        let errorReader = Task { for await chunk in errors { noteError(chunk) } }
        Task {
            var buffer = Data()
            for await chunk in output {
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    receive(buffer[buffer.startIndex..<newline])
                    buffer.removeSubrange(buffer.startIndex...newline)
                }
            }
            await errorReader.value
            exited(current)
        }
        return (folder, errorReader)
    }

    private func openThread(in folder: URL) async throws {
        let read = try await request("config/read", ["cwd": folder.path])
        let servers = Array(((read.object["config"] as? [String: Any])?["mcp_servers"] as? [String: Any] ?? [:]).keys)
        // Codex splits override keys on dots, so a server named with one can't be turned off.
        if let name = servers.first(where: { $0.contains(".") }) {
            throw CodexAgentSessionError.server("Codex has an MCP server named \"\(name)\" that msgblast can't turn off for the msgblast agent. Rename it in your Codex config, then try again.")
        }
        var params: [String: Any] = ["cwd": folder.path, "approvalPolicy": "never", "sandbox": "read-only", "developerInstructions": instructions,
                                     "config": Self.threadConfig(executable: Bundle.main.executableURL?.path ?? "msgblast", sessionKey: sessionKey, otherServers: servers)]
        let result: Message
        if let threadID {
            params["threadId"] = threadID
            result = try await request("thread/resume", params)
        } else {
            params["ephemeral"] = false
            result = try await request("thread/start", params)
        }
        guard let id = (result.object["thread"] as? [String: Any])?["id"] as? String else {
            throw CodexAgentSessionError.server("Codex didn't open a conversation for the msgblast agent.")
        }
        threadID = id
    }

    private func request(_ method: String, _ params: [String: Any], timeout: Int? = nil) async throws -> Message {
        nextID += 1
        let id = nextID
        try write(["id": id, "method": method, "params": params])
        if let timeout {
            Task { try? await Task.sleep(for: .seconds(timeout)); resolve(id, .failure(CodexAgentSessionError.stopped(""))) }
        }
        return try await withCheckedThrowingContinuation { pending[id] = $0 }
    }

    private func write(_ object: [String: Any]) throws {
        guard let input else { throw CodexAgentSessionError.stopped(lastErrorLine) }
        do { try input.write(contentsOf: JSONSerialization.data(withJSONObject: object) + Data([0x0A])) } catch {
            throw CodexAgentSessionError.stopped(lastErrorLine)
        }
    }

    private func resolve(_ id: Int, _ result: Result<Message, Error>) {
        pending.removeValue(forKey: id)?.resume(with: result)
    }

    private func receive(_ line: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        let params = object["params"] as? [String: Any] ?? [:]
        if let method = object["method"] as? String, let id = object["id"] {
            let reply: [String: Any] = Self.answer(method, params).map { ["id": id, "result": $0] }
                ?? ["id": id, "error": ["code": -32601, "message": "msgblast doesn't support \(method)."]]
            try? write(reply)
        } else if let method = object["method"] as? String {
            notify(method, params)
        } else if let id = object["id"] as? Int {
            if let error = object["error"] as? [String: Any] {
                resolve(id, .failure(CodexAgentSessionError.server(error["message"] as? String ?? "Codex returned an error.")))
            } else {
                resolve(id, .success(Message(object: object["result"] as? [String: Any] ?? [:])))
            }
        }
    }

    private func notify(_ method: String, _ params: [String: Any]) {
        guard turn != nil, let threadID, params["threadId"] as? String == threadID else { return }
        let item = params["item"] as? [String: Any] ?? [:]
        switch method {
        case "turn/started":
            turnID = (params["turn"] as? [String: Any])?["id"] as? String
            if interruptRequested { Task { await sendInterrupt() } }
        case "item/agentMessage/delta":
            guard let delta = params["delta"] as? String else { return }
            wroteText = true
            turn?.yield(.text(delta))
        case "item/started" where item["type"] as? String == "agentMessage" && wroteText:
            turn?.yield(.text("\n\n"))
        case "item/started", "item/completed":
            guard item["type"] as? String == "mcpToolCall", let tool = item["tool"] as? String else { return }
            turn?.yield(.tool(name: tool, finished: method == "item/completed", failed: item["status"] as? String == "failed"))
        case "turn/completed":
            let completed = params["turn"] as? [String: Any] ?? [:], error = completed["error"] as? [String: Any]
            finishTurn(completed["status"] as? String == "failed"
                       ? .failed(error?["message"] as? String ?? "Codex couldn't finish the reply.") : .completed(sessionID: threadID))
        default: break
        }
    }

    private func sendInterrupt() async {
        guard let threadID, let turnID else { return }
        _ = try? await request("turn/interrupt", ["threadId": threadID, "turnId": turnID])
    }

    private func finishTurn(_ event: MsgblastAgentEvent) {
        turn?.yield(event)
        turn?.finish()
        turn = nil; turnID = nil
    }

    private static func chunks(_ pipe: Pipe) -> AsyncStream<Data> {
        AsyncStream { continuation in
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil; continuation.finish() } else { continuation.yield(data) }
            }
        }
    }

    private func noteError(_ data: Data) {
        stderrTail = String((stderrTail + String(decoding: data, as: UTF8.self)).suffix(2_000))
    }

    private var lastErrorLine: String {
        stderrTail.split(whereSeparator: \.isNewline).last.map { String($0.prefix(300)) } ?? ""
    }

    private func exited(_ current: Int) {
        guard current == launches, process != nil else { return }
        // While opening, `open` reports the failure itself.
        shutDown(opening ? nil : .stopped(lastErrorLine))
    }

    /// Ends the app-server's whole process group. The saved thread ID stays, so the next turn resumes it.
    private func shutDown(_ reason: CodexAgentSessionError?) {
        if let reason { finishTurn(.failed(reason.errorDescription ?? "")) }
        for id in Array(pending.keys) { resolve(id, .failure(reason ?? .stopped(lastErrorLine))) }
        try? input?.close()
        if let process { AgentProcess.stop(process, group: group) }
        if let directory { try? FileManager.default.removeItem(at: directory) }
        process = nil; group = nil; input = nil; directory = nil
    }
}
