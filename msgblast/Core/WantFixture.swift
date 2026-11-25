import Foundation

/// Sample want lists for Demo and previews. Never contacts the network. Once `activityDelay` has
/// passed it delivers one comment and one outside suggestion, so forwarding can be shown.
public actor WantFixture: WantService {
    private var lists: [WantList]
    private var comments: [WantComment]
    private var pending: [WantEvent] = []
    private var suggested: [WantEntry] = []
    private var seq = 100
    private let activityAt: Date

    public init(now: Date = Date(), activityDelay: TimeInterval = 0) {
        activityAt = now.addingTimeInterval(activityDelay)
        let me = WantActor.user(handle: "quiet-otter-4821")
        func ago(_ hours: Double) -> Date { now.addingTimeInterval(-hours * 3600) }
        func price(_ value: String, _ by: WantActor, _ hours: Double, was: String? = nil) -> WantPrice {
            WantPrice(price: value, currency: "USD", originalPrice: was, postedBy: by, postedAt: ago(hours))
        }
        func entry(_ id: String, _ item: String, _ title: String, _ retailer: String, _ author: WantActor, _ p: WantPrice, _ hours: Double) -> WantEntry {
            WantEntry(id: id, itemId: item, listId: "lst_demo", url: "https://wantmcp.com/l/lst_demo#\(id)", status: "listed", author: author, title: title,
                      productUrl: "https://example.com/\(id)", imageUrl: nil, retailer: retailer, currentPrice: p, createdAt: ago(hours))
        }
        let claude = WantActor.agent(name: "Claude", ownerHandle: "quiet-otter-4821"), codex = WantActor.agent(name: "Codex", ownerHandle: "quiet-otter-4821")
        let headphones = WantItem(id: "itm_headphones", listId: "lst_demo", text: "Noise-cancelling headphones for flights, under $300", createdBy: me,
                                  createdAt: ago(30), entryCounts: .init(listed: 2, suggested: 0), commentCount: 1, entries: [
            entry("ent_1", "itm_headphones", "Over-ear ANC headphones, 2026 model", "Example Electronics", claude, price("249.00", claude, 2, was: "329.00"), 20),
            entry("ent_2", "itm_headphones", "Travel ANC headphones with case", "Sample Outlet", codex, price("279.99", codex, 5), 6),
        ])
        let kettle = WantItem(id: "itm_kettle", listId: "lst_demo", text: "A gooseneck kettle with temperature control", createdBy: me,
                              createdAt: ago(10), entryCounts: .init(listed: 0, suggested: 0), commentCount: 0, entries: [])
        let van = WantItem(id: "itm_van", listId: "lst_move", text: "Book a van for moving day", createdBy: me, createdAt: ago(8),
                           entryCounts: .init(listed: 1, suggested: 0), commentCount: 0, details: "Saturday 6 Dec, 8am pickup.", status: "in_progress", claimedBy: codex, entries: [
            WantEntry(id: "ent_4", itemId: "itm_van", listId: "lst_move", url: "https://wantmcp.com/l/lst_move#ent_4", status: "listed", author: codex,
                      title: "Three quotes, cheapest is £145", productUrl: nil, imageUrl: nil, retailer: "", links: ["https://example.com/vans"], currentPrice: nil, createdAt: ago(1)),
        ])
        lists = [WantList(id: "lst_demo", url: "https://wantmcp.com/l/lst_demo", title: "Holiday wants", ownerHandle: "quiet-otter-4821", itemCount: 2, items: [headphones, kettle]),
                 WantList(id: "lst_move", url: "https://wantmcp.com/l/lst_move", title: "Flat move", ownerHandle: "quiet-otter-4821", itemCount: 1, items: [van],
                          format: "tasks", visibility: "private")]
        comments = [WantComment(id: "cmt_1", listId: "lst_demo", targetType: "item", targetId: "itm_headphones", url: "https://wantmcp.com/l/lst_demo#cmt_1",
                                author: .user(handle: "bright-fox-1180"), body: "Check the open-box price too.", createdAt: ago(3))]
        let reply = WantComment(id: "cmt_2", listId: "lst_demo", targetType: "item", targetId: "itm_headphones", url: "https://wantmcp.com/l/lst_demo#cmt_2",
                                author: .user(handle: "bright-fox-1180"), body: "Does either one fold flat?", createdAt: now)
        let suggestion = WantEntry(id: "ent_3", itemId: "itm_kettle", listId: "lst_demo", url: "https://wantmcp.com/l/lst_demo#ent_3", status: "suggested",
                                   author: .outside(name: "ShopBot"), title: "Gooseneck kettle, 0.9 L", productUrl: "https://example.com/ent_3", imageUrl: nil,
                                   retailer: "Example Home", currentPrice: price("59.00", .outside(name: "ShopBot"), 0), createdAt: now)
        pending = [
            WantEvent(seq: 101, type: "comment.created", listId: "lst_demo", createdAt: now, url: reply.url, actor: reply.author,
                      item: .init(id: headphones.id, text: headphones.text), comment: reply),
            WantEvent(seq: 102, type: "entry.suggested", listId: "lst_demo", createdAt: now, url: suggestion.url, actor: suggestion.author,
                      item: .init(id: kettle.id, text: kettle.text), entry: suggestion),
        ]
        comments.append(reply)
    }

    public func writableListIDs() -> [String] { lists.map(\.id) }
    public func list(_ id: String) throws -> WantList {
        guard let list = lists.first(where: { $0.id == id }) else { throw WantError.server("List not found") }
        return list
    }
    public func comments(listID: String) -> [WantComment] { comments.filter { comment in comment.listId == listID && pending.allSatisfy { $0.comment?.id != comment.id } } }
    public func suggestions(listID: String) -> [WantEntry] { suggested.filter { $0.listId == listID } }
    public func addItem(listID: String, text: String) throws -> WantItem {
        guard let index = lists.firstIndex(where: { $0.id == listID }) else { throw WantError.server("List not found") }
        seq += 1
        let item = WantItem(id: "itm_\(seq)", listId: listID, text: text, createdBy: .agent(name: "msgblast", ownerHandle: lists[index].ownerHandle),
                            createdAt: Date(), entryCounts: .init(listed: 0, suggested: 0), commentCount: 0, entries: [])
        lists[index].items = (lists[index].items ?? []) + [item]
        lists[index].itemCount += 1
        return item
    }
    public func poll(_ type: String, cursor: String?) -> WantEventPage {
        guard let cursor, Date() >= activityAt else { return WantEventPage(events: [], cursor: cursor ?? "0", nextPoll: 5) }
        let after = Int(cursor) ?? 0
        let matches = { (event: WantEvent) in type == "list.activity" || event.type == type }
        let events = pending.filter { matches($0) && $0.seq > after }
        pending.removeAll(where: matches)
        suggested += events.filter { $0.type == "entry.suggested" }.compactMap(\.entry)
        return WantEventPage(events: events, cursor: String(events.map(\.seq).max() ?? after), nextPoll: 5)
    }
}
