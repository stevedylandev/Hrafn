import Testing
import Foundation
import GRDB
@testable import HrafnStore

private let romeo = "romeo@example.net"

private func makeStore() throws -> (HrafnDatabase, Account) {
    let database = try HrafnDatabase()
    let account = Account(jid: "juliet@example.com")
    try database.save(account)
    return (database, account)
}

private func file(_ account: Account, url: String, id: String, archiveID: String? = nil, outgoing: Bool = false,
                  read: Bool = false) -> MessageEvent {
    let url = URL(string: url)!
    return MessageEvent(accountID: account.id, peer: romeo, isOutgoing: outgoing,
                        content: .body(url.absoluteString, markable: true), senderID: id, stanzaID: id,
                        archiveID: archiveID, alreadyRead: read,
                        attachment: Attachment(url: url, fileName: url.lastPathComponent, mimeType: "image/png"))
}

@Suite struct AttachmentStoreTests {

    @Test func storesAttachmentsAndKeepsThemAcrossCopies() throws {
        let (database, account) = try makeStore()
        let result = try database.ingest(file(account, url: "https://up.example.net/a/cat.png", id: "f1"))
        guard case .inserted(let id) = result else { Issue.record("not inserted: \(result)"); return }
        let row = try #require(try database.message(id: id))
        #expect(row.attachment?.fileName == "cat.png")
        #expect(row.attachment?.kind == .image)
        #expect(row.preview == "📷 Photo")

        // The archive copy merges into the same row, attachment intact.
        #expect(try database.ingest(file(account, url: "https://up.example.net/a/cat.png", id: "f1", archiveID: "A1"))
                == .merged(id))
        #expect(try database.message(id: id)?.attachment?.url?.absoluteString == "https://up.example.net/a/cat.png")
    }

    @Test func awaitingDownloadIsUnreadUndecidedAndRemote() throws {
        let (database, account) = try makeStore()
        try database.ingest(file(account, url: "https://up.example.net/1.png", id: "1"))
        try database.ingest(file(account, url: "https://up.example.net/2.png", id: "2", read: true))
        try database.ingest(MessageEvent(accountID: account.id, peer: romeo, isOutgoing: false,
                                         content: .body("plain", markable: true), senderID: "3"))
        var waiting = try database.attachmentsAwaitingDownload(accountID: account.id)
        #expect(waiting.map(\.originID) == ["1"])

        _ = try database.updateAttachment(messageID: waiting[0].id!) { $0.autoDownloadConsidered = true }
        waiting = try database.attachmentsAwaitingDownload(accountID: account.id)
        #expect(waiting.isEmpty)
    }

    @Test func outgoingFilesWaitForTheirUpload() throws {
        let (database, account) = try makeStore()
        let row = try database.insertOutgoing(
            accountID: account.id, peer: romeo,
            attachment: Attachment(fileName: "note.m4a", mimeType: "audio/mp4", localPath: "x/note.m4a",
                                   isVoiceMessage: true, autoDownloadConsidered: true),
            id: "o1")
        #expect(row.body.isEmpty)
        #expect(row.state == .pending)
        #expect(row.attachment?.needsUpload == true)
        #expect(row.preview == "🎤 Voice message")
        #expect(try database.outbox(accountID: account.id).map(\.id) == [row.id])
        // Our own files are never offered for download.
        #expect(try database.attachmentsAwaitingDownload(accountID: account.id).isEmpty)

        let url = URL(string: "https://up.example.com/x/note.m4a")!
        let done = try #require(try database.completeUpload(messageID: row.id!, url: url))
        #expect(done.body == url.absoluteString)
        #expect(done.attachment?.url == url && done.attachment?.localPath == "x/note.m4a")
        #expect(try database.localAttachmentPaths(accountID: account.id) == ["x/note.m4a"])
    }

    @Test func decodesAttachmentsWithMissingFields() throws {
        let json = #"{"url":"https://e.example/a.bin","fileName":"a.bin"}"#
        let attachment = try JSONDecoder().decode(Attachment.self, from: Data(json.utf8))
        #expect(attachment.fileName == "a.bin" && !attachment.isVoiceMessage && !attachment.autoDownloadConsidered)
        #expect(attachment.kind == .file)
    }
}

@Suite struct ProfileStoreTests {

    @Test func profilesNameConversationsAndExpire() throws {
        let (database, account) = try makeStore()
        try database.replaceRoster(accountID: account.id, entries: [
            RosterEntry(jid: romeo, name: nil, subscription: .both, pendingOut: false, groups: []),
            RosterEntry(jid: "nurse@example.com", name: "Nurse", subscription: .both, pendingOut: false, groups: []),
        ], version: nil)
        try database.openConversation(accountID: account.id, peer: romeo)
        #expect(try database.profilesToRefresh(accountID: account.id, checkedBefore: Date()).sorted()
                == ["nurse@example.com", romeo])

        try database.updateProfile(accountID: account.id, jid: romeo) {
            $0.nickname = "Romeo M."
            $0.avatarHash = "abc"
            $0.checkedAt = Date()
        }
        #expect(try database.profilesToRefresh(accountID: account.id, checkedBefore: Date().addingTimeInterval(-60))
                == ["nurse@example.com"])
        let summary = try database.writer.read { db in try HrafnDatabase.conversationSummaries(db) }.first
        #expect(summary?.title == "Romeo M.")
        #expect(summary?.profile?.avatarHash == "abc")
        #expect(try database.avatarHashesInUse() == ["abc"])
    }
}
