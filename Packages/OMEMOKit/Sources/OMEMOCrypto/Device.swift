import Foundation

/// A signed pre-key: the medium-term key of X3DH, signed by the identity key
/// and replaced from time to time.
public struct SignedPreKey: Sendable, Codable {
    public let id: UInt32
    public let keyPair: KeyPair
    /// XEdDSA signature, by the identity key, of the serialized public key
    /// (OMEMO 0.3: type byte and all).
    public let signature: Data
    public let created: Date
    /// The same over the bare 32-byte key, as OMEMO 2 signs it. Absent from
    /// keys stored before OMEMO 2; `LocalDevice` adds it when loading.
    public internal(set) var rawKeySignature: Data?
}

/// What another device publishes so a session can be started with it
/// (XEP-0384 0.3 §4.3, 0.8 §5.3.2 bundles), already decoded from XML.
public struct PreKeyBundle: Sendable, Equatable {
    public var version: OMEMOVersion
    public var deviceID: UInt32
    /// As an X25519 key, whichever form was published: what X3DH uses, and
    /// what trust decisions are about.
    public var identityKey: PublicKey
    /// OMEMO 2: the identity key as published, an Ed25519 key.
    public var ed25519IdentityKey: Data?
    public var signedPreKeyID: UInt32
    public var signedPreKey: PublicKey
    public var signedPreKeySignature: Data
    public var preKeys: [UInt32: PublicKey]

    public init(deviceID: UInt32, identityKey: PublicKey, signedPreKeyID: UInt32, signedPreKey: PublicKey,
                signedPreKeySignature: Data, preKeys: [UInt32: PublicKey]) {
        self.version = .legacy
        self.deviceID = deviceID
        self.identityKey = identityKey
        self.signedPreKeyID = signedPreKeyID
        self.signedPreKey = signedPreKey
        self.signedPreKeySignature = signedPreKeySignature
        self.preKeys = preKeys
    }

    /// An OMEMO 2 bundle, whose identity key is an Ed25519 key.
    public init(deviceID: UInt32, ed25519IdentityKey: Data, signedPreKeyID: UInt32, signedPreKey: PublicKey,
                signedPreKeySignature: Data, preKeys: [UInt32: PublicKey]) throws {
        self.init(deviceID: deviceID, identityKey: try PublicKey(ed25519: ed25519IdentityKey),
                  signedPreKeyID: signedPreKeyID, signedPreKey: signedPreKey,
                  signedPreKeySignature: signedPreKeySignature, preKeys: preKeys)
        self.version = .v2
        self.ed25519IdentityKey = Data(ed25519IdentityKey)
    }

    /// The signed pre-key must be signed by the identity key; a bundle that
    /// fails this is never used. OMEMO 0.3 signs the serialized key with
    /// XEdDSA; OMEMO 2 the bare key with Ed25519.
    public var isSignatureValid: Bool {
        switch version {
        case .legacy:
            identityKey.isValidSignature(signedPreKeySignature, for: signedPreKey.serialized)
        case .v2:
            ed25519IdentityKey.map { Ed25519.verify(signedPreKeySignature, for: signedPreKey.rawRepresentation,
                                                    publicKey: $0) } ?? false
        }
    }
}

/// This device's keys: its identity, the current signed pre-key (and recent
/// ones, for messages already in flight), and the one-time pre-keys.
public struct LocalDevice: Sendable, Codable {
    /// XEP-0384 0.3 recommends 100 pre-keys (§4.3: "at least 20").
    public static let preKeyTarget = 100
    /// Replaced signed pre-keys are kept this long, then forgotten.
    public static let signedPreKeyRetention: TimeInterval = 30 * 24 * 60 * 60

    public let deviceID: UInt32
    public let identity: KeyPair
    public private(set) var signedPreKey: SignedPreKey
    public private(set) var previousSignedPreKeys: [SignedPreKey] = []
    public private(set) var preKeys: [UInt32: KeyPair] = [:]
    private var nextPreKeyID: UInt32 = 1

    /// A new device: fresh identity, signed pre-key and pre-keys. Device ids
    /// are random in 1...2^31 − 1 (§4.2).
    public static func generate(deviceID: UInt32 = .random(in: 1...0x7FFF_FFFF), now: Date = Date()) throws -> LocalDevice {
        let identity = KeyPair.generate()
        var device = LocalDevice(deviceID: deviceID, identity: identity,
                                 signedPreKey: try Self.makeSignedPreKey(id: 1, identity: identity, now: now))
        device.refillPreKeys()
        return device
    }

    private init(deviceID: UInt32, identity: KeyPair, signedPreKey: SignedPreKey) {
        self.deviceID = deviceID
        self.identity = identity
        self.signedPreKey = signedPreKey
    }

    /// The OMEMO 0.3 bundle.
    public var bundle: PreKeyBundle { bundle(for: .legacy) }

    /// The bundle to publish for `version`. Both carry the same keys; OMEMO 2
    /// gives the identity in its Ed25519 form and signs the bare pre-key.
    public func bundle(for version: OMEMOVersion) -> PreKeyBundle {
        var bundle = PreKeyBundle(deviceID: deviceID, identityKey: identity.publicKey, signedPreKeyID: signedPreKey.id,
                                  signedPreKey: signedPreKey.keyPair.publicKey,
                                  signedPreKeySignature: signedPreKey.signature,
                                  preKeys: preKeys.mapValues(\.publicKey))
        if version == .v2 {
            bundle.version = .v2
            // Neither can be missing: the key is our own, valid X25519 key,
            // and the signature is added whenever a device is made or loaded.
            bundle.ed25519IdentityKey = try? identity.publicKey.ed25519()
            bundle.signedPreKeySignature = signedPreKey.rawKeySignature ?? Data()
        }
        return bundle
    }

    /// Tops the one-time pre-keys back up. Returns whether any were added,
    /// meaning the bundle must be republished.
    @discardableResult
    public mutating func refillPreKeys(to target: Int = preKeyTarget) -> Bool {
        var added = false
        while preKeys.count < target {
            // Ids are never reused: a stale bundle must not name a new key.
            preKeys[nextPreKeyID] = .generate()
            nextPreKeyID = nextPreKeyID == 0x7FFF_FFFF ? 1 : nextPreKeyID + 1
            added = true
        }
        return added
    }

    /// Removes a one-time pre-key after it started a session.
    public mutating func consumePreKey(_ id: UInt32) {
        preKeys.removeValue(forKey: id)
    }

    public mutating func rotateSignedPreKey(now: Date = Date()) throws {
        let id = signedPreKey.id == 0x7FFF_FFFF ? 1 : signedPreKey.id + 1
        previousSignedPreKeys.append(signedPreKey)
        previousSignedPreKeys.removeAll { now.timeIntervalSince($0.created) > Self.signedPreKeyRetention + 7 * 24 * 60 * 60 }
        signedPreKey = try Self.makeSignedPreKey(id: id, identity: identity, now: now)
    }

    func signedPreKey(id: UInt32) -> SignedPreKey? {
        id == signedPreKey.id ? signedPreKey : previousSignedPreKeys.first { $0.id == id }
    }

    private static func makeSignedPreKey(id: UInt32, identity: KeyPair, now: Date) throws -> SignedPreKey {
        let pair = KeyPair.generate()
        return SignedPreKey(id: id, keyPair: pair, signature: try identity.sign(pair.publicKey.serialized), created: now,
                            rawKeySignature: try identity.sign(pair.publicKey.rawRepresentation))
    }
}

// MARK: - Storage without the identity

extension LocalDevice {
    /// Everything but the identity's private key, which belongs somewhere
    /// safer (the keychain, bound to this device). Only the identity's public
    /// key is kept, to check the two halves belong together.
    private struct Stored: Codable {
        var deviceID: UInt32
        var identityPublicKey: PublicKey
        var signedPreKey: SignedPreKey
        var previousSignedPreKeys: [SignedPreKey]
        var preKeys: [UInt32: KeyPair]
        var nextPreKeyID: UInt32
    }

    public func encodedWithoutIdentity() throws -> Data {
        try JSONEncoder().encode(Stored(deviceID: deviceID, identityPublicKey: identity.publicKey,
                                        signedPreKey: signedPreKey, previousSignedPreKeys: previousSignedPreKeys,
                                        preKeys: preKeys, nextPreKeyID: nextPreKeyID))
    }

    /// Reassembles a device. Throws `authenticationFailed` if `identity` is
    /// not the identity the rest was stored with.
    public init(encodedWithoutIdentity data: Data, identity: KeyPair) throws {
        let stored = try JSONDecoder().decode(Stored.self, from: data)
        guard stored.identityPublicKey == identity.publicKey else { throw OMEMOCryptoError.authenticationFailed }
        var signedPreKey = stored.signedPreKey
        if signedPreKey.rawKeySignature == nil {
            // Stored before OMEMO 2.
            signedPreKey.rawKeySignature = try identity.sign(signedPreKey.keyPair.publicKey.rawRepresentation)
        }
        self.init(deviceID: stored.deviceID, identity: identity, signedPreKey: signedPreKey)
        previousSignedPreKeys = stored.previousSignedPreKeys
        preKeys = stored.preKeys
        nextPreKeyID = stored.nextPreKeyID
    }
}
