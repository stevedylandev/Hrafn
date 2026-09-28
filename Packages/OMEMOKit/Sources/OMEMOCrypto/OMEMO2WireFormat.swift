import Foundation

// OMEMO 2's messages (XEP-0384 0.8 §7, "Protocol Buffers schemas"), carried
// base64 inside `<key/>` elements. Unlike OMEMO 0.3's there is no version
// byte, keys are the bare 32 bytes, and the MAC is 16 bytes over X3DH's
// associated data and the inner message:
//
//     message OMEMOMessage {
//         required uint32 n = 1;  required uint32 pn = 2;
//         required bytes dh_pub = 3;  optional bytes ciphertext = 4;
//     }
//     message OMEMOAuthenticatedMessage { required bytes mac = 1; required bytes message = 2; }
//     message OMEMOKeyExchange {
//         required uint32 pk_id = 1;  required uint32 spk_id = 2;
//         required bytes ik = 3;  required bytes ek = 4;
//         required OMEMOAuthenticatedMessage message = 5;
//     }

/// `OMEMOAuthenticatedMessage` and the `OMEMOMessage` inside it.
public struct OMEMO2Message: Sendable, Equatable, RatchetMessage {
    static let macLength = 16

    public var ratchetKey: PublicKey
    public var counter: UInt32
    public var previousCounter: UInt32
    public var ciphertext: Data
    /// The serialized `OMEMOMessage`, as the MAC covers it.
    private var body: Data
    private var mac: Data

    init(ratchetKey: PublicKey, counter: UInt32, previousCounter: UInt32, ciphertext: Data,
         macKey: Data, associatedData: Data) {
        var writer = ProtobufWriter()
        writer.varint(1, UInt64(counter))
        writer.varint(2, UInt64(previousCounter))
        writer.bytes(3, ratchetKey.rawRepresentation)
        writer.bytes(4, ciphertext)
        self.ratchetKey = ratchetKey
        self.counter = counter
        self.previousCounter = previousCounter
        self.ciphertext = ciphertext
        body = writer.data
        mac = Self.mac(body, key: macKey, associatedData: associatedData)
    }

    public init(serialized data: Data) throws {
        let outer = try ProtobufReader(Data(data))
        guard let mac = outer.bytes[1], mac.count == Self.macLength, let body = outer.bytes[2] else {
            throw OMEMOCryptoError.malformed
        }
        let fields = try ProtobufReader(body)
        guard let counter = try fields.uint32(1), let previousCounter = try fields.uint32(2),
              let key = fields.bytes[3], key.count == 32 else { throw OMEMOCryptoError.malformed }
        self.ratchetKey = try PublicKey(rawRepresentation: key)
        self.counter = counter
        self.previousCounter = previousCounter
        self.ciphertext = fields.bytes[4] ?? Data()
        self.body = body
        self.mac = mac
    }

    public var serialized: Data {
        var writer = ProtobufWriter()
        writer.bytes(1, mac)
        writer.bytes(2, body)
        return writer.data
    }

    func verifyMAC(key: Data, in state: SessionState) throws {
        guard let associatedData = state.associatedData,
              constantTimeEqual(Self.mac(body, key: key, associatedData: associatedData), mac) else {
            throw OMEMOCryptoError.authenticationFailed
        }
    }

    private static func mac(_ body: Data, key: Data, associatedData: Data) -> Data {
        Data(KDF.hmac(key: key, associatedData + body).prefix(macLength))
    }
}

/// `OMEMOKeyExchange`: the first messages of a session (`kex='true'`).
public struct OMEMO2KeyExchange: Sendable, Equatable {
    public var preKeyID: UInt32
    public var signedPreKeyID: UInt32
    /// The initiator's identity key, Ed25519.
    public var identityKey: Data
    public var baseKey: PublicKey
    public var message: OMEMO2Message

    init(preKeyID: UInt32, signedPreKeyID: UInt32, identityKey: Data, baseKey: PublicKey, message: OMEMO2Message) {
        self.preKeyID = preKeyID
        self.signedPreKeyID = signedPreKeyID
        self.identityKey = identityKey
        self.baseKey = baseKey
        self.message = message
    }

    public init(serialized data: Data) throws {
        let fields = try ProtobufReader(Data(data))
        guard let preKeyID = try fields.uint32(1), let signedPreKeyID = try fields.uint32(2),
              let identityKey = fields.bytes[3], identityKey.count == 32,
              let baseKey = fields.bytes[4], baseKey.count == 32, let message = fields.bytes[5] else {
            throw OMEMOCryptoError.malformed
        }
        self.preKeyID = preKeyID
        self.signedPreKeyID = signedPreKeyID
        self.identityKey = identityKey
        self.baseKey = try PublicKey(rawRepresentation: baseKey)
        self.message = try OMEMO2Message(serialized: message)
    }

    public var serialized: Data {
        var writer = ProtobufWriter()
        writer.varint(1, UInt64(preKeyID))
        writer.varint(2, UInt64(signedPreKeyID))
        writer.bytes(3, identityKey)
        writer.bytes(4, baseKey.rawRepresentation)
        writer.bytes(5, message.serialized)
        return writer.data
    }

    var keyExchange: SessionState.KeyExchange {
        get throws {
            .init(version: .v2, registrationID: 0, preKeyID: preKeyID, signedPreKeyID: signedPreKeyID,
                  baseKey: baseKey, identityKey: try PublicKey(ed25519: identityKey), ed25519IdentityKey: identityKey)
        }
    }
}
