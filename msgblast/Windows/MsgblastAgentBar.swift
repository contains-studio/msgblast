import AppKit
import SwiftUI
import msgblastCore

/// Where the person expanded the msgblast agent into the whole agents area.
enum MsgblastAgentLayout {
    static let expandedKey = "MsgblastAgentBarExpanded"
    static let seenReplyKey = "MsgblastAgentSeenReply"
}

/// The msgblast agent collapsed to one line above the agents. It shows what the agent is doing, and its newest
/// reply until the person opens the conversation.
struct MsgblastAgentBar: View {
    @ObservedObject var model: AppModel
    @ObservedObject var agent: MsgblastAgentController
    @ObservedObject var accounts: PersonalAgentController
    @ObservedObject var activity: AgentControlActivity
    @ObservedObject var chatGPT: ChatGPTConnection
    @AppStorage(MsgblastAgentLayout.expandedKey) private var expanded = false
    @AppStorage(MsgblastAgentLayout.seenReplyKey) private var seenReply = ""
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles").foregroundStyle(Color.accentColor).accessibilityHidden(true)
                if agent.isWorking {
                    MsgblastAgentTyping(compact: true)
                    Text(MsgblastAgentThread.status(agent: agent, activity: activity)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Button("Stop") { Task { await agent.stop() } }
                } else {
                    TextField("Message msgblast agent", text: $draft)
                        .textFieldStyle(.plain)
                        .onSubmit(send)
                        .disabled(agent.loadError != nil || agent.conversation.account == nil)
                        .accessibilityLabel("Message msgblast agent")
                    MsgblastAgentAccountMenu(model: model, agent: agent, accounts: accounts, chatGPT: chatGPT)
                }
                Button { withAnimation(.snappy) { expanded = true } } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(.borderless)
                .help("Open the msgblast agent (⌘4)")
                .accessibilityLabel("Expand msgblast agent")
            }
            if let reply = unseenReply {
                Button { withAnimation(.snappy) { expanded = true } } label: {
                    HStack(spacing: 6) {
                        Text(reply).lineLimit(1).truncationMode(.tail).foregroundStyle(.secondary)
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
                .padding(.leading, 26).padding(.top, 6)
                .accessibilityLabel("Show the msgblast agent's reply")
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .help(agent.loadError ?? "")
        .task { await accounts.discover(); await accounts.refreshAccounts(); await chatGPT.load() }
    }

    /// The newest reply, as plain text, until the person opens the conversation.
    private var unseenReply: String? {
        guard !agent.isWorking, let last = agent.conversation.messages.last(where: { $0.role == .agent && $0.note != true }),
              last.id.uuidString != seenReply else { return nil }
        let text = MsgblastAgentText.render(MsgblastAgentText.comparisonCards(in: last.text).text).string
            .replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\t", with: " ")
        return text.isEmpty ? nil : text
    }

    private func send() {
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let sent = agent.conversation.messages.count
        agent.send(draft)
        // Keep the draft when the message could not be saved.
        if agent.conversation.messages.count > sent { draft = "" }
    }
}

/// The msgblast agent filling the agents area, in place of the grid, comparison columns and shared composer.
struct MsgblastAgentPanel: View {
    @ObservedObject var model: AppModel
    @ObservedObject var agent: MsgblastAgentController
    @ObservedObject var accounts: PersonalAgentController
    @ObservedObject var activity: AgentControlActivity
    @ObservedObject var chatGPT: ChatGPTConnection
    @AppStorage(MsgblastAgentLayout.expandedKey) private var expanded = false
    @AppStorage(MsgblastAgentLayout.seenReplyKey) private var seenReply = ""
    @State private var draft = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").foregroundStyle(Color.accentColor).accessibilityHidden(true)
                Text("msgblast agent").font(.headline)
                Spacer()
                MsgblastAgentAccountMenu(model: model, agent: agent, accounts: accounts, chatGPT: chatGPT)
                Button { withAnimation(.snappy) { expanded = false } } label: {
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                }
                .buttonStyle(.borderless)
                .help("Back to the agents (⌘4)")
                .accessibilityLabel("Collapse msgblast agent")
            }
            .padding(.horizontal, 18).padding(.vertical, 10)
            .background(.bar)
            Divider()
            if agent.conversation.messages.isEmpty && !agent.isWorking {
                VStack(spacing: 6) {
                    Image(systemName: "sparkles").font(.system(size: 28)).foregroundStyle(Color.accentColor)
                    Text("Ask your agents anything").font(.headline)
                    Text("msgblast agent sends it to your agents and sums up their replies.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                MsgblastAgentThread(model: model, agent: agent, activity: activity) { model.openAgentLink($0) }
                    .frame(maxWidth: 820).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            MsgblastAgentComposer(agent: agent, draft: $draft, send: send)
                .frame(maxWidth: 820).frame(maxWidth: .infinity)
                .background(.bar)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear(perform: markSeen)
        .onChange(of: agent.conversation.messages) { _, _ in markSeen() }
        .task { await accounts.discover(); await accounts.refreshAccounts(); await chatGPT.load() }
    }

    private func markSeen() {
        if let last = agent.conversation.messages.last(where: { $0.role == .agent && $0.note != true }) { seenReply = last.id.uuidString }
    }

    private func send() {
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let sent = agent.conversation.messages.count
        agent.send(draft)
        // Keep the draft when the message could not be saved.
        if agent.conversation.messages.count > sent { draft = "" }
    }
}

extension AppModel {
    /// Opens a comparison link in the grid and scrolls to its `agent`, collapsing the msgblast agent so the
    /// comparison shows. https opens in the browser; anything else is ignored.
    func openAgentLink(_ url: URL) {
        guard url.scheme == "msgblast" else { if url.scheme == "https" { NSWorkspace.shared.open(url) }; return }
        guard url.host == "comparison", let id = UUID(uuidString: url.lastPathComponent), comparison(id) != nil else { return }
        UserDefaults.standard.set(false, forKey: MsgblastAgentLayout.expandedKey)
        keepsWindowFrame = id
        coordinator?.open(id)
        let agentID = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "agent" }?.value
        if let pane = webAgents.sessions.first(where: { $0.id.gridID.id == agentID }) {
            paneFocus = PaneFocus(comparisonID: id, paneID: pane.id.id)
        }
    }
}

/// The conversation as Messages shows it: the person's bubbles on the right in the accent colour, the agent's
/// on the left in grey, grouped by side, with centred times between groups and centred notes for steps.
struct MsgblastAgentThread: View {
    @ObservedObject var model: AppModel
    @ObservedObject var agent: MsgblastAgentController
    @ObservedObject var activity: AgentControlActivity
    let open: (URL) -> Void
    private static let bottom = "msgblast-agent-bottom"
    @State private var width: CGFloat = 600
    /// Messages keeps bubbles to about 70% of the conversation, and never very wide.
    private var bubbleWidth: CGFloat { min(560, max(240, (width - 32) * 0.7)) }

    var body: some View {
        let messages = Array(agent.conversation.messages.suffix(60))
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                        let previous = index > 0 ? messages[index - 1] : nil
                        if let time = Self.time(before: message, previous: previous) {
                            Text(time).font(.caption2).foregroundStyle(.secondary).padding(.top, 12).padding(.bottom, 4)
                        }
                        row(message)
                            .padding(.top, previous.map { $0.role == message.role && $0.note != true && message.note != true } == true ? 2 : 8)
                    }
                    if agent.isWorking {
                        HStack {
                            MsgblastAgentTyping(compact: false)
                            Text(Self.status(agent: agent, activity: activity)).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                        }.padding(.top, 8)
                    }
                    if case .failed(let message) = agent.status {
                        Text(message).font(.caption).foregroundStyle(.red).multilineTextAlignment(.center).padding(.top, 8)
                    }
                    Color.clear.frame(height: 1).id(Self.bottom)
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .onAppear { proxy.scrollTo(Self.bottom, anchor: .bottom) }
            .onChange(of: agent.conversation.messages) { _, _ in withAnimation { proxy.scrollTo(Self.bottom, anchor: .bottom) } }
            .onChange(of: agent.isWorking) { _, _ in withAnimation { proxy.scrollTo(Self.bottom, anchor: .bottom) } }
        }
    }

    @ViewBuilder
    private func row(_ message: MsgblastAgentMessage) -> some View {
        if message.note == true {
            Text(message.text).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
        } else if message.role == .person {
            HStack {
                Spacer(minLength: 0)
                AgentMessageText(text: message.text, person: true, open: open)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                    .frame(maxWidth: bubbleWidth, alignment: .trailing)
            }
        } else {
            let parts = MsgblastAgentText.comparisonCards(in: message.text)
            HStack {
                VStack(alignment: .leading, spacing: 8) {
                    if !parts.text.isEmpty { AgentMessageText(text: parts.text, person: false, open: open) }
                    ForEach(parts.comparisons, id: \.self) { id in
                        if let comparison = model.comparison(id) {
                            ComparisonCard(model: model, comparison: comparison) {
                                open(URL(string: "msgblast://comparison/\(id.uuidString)")!)
                            }
                        }
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(Self.agentBubble, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                .frame(maxWidth: bubbleWidth, alignment: .leading)
                Spacer(minLength: 0)
            }
        }
    }

    /// Messages' grey bubble, lighter in light mode and darker in dark mode.
    static let agentBubble = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 0.17, alpha: 1) : NSColor(white: 0.91, alpha: 1)
    })

    /// A time above a message that starts the conversation or comes 15 minutes after the one before.
    static func time(before message: MsgblastAgentMessage, previous: MsgblastAgentMessage?) -> String? {
        guard let date = message.created else { return nil }
        if let earlier = previous?.created, date.timeIntervalSince(earlier) < 15 * 60 { return nil }
        let time = date.formatted(date: .omitted, time: .shortened)
        if Calendar.current.isDateInToday(date) { return "Today \(time)" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday \(time)" }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
    }

    /// What the agent is doing, for the typing line.
    static func status(agent: MsgblastAgentController, activity: AgentControlActivity) -> String {
        guard case .working(let tool) = agent.status else { return "" }
        let own = activity.log.entries.first { $0.client == MsgblastAgent.clientName }
        switch tool {
        case "msgblast_agents_list": return "Looking at your agents…"
        case "msgblast_blast_start", "msgblast_blast_follow_up", "msgblast_agent_message": return "Sending…"
        case "msgblast_blast_wait":
            guard let count = own?.agentCount else { return "Waiting for replies…" }
            return "Waiting for \(count == 1 ? "1 reply" : "\(count) replies")…"
        case "msgblast_comparison_read": return "Reading replies…"
        default: return "Thinking…"
        }
    }
}

/// A comparison the agent linked: its title, its agents' icons, and how many replies it has. Tapping opens it.
private struct ComparisonCard: View {
    @ObservedObject var model: AppModel
    let comparison: Comparison
    let open: () -> Void

    var body: some View {
        let sessions = comparison.resolvedWebAgentIDs.compactMap { id in model.webAgents.sessions.first { $0.id == id } }
        let replies = model.controlTranscript(comparison).filter { !$0.outgoing }.count
        Button(action: open) {
            HStack(spacing: 10) {
                HStack(spacing: -6) {
                    ForEach(sessions.prefix(4), id: \.id) { session in
                        AgentAvatar(agent: AgentArtwork.agent(for: session), name: session.name, size: 22)
                            .overlay(Circle().stroke(Color(nsColor: .textBackgroundColor), lineWidth: 1.5))
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    // The full prompt, not the 65-character title, so two lines end in an ellipsis rather than mid-word.
                    Text(comparison.customTitle ?? (comparison.prompt.isEmpty ? comparison.title : comparison.prompt))
                        .font(.callout.weight(.semibold)).lineLimit(2).truncationMode(.tail).multilineTextAlignment(.leading)
                    Text(replies == 1 ? "1 reply" : "\(replies) replies").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(10)
            .frame(minWidth: 220, maxWidth: 360, alignment: .leading)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open comparison \(comparison.title), \(replies) replies")
    }
}

/// Messages' typing bubble: three dots that pulse in turn.
struct MsgblastAgentTyping: View {
    let compact: Bool
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.2)) { context in
            let step = Int(context.date.timeIntervalSinceReferenceDate / 0.3) % 3
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { index in
                    Circle().fill(Color.secondary).frame(width: 7, height: 7).opacity(index == step ? 0.9 : 0.35)
                }
            }
            .padding(.horizontal, compact ? 0 : 12).padding(.vertical, compact ? 0 : 10)
            .background(compact ? Color.clear : MsgblastAgentThread.agentBubble, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        }
        .accessibilityLabel("msgblast agent is typing")
    }
}

/// Messages' composer: a rounded field and a round send arrow that becomes Stop while the agent works.
struct MsgblastAgentComposer: View {
    @ObservedObject var agent: MsgblastAgentController
    @Binding var draft: String
    let send: () -> Void

    var body: some View {
        let empty = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        HStack(spacing: 8) {
            TextField("Message msgblast agent", text: $draft)
                .textFieldStyle(.plain)
                .onSubmit { if !agent.isWorking { send() } }
                .padding(.horizontal, 12).padding(.vertical, 7)
                .overlay(RoundedRectangle(cornerRadius: 17, style: .continuous).stroke(Color.secondary.opacity(0.35)))
                .disabled(agent.loadError != nil || agent.conversation.account == nil)
                .accessibilityLabel("Message msgblast agent")
            Button {
                if agent.isWorking { Task { await agent.stop() } } else { send() }
            } label: {
                Image(systemName: agent.isWorking ? "stop.circle.fill" : "arrow.up.circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(agent.isWorking || !empty ? Color.accentColor : Color.secondary.opacity(0.5))
            }
            .buttonStyle(.plain)
            .disabled(!agent.isWorking && (empty || agent.conversation.account == nil))
            .accessibilityLabel(agent.isWorking ? "Stop" : "Send")
            .help(agent.loadError ?? "")
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }
}

/// The account the agent thinks with: Claude Code, ChatGPT through `codex login`, or the ChatGPT plan.
struct MsgblastAgentAccountMenu: View {
    @ObservedObject var model: AppModel
    @ObservedObject var agent: MsgblastAgentController
    @ObservedObject var accounts: PersonalAgentController
    @ObservedObject var chatGPT: ChatGPTConnection
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Menu {
            accountSection(.claude, provider: .claude, name: "Claude Code")
            accountSection(.codexLogin, provider: .codex, name: "ChatGPT · Codex")
            chatGPTSection
        } label: {
            Text(accountName(agent.conversation.account) ?? "Choose account")
        }
        .menuStyle(.button).buttonStyle(.bordered).controlSize(.small).fixedSize()
        .tint(agent.conversation.account == nil ? Color.accentColor : nil)
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
}

/// Message text whose links come to `open` instead of the system, so msgblast links never leave the app.
/// It is as wide as its text, up to the width it is offered.
private struct AgentMessageText: NSViewRepresentable {
    let text: String
    let person: Bool
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
        view.linkTextAttributes = person ? [.foregroundColor: NSColor.white, .underlineStyle: NSUnderlineStyle.single.rawValue,
                                            .cursor: NSCursor.pointingHand]
                                         : [.foregroundColor: NSColor.linkColor, .cursor: NSCursor.pointingHand]
        let styled = MsgblastAgentText.render(text, color: person ? .white : .labelColor)
        guard view.textStorage?.isEqual(to: styled) != true else { return }
        view.textStorage?.setAttributedString(styled)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: NSTextView, context: Context) -> CGSize? {
        guard let container = view.textContainer, let layout = view.layoutManager else { return nil }
        let width = proposal.width ?? 400
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        return CGSize(width: min(width, ceil(used.width)), height: ceil(used.height))
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
