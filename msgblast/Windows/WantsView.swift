import AppKit
import SwiftUI
import msgblastCore

struct WantsView: View {
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
                    WantItemDetail(wants: wants, item: selected.item, list: selected.list)
                } else {
                    ContentUnavailableView("Choose a want", systemImage: "gift", description: Text("Its offers and comments appear here."))
                }
            }.frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar {
            ToolbarItemGroup {
                WantsConnectButton()
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

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "gift").font(.system(size: 44)).foregroundStyle(.tint)
            Text("The Want MCP").font(.title2.bold())
            Text("An MCP server for getting what you want.").foregroundStyle(.secondary)
            HStack {
                SecureField("Write key (wk_…)", text: $key).textFieldStyle(.roundedBorder).frame(width: 260)
                Button("Add") {
                    if wants.useWriteKey(key) { key = "" }
                }.disabled(key.isEmpty)
            }
            Text("On wantmcp.com, open a list's settings, then Agents › Add another agent.").font(.callout).foregroundStyle(.secondary)
            Link("Open wantmcp.com", destination: URL(string: "https://wantmcp.com/app")!).font(.callout)
        }.padding(40).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct WantsListColumn: View {
    @ObservedObject var wants: WantsModel
    @Binding var selection: String?

    var body: some View {
        List(selection: $selection) {
            ForEach(wants.lists) { list in
                Section(list.title) {
                    ForEach(list.items ?? []) { item in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.text).lineLimit(2)
                            Text(progress(item, list.kind)).font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 3).tag(item.id)
                    }
                }
            }
            if wants.lists.isEmpty { Text("No lists yet. Create one at wantmcp.com.").foregroundStyle(.secondary) }
        }.listStyle(.sidebar)
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
    @ObservedObject var wants: WantsModel
    let item: WantItem
    let list: WantList
    private var entries: [WantEntry] { wants.entries[item.id] ?? item.entries ?? [] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.text).font(.title2.bold()).textSelection(.enabled)
                    HStack(spacing: 8) {
                        if let url = WantJSON.webURL(list.url(for: item)) { Link(list.title, destination: url) } else { Text(list.title) }
                        if list.isPrivate { Label("Private", systemImage: "lock").foregroundStyle(.secondary) }
                        if let status { Text(status).foregroundStyle(.secondary) }
                    }.font(.callout)
                    if let details = item.details ?? item.detailsPreview, !details.isEmpty { Text(details).foregroundStyle(.secondary).textSelection(.enabled) }
                }
                if let question = item.openQuestion { questionCard(question) }
                section(list.kind.entries, empty: "No \(list.kind.entries.lowercased()) yet.", rows: entries) { WantEntryRow(entry: $0) }
                let pending = (wants.suggestions[list.id] ?? []).filter { $0.itemId == item.id }
                if !pending.isEmpty {
                    section("Suggested by outside agents", empty: "", rows: pending) { WantEntryRow(entry: $0) }
                    Text("Hidden from others until you or your agents promote them.").font(.caption).foregroundStyle(.secondary)
                }
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
    }

    private var status: String? {
        switch item.status {
        case "in_progress": (["In progress"] + (item.claimedBy.map { [$0.label] } ?? [])).joined(separator: " · ")
        case "done": list.kind.finished
        default: nil
        }
    }

    private func questionCard(_ question: WantQuestion) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(WantFormat.waiting, systemImage: "questionmark.bubble").font(.headline).foregroundStyle(.orange)
            Text(question.text).textSelection(.enabled)
            if let asker = question.askedBy { Text("Asked by \(asker.label)").font(.caption).foregroundStyle(.secondary) }
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
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
            if entry.productUrl != nil {
                AsyncImage(url: entry.status == "listed" ? WantJSON.webURL(entry.imageUrl) : nil) { image in
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
                HStack(spacing: 6) {
                    if !entry.retailer.isEmpty { Text(entry.retailer).foregroundStyle(.secondary) }
                    if let price = entry.currentPrice {
                        Text(price.formatted).fontWeight(.semibold)
                        if let was = price.formattedOriginal { Text(was).strikethrough().foregroundStyle(.secondary) }
                        if !price.isVerified { Text("unverified").font(.caption).foregroundStyle(.orange) }
                        if let checked = price.checkedAt { Text("checked \(checked.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.secondary) }
                    }
                }
                byline(entry.author, entry.createdAt)
            }
            Spacer(minLength: 0)
        }
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
                    Link("Setup prompts for Claude Code, Codex and others", destination: URL(string: "https://wantmcp.com/connect")!).font(.callout)
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
