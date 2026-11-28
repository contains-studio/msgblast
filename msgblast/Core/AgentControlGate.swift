import Foundation

/// Which outside agents the person approved, and at what level. Saved beside state.json.
/// An unreadable file refuses every agent and is never overwritten.
@MainActor public final class AgentControlGate: ObservableObject {
    public typealias Approve = @MainActor (String) async -> AgentControlAccess?
    @Published public private(set) var approvals: [String: AgentControlAccess] = [:]
    /// Agents the person chose Don't Allow for. They are refused without asking again until
    /// msgblast quits, or until the person clears them in Settings.
    @Published public private(set) var refused: Set<String> = []
    /// Set when an approval could not be saved; it then lasts only until msgblast quits.
    @Published public private(set) var saveError: String?
    public let loadFailed: Bool
    private let file: URL
    private var pending: [String: Task<AgentControlAccess?, Never>] = [:]

    public init(file: URL) {
        self.file = file
        if let data = try? Data(contentsOf: file) {
            let decoded = try? JSONDecoder().decode([String: AgentControlAccess].self, from: data)
            approvals = decoded ?? [:]
            loadFailed = decoded == nil
        } else {
            loadFailed = FileManager.default.fileExists(atPath: file.path)
        }
    }

    /// The client's level, asking the person once if it is new. Nil means refused.
    public func access(for client: String, approve: @escaping Approve) async -> AgentControlAccess? {
        guard !loadFailed, !refused.contains(client) else { return nil }
        if let level = approvals[client] { return level }
        if let waiting = pending[client] { return await waiting.value }
        let task = Task { @MainActor in await approve(client) }
        pending[client] = task
        let level = await task.value
        pending[client] = nil
        guard let level else { refused.insert(client); return nil }
        do { try set(level, for: client) } catch {
            approvals[client] = level
            saveError = "msgblast could not save the approval for \(client), so it lasts until msgblast quits."
        }
        return level
    }

    public func set(_ level: AgentControlAccess?, for client: String) throws {
        guard !loadFailed else { return }
        var next = approvals
        next[client] = level
        try JSONEncoder().encode(next).write(to: file, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        approvals = next
        refused.remove(client)
        saveError = nil
    }

    /// A change made in Settings. If it can't be saved it still applies until msgblast quits,
    /// and Settings shows why.
    public func change(_ level: AgentControlAccess?, for client: String) {
        guard !loadFailed else { return }
        do { try set(level, for: client) } catch {
            approvals[client] = level
            refused.remove(client)
            saveError = "msgblast could not save the change for \(client), so it lasts until msgblast quits."
        }
    }

    /// Lets an agent the person refused ask again.
    public func forgetRefusal(_ client: String) { refused.remove(client) }

    /// The name an agent gives, made safe to show in a prompt and to save: control, format
    /// and bidirectional characters are removed, runs of spaces become one, and the result
    /// must be 1 to 80 characters. Nil when nothing is left.
    public nonisolated static func clientName(_ raw: String) -> String? {
        let kept = raw.unicodeScalars.map { scalar -> Character in
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .privateUse, .surrogate, .unassigned: " "
            default: scalar.properties.isWhitespace ? " " : Character(scalar)
            }
        }
        let name = String(kept).split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        guard !name.isEmpty, name.count <= 80 else { return nil }
        return name
    }
}

/// One newline-delimited JSON request per line on the local socket:
/// `{"id":1,"client":"Claude Code","method":"tools/list"}` or
/// `{"id":2,"client":"Claude Code","method":"tools/call","name":"msgblast_status","arguments":{}}`.
public enum AgentControlWire {
    /// `isLive` turns false once the session the request came on is closed, for example when Outside
    /// agents is switched off while an approval prompt is open. Nothing runs after that.
    /// A request with a `sessionKey` from `sessionKeys` is the built-in msgblast agent: Full access to AI agents only,
    /// never asked about. Without `sessionKeys` (the Tailscale path) every key is refused. While `outsideAgents` is
    /// false only keyed requests run. No other caller may use the agent's name.
    @MainActor public static func respond(to line: Data, host: AgentControlHost, gate: AgentControlGate, approve: @escaping AgentControlGate.Approve,
                                          sessionKeys: AgentSessionKeys? = nil, outsideAgents: Bool = true,
                                          isLive: @MainActor () -> Bool = { true }) async -> Data {
        guard let request = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            return reply(nil, error: "invalidRequest", "Each line must be one JSON object.")
        }
        let id = request["id"]
        let caller: Caller
        switch await Self.caller(request, gate: gate, approve: approve, sessionKeys: sessionKeys, outsideAgents: outsideAgents) {
        case .success(let found): caller = found
        case .failure(let refusal): return reply(id, error: refusal.code, refusal.message)
        }
        let (client, access) = (caller.client, caller.access)
        guard isLive(), caller.isLive() else { return reply(id, error: "unavailable", "msgblast closed this session, because Outside agents was switched off or its key changed. Nothing was run.") }
        let agentsOnly = client == MsgblastAgent.clientName
        switch request["method"] as? String {
        case "tools/list": return reply(id, result: ["tools": toolList(access)])
        case "tools/call": return await call(request, id: id, access: access, host: host, client: client, agentsOnly: agentsOnly)
        default: return reply(id, error: "invalidRequest", "Unknown method. Use tools/list or tools/call.")
        }
    }

    private struct Caller {
        let client: String, access: AgentControlAccess, isLive: @MainActor () -> Bool
    }
    private struct Refusal: Error { let code, message: String }

    /// Who is asking: the msgblast agent by its live key, or an outside agent the person approved.
    @MainActor private static func caller(_ request: [String: Any], gate: AgentControlGate, approve: @escaping AgentControlGate.Approve,
                                          sessionKeys: AgentSessionKeys?, outsideAgents: Bool) async -> Result<Caller, Refusal> {
        if let key = request["sessionKey"] {
            guard let key = key as? String, let sessionKeys, sessionKeys.isLive(key) else {
                return .failure(Refusal(code: "notApproved", message: "This msgblast agent session has ended. Nothing was run."))
            }
            return .success(Caller(client: MsgblastAgent.clientName, access: .full, isLive: { sessionKeys.isLive(key) }))
        }
        guard let name = (request["client"] as? String).flatMap(AgentControlGate.clientName) else {
            return .failure(Refusal(code: "invalidRequest", message: "Name the agent in \"client\", in 80 characters or fewer."))
        }
        guard !isReserved(name) else {
            return .failure(Refusal(code: "notApproved", message: "\(MsgblastAgent.clientName) is the name of msgblast’s own agent. Use another name."))
        }
        guard outsideAgents else { return .failure(Refusal(code: "unavailable", message: AgentControlCLI.unavailable)) }
        guard let level = await gate.access(for: name, approve: approve) else {
            return .failure(Refusal(code: "notApproved", message: notApproved(name, gate: gate)))
        }
        return .success(Caller(client: name, access: level, isLive: { true }))
    }

    /// Whether the line carries a session key, so the socket can tell the built-in agent's requests from others'.
    public static func hasSessionKey(_ line: Data) -> Bool {
        ((try? JSONSerialization.jsonObject(with: line)) as? [String: Any])?["sessionKey"] != nil
    }

    /// The built-in agent's name, compared ignoring case and spacing.
    static func isReserved(_ client: String) -> Bool {
        let squeezed = { (name: String) in name.lowercased().filter { !$0.isWhitespace } }
        return squeezed(client) == squeezed(MsgblastAgent.clientName)
    }

    @MainActor private static func notApproved(_ client: String, gate: AgentControlGate) -> String {
        gate.refused.contains(client)
            ? "The person chose Don’t Allow for \(client) in msgblast. It won’t ask again until msgblast restarts or the refusal is cleared in Settings → Outside agents."
            : "msgblast has not approved \(client). Approve it in msgblast → Settings → Outside agents."
    }

    @MainActor private static func toolList(_ access: AgentControlAccess) -> [[String: Any]] {
        AgentControl.tools.map { tool -> [String: Any] in
            ["name": tool.name, "title": tool.title, "description": tool.summary, "access": tool.access.label,
             "allowed": access >= tool.access,
             "inputSchema": (try? JSONSerialization.jsonObject(with: Data(tool.inputSchema.utf8))) ?? [:]]
        }
    }

    @MainActor private static func call(_ request: [String: Any], id: Any?, access: AgentControlAccess, host: AgentControlHost,
                                         client: String, agentsOnly: Bool) async -> Data {
        guard let name = request["name"] as? String else { return reply(id, error: "invalidRequest", "tools/call needs \"name\".") }
        guard let arguments = encoded(request["arguments"]) else {
            return reply(id, error: "invalidArguments", "arguments must be a JSON object.")
        }
        do {
            let data = try await AgentControl.call(name, arguments: arguments, access: access, host: host, client: client, agentsOnly: agentsOnly)
            return reply(id, result: try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed))
        } catch let error as AgentControlError {
            return reply(id, error: code(error), error.localizedDescription)
        } catch {
            // Other errors can carry paths or app details; the agent gets a fixed line.
            return reply(id, error: "failed", "msgblast could not run \(name).")
        }
    }

    /// Missing or null arguments are empty. Anything but an object is refused here, because
    /// JSONSerialization raises an uncatchable exception for a bare string or number.
    private static func encoded(_ arguments: Any?) -> Data? {
        switch arguments {
        case nil, is NSNull: Data()
        case let object as [String: Any]: try? JSONSerialization.data(withJSONObject: object)
        default: nil
        }
    }

    private static func code(_ error: Error) -> String {
        switch error as? AgentControlError {
        case .unknownTool: "unknownTool"
        case .needsAccess: "needsAccess"
        case .invalidArguments: "invalidArguments"
        case .notFound: "notFound"
        case .refused: "refused"
        case nil: "failed"
        }
    }

    private static func reply(_ id: Any?, result: Any? = nil, error code: String? = nil, _ message: String = "") -> Data {
        var body: [String: Any] = ["id": id ?? NSNull()]
        if let code { body["error"] = ["code": code, "message": message] } else { body["result"] = result ?? NSNull() }
        var data = (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data(#"{"error":{"code":"failed"}}"#.utf8)
        data.append(0x0A)
        return data
    }
}
