import AppKit
import SwiftUI
import msgblastCore

/// The built-in msgblast agent above the agents workspace: one line when idle, recent turns when expanded.
struct MsgblastAgentBar: View {
    @ObservedObject var model: AppModel
    @ObservedObject var agent: MsgblastAgentController
    @ObservedObject var accounts: PersonalAgentController
    @ObservedObject var activity: AgentControlActivity
    @ObservedObject var chatGPT: ChatGPTConnection
    /// About a third of the window, so the grid stays visible.
    let maxHeight: CGFloat
    @AppStorage("MsgblastAgentBarExpanded") private var expanded = false
    @Environment(\.openSettings) private var openSettings
    @State private var draft = ""
    private static let tint = Color.purple

    var body: some View {
        VStack(spacing: 0) {
            inputRow
            if expanded && !agent.conversation.messages.isEmpty { turns }
        }
        .background(Self.tint.opacity(0.06)).background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .task { await accounts.discover(); await accounts.refreshAccounts(); await chatGPT.load() }
    }

    private var inputRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles").foregroundStyle(Self.tint).accessibilityHidden(true)
            if agent.isWorking {
                ProgressView().controlSize(.small)
                Text(statusLine).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button("Stop") { Task { await agent.stop() } }
            } else {
                TextField("Ask msgblast agent…", text: $draft)
                    .textFieldStyle(.plain)
                    .onSubmit(send)
                    .disabled(agent.loadError != nil || agent.conversation.account == nil)
                    .accessibilityLabel("Ask msgblast agent")
                if case .failed(let message) = agent.status {
                    Text(message).foregroundStyle(.red).lineLimit(1).truncationMode(.tail).help(message)
                }
                accountMenu
            }
            Button { withAnimation(.snappy) { expanded.toggle() } } label: {
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(expanded ? "Collapse msgblast agent" : "Expand msgblast agent")
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .help(agent.loadError ?? "")
    }

    private var turns: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(agent.conversation.messages.suffix(40)) { message in
                        LinkedText(message: message, open: open)
                            .id(message.id)
                    }
                }.padding(.horizontal, 18).padding(.bottom, 12)
            }
            .frame(maxHeight: max(80, maxHeight - 48))
            .fixedSize(horizontal: false, vertical: true)
            .onAppear { proxy.scrollTo(agent.conversation.messages.last?.id, anchor: .bottom) }
            .onChange(of: agent.conversation.messages) { _, messages in proxy.scrollTo(messages.last?.id, anchor: .bottom) }
        }
    }

    private var accountMenu: some View {
        Menu {
            accountSection(.claude, provider: .claude, name: "Claude Code")
            accountSection(.codexLogin, provider: .codex, name: "ChatGPT · Codex")
            chatGPTSection
        } label: {
            Text(accountName(agent.conversation.account) ?? "Choose account")
        }
        .menuStyle(.borderlessButton).fixedSize()
        .foregroundStyle(agent.conversation.account == nil ? Self.tint : .secondary)
        .accessibilityLabel("msgblast agent account")
    }

    @ViewBuilder
    private func accountSection(_ account: MsgblastAgentAccount, provider: PersonalAgentProvider, name: String) -> some View {
        let installed = accounts.installed.contains { $0.provider == provider }
        let status = accounts.accounts[provider]
        let connected = [.subscription, .apiKey, .other].contains(status ?? .unknown)
        Section(name) {
            if !installed {
                Link("Install \(provider.name)…", destination: URL(string: provider == .codex
                     ? "https://developers.openai.com/codex/cli" : "https://code.claude.com/docs/en/setup")!)
            } else if connected {
                Toggle("Use \(name)", isOn: Binding(get: { agent.conversation.account == account }, set: { if $0 { Task { await agent.choose(account) } } }))
                Text(status?.label ?? "")
            } else {
                Button("Sign in to \(provider.name)…") { accounts.signIn(provider) }.disabled(accounts.demo)
                Text(status?.label ?? "Checking sign-in…")
            }
        }
    }

    /// Connect with ChatGPT: the plan connected in Settings, run through Codex without `codex login`.
    @ViewBuilder
    private var chatGPTSection: some View {
        Section("ChatGPT plan") {
            if let status = chatGPT.status, status.sharesPlan {
                Toggle("Use ChatGPT plan", isOn: Binding(get: { agent.conversation.account == .chatGPT }, set: { if $0 { Task { await agent.choose(.chatGPT) } } }))
                Text(status.email.map { "Connected as \($0)" } ?? "Connected")
            } else {
                Button("Connect with ChatGPT…") {
                    model.settingsPageRequest = "CLI tools"
                    NSApp.activate()
                    openSettings()
                }
            }
        }
    }

    private func accountName(_ account: MsgblastAgentAccount?) -> String? {
        switch account {
        case .claude: "Claude Code"
        case .codexLogin: "ChatGPT · Codex"
        case .chatGPT: "ChatGPT plan"
        case nil: nil
        }
    }

    private var statusLine: String {
        guard case .working(let tool) = agent.status else { return "" }
        let own = activity.log.entries.first { $0.client == MsgblastAgent.clientName }
        switch tool {
        case "msgblast_agents_list": return "Looking at your agents…"
        case "msgblast_blast_start", "msgblast_blast_follow_up", "msgblast_agent_message": return "Sending…"
        case "msgblast_blast_wait":
            guard let count = own?.agentCount else { return "Waiting for replies…" }
            return "Sent to \(count == 1 ? "1 agent" : "\(count) agents") · waiting for replies…"
        case "msgblast_comparison_read": return "Reading replies…"
        default: return "Thinking…"
        }
    }

    private func send() {
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let sent = agent.conversation.messages.count
        agent.send(draft)
        // Keep the draft when the message could not be saved.
        guard agent.conversation.messages.count > sent else { return }
        draft = ""
        withAnimation(.snappy) { expanded = true }
    }

    /// Opens a comparison link in the grid and scrolls to its `agent`; https opens in the browser; anything else is ignored.
    private func open(_ url: URL) {
        guard url.scheme == "msgblast" else { if url.scheme == "https" { NSWorkspace.shared.open(url) }; return }
        guard url.host == "comparison", let id = UUID(uuidString: url.lastPathComponent), model.comparison(id) != nil else { return }
        model.keepsWindowFrame = id
        model.coordinator?.open(id)
        let agentID = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "agent" }?.value
        if let pane = model.webAgents.sessions.first(where: { $0.id.gridID.id == agentID }) {
            model.paneFocus = PaneFocus(comparisonID: id, paneID: pane.id.id)
        }
    }

}

/// Message text whose links come to `open` instead of the system, so msgblast links never leave the app.
private struct LinkedText: NSViewRepresentable {
    let message: MsgblastAgentMessage
    let open: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSTextView {
        let view = NSTextView()
        view.isEditable = false
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.delegate = context.coordinator
        return view
    }
    func updateNSView(_ view: NSTextView, context: Context) {
        context.coordinator.open = open
        let styled: NSAttributedString
        if message.note == true {
            styled = NSAttributedString(string: message.text, attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                                                                            .foregroundColor: NSColor.tertiaryLabelColor])
        } else if message.role == .person {
            styled = MsgblastAgentText.render(message.text, color: .secondaryLabelColor, weight: .semibold)
        } else {
            styled = MsgblastAgentText.render(message.text)
        }
        guard view.textStorage?.isEqual(to: styled) != true else { return }
        view.textStorage?.setAttributedString(styled)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: NSTextView, context: Context) -> CGSize? {
        guard let container = view.textContainer, let layout = view.layoutManager else { return nil }
        let width = proposal.width ?? 400
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        return CGSize(width: width, height: ceil(layout.usedRect(for: container).height))
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var open: (URL) -> Void = { _ in }
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            if let url = link as? URL { open(url) }
            return true
        }
    }
}

/// A request to scroll the grid to one agent's pane in a comparison.
struct PaneFocus: Equatable {
    let comparisonID: UUID
    let paneID: String
    let request = UUID()
}

