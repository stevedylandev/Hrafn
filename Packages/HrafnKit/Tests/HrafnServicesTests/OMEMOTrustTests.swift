import Foundation
import Testing
import OMEMOCrypto
import OMEMOProtocol
@testable import HrafnServices
import HrafnStore
import XMPPCore
import XMPPIM

/// The trust screens' side: devices with fingerprints, decisions, and
/// verification by scanned code.
@MainActor
@Suite struct OMEMOTrustTests {
    let juliet = try! JID("juliet@example.com")
    let romeo = try! JID("romeo@example.net")
    let pep = MemoryDirectory()
    let omemo = try! OMEMODatabase()
    let credentials = InMemoryCredentialStore()
    let manager: AccountManager
    let accountID = "juliet@example.com"

    init() throws {
        let database = try HrafnDatabase()
        // Disabled: listed by the manager, never connected.
        try database.save(Account(id: accountID, jid: juliet.description, enabled: false))
        manager = AccountManager(database: database, credentials: credentials, omemo: omemo)
    }

    /// Juliet's engine on the manager's storage, and Romeo with `devices`.
    func setUp(romeoDevices: Int = 1) async throws -> (OMEMOEngine, [OMEMOEngine]) {
        let julietEngine = OMEMOEngine(account: juliet, store: DatabaseOMEMOStore(accountID: accountID, database: omemo,
                                                                                  credentials: credentials),
                                       directory: pep.directory(for: juliet))
        try await julietEngine.setUp()
        var romeos: [OMEMOEngine] = []
        for _ in 0..<romeoDevices {
            let engine = OMEMOEngine(account: romeo, store: InMemoryOMEMOStore(), directory: pep.directory(for: romeo))
            try await engine.setUp()
            romeos.append(engine)
        }
        _ = try await julietEngine.encrypt("hi", to: [romeo])
        return (julietEngine, romeos)
    }

    func devices() throws -> [OMEMODevice] {
        try omemo.identities(accountID: accountID, jid: romeo.description).map(AccountManager.device)
    }

    func uri(for engines: [OMEMOEngine]) async -> XMPPURI {
        var fingerprints: [UInt32: String] = [:]
        for engine in engines {
            let key = await engine.identityKey!
            fingerprints[await engine.deviceID!] = key.rawRepresentation.map { String(format: "%02x", $0) }.joined()
        }
        return XMPPURI(jid: romeo, omemoFingerprints: fingerprints)
    }

    @Test func devicesShowFingerprintsAndTrust() async throws {
        let (_, romeos) = try await setUp(romeoDevices: 2)
        let shown = try devices()
        #expect(shown.count == 2)
        #expect(shown.allSatisfy { $0.trust == .blind && $0.isActive })
        let key = await romeos[0].identityKey!
        #expect(shown.contains { $0.fingerprint == key.fingerprint })
        #expect(manager.ownOMEMODevice(accountID: accountID)?.fingerprint.split(separator: " ").count == 8)
    }

    @Test func scanningVerifies() async throws {
        let (julietEngine, romeos) = try await setUp(romeoDevices: 2)
        let result = try manager.verify(await uri(for: [romeos[0]]), accountID: accountID)
        #expect(result.verified == [await romeos[0].deviceID!])
        #expect(try devices().first { $0.deviceID == result.verified[0] }?.trust == .verified)

        // A new device after verification waits.
        let third = OMEMOEngine(account: romeo, store: InMemoryOMEMOStore(), directory: pep.directory(for: romeo))
        try await third.setUp()
        try await julietEngine.deviceListChanged(try await pep.directory(for: juliet).deviceList(of: romeo, version: .legacy), of: romeo, version: .legacy)
        let sent = try await julietEngine.encrypt("x", to: [romeo])
        let thirdID = await third.deviceID!
        #expect(!sent.message.keys.contains { $0.deviceID == thirdID })
        #expect(try devices().first { $0.deviceID == thirdID }?.trust == .undecided)

        // The user trusts it.
        let pending = try #require(try devices().first { $0.deviceID == thirdID })
        try manager.setTrust(.blind, of: pending, accountID: accountID)
        let again = try await julietEngine.encrypt("y", to: [romeo])
        #expect(again.message.keys.contains { $0.deviceID == thirdID })
    }

    /// A code whose key differs from what we know verifies nothing.
    @Test func mismatchVerifiesNothing() async throws {
        let (_, romeos) = try await setUp()
        let id = await romeos[0].deviceID!
        let wrong = XMPPURI(jid: romeo, omemoFingerprints: [id: String(repeating: "00", count: 32), 99: String(repeating: "11", count: 32)])
        let result = try manager.verify(wrong, accountID: accountID)
        #expect(result == OMEMOVerification(verified: [], mismatched: [id], unknown: [99]))
        #expect(try devices().allSatisfy { $0.trust == .blind })
    }

    /// A decision made on a screen showing an old key does not apply to a
    /// new one.
    @Test func staleDecisionIsIgnored() async throws {
        _ = try await setUp()
        var device = try #require(try devices().first)
        device.key = Data([0x05] + [UInt8](repeating: 1, count: 32))
        try manager.setTrust(.verified, of: device, accountID: accountID)
        #expect(try devices().first?.trust == .blind)
    }

    @Test func ownURI() async throws {
        _ = try await setUp()
        await manager.start()
        let uri = try #require(manager.verificationURI(accountID: accountID))
        let own = try #require(manager.ownOMEMODevice(accountID: accountID))
        #expect(uri.jid == juliet)
        #expect(uri.omemoFingerprints[own.deviceID]?.count == 64)
        #expect(XMPPURI(uri.description) == uri)
    }
}
