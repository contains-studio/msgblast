import SwiftUI
import msgblastMobileKit
import msgblastRemoteProtocol

/// The Mac's msgblast agent: its conversation, what it is doing with Stop, and a composer.
/// It runs on the Mac with the account chosen there; this screen only asks and shows.
struct AgentView: View {
    @ObservedObject var app: MobileApp
    @State private var text = ""
    @State private var focused = false
    @State private var asking = false
    /// The Mac's answer to the last ask or Stop, when it refused or never answered.
    @State private var notice: String?
    @State private var opened: AgentLinkTarget?
    @Environment(\.dynamicTypeSize) private var typeSize

    private var chat: RemoteAgentChat? { app.store.agentChat }
    private var working: Bool { chat?.state == .working }
    private var setUp: Bool { chat?.account != nil }
    private var canAsk: Bool {
        setUp && !working && !asking && app.connection.state.canSend && !app.store.projection.macLocked
            && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Space.runGap) {
                    ForEach(chat?.messages ?? []) { message in bubble(message).id(message.id) }
                }
                .padding(.horizontal, Space.screen).padding(.vertical, Space.inset)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: chat?.messages.last) { _, last in withAnimation(.snappy) { proxy.scrollTo(last?.id, anchor: .bottom) } }
        }
        .overlay {
            if chat?.messages.isEmpty != false {
                ContentUnavailableView {
                    Label("msgblast agent", systemImage: "sparkles")
                } description: {
                    Text(setUp ? "Asks your agents and sums up their replies" : "Set up the msgblast agent on your Mac")
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
        .navigationTitle("msgblast agent")
        .navigationBarTitleDisplayMode(.inline)
        .modifier(AgentSubtitle(app: app, account: chat?.account))
        .navigationDestination(item: $opened) { ConversationView(app: app, conversationID: $0.id, focusAgent: $0.agentID) }
        .environment(\.openURL, OpenURLAction { url in
            if let link = AgentChat.comparison(url) {
                if app.store.projection.conversations[link.id] != nil { opened = AgentLinkTarget(id: link.id, agentID: link.agentID) }
                return .handled
            }
            return url.scheme == "https" ? .systemAction : .discarded
        })
        .onAppear { text = app.store.draft(MobileStore.agentDraftKey) }
        .onChange(of: text) { _, value in app.store.setDraft(value, for: MobileStore.agentDraftKey) }
    }

    /// What you asked in Messages' blue on the right; the agent's reply as plain text across the screen.
    @ViewBuilder private func bubble(_ message: RemoteAgentMessage) -> some View {
        let markdown = (try? AttributedString(markdown: message.text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(message.text)
        if message.fromPerson {
            Text(markdown)
                .foregroundStyle(.white)
                .padding(.horizontal, Space.bubbleH).padding(.vertical, Space.bubbleV)
                .background(Color("Bubble"), in: RoundedRectangle(cornerRadius: Space.cornerBubble, style: .continuous))
                .containerRelativeFrame(.horizontal, alignment: .trailing) { width, _ in width * Space.bubbleMax }
                .frame(maxWidth: .infinity, alignment: .trailing)
        } else {
            Text(markdown)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var bottomBar: some View {
        VStack(alignment: .leading, spacing: Space.gap) {
            if let line = statusLine {
                // At accessibility sizes Stop goes under the line rather than squeezing it to a word per row.
                let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: Space.gap)) : AnyLayout(HStackLayout(spacing: Space.gap))
                layout {
                    HStack(spacing: Space.gap) {
                        if working { ProgressView().controlSize(.small) }
                        Text(line.text).font(.footnote).foregroundStyle(line.failed ? Color.red : Color.secondary)
                        if let detail = line.detail { DetailButton(detail: detail) }
                    }
                    if !typeSize.isAccessibilitySize { Spacer(minLength: 0) }
                    if working { Button("Stop", action: stop).buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.small) }
                }
                .padding(.horizontal, Space.screen - Space.barEdge)
            }
            HStack(alignment: .bottom, spacing: Space.gap) {
                MessageField(text: $text, placeholder: "Ask msgblast agent…", focused: $focused)
                    .frame(minHeight: Space.fieldHeight)
                    .background(RoundedRectangle(cornerRadius: Space.fieldHeight / 2, style: .continuous).fill(Color(.secondarySystemBackground)))
                    .disabled(!setUp)
                Button(action: ask) {
                    Image(systemName: "arrow.up").font(.system(size: Space.glyph * 0.85, weight: .semibold))
                        .foregroundStyle(canAsk ? Color.white : Color.secondary)
                        .frame(width: Space.fieldHeight, height: Space.fieldHeight)
                        .background(Circle().fill(canAsk ? AnyShapeStyle(.tint) : AnyShapeStyle(Color(.tertiarySystemFill))))
                }
                .buttonStyle(.plain)
                .disabled(!canAsk)
                .accessibilityLabel("Ask")
            }
        }
        .padding(.horizontal, Space.barEdge).padding(.vertical, Space.barV)
        .background(.bar)
    }

    /// At most one line: the agent's step or failure, else what the Mac said about the last ask.
    private var statusLine: (text: String, detail: String?, failed: Bool)? {
        if !setUp && chat?.messages.isEmpty == false { return ("Set up the msgblast agent on your Mac", nil, false) }
        if working { return (chat?.line ?? "Working…", nil, false) }
        if let notice { return (notice, nil, true) }
        if chat?.state == .failed, let line = chat?.line { return (line, chat?.detail, true) }
        return nil
    }

    private func ask() {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canAsk else { return }
        asking = true
        notice = nil
        Task {
            notice = await app.askAgent(question)
            if notice == nil { text = "" }
            asking = false
        }
    }

    private func stop() {
        Task { notice = await app.stopAgent() }
    }
}

/// A comparison a summary link names, and the agent to show in it.
struct AgentLinkTarget: Hashable {
    let id: UUID
    let agentID: String?
}

/// The connection's subtitle while there is one to show, else the account the Mac thinks with.
private struct AgentSubtitle: ViewModifier {
    @ObservedObject var app: MobileApp
    var account: String?
    func body(content: Content) -> some View {
        let state = app.store.projection.macLocked && app.connection.state.canSend ? MacConnectionState.macLocked : app.connection.state
        let connection = state.navigationSubtitle(lastHeard: app.connection.lastHeard, reconnectingSince: app.connection.reconnectingSince, now: Date())
        content.navigationSubtitle(connection ?? account.map { "\($0) on your Mac" } ?? "")
    }
}
