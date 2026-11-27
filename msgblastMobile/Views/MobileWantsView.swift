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
                    WantsBrowserLink(destination: URL(string: "https://wantmcp.com/app")!) { Text("Get a list key on Wants") }
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

private struct WantsBrowserLink<Label: View>: View {
    let destination: URL
    @ViewBuilder var label: () -> Label
    @State private var showingBrowser = false

    var body: some View {
        Button { showingBrowser = true } label: { label() }
            .accessibilityRemoveTraits(.isButton)
            .accessibilityAddTraits(.isLink)
            .sheet(isPresented: $showingBrowser) {
                SafariView(url: destination).ignoresSafeArea()
            }
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
                        WantsBrowserLink(destination: URL(string: "https://wantmcp.com/app")!) { Text("Open my lists on Wants") }
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

private extension WantFormat {
    var addTitle: String {
        switch self { case .shopping: "Add want"; case .tasks: "Add task"; case .research: "Ask a question" }
    }
    var placeholder: String {
        switch self {
        case .shopping: "e.g. A quiet dehumidifier"
        case .tasks: "e.g. Get three moving quotes"
        case .research: "e.g. Is a heat pump worth it?"
        }
    }
    func entryCount(_ count: Int) -> String {
        let noun: String = switch self { case .shopping: "product"; case .tasks: "update"; case .research: "answer" }
        return "\(count) \(noun)\(count == 1 ? "" : "s")"
    }
}

private struct WantsLook {
    enum Template: String { case sheet, today, doc, board, sections, heat, tracker, gallery }
    let template: Template
    typealias Occasion = (name: String, icon: String, color: Color)
    let occasion: Occasion?
    private static let occasions: [String: Occasion] = [
        "birthday": ("Birthday", "birthday.cake", .pink),
        "black-friday": ("Black Friday", "tag", .purple),
        "cyber-monday": ("Cyber Monday", "bolt", .blue),
        "chanukah": ("Chanukah", "flame", .blue),
        "christmas": ("Christmas", "tree", .green),
        "kwanzaa": ("Kwanzaa", "flame", .orange),
        "new-year": ("New Year", "sparkles", .purple),
        "valentines": ("Valentine’s Day", "heart", .pink),
        "halloween": ("Halloween", "moon.stars", .orange),
    ]

    init(list: WantList) {
        let parts = (list.theme ?? "").lowercased().components(separatedBy: "--")
        let slug = parts[0]
        let fallback: Template = switch list.kind { case .shopping: .sheet; case .tasks: .today; case .research: .doc }
        template = slug == "checklist" ? .today : Template(rawValue: slug) ?? fallback
        let occasionSlug = parts.count > 1 ? parts[1] : slug
        occasion = Self.occasions[occasionSlug == "hanukkah" ? "chanukah" : occasionSlug]
    }
}

private struct WantsGalleryPhoto: View {
    let client: WantMCPClient
    let item: WantItem
    @State private var photo: URL?

    var body: some View {
        Group {
            if let photo {
                AsyncImage(url: photo) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFit().frame(maxWidth: .infinity).frame(height: 108)
                            .background(.white, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            } else { Color.clear.frame(height: 0) }
        }
        .task(id: item) {
            photo = nil
            guard item.entryCounts.listed > 0 else { return }
            let entries: [WantEntry]
            if let included = item.entries { entries = included }
            else { entries = (try? await client.entries(itemID: item.id)) ?? [] }
            guard !Task.isCancelled else { return }
            let listed = entries.filter { $0.status == "listed" }
            let best = listed.first { $0.id == item.bestPrice?.entryId }
            photo = WantJSON.webURL(best?.imageUrl) ?? listed.lazy.compactMap { WantJSON.webURL($0.imageUrl) }.first
        }
        .accessibilityHidden(true)
    }
}

private struct WantsListDetail: View {
    let client: WantMCPClient
    @State var list: WantList
    @State private var comments: [WantComment] = []
    @State private var error: String?

    private var look: WantsLook { WantsLook(list: list) }
    private var items: [WantItem] { list.items ?? [] }

    var body: some View {
        List {
            if let error { Text(error).foregroundStyle(.secondary) }
            Section {
                WantsSubmission(title: list.kind.addTitle, placeholder: list.kind.placeholder) { text in
                    _ = try await client.addItem(listID: list.id, text: text)
                    await refresh()
                }
            } header: {
                if let occasion = look.occasion {
                    Label(occasion.name, systemImage: occasion.icon).foregroundStyle(occasion.color)
                }
            }
            if !items.isEmpty {
                if look.template == .board {
                    Section {
                        ScrollView(.horizontal) {
                            HStack(alignment: .top, spacing: 12) {
                                ForEach(groups, id: \.self) { group in
                                    let members = items.filter { groupName($0) == group }
                                    VStack(alignment: .leading, spacing: 10) {
                                        Text("\(group) · \(members.count)").font(.headline)
                                        ForEach(members) { item in
                                            itemLink(item).buttonStyle(.plain)
                                                .padding(10).background(.background, in: RoundedRectangle(cornerRadius: 10))
                                        }
                                        if members.isEmpty { Text("Nothing here").foregroundStyle(.secondary) }
                                    }
                                    .padding(12).containerRelativeFrame(.horizontal) { width, _ in width * 0.88 }
                                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 14))
                                }
                            }.scrollTargetLayout()
                        }.scrollTargetBehavior(.viewAligned)
                    }.listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                } else if [.sections, .heat].contains(look.template) {
                    ForEach(groups, id: \.self) { group in
                        let members = items.filter { groupName($0) == group }
                        if !members.isEmpty {
                            Section {
                                ForEach(members) { item in itemLink(item) }
                            } header: { Text("\(group) · \(members.count)") }
                        }
                    }
                } else {
                    itemSection(items.filter { !$0.isFinished }, title: list.kind.item + "s")
                    itemSection(items.filter(\.isFinished), title: list.kind.finished)
                }
            }
            WantsComments(comments: comments.filter { $0.targetId == list.id })
        }
        .tint(look.occasion?.color ?? .accentColor)
        .navigationTitle(list.title)
        .wantsActivity(client: client, refresh: refresh)
        .refreshable { await refresh() }
    }

    private func groupName(_ item: WantItem) -> String {
        if item.isFinished { return list.kind.finished }
        if item.openQuestion != nil || item.status == "waiting_on_owner" { return WantFormat.waiting }
        if list.kind != .shopping && item.status == "in_progress" { return "In progress" }
        return "Open"
    }

    private var groups: [String] {
        var names = items.contains { groupName($0) == WantFormat.waiting } ? [WantFormat.waiting] : []
        let active = look.template == .board ? ["Open", "In progress"] : ["In progress", "Open"]
        names += list.kind == .shopping ? ["Open"] : active
        return names + [list.kind.finished]
    }

    @ViewBuilder private func itemSection(_ members: [WantItem], title: String) -> some View {
        if !members.isEmpty {
            Section(title) {
                if look.template == .gallery {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), alignment: .topLeading)], alignment: .leading, spacing: 16) {
                        ForEach(members) { item in
                            itemLink(item)
                                .navigationLinkIndicatorVisibility(.hidden)
                                .buttonStyle(.plain)
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                                .background(.background, in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(members) { item in itemLink(item) }
                }
            }
        }
    }

    private func itemLink(_ item: WantItem) -> some View {
        NavigationLink {
            WantsItemDetail(client: client, listID: list.id, itemURL: WantJSON.webURL(list.url(for: item)), item: item, format: list.kind)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                if look.template == .gallery && list.kind == .shopping {
                    WantsGalleryPhoto(client: client, item: item)
                }
                HStack(alignment: .firstTextBaseline) {
                    if look.template == .today {
                        Image(systemName: item.isFinished ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(.secondary).accessibilityHidden(true)
                    }
                    Text(item.text)
                        .font(look.template == .doc ? .system(.headline, design: .serif) : .body)
                        .fontWeight([.gallery, .heat, .board].contains(look.template) ? .semibold : .regular)
                }
                let count = item.entryCounts.listed
                let phase = groupName(item)
                let grouped = [.board, .sections, .heat].contains(look.template)
                let parts = [!grouped && [WantFormat.waiting, "In progress"].contains(phase) ? phase : nil,
                             item.claimedBy?.label, item.bestPrice?.formatted, count > 0 ? list.kind.entryCount(count) : nil].compactMap { $0 }
                if let due = item.dueAt, !item.isFinished {
                    Label(due.formatted(date: .abbreviated, time: .omitted), systemImage: "calendar")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !parts.isEmpty {
                    Text(parts.joined(separator: " · "))
                        .font(look.template == .tracker ? .system(.caption, design: .monospaced) : .caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        }
        .listRowBackground(look.template == .heat && !item.isFinished ? heatColor(item).opacity(0.14) : nil)
    }

    private func heatColor(_ item: WantItem) -> Color {
        switch groupName(item) {
        case WantFormat.waiting: .orange
        case "In progress": .yellow
        default: .blue
        }
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
                            WantsBrowserLink(destination: url) { entryLabel(entry) }
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
                    if let itemURL { WantsBrowserLink(destination: itemURL) { Text("Open item on Wants") } }
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
