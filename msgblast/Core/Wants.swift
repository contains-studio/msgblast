import Foundation

/// The Want MCP's wire types (wantmcp.com), decoded from tool `structuredContent` with
/// `WantJSON.decoder`. Only the fields msgblast shows or acts on are kept.
public enum WantActor: Codable, Hashable, Sendable {
    case user(handle: String)
    case agent(name: String, ownerHandle: String)
    case outside(name: String?)

    public var label: String {
        switch self {
        case .user(let handle): handle
        case .agent(let name, _): name
        case .outside(let name): name ?? "Outside agent"
        }
    }
    public var isAgent: Bool { if case .agent = self { true } else { false } }

    private enum CodingKeys: String, CodingKey { case kind, handle, name, ownerHandle }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "user": self = .user(handle: try c.decode(String.self, forKey: .handle))
        case "agent": self = .agent(name: try c.decode(String.self, forKey: .name), ownerHandle: try c.decode(String.self, forKey: .ownerHandle))
        default: self = .outside(name: try c.decodeIfPresent(String.self, forKey: .name))
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .user(let handle): try c.encode("user", forKey: .kind); try c.encode(handle, forKey: .handle)
        case .agent(let name, let owner): try c.encode("agent", forKey: .kind); try c.encode(name, forKey: .name); try c.encode(owner, forKey: .ownerHandle)
        case .outside(let name): try c.encode("outside", forKey: .kind); try c.encodeIfPresent(name, forKey: .name)
        }
    }
}

public struct WantPrice: Codable, Hashable, Sendable {
    public var price: String, currency: String, originalPrice: String?, postedBy: WantActor, postedAt: Date
    /// Provenance: only a price read on the retailer's own page is verified. Older servers left these out.
    public var verified: Bool?, checkedAt: Date?
    public var isVerified: Bool { verified == true }
    public var formatted: String { Self.format(price, currency: currency) }
    public var formattedOriginal: String? { originalPrice.flatMap { $0 == price ? nil : Self.format($0, currency: currency) } }

    static func format(_ amount: String, currency: String) -> String {
        let format = NumberFormatter()
        format.numberStyle = .currency
        format.currencyCode = currency
        return Decimal(string: amount).flatMap { format.string(from: NSDecimalNumber(decimal: $0)) } ?? "\(amount) \(currency)"
    }
}

public struct WantEntry: Codable, Hashable, Identifiable, Sendable {
    public var id: String, itemId: String, listId: String, url: String, status: String
    /// `product_url` is null on task and research lists, whose entries carry `links` instead.
    public var author: WantActor, title: String, productUrl: String?, imageUrl: String?, retailer: String
    public var links: [String]?
    public var currentPrice: WantPrice?, createdAt: Date
    public var link: String? { productUrl ?? links?.first }
}

public struct WantItem: Codable, Hashable, Identifiable, Sendable {
    public struct Counts: Codable, Hashable, Sendable { public var listed: Int, suggested: Int }
    public var id: String, text: String
    /// `https://wantmcp.com/l/{list}#itm_...`. Older servers left it out.
    public var url: String?
    public var entryCounts: Counts, commentCount: Int
    /// `open`, `in_progress`, `waiting_on_owner` or `done` on servers with list formats. The compact
    /// `get_list` sends `details_preview` instead of `details`.
    public var details: String?, detailsPreview: String?, status: String?, claimedBy: WantActor?
    /// An agent's question to the person; the item waits on them until it is answered.
    public var openQuestion: WantQuestion?
    /// Only the full `get_list` includes entries; otherwise they come from `get_item_entries`.
    public var entries: [WantEntry]?
}

public struct WantQuestion: Codable, Hashable, Identifiable, Sendable {
    public struct Answer: Codable, Hashable, Sendable { public var text: String }
    public var id: String, text: String, options: [String]?, askedBy: WantActor?, answer: Answer?
}

public struct WantList: Codable, Hashable, Identifiable, Sendable {
    public var id: String, url: String, title: String, ownerHandle: String, itemCount: Int
    public var items: [WantItem]?
    /// `shopping`, `tasks` or `research`, and `public` or `private`. Older servers left them out.
    public var format: String?, visibility: String?
    /// The server's instructions for agents working this list's format.
    public var howToWork: String?
    public var kind: WantFormat { format.flatMap(WantFormat.init(rawValue:)) ?? .shopping }
    /// A private list's links open only for its writers, so they are not for sharing.
    public var isPrivate: Bool { visibility == "private" }

    /// The item's own link, or `{list url}#{item id}` when the server left it out.
    public func url(for item: WantItem) -> String { item.url ?? "\(url)#\(item.id)" }
}

/// What a list is for. Older servers only had shopping lists.
public enum WantFormat: String, Sendable {
    case shopping, tasks, research
    public var item: String { switch self { case .shopping: "Want"; case .tasks: "Task"; case .research: "Question" } }
    public var entries: String { switch self { case .shopping: "Offers"; case .tasks: "Updates"; case .research: "Answers" } }
    public var finished: String { switch self { case .shopping: "Bought"; case .tasks: "Done"; case .research: "Answered" } }
    public static let waiting = "Waiting on you"
}

public struct WantComment: Codable, Hashable, Identifiable, Sendable {
    public var id: String, listId: String, targetType: String, targetId: String, url: String
    public var author: WantActor, body: String, createdAt: Date
}

public struct WantEvent: Codable, Hashable, Sendable {
    public struct ItemRef: Codable, Hashable, Sendable { public var id: String, text: String }
    public var seq: Int, type: String, listId: String, createdAt: Date, url: String, actor: WantActor
    public var item: ItemRef?, entry: WantEntry?, comment: WantComment?
}

public enum WantJSON {
    public static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            let plain = ISO8601DateFormatter(), fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            guard let date = plain.date(from: text) ?? fractional.date(from: text) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not an ISO 8601 date: \(text)"))
            }
            return date
        }
        return decoder
    }
}
