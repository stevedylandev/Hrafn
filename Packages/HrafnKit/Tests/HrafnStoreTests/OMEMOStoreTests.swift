import Foundation
import GRDB
import Testing
@testable import HrafnStore

@Suite struct OMEMOStoreTests {
    let db = try! OMEMODatabase()

    @Test func commitsAndReads() throws {
        var write = OMEMOWrite()
        write.device = (42, Data([1, 2]), Data([0x05, 9]))
        write.sessions = [.init(jid: "bob@example.net", deviceID: 7, version: "0.3", state: Data([3]))]
        write.identities = [.init(jid: "bob@example.net", deviceID: 7, key: Data([4]), trust: "blind")]
        try db.commit(accountID: "a", write)

        #expect(try db.device(accountID: "a")?.deviceID == 42)
        #expect(try db.device(accountID: "a")?.state == Data([1, 2]))
        #expect(try db.ownIdentity(accountID: "a")?.key == Data([0x05, 9]))
        #expect(try db.session(accountID: "a", jid: "bob@example.net", deviceID: 7, version: "0.3") == Data([3]))
        #expect(try db.identity(accountID: "a", jid: "bob@example.net", deviceID: 7)?.key == Data([4]))
        #expect(try db.identity(accountID: "a", jid: "bob@example.net", deviceID: 7)?.trust == "blind")
        #expect(try db.device(accountID: "b") == nil)

        // The engine replaces a changed identity (undecided).
        write = OMEMOWrite()
        write.sessions = [.init(jid: "bob@example.net", deviceID: 7, version: "0.3", state: Data([5]))]
        write.identities = [.init(jid: "bob@example.net", deviceID: 7, key: Data([6]), trust: "undecided")]
        try db.commit(accountID: "a", write)
        #expect(try db.session(accountID: "a", jid: "bob@example.net", deviceID: 7, version: "0.3") == Data([5]))
        #expect(try db.identity(accountID: "a", jid: "bob@example.net", deviceID: 7)?.key == Data([6]))
        #expect(try db.identity(accountID: "a", jid: "bob@example.net", deviceID: 7)?.trust == "undecided")
    }

    /// The user's decision applies only to the key they were shown.
    @Test func trustNamesTheKey() throws {
        var write = OMEMOWrite()
        write.identities = [.init(jid: "bob@example.net", deviceID: 7, key: Data([4]), trust: "undecided"),
                            .init(jid: "bob@example.net", deviceID: 8, key: Data([5]), trust: "blind")]
        try db.commit(accountID: "a", write)
        try db.saveDeviceIDs([8], accountID: "a", jid: "bob@example.net", version: "0.3")

        #expect(try !db.setTrust("verified", accountID: "a", jid: "bob@example.net", deviceID: 7, key: Data([9])))
        #expect(try db.setTrust("verified", accountID: "a", jid: "bob@example.net", deviceID: 7, key: Data([4])))
        let devices = try db.identities(accountID: "a", jid: "bob@example.net")
        #expect(devices.map(\.deviceID) == [8, 7])   // active first
        #expect(devices.map(\.isActive) == [true, false])
        #expect(devices.map(\.trust) == ["blind", "verified"])
    }

    @Test func deviceIDs() throws {
        #expect(try db.deviceIDs(accountID: "a", jid: "bob@example.net", version: "0.3") == nil)
        try db.saveDeviceIDs([1, 0x7FFF_FFFF], accountID: "a", jid: "bob@example.net", version: "0.3")
        #expect(try db.deviceIDs(accountID: "a", jid: "bob@example.net", version: "0.3") == [1, 0x7FFF_FFFF])
        try db.saveDeviceIDs([], accountID: "a", jid: "bob@example.net", version: "0.3")
        #expect(try db.deviceIDs(accountID: "a", jid: "bob@example.net", version: "0.3") == [])
    }

    /// A device can have a session and a list in each version.
    @Test func versionsAreSeparate() throws {
        var write = OMEMOWrite()
        write.sessions = [.init(jid: "b@x", deviceID: 2, version: "0.3", state: Data([1])),
                          .init(jid: "b@x", deviceID: 2, version: "2", state: Data([2]))]
        write.identities = [.init(jid: "b@x", deviceID: 2, key: Data([9]), trust: "blind"),
                            .init(jid: "b@x", deviceID: 3, key: Data([8]), trust: "blind")]
        try db.commit(accountID: "a", write)
        #expect(try db.session(accountID: "a", jid: "b@x", deviceID: 2, version: "0.3") == Data([1]))
        #expect(try db.session(accountID: "a", jid: "b@x", deviceID: 2, version: "2") == Data([2]))

        try db.saveDeviceIDs([2], accountID: "a", jid: "b@x", version: "0.3")
        try db.saveDeviceIDs([3], accountID: "a", jid: "b@x", version: "2")
        #expect(try db.deviceIDs(accountID: "a", jid: "b@x", version: "2") == [3])
        // Active in either list.
        #expect(try db.identities(accountID: "a", jid: "b@x").map(\.isActive) == [true, true])
    }

    /// Sessions and lists from before OMEMO 2 become OMEMO 0.3's.
    @Test func migratesToVersions() throws {
        let queue = try DatabaseQueue()
        try OMEMODatabase.migrator.migrate(queue, upTo: "v2")
        try queue.write { db in
            try db.execute(sql: "INSERT INTO session (accountID, jid, deviceID, state) VALUES ('a', 'b@x', 2, x'01')")
            try db.execute(sql: """
                INSERT INTO deviceList (accountID, jid, deviceIDs, updatedAt) VALUES ('a', 'b@x', '[2]', '2026-01-01')
                """)
        }
        try OMEMODatabase.migrator.migrate(queue)
        let session = try queue.read { db in try Row.fetchOne(db, sql: "SELECT version, state FROM session") }
        #expect(session?["version"] == "0.3")
        #expect(session?["state"] == Data([1]))
        #expect(try queue.read { db in try String.fetchOne(db, sql: "SELECT version FROM deviceList") } == "0.3")
    }

    @Test func resetKeepsIdentitiesAndDeleteRemovesAll() throws {
        var write = OMEMOWrite()
        write.device = (1, Data(), Data())
        write.sessions = [.init(jid: "b@x", deviceID: 2, version: "0.3", state: Data())]
        write.identities = [.init(jid: "b@x", deviceID: 2, key: Data([9]), trust: "blind")]
        try db.commit(accountID: "a", write)
        try db.commit(accountID: "other", write)
        try db.saveDeviceIDs([2], accountID: "a", jid: "b@x", version: "0.3")

        try db.resetDevice(accountID: "a")
        #expect(try db.device(accountID: "a") == nil)
        #expect(try db.session(accountID: "a", jid: "b@x", deviceID: 2, version: "0.3") == nil)
        #expect(try db.identity(accountID: "a", jid: "b@x", deviceID: 2)?.key == Data([9]))

        try db.deleteAccount(accountID: "a")
        #expect(try db.identity(accountID: "a", jid: "b@x", deviceID: 2) == nil)
        #expect(try db.deviceIDs(accountID: "a", jid: "b@x", version: "0.3") == nil)
        #expect(try db.device(accountID: "other") != nil)
    }

    /// On disk: a directory of its own, excluded from backups, reopened with
    /// its data.
    @Test func excludedFromBackups() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "omemo-\(UUID().uuidString)/OMEMO")
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        do {
            let db = try OMEMODatabase(directory: directory)
            var write = OMEMOWrite()
            write.device = (5, Data([1]), Data())
            try db.commit(accountID: "a", write)
        }
        let values = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
        #expect(try OMEMODatabase(directory: directory).device(accountID: "a")?.deviceID == 5)
    }
}
