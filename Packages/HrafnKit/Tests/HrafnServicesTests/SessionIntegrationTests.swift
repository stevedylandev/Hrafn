import Testing
import Foundation
import CryptoKit
import GRDB
@testable import HrafnServices
import HrafnStore
import XMPPCore
import XMPPXML

/// Phase 4 exit behaviour end to end: sessions writing to the database against
/// the Docker servers. Off unless `HRAFN_INTEGRATION=1` (see XMPPKit's
/// `TestServers.swift` for bringing the servers up).
private let integrationEnabled = ProcessInfo.processInfo.environment["HRAFN_INTEGRATION"] == "1"
let devPassword = ProcessInfo.processInfo.environment["HRAFN_DEV_PASSWORD"] ?? "devpassword"

struct LiveServer: Sendable, CustomStringConvertible {
    let domain: String
    let directTLSPort: Int
    var description: String { domain }

    static let prosody = LiveServer(domain: "alpha.test", directTLSPort: 5223)
    static let ejabberd = LiveServer(domain: "beta.test", directTLSPort: 15223)

    /// The Docker CA is private, so the account pins the server's leaf — the
    /// same path a user takes to trust a self-signed server.
    var fingerprint: String {
        get throws {
            let root = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
            let pem = try String(contentsOf: root.appending(path: "docker/certs/\(domain).crt"), encoding: .utf8)
            let base64 = pem.replacingOccurrences(of: "-----BEGIN CERTIFICATE-----", with: "")
                .replacingOccurrences(of: "-----END CERTIFICATE-----", with: "").filter { !$0.isWhitespace }
            let der = try #require(Data(base64Encoded: base64))
            return SHA256.hash(data: der).map { String(format: "%02X", $0) }.joined()
        }
    }

    func account(_ user: String) throws -> Account {
        Account(jid: "\(user)@\(domain)", host: "127.0.0.1", port: directTLSPort, directTLS: true,
                trustedFingerprint: try fingerprint)
    }
}

/// Polls until `condition` holds.
@MainActor
func eventually(_ what: String, timeout: Duration = .seconds(10),
                _ condition: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if try await condition() { return }
        try await Task.sleep(for: .milliseconds(50))
    }
    Issue.record("timed out waiting for \(what)")
    throw AccountError.notConnected
}

@MainActor
final class Device {
    let database: HrafnDatabase
    let manager: AccountManager
    let account: Account

    init(_ user: String, on server: LiveServer, database: HrafnDatabase? = nil) async throws {
        self.database = try database ?? HrafnDatabase()
        let credentials = InMemoryCredentialStore()
        manager = AccountManager(database: self.database, credentials: credentials,
                                 console: ProcessInfo.processInfo.environment["HRAFN_XML"] == "1"
                                    ? RedactingXMLConsole(PrintXMLConsole()) : nil,
                                 loopbackHTTP: true)
        let template = try server.account(user)
        account = try await manager.addAccount(jid: template.jid, password: devPassword, host: template.host,
                                               port: template.port, directTLS: true,
                                               trustedFingerprint: template.trustedFingerprint)
        try await waitOnline()
    }

    var session: AccountSession { manager.session(for: account.id)! }
    var status: AccountStatus { manager.status(for: account.id) }

    func waitOnline() async throws {
        try await eventually("\(account.jid) online") { status.connection == .online && status.boundJID != nil }
        // Let the post-login sync (roster, carbons, presence, history) finish.
        try await Task.sleep(for: .milliseconds(500))
    }

    func messages(with peer: String) throws -> [StoredMessage] {
        try database.writer.read { db in
            try StoredMessage.filter(Column("accountID") == account.id && Column("peer") == peer)
                .order(Column("timestamp"), Column("id")).fetchAll(db)
        }
    }

    func unread(_ peer: String) throws -> Int? {
        try database.writer.read { db in
            try Conversation.fetchOne(db, key: ["accountID": account.id, "peer": peer])?.unreadCount
        }
    }

    func contact(_ jid: String) throws -> Contact? {
        try database.fetchContacts(accountID: account.id).first { $0.jid == jid }
    }
}

/// Runs `body`, then logs every device out cleanly whether it threw or not.
/// A session left open when the process exits is not closed politely, and
/// the server then routes its unacknowledged stanzas to offline storage — into
/// whichever test logs in as that user next.
@MainActor
func closing(_ devices: [Device], _ body: () async throws -> Void) async throws {
    do {
        try await body()
    } catch {
        for device in devices { await device.manager.stopAll() }
        throw error
    }
    for device in devices { await device.manager.stopAll() }
}

@Suite(.enabled(if: integrationEnabled), .serialized, .timeLimit(.minutes(2)))
@MainActor
struct SessionIntegrationTests {

    @Test func refusesAnUnpinnedPrivateCertificate() async throws {
        let manager = AccountManager(database: try HrafnDatabase(), credentials: InMemoryCredentialStore())
        let error = await #expect(throws: AccountError.self) {
            try await manager.addAccount(jid: "juliet@alpha.test", password: devPassword, host: "127.0.0.1", port: 5223)
        }
        guard case .untrustedCertificate(let fingerprint) = error else {
            Issue.record("expected untrustedCertificate, got \(String(describing: error))")
            return
        }
        #expect(fingerprint == (try LiveServer.prosody.fingerprint))
        #expect(manager.accounts.isEmpty)
    }

    @Test func rejectsAWrongPassword() async throws {
        let manager = AccountManager(database: try HrafnDatabase(), credentials: InMemoryCredentialStore())
        let template = try LiveServer.prosody.account("juliet")
        await #expect(throws: AccountError.self) {
            try await manager.addAccount(jid: template.jid, password: "wrong", host: template.host, port: template.port,
                                         trustedFingerprint: template.trustedFingerprint)
        }
    }

    /// Contacts, messaging with receipts and markers, catch-up after being
    /// offline, and the outbox — on one server and across two (federation).
    @Test(arguments: [(LiveServer.prosody, LiveServer.prosody), (LiveServer.ejabberd, LiveServer.ejabberd),
                      (LiveServer.prosody, LiveServer.ejabberd)])
    func dailyDrivable(_ servers: (LiveServer, LiveServer)) async throws {
        let (julietServer, romeoServer) = servers
        let juliet = try await Device("juliet", on: julietServer)
        let romeo = try await Device("romeo", on: romeoServer)
        try await closing([juliet, romeo]) {
            try await exercise(juliet: juliet, romeo: romeo)
        }
    }

    private func exercise(juliet: Device, romeo: Device) async throws {
        let julietJID = juliet.account.jid
        let romeoJID = romeo.account.jid

        // Start from strangers.
        try? await juliet.session.removeContact(romeoJID)
        try? await romeo.session.removeContact(julietJID)
        try await eventually("roster cleared") { try juliet.contact(romeoJID)?.inRoster != true }

        // Juliet adds Romeo; Romeo sees the request and approves; both end up
        // mutually subscribed.
        try await juliet.session.addContact(romeoJID, name: "Romeo")
        try await eventually("Romeo sees the request") { try romeo.contact(julietJID)?.pendingIn == true }
        try await romeo.session.answerSubscription(from: julietJID, approve: true)
        try await eventually("mutual subscription") {
            try juliet.contact(romeoJID)?.subscription == .both && romeo.contact(julietJID)?.subscription == .both
        }
        #expect(try juliet.contact(romeoJID)?.name == "Romeo")
        try await eventually("presence") { juliet.status.availability(of: romeoJID) == .online }

        // A message, a receipt, then a displayed marker once Romeo looks.
        let sent = try await juliet.session.send("hello \(UUID())", to: romeoJID)
        #expect(sent.state == .sent)
        try await eventually("delivery") { try romeo.messages(with: julietJID).contains { $0.originID == sent.originID } }
        try await eventually("receipt") { try juliet.messages(with: romeoJID).last?.state == .delivered }
        #expect(try romeo.unread(julietJID) == 1)
        await romeo.session.setVisibleConversation(julietJID)
        try await eventually("displayed") { try juliet.messages(with: romeoJID).last?.state == .displayed }
        #expect(try romeo.unread(julietJID) == 0)
        await romeo.session.setVisibleConversation(nil)

        // Typing reaches the other side once both have spoken chat states.
        _ = try await romeo.session.send("hi", to: julietJID)
        try await eventually("reply") { try juliet.messages(with: romeoJID).last?.body == "hi" }
        await juliet.session.sendChatState(.composing, to: romeoJID)
        try await eventually("typing") { romeo.status.typing[julietJID] == .composing }

        // Correction and retraction.
        try await juliet.session.correct(messageID: sent.id!, with: "hello, corrected")
        try await eventually("correction") {
            try romeo.messages(with: julietJID).first { $0.originID == sent.originID }?.body == "hello, corrected"
        }
        try await juliet.session.retract(messageID: sent.id!)
        try await eventually("retraction") {
            try romeo.messages(with: julietJID).first { $0.originID == sent.originID }?.isRetracted == true
        }

        // Juliet goes offline; Romeo writes; Juliet comes back and catches up
        // from the archive, exactly once each.
        await juliet.manager.setEnabled(juliet.account.id, false)
        let offline = (1...3).map { "while you were out \($0) \(UUID())" }
        for text in offline { _ = try await romeo.session.send(text, to: julietJID) }
        try await Task.sleep(for: .milliseconds(500))
        await juliet.manager.setEnabled(juliet.account.id, true)
        try await juliet.waitOnline()
        try await eventually("catch-up") {
            let bodies = try juliet.messages(with: romeoJID).map(\.body)
            return offline.allSatisfy { text in bodies.filter { $0 == text }.count == 1 }
        }
        // The Romeo messages and the markers came once each, even though they
        // may have arrived both from offline storage and the archive.
        let julietRows = try juliet.messages(with: romeoJID)
        #expect(Set(julietRows.compactMap(\.originID)).count == julietRows.count)

        // Tidy up for the next run.
        try? await juliet.session.removeContact(romeoJID)
        try? await romeo.session.removeContact(julietJID)
    }

    /// XEP-0484 through the manager: the first login gets a token, kept with
    /// the password; the next logs in with it, bound to the TLS channel.
    @Test(arguments: [LiveServer.prosody, LiveServer.ejabberd])
    func fastLoginAfterTheFirst(_ server: LiveServer) async throws {
        let credentials = InMemoryCredentialStore()
        let manager = AccountManager(database: try HrafnDatabase(), credentials: credentials)
        let template = try server.account("juliet")
        let account = try await manager.addAccount(jid: template.jid, password: devPassword, host: template.host,
                                                   port: template.port, directTLS: true,
                                                   trustedFingerprint: template.trustedFingerprint)
        let status = manager.status(for: account.id)
        try await eventually("online") { status.connection == .online }
        #expect(credentials.fastToken(for: account.id)?.mechanism == "HT-SHA-256-EXPR")

        await manager.restart(account.id)
        try await eventually("online again") { status.connection == .online && status.boundJID != nil }
        let session = try #require(manager.session(for: account.id))
        #expect(await session.client.sessionMechanism == "HT-SHA-256-EXPR")
        await manager.stopAll()
    }

    /// A message written with no connection waits in the outbox and goes out
    /// with the next session.
    @Test func outboxSurvivesBeingOffline() async throws {
        let database = try HrafnDatabase()
        let juliet = try await Device("juliet", on: .prosody, database: database)
        let romeo = try await Device("romeo", on: .prosody)
        try await closing([juliet, romeo]) {
            try await exerciseOutbox(juliet: juliet, romeo: romeo, database: database)
        }
    }

    private func exerciseOutbox(juliet: Device, romeo: Device, database: HrafnDatabase) async throws {
        // Stop the session but keep the object, so `send` has no connection.
        let session = juliet.session
        await session.stop()
        let text = "queued \(UUID())"
        let row = try await session.send(text, to: romeo.account.jid)
        #expect(row.state == .pending)
        #expect(try database.outbox(accountID: juliet.account.id).map(\.id) == [row.id])

        await juliet.manager.restart(juliet.account.id)
        try await juliet.waitOnline()
        try await eventually("outbox flushed") { try database.outbox(accountID: juliet.account.id).isEmpty }
        try await eventually("delivered") { try romeo.messages(with: juliet.account.jid).contains { $0.body == text } }
    }
}
