import Foundation

// OMEMO 0.3 (XEP-0384 version 0.3.0, `eu.siacs.conversations.axolotl`) carries
// the Signal protocol's own messages inside `<key/>` elements, and the XEP
// does not restate their format. What follows is the published wire format of
// version 3 of those messages. Interoperability with other 0.3 clients is the
// test of it; see docs/OMEMO.md.

/// The ratchet message: one message key's worth of ciphertext.
///
///     version (1 byte: current << 4 | minimum, both 3)
///     protobuf { 1: ratchetKey (33 bytes), 2: counter, 3: previousCounter, 4: ciphertext }
///     MAC (8 bytes: HMAC-SHA-256, truncated)
public struct LegacySignalMessage: Sendable, Equatable {
    static let version: UInt8 = 3 << 4 | 3
    static let macLength = 8

    public var ratchetKey: PublicKey
    public var counter: UInt32
    public var previousCounter: UInt32
    public var ciphertext: Data
    /// The whole message as sent: version, protobuf and MAC.
    public private(set) var serialized: Data

    /// Builds and authenticates a message. The MAC covers both identities,
    /// sender first, then the version byte and protobuf.
    init(ratchetKey: PublicKey, counter: UInt32, previousCounter: UInt32, ciphertext: Data,
         macKey: Data, sender: PublicKey, receiver: PublicKey) {
        var writer = ProtobufWriter()
        writer.bytes(1, ratchetKey.serialized)
        writer.varint(2, UInt64(counter))
        writer.varint(3, UInt64(previousCounter))
        writer.bytes(4, ciphertext)
        let body = Data([Self.version]) + writer.data
        self.ratchetKey = ratchetKey
        self.counter = counter
        self.previousCounter = previousCounter
        self.ciphertext = ciphertext
        self.serialized = body + Self.mac(body, key: macKey, sender: sender, receiver: receiver)
    }

    public init(serialized data: Data) throws {
        let data = Data(data)
        guard data.count > 1 + Self.macLength, let version = data.first else { throw OMEMOCryptoError.malformed }
        // Version 3 only: the high nibble is the sender's version.
        guard version >> 4 == 3 else { throw OMEMOCryptoError.malformed }
        let fields = try ProtobufReader(data.dropFirst().dropLast(Self.macLength))
        guard let key = fields.bytes[1], let counter = try fields.uint32(2),
              let ciphertext = fields.bytes[4] else { throw OMEMOCryptoError.malformed }
        self.ratchetKey = try PublicKey(serialized: key)
        self.counter = counter
        self.previousCounter = try fields.uint32(3) ?? 0
        self.ciphertext = ciphertext
        self.serialized = data
    }

    func verifyMAC(key: Data, sender: PublicKey, receiver: PublicKey) throws {
        let body = serialized.dropLast(Self.macLength)
        let expected = Self.mac(Data(body), key: key, sender: sender, receiver: receiver)
        guard constantTimeEqual(expected, serialized.suffix(Self.macLength)) else {
            throw OMEMOCryptoError.authenticationFailed
        }
    }

    private static func mac(_ body: Data, key: Data, sender: PublicKey, receiver: PublicKey) -> Data {
        Data(KDF.hmac(key: key, sender.serialized + receiver.serialized + body).prefix(macLength))
    }
}

/// The first messages of a session, which carry what the receiver needs to
/// complete X3DH (`prekey='true'` on the `<key/>` element).
///
///     version (1 byte)
///     protobuf { 5: registrationId, 1: preKeyId, 6: signedPreKeyId, 2: baseKey,
///                3: identityKey, 4: message (a serialized LegacySignalMessage) }
public struct LegacyPreKeySignalMessage: Sendable, Equatable {
    /// OMEMO 0.3 uses the device id as the registration id.
    public var registrationID: UInt32
    public var preKeyID: UInt32?
    public var signedPreKeyID: UInt32
    public var baseKey: PublicKey
    public var identityKey: PublicKey
    public var message: LegacySignalMessage

    init(registrationID: UInt32, preKeyID: UInt32?, signedPreKeyID: UInt32, baseKey: PublicKey,
         identityKey: PublicKey, message: LegacySignalMessage) {
        self.registrationID = registrationID
        self.preKeyID = preKeyID
        self.signedPreKeyID = signedPreKeyID
        self.baseKey = baseKey
        self.identityKey = identityKey
        self.message = message
    }

    public init(serialized data: Data) throws {
        let data = Data(data)
        guard let version = data.first, version >> 4 == 3 else { throw OMEMOCryptoError.malformed }
        let fields = try ProtobufReader(data.dropFirst())
        guard let signedPreKeyID = try fields.uint32(6), let baseKey = fields.bytes[2],
              let identityKey = fields.bytes[3], let message = fields.bytes[4] else {
            throw OMEMOCryptoError.malformed
        }
        self.registrationID = try fields.uint32(5) ?? 0
        self.preKeyID = try fields.uint32(1)
        self.signedPreKeyID = signedPreKeyID
        self.baseKey = try PublicKey(serialized: baseKey)
        self.identityKey = try PublicKey(serialized: identityKey)
        self.message = try LegacySignalMessage(serialized: message)
    }

    public var serialized: Data {
        var writer = ProtobufWriter()
        writer.varint(5, UInt64(registrationID))
        if let preKeyID { writer.varint(1, UInt64(preKeyID)) }
        writer.varint(6, UInt64(signedPreKeyID))
        writer.bytes(2, baseKey.serialized)
        writer.bytes(3, identityKey.serialized)
        writer.bytes(4, message.serialized)
        return Data([LegacySignalMessage.version]) + writer.data
    }
}

extension LegacySignalMessage: RatchetMessage {
    /// Signal's MAC binds the direction: sender's identity, then receiver's.
    func verifyMAC(key: Data, in state: SessionState) throws {
        try verifyMAC(key: key, sender: state.remoteIdentity, receiver: state.localIdentity)
    }
}

extension LegacyPreKeySignalMessage {
    var keyExchange: SessionState.KeyExchange {
        .init(version: .legacy, registrationID: registrationID, preKeyID: preKeyID, signedPreKeyID: signedPreKeyID,
              baseKey: baseKey, identityKey: identityKey)
    }
}

func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
    guard a.count == b.count else { return false }
    var difference: UInt8 = 0
    for (x, y) in zip(a, b) { difference |= x ^ y }
    return difference == 0
}
