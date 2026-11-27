import Foundation
import Security

public enum WantsKeychain {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.msgblast.ios.wants",
         kSecAttrAccount as String: "https://mcp.wantmcp.com/mcp",
         kSecUseDataProtectionKeychain as String: true]
    }

    public static func read() throws -> WantCredential? {
        var result: CFTypeRef?
        var lookup = query
        lookup[kSecReturnData as String] = true
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw WantError.server("The Wants key could not be read. Unlock your iPhone and try again.")
        }
        if let grant = WantCredential.restore(data, for: WantOAuth.resource) { return grant }
        if let text = String(data: data, encoding: .utf8), let legacy = WantCredential.writeKey(text) { return legacy }
        throw WantError.invalidResponse
    }

    public static func save(_ grant: WantCredential) throws {
        var bound = grant
        bound.endpoint = WantOAuth.resource
        let data = try JSONEncoder().encode(bound)
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        var status = SecItemAdd(item as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let change = [kSecValueData as String: data]
            status = SecItemUpdate(query as CFDictionary, change as CFDictionary)
        }
        guard status == errSecSuccess else {
            throw WantError.server("The Wants key could not be saved.")
        }
    }

    public static func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard [errSecSuccess, errSecItemNotFound].contains(status) else {
            throw WantError.server("The Wants key could not be removed.")
        }
    }
}

@MainActor public final class MobileWantConnection {
    public let id = UUID()
    public private(set) var grant: WantCredential
    private var refreshing: Task<String, Error>?

    public init(_ grant: WantCredential) { self.grant = grant }

    public func token() async throws -> String {
        guard grant.refreshToken != nil, let expiry = grant.expiresAt,
              expiry <= Date().addingTimeInterval(60) else { return grant.accessToken }
        return try await refresh()
    }

    public func refresh() async throws -> String {
        if let refreshing { return try await refreshing.value }
        let previous = grant
        let task = Task {
            var next = try await WantOAuth.refresh(previous, resource: WantOAuth.resource)
            guard try WantsKeychain.read()?.accessToken == previous.accessToken else { throw CancellationError() }
            next.grantID = previous.grantID
            try WantsKeychain.save(next)
            grant = next
            return next.accessToken
        }
        refreshing = task
        defer { refreshing = nil }
        return try await task.value
    }
}
