import Security
import XCTest
@testable import msgblastCore

/// An RSA key made for the test, standing in for OpenAI's signing key.
struct ChatGPTFixtureKey {
    let key = SecKeyCreateRandomKey([kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048] as CFDictionary, nil)!

    /// The public key as a JWKS entry. PKCS #1 is SEQUENCE { INTEGER n, INTEGER e }.
    var jwk: [String: String] {
        let der = [UInt8](SecKeyCopyExternalRepresentation(SecKeyCopyPublicKey(key)!, nil)! as Data)
        func read(_ at: Int) -> (start: Int, end: Int) {
            guard der[at + 1] & 0x80 != 0 else { return (at + 2, at + 2 + Int(der[at + 1])) }
            let count = Int(der[at + 1] & 0x7f), length = der[(at + 2)..<(at + 2 + count)].reduce(0) { $0 << 8 | Int($1) }
            return (at + 2 + count, at + 2 + count + length)
        }
        let n = read(read(0).start), e = read(n.end)
        return ["kid": "test", "kty": "RSA", "n": WantOAuth.base64URL(Data(der[n.start..<n.end])), "e": WantOAuth.base64URL(Data(der[e.start..<e.end]))]
    }

    var keySet: ChatGPTIDToken.KeySet { try! JSONDecoder().decode(ChatGPTIDToken.KeySet.self, from: JSONSerialization.data(withJSONObject: ["keys": [jwk]])) }

    func sign(_ claims: [String: Any], kid: String = "test") -> String {
        let input = [["alg": "RS256", "kid": kid], claims].map { WantOAuth.base64URL(try! JSONSerialization.data(withJSONObject: $0)) }.joined(separator: ".")
        let signature = SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, Data(input.utf8) as CFData, nil)! as Data
        return input + "." + WantOAuth.base64URL(signature)
    }

    static func claims(audience: String, nonce: String, at date: Date, subject: String = "user-1") -> [String: Any] {
        ["iss": "https://auth.openai.com", "aud": audience, "sub": subject, "nonce": nonce, "email": "person@example.com",
         "iat": date.timeIntervalSince1970, "exp": date.timeIntervalSince1970 + 3600]
    }
}

final class ChatGPTIDTokenTests: XCTestCase {
    private let fixture = ChatGPTFixtureKey()
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    private func verify(_ token: String) throws -> ChatGPTIDToken.Identity {
        try ChatGPTIDToken.verify(token, keys: fixture.keySet, issuer: "https://auth.openai.com", audience: "oaiapp_1", nonce: "n1", now: now)
    }

    func testAcceptsASignedTokenForThisSignIn() throws {
        let identity = try verify(fixture.sign(ChatGPTFixtureKey.claims(audience: "oaiapp_1", nonce: "n1", at: now)))
        XCTAssertEqual(identity, .init(subject: "user-1", email: "person@example.com"))
    }

    func testRejectsWrongClaimsAndSignatures() {
        let good = ChatGPTFixtureKey.claims(audience: "oaiapp_1", nonce: "n1", at: now)
        let cases: [(String, String)] = [
            (fixture.sign(good.merging(["nonce": "other"]) { $1 }), "nonce"),
            (fixture.sign(good.merging(["aud": "oaiapp_2"]) { $1 }), "audience"),
            (fixture.sign(good.merging(["iss": "https://example.com"]) { $1 }), "issuer"),
            (fixture.sign(good.merging(["exp": now.timeIntervalSince1970 - 10]) { $1 }), "expired"),
            (fixture.sign(good.merging(["sub": ""]) { $1 }), "subject"),
            (ChatGPTFixtureKey().sign(good), "signature"),
            (fixture.sign(good, kid: "rotated"), "signature"),
        ]
        for (token, reason) in cases {
            XCTAssertThrowsError(try verify(token), reason) { XCTAssertEqual($0 as? ChatGPTIDToken.Invalid, .init(reason: reason)) }
        }
        let real = fixture.sign(good).split(separator: "."), forged = fixture.sign(good.merging(["sub": "someone-else"]) { $1 }).split(separator: ".")
        XCTAssertThrowsError(try verify([forged[0], forged[1], real[2]].joined(separator: ".")))
    }

    func testAnUnknownKeyIDAsksForNewKeys() {
        let claims = ChatGPTFixtureKey.claims(audience: "oaiapp_1", nonce: "n1", at: now)
        XCTAssertTrue(ChatGPTIDToken.needsNewKeys(fixture.sign(claims, kid: "rotated"), keys: fixture.keySet))
        XCTAssertFalse(ChatGPTIDToken.needsNewKeys(fixture.sign(claims), keys: fixture.keySet))
    }
}
