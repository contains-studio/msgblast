import SwiftUI
import msgblastMobileKit

struct MobileWantsView: View {
    @State private var key: String?
    @State private var draft = ""
    @FocusState private var editingKey: Bool
    @State private var keyRejected = false
    @State private var connecting = false
    @State private var error: String?

    static func client(_ key: String) -> WantMCPClient {
        WantMCPClient(endpoint: URL(string: "https://mcp.wantmcp.com/mcp")!) { key }
    }

    var body: some View {
        Group {
            if let key {
                WantsLists(client: Self.client(key)) { disconnect(replacing: true) }
                    .id(key)
                    .toolbar {
                        Button("Disconnect", systemImage: "person.crop.circle.badge.minus") {
                            disconnect(replacing: false)
                        }
                    }
            } else {
                Form {
                    Section {
                        if keyRejected { Text("This list key was rejected. Paste a new key from your list’s settings.").foregroundStyle(.secondary) }
                        SecureField("List write key", text: $draft)
                            .focused($editingKey)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button("Connect list") { Task { await connect() } }
                            .disabled(connecting || WantCredential.writeKey(draft) == nil)
                    } footer: {
                        Text("In your list’s settings, open Agents and create a key for msgblast. Paste the wk_ key here.")
                    }
                    Link("Get a list key on Wants", destination: URL(string: "https://wantmcp.com/app")!)
                }
            }
        }
        .navigationTitle("Wants")
        .onAppear {
            do { key = try WantsKeychain.read() } catch { self.error = error.localizedDescription }
        }
        .alert("Wants connection", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    private func disconnect(replacing: Bool) {
        do {
            try WantsKeychain.remove()
            key = nil
            draft = ""
            keyRejected = replacing
            editingKey = replacing
        } catch { self.error = error.localizedDescription }
    }

    private func connect() async {
        guard !connecting, let credential = WantCredential.writeKey(draft) else { return }
        connecting = true
        defer { connecting = false }
        do {
            _ = try await Self.client(credential.accessToken).writableListIDs()
            try WantsKeychain.save(credential.accessToken)
            draft = ""
            keyRejected = false
            key = credential.accessToken
        } catch WantError.unauthorized {
            keyRejected = true
            draft = ""
            editingKey = true
        } catch { self.error = error.localizedDescription }
    }
}

private struct WantsLists: View {
    let client: WantMCPClient
    let replaceKey: () -> Void
    @State private var keyRejected = false
    @State private var lists: [WantList]?
    @State private var error: String?

    var body: some View {
        List {
            if keyRejected {
                Section {
                    Text("This list key no longer has access.")
                    Button("Replace list key", action: replaceKey)
                }
            } else if let error { Text(error).foregroundStyle(.secondary) }
            if let lists {
                if lists.isEmpty {
                    ContentUnavailableView {
                        Label("No writable lists", systemImage: "checklist")
                    } description: {
                        Text("Create a list on Wants or connect a key with access to an existing one.")
                    } actions: {
                        Link("Open my lists on Wants", destination: URL(string: "https://wantmcp.com/app")!)
                    }
                }
                ForEach(lists) { list in
                    NavigationLink { WantsListDetail(client: client, list: list) } label: {
                        Label(list.title, systemImage: list.isPrivate ? "lock" : "list.bullet")
                    }
                }
            } else if error == nil && !keyRejected { ProgressView("Loading lists") }
        }
        .task { await refresh() }
        .refreshable { await refresh() }
    }

    private func refresh() async {
        do {
            var result: [WantList] = []
            for id in try await client.writableListIDs() { result.append(try await client.list(id)) }
            try Task.checkCancellation()
            lists = result
            keyRejected = false
            error = nil
        } catch WantError.unauthorized {
            guard !Task.isCancelled else { return }
            lists = nil
            error = nil
            keyRejected = true
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
}

private struct WantsListDetail: View {
    let client: WantMCPClient
    @State var list: WantList
    @State private var comments: [WantComment] = []
    @State private var error: String?

    var body: some View {
        List {
            if let error { Text(error).foregroundStyle(.secondary) }
            Section {
                WantsSubmission(title: "Add item", placeholder: "What would you like to add?") { text in
                    _ = try await client.addItem(listID: list.id, text: text)
                    await refresh()
                }
            }
            Section {
                ForEach(list.items ?? []) { item in
                    NavigationLink { WantsItemDetail(client: client, listID: list.id, itemURL: WantJSON.webURL(list.url(for: item)), item: item, format: list.kind) } label: {
                        VStack(alignment: .leading) {
                            Text(item.text)
                            if item.openQuestion != nil {
                                Text(WantFormat.waiting).font(.caption).foregroundStyle(.secondary)
                            } else if list.kind == .shopping && item.entryCounts.listed > 0 {
                                Text(item.entryCounts.listed == 1 ? "1 offer" : "\(item.entryCounts.listed) offers")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } header: {
                if list.items?.isEmpty == false { Text("Items") }
            }
            WantsComments(comments: comments.filter { $0.targetId == list.id })
        }
        .navigationTitle(list.title)
        .wantsActivity(client: client, refresh: refresh)
        .refreshable { await refresh() }
    }

    private func refresh() async {
        do {
            list = try await client.list(list.id)
            comments = try await client.comments(listID: list.id)
            error = nil
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
}

private struct WantsItemDetail: View {
    let client: WantMCPClient
    let listID: String
    let itemURL: URL?
    @State var item: WantItem
    let format: WantFormat
    @State private var entries: [WantEntry]?
    @State private var comments: [WantComment] = []
    @State private var error: String?

    var body: some View {
        List {
            Section {
                Text(item.text).font(.title2.bold()).accessibilityAddTraits(.isHeader)
                if let details = item.details ?? item.detailsPreview, !details.isEmpty { Text(details) }
            }
            if let question = item.openQuestion {
                Section(WantFormat.waiting) {
                    if let author = question.askedBy { Text(author.label).font(.caption).foregroundStyle(.secondary) }
                    Text(question.text)
                    WantsSubmission(title: "Send answer", placeholder: "Your answer", options: question.options ?? []) { text in
                        try await client.answer(questionID: question.id, text: text)
                        item.openQuestion = nil
                        await refresh()
                    }
                    .id(question.id)
                }
            }
            if let entries, !entries.isEmpty {
                Section(format.entries) {
                    ForEach(entries) { entry in
                        if let url = WantJSON.webURL(entry.link) {
                            Link(destination: url) { entryLabel(entry) }
                                .buttonStyle(.plain)
                        } else {
                            entryLabel(entry)
                        }
                    }
                }
            }
            if entries?.isEmpty == true && error == nil && item.openQuestion == nil {
                Section {
                    Text("No \(format.entries.lowercased()) yet").foregroundStyle(.secondary)
                    if let itemURL { Link("Open item on Wants", destination: itemURL) }
                }
            }
            WantsComments(comments: comments.filter { $0.targetId == item.id })
            if let error { Text(error).foregroundStyle(.secondary) }
        }
        .navigationBarTitleDisplayMode(.inline)
        .wantsActivity(client: client, refresh: refresh)
        .refreshable { await refresh() }
    }

    private func entryLabel(_ entry: WantEntry) -> some View {
        HStack(alignment: .top, spacing: Space.inset) {
            if format == .shopping { offerThumbnail(entry.imageUrl) }
            VStack(alignment: .leading, spacing: Space.tight) {
                Text(entry.title).font(.headline)
                    .foregroundStyle(WantJSON.webURL(entry.link) == nil ? Color.primary : Color.accentColor)
                if let price = entry.currentPrice {
                    Text([price.formatted, entry.retailer].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.subheadline)
                    let source = switch price.source {
                    case "retailer_page": "Store page"
                    case "search": "Search result"
                    case "aggregator": "Price comparison site"
                    case "user": "User supplied"
                    default: price.isVerified ? "Store page" : ""
                    }
                    Text([source, price.isVerified ? "" : "Unverified"].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                    let time = (price.checkedAt ?? price.postedAt).formatted(.relative(presentation: .named))
                    Text("\(price.postedBy.label) · \(price.checkedAt == nil ? "Posted" : "Checked") \(time)")
                        .font(.caption).foregroundStyle(.secondary)
                } else if !entry.retailer.isEmpty {
                    Text(entry.retailer).font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func offerThumbnail(_ address: String?) -> some View {
        AsyncImage(url: WantJSON.webURL(address)) { phase in
            if let image = phase.image {
                image.resizable().scaledToFit()
            } else {
                Image(systemName: "photo").foregroundStyle(.secondary)
            }
        }
        .frame(width: 64, height: 64)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: Space.gap))
        .clipShape(RoundedRectangle(cornerRadius: Space.gap))
        .accessibilityHidden(true)
    }

    private func refresh() async {
        do {
            entries = try await client.entries(itemID: item.id)
            comments = try await client.comments(listID: listID)
            if let updated = try await client.list(listID).items?.first(where: { $0.id == item.id }) { item = updated }
            error = nil
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
}

private struct WantsComments: View {
    let comments: [WantComment]
    var body: some View {
        if !comments.isEmpty {
            Section("Comments") {
                ForEach(comments) { comment in
                    VStack(alignment: .leading) {
                        Text(comment.author.label).font(.caption).foregroundStyle(.secondary)
                        Text(comment.body)
                    }
                }
            }
        }
    }
}

private struct WantsSubmission: View {
    let title: String
    let placeholder: String
    var options: [String] = []
    let submit: (String) async throws -> Void
    @State private var draft = ""
    @FocusState private var editing: Bool
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        ForEach(options, id: \.self) { option in
            Button(option) { send(option) }.disabled(busy)
        }
        TextField(placeholder, text: $draft, axis: .vertical).focused($editing).disabled(busy)
        Button(title) { send(draft) }
            .disabled(busy || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        if let error { Text(error).font(.footnote).foregroundStyle(.secondary) }
    }

    private func send(_ text: String) {
        guard !busy else { return }
        busy = true
        editing = false
        error = nil
        Task {
            defer { busy = false }
            do {
                try await submit(text.trimmingCharacters(in: .whitespacesAndNewlines))
                draft = ""
            } catch { self.error = error.localizedDescription }
        }
    }
}

private extension View {
    func wantsActivity(client: WantMCPClient, refresh: @escaping @MainActor () async -> Void) -> some View {
        modifier(WantsActivity(client: client, refresh: refresh))
    }
}

private struct WantsActivity: ViewModifier {
    let client: WantMCPClient
    let refresh: @MainActor () async -> Void
    @Environment(\.scenePhase) private var phase

    func body(content: Content) -> some View {
        content.task(id: phase) {
            guard phase == .active else { return }
            var cursor: String?
            var initial = true
            while !Task.isCancelled {
                do {
                    let page = try await client.poll("list.activity", cursor: cursor)
                    try Task.checkCancellation()
                    if initial || page.hasActivity { await refresh() }
                    initial = false
                    let advanced = page.cursor != cursor
                    cursor = page.cursor
                    let delay = page.hasMore && advanced ? 0 : min(300, max(2, page.nextPoll ?? 30))
                    try await Task.sleep(for: .seconds(delay))
                } catch {
                    guard !Task.isCancelled else { return }
                    await refresh()
                    try? await Task.sleep(for: .seconds(30))
                }
            }
        }
    }
}
