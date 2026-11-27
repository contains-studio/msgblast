import SwiftUI
import AuthenticationServices
import msgblastMobileKit

struct MobileWantsView: View {
    @Environment(\.webAuthenticationSession) private var authentication
    @State private var connection: MobileWantConnection?
    @State private var operation: Task<Void, Never>?
    @State private var draft = ""
    @FocusState private var editingKey: Bool
    @State private var startingList = false
    @State private var showingKeyForm = false
    @State private var replacingKey = false
    @State private var keyRejected = false
    @State private var connecting = false
    @State private var error: String?

    private func client(_ connection: MobileWantConnection) -> WantMCPClient {
        WantMCPClient(endpoint: WantOAuth.resource, renew: { try await connection.renew($0) }) { try await connection.token() }
    }

    var body: some View {
        Group {
            if let connection, !replacingKey {
                WantsLists(client: client(connection), connection: connection) {
                    if connection.grant.clientID != nil { disconnect(); return }
                    replacingKey = true
                    editingKey = true
                    keyRejected = true
                }
                    .id(connection.id)
                    .toolbar {
                        Button("Disconnect", systemImage: "person.crop.circle.badge.minus") {
                            disconnect()
                        }
                    }
            } else if showingKeyForm || replacingKey {
                Form {
                    Section {
                        if keyRejected { Text("This list key was rejected. Get a new key or connect again.").foregroundStyle(.secondary) }
                        SecureField("List write key", text: $draft)
                            .focused($editingKey)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button("Connect list") { Task { await connect() } }
                            .disabled(connecting || WantCredential.writeKey(draft) == nil)
                        Button("Cancel", role: .cancel) {
                            showingKeyForm = false
                            replacingKey = false
                            keyRejected = false
                            draft = ""
                        }.disabled(connecting)
                    } footer: {
                        Text("Choose a list on The Want MCP, create a key for msgblast, then paste it here.")
                    }
                    WantsBrowserLink(destination: WantOAuth.keyPage) { Text("Get a list key") }
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Image(systemName: "checklist")
                            .font(.largeTitle).foregroundStyle(.tint).accessibilityHidden(true)
                        Text("What do you want help with?")
                            .font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
                        Text("Make a list of things to buy, tasks to finish, or questions to answer. Give it to an agent, then review the products, updates, or answers it brings back.")
                            .foregroundStyle(.secondary)
                        Button {
                            operation = Task { await signIn() }
                        } label: {
                            Text("Connect with The Want MCP").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent).controlSize(.large).padding(.top, 12)
                        Button("Start a list") { startingList = true }
                            .frame(maxWidth: .infinity, minHeight: 44)
                        Button("I already have a list key") { showingKeyForm = true }
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .frame(maxWidth: 420).padding(24).frame(maxWidth: .infinity)
                }
                .disabled(connecting)
            }
        }
        .sheet(isPresented: $startingList) {
            StartWantListSheet { title, format in
                let grant = try await WantClaim.start(title: title, format: format)
                connection = try MobileWantConnection.install(grant)
            }
        }
        .navigationTitle("Wants")
        .onAppear {
            guard connection == nil else { return }
            do { connection = try WantsKeychain.read().map(MobileWantConnection.init) } catch { self.error = error.localizedDescription }
        }
        .onDisappear { operation?.cancel() }
        .alert("Wants connection", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    private func signIn() async {
        guard !connecting else { return }
        connecting = true
        defer { connecting = false }
        do {
            let resource = WantOAuth.resource
            let redirect = URL(string: "app.msgblast:/oauth")!
            let server = try await WantOAuth.discover(resource: resource, hint: nil)
            guard server.issuer == "https://mcp.wantmcp.com" else { throw WantError.invalidResponse }
            let defaults = UserDefaults.standard
            let registration = "WantsMobileOAuthClientID"
            let clientID: String
            if let saved = defaults.string(forKey: registration) { clientID = saved }
            else {
                clientID = try await WantOAuth.register(server, redirect: redirect)
                defaults.set(clientID, forKey: registration)
            }
            let pkce = WantOAuth.PKCE()
            let url = WantOAuth.authorizeURL(server, clientID: clientID, redirect: redirect, pkce: pkce, resource: resource)
            try Task.checkCancellation()
            let back = try await authentication.authenticate(using: url, callback: .customScheme("app.msgblast"),
                                                              preferredBrowserSession: .shared, additionalHeaderFields: WantOAuth.checkHeaders)
            var parts = URLComponents(url: back, resolvingAgainstBaseURL: false)
            let issuer = parts?.queryItems?.filter { $0.name == "iss" }
            parts?.query = nil
            guard parts?.url == redirect, issuer?.count == 1, issuer?.first?.value == server.issuer else { throw WantError.invalidResponse }
            let grant = try await WantOAuth.exchange(callback: back, server: server, clientID: clientID, redirect: redirect, pkce: pkce, resource: resource)
            try Task.checkCancellation()
            connection = try MobileWantConnection.install(grant)
        } catch is CancellationError {
        } catch ASWebAuthenticationSessionError.canceledLogin {
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }

    private func disconnect() {
        do {
            try WantsKeychain.remove()
            connection = nil
            showingKeyForm = false
            draft = ""
            keyRejected = false
            editingKey = false
        } catch { self.error = error.localizedDescription }
    }

    private func connect() async {
        guard !connecting, let credential = WantCredential.writeKey(draft) else { return }
        connecting = true
        defer { connecting = false }
        do {
            let candidate = WantMCPClient(endpoint: WantOAuth.resource) { credential.accessToken }
            _ = try await candidate.writableListIDs()
            connection = try MobileWantConnection.install(credential)
            draft = ""
            keyRejected = false
            replacingKey = false
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
    @ObservedObject var connection: MobileWantConnection
    @Environment(\.scenePhase) private var phase
    let replaceKey: () -> Void
    @State private var keyRejected = false
    @State private var lists: [WantList]?
    @State private var refreshID = 0
    @State private var error: String?

    var body: some View {
        List {
            if let claim = connection.grant.claim, claim.active, !connection.removed.contains(claim.listID), !keyRejected, !connection.revoked {
                Section {
                    WantsBrowserLink(destination: claim.url) { Text("Keep this list") }
                } footer: {
                    Text("Keep your private list before \(claim.expiresAt.formatted()) or it will expire.")
                }
            }
            if keyRejected || connection.revoked {
                Section {
                    Text("This connection no longer has access.")
                    Button(connection.grant.clientID == nil ? "Replace list key" : "Reconnect", action: replaceKey)
                }
            } else if let error { Text(error).foregroundStyle(.secondary) }
            if let lists, !connection.revoked {
                let available = lists.filter { !connection.removed.contains($0.id) }
                if available.isEmpty && !connection.removed.isEmpty {
                    ContentUnavailableView("Access removed", systemImage: "lock", description: Text("Connect another list to continue."))
                    Button(connection.grant.clientID == nil ? "Replace list key" : "Reconnect", action: replaceKey)
                } else if available.isEmpty {
                    ContentUnavailableView {
                        Label("No writable lists", systemImage: "checklist")
                    } description: {
                        Text("Create a list on Wants or connect a key with access to an existing one.")
                    } actions: {
                        WantsBrowserLink(destination: URL(string: "https://wantmcp.com/app")!) { Text("Open my lists on Wants") }
                    }
                }
                ForEach(available) { list in
                    NavigationLink { WantsAccessView(listID: list.id, client: client, connection: connection) { WantsListDetail(connection: connection, client: client, list: list) } } label: {
                        Label(list.title, systemImage: list.isPrivate ? "lock" : "list.bullet")
                    }
                }
            } else if error == nil && !keyRejected && !connection.revoked { ProgressView("Loading lists") }
        }
        .task(id: phase) { if phase == .active { await connection.followAccess(client: client) } }
        .task { await refresh() }
        .refreshable { await refresh() }
    }

    private func refresh() async {
        refreshID += 1
        let request = refreshID
        do {
            var result: [WantList] = []
            for id in try await client.writableListIDs() where !connection.removed.contains(id) { result.append(try await client.list(id)) }
            try Task.checkCancellation()
            guard request == refreshID else { return }
            lists = result
            keyRejected = false
            error = nil
        } catch WantError.unauthorized {
            guard request == refreshID, !Task.isCancelled else { return }
            lists = nil
            error = nil
            keyRejected = true
        } catch { if request == refreshID && !Task.isCancelled { self.error = error.localizedDescription } }
    }
}

private struct WantsAccessView<Content: View>: View {
    let listID: String
    let client: WantMCPClient
    @Environment(\.scenePhase) private var phase
    @ObservedObject var connection: MobileWantConnection
    @ViewBuilder var content: () -> Content

    var body: some View {
        if connection.revoked || connection.removed.contains(listID) {
            ContentUnavailableView("Access removed", systemImage: "lock", description: Text("msgblast no longer has access to this list."))
        } else { content().task(id: phase) { if phase == .active { await connection.followAccess(client: client) } } }
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

    let retry: Int
    @State private var imageAttempt = 0

    private struct Lookup: Equatable {
        let id: String
        let count: Int
        let best: String?
        let images: [String?]?
        let retry: Int
    }

    var body: some View {
        Group {
            if let photo {
                AsyncImage(url: photo) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFit().frame(maxWidth: .infinity).frame(height: 108)
                            .background(.white, in: RoundedRectangle(cornerRadius: 12))
                    } else if phase.error != nil {
                        Color.clear.frame(height: 0).onChange(of: retry) { imageAttempt += 1 }
                    }
                }
                .id(imageAttempt)
            } else { Color.clear.frame(height: 0) }
        }
        .task(id: Lookup(id: item.id, count: item.entryCounts.listed, best: item.bestPrice?.entryId,
                         images: item.entries?.map(\.imageUrl), retry: retry)) {
            guard item.entryCounts.listed > 0 else { photo = nil; return }
            let entries: [WantEntry]
            if let included = item.entries { entries = included }
            else if let fetched = try? await client.entries(itemID: item.id) { entries = fetched }
            else { return }
            guard !Task.isCancelled else { return }
            let listed = entries.filter { $0.status == "listed" }
            let best = listed.first { $0.id == item.bestPrice?.entryId }
            photo = WantJSON.webURL(best?.imageUrl) ?? listed.lazy.compactMap { WantJSON.webURL($0.imageUrl) }.first
        }
        .accessibilityHidden(true)
    }
}

private struct WantsListDetail: View {
    @ObservedObject var connection: MobileWantConnection
    let client: WantMCPClient
    @State var list: WantList
    @State private var refreshID = 0
    @State private var comments: [WantComment] = []
    @State private var error: String?

    @State private var galleryRetry = 0
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
        .refreshable {
            galleryRetry += 1
            _ = await refresh()
        }
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
            WantsAccessView(listID: list.id, client: client, connection: connection) {
                WantsItemDetail(client: client, listID: list.id, itemURL: WantJSON.webURL(list.url(for: item)), item: item, format: list.kind)
            }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                if look.template == .gallery && list.kind == .shopping {
                    WantsGalleryPhoto(client: client, item: item, retry: galleryRetry)
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

    @discardableResult private func refresh() async -> Bool {
        refreshID += 1
        let request = refreshID
        do {
            let updated = try await client.list(list.id)
            let notes = try await client.comments(listID: list.id)
            guard request == refreshID, !Task.isCancelled else { return false }
            list = updated
            comments = notes
            error = nil
            return true
        } catch {
            if request == refreshID && !Task.isCancelled { self.error = error.localizedDescription }
            return false
        }
    }
}

private struct WantsItemDetail: View {
    let client: WantMCPClient
    let listID: String
    let itemURL: URL?
    @State var item: WantItem
    let format: WantFormat
    @State private var entries: [WantEntry]?
    @State private var refreshID = 0
    @State private var comments: [WantComment] = []
    @State private var error: String?

    var body: some View {
        List {
            Section {
                Text(item.text).font(.title2.bold()).accessibilityAddTraits(.isHeader)
                if let details = item.details ?? item.detailsPreview, !details.isEmpty { Text(details) }
            }
            if format != .shopping, item.claimedBy != nil || item.statusNote?.isEmpty == false {
                Section(item.isFinished ? format.finished : "Activity") {
                    if let owner = item.claimedBy { Label(owner.label, systemImage: "person") }
                    if let note = item.statusNote, !note.isEmpty { Text(note) }
                }
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
                Section(format == .shopping ? "Products" : format.entries) {
                    ForEach(displayOrder(entries)) { entry in
                        entryRow(entry)
                    }
                }
            }
            if entries == nil && error == nil { ProgressView() }
            if entries?.isEmpty == true && error == nil && item.openQuestion == nil {
                Section {
                    Text(format == .shopping ? "No products yet" : "No \(format.entries.lowercased()) yet").foregroundStyle(.secondary)
                    if let itemURL { WantsBrowserLink(destination: itemURL) { Text("Open item on Wants") } }
                }
            }
            WantsComments(comments: comments.filter { $0.targetId == item.id })
            if let error { Text(error).foregroundStyle(.secondary) }
        }
        .navigationBarTitleDisplayMode(.inline)
        .wantsActivity(client: client, loadOnOpen: true, refresh: refresh)
        .refreshable { await refresh() }
    }

    private func entryRow(_ entry: WantEntry) -> some View {
        let listed = entry.status == "listed"
        return VStack(alignment: .leading, spacing: Space.gap) {
            if format == .shopping {
                if listed, let url = WantJSON.webURL(entry.productUrl) {
                    WantsBrowserLink(destination: url) { entryLabel(entry, linked: true) }.buttonStyle(.plain)
                } else { entryLabel(entry, linked: false) }
            } else {
                writtenEntry(entry)
            }
            ForEach(Array((listed ? entry.links ?? [] : []).enumerated()), id: \.offset) { _, address in
                if let url = WantJSON.webURL(address) {
                    WantsBrowserLink(destination: url) {
                        Label(url.absoluteString.components(separatedBy: "://").dropFirst().joined(separator: "://"),
                              systemImage: "link")
                            .lineLimit(2).frame(minHeight: 44, alignment: .leading)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Open source \(url.absoluteString)")
                }
            }
            ForEach(comments.filter { $0.targetType == "entry" && $0.targetId == entry.id }) {
                WantsCommentRow(comment: $0)
            }
        }
    }

    private func displayOrder(_ entries: [WantEntry]) -> [WantEntry] {
        guard format != .shopping else { return entries }
        let accepted = format == .research ? item.completion?.entryId : nil
        return entries.sorted { left, right in
            if (left.id == accepted) != (right.id == accepted) { return left.id == accepted }
            return left.createdAt == right.createdAt ? left.id < right.id : left.createdAt > right.createdAt
        }
    }

    @ViewBuilder private func writtenEntry(_ entry: WantEntry) -> some View {
        if format == .research && item.completion?.entryId == entry.id {
            Label("Accepted answer", systemImage: "checkmark.circle").font(.caption.bold())
        }
        Text(entry.title)
            .font(format == .research ? .system(.headline, design: .serif) : .headline)
            .accessibilityAddTraits(.isHeader)
        Text("\(entry.author.label) · \(entry.createdAt.formatted(.relative(presentation: .named)))")
            .font(.caption).foregroundStyle(.secondary)
        if let body = entry.description, !body.isEmpty {
            Text(body).font(format == .research ? .system(.body, design: .serif) : .body)
                .textSelection(.enabled)
        }
    }

    private func entryLabel(_ entry: WantEntry, linked: Bool) -> some View {
        HStack(alignment: .top, spacing: Space.inset) {
            offerThumbnail(entry.status == "listed" ? entry.imageUrl : nil)
            VStack(alignment: .leading, spacing: Space.tight) {
                Text(entry.title).font(.headline)
                    .foregroundStyle(linked ? Color.accentColor : Color.primary)
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

    @discardableResult private func refresh() async -> Bool {
        refreshID += 1
        let request = refreshID
        do {
            let updatedEntries = try await client.entries(itemID: item.id)
            let notes = try await client.comments(listID: listID)
            let updated = try await client.list(listID, full: format == .research).items?.first { $0.id == item.id }
            guard request == refreshID, !Task.isCancelled else { return false }
            entries = updatedEntries
            comments = notes
            if let updated { item = updated }
            error = nil
            return true
        } catch {
            if request == refreshID && !Task.isCancelled { self.error = error.localizedDescription }
            return false
        }
    }
}

private struct WantsComments: View {
    let comments: [WantComment]
    var body: some View {
        if !comments.isEmpty {
            Section("Comments") {
                ForEach(comments) { comment in
                    WantsCommentRow(comment: comment)
                }
            }
        }
    }
}

private struct WantsCommentRow: View {
    let comment: WantComment
    var body: some View {
        VStack(alignment: .leading, spacing: Space.tight) {
            Text(comment.author.label).font(.caption).foregroundStyle(.secondary)
            Text(comment.body)
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
    func wantsActivity(client: WantMCPClient, loadOnOpen: Bool = false, refresh: @escaping @MainActor () async -> Bool) -> some View {
        modifier(WantsActivity(client: client, loadOnOpen: loadOnOpen, refresh: refresh))
    }
}

private struct WantsActivity: ViewModifier {
    let client: WantMCPClient
    let loadOnOpen: Bool
    let refresh: @MainActor () async -> Bool
    @Environment(\.scenePhase) private var phase

    func body(content: Content) -> some View {
        content.task(id: phase) {
            guard phase == .active else { return }
            if loadOnOpen { _ = await refresh() }
            var cursor: String?
            var initial = true
            while !Task.isCancelled {
                do {
                    let page = try await client.poll("list.activity", cursor: cursor)
                    try Task.checkCancellation()
                    if initial || page.hasActivity {
                        guard await refresh() else {
                            initial = true
                            try await Task.sleep(for: .seconds(2))
                            continue
                        }
                    }
                    initial = false
                    let advanced = page.cursor != cursor
                    cursor = page.cursor
                    let delay = page.hasMore && advanced ? 0 : min(300, max(2, page.nextPoll ?? 30))
                    try await Task.sleep(for: .seconds(delay))
                } catch {
                    guard !Task.isCancelled else { return }
                    _ = await refresh()
                    try? await Task.sleep(for: .seconds(30))
                }
            }
        }
    }
}
