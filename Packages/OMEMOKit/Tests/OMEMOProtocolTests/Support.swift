import Foundation
import OMEMOCrypto
import OMEMOProtocol
import XMPPCore
import XMPPIM
import XMPPXML

/// A PEP service shared by every account in a test, with the nodes of both
/// versions. Bundles and lists go through their XML, so parsing and
/// serializing are exercised too.
final class FakePEP: @unchecked Sendable {
    private let lock = NSLock()
    private var lists: [String: Element] = [:]
    private var bundles: [String: Element] = [:]
    private(set) var bundlePublishes = 0
    /// Versions whose nodes the server refuses, as one without OMEMO 2's
    /// publish options might.
    var refused: Set<OMEMOVersion> {
        get { lock.withLock { refusedVersions } }
        set { lock.withLock { refusedVersions = newValue } }
    }
    private var refusedVersions: Set<OMEMOVersion> = []

    func directory(for account: JID) -> OMEMODirectory { Directory(pep: self, account: account.bare) }

    func setList(_ element: Element, of jid: JID) {
        let version = DeviceList(element: element)?.version ?? .legacy
        lock.withLock { lists["\(version.rawValue) \(jid.bare)"] = element }
    }

    func setBundle(_ element: Element, of jid: JID, deviceID: UInt32) {
        let version: OMEMOVersion = element.namespaceURI == Namespaces.omemo2 ? .v2 : .legacy
        lock.withLock { bundles["\(version.rawValue) \(jid.bare)/\(deviceID)"] = element }
    }

    func list(of jid: JID, version: OMEMOVersion) -> [UInt32] {
        lock.withLock { lists["\(version.rawValue) \(jid.bare)"] }.flatMap(DeviceList.init(element:))?.deviceIDs ?? []
    }

    /// Takes a device out of one version, as if its client never spoke it
    /// (some clients have no OMEMO 0.3, most no OMEMO 2).
    func withdraw(_ deviceID: UInt32, of jid: JID, from version: OMEMOVersion) {
        setList(DeviceList(deviceIDs: list(of: jid, version: version).filter { $0 != deviceID }, version: version).element,
                of: jid)
        _ = lock.withLock { bundles.removeValue(forKey: "\(version.rawValue) \(jid.bare)/\(deviceID)") }
    }

    struct Directory: OMEMODirectory {
        struct Refused: Error {}
        let pep: FakePEP
        let account: JID

        func deviceList(of jid: JID, version: OMEMOVersion) async throws -> [UInt32] {
            if pep.refused.contains(version) { throw Refused() }
            return pep.list(of: jid, version: version)
        }

        func publishDeviceList(_ deviceIDs: [UInt32], version: OMEMOVersion) async throws {
            if pep.refused.contains(version) { throw Refused() }
            pep.setList(DeviceList(deviceIDs: deviceIDs, version: version).element, of: account)
        }

        func bundle(of jid: JID, deviceID: UInt32, version: OMEMOVersion) async throws -> PreKeyBundle {
            guard !pep.refused.contains(version),
                  let element = pep.lock.withLock({ pep.bundles["\(version.rawValue) \(jid.bare)/\(deviceID)"] }) else {
                throw OMEMOProtocolError.bundleNotFound(jid, deviceID)
            }
            return try PreKeyBundle(element: element, deviceID: deviceID)
        }

        func publishBundle(_ bundle: PreKeyBundle) async throws {
            if pep.refused.contains(bundle.version) { throw Refused() }
            pep.lock.withLock { pep.bundlePublishes += 1 }
            pep.setBundle(bundle.element, of: account, deviceID: bundle.deviceID)
        }
    }
}

/// Sends through XML, as the real transport would.
func overTheWire(_ message: EncryptedMessage) throws -> EncryptedMessage {
    let stanza = Message.omemo(message, to: try JID("somebody@example.org"))
    let parsed = try Element(xmlFragment: stanza.element.xmlString)
    guard let encrypted = Message(parsed)?.omemoEncrypted else { throw OMEMOCryptoError.malformed }
    return encrypted
}

final class Box: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?
    var value: String? { lock.withLock { stored } }
    func set(_ value: String?) { lock.withLock { stored = value } }
}

/// An in-memory store whose next commit can be made to fail, as if the
/// process died just before it.
final class FailingCommitStore: OMEMOStore, @unchecked Sendable {
    struct Crash: Error {}
    private let base = InMemoryOMEMOStore()
    private let lock = NSLock()
    private var fail = false
    var failNextCommit: Bool {
        get { lock.withLock { fail } }
        set { lock.withLock { fail = newValue } }
    }

    func localDevice() throws -> LocalDevice? { try base.localDevice() }
    func session(with address: SessionAddress) throws -> Session? { try base.session(with: address) }
    func identity(of address: DeviceAddress) throws -> IdentityRecord? { try base.identity(of: address) }
    func identities(of jid: JID) throws -> [UInt32: IdentityRecord] { try base.identities(of: jid) }
    func deviceIDs(of jid: JID, version: OMEMOVersion) throws -> [UInt32]? { try base.deviceIDs(of: jid, version: version) }
    func saveDeviceIDs(_ deviceIDs: [UInt32], of jid: JID, version: OMEMOVersion) throws {
        try base.saveDeviceIDs(deviceIDs, of: jid, version: version)
    }
    func commit(_ changes: OMEMOChanges) throws {
        if lock.withLock({ defer { fail = false }; return fail }) { throw Crash() }
        try base.commit(changes)
    }
}
