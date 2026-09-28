import Clibsodium
import CryptoKit
import Foundation

/// A Curve25519 (X25519) public key. OMEMO 0.3 serializes these the way the
/// Signal protocol does: a type byte `0x05` ("DJB") followed by the 32-byte
/// Montgomery u-coordinate.
public struct PublicKey: Sendable, Hashable, Codable {
    static let djbType: UInt8 = 0x05

    /// The 32-byte u-coordinate.
    public let rawRepresentation: Data

    public init(rawRepresentation: Data) throws {
        guard rawRepresentation.count == 32 else { throw OMEMOCryptoError.malformed }
        self.rawRepresentation = Data(rawRepresentation)
    }

    /// Accepts the 33-byte serialized form. The bare 32 bytes are accepted
    /// too: some clients publish bundle keys without the type byte.
    public init(serialized data: Data) throws {
        let bytes = Data(data)
        if bytes.count == 33, bytes.first == Self.djbType {
            try self.init(rawRepresentation: bytes.dropFirst())
        } else if bytes.count == 32 {
            try self.init(rawRepresentation: bytes)
        } else {
            throw OMEMOCryptoError.malformed
        }
    }

    public var serialized: Data { Data([Self.djbType]) + rawRepresentation }

    /// The fingerprint users compare: the serialized key's bytes as lowercase
    /// hex, without the type byte, in groups of eight.
    public var fingerprint: String {
        let hex = rawRepresentation.map { String(format: "%02x", $0) }.joined()
        return stride(from: 0, to: hex.count, by: 8).map { offset in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            return String(hex[start..<hex.index(start, offsetBy: 8)])
        }.joined(separator: " ")
    }
}

/// An X25519 key pair. The private key is kept as its 32 raw bytes, the form
/// CryptoKit takes and returns; clamping happens inside the primitives.
public struct KeyPair: Sendable, Codable {
    public let privateKey: Data
    public let publicKey: PublicKey

    public static func generate() -> KeyPair {
        // Cannot fail: a fresh CryptoKit key always has 32 raw bytes.
        try! KeyPair(privateKey: Curve25519.KeyAgreement.PrivateKey().rawRepresentation)
    }

    public init(privateKey: Data) throws {
        let key = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKey)
        self.privateKey = key.rawRepresentation
        self.publicKey = try PublicKey(rawRepresentation: key.publicKey.rawRepresentation)
    }

    /// X25519. CryptoKit refuses low-order points, whose shared secret
    /// would be all zeros.
    func agreement(with other: PublicKey) throws -> Data {
        do {
            let ours = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKey)
            let theirs = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: other.rawRepresentation)
            return try ours.sharedSecretFromKeyAgreement(with: theirs).withUnsafeBytes { Data($0) }
        } catch {
            throw OMEMOCryptoError.malformed
        }
    }

    /// XEdDSA signature (see `XEdDSA`), as OMEMO 0.3 signs its signed pre-key.
    public func sign(_ message: Data) throws -> Data {
        try XEdDSA.sign(message, privateKey: privateKey)
    }
}

extension PublicKey {
    public func isValidSignature(_ signature: Data, for message: Data) -> Bool {
        XEdDSA.verify(signature, for: message, publicKey: rawRepresentation)
    }
}

// MARK: - Ed25519 form (OMEMO 2)

extension PublicKey {
    /// OMEMO 2 publishes identity keys as Ed25519 keys. This is the X25519
    /// key they are used as in X3DH: u = (1 + y) / (1 − y) (RFC 7748 §4.1).
    /// Both Edwards points with that y give the same u, so the sign bit is
    /// lost; the Ed25519 form is kept alongside where it matters.
    public init(ed25519 key: Data) throws {
        try Sodium.ensureReady()
        guard key.count == 32 else { throw OMEMOCryptoError.malformed }
        var u = [UInt8](repeating: 0, count: 32)
        guard crypto_sign_ed25519_pk_to_curve25519(&u, [UInt8](key)) == 0 else { throw OMEMOCryptoError.malformed }
        try self.init(rawRepresentation: Data(u))
    }

    /// The Ed25519 key that XEdDSA signatures by this key verify under: the
    /// Edwards point for u with sign bit 0 (XEdDSA §4.1). This device's
    /// identity is published in this form for OMEMO 2, so one identity
    /// serves both versions.
    public func ed25519() throws -> Data {
        guard let u = Field25519(bytes: rawRepresentation),
              let y = XEdDSA.edwardsPoint(fromMontgomery: u) else { throw OMEMOCryptoError.malformed }
        return Data(y)
    }
}

enum Ed25519 {
    /// RFC 8032 verification (libsodium's, which also refuses non-canonical
    /// and small-order encodings).
    static func verify(_ signature: Data, for message: Data, publicKey: Data) -> Bool {
        guard Sodium.isReady, signature.count == 64, publicKey.count == 32 else { return false }
        return crypto_sign_verify_detached([UInt8](signature), [UInt8](message), UInt64(message.count),
                                           [UInt8](publicKey)) == 0
    }
}
