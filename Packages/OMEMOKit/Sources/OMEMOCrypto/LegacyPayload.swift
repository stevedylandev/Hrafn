import CryptoKit
import Foundation

/// OMEMO 0.3 message payloads (XEP-0384 0.3 §4.5): the body is encrypted once
/// with AES-128-GCM under a fresh key, and that key, followed by the GCM
/// tag, is what each device's ratchet encrypts.
public enum LegacyPayload {
    public struct Sealed: Sendable, Equatable {
        /// `<payload/>`: the ciphertext, without the tag.
        public var payload: Data
        /// `<iv/>`: 12 bytes.
        public var iv: Data
        /// Key (16 bytes) and tag (16 bytes): the plaintext of each `<key/>`.
        public var keyMaterial: Data
    }

    public static func seal(_ plaintext: Data) throws -> Sealed {
        let key = SymmetricKey(size: .bits128)
        let nonce = AES.GCM.Nonce()
        let box = try AES.GCM.seal(plaintext, using: key, nonce: nonce)
        return Sealed(payload: Data(box.ciphertext), iv: Data(nonce),
                      keyMaterial: key.withUnsafeBytes { Data($0) } + Data(box.tag))
    }

    /// Key material is normally key + tag. Older clients sent the 16-byte key
    /// alone with the tag at the end of the payload; that is accepted too.
    /// The IV may be 12 or 16 bytes (older clients used 16).
    public static func open(payload: Data, iv: Data, keyMaterial: Data) throws -> Data {
        let key: Data
        let ciphertext: Data
        let tag: Data
        switch keyMaterial.count {
        case 32...:
            key = keyMaterial.prefix(16)
            tag = keyMaterial.dropFirst(16).prefix(16)
            ciphertext = payload
        case 16:
            guard payload.count >= 16 else { throw OMEMOCryptoError.malformed }
            key = keyMaterial
            tag = payload.suffix(16)
            ciphertext = payload.dropLast(16)
        default:
            throw OMEMOCryptoError.malformed
        }
        guard iv.count == 12 || iv.count == 16 else { throw OMEMOCryptoError.malformed }
        do {
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: iv), ciphertext: ciphertext, tag: tag)
            return try AES.GCM.open(box, using: SymmetricKey(data: key))
        } catch {
            throw OMEMOCryptoError.authenticationFailed
        }
    }
}
