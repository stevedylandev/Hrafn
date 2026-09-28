import Foundation

/// OMEMO 2 payloads (XEP-0384 0.8 §6.1): the XEP-0420 envelope encrypted
/// once under a fresh 32-byte key, expanded by HKDF-SHA-256 (info "OMEMO
/// Payload") into an AES-256-CBC key, an HMAC-SHA-256 key and an IV. The key
/// followed by the 16-byte truncated HMAC of the ciphertext is what each
/// device's ratchet encrypts.
public enum OMEMO2Payload {
    public struct Sealed: Sendable, Equatable {
        /// `<payload/>`: the ciphertext.
        public var payload: Data
        /// Key (32 bytes) and truncated HMAC (16 bytes).
        public var keyMaterial: Data
    }

    /// What an empty message's ratchet encrypts in place of key material:
    /// 32 zero bytes (§6.1, messages without payload).
    public static let emptyKeyMaterial = Data(count: 32)

    public static func seal(_ plaintext: Data) throws -> Sealed {
        let key = Data.random(count: 32)
        let keys = expand(key)
        let ciphertext = try AESCBC.encrypt(plaintext, key: keys.cipher, iv: keys.iv)
        return Sealed(payload: ciphertext, keyMaterial: key + KDF.hmac(key: keys.mac, ciphertext).prefix(16))
    }

    public static func open(payload: Data, keyMaterial: Data) throws -> Data {
        guard keyMaterial.count == 48 else { throw OMEMOCryptoError.malformed }
        let keys = expand(Data(keyMaterial.prefix(32)))
        guard constantTimeEqual(Data(KDF.hmac(key: keys.mac, payload).prefix(16)), Data(keyMaterial.suffix(16))) else {
            throw OMEMOCryptoError.authenticationFailed
        }
        return try AESCBC.decrypt(payload, key: keys.cipher, iv: keys.iv)
    }

    private static func expand(_ key: Data) -> (cipher: Data, mac: Data, iv: Data) {
        let material = KDF.hkdf(key, info: "OMEMO Payload", count: 80)
        return (Data(material.prefix(32)), Data(material.dropFirst(32).prefix(32)), Data(material.suffix(16)))
    }
}
