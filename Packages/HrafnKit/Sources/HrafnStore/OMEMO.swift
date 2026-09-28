import Foundation
import GRDB

/// One OMEMO operation's writes, applied in one transaction. The state is
/// opaque to the store: OMEMOKit encodes it, HrafnServices maps it.
public struct OMEMOWrite: Sendable {
    public struct Session: Sendable {
        public var jid: String
        public var deviceID: UInt32
        /// The OMEMO version spoken, as OMEMOKit names it ("0.3", "2").
        public var version: String
        public var state: Data

        public init(jid: String, deviceID: UInt32, version: String, state: Data) {
            self.jid = jid
            self.deviceID = deviceID
            self.version = version
            self.state = state
        }
    }

    public struct Identity: Sendable {
        public var jid: String
        public var deviceID: UInt32
        public var key: Data
        public var trust: String

        public init(jid: String, deviceID: UInt32, key: Data, trust: String) {
            self.jid = jid
            self.deviceID = deviceID
            self.key = key
            self.trust = trust
        }
    }

    /// This device's id, state (without the identity's private key) and
    /// public identity key.
    public var device: (deviceID: UInt32, state: Data, identityKey: Data)?
    public var sessions: [Session] = []
    /// Identity keys seen for the first time, or changed: they replace what
    /// is stored for the device. The user's trust decisions are written with
    /// `setTrust` instead.
    public var identities: [Identity] = []

    public init() {}
}

/// OMEMO state: this device's keys (less the identity's private key, which
/// is in the keychain), sessions, identities seen, device lists. Sessions
/// and lists are per OMEMO version ("0.3", "2"); identities and trust per
/// device, whichever version.
///
/// A file of its own, excluded from backups. Ratchet state must never be
/// restored: an older copy would encrypt new messages with message keys
/// already used. After a restore the file is simply gone and the device
/// starts over with a new identity, as a new device should.
public final class OMEMODatabase: Sendable {

    public let writer: any DatabaseWriter

    /// Opens (creating if needed) `OMEMO.sqlite` in `directory`, a directory
    /// of its own: the exclusion from backups is set on the directory, so it
    /// covers SQLite's `-wal` and `-shm` files too.
    public init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var excluded = URLResourceValues()
        excluded.isExcludedFromBackup = true
        var directory = directory
        try directory.setResourceValues(excluded)
        var configuration = Configuration()
        // Shared with the notification service extension, like HrafnDatabase.
        configuration.busyMode = .timeout(5)
        configuration.observesSuspensionNotifications = true
        writer = try DatabasePool(path: directory.appending(path: "OMEMO.sqlite").path, configuration: configuration)
        try Self.migrator.migrate(writer)
    }

    /// An in-memory database, for tests.
    public init() throws {
        writer = try DatabaseQueue()
        try Self.migrator.migrate(writer)
    }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            // Accounts live in the other file: rows are removed with
            // `deleteAccount` rather than by a foreign key.
            try db.create(table: "device") { t in
                t.primaryKey("accountID", .text)
                t.column("deviceID", .integer).notNull()
                t.column("state", .blob).notNull()
            }
            // One Double Ratchet session per remote device.
            try db.create(table: "session") { t in
                t.column("accountID", .text).notNull()
                t.column("jid", .text).notNull()
                t.column("deviceID", .integer).notNull()
                t.column("state", .blob).notNull()
                t.primaryKey(["accountID", "jid", "deviceID"])
            }
            // The identity key first seen for each remote device.
            try db.create(table: "identity") { t in
                t.column("accountID", .text).notNull()
                t.column("jid", .text).notNull()
                t.column("deviceID", .integer).notNull()
                t.column("identityKey", .blob).notNull()
                t.column("firstSeen", .datetime).notNull()
                t.primaryKey(["accountID", "jid", "deviceID"])
            }
            // Device lists as last published, a cache.
            try db.create(table: "deviceList") { t in
                t.column("accountID", .text).notNull()
                t.column("jid", .text).notNull()
                t.column("deviceIDs", .jsonText).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.primaryKey(["accountID", "jid"])
            }
        }
        migrator.registerMigration("v2") { db in
            // Trust (Blind Trust Before Verification, docs/OMEMO.md), and our
            // own public identity key, for the fingerprint screens.
            try db.alter(table: "identity") { t in
                t.add(column: "trust", .text).notNull().defaults(to: "blind")
            }
            try db.alter(table: "device") { t in
                t.add(column: "identityKey", .blob)
            }
        }
        migrator.registerMigration("v3") { db in
            // OMEMO 2: a device may have a session, and a list, in each
            // version. Everything before was OMEMO 0.3. The version joins the
            // primary keys, so the tables are rebuilt.
            try db.create(table: "session_v3") { t in
                t.column("accountID", .text).notNull()
                t.column("jid", .text).notNull()
                t.column("deviceID", .integer).notNull()
                t.column("version", .text).notNull()
                t.column("state", .blob).notNull()
                t.primaryKey(["accountID", "jid", "deviceID", "version"])
            }
            try db.execute(sql: """
                INSERT INTO session_v3 (accountID, jid, deviceID, version, state)
                SELECT accountID, jid, deviceID, '0.3', state FROM session
                """)
            try db.drop(table: "session")
            try db.rename(table: "session_v3", to: "session")

            try db.create(table: "deviceList_v3") { t in
                t.column("accountID", .text).notNull()
                t.column("jid", .text).notNull()
                t.column("version", .text).notNull()
                t.column("deviceIDs", .jsonText).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.primaryKey(["accountID", "jid", "version"])
            }
            try db.execute(sql: """
                INSERT INTO deviceList_v3 (accountID, jid, version, deviceIDs, updatedAt)
                SELECT accountID, jid, '0.3', deviceIDs, updatedAt FROM deviceList
                """)
            try db.drop(table: "deviceList")
            try db.rename(table: "deviceList_v3", to: "deviceList")
        }
        return migrator
    }
}

/// A device of a contact (or of our own account) as the trust screens show
/// it.
public struct OMEMODeviceIdentity: Sendable, Hashable, Identifiable {
    public var jid: String
    public var deviceID: UInt32
    /// The serialized identity key.
    public var key: Data
    /// `Trust`'s raw value in OMEMOKit: blind, verified, undecided, untrusted.
    public var trust: String
    public var firstSeen: Date
    /// In one of the account's device lists as last seen.
    public var isActive: Bool

    public var id: String { "\(jid)/\(deviceID)" }
}

extension OMEMODatabase {

    public func device(accountID: String) throws -> (deviceID: UInt32, state: Data)? {
        try writer.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT deviceID, state FROM device WHERE accountID = ?",
                                             arguments: [accountID]),
                  let id = UInt32(exactly: row["deviceID"] as Int64) else { return nil }
            return (id, row["state"])
        }
    }

    public func session(accountID: String, jid: String, deviceID: UInt32, version: String) throws -> Data? {
        try writer.read { db in
            try Data.fetchOne(db, sql: """
                SELECT state FROM session WHERE accountID = ? AND jid = ? AND deviceID = ? AND version = ?
                """, arguments: [accountID, jid, Int64(deviceID), version])
        }
    }

    public func identity(accountID: String, jid: String, deviceID: UInt32) throws -> (key: Data, trust: String)? {
        try writer.read { db in
            try Row.fetchOne(db, sql: "SELECT identityKey, trust FROM identity WHERE accountID = ? AND jid = ? AND deviceID = ?",
                             arguments: [accountID, jid, Int64(deviceID)]).map { ($0["identityKey"], $0["trust"]) }
        }
    }

    /// Every device known for `jid`, active ones first, then by id.
    public func identities(accountID: String, jid: String) throws -> [OMEMODeviceIdentity] {
        try writer.read { db in try Self.identities(db, accountID, jid) }
    }

    public func observeIdentities(accountID: String, jid: String) -> AsyncThrowingStream<[OMEMODeviceIdentity], any Error> {
        let values = ValueObservation.tracking { db in try Self.identities(db, accountID, jid) }.values(in: writer)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await value in values { continuation.yield(value) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func identities(_ db: Database, _ accountID: String, _ jid: String) throws -> [OMEMODeviceIdentity] {
        let active: Set<UInt32> = try String.fetchAll(db, sql: "SELECT deviceIDs FROM deviceList WHERE accountID = ? AND jid = ?",
                                                      arguments: [accountID, jid])
            .reduce(into: []) { active, json in
                active.formUnion((try? JSONDecoder().decode([UInt32].self, from: Data(json.utf8))) ?? [])
            }
        return try Row.fetchAll(db, sql: """
            SELECT deviceID, identityKey, trust, firstSeen FROM identity WHERE accountID = ? AND jid = ?
            """, arguments: [accountID, jid])
            .compactMap { row in
                guard let id = UInt32(exactly: row["deviceID"] as Int64) else { return nil }
                return OMEMODeviceIdentity(jid: jid, deviceID: id, key: row["identityKey"], trust: row["trust"],
                                           firstSeen: row["firstSeen"], isActive: active.contains(id))
            }
            .sorted { ($0.isActive ? 0 : 1, $0.deviceID) < ($1.isActive ? 0 : 1, $1.deviceID) }
    }

    /// The user's decision about a device. Applies only while the device
    /// still has `key`: a screen showing an old key cannot approve a new one.
    /// Returns whether it applied.
    @discardableResult
    public func setTrust(_ trust: String, accountID: String, jid: String, deviceID: UInt32, key: Data) throws -> Bool {
        try writer.write { db in
            try db.execute(sql: """
                UPDATE identity SET trust = ? WHERE accountID = ? AND jid = ? AND deviceID = ? AND identityKey = ?
                """, arguments: [trust, accountID, jid, Int64(deviceID), key])
            return db.changesCount > 0
        }
    }

    /// This device's id and public identity key.
    public func ownIdentity(accountID: String) throws -> (deviceID: UInt32, key: Data)? {
        try writer.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT deviceID, identityKey FROM device WHERE accountID = ?",
                                             arguments: [accountID]),
                  let id = UInt32(exactly: row["deviceID"] as Int64), let key: Data = row["identityKey"] else { return nil }
            return (id, key)
        }
    }

    public func commit(accountID: String, _ write: OMEMOWrite, now: Date = Date()) throws {
        try writer.write { db in
            if let device = write.device {
                try db.execute(sql: """
                    INSERT INTO device (accountID, deviceID, state, identityKey) VALUES (?, ?, ?, ?)
                    ON CONFLICT (accountID) DO UPDATE SET deviceID = excluded.deviceID, state = excluded.state,
                                                          identityKey = excluded.identityKey
                    """, arguments: [accountID, Int64(device.deviceID), device.state, device.identityKey])
            }
            for session in write.sessions {
                try db.execute(sql: """
                    INSERT INTO session (accountID, jid, deviceID, version, state) VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT (accountID, jid, deviceID, version) DO UPDATE SET state = excluded.state
                    """, arguments: [accountID, session.jid, Int64(session.deviceID), session.version, session.state])
            }
            for identity in write.identities {
                try db.execute(sql: """
                    INSERT INTO identity (accountID, jid, deviceID, identityKey, firstSeen, trust) VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT (accountID, jid, deviceID) DO UPDATE SET
                        identityKey = excluded.identityKey, trust = excluded.trust, firstSeen = excluded.firstSeen
                    """, arguments: [accountID, identity.jid, Int64(identity.deviceID), identity.key, now, identity.trust])
            }
        }
    }

    public func deviceIDs(accountID: String, jid: String, version: String) throws -> [UInt32]? {
        try writer.read { db in
            guard let json = try String.fetchOne(db, sql: """
                SELECT deviceIDs FROM deviceList WHERE accountID = ? AND jid = ? AND version = ?
                """, arguments: [accountID, jid, version]) else { return nil }
            return try JSONDecoder().decode([UInt32].self, from: Data(json.utf8))
        }
    }

    public func saveDeviceIDs(_ deviceIDs: [UInt32], accountID: String, jid: String, version: String,
                              now: Date = Date()) throws {
        let json = String(decoding: try JSONEncoder().encode(deviceIDs), as: UTF8.self)
        try writer.write { db in
            try db.execute(sql: """
                INSERT INTO deviceList (accountID, jid, version, deviceIDs, updatedAt) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT (accountID, jid, version) DO UPDATE SET deviceIDs = excluded.deviceIDs,
                                                                    updatedAt = excluded.updatedAt
                """, arguments: [accountID, jid, version, json, now])
        }
    }

    /// Forgets this device and every session, as when the identity's private
    /// key is gone: the ratchets are useless without it. What contacts'
    /// identities were is kept.
    public func resetDevice(accountID: String) throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM device WHERE accountID = ?", arguments: [accountID])
            try db.execute(sql: "DELETE FROM session WHERE accountID = ?", arguments: [accountID])
        }
    }

    /// Everything stored for an account, when it is removed.
    public func deleteAccount(accountID: String) throws {
        try writer.write { db in
            for table in ["device", "session", "identity", "deviceList"] {
                try db.execute(sql: "DELETE FROM \(table) WHERE accountID = ?", arguments: [accountID])
            }
        }
    }
}
