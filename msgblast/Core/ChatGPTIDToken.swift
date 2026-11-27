import Foundation
import Security

/// Verifies the ID token OpenAI returns from a ChatGPT sign-in: its RS256 signature against the
/// published keys, then issuer, audience, expiry and nonce.
public enum ChatGPTIDToken {
    public struct Identity: Equatable, Sendable {
        /// The account's identity for this registration. The email is shown, never matched.
        public var subject: String, email: String?
    }

    public struct Invalid: Error, Equatable { public let reason: String }

    /// One key from a JWKS document. OpenAI signs ID tokens with RS256 only.
    public struct Key: Codable, Sendable {
        public var kty: String
        public var kid: String?, n: String?, e: String?
    }
    public struct KeySet: Codable, Sendable { public var keys: [Key] }

    public static func verify(_ token: String, keys: KeySet, issuer: String, audience: String, nonce: String,
                              now: Date = Date()) throws -> Identity {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, let headerData = decode(parts[0]), let claimsData = decode(parts[1]), let signature = decode(parts[2]),
              let header = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              let claims = try? JSONSerialization.jsonObject(with: claimsData) as? [String: Any] else { throw Invalid(reason: "malformed") }
        let kid = header["kid"] as? String
        let signed = Data("\(parts[0]).\(parts[1])".utf8)
        guard header["alg"] as? String == "RS256",
              keys.keys.contains(where: { (kid == nil || $0.kid == kid) && check(signature, of: signed, key: $0) }) else { throw Invalid(reason: "signature") }
        guard claims["iss"] as? String == issuer else { throw Invalid(reason: "issuer") }
        let audiences = (claims["aud"] as? [String]) ?? [claims["aud"] as? String].compactMap { $0 }
        guard audiences.contains(audience) else { throw Invalid(reason: "audience") }
        guard let expiry = claims["exp"] as? Double, claims["iat"] is Double, Date(timeIntervalSince1970: expiry + 5) > now else { throw Invalid(reason: "expired") }
        guard claims["nonce"] as? String == nonce else { throw Invalid(reason: "nonce") }
        guard let subject = claims["sub"] as? String, !subject.isEmpty else { throw Invalid(reason: "subject") }
        return Identity(subject: subject, email: claims["email"] as? String)
    }

    /// True when the token's `kid` is missing from the set, so the keys may have rotated.
    public static func needsNewKeys(_ token: String, keys: KeySet) -> Bool {
        guard let header = token.split(separator: ".").first.flatMap({ decode(String($0)) }),
              let kid = (try? JSONSerialization.jsonObject(with: header) as? [String: Any])?["kid"] as? String else { return false }
        return !keys.keys.contains { $0.kid == kid }
    }

    static func check(_ signature: Data, of data: Data, key: Key) -> Bool {
        guard key.kty == "RSA", let n = key.n.flatMap(decode), let e = key.e.flatMap(decode),
              let secKey = SecKeyCreateWithData(rsaPublicKey(modulus: n, exponent: e) as CFData,
                                                [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic] as CFDictionary, nil) else { return false }
        return SecKeyVerifySignature(secKey, .rsaSignatureMessagePKCS1v15SHA256, data as CFData, signature as CFData, nil)
    }

    /// PKCS #1 `RSAPublicKey ::= SEQUENCE { modulus INTEGER, publicExponent INTEGER }`.
    static func rsaPublicKey(modulus: Data, exponent: Data) -> Data {
        func integer(_ bytes: Data) -> Data {
            let trimmed = bytes.drop { $0 == 0 }
            let value = (trimmed.first ?? 0) & 0x80 != 0 ? Data([0]) + trimmed : Data(trimmed)
            return Data([0x02]) + length(value.count) + value
        }
        let body = integer(modulus) + integer(exponent)
        return Data([0x30]) + length(body.count) + body
    }

    static func length(_ count: Int) -> Data {
        guard count >= 0x80 else { return Data([UInt8(count)]) }
        let bytes = withUnsafeBytes(of: UInt32(count).bigEndian, Array.init).drop { $0 == 0 }
        return Data([0x80 | UInt8(bytes.count)]) + Data(bytes)
    }

    static func decode(_ text: String) -> Data? {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }
}
