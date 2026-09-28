import Foundation
import OMEMOCrypto
import XMPPCore
import XMPPXML

/// OMEMO for one account, in both versions: keeps this device published in
/// each, encrypts for every device of the recipients and of our own account,
/// and decrypts what arrives.
///
/// This device is one device in both versions: one id, one identity, one
/// pool of pre-keys, published as an OMEMO 0.3 and an OMEMO 2 bundle. Each
/// remote device is encrypted for in one version: OMEMO 0.3 when it lists
/// itself there, which nearly every client does, and OMEMO 2 only for
/// devices that speak nothing else.
///
/// Each operation fetches what it needs from the directory first, then does
/// all cryptography and commits its changes at once without suspending, so
/// the actor never interleaves two updates of the same session. The device's
/// keys are read from the store at every operation: another process (the
/// notification service extension) may have used a pre-key in between.
public actor OMEMOEngine {
    /// Signed pre-keys are replaced weekly (XEP-0384 0.8 §5.3.2 suggests one
    /// week to one month).
    public static let signedPreKeyLifetime: TimeInterval = 7 * 24 * 60 * 60

    public nonisolated let account: JID
    private let store: OMEMOStore
    private let directory: OMEMODirectory
    private var identity: (deviceID: UInt32, key: PublicKey)?
    /// Lists fetched or pushed since this engine started. Others are
    /// fetched again before use: changes are pushed only for contacts, so a
    /// cached list of anyone else can be arbitrarily old.
    private var current: Set<ListKey> = []

    private struct ListKey: Hashable {
        var jid: JID
        var version: OMEMOVersion
    }

    public init(account: JID, store: OMEMOStore, directory: OMEMODirectory) {
        self.account = account.bare
        self.store = store
        self.directory = directory
    }

    public var deviceID: UInt32? { identity?.deviceID }
    public var identityKey: PublicKey? { identity?.key }

    private func loadDevice() throws -> LocalDevice {
        guard let device = try store.localDevice() else { throw OMEMOProtocolError.notSetUp }
        return device
    }

    // MARK: - Own device

    /// Loads this device's keys or creates them, rotates an old signed
    /// pre-key, and makes sure the device is in our lists and its bundles
    /// published, OMEMO 0.3 first: a server that refuses OMEMO 2's nodes
    /// still gets that. Run after each connection.
    public func setUp(now: Date = Date()) async throws {
        var device = try store.localDevice() ?? LocalDevice.generate(now: now)
        if now.timeIntervalSince(device.signedPreKey.created) > Self.signedPreKeyLifetime {
            try device.rotateSignedPreKey(now: now)
        }
        device.refillPreKeys()
        var changes = OMEMOChanges()
        changes.localDevice = device
        try store.commit(changes)
        identity = (device.deviceID, device.identity.publicKey)

        for version in [OMEMOVersion.legacy, .v2] {
            try await directory.publishBundle(device.bundle(for: version))
            let published = try await directory.deviceList(of: account, version: version)
            try store.saveDeviceIDs(published, of: account, version: version)
            if !published.contains(device.deviceID) {
                try await directory.publishDeviceList(published + [device.deviceID], version: version)
            }
        }
    }

    /// A device list from a PEP notification. If our own list lost this
    /// device (another client rewrote it), this device is put back (§4.2).
    public func deviceListChanged(_ deviceIDs: [UInt32], of jid: JID, version: OMEMOVersion) async throws {
        try store.saveDeviceIDs(deviceIDs, of: jid.bare, version: version)
        current.insert(ListKey(jid: jid.bare, version: version))
        if jid.bare == account, let id = identity?.deviceID, !deviceIDs.contains(id) {
            // The notification may be old: servers resend the last published
            // list on login, from before this device was added. Re-adding
            // us to that list would undo changes made since (devices
            // removed), so go by what the server has now.
            let current = try await directory.deviceList(of: account, version: version)
            try store.saveDeviceIDs(current, of: account, version: version)
            if !current.contains(id) { try await directory.publishDeviceList(current + [id], version: version) }
        }
    }

    /// Takes devices out of our own lists: ones that no longer exist (an
    /// uninstalled app, a restored phone), which others would otherwise go on
    /// encrypting for. This device is never removed; a device that is still
    /// in use puts itself back (§4.2).
    public func removeOwnDevices(_ deviceIDs: Set<UInt32>) async throws {
        let ownID = try loadDevice().deviceID
        for version in OMEMOVersion.allCases {
            let current = try await directory.deviceList(of: account, version: version)
            let kept = current.filter { !deviceIDs.contains($0) || $0 == ownID }
            guard kept != current else { continue }
            try await directory.publishDeviceList(kept, version: version)
            try store.saveDeviceIDs(kept, of: account, version: version)
        }
    }

    /// `jid`'s devices in either version: fetched the first time this engine
    /// needs them, from the cache after that (and when the server cannot be
    /// asked). Throws only when neither list can be had.
    public func deviceIDs(of jid: JID) async throws -> [UInt32] {
        let lists = try await deviceLists(of: jid)
        return lists[.legacy, default: []] + lists[.v2, default: []].filter { !lists[.legacy, default: []].contains($0) }
    }

    public func deviceIDs(of jid: JID, version: OMEMOVersion) async throws -> [UInt32] {
        let known = try store.deviceIDs(of: jid.bare, version: version)
        if let known, current.contains(ListKey(jid: jid.bare, version: version)) { return known }
        do {
            return try await refreshDeviceIDs(of: jid, version: version)
        } catch {
            if let known { return known }
            throw error
        }
    }

    /// Both lists. A cached answer of no devices at all is not trusted, even
    /// from this session: it may have been fetched moments before the
    /// contact set OMEMO up, and only contacts' changes are pushed. Deciding
    /// on it would fail the message, or send it in the clear.
    private func deviceLists(of jid: JID) async throws -> [OMEMOVersion: [UInt32]] {
        var lists: [OMEMOVersion: [UInt32]] = [:]
        for version in OMEMOVersion.allCases where current.contains(ListKey(jid: jid.bare, version: version)) {
            lists[version] = try store.deviceIDs(of: jid.bare, version: version)
        }
        if lists.count == OMEMOVersion.allCases.count, lists.values.contains(where: { !$0.isEmpty }) { return lists }

        lists = [:]
        var failure: (any Error)?
        for version in OMEMOVersion.allCases {
            do {
                lists[version] = try await refreshDeviceIDs(of: jid, version: version)
            } catch {
                if let known = try store.deviceIDs(of: jid.bare, version: version) { lists[version] = known }
                failure = failure ?? error
            }
        }
        if lists.isEmpty, let failure { throw failure }
        return lists
    }

    /// `jid`'s devices in both versions, fetched now. For people whose list
    /// changes are not pushed to us (room members who are not contacts):
    /// the cache would otherwise stay as it was when first fetched.
    @discardableResult
    public func refreshDeviceIDs(of jid: JID) async throws -> [UInt32] {
        var ids: [UInt32] = []
        var failure: (any Error)?
        var fetched = false
        for version in OMEMOVersion.allCases {
            do {
                ids += try await refreshDeviceIDs(of: jid, version: version).filter { !ids.contains($0) }
                fetched = true
            } catch {
                failure = failure ?? error
            }
        }
        if !fetched, let failure { throw failure }
        return ids
    }

    @discardableResult
    public func refreshDeviceIDs(of jid: JID, version: OMEMOVersion) async throws -> [UInt32] {
        let fetched = try await directory.deviceList(of: jid.bare, version: version)
        try store.saveDeviceIDs(fetched, of: jid.bare, version: version)
        current.insert(ListKey(jid: jid.bare, version: version))
        return fetched
    }

    /// Which of `candidates` has a device with this id, by the cached lists.
    /// Rooms do not always say who sent a message (archives of people who
    /// have left); the sender's device id does.
    public func owner(ofDevice deviceID: UInt32, among candidates: [JID]) -> JID? {
        candidates.first { candidate in
            OMEMOVersion.allCases.contains { (try? store.deviceIDs(of: candidate.bare, version: $0))?.contains(deviceID) == true }
        }?.bare
    }

    // MARK: - Encrypting

    public struct Encrypted: Sendable {
        public var message: EncryptedMessage
        /// Devices left out, and why (no bundle, changed identity, …).
        public var skipped: [(address: DeviceAddress, error: any Error)]
    }

    /// A device to encrypt for, and the versions it could be reached in, in
    /// order of preference.
    private struct Target {
        var address: DeviceAddress
        var versions: [OMEMOVersion]
    }

    /// Encrypts `body` for all devices of `recipients` and our other devices.
    /// `conversation` is where the message goes (the contact, or the room),
    /// named in OMEMO 2's envelope; it defaults to a single recipient.
    /// Throws `noDevices` if a recipient (other than us) has none that work.
    /// The advanced sessions are committed before this returns, so a message
    /// key is never used twice.
    public func encrypt(_ body: String, to recipients: [JID], conversation: JID? = nil) async throws -> Encrypted {
        let others = Array(Set(recipients.map(\.bare))).filter { $0 != account }
        let envelope = SCEEnvelope(content: [Element(name: "body", namespaceURI: Namespaces.client, text: body)],
                                   from: account, to: conversation ?? (recipients.count == 1 ? recipients[0] : nil))
        let sealed = Sealed(legacy: try LegacyPayload.seal(Data(body.utf8)),
                            v2: try OMEMO2Payload.seal(Data(envelope.element.xmlString.utf8)))

        // Fetch: device lists never seen, then bundles for devices without a
        // session.
        let ownID = try loadDevice().deviceID
        var targets: [Target] = []
        for jid in others + [account] {
            let lists = try await deviceLists(of: jid)
            let legacy = lists[.legacy, default: []], v2 = lists[.v2, default: []]
            for id in legacy + v2.filter({ !legacy.contains($0) }) where !(jid == account && id == ownID) {
                targets.append(Target(address: DeviceAddress(jid: jid, deviceID: id),
                                      versions: [.legacy, .v2].filter { (lists[$0] ?? []).contains(id) }))
            }
        }
        var skipped: [(address: DeviceAddress, error: any Error)] = []
        let chosen = await choose(for: targets, skipped: &skipped)

        // Encrypt and commit: no suspension from here on.
        let message = try seal(sealed, for: chosen, local: try loadDevice(), skipped: &skipped)
        for jid in others {
            guard !message.keys.contains(where: { key in
                chosen.contains { $0.address.device.jid == jid && $0.address.device.deviceID == key.deviceID }
            }) else { continue }
            let distrusted = skipped.contains { skip in
                if case OMEMOProtocolError.notTrusted(let who, _) = skip.error { return who == jid }
                return false
            }
            throw distrusted ? OMEMOProtocolError.noTrustedDevices(jid) : OMEMOProtocolError.noDevices(jid)
        }
        return Encrypted(message: message, skipped: skipped)
    }

    /// §4.5's key transport message (0.8 §6.1: an empty message): key
    /// material without a payload. Sent after a pre-key message arrives, in
    /// its version, so the sender's next messages are ordinary ones, and to
    /// fix a broken session.
    public func keyTransport(to session: SessionAddress) async throws -> EncryptedMessage {
        var skipped: [(address: DeviceAddress, error: any Error)] = []
        let chosen = await choose(for: [Target(address: session.device, versions: [session.version])], skipped: &skipped)
        if let failure = skipped.first { throw failure.error }
        let empty = Sealed(legacy: try LegacyPayload.seal(Data()), v2: nil)
        return try seal(empty, for: chosen, local: try loadDevice(), skipped: &skipped)
    }

    private struct Chosen {
        var address: SessionAddress
        /// To start the session from; `nil` when there is one.
        var bundle: PreKeyBundle?
    }

    /// Picks each target's version: one it has a session in, else the first
    /// whose bundle can be fetched.
    private func choose(for targets: [Target], skipped: inout [(address: DeviceAddress, error: any Error)]) async
        -> [Chosen] {
        var chosen: [Chosen] = []
        for target in targets {
            if let version = target.versions.first(where: {
                (try? store.session(with: SessionAddress(target.address, $0))) != nil
            }) {
                chosen.append(Chosen(address: SessionAddress(target.address, version)))
                continue
            }
            var failure: (any Error)?
            for version in target.versions {
                do {
                    let bundle = try await directory.bundle(of: target.address.jid, deviceID: target.address.deviceID,
                                                            version: version)
                    chosen.append(Chosen(address: SessionAddress(target.address, version), bundle: bundle))
                    failure = nil
                    break
                } catch {
                    failure = failure ?? error
                }
            }
            if let failure { skipped.append((target.address, failure)) }
        }
        return chosen
    }

    /// The payload sealed for each version. `v2` is `nil` for an empty
    /// message.
    private struct Sealed {
        var legacy: LegacyPayload.Sealed
        var v2: OMEMO2Payload.Sealed?
    }

    /// Encrypts the key material for each device, starting sessions from the
    /// fetched bundles where there are none, and commits. Synchronous by
    /// design.
    private func seal(_ sealed: Sealed, for chosen: [Chosen], local: LocalDevice,
                      skipped: inout [(address: DeviceAddress, error: any Error)]) throws -> EncryptedMessage {
        var keys: [OMEMOVersion: [EncryptedElement.Key]] = [:]
        var changes = OMEMOChanges()
        for target in chosen {
            let address = target.address.device
            do {
                var session: Session
                if let existing = try store.session(with: target.address) {
                    session = existing
                } else if let bundle = target.bundle {
                    session = try Session.initiate(local: local, bundle: bundle)
                } else {
                    continue
                }
                let trust = try checkIdentity(session.remoteIdentity, of: address, changes: &changes)
                guard trust.isTrusted else { throw OMEMOProtocolError.notTrusted(address.jid, address.deviceID) }
                let keyMaterial = switch target.address.version {
                case .legacy: sealed.legacy.keyMaterial
                case .v2: sealed.v2?.keyMaterial ?? OMEMO2Payload.emptyKeyMaterial
                }
                let key = try session.encrypt(keyMaterial)
                changes.sessions[target.address] = session
                keys[target.address.version, default: []].append(
                    EncryptedElement.Key(deviceID: address.deviceID, data: key.data, isPreKey: key.isPreKey,
                                         jid: target.address.version == .v2 ? address.jid : nil))
            } catch {
                skipped.append((address, error))
            }
        }
        try store.commit(changes)

        var elements: [EncryptedElement] = []
        if let legacy = keys[.legacy] {
            elements.append(EncryptedElement(senderDeviceID: local.deviceID, keys: legacy, iv: sealed.legacy.iv,
                                             payload: sealed.v2 == nil ? nil : sealed.legacy.payload))
        }
        if let v2 = keys[.v2] {
            elements.append(EncryptedElement(version: .v2, senderDeviceID: local.deviceID, keys: v2,
                                             payload: sealed.v2?.payload))
        }
        // Nobody to encrypt for (no other devices of ours, no recipients):
        // an OMEMO 0.3 element without keys, as before OMEMO 2.
        return EncryptedMessage(elements) ?? EncryptedMessage(
            EncryptedElement(senderDeviceID: local.deviceID, keys: [], iv: sealed.legacy.iv,
                             payload: sealed.v2 == nil ? nil : sealed.legacy.payload))
    }

    // MARK: - Decrypting

    public struct Decrypted: Sendable {
        /// `nil` for a key transport message.
        public var body: String?
        /// What the sender encrypted: the body, or everything in OMEMO 2's
        /// envelope. Empty for a key transport message. See
        /// `Message.decrypted(content:)`.
        public var content: [Element]
        public var sender: DeviceAddress
        public var version: OMEMOVersion
        public var senderIdentity: PublicKey
        /// The sender device's trust when the message arrived. Messages from
        /// devices not trusted are still read; the app marks them.
        public var senderTrust: Trust
        /// The message started a session: answer with `keyTransport(to:)`
        /// so the sender stops sending pre-key messages.
        public var shouldAcknowledge: Bool

        public var session: SessionAddress { SessionAddress(sender, version) }
    }

    /// Decrypts a message, from whichever of its elements has a key for
    /// this device. `persist` runs after decryption and before the advanced
    /// session is committed: store the message there. If it throws, nothing
    /// is committed, and if the process dies after it, the message can be
    /// decrypted again when redelivered (deduplicate it then) instead of
    /// being lost with its message key.
    ///
    /// `conversations`, when given, are where the message may have been
    /// addressed: an OMEMO 2 envelope naming another is refused, so a
    /// message cannot be replayed into another chat.
    public func decrypt(_ encrypted: EncryptedMessage, from sender: JID, conversations: [JID]? = nil,
                        persist: @Sendable (Decrypted) throws -> Void = { _ in }) async throws -> Decrypted {
        let ownID = try loadDevice().deviceID
        let candidates = encrypted.elements.compactMap { element in
            element.keys.first { $0.deviceID == ownID && ($0.jid == nil || $0.jid == account) }.map { (element, $0) }
        }
        guard !candidates.isEmpty else { throw OMEMOProtocolError.notEncryptedForThisDevice }
        var failure: (any Error)?
        for (element, key) in candidates {
            do {
                return try await decrypt(element, key: key, from: sender, conversations: conversations, persist: persist)
            } catch {
                failure = failure ?? error
            }
        }
        throw failure!
    }

    public func decrypt(_ encrypted: EncryptedElement, from sender: JID, conversations: [JID]? = nil,
                        persist: @Sendable (Decrypted) throws -> Void = { _ in }) async throws -> Decrypted {
        try await decrypt(EncryptedMessage(encrypted), from: sender, conversations: conversations, persist: persist)
    }

    private func decrypt(_ encrypted: EncryptedElement, key: EncryptedElement.Key, from sender: JID,
                         conversations: [JID]?, persist: @Sendable (Decrypted) throws -> Void) async throws -> Decrypted {
        var device = try loadDevice()
        let address = DeviceAddress(jid: sender, deviceID: encrypted.senderDeviceID)
        let sessionAddress = SessionAddress(address, encrypted.version)

        var changes = OMEMOChanges()
        let keyMaterial: Data
        let session: Session
        if key.isPreKey {
            let accepted = try Session.accept(serialized: key.data, version: encrypted.version, local: device,
                                              existing: store.session(with: sessionAddress))
            if let used = accepted.consumedPreKeyID {
                device.consumePreKey(used)
                device.refillPreKeys()
                changes.localDevice = device
            }
            keyMaterial = accepted.plaintext
            session = accepted.session
        } else {
            guard var existing = try store.session(with: sessionAddress) else {
                throw OMEMOProtocolError.noSession(address.jid, address.deviceID)
            }
            keyMaterial = try existing.decrypt(serialized: key.data)
            session = existing
        }

        var content: [Element] = []
        if let payload = encrypted.payload {
            switch encrypted.version {
            case .legacy:
                let plaintext = try LegacyPayload.open(payload: payload, iv: encrypted.iv, keyMaterial: keyMaterial)
                guard let text = String(data: plaintext, encoding: .utf8) else { throw OMEMOCryptoError.malformed }
                content = [Element(name: "body", namespaceURI: Namespaces.client, text: text)]
            case .v2:
                let plaintext = try OMEMO2Payload.open(payload: payload, keyMaterial: keyMaterial)
                guard let text = String(data: plaintext, encoding: .utf8),
                      let envelope = (try? Element(xmlFragment: text)).flatMap(SCEEnvelope.init(element:)) else {
                    throw OMEMOCryptoError.malformed
                }
                // XEP-0420 §5: the affixes must match the stanza.
                if let from = envelope.from, from != sender.bare { throw OMEMOProtocolError.envelopeMismatch }
                if let to = envelope.to, let conversations, !conversations.contains(where: { $0.bare == to }) {
                    throw OMEMOProtocolError.envelopeMismatch
                }
                content = envelope.content
            }
        }

        let trust = try checkIdentity(session.remoteIdentity, of: address, changes: &changes)
        let body = encrypted.payload == nil ? nil
            : content.first { $0.matches(name: "body", namespaceURI: Namespaces.client) }?.text ?? ""
        let result = Decrypted(body: body, content: content, sender: address, version: encrypted.version,
                               senderIdentity: session.remoteIdentity, senderTrust: trust,
                               shouldAcknowledge: key.isPreKey)
        try persist(result)
        changes.sessions[sessionAddress] = session
        try store.commit(changes)

        // The used pre-key must disappear from the published bundles.
        if let changed = changes.localDevice {
            for version in OMEMOVersion.allCases { try? await directory.publishBundle(changed.bundle(for: version)) }
        }
        return result
    }

    /// The device's trust, recording its identity when it is new or changed:
    /// Blind Trust Before Verification (see `Trust`). A key that changed
    /// replaces the old one, undecided. One record per device, whichever
    /// version: identities are compared in their X25519 form.
    private func checkIdentity(_ identity: PublicKey, of address: DeviceAddress,
                               changes: inout OMEMOChanges) throws -> Trust {
        if let pending = changes.identities[address], pending.key == identity { return pending.trust }
        if let known = try store.identity(of: address) {
            if known.key == identity { return known.trust }
            changes.identities[address] = IdentityRecord(key: identity, trust: .undecided)
            return .undecided
        }
        let verified = try store.identities(of: address.jid).values.contains { $0.trust == .verified }
        let trust: Trust = verified ? .undecided : .blind
        changes.identities[address] = IdentityRecord(key: identity, trust: trust)
        return trust
    }
}
