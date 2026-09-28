import Foundation

/// A ratchet message ready for a `<key/>` element.
public struct EncryptedKey: Sendable, Equatable {
    public var data: Data
    /// Sets `prekey='true'` (OMEMO 2: `kex='true'`): the data is a pre-key
    /// message.
    public var isPreKey: Bool
}

/// The sessions with one remote device: the current one, plus a few older
/// ones for messages still in flight when a new session replaced them (both
/// sides may start one at the same time).
///
/// A value type. Every operation either succeeds and leaves the new state in
/// `self`, or throws and leaves `self` unchanged; persist it after success.
///
/// A session speaks one version of OMEMO; a device reached with both has a
/// session for each.
public struct Session: Sendable, Codable {
    static let maxPreviousStates = 5

    private(set) var current: SessionState
    private(set) var previous: [SessionState] = []

    public var version: OMEMOVersion { current.version }

    /// The remote device's identity key, whose trust the caller decides.
    public var remoteIdentity: PublicKey { current.remoteIdentity }
    /// Whether the other side has not answered yet, so messages still carry
    /// pre-key data.
    public var isAwaitingReply: Bool { current.pendingPreKey != nil }

    /// Starts a session from a bundle, in the bundle's version, using one of
    /// its pre-keys at random (XEP-0384 0.3 §4.5, 0.8 §5.3.3). Throws if the
    /// bundle's signature is invalid, or if an OMEMO 2 bundle has no
    /// pre-keys left.
    public static func initiate(local: LocalDevice, bundle: PreKeyBundle) throws -> Session {
        let preKeyID = bundle.preKeys.keys.randomElement()
        return Session(current: try .initiate(local: local, bundle: bundle, preKeyID: preKeyID))
    }

    public mutating func encrypt(_ plaintext: Data) throws -> EncryptedKey {
        var state = current
        let message = try state.encrypt(plaintext)
        guard let pending = state.pendingPreKey else {
            current = state
            return EncryptedKey(data: message, isPreKey: false)
        }
        let wrapped: Data
        switch state.version {
        case .legacy:
            wrapped = LegacyPreKeySignalMessage(
                registrationID: state.localRegistrationID, preKeyID: pending.preKeyID,
                signedPreKeyID: pending.signedPreKeyID, baseKey: pending.baseKey,
                identityKey: state.localIdentity, message: try LegacySignalMessage(serialized: message)).serialized
        case .v2:
            guard let preKeyID = pending.preKeyID else { throw OMEMOCryptoError.unknownPreKey }
            wrapped = OMEMO2KeyExchange(
                preKeyID: preKeyID, signedPreKeyID: pending.signedPreKeyID,
                identityKey: try state.localIdentity.ed25519(), baseKey: pending.baseKey,
                message: try OMEMO2Message(serialized: message)).serialized
        }
        current = state
        return EncryptedKey(data: wrapped, isPreKey: true)
    }

    /// Decrypts a ratchet message. Tries the current state, then older ones;
    /// one that works becomes current.
    public mutating func decrypt(_ message: LegacySignalMessage) throws -> Data {
        try decrypt(message as any RatchetMessage)
    }

    public mutating func decrypt(_ message: OMEMO2Message) throws -> Data {
        try decrypt(message as any RatchetMessage)
    }

    private mutating func decrypt(_ message: any RatchetMessage) throws -> Data {
        var candidates = [current] + previous
        for index in candidates.indices {
            var state = candidates[index]
            guard let plaintext = try? state.decrypt(message) else { continue }
            candidates.remove(at: index)
            current = state
            previous = Array(candidates.prefix(Self.maxPreviousStates))
            return plaintext
        }
        throw OMEMOCryptoError.authenticationFailed
    }

    /// Decrypts a ratchet message serialized in the session's version.
    public mutating func decrypt(serialized data: Data) throws -> Data {
        switch version {
        case .legacy: try decrypt(LegacySignalMessage(serialized: data))
        case .v2: try decrypt(OMEMO2Message(serialized: data))
        }
    }

    /// The result of accepting a pre-key message.
    public struct Accepted: Sendable {
        public var session: Session
        public var plaintext: Data
        /// The one-time pre-key it used, which the caller must now remove
        /// from `LocalDevice` and republish the bundle without. `nil` when
        /// the message belonged to a session that already existed.
        public var consumedPreKeyID: UInt32?
    }

    /// Accepts a pre-key message: continues the session it belongs to, if we
    /// already have it, or completes X3DH and starts a new one, keeping the
    /// old one for messages in flight.
    ///
    /// The identity key in the message is not checked against anything; the
    /// caller compares `session.remoteIdentity` with what it trusts.
    public static func accept(_ message: LegacyPreKeySignalMessage, local: LocalDevice,
                              existing: Session?) throws -> Accepted {
        try accept(message.keyExchange, message.message, local: local, existing: existing)
    }

    public static func accept(_ message: OMEMO2KeyExchange, local: LocalDevice, existing: Session?) throws -> Accepted {
        try accept(try message.keyExchange, message.message, local: local, existing: existing)
    }

    /// Accepts a pre-key message serialized in `version`. `existing` must be
    /// the session of that version, if any.
    public static func accept(serialized data: Data, version: OMEMOVersion = .legacy, local: LocalDevice,
                              existing: Session?) throws -> Accepted {
        switch version {
        case .legacy: try accept(LegacyPreKeySignalMessage(serialized: data), local: local, existing: existing)
        case .v2: try accept(OMEMO2KeyExchange(serialized: data), local: local, existing: existing)
        }
    }

    private static func accept(_ exchange: SessionState.KeyExchange, _ message: any RatchetMessage,
                               local: LocalDevice, existing: Session?) throws -> Accepted {
        guard existing.map({ $0.version == exchange.version }) ?? true else { throw OMEMOCryptoError.malformed }
        if var session = existing, session.hasState(baseKey: exchange.baseKey) {
            let plaintext = try session.decrypt(message)
            return Accepted(session: session, plaintext: plaintext, consumedPreKeyID: nil)
        }
        var state = try SessionState.respond(to: exchange, local: local)
        let plaintext = try state.decrypt(message)
        var session = Session(current: state)
        if let existing {
            session.previous = Array(([existing.current] + existing.previous).prefix(maxPreviousStates))
        }
        return Accepted(session: session, plaintext: plaintext, consumedPreKeyID: exchange.preKeyID)
    }

    private func hasState(baseKey: PublicKey) -> Bool {
        current.baseKey == baseKey || previous.contains { $0.baseKey == baseKey }
    }
}
