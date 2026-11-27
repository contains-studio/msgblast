import SwiftUI
import msgblastMobileKit

struct MobileWantsView: View {
    @State private var key: String?
    @State private var draft = ""
    @State private var connecting = false
    @State private var error: String?

    static func client(_ key: String) -> WantMCPClient {
        WantMCPClient(endpoint: URL(string: "https://mcp.wantmcp.com/mcp")!) { key }
    }

    var body: some View {
        Group {
            if let key {
                WantsLists(client: Self.client(key)).id(key)
                    .toolbar {
                        Button("Disconnect", systemImage: "person.crop.circle.badge.minus") {
                            do { try WantsKeychain.remove(); self.key = nil }
                            catch { self.error = error.localizedDescription }
                        }
                    }
            } else {
                Form {
                    Section {
                        SecureField("List write key", text: $draft)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button("Connect list") { Task { await connect() } }
                            .disabled(connecting || WantCredential.writeKey(draft) == nil)
                    } header: { Text("Connect a list") } footer: {
                        Text("In your list’s settings, open Agents and create a key for msgblast. Paste the wk_ key here.")
                    }
                    Link("Open The Want MCP", destination: URL(string: "https://wantmcp.com/app")!)
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

    private func connect() async {
        guard !connecting, let credential = WantCredential.writeKey(draft) else { return }
        connecting = true
        defer { connecting = false }
        do {
            _ = try await Self.client(credential.accessToken).writableListIDs()
            try WantsKeychain.save(credential.accessToken)
            draft = ""
            key = credential.accessToken
        } catch { self.error = error.localizedDescription }
    }
}

private struct WantsLists: View {
    let client: WantMCPClient
    @State private var lists: [WantList]?
    @State private var error: String?

    var body: some View {
        List {
            if let error { Text(error).foregroundStyle(.secondary) }
            if let lists {
                if lists.isEmpty { ContentUnavailableView("No writable lists", systemImage: "checklist") }
                ForEach(lists) { list in
                    NavigationLink { WantsListDetail(client: client, list: list) } label: {
                        Label(list.title, systemImage: list.isPrivate ? "lock" : "list.bullet")
                    }
                }
            } else if error == nil { ProgressView("Loading lists") }
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
            error = nil
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
            Section("Items") {
                ForEach(list.items ?? []) { item in
                    NavigationLink { WantsItemDetail(client: client, listID: list.id, item: item, format: list.kind) } label: {
                        VStack(alignment: .leading) {
                            Text(item.text)
                            if item.openQuestion != nil { Text(WantFormat.waiting).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
                if list.items?.isEmpty != false { Text("No items yet").foregroundStyle(.secondary) }
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
    @State var item: WantItem
    let format: WantFormat
    @State private var entries: [WantEntry] = []
    @State private var comments: [WantComment] = []
    @State private var error: String?

    var body: some View {
        List {
            Section {
                Text(item.text).font(.headline)
                if let details = item.details ?? item.detailsPreview, !details.isEmpty { Text(details) }
            }
            if let question = item.openQuestion {
                Section(WantFormat.waiting) {
                    Text(question.text)
                    WantsSubmission(title: "Send answer", placeholder: "Your answer", options: question.options ?? []) { text in
                        try await client.answer(questionID: question.id, text: text)
                        item.openQuestion = nil
                        await refresh()
                    }
                    .id(question.id)
                }
            }
            if !entries.isEmpty {
                Section(format.entries) {
                    ForEach(entries) { entry in
                        VStack(alignment: .leading) {
                            if let url = WantJSON.webURL(entry.link) { Link(entry.title, destination: url) }
                            else { Text(entry.title) }
                            if let price = entry.currentPrice {
                                Text(price.formatted + (price.isVerified ? "" : " · Unverified")).font(.subheadline)
                            }
                        }
                    }
                }
            }
            WantsComments(comments: comments.filter { $0.targetId == item.id })
            if let error { Text(error).foregroundStyle(.secondary) }
        }
        .navigationTitle(format.item)
        .wantsActivity(client: client, refresh: refresh)
        .refreshable { await refresh() }
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
