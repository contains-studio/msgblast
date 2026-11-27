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
        GeometryReader { area in
            if area.size.width >= 640 {
                HSplitView {
                    listColumn.frame(minWidth: 200, idealWidth: 240, maxWidth: min(320, area.size.width * 0.36))
                    detail.frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
                }
            } else if selected != nil {
                VStack(alignment: .leading, spacing: 0) {
                    Button { selectedItem = nil } label: { Label("Wants", systemImage: "chevron.backward") }
                        .buttonStyle(.link).padding(.horizontal, 20).padding(.vertical, 10)
                    Divider()
                    detail
                }
            } else {
                listColumn
            }
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

    private var listColumn: some View {
        WantsListColumn(wants: wants, selection: $selectedItem)
    }

    @ViewBuilder private var detail: some View {
        if let selected {
            WantItemDetail(model: model, wants: wants, item: selected.item, list: selected.list)
        } else {
            ContentUnavailableView("Choose a want", systemImage: "gift", description: Text("Its offers and comments appear here."))
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
            Image(systemName: "checklist").font(.largeTitle).foregroundStyle(.tint).accessibilityHidden(true)
            Text("What do you want help with?").font(.title.bold()).accessibilityAddTraits(.isHeader)
            Text("Make a list of things to buy, tasks to finish, or questions to answer. Give it to an agent, then review the products, updates, or answers it brings back.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: 360)
                .padding(.bottom, 6)
            if wants.signingIn {
                HStack { ProgressView().controlSize(.small); Text("Finish setting up The Want MCP in your browser.") }
                Button("Cancel") { wants.cancelSignIn() }
            } else {
                Button("Connect with The Want MCP") { Task { await wants.signIn() } }.buttonStyle(.borderedProminent).controlSize(.large)
                if showingKey {
                    HStack {
                        SecureField("wk_…", text: $key).textFieldStyle(.roundedBorder).frame(width: 260)
                        Button("Add") {
                            if wants.useWriteKey(key) { key = "" }
                        }.disabled(key.isEmpty)
                    }
                    Link("Get a list key", destination: WantOAuth.keyPage).font(.callout).foregroundStyle(.secondary)
                } else {
                    Button("I already have a list key") { showingKey = true }.buttonStyle(.link)
                }
            }
        }.multilineTextAlignment(.center).padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct WantsListColumn: View {
    @ObservedObject var wants: WantsModel
    @Binding var selection: String?
    @State private var draft = ""
    @State private var adding = false
    @State private var listID: String?

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(wants.lists) { list in
                    Section {
                        ForEach(list.items ?? []) { item in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.text).fontWeight(.medium).lineLimit(3)
                                if item.status == "waiting_on_owner" {
                                    Label(WantFormat.waiting, systemImage: "questionmark.bubble")
                                        .font(.caption.weight(.medium))
                                } else {
                                    Text(progress(item, list.kind)).font(.caption).foregroundStyle(.secondary)
                                }
                            }.padding(.vertical, 5).tag(item.id)
                        }
                    } header: {
                        Text(list.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    }
                }
                if wants.lists.isEmpty { Text("No lists yet. Create one at wantmcp.com.").foregroundStyle(.secondary) }
            }.listStyle(.sidebar)
                .onChange(of: selection) { _, item in
                    if let list = wants.lists.first(where: { $0.items?.contains { $0.id == item } == true }) { listID = list.id }
                }
            Divider()
            HStack {
                TextField("Add a \(target?.kind.item.lowercased() ?? "want")", text: $draft).textFieldStyle(.roundedBorder).onSubmit(add)
                Button(action: add) { Image(systemName: "plus") }.disabled(adding || draft.trimmingCharacters(in: .whitespaces).isEmpty || target == nil)
                    .accessibilityLabel("Add Want")
                if wants.lists.count > 1 {
                    Menu {
                        ForEach(wants.lists) { list in Button(list.title) { listID = list.id } }
                    } label: { Image(systemName: "list.bullet") }.menuStyle(.borderlessButton).fixedSize().help("Add to \(target?.title ?? "")")
                }
            }.padding(10)
        }
    }

    private var target: WantList? { wants.lists.first { $0.id == listID } ?? wants.lists.first }
    private func add() {
        guard !adding, let target else { return }
        let text = draft
        adding = true
        Task {
            if await wants.addItem(text, to: target), draft == text { draft = "" }
            adding = false
        }
    }
    private func progress(_ item: WantItem, _ format: WantFormat) -> String {
        if item.status == "done" { return format.finished }
        if item.status == "in_progress" { return "In progress" }
        if item.status == "waiting_on_owner" { return WantFormat.waiting }
        let count = item.entryCounts.listed, noun = format.entries.lowercased()
        return count == 0 ? "No \(noun) yet" : count == 1 ? "1 \(noun.dropLast())" : "\(count) \(noun)"
    }
}

private struct WantItemDetail: View {
    @ObservedObject var model: AppModel
    @ObservedObject var wants: WantsModel
    let item: WantItem
    let list: WantList
    @State private var picking = false
    @State private var answers: [String: String] = [:]
    private var entries: [WantEntry] { wants.entries[item.id] ?? item.entries ?? [] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        if let url = WantJSON.webURL(list.url(for: item)) {
                            Link(list.title, destination: url)
                        } else {
                            Text(list.title)
                        }
                        if list.isPrivate { Label("Private", systemImage: "lock") }
                    }.font(.callout).foregroundStyle(.secondary)
                    Text(item.text).font(.title.bold()).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    if let status { Text(status).font(.callout).foregroundStyle(.secondary) }
                    if let details = item.details ?? item.detailsPreview, !details.isEmpty { Text(details).textSelection(.enabled) }
                    Button { picking = true } label: { Label(list.kind.ask, systemImage: "paperplane") }
                        .buttonStyle(.borderedProminent).disabled(wants.sending || !model.canStartNewBlast)
                }
                Divider()
                if let question = item.openQuestion { questionCard(question) }
                section(list.kind.entries, empty: "No \(list.kind.entries.lowercased()) yet.", rows: entries) { WantEntryRow(entry: $0) }
                let pending = (wants.suggestions[list.id] ?? []).filter { $0.itemId == item.id }
                if !pending.isEmpty {
                    section("Suggested by outside agents", empty: "", rows: pending) { WantEntryRow(entry: $0) }
                    Text("Hidden from others until you or your agents promote them.").font(.caption).foregroundStyle(.secondary)
                }
                if let replies = wants.replies(for: item) { repliesSection(replies.comparison, replies.turns) }
                let comments = (wants.comments[list.id] ?? []).filter { comment in comment.targetId == item.id || entries.contains { $0.id == comment.targetId } }
                section("Comments", empty: "No comments.", rows: comments) { comment in
                    VStack(alignment: .leading, spacing: 3) {
                        byline(comment.author, comment.createdAt)
                        Text(comment.body).textSelection(.enabled)
                    }
                }
            }.padding(24).frame(maxWidth: 760, alignment: .leading)
        }
        .task(id: item.id) { await wants.loadEntries(item) }
        .sheet(isPresented: $picking) {
            WantsAgentPicker(title: "Choose agents", action: list.kind.ask, agents: wants.agents,
                             initial: wants.saved.blasts[item.id]?.agents ?? wants.agents.filter(\.selected).map(\.id)) { chosen in
                Task { await wants.blast(item, in: list, to: chosen) }
            }
        }
    }

    private var status: String? {
        switch item.status {
        case "in_progress": (["In progress"] + (item.claimedBy.map { [$0.label] } ?? [])).joined(separator: " · ")
        case "done": list.kind.finished
        default: nil
        }
    }

    /// An agent's question, waiting on the person: one tap for an offered option, or a typed answer.
    private func questionCard(_ question: WantQuestion) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(WantFormat.waiting, systemImage: "questionmark.bubble").font(.headline).foregroundStyle(.orange)
            Text(question.text).textSelection(.enabled)
            if let asker = question.askedBy { Text("Asked by \(asker.label)").font(.caption).foregroundStyle(.secondary) }
            HStack {
                ForEach(question.options ?? [], id: \.self) { option in
                    Button(option) { Task { await wants.answer(question, with: option) } }
                }
            }
            HStack {
                TextField("Or type an answer", text: Binding(get: { answers[question.id] ?? "" }, set: { answers[question.id] = $0 }))
                    .textFieldStyle(.roundedBorder).onSubmit { send(question) }
                Button("Answer") { send(question) }.disabled((answers[question.id] ?? "").trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }.disabled(wants.answering.contains(question.id)).padding(14).background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private func send(_ question: WantQuestion) {
        guard let text = answers[question.id] else { return }
        Task {
            if await wants.answer(question, with: text), answers[question.id] == text { answers[question.id] = nil }
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
            if entry.status == "listed", let image = WantJSON.webURL(entry.imageUrl) {
                AsyncImage(url: image) { image in
                    image.resizable().scaledToFit()
                } placeholder: {
                    Image(systemName: "shippingbox").font(.title2).foregroundStyle(.tertiary)
                }.frame(width: 64, height: 64).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            }
            VStack(alignment: .leading, spacing: 3) {
                if entry.status == "listed", let url = WantJSON.webURL(entry.link) {
                    Link(entry.title, destination: url).font(.body.weight(.semibold))
                } else {
                    // Outside suggestions are untrusted: shown as plain text, never as links.
                    Text(entry.title).font(.body.weight(.semibold))
                    Text(entry.link ?? "").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if !entry.retailer.isEmpty { Text(entry.retailer).font(.callout).foregroundStyle(.secondary) }
                if let price = entry.currentPrice {
                    HStack(spacing: 8) {
                        Text(price.formatted).font(.headline).monospacedDigit()
                        if let was = price.formattedOriginal { Text(was).strikethrough().foregroundStyle(.secondary) }
                    }
                    HStack(spacing: 6) {
                        if !price.isVerified { Text("unverified").font(.caption).foregroundStyle(.orange) }
                        if let checked = price.checkedAt { Text("checked \(checked.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.secondary) }
                    }
                }
                byline(entry.author, entry.createdAt)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(.separator.opacity(0.5)) }
    }
}

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
        _chosen = State(initialValue: Set(initial).intersection(agents.filter { !$0.busy }.map(\.id)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            if agents.isEmpty { Text("Connect an agent in msgblast first.").foregroundStyle(.secondary) }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(agents, id: \.id) { agent in
                        Toggle(isOn: Binding(get: { chosen.contains(agent.id) }, set: { on in
                            if on { chosen.insert(agent.id) } else { chosen.remove(agent.id) }
                        })) {
                            HStack {
                                Text(agent.name)
                                if agent.busy { Text("Busy").foregroundStyle(.secondary) }
                                Spacer()
                            }.contentShape(Rectangle())
                        }.disabled(agent.busy)
                    }
                }
            }.frame(height: min(280, CGFloat(agents.count) * 26))
            Divider()
            HStack {
                Text("\(chosen.count) selected").font(.callout).foregroundStyle(.secondary)
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
            .help("Forward comments, outside suggestions and answers from your lists")
            .contextMenu { Button("Choose Agents…") { picking = true } }
            .sheet(isPresented: $picking) {
                WantsAgentPicker(title: "Choose agents for items you haven’t asked about", action: "Turn On", agents: wants.agents, initial: wants.saved.forwardAgents) {
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
                    Text("Each agent needs its own connection to post to your lists.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    row("MCP server URL", url)
                    Text("ChatGPT and Claude: Settings → Connectors → Add custom connector, then paste the server URL.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Link("Setup prompts for Claude Code, Codex and others", destination: URL(string: WantPrompt.connectURL)!).font(.callout)
                }.padding(18).frame(width: 420)
            }
    }

    private func row(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.bold())
            HStack {
                Text(value).font(.system(.caption, design: .monospaced)).textSelection(.enabled).lineLimit(2)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                }
            }
        }
    }
}
