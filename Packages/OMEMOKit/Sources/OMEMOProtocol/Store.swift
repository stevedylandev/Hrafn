import Foundation
import OMEMOCrypto
import XMPPCore

/// One remote device: an account and a device id.
public struct DeviceAddress: Sendable, Hashable {
    public var jid: JID
    public var deviceID: UInt32

    public init(jid: JID, deviceID: UInt32) {
        self.jid = jid.bare
        self.deviceID = deviceID
    }
}

/// A session: a remote device and the version of OMEMO spoken with it.
public struct SessionAddress: Sendable, Hashable {
    public var device: DeviceAddress
    public var version: OMEMOVersion

    public init(_ device: DeviceAddress, _ version: OMEMOVersion) {
        self.device = device
        self.version = version
    }
}

/// How far a remote device's identity key is trusted.
///
/// Blind Trust Before Verification: a contact's devices are trusted as they
/// appear (`blind`) until the user verifies one of them; from then on, new
/// devices of that contact wait for the user (`undecided`). A device whose
/// key changes waits too, whatever came before.
public enum Trust: String, Sendable, Hashable, Codable, CaseIterable {
    /// Trusted without verification.
    case blind
    /// The user compared fingerprints (or scanned them).
    case verified
    /// New or changed, and the contact has verified devices: not encrypted
    /// for until the user decides. Its messages are read, and marked.
    case undecided
    /// The user said no: never encrypted for; its messages are marked.
    case untrusted

    /// Messages are encrypted for the device.
    public var isTrusted: Bool { self == .blind || self == .verified }
}

/// A remote device's identity key and how far it is trusted.
public struct IdentityRecord: Sendable, Hashable {
    public var key: PublicKey
    public var trust: Trust

    public init(key: PublicKey, trust: Trust) {
        self.key = key
        self.trust = trust
    }
}

/// What one engine operation changed, written by `OMEMOStore.commit` all at
/// once, so a crash never leaves half of it behind.
public struct OMEMOChanges: Sendable {
    public var localDevice: LocalDevice?
    public var sessions: [SessionAddress: Session] = [:]
    /// Identity keys seen for the first time, or changed. Replaces what is
    /// stored for the device.
    public var identities: [DeviceAddress: IdentityRecord] = [:]

    public init() {}

    public var isEmpty: Bool { localDevice == nil && sessions.isEmpty && identities.isEmpty }
}

/// Persistence for one account's OMEMO state. Synchronous: the engine reads
/// and commits between suspension points, so a session is loaded, advanced
/// and saved without another operation interleaving. GRDB in the app.
public protocol OMEMOStore: Sendable {
    func localDevice() throws -> LocalDevice?
    func session(with address: SessionAddress) throws -> Session?
    /// The identity key known for a device, and its trust. The same for
    /// both versions: kept in its X25519 form.
    func identity(of address: DeviceAddress) throws -> IdentityRecord?
    /// Every identity known for `jid`'s devices.
    func identities(of jid: JID) throws -> [UInt32: IdentityRecord]
    func commit(_ changes: OMEMOChanges) throws

    /// The last device list of `version` seen for `jid`, or `nil` if never
    /// fetched. A cache, written on its own.
    func deviceIDs(of jid: JID, version: OMEMOVersion) throws -> [UInt32]?
    func saveDeviceIDs(_ deviceIDs: [UInt32], of jid: JID, version: OMEMOVersion) throws
}

/// For tests, and for accounts that must not persist anything.
public final class InMemoryOMEMOStore: OMEMOStore, @unchecked Sendable {
    private let lock = NSLock()
    private var local: LocalDevice?
    private var sessions: [SessionAddress: Session] = [:]
    private var lists: [String: [UInt32]] = [:]
    private var identities: [DeviceAddress: IdentityRecord] = [:]

    public init(localDevice: LocalDevice? = nil) {
        local = localDevice
    }

    public func localDevice() throws -> LocalDevice? { lock.withLock { local } }
    public func session(with address: SessionAddress) throws -> Session? { lock.withLock { sessions[address] } }
    public func identity(of address: DeviceAddress) throws -> IdentityRecord? { lock.withLock { identities[address] } }

    public func identities(of jid: JID) throws -> [UInt32: IdentityRecord] {
        lock.withLock {
            Dictionary(uniqueKeysWithValues: identities.filter { $0.key.jid == jid.bare }.map { ($0.key.deviceID, $0.value) })
        }
    }

    /// The user's decision about a device, as the app's store records it.
    public func setTrust(_ trust: Trust, of address: DeviceAddress) {
        lock.withLock { identities[address]?.trust = trust }
    }

    public func commit(_ changes: OMEMOChanges) throws {
        lock.withLock {
            if let device = changes.localDevice { local = device }
            sessions.merge(changes.sessions) { $1 }
            identities.merge(changes.identities) { $1 }
        }
    }

    public func deviceIDs(of jid: JID, version: OMEMOVersion) throws -> [UInt32]? {
        lock.withLock { lists["\(version.rawValue) \(jid.bare)"] }
    }

    public func saveDeviceIDs(_ deviceIDs: [UInt32], of jid: JID, version: OMEMOVersion) throws {
        lock.withLock { lists["\(version.rawValue) \(jid.bare)"] = deviceIDs }
    }
}
