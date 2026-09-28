import Foundation
import GRDB

// MARK: - Accounts

extension HrafnDatabase {

    public func allAccounts() throws -> [Account] {
        try writer.read { db in try Account.order(Column("createdAt")).fetchAll(db) }
    }

    public func account(id: String) throws -> Account? {
        try writer.read { db in try Account.fetchOne(db, key: id) }
    }

    public func save(_ account: Account) throws {
        try writer.write { db in try account.save(db) }
    }

    /// Deletes the account and everything stored for it.
    public func deleteAccount(id: String) throws {
        _ = try writer.write { db in try Account.deleteOne(db, key: id) }
    }
}

// MARK: - Roster

/// A roster item as the store takes it, free of protocol types.
public struct RosterEntry: Sendable, Hashable {
    public var jid: String
    public var name: String?
    public var subscription: Contact.Subscription
    public var pendingOut: Bool
    public var groups: [String]

    public init(jid: String, name: String?, subscription: Contact.Subscription, pendingOut: Bool, groups: [String]) {
        self.jid = jid
        self.name = name
        self.subscription = subscription
        self.pendingOut = pendingOut
        self.groups = groups
    }
}

extension HrafnDatabase {

    /// Replaces the cached roster with a full one from the server. Contacts
    /// that are only pending inbound requests survive.
    public func replaceRoster(accountID: String, entries: [RosterEntry], version: String?) throws {
        try writer.write { db in
            let pendingIn = Set(try String.fetchAll(db, sql:
                "SELECT jid FROM contact WHERE accountID = ? AND pendingIn", arguments: [accountID]))
            try Contact.filter(Column("accountID") == accountID).deleteAll(db)
            for entry in entries {
                try Self.contact(accountID: accountID, entry: entry, pendingIn: pendingIn.contains(entry.jid)).insert(db)
            }
            for jid in pendingIn where !entries.contains(where: { $0.jid == jid }) {
                try Contact(accountID: accountID, jid: jid, pendingIn: true, inRoster: false).insert(db)
            }
            try db.execute(sql: "UPDATE account SET rosterVersion = ? WHERE id = ?", arguments: [version, accountID])
        }
    }

    /// Applies a roster push (`removed`: `subscription='remove'`).
    public func applyRosterPush(accountID: String, entry: RosterEntry, removed: Bool, version: String?) throws {
        try writer.write { db in
            let existing = try Contact.fetchOne(db, key: ["accountID": accountID, "jid": entry.jid])
            if removed {
                if existing?.pendingIn == true {
                    try Contact(accountID: accountID, jid: entry.jid, pendingIn: true, inRoster: false).save(db)
                } else {
                    try Contact.deleteOne(db, key: ["accountID": accountID, "jid": entry.jid])
                }
            } else {
                // Once they are subscribed to us, their request is answered.
                let pendingIn = (existing?.pendingIn ?? false) && !(entry.subscription == .from || entry.subscription == .both)
                try Self.contact(accountID: accountID, entry: entry, pendingIn: pendingIn).save(db)
            }
            if let version {
                try db.execute(sql: "UPDATE account SET rosterVersion = ? WHERE id = ?", arguments: [version, accountID])
            }
        }
    }

    /// Records or clears an inbound subscription request.
    public func setPendingIn(accountID: String, jid: String, _ pending: Bool) throws {
        try writer.write { db in
            if var contact = try Contact.fetchOne(db, key: ["accountID": accountID, "jid": jid]) {
                contact.pendingIn = pending
                if !pending && !contact.inRoster {
                    try contact.delete(db)
                } else {
                    try contact.update(db)
                }
            } else if pending {
                try Contact(accountID: accountID, jid: jid, pendingIn: true, inRoster: false).insert(db)
            }
        }
    }

    public func fetchContacts(accountID: String) throws -> [Contact] {
        try writer.read { db in try Contact.filter(Column("accountID") == accountID).fetchAll(db) }
    }

    private static func contact(accountID: String, entry: RosterEntry, pendingIn: Bool) -> Contact {
        Contact(accountID: accountID, jid: entry.jid, name: entry.name, subscription: entry.subscription,
                pendingOut: entry.pendingOut, pendingIn: pendingIn, inRoster: true, groups: entry.groups)
    }
}

// MARK: - Blocking

extension HrafnDatabase {

    public func replaceBlocklist(accountID: String, jids: [String]) throws {
        try writer.write { db in
            try BlockedJID.filter(Column("accountID") == accountID).deleteAll(db)
            for jid in Set(jids) { try BlockedJID(accountID: accountID, jid: jid).insert(db) }
        }
    }

    public func setBlocked(accountID: String, jids: [String], _ blocked: Bool) throws {
        try writer.write { db in
            for jid in jids {
                if blocked {
                    try BlockedJID(accountID: accountID, jid: jid).insert(db, onConflict: .ignore)
                } else {
                    try BlockedJID.deleteOne(db, key: ["accountID": accountID, "jid": jid])
                }
            }
        }
    }

    public func isBlocked(accountID: String, jid: String) throws -> Bool {
        try writer.read { db in try BlockedJID.exists(db, key: ["accountID": accountID, "jid": jid]) }
    }
}

// MARK: - Archive cursors

extension HrafnDatabase {

    public func archiveCursor(accountID: String, archive: String) throws -> ArchiveCursor? {
        try writer.read { db in try ArchiveCursor.fetchOne(db, key: ["accountID": accountID, "archive": archive]) }
    }

    public func setArchiveCursor(_ cursor: ArchiveCursor) throws {
        try writer.write { db in try cursor.save(db) }
    }
}
