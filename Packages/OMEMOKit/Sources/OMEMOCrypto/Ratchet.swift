import Foundation

// The Double Ratchet ("The Double Ratchet Algorithm", Perrin and Marlinspike,
// 2016) over the X3DH key agreement ("The X3DH Key Agreement Protocol", same
// authors), with the parameters OMEMO 0.3 inherits from the Signal protocol
// and those XEP-0384 0.8 §5.3 sets for OMEMO 2.

/// KDF labels. OMEMO 0.3 uses the Signal protocol's; OMEMO 2 its own.
struct RatchetLabels: Sendable {
    var x3dh: String
    var rootChain: String
    var messageKeys: String

    static let legacy = RatchetLabels(x3dh: "WhisperText", rootChain: "WhisperRatchet", messageKeys: "WhisperMessageKeys")
    static let omemo2 = RatchetLabels(x3dh: "OMEMO X3DH", rootChain: "OMEMO Root Chain",
                                      messageKeys: "OMEMO Message Key Material")
}

/// A received ratchet message, in either wire format.
protocol RatchetMessage {
    var ratchetKey: PublicKey { get }
    var counter: UInt32 { get }
    var previousCounter: UInt32 { get }
    var ciphertext: Data { get }
    /// Throws `authenticationFailed` unless the MAC, made with `key`,
    /// verifies in the context of `state`.
    func verifyMAC(key: Data, in state: SessionState) throws
}

struct ChainKey: Sendable, Codable {
    var key: Data
    var index: UInt32

    /// §5.2 KDF_CK: the message key seed is HMAC(ck, 0x01), the next chain
    /// key HMAC(ck, 0x02).
    var messageKeySeed: Data { KDF.hmac(key: key, Data([0x01])) }
    var next: ChainKey { ChainKey(key: KDF.hmac(key: key, Data([0x02])), index: index + 1) }
}

struct MessageKeys {
    var cipherKey: Data
    var macKey: Data
    var iv: Data

    /// The seed expands to an AES-256 key, an HMAC key and a CBC IV.
    init(seed: Data, labels: RatchetLabels) {
        let material = KDF.hkdf(seed, info: labels.messageKeys, count: 80)
        cipherKey = Data(material.prefix(32))
        macKey = Data(material.dropFirst(32).prefix(32))
        iv = Data(material.suffix(16))
    }
}

/// §3.5: keys of messages that were skipped, so they can still be read when
/// they arrive late.
struct SkippedKey: Sendable, Codable {
    var ratchetKey: PublicKey
    var index: UInt32
    var seed: Data
}

/// What the initiator keeps putting on its messages until the other side
/// replies, so the responder can complete X3DH from any of them.
struct PendingPreKey: Sendable, Codable {
    var preKeyID: UInt32?
    var signedPreKeyID: UInt32
    var baseKey: PublicKey
}

/// One Double Ratchet session with one remote device.
struct SessionState: Sendable, Codable {
    /// §3.5 MAX_SKIP, per chain. XEP-0384 0.8 §7.4 suggests 1000 too.
    static let maxSkip: UInt32 = 1000
    /// All skipped keys kept at once, across chains; oldest dropped first.
    static let maxStoredSkipped = 2000

    var localIdentity: PublicKey
    var remoteIdentity: PublicKey
    var localRegistrationID: UInt32
    var remoteRegistrationID: UInt32
    /// X3DH's ephemeral key: identifies the session a pre-key message
    /// belongs to.
    var baseKey: PublicKey

    var rootKey: Data
    var sendingRatchet: KeyPair
    var sendingChain: ChainKey
    var receivingRatchet: PublicKey?
    var receivingChain: ChainKey?
    var previousCounter: UInt32 = 0
    var skipped: [SkippedKey] = []
    var pendingPreKey: PendingPreKey?
    /// OMEMO 2 only: X3DH's associated data, both identity keys in their
    /// Ed25519 form, the initiator's first. Its MACs cover it. `nil` marks an
    /// OMEMO 0.3 session (optional so sessions stored before OMEMO 2 decode).
    var associatedData: Data?

    var version: OMEMOVersion { associatedData == nil ? .legacy : .v2 }
    private var labels: RatchetLabels { version.labels }

    // MARK: - Sending

    /// Encrypts one message and returns it serialized in the session's wire
    /// format: a `LegacySignalMessage` or an `OMEMO2Message`.
    mutating func encrypt(_ plaintext: Data) throws -> Data {
        let keys = MessageKeys(seed: sendingChain.messageKeySeed, labels: labels)
        let ciphertext = try AESCBC.encrypt(plaintext, key: keys.cipherKey, iv: keys.iv)
        let serialized: Data
        if let associatedData {
            serialized = OMEMO2Message(ratchetKey: sendingRatchet.publicKey, counter: sendingChain.index,
                                       previousCounter: previousCounter, ciphertext: ciphertext,
                                       macKey: keys.macKey, associatedData: associatedData).serialized
        } else {
            serialized = LegacySignalMessage(ratchetKey: sendingRatchet.publicKey, counter: sendingChain.index,
                                             previousCounter: previousCounter, ciphertext: ciphertext,
                                             macKey: keys.macKey, sender: localIdentity, receiver: remoteIdentity)
                .serialized
        }
        sendingChain = sendingChain.next
        return serialized
    }

    // MARK: - Receiving

    /// §3.5 RatchetDecrypt. Mutates `self` only on success: callers run it on
    /// a copy, so a forged message cannot advance or corrupt the session.
    mutating func decrypt(_ message: some RatchetMessage) throws -> Data {
        let seed: Data
        if let index = skipped.firstIndex(where: { $0.ratchetKey == message.ratchetKey && $0.index == message.counter }) {
            seed = skipped[index].seed
            skipped.remove(at: index)
        } else {
            if message.ratchetKey != receivingRatchet {
                try skip(until: message.previousCounter)
                try ratchetStep(theirs: message.ratchetKey)
            }
            try skip(until: message.counter)
            guard let chain = receivingChain, chain.index == message.counter else {
                // Behind the chain and not among the skipped keys: a replay,
                // or a message whose key was already dropped.
                throw OMEMOCryptoError.messageOutOfRange
            }
            seed = chain.messageKeySeed
            receivingChain = chain.next
        }

        let keys = MessageKeys(seed: seed, labels: labels)
        try message.verifyMAC(key: keys.macKey, in: self)
        let plaintext = try AESCBC.decrypt(message.ciphertext, key: keys.cipherKey, iv: keys.iv)
        // They have our messages' ratchet key now, so pre-key data can stop.
        pendingPreKey = nil
        return plaintext
    }

    /// §3.5 SkipMessageKeys: stores the current receiving chain's keys up to
    /// (not including) `until`.
    private mutating func skip(until: UInt32) throws {
        guard var chain = receivingChain, let ratchetKey = receivingRatchet, chain.index < until else { return }
        guard until - chain.index <= Self.maxSkip else { throw OMEMOCryptoError.messageOutOfRange }
        while chain.index < until {
            skipped.append(SkippedKey(ratchetKey: ratchetKey, index: chain.index, seed: chain.messageKeySeed))
            chain = chain.next
        }
        if skipped.count > Self.maxStoredSkipped { skipped.removeFirst(skipped.count - Self.maxStoredSkipped) }
        receivingChain = chain
    }

    /// §3.5 DHRatchet.
    private mutating func ratchetStep(theirs: PublicKey) throws {
        previousCounter = sendingChain.index
        receivingRatchet = theirs
        let (rootAfterReceive, receiving) = try Self.rootStep(rootKey, sendingRatchet.agreement(with: theirs), labels: labels)
        receivingChain = receiving
        sendingRatchet = .generate()
        let (rootAfterSend, sending) = try Self.rootStep(rootAfterReceive, sendingRatchet.agreement(with: theirs), labels: labels)
        rootKey = rootAfterSend
        sendingChain = sending
    }

    /// §5.2 KDF_RK: HKDF with the root key as salt.
    static func rootStep(_ rootKey: Data, _ dhOutput: Data, labels: RatchetLabels) -> (Data, ChainKey) {
        let material = KDF.hkdf(dhOutput, salt: rootKey, info: labels.rootChain, count: 64)
        return (Data(material.prefix(32)), ChainKey(key: Data(material.suffix(32)), index: 0))
    }
}

// MARK: - X3DH

extension SessionState {
    /// X3DH §3.3, as the initiator ("Alice"), from the other device's bundle,
    /// in the bundle's version. OMEMO 2 always uses a one-time pre-key.
    static func initiate(local: LocalDevice, bundle: PreKeyBundle, preKeyID: UInt32?) throws -> SessionState {
        guard bundle.isSignatureValid else { throw OMEMOCryptoError.authenticationFailed }
        let version = bundle.version, labels = version.labels
        let base = KeyPair.generate()
        var secret = Data(repeating: 0xFF, count: 32)
        secret += try local.identity.agreement(with: bundle.signedPreKey)
        secret += try base.agreement(with: bundle.identityKey)
        secret += try base.agreement(with: bundle.signedPreKey)
        if let preKeyID {
            guard let preKey = bundle.preKeys[preKeyID] else { throw OMEMOCryptoError.unknownPreKey }
            secret += try base.agreement(with: preKey)
        } else if version == .v2 {
            throw OMEMOCryptoError.unknownPreKey
        }
        let pending = PendingPreKey(preKeyID: preKeyID, signedPreKeyID: bundle.signedPreKeyID, baseKey: base.publicKey)
        let sending = KeyPair.generate()

        switch version {
        case .legacy:
            // Signal's variant: 64 bytes, a root key and the responder's
            // first sending chain, on its signed pre-key as ratchet key.
            let derived = KDF.hkdf(secret, info: labels.x3dh, count: 64)
            let (root, sendingChain) = rootStep(Data(derived.prefix(32)), try sending.agreement(with: bundle.signedPreKey),
                                                labels: labels)
            return SessionState(
                localIdentity: local.identity.publicKey, remoteIdentity: bundle.identityKey,
                localRegistrationID: local.deviceID, remoteRegistrationID: bundle.deviceID,
                baseKey: base.publicKey, rootKey: root, sendingRatchet: sending, sendingChain: sendingChain,
                receivingRatchet: bundle.signedPreKey, receivingChain: ChainKey(key: Data(derived.suffix(32)), index: 0),
                pendingPreKey: pending)
        case .v2:
            // Double Ratchet §3.3 RatchetInitAlice: SK is the root key, the
            // signed pre-key the responder's ratchet key.
            guard let theirs = bundle.ed25519IdentityKey else { throw OMEMOCryptoError.malformed }
            let sk = KDF.hkdf(secret, info: labels.x3dh, count: 32)
            let (root, sendingChain) = rootStep(sk, try sending.agreement(with: bundle.signedPreKey), labels: labels)
            return SessionState(
                localIdentity: local.identity.publicKey, remoteIdentity: bundle.identityKey,
                localRegistrationID: local.deviceID, remoteRegistrationID: bundle.deviceID,
                baseKey: base.publicKey, rootKey: root, sendingRatchet: sending, sendingChain: sendingChain,
                receivingRatchet: nil, receivingChain: nil, pendingPreKey: pending,
                associatedData: try local.identity.publicKey.ed25519() + theirs)
        }
    }

    /// What a pre-key message carries for the responder, in either format.
    struct KeyExchange {
        var version: OMEMOVersion
        var registrationID: UInt32
        var preKeyID: UInt32?
        var signedPreKeyID: UInt32
        var baseKey: PublicKey
        var identityKey: PublicKey
        /// OMEMO 2: the initiator's identity as sent, Ed25519.
        var ed25519IdentityKey: Data?
    }

    /// X3DH §3.4, as the responder ("Bob"), from a pre-key message.
    static func respond(to exchange: KeyExchange, local: LocalDevice) throws -> SessionState {
        guard let signedPreKey = local.signedPreKey(id: exchange.signedPreKeyID) else {
            throw OMEMOCryptoError.unknownPreKey
        }
        let labels = exchange.version.labels
        var secret = Data(repeating: 0xFF, count: 32)
        secret += try signedPreKey.keyPair.agreement(with: exchange.identityKey)
        secret += try local.identity.agreement(with: exchange.baseKey)
        secret += try signedPreKey.keyPair.agreement(with: exchange.baseKey)
        if let preKeyID = exchange.preKeyID {
            guard let preKey = local.preKeys[preKeyID] else { throw OMEMOCryptoError.unknownPreKey }
            secret += try preKey.agreement(with: exchange.baseKey)
        } else if exchange.version == .v2 {
            throw OMEMOCryptoError.unknownPreKey
        }

        switch exchange.version {
        case .legacy:
            let derived = KDF.hkdf(secret, info: labels.x3dh, count: 64)
            return SessionState(
                localIdentity: local.identity.publicKey, remoteIdentity: exchange.identityKey,
                localRegistrationID: local.deviceID, remoteRegistrationID: exchange.registrationID,
                baseKey: exchange.baseKey, rootKey: Data(derived.prefix(32)), sendingRatchet: signedPreKey.keyPair,
                sendingChain: ChainKey(key: Data(derived.suffix(32)), index: 0))
        case .v2:
            // RatchetInitBob: no chains until the first message's ratchet
            // step, which replaces this placeholder sending chain before
            // anything is sent on it.
            guard let theirs = exchange.ed25519IdentityKey else { throw OMEMOCryptoError.malformed }
            return SessionState(
                localIdentity: local.identity.publicKey, remoteIdentity: exchange.identityKey,
                localRegistrationID: local.deviceID, remoteRegistrationID: exchange.registrationID,
                baseKey: exchange.baseKey, rootKey: KDF.hkdf(secret, info: labels.x3dh, count: 32),
                sendingRatchet: signedPreKey.keyPair, sendingChain: ChainKey(key: Data(count: 32), index: 0),
                associatedData: theirs + (try local.identity.publicKey.ed25519()))
        }
    }
}
