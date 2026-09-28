import Foundation
import OMEMOCrypto
import OMEMOProtocol
import HrafnStore
import XMPPCore

/// OMEMOKit's store for one account: state in `OMEMODatabase`, the identity's
/// private key in the keychain (`CredentialStore`).
public final class DatabaseOMEMOStore: OMEMOStore, @unchecked Sendable {
    public let accountID: String
    private let database: OMEMODatabase
    private let credentials: any CredentialStore
    /// The identity key pair, once read: the keychain is slower than SQLite
    /// and the pair never changes for a device.
    private let lock = NSLock()
    private var identity: KeyPair?

    public init(accountID: String, database: OMEMODatabase, credentials: any CredentialStore) {
        self.accountID = accountID
        self.database = database
        self.credentials = credentials
    }

    /// `nil` when there is no device yet, or when the keychain no longer has
    /// the identity the stored device was made with. That device is then
    /// forgotten, with its sessions, and the engine makes a new one.
    ///
    /// A keychain that cannot be read (before first unlock) throws instead:
    /// that is not a lost key.
    public func localDevice() throws -> LocalDevice? {
        guard let stored = try database.device(accountID: accountID) else { return nil }
        guard let pair = try identityKeyPair(),
              let device = try? LocalDevice(encodedWithoutIdentity: stored.state, identity: pair) else {
            try database.resetDevice(accountID: accountID)
            return nil
        }
        return device
    }

    public func session(with address: SessionAddress) throws -> Session? {
        try database.session(accountID: accountID, jid: address.device.jid.description, deviceID: address.device.deviceID,
                             version: address.version.rawValue)
            .map { try JSONDecoder().decode(Session.self, from: $0) }
    }

    public func identity(of address: DeviceAddress) throws -> IdentityRecord? {
        try database.identity(accountID: accountID, jid: address.jid.description, deviceID: address.deviceID)
            .map { IdentityRecord(key: try PublicKey(serialized: $0.key), trust: Trust(rawValue: $0.trust) ?? .undecided) }
    }

    public func identities(of jid: JID) throws -> [UInt32: IdentityRecord] {
        var records: [UInt32: IdentityRecord] = [:]
        for identity in try database.identities(accountID: accountID, jid: jid.bare.description) {
            guard let key = try? PublicKey(serialized: identity.key) else { continue }
            records[identity.deviceID] = IdentityRecord(key: key, trust: Trust(rawValue: identity.trust) ?? .undecided)
        }
        return records
    }

    /// The keychain first, so the database never names an identity whose
    /// private key is not stored; then everything else in one transaction.
    public func commit(_ changes: OMEMOChanges) throws {
        guard !changes.isEmpty else { return }
        var write = OMEMOWrite()
        if let device = changes.localDevice {
            if try identityKeyPair()?.publicKey != device.identity.publicKey {
                try credentials.setOMEMOIdentityKey(device.identity.privateKey, for: accountID)
                lock.withLock { identity = device.identity }
            }
            write.device = (device.deviceID, try device.encodedWithoutIdentity(), device.identity.publicKey.serialized)
        }
        let encoder = JSONEncoder()
        for (address, session) in changes.sessions {
            write.sessions.append(.init(jid: address.device.jid.description, deviceID: address.device.deviceID,
                                        version: address.version.rawValue, state: try encoder.encode(session)))
        }
        for (address, record) in changes.identities {
            write.identities.append(.init(jid: address.jid.description, deviceID: address.deviceID,
                                          key: record.key.serialized, trust: record.trust.rawValue))
        }
        try database.commit(accountID: accountID, write)
    }

    public func deviceIDs(of jid: JID, version: OMEMOVersion) throws -> [UInt32]? {
        try database.deviceIDs(accountID: accountID, jid: jid.bare.description, version: version.rawValue)
    }

    public func saveDeviceIDs(_ deviceIDs: [UInt32], of jid: JID, version: OMEMOVersion) throws {
        try database.saveDeviceIDs(deviceIDs, accountID: accountID, jid: jid.bare.description, version: version.rawValue)
    }

    private func identityKeyPair() throws -> KeyPair? {
        if let cached = lock.withLock({ identity }) { return cached }
        guard let secret = try credentials.omemoIdentityKey(for: accountID),
              let pair = try? KeyPair(privateKey: secret) else { return nil }
        lock.withLock { identity = pair }
        return pair
    }
}
