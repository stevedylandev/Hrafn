import Foundation
import GRDB
import Testing
@testable import HrafnStore

@Suite struct EncryptionStoreTests {
    let database = try! HrafnDatabase()
    let account = Account(jid: "juliet@example.com")
    let romeo = "romeo@example.net"

    init() throws { try database.save(account) }

    func body(_ text: String, archiveID: String? = nil, senderID: String? = nil,
              encryption: MessageEncryption?) -> MessageEvent {
        MessageEvent(accountID: account.id, peer: romeo, isOutgoing: false, content: .body(text, markable: true),
                     senderID: senderID, archiveID: archiveID, encryption: encryption)
    }

    func rows() throws -> [StoredMessage] {
        try database.writer.read { db in try StoredMessage.order(Column("id")).fetchAll(db) }
    }

    /// The first encrypted message decides an undecided conversation.
    @Test func firstEncryptedMessageDecides() throws {
        try database.ingest(body("plain", senderID: "a", encryption: nil))
        #expect(try database.conversationEncryption(accountID: account.id, peer: romeo) == nil)
        try database.ingest(body("secret", senderID: "b", encryption: .omemo))
        #expect(try database.conversationEncryption(accountID: account.id, peer: romeo) == .omemo)
        #expect(try rows().map(\.encryption) == [nil, .omemo])
    }

    /// …but never overrides the user's choice.
    @Test func userChoiceStands() throws {
        try database.setConversationEncryption(accountID: account.id, peer: romeo, .off)
        try database.ingest(body("secret", senderID: "b", encryption: .omemo))
        #expect(try database.conversationEncryption(accountID: account.id, peer: romeo) == .off)
        try database.setConversationEncryption(accountID: account.id, peer: romeo, nil)
        #expect(try database.conversationEncryption(accountID: account.id, peer: romeo) == nil)
    }

    /// A placeholder is replaced by a decrypted copy, found by archive id or
    /// by the sender's id; a placeholder never replaces text.
    @Test func placeholdersUpgrade() throws {
        try database.ingest(body("🔒", archiveID: "s1", senderID: "m1", encryption: .undecryptable))
        #expect(try database.ingest(body("hello", archiveID: "s1", senderID: "m1", encryption: .omemo)) != .duplicate)
        try database.ingest(body("🔒", senderID: "m2", encryption: .undecryptable))
        try database.ingest(body("again", senderID: "m2", encryption: .omemo))
        try database.ingest(body("kept", senderID: "m3", encryption: .omemo))
        #expect(try database.ingest(body("🔒", senderID: "m3", encryption: .undecryptable)) == .duplicate)
        #expect(try rows().map(\.body) == ["hello", "again", "kept"])
        #expect(try rows().allSatisfy { $0.encryption == .omemo })
    }

    @Test func outgoing() throws {
        let row = try database.insertOutgoing(accountID: account.id, peer: romeo, body: "x", id: "o1")
        #expect(row.encryption == nil)
        try database.setEncryption(messageID: row.id!, .omemo)
        #expect(try database.message(id: row.id!)?.encryption == .omemo)
        #expect(try database.conversationEncryption(accountID: account.id, peer: romeo) == .omemo)
    }
}
