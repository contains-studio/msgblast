import AppKit
import SwiftUI
import msgblastCore

/// The Wants panel: the person's Want MCP lists and items, each item's offers and comments,
/// and the blast that asks their agents for more.
struct WantsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var wants: WantsModel
    @State private var selectedItem: String?

    var body: some View {
        Group {
            if wants.signedIn { content } else { WantsSignInView(wants: wants) }
        }
        .alert("The Want MCP", isPresented: Binding(get: { wants.error != nil }, set: { if !$0 { wants.error = nil } })) {
            Button("OK") { wants.error = nil }
        } message: { Text(wants.error ?? "") }
    }

    private var content: some View {
        HSplitView {
            WantsListColumn(wants: wants, selection: $selectedItem)
                .frame(minWidth: 240, idealWidth: 300, maxWidth: 380)
            Group {
                if let selected {
                    WantItemDetail(model: model, wants: wants, item: selected.item, list: selected.list)
                } else {
                    ContentUnavailableView("Choose a want", systemImage: "gift", description: Text("Its offers and comments appear here."))
                }
            }.frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar {
            ToolbarItemGroup {
                WantsConnectButton()
                WantsForwardMenu(wants: wants)
                Menu {
                    Button("Refresh") { Task { await wants.reload() } }
                    Divider()
                    Button("Sign Out") { wants.signOut() }
                } label: { Label("More", systemImage: "ellipsis.circle") }
            }
        }
    }

    private var selected: (item: WantItem, list: WantList)? {
        for list in wants.lists {
            if let item = list.items?.first(where: { $0.id == selectedItem }) { return (item, list) }
        }
        return nil
    }
}

private struct WantsSignInView: View {
    @ObservedObject var wants: WantsModel
    @State private var key = ""
    @State private var showingKey = false

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "gift").font(.system(size: 44)).foregroundStyle(.tint)
            Text("The Want MCP").font(.title2.bold())
            Text("Keep want lists that your agents fill with the best offers.").foregroundStyle(.secondary)
            if wants.signingIn {
                HStack { ProgressView().controlSize(.small); Text("Finish signing in in your browser.") }
                Button("Cancel") { wants.cancelSignIn() }
            } else {
                Button("Sign In…") { Task { await wants.signIn() } }.buttonStyle(.borderedProminent).controlSize(.large)
                if showingKey {
                    HStack {
                        SecureField("wk_…", text: $key).textFieldStyle(.roundedBorder).frame(width: 260)
                        Button("Add") {
                            if wants.useWriteKey(key) { key = "" } else { wants.error = "That isn't a write key. Keys start with wk_." }
                        }.disabled(key.isEmpty)
                    }
                } else {
                    Button("Use a Write Key") { showingKey = true }.buttonStyle(.link)
                }
            }
        }.padding(40).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct WantsListColumn: View {
    @ObservedObject var wants: WantsModel
    @Binding var selection: String?
    @State private var draft = ""
    @State private var listID: String?

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(wants.lists) { list in
                    Section(list.title) {
                        ForEach(list.items ?? []) { item in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.text).lineLimit(2)
                                Text(offerCount(item)).font(.caption).foregroundStyle(.secondary)
                            }.padding(.vertical, 3).tag(item.id)
                        }
                    }
                }
                if wants.lists.isEmpty { Text("No lists yet. Create one at wantmcp.com.").foregroundStyle(.secondary) }
            }.listStyle(.sidebar)
            Divider()
            HStack {
                if wants.lists.count > 1 {
                    Picker("List", selection: $listID) {
                        ForEach(wants.lists) { Text($0.title).tag(Optional($0.id)) }
                    }.labelsHidden().frame(width: 110)
                }
                TextField("Add a want", text: $draft).textFieldStyle(.roundedBorder).onSubmit(add)
                Button(action: add) { Image(systemName: "plus") }.disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || target == nil)
                    .accessibilityLabel("Add Want")
            }.padding(10)
        }
    }

    private var target: WantList? { wants.lists.first { $0.id == listID } ?? wants.lists.first }
    private func add() {
        guard let target else { return }
        let text = draft
        draft = ""
        Task { await wants.addItem(text, to: target) }
    }
    private func offerCount(_ item: WantItem) -> String {
        let count = item.entryCounts.listed
        return count == 0 ? "No offers yet" : count == 1 ? "1 offer" : "\(count) offers"
    }
}

private struct WantItemDetail: View {
    @ObservedObject var model: AppModel
    @ObservedObject var wants: WantsModel
    let item: WantItem
    let list: WantList
    @State private var picking = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.text).font(.title2.bold()).textSelection(.enabled)
                        Link(list.title, destination: URL(string: list.url(for: item))!).font(.callout)
                    }
                    Spacer()
                    Button { picking = true } label: { Label("Find Offers", systemImage: "paperplane") }
                        .buttonStyle(.borderedProminent).disabled(wants.sending || !model.canStartNewBlast)
                }
                section("Offers", empty: "No offers yet. Ask your agents to find some.", rows: item.entries ?? []) { WantEntryRow(entry: $0) }
                let pending = (wants.suggestions[list.id] ?? []).filter { $0.itemId == item.id }
                if !pending.isEmpty {
                    section("Suggested by outside agents", empty: "", rows: pending) { WantEntryRow(entry: $0) }
                    Text("Hidden from others until you or your agents promote them.").font(.caption).foregroundStyle(.secondary)
                }
                if let replies = wants.replies(for: item) { repliesSection(replies.comparison, replies.turns) }
                let comments = (wants.comments[list.id] ?? []).filter { comment in comment.targetId == item.id || (item.entries ?? []).contains { $0.id == comment.targetId } }
                section("Comments", empty: "No comments.", rows: comments) { comment in
                    VStack(alignment: .leading, spacing: 3) {
                        byline(comment.author, comment.createdAt)
                        Text(comment.body).textSelection(.enabled)
                    }
                }
            }.padding(24).frame(maxWidth: 760, alignment: .leading)
        }
        .sheet(isPresented: $picking) {
            WantsAgentPicker(title: "Find offers with", action: "Send", agents: wants.agents,
                             initial: wants.saved.blasts[item.id]?.agents ?? wants.agents.filter(\.selected).map(\.id)) { chosen in
                Task { await wants.blast(item, in: list, to: chosen) }
            }
        }
    }

    private func repliesSection(_ id: UUID, _ turns: [AgentControlTurn]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Replies").font(.headline)
                Spacer()
                Button("Open Conversation") { wants.openConversation(id) }.buttonStyle(.link)
            }
            if turns.isEmpty { Text("Waiting for replies…").foregroundStyle(.secondary) }
            ForEach(Array(turns.enumerated()), id: \.offset) { _, turn in
                VStack(alignment: .leading, spacing: 3) {
                    Text(turn.agent).font(.subheadline.bold())
                    Text(turn.text).lineLimit(8).textSelection(.enabled)
                }
            }
        }
    }

    private func section<Row: Identifiable, Content: View>(_ title: String, empty: String, rows: [Row], @ViewBuilder row: @escaping (Row) -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            if rows.isEmpty { Text(empty).foregroundStyle(.secondary) }
            ForEach(rows) { row($0) }
        }
    }
}

private struct WantEntryRow: View {
    let entry: WantEntry
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AsyncImage(url: entry.imageUrl.flatMap(URL.init(string:))) { image in
                image.resizable().scaledToFit()
            } placeholder: {
                Image(systemName: "shippingbox").font(.title2).foregroundStyle(.tertiary)
            }.frame(width: 64, height: 64).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                if entry.status == "listed", let url = URL(string: entry.productUrl) {
                    Link(entry.title, destination: url).font(.body.weight(.semibold))
                } else {
                    // Outside suggestions are untrusted: shown as plain text, never as links.
                    Text(entry.title).font(.body.weight(.semibold))
                    Text(entry.productUrl).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                HStack(spacing: 6) {
                    Text(entry.retailer).foregroundStyle(.secondary)
                    if let price = entry.currentPrice {
                        Text(price.formatted).fontWeight(.semibold)
                        if let was = price.formattedOriginal { Text(was).strikethrough().foregroundStyle(.secondary) }
                    }
                }
                byline(entry.author, entry.createdAt)
            }
            Spacer(minLength: 0)
        }
    }
}

/// Who posted something and when. The person's own agents are highlighted, as on wantmcp.com.
private func byline(_ actor: WantActor, _ date: Date) -> some View {
    HStack(spacing: 4) {
        if actor.isAgent { Image(systemName: "sparkles").foregroundStyle(.tint) }
        Text(actor.label).foregroundStyle(actor.isAgent ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        Text("·").foregroundStyle(.secondary)
        Text(date, format: .relative(presentation: .named)).foregroundStyle(.secondary)
    }.font(.caption)
}

/// Chooses which of the person's agents get a message.
private struct WantsAgentPicker: View {
    @Environment(\.dismiss) private var dismiss
    let title: String, action: String
    let agents: [AgentControlAgent]
    @State var chosen: Set<String>
    let done: ([String]) -> Void

    init(title: String, action: String, agents: [AgentControlAgent], initial: [String], done: @escaping ([String]) -> Void) {
        self.title = title; self.action = action; self.agents = agents; self.done = done
        _chosen = State(initialValue: Set(initial).intersection(agents.map(\.id)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            if agents.isEmpty { Text("Connect an agent in msgblast first.").foregroundStyle(.secondary) }
            ForEach(agents, id: \.id) { agent in
                Toggle(agent.name, isOn: Binding(get: { chosen.contains(agent.id) }, set: { on in
                    if on { chosen.insert(agent.id) } else { chosen.remove(agent.id) }
                })).disabled(agent.busy)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(action) { done(agents.map(\.id).filter(chosen.contains)); dismiss() }
                    .keyboardShortcut(.defaultAction).disabled(chosen.isEmpty)
            }
        }.padding(20).frame(width: 340)
    }
}

/// Turns forwarding of new comments and outside suggestions on or off, and picks who gets them
/// for items that have not been blasted yet.
private struct WantsForwardMenu: View {
    @ObservedObject var wants: WantsModel
    @State private var picking = false

    var body: some View {
        Toggle(isOn: Binding(get: { wants.saved.forwardActivity }, set: { on in
            if on && wants.saved.forwardAgents.isEmpty { picking = true } else { wants.setForwarding(on) }
        })) { Label("Forward Activity", systemImage: "bell.badge") }
            .help("Send new comments and outside suggestions to your agents")
            .contextMenu { Button("Choose Agents…") { picking = true } }
            .sheet(isPresented: $picking) {
                WantsAgentPicker(title: "Forward new comments and suggestions to", action: "Turn On", agents: wants.agents, initial: wants.saved.forwardAgents) {
                    wants.setForwarding(true, agents: $0)
                }
            }
    }
}

/// Each agent posts with its own connection to The Want MCP; this shows how to add it.
private struct WantsConnectButton: View {
    @State private var showing = false
    private var url: String { WantsModel.endpoint.absoluteString }

    var body: some View {
        Button { showing.toggle() } label: { Label("Connect Agents", systemImage: "link") }
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Connect your agents").font(.headline)
                    Text("Each agent needs its own connection to post offers to your list. Agents that aren't connected reply in msgblast instead.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    row("MCP server URL", url, note: nil)
                    row("Claude Code", "claude mcp add --transport http wantmcp \(url)", note: "Copies a Terminal command")
                    row("Codex", "codex mcp add wantmcp --url \(url)", note: "Copies a Terminal command")
                    Text("ChatGPT and Claude: Settings → Connectors → Add custom connector, then paste the server URL.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(18).frame(width: 420)
            }
    }

    private func row(_ title: String, _ value: String, note: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.bold())
            HStack {
                Text(value).font(.system(.caption, design: .monospaced)).textSelection(.enabled).lineLimit(2)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                }.help(note ?? "Copy")
            }
            if let note { Text(note).font(.caption2).foregroundStyle(.secondary) }
        }
    }
}
