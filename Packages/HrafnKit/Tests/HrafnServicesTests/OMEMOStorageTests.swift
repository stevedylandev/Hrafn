import Foundation
import GRDB
import Testing
import OMEMOCrypto
import OMEMOProtocol
@testable import HrafnServices
import HrafnStore
import XMPPCore

/// OMEMOKit's engine on the app's storage: GRDB for state, the credential
/// store (the keychain in the app) for the identity's private key.
@Suite struct OMEMOStorageTests {
    let alice = try! JID("alice@example.org")
    let bob = try! JID("bob@example.net")
    let pep = MemoryDirectory()

    /// A new engine over the same storage, as a restarted app or the
    /// notification service extension would make.
    func engine(_ jid: JID, _ db: OMEMODatabase, _ credentials: any CredentialStore,
                setUp: Bool = true) async throws -> OMEMOEngine {
        let engine = OMEMOEngine(account: jid, store: DatabaseOMEMOStore(accountID: jid.description, database: db,
                                                                         credentials: credentials),
                                 directory: pep.directory(for: jid))
        if setUp { try await engine.setUp() }
        return engine
    }

    @Test func survivesRestarts() async throws {
        let aliceDB = try OMEMODatabase(), bobDB = try OMEMODatabase()
        let aliceKeys = InMemoryCredentialStore(), bobKeys = InMemoryCredentialStore()
        var a = try await engine(alice, aliceDB, aliceKeys)
        var b = try await engine(bob, bobDB, bobKeys)
        let aliceID = await a.deviceID

        for round in 0..<4 {
            let m = try await a.encrypt("to bob \(round)", to: [bob])
            #expect(try await b.decrypt(m.message, from: alice).body == "to bob \(round)")
            let r = try await b.encrypt("to alice \(round)", to: [alice])
            #expect(try await a.decrypt(r.message, from: bob).body == "to alice \(round)")
            // Both "processes" restart; nothing is kept in memory.
            a = try await engine(alice, aliceDB, aliceKeys)
            b = try await engine(bob, bobDB, bobKeys)
        }
        let finalID = await a.deviceID
        #expect(finalID == aliceID)
        // Decrypting without setUp works too (the extension skips it).
        let late = try await engine(bob, bobDB, bobKeys, setUp: false)
        let m = try await a.encrypt("no setUp", to: [bob])
        #expect(try await late.decrypt(m.message, from: alice).body == "no setUp")
    }

    /// The identity's private key is in the credential store, and nowhere in
    /// the database.
    @Test func identityKeyOnlyInTheKeychain() async throws {
        let db = try OMEMODatabase(), keys = InMemoryCredentialStore()
        _ = try await engine(alice, db, keys)
        let stored = try keys.omemoIdentityKey(for: alice.description)
        let secret = try #require(stored)
        #expect(secret.count == 32)
        let blobs = try await db.writer.read { db in
            try Data.fetchAll(db, sql: "SELECT state FROM device UNION ALL SELECT state FROM session")
        }
        #expect(!blobs.isEmpty)
        for blob in blobs {
            #expect(blob.range(of: secret) == nil)
            #expect(blob.range(of: Data(secret.base64EncodedString().utf8)) == nil)
        }
    }

    /// The keychain lost the key (the database came from elsewhere): a new
    /// device, no old sessions, the identities seen still remembered.
    @Test func lostIdentityStartsANewDevice() async throws {
        let aliceDB = try OMEMODatabase(), aliceKeys = InMemoryCredentialStore()
        let bobDB = try OMEMODatabase(), bobKeys = InMemoryCredentialStore()
        let a = try await engine(alice, aliceDB, aliceKeys)
        let b = try await engine(bob, bobDB, bobKeys)
        let m = try await a.encrypt("hi", to: [bob])
        _ = try await b.decrypt(m.message, from: alice)
        let oldID = await b.deviceID!

        try bobKeys.setOMEMOIdentityKey(nil, for: bob.description)
        let fresh = try await engine(bob, bobDB, bobKeys)
        #expect(await fresh.deviceID != oldID)
        let aliceID = await a.deviceID!
        let aliceAddress = DeviceAddress(jid: alice, deviceID: aliceID)
        let store = DatabaseOMEMOStore(accountID: bob.description, database: bobDB, credentials: bobKeys)
        #expect(try store.session(with: SessionAddress(aliceAddress, .legacy)) == nil)
        #expect(try store.identity(of: aliceAddress) != nil)
        let freshID = await fresh.deviceID!
        let published = try await pep.directory(for: alice).deviceList(of: bob, version: .legacy)
        #expect(published.contains(freshID))
    }

    /// A keychain that cannot be read yet (before first unlock) is an
    /// error, not a lost key: nothing is reset.
    @Test func lockedKeychainResetsNothing() async throws {
        let db = try OMEMODatabase(), keys = InMemoryCredentialStore()
        let first = try await engine(alice, db, keys)
        let id = await first.deviceID
        let locked = LockedCredentials(base: keys)
        let store = DatabaseOMEMOStore(accountID: alice.description, database: db, credentials: locked)
        #expect(throws: LockedCredentials.Locked.self) { try store.localDevice() }
        #expect(try db.device(accountID: alice.description)?.deviceID == id)
    }

    /// A message stored by `persist` but whose session was never committed
    /// (the process died) decrypts again, and is deduplicated by the caller.
    @Test func persistRunsBeforeTheSessionIsCommitted() async throws {
        let aliceDB = try OMEMODatabase(), aliceKeys = InMemoryCredentialStore()
        let bobDB = try OMEMODatabase(), bobKeys = InMemoryCredentialStore()
        let a = try await engine(alice, aliceDB, aliceKeys)
        let b = try await engine(bob, bobDB, bobKeys)
        let m = try await a.encrypt("once", to: [bob])
        let aliceAddress = DeviceAddress(jid: alice, deviceID: m.message.senderDeviceID)
        let store = DatabaseOMEMOStore(accountID: bob.description, database: bobDB, credentials: bobKeys)

        let sawSession = Flag()
        _ = try await b.decrypt(m.message, from: alice) { _ in
            sawSession.set((try? store.session(with: SessionAddress(aliceAddress, .legacy))) != nil)
        }
        #expect(sawSession.value == false)
        #expect(try store.session(with: SessionAddress(aliceAddress, .legacy)) != nil)
    }
}

// MARK: - Support

/// Device lists and bundles in memory, as PEP would hold them.
final class MemoryDirectory: @unchecked Sendable {
    private let lock = NSLock()
    private var lists: [String: [UInt32]] = [:]
    private var bundles: [String: PreKeyBundle] = [:]

    func directory(for account: JID) -> OMEMODirectory { Directory(owner: self, account: account.bare) }

    struct Directory: OMEMODirectory {
        let owner: MemoryDirectory
        let account: JID

        func deviceList(of jid: JID, version: OMEMOVersion) async throws -> [UInt32] {
            owner.lock.withLock { owner.lists["\(version.rawValue) \(jid.bare)"] ?? [] }
        }
        func publishDeviceList(_ deviceIDs: [UInt32], version: OMEMOVersion) async throws {
            owner.lock.withLock { owner.lists["\(version.rawValue) \(account)"] = deviceIDs }
        }
        func bundle(of jid: JID, deviceID: UInt32, version: OMEMOVersion) async throws -> PreKeyBundle {
            guard let bundle = owner.lock.withLock({ owner.bundles["\(version.rawValue) \(jid.bare)/\(deviceID)"] }) else {
                throw OMEMOProtocolError.bundleNotFound(jid, deviceID)
            }
            return bundle
        }
        func publishBundle(_ bundle: PreKeyBundle) async throws {
            owner.lock.withLock { owner.bundles["\(bundle.version.rawValue) \(account)/\(bundle.deviceID)"] = bundle }
        }
    }
}

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool?
    var value: Bool? { lock.withLock { stored } }
    func set(_ value: Bool) { lock.withLock { stored = value } }
}

/// Credentials whose OMEMO key cannot be read, like the keychain before the
/// first unlock (`errSecInteractionNotAllowed`).
struct LockedCredentials: CredentialStore {
    struct Locked: Error {}
    let base: InMemoryCredentialStore

    func password(for accountID: String) throws -> String? { try base.password(for: accountID) }
    func setPassword(_ password: String, for accountID: String) throws { try base.setPassword(password, for: accountID) }
    func removePassword(for accountID: String) throws { try base.removePassword(for: accountID) }
    func omemoIdentityKey(for accountID: String) throws -> Data? { throw Locked() }
    func setOMEMOIdentityKey(_ key: Data?, for accountID: String) throws { throw Locked() }
}
