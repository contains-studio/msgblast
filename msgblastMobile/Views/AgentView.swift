import SwiftUI
import msgblastMobileKit
import msgblastRemoteProtocol

/// The Mac's msgblast agent as a Messages conversation: your messages in blue on the right,
/// its answers in grey on the left, steps as small centred lines, and comparisons as cards.
/// It runs on the Mac with the account chosen there; this screen only asks and shows.
struct AgentView: View {
    @ObservedObject var app: MobileApp
    @State private var text = ""
    @State private var focused = false
    @State private var asking = false
    /// The Mac's answer to the last ask or Stop, when it refused or never answered.
    @State private var notice: String?
    @State private var opened: AgentLinkTarget?
    @State private var width: CGFloat = 390
    private static let bottomID = "agent-bottom"

    private var chat: RemoteAgentChat? { app.store.agentChat }
    private var messages: [RemoteAgentMessage] { chat?.messages ?? [] }
    private var working: Bool { chat?.state == .working }
    private var setUp: Bool { chat?.account != nil }
    private var connected: Bool { app.connection.state.canSend && !app.store.projection.macLocked }
    private var canAsk: Bool { setUp && !working && !asking && connected && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(messages.indices, id: \.self) { index in row(index).id(messages[index].id) }
                    statusRows
                    Color.clear.frame(height: 1).id(Self.bottomID)
                }
                .padding(.horizontal, Space.screen).padding(.vertical, Space.inset)
            }
            .defaultScrollAnchor(.bottom)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .onChange(of: messages.last) { _, _ in withAnimation(.snappy) { proxy.scrollTo(Self.bottomID, anchor: .bottom) } }
            .onChange(of: working) { _, _ in withAnimation(.snappy) { proxy.scrollTo(Self.bottomID, anchor: .bottom) } }
        }
        .overlay {
            if messages.isEmpty && !working {
                ContentUnavailableView {
                    Label("msgblast agent", systemImage: "sparkles")
                } description: {
                    Text(setUp ? "Asks your agents and sums up their replies" : "Set up the msgblast agent on your Mac")
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { composer }
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

    // MARK: Rows

    /// One message: its time header when one is due, then a bubble or a centred note.
    @ViewBuilder private func row(_ index: Int) -> some View {
        let message = messages[index]
        let previous = index == 0 ? nil : messages[index - 1]
        let next = index + 1 < messages.count ? messages[index + 1] : nil
        let header = message.created.flatMap { ProjectionPresenter.timeHeader($0, previous: previous?.created) }
        let nextHeader = next?.created.flatMap { ProjectionPresenter.timeHeader($0, previous: message.created) }
        if let header { CentredLine(text: header, weight: .semibold).padding(.top, index == 0 ? 0 : Space.separator).padding(.bottom, Space.separator) }
        if message.note == true {
            CentredLine(text: message.text).padding(.vertical, Space.gap)
        } else {
            let continues = header == nil && previous.map { Self.sameSide($0, message) } == true
            let endsRun = nextHeader != nil || next.map { Self.sameSide(message, $0) } != true
            bubble(message, tail: endsRun)
                .padding(.top, header != nil || previous == nil ? 0 : continues ? Space.run : Space.runGap)
        }
    }

    private static func sameSide(_ a: RemoteAgentMessage, _ b: RemoteAgentMessage) -> Bool {
        a.note != true && b.note != true && a.fromPerson == b.fromPerson
    }

    @ViewBuilder private func bubble(_ message: RemoteAgentMessage, tail: Bool) -> some View {
        let mine = message.fromPerson
        MaxWidth(width: width * Space.bubbleMax) {
            Group {
                if mine { Text(Self.inline(message.text)).tint(.white) } else { reply(message.text) }
            }
            .font(.body)
            .textSelection(.enabled)
            .padding(.horizontal, Space.bubbleH).padding(.vertical, Space.bubbleV)
            .background(BubbleShape(mine: mine, tail: tail).fill(mine ? Color("Bubble") : Color(.secondarySystemBackground)))
            .foregroundStyle(mine ? .white : .primary)
            .contextMenu { Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = message.text } }
        }
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
    }

    /// The agent's answer: paragraphs, headings and lists, then a card for each comparison it linked.
    private func reply(_ text: String) -> some View {
        let reply = AgentChat.reply(text) { app.store.projection.agents[$0]?.displayName }
        return VStack(alignment: .leading, spacing: Space.gap) {
            ForEach(reply.blocks.indices, id: \.self) { index in
                switch reply.blocks[index] {
                case .paragraph(let text): Text(Self.inline(text))
                case .heading(let text): Text(Self.inline(text)).font(.headline)
                case .item(let text, let marker, let level):
                    HStack(alignment: .firstTextBaseline, spacing: Space.tight + Space.hairline) {
                        Text(marker).foregroundStyle(.secondary)
                        Text(Self.inline(text))
                    }
                    .padding(.leading, CGFloat(level) * Space.screen)
                }
            }
            ForEach(reply.comparisons, id: \.self) { id in ComparisonCard(app: app, id: id) { opened = AgentLinkTarget(id: id, agentID: nil) } }
        }
    }

    private static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }

    /// While working: the step as a centred line and the typing bubble. Otherwise what went wrong, if anything.
    @ViewBuilder private var statusRows: some View {
        if working {
            if let line = chat?.line { CentredLine(text: line).padding(.top, Space.separator) }
            TypingBubble(app: app, agentID: "", name: "msgblast agent", showsAvatar: false).padding(.top, Space.gap)
        } else if let notice {
            CentredLine(text: notice, failed: true).padding(.top, Space.separator)
        } else if !setUp && !messages.isEmpty {
            CentredLine(text: "Set up the msgblast agent on your Mac").padding(.top, Space.separator)
        } else if chat?.state == .failed, let line = chat?.line {
            CentredLine(text: line, detail: chat?.detail, failed: true).padding(.top, Space.separator)
        }
    }

    // MARK: Composer

    /// Messages' field with a round Send that becomes Stop while the agent works.
    private var composer: some View {
        HStack(alignment: .bottom, spacing: Space.gap) {
            MessageField(text: $text, placeholder: "Message msgblast agent", focused: $focused)
                .frame(minHeight: Space.fieldHeight)
                .background(RoundedRectangle(cornerRadius: Space.fieldHeight / 2, style: .continuous).fill(Color(.secondarySystemBackground)))
                .disabled(!setUp)
            Button { if working { stop() } else { ask() } } label: { sendLabel }
            .buttonStyle(.plain)
            .disabled(!sendEnabled)
            .accessibilityLabel(working ? "Stop" : "Send")
        }
        .padding(.horizontal, Space.barEdge).padding(.vertical, Space.barV - (Space.control - Space.fieldHeight) / 2)
        .background(.bar)
    }

    /// Send asks; while the agent works the same button stops it.
    private var sendEnabled: Bool { working ? connected : canAsk }
    private var sendLabel: some View {
        let symbol = working ? "stop.fill" : "arrow.up"
        let fill: AnyShapeStyle = sendEnabled ? AnyShapeStyle(.tint) : AnyShapeStyle(Color(.tertiarySystemFill))
        return Image(systemName: symbol)
            .font(.system(size: Space.glyph * (working ? 0.7 : 0.85), weight: .semibold))
            .foregroundStyle(sendEnabled ? Color.white : Color.secondary)
            .frame(width: Space.fieldHeight, height: Space.fieldHeight)
            .background(Circle().fill(fill))
            .frame(width: Space.control, height: Space.control)
            .contentShape(Circle())
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

/// A small centred line between messages, as Messages shows times and events.
private struct CentredLine: View {
    var text: String
    var weight: UIFont.Weight = .regular
    var detail: String? = nil
    var failed = false
    var body: some View {
        HStack(spacing: Space.tight) {
            Text(text).font(.scaled(Space.threadCaption, weight: weight, relativeTo: .caption2))
                .foregroundStyle(failed ? Color.red : Color.secondary)
                .multilineTextAlignment(.center)
            if let detail { DetailButton(detail: detail).font(.caption) }
        }
        .frame(maxWidth: .infinity)
    }
}

/// A comparison the agent linked: its title, the agents' icons and how many replied. Opens its thread.
private struct ComparisonCard: View {
    @ObservedObject var app: MobileApp
    let id: UUID
    let open: () -> Void
    var body: some View {
        let conversation = app.store.projection.conversations[id]
        let replied = Set(app.store.projection.turns(in: id).filter { $0.role == .assistant }.compactMap(\.agentID)).count
        Button(action: open) {
            HStack(spacing: Space.gap) {
                VStack(alignment: .leading, spacing: Space.tight) {
                    Text(conversation?.title ?? "Comparison").font(.subheadline.weight(.semibold)).lineLimit(2).multilineTextAlignment(.leading)
                    HStack(spacing: Space.tight) {
                        HStack(spacing: -Space.tight) {
                            ForEach((conversation?.agentIDs ?? []).prefix(5), id: \.self) { agent in
                                AgentAvatar(app: app, agentID: agent, name: app.store.projection.agents[agent]?.displayName ?? agent, size: Space.avatarInline)
                                    .background(Circle().fill(Color(.systemBackground)).padding(-1))
                            }
                        }
                        Text(conversation == nil ? "Open on your Mac" : replied == 1 ? "1 reply" : replied == 0 ? "No replies yet" : "\(replied) replies")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(Space.inset)
            .background(RoundedRectangle(cornerRadius: Space.cornerCard, style: .continuous).fill(Color(.systemBackground)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(conversation == nil)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the comparison")
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
