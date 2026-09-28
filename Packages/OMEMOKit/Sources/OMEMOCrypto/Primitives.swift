import Clibsodium
import CommonCrypto
import CryptoKit
import Foundation

/// Errors from the cryptographic layer. Deliberately coarse: a peer learns
/// nothing from which check failed, and neither does the log.
public enum OMEMOCryptoError: Error, Sendable, Equatable {
    /// A key, signature or message has the wrong size or an invalid encoding.
    case malformed
    /// A signature, MAC or authentication tag did not verify.
    case authenticationFailed
    /// The message is older than the session (already decrypted or its keys
    /// were discarded), or too far ahead of it.
    case messageOutOfRange
    /// A pre-key message names a pre-key this device no longer has.
    case unknownPreKey
    /// A message arrived for a session that does not exist.
    case noSession
    /// A primitive failed (random numbers, libsodium initialisation).
    case internalFailure
}

enum Sodium {
    /// `sodium_init()` is idempotent and thread-safe; call it before any use.
    static let isReady: Bool = sodium_init() >= 0

    static func ensureReady() throws {
        guard isReady else { throw OMEMOCryptoError.internalFailure }
    }
}

extension Data {
    static func random(count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        return Data(bytes)
    }
}

enum KDF {
    /// RFC 5869 HKDF with SHA-256. An absent salt is 32 zero bytes (§2.2).
    static func hkdf(_ ikm: Data, salt: Data = Data(count: 32), info: String, count: Int) -> Data {
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: ikm), salt: salt,
                                         info: Data(info.utf8), outputByteCount: count)
        return key.withUnsafeBytes { Data($0) }
    }

    static func hmac(key: Data, _ message: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key)))
    }
}

enum AESCBC {
    /// AES-256-CBC with PKCS#7 padding, which the ratchet's message keys use.
    static func encrypt(_ plaintext: Data, key: Data, iv: Data) throws -> Data {
        try crypt(CCOperation(kCCEncrypt), plaintext, key: key, iv: iv)
    }

    static func decrypt(_ ciphertext: Data, key: Data, iv: Data) throws -> Data {
        try crypt(CCOperation(kCCDecrypt), ciphertext, key: key, iv: iv)
    }

    private static func crypt(_ operation: CCOperation, _ input: Data, key: Data, iv: Data) throws -> Data {
        guard key.count == kCCKeySizeAES256, iv.count == kCCBlockSizeAES128 else { throw OMEMOCryptoError.malformed }
        var output = Data(count: input.count + kCCBlockSizeAES128)
        let capacity = output.count
        var moved = 0
        let status = output.withUnsafeMutableBytes { out in
            input.withUnsafeBytes { inp in
                key.withUnsafeBytes { k in
                    iv.withUnsafeBytes { v in
                        CCCrypt(operation, CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                k.baseAddress, key.count, v.baseAddress,
                                inp.baseAddress, input.count, out.baseAddress, capacity, &moved)
                    }
                }
            }
        }
        // A padding error on decryption is reported like any other failure;
        // the MAC was checked first, so it cannot serve as a padding oracle.
        guard status == kCCSuccess else { throw OMEMOCryptoError.authenticationFailed }
        return Data(output.prefix(moved))
    }
}
