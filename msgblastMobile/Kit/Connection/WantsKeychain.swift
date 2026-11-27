import Foundation
import Security

public enum WantsKeychain {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.msgblast.ios.wants",
         kSecAttrAccount as String: "https://mcp.wantmcp.com/mcp",
         kSecUseDataProtectionKeychain as String: true]
    }

    public static func read() throws -> String? {
        var result: CFTypeRef?
        var lookup = query
        lookup[kSecReturnData as String] = true
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let key = String(data: data, encoding: .utf8) else {
            throw WantError.server("The Wants key could not be read. Unlock your iPhone and try again.")
        }
        return key
    }

    public static func save(_ key: String) throws {
        var item = query
        item[kSecValueData as String] = Data(key.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
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
