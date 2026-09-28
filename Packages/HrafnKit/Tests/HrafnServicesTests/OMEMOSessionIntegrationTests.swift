import Foundation
import GRDB
import OMEMOCrypto
import OMEMOProtocol
import Testing
@testable import HrafnServices
import HrafnStore
import XMPPClient
import XMPPCore
import XMPPIM
import XMPPStream
import XMPPTestSupport
import XMPPXML


/// OMEMO through the whole stack, on the Docker servers: two apps talk,
/// encrypted by default, and the notification service extension decrypts
/// what came while the app was away.
@MainActor
@Suite(.enabled(if: integrationEnabled), .serialized, .timeLimit(.minutes(2)))
struct OMEMOSessionIntegrationTests {

    nonisolated static let pairs: [(LiveServer, LiveServer)] = [(.prosody, .prosody), (.prosody, .ejabberd)]

    @MainActor
    final class App {
        let database = try! HrafnDatabase()
        let omemo = try! OMEMODatabase()
        let credentials = InMemoryCredentialStore()
        let locks = FileManager.default.temporaryDirectory.appending(path: "hrafn-locks-\(UUID().uuidString)")
        let manager: AccountManager
        var account: Account!

        init() {
            manager = AccountManager(database: database, credentials: credentials, omemo: omemo,
                                     console: ProcessInfo.processInfo.environment["HRAFN_XML"] == "1"
                                        ? RedactingXMLConsole(PrintXMLConsole()) : nil,
                                     lockDirectory: locks, loopbackHTTP: true)
        }

        func add(_ user: String, on server: LiveServer) async throws {
            // Start from empty device lists: every run's devices would stay
            // in them otherwise, and each first message fetches a bundle
            // for every one.
            let client = try bareClient(try JID("\(user)@\(server.domain)"), on: server)
            try await client.connect()
            for version in OMEMOVersion.allCases { try await PEPDirectory(client: client).publishDeviceList([], version: version) }
            await client.disconnect()

            let template = try server.account(user)
            account = try await manager.addAccount(jid: template.jid, password: devPassword, host: template.host,
                                                   port: template.port, trustedFingerprint: template.trustedFingerprint)
            try await eventually("\(account.jid) online") { manager.status(for: account.id).connection == .online }
            // Post-login OMEMO set-up: this device is in the published list.
            try await eventually("\(account.jid) device published") { await session.publishedOwnDevice() != nil }
        }

        var session: AccountSession { manager.session(for: account.id)! }

        func messages(with peer: String) throws -> [StoredMessage] {
            try database.writer.read { db in
                try StoredMessage.filter(Column("accountID") == account.id && Column("peer") == peer)
                    .order(Column("timestamp"), Column("id")).fetchAll(db)
            }
        }
    }

    @Test(arguments: 0..<pairs.count)
    func encryptedConversation(_ index: Int) async throws {
        let (julietServer, romeoServer) = Self.pairs[index]
        let juliet = App(), romeo = App()
        try await juliet.add("montague", on: julietServer)
        try await romeo.add("capulet", on: romeoServer)
        defer {
            try? FileManager.default.removeItem(at: juliet.locks)
            try? FileManager.default.removeItem(at: romeo.locks)
        }
        let token = UUID().uuidString.prefix(6)
        let julietJID = juliet.account.jid, romeoJID = romeo.account.jid

        // Undecided, and Romeo has a device: encrypted.
        let sent = try await juliet.session.send("secret \(token)", to: romeoJID)
        let stored = try #require(try juliet.database.message(id: sent.id!))
        #expect(stored.encryption == .omemo)
        #expect(stored.state == .sent, "\(stored.errorText ?? "")")
        #expect(try juliet.database.conversationEncryption(accountID: juliet.account.id, peer: romeoJID) == .omemo)

        try await eventually("romeo decrypts") {
            try romeo.messages(with: julietJID).contains { $0.body == "secret \(token)" && $0.encryption == .omemo }
        }
        #expect(try romeo.database.conversationEncryption(accountID: romeo.account.id, peer: julietJID) == .omemo)

        // The reply, and a correction, both ways encrypted.
        try await romeo.session.send("reply \(token)", to: julietJID)
        try await eventually("juliet decrypts") {
            try juliet.messages(with: romeoJID).contains { $0.body == "reply \(token)" && $0.encryption == .omemo }
        }
        try await juliet.session.correct(messageID: sent.id!, with: "corrected \(token)")
        try await eventually("romeo sees the correction") {
            try romeo.messages(with: julietJID).contains { $0.body == "corrected \(token)" }
        }

        // Romeo's app goes away; the extension decrypts from the archive.
        await romeo.manager.suspend()
        try await juliet.session.send("while away \(token)", to: romeoJID)
        try await Task.sleep(for: .seconds(1))
        let fetch = BackgroundFetch(database: romeo.database, credentials: romeo.credentials,
                                    lockDirectory: romeo.locks, omemo: romeo.omemo)
        let outcome = await fetch.run()
        #expect(outcome.failures.isEmpty)
        #expect(outcome.notifications.map(\.message.body).contains("while away \(token)"))
        #expect(try romeo.messages(with: julietJID).contains { $0.body == "while away \(token)" && $0.encryption == .omemo })

        // Back in the app, the conversation carries on.
        await romeo.manager.resume()
        try await eventually("romeo online again") {
            romeo.manager.status(for: romeo.account.id).connection == .online
        }
        try await Task.sleep(for: .seconds(1))
        try await romeo.session.send("back \(token)", to: julietJID)
        try await eventually("juliet decrypts after the extension") {
            try juliet.messages(with: romeoJID).contains { $0.body == "back \(token)" && $0.encryption == .omemo }
        }

        // Turned off: plain text again.
        try juliet.manager.setEncryption(accountID: juliet.account.id, peer: romeoJID, .off)
        let plain = try await juliet.session.send("plain \(token)", to: romeoJID)
        #expect(try juliet.database.message(id: plain.id!)?.encryption == nil)
        try await eventually("romeo receives plain") {
            try romeo.messages(with: julietJID).contains { $0.body == "plain \(token)" && $0.encryption == nil }
        }

        await juliet.manager.stopAll()
        await romeo.manager.stopAll()
    }

    /// A private group, encrypted: automatic once every member has devices,
    /// both ways, a correction, and history read back from the room's
    /// archive after the app was away.
    @Test(arguments: [LiveServer.prosody, LiveServer.ejabberd])
    func encryptedGroup(_ server: LiveServer) async throws {
        let juliet = App(), romeo = App()
        try await juliet.add("montague", on: server)
        try await romeo.add("capulet", on: server)
        defer {
            try? FileManager.default.removeItem(at: juliet.locks)
            try? FileManager.default.removeItem(at: romeo.locks)
        }
        let token = UUID().uuidString.prefix(6)

        let key = try await juliet.session.createRoom(name: "Vault \(token)", kind: .privateGroup)
        do {
            try await juliet.session.invite(romeo.account.jid, to: key)
            try await eventually("invitation") {
                try romeo.database.invitation(accountID: romeo.account.id, room: key) != nil
            }
            try await romeo.session.acceptInvitation(key)
            try await eventually("romeo joined") { romeo.manager.status(for: romeo.account.id).room(key).isJoined }
            try await eventually("juliet knows romeo is a member") {
                await juliet.session.roomMembers(key).map(\.description).contains(romeo.account.jid)
            }

            let sent = try await juliet.session.send("group secret \(token)", to: key)
            try await eventually("reflected") {
                try juliet.database.message(id: sent.id!)?.state == .delivered
            }
            let own = try #require(try juliet.database.message(id: sent.id!))
            #expect(own.encryption == .omemo)
            #expect(own.body == "group secret \(token)")
            #expect(try juliet.database.conversationEncryption(accountID: juliet.account.id, peer: key) == .omemo)
            try await eventually("romeo decrypts") {
                try romeo.messages(with: key).contains { $0.body == "group secret \(token)" && $0.encryption == .omemo }
            }

            try await romeo.session.send("group reply \(token)", to: key)
            try await eventually("juliet decrypts") {
                try juliet.messages(with: key).contains { $0.body == "group reply \(token)" && $0.encryption == .omemo
                    && !$0.isOutgoing }
            }
            try await juliet.session.correct(messageID: sent.id!, with: "group corrected \(token)")
            try await eventually("romeo sees the correction") {
                try romeo.messages(with: key).contains { $0.body == "group corrected \(token)" }
            }

            // Romeo is away; the room's archive holds what he missed.
            await romeo.manager.suspend()
            try await juliet.session.send("group while away \(token)", to: key)
            try await Task.sleep(for: .seconds(1))
            await romeo.manager.resume()
            try await eventually("romeo reads the archive") {
                try romeo.messages(with: key).contains { $0.body == "group while away \(token)" && $0.encryption == .omemo }
            }
            #expect(try romeo.messages(with: key).filter { $0.encryption == .undecryptable }.isEmpty)

        } catch {
            try? await juliet.session.destroyRoom(key)
            throw error
        }
        try await juliet.session.destroyRoom(key)
        await juliet.manager.stopAll()
        await romeo.manager.stopAll()
    }

    /// XEP-0454: a file in an encrypted chat is uploaded as ciphertext and
    /// its `aesgcm://` link sent encrypted; the other side downloads and
    /// decrypts it. In a private group the same.
    @Test(arguments: [LiveServer.prosody, LiveServer.ejabberd])
    func encryptedFiles(_ server: LiveServer) async throws {
        let juliet = App(), romeo = App()
        try await juliet.add("montague", on: server)
        try await romeo.add("capulet", on: server)
        defer {
            try? FileManager.default.removeItem(at: juliet.locks)
            try? FileManager.default.removeItem(at: romeo.locks)
        }
        let julietJID = juliet.account.jid, romeoJID = romeo.account.jid
        let contents = Data("a letter for Romeo \(UUID().uuidString)".utf8)
        func file(_ app: App, _ name: String) throws -> OutgoingFile {
            let source = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            try contents.write(to: source)
            let path = try app.manager.media.importFile(source, named: name)
            return OutgoingFile(localPath: path, fileName: name, mimeType: "text/plain")
        }

        try juliet.manager.setEncryption(accountID: juliet.account.id, peer: romeoJID, .omemo)
        let sent = try await juliet.session.sendFile(try file(juliet, "letter.txt"), to: romeoJID)
        try await eventually("sent") { try juliet.database.message(id: sent.id!)?.state == .sent }
        let own = try #require(try juliet.database.message(id: sent.id!))
        #expect(own.encryption == .omemo)
        let uploaded = try #require(own.attachment?.url)
        #expect(own.attachment?.encryptionKey != nil)
        #expect(own.body.hasPrefix("aesgcm://"))
        #expect(!uploaded.lastPathComponent.contains("letter"))
        // The server holds ciphertext.
        let raw = try await HTTPTransfer(pinnedFingerprint: nil, loopback: true).download(uploaded)
        #expect(try Data(contentsOf: raw) != contents)

        try await eventually("romeo has the file") {
            try romeo.messages(with: julietJID).contains { $0.attachment?.encryptionKey != nil }
        }
        let received = try #require(try romeo.messages(with: julietJID).first { $0.attachment?.encryptionKey != nil })
        #expect(received.encryption == .omemo)
        #expect(received.attachment?.url == uploaded)
        // Downloaded now, unless the automatic download already has it.
        try await romeo.session.download(messageID: received.id!)
        try await eventually("downloaded") { try romeo.database.message(id: received.id!)?.attachment?.localPath != nil }
        let path = try #require(try romeo.database.message(id: received.id!)?.attachment?.localPath)
        #expect(try Data(contentsOf: romeo.manager.media.url(for: path)) == contents)

        // A private group.
        let key = try await juliet.session.createRoom(name: "Files \(UUID().uuidString.prefix(4))", kind: .privateGroup)
        do {
            try await juliet.session.invite(romeoJID, to: key)
            try await eventually("invitation") {
                try romeo.database.invitation(accountID: romeo.account.id, room: key) != nil
            }
            try await romeo.session.acceptInvitation(key)
            try await eventually("member") { await juliet.session.roomMembers(key).map(\.description).contains(romeoJID) }
            let inRoom = try await juliet.session.sendFile(try file(juliet, "notice.txt"), to: key)
            try await eventually("reflected") { try juliet.database.message(id: inRoom.id!)?.state == .delivered }
            #expect(try juliet.database.message(id: inRoom.id!)?.encryption == .omemo)
            try await eventually("romeo has the room file") {
                try romeo.messages(with: key).contains { $0.attachment?.encryptionKey != nil && $0.encryption == .omemo }
            }
            let roomFile = try #require(try romeo.messages(with: key).first { $0.attachment?.encryptionKey != nil })
            try await romeo.session.download(messageID: roomFile.id!)
            try await eventually("downloaded") { try romeo.database.message(id: roomFile.id!)?.attachment?.localPath != nil }
            let roomPath = try #require(try romeo.database.message(id: roomFile.id!)?.attachment?.localPath)
            #expect(try Data(contentsOf: romeo.manager.media.url(for: roomPath)) == contents)

        } catch {
            try? await juliet.session.destroyRoom(key)
            throw error
        }
        try await juliet.session.destroyRoom(key)
        await juliet.manager.stopAll()
        await romeo.manager.stopAll()
    }

    /// A contact on a client with OMEMO 2 only: the app writes
    /// to it and reads its replies in OMEMO 2. The contact is a bare client
    /// whose engine cannot see OMEMO 0.3's nodes.
    @Test(arguments: [LiveServer.prosody, LiveServer.ejabberd])
    func omemo2OnlyContact(_ server: LiveServer) async throws {
        let juliet = App()
        try await juliet.add("montague", on: server)
        defer { try? FileManager.default.removeItem(at: juliet.locks) }
        let token = UUID().uuidString.prefix(6)
        let julietJID = try JID(juliet.account.jid)
        let contactJID = try JID("capulet@\(server.domain)")

        let client = try bareClient(contactJID, on: server)
        await client.addFeature(OMEMO2Nodes.devicesNotify)
        try await client.connect()
        try await client.send(Presence.available(caps: await client.capsElement))
        let pep = PEPDirectory(client: client)
        // Only OMEMO 2 devices, as such a client publishes.
        for version in OMEMOVersion.allCases { try await pep.publishDeviceList([], version: version) }
        let contact = OMEMOEngine(account: contactJID, store: InMemoryOMEMOStore(), directory: OMEMO2Only(base: pep))
        try await contact.setUp()

        let arrival = Task { () -> EncryptedMessage? in
            try await withThrowingTaskGroup(of: EncryptedMessage?.self) { group in
                group.addTask {
                    for await event in client.events {
                        if case .message(let m) = event, m.from?.bare == julietJID, let e = m.omemoEncrypted { return e }
                    }
                    return nil
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(15))
                    return nil
                }
                defer { group.cancelAll() }
                return try await group.next() ?? nil
            }
        }
        let sent = try await juliet.session.send("to contact \(token)", to: contactJID.description)
        #expect(try juliet.database.message(id: sent.id!)?.encryption == .omemo)
        let encrypted = try #require(try await arrival.value)
        // The contact's device in OMEMO 2; earlier runs' devices of Juliet's own
        // account may add an OMEMO 0.3 element beside it.
        let contactID = await contact.deviceID!
        #expect(encrypted.element(.v2)?.keys.contains { $0.deviceID == contactID && $0.jid == contactJID } == true)
        #expect(encrypted.element(.legacy)?.keys.contains { $0.deviceID == contactID } != true)
        let read = try await contact.decrypt(encrypted, from: julietJID, conversations: [contactJID])
        #expect(read.body == "to contact \(token)")
        try await client.send(Message(type: .chat, to: julietJID)
            .encrypted(with: try await contact.keyTransport(to: read.session)))

        let reply = try await contact.encrypt("from contact \(token)", to: [julietJID])
        #expect(reply.message.elements.map(\.version) == [.v2])
        try await client.send(Message.omemo(reply.message, to: julietJID))
        try await eventually("juliet reads OMEMO 2") {
            try juliet.messages(with: contactJID.description)
                .contains { $0.body == "from contact \(token)" && $0.encryption == .omemo }
        }

        await client.disconnect()
        await juliet.manager.stopAll()
    }
}

/// A directory with OMEMO 0.3's nodes hidden, for a client that has only
/// OMEMO 2.
struct OMEMO2Only: OMEMODirectory {
    struct Unsupported: Error {}
    let base: PEPDirectory

    func deviceList(of jid: JID, version: OMEMOVersion) async throws -> [UInt32] {
        version == .v2 ? try await base.deviceList(of: jid, version: version) : []
    }

    func publishDeviceList(_ deviceIDs: [UInt32], version: OMEMOVersion) async throws {
        if version == .v2 { try await base.publishDeviceList(deviceIDs, version: version) }
    }

    func bundle(of jid: JID, deviceID: UInt32, version: OMEMOVersion) async throws -> PreKeyBundle {
        guard version == .v2 else { throw Unsupported() }
        return try await base.bundle(of: jid, deviceID: deviceID, version: version)
    }

    func publishBundle(_ bundle: PreKeyBundle) async throws {
        if bundle.version == .v2 { try await base.publishBundle(bundle) }
    }
}

/// A client of our own for `jid`, without the app around it.
func bareClient(_ jid: JID, on server: LiveServer) throws -> XMPPClient {
    let testServer = server.domain == TestServer.prosody.domain ? TestServer.prosody : TestServer.ejabberd
    return XMPPClient(configuration: SessionConfiguration(
                          credentials: try Credentials(jid: jid, password: devPassword),
                          tlsPolicy: try testServer.trustPolicy(), endpoints: [testServer.endpoint(.directTLS)],
                          allowPlain: false),
                      identity: ClientIdentity(name: "Hrafn tests", node: "https://example.org/hrafn-tests"),
                      resilience: .oneShot)
}
