import Foundation
import GRDB
import Testing
import OMEMOCrypto
import OMEMOProtocol
@testable import HrafnServices
import HrafnStore
import XMPPCore
import XMPPIM

/// Inbound OMEMO as the session, catch-up and the extension store it.
@Suite struct OMEMOInboundTests {
    let juliet = try! JID("juliet@example.com")
    let romeo = try! JID("romeo@example.net")
    let pep = MemoryDirectory()
    let database = try! HrafnDatabase()
    let account = Account(jid: "juliet@example.com")

    init() throws { try database.save(account) }

    func engine(_ jid: JID) async throws -> OMEMOEngine {
        let engine = OMEMOEngine(account: jid, store: InMemoryOMEMOStore(), directory: pep.directory(for: jid))
        try await engine.setUp()
        return engine
    }

    /// `text` from `sender`'s device to `to`, as it arrives.
    func encrypted(_ text: String, from sender: OMEMOEngine, resource: String = "phone", to: JID, id: String,
                   source: InboundMessage.Source = .live, archiveID: String? = nil) async throws -> InboundMessage {
        let encrypted = try await sender.encrypt(text, to: [to])
        var message = Message.chat(to: to, body: text, id: id).encrypted(with: encrypted.message)
        message.element["from"] = "\(sender.account)/\(resource)"
        let outgoing = sender.account == juliet
        return InboundMessage(message: message, source: outgoing ? .carbon : source, isOutgoing: outgoing,
                              peer: outgoing ? to : sender.account, timestamp: nil, archiveID: archiveID)
    }

    func rows() throws -> [StoredMessage] {
        try database.writer.read { db in try StoredMessage.order(Column("id")).fetchAll(db) }
    }

    @Test func decryptsStoresAndAcknowledges() async throws {
        let romeoPhone = try await engine(romeo)
        let julietPhone = try await engine(juliet)
        let store = InboundStore(database: database, accountID: account.id, omemo: julietPhone)

        let first = try await store.store(try await encrypted("hello", from: romeoPhone, to: juliet, id: "m1"))
        #expect(first.inbound.message.body == "hello")
        #expect(first.acknowledge?.device.jid == romeo)
        let second = try await store.store(try await encrypted("again", from: romeoPhone, to: juliet, id: "m2"))
        #expect(second.acknowledge != nil)  // Still pre-key: no reply yet.

        let ack = try await julietPhone.keyTransport(to: first.acknowledge!)
        _ = try await romeoPhone.decrypt(ack, from: juliet)
        let third = try await store.store(try await encrypted("plain now", from: romeoPhone, to: juliet, id: "m3"))
        #expect(third.acknowledge == nil)

        #expect(try rows().map(\.body) == ["hello", "again", "plain now"])
        #expect(try rows().allSatisfy { $0.encryption == .omemo && !$0.isOutgoing })
        #expect(try database.conversationEncryption(accountID: account.id, peer: romeo.description) == .omemo)
    }

    /// The archive's copy of a message already read live: its keys are gone,
    /// but no placeholder appears either.
    @Test func archiveCopyOfAReadMessage() async throws {
        let romeoPhone = try await engine(romeo)
        let store = InboundStore(database: database, accountID: account.id, omemo: try await engine(juliet))
        let live = try await encrypted("once", from: romeoPhone, to: juliet, id: "m1", archiveID: "a1")
        _ = try await store.store(live)
        let copy = live.replacing(live.message)
        _ = try await store.store(InboundMessage(message: copy.message, source: .archive, isOutgoing: false,
                                                 peer: romeo, timestamp: nil, archiveID: "a1"))
        #expect(try rows().map(\.body) == ["once"])
    }

    @Test func notForThisDeviceLeavesAPlaceholder() async throws {
        let romeoPhone = try await engine(romeo)
        _ = try await engine(juliet)
        let message = try await encrypted("elsewhere", from: romeoPhone, to: juliet, id: "m1")
        // A device that joined after the message was sent.
        let late = try await engine(juliet)
        let stored = try await InboundStore(database: database, accountID: account.id, omemo: late).store(message)
        #expect(stored.events.count == 1)
        #expect(try rows().map(\.body) == [InboundStore.undecryptableBody])
        #expect(try rows().first?.encryption == .undecryptable)
    }

    /// Without OMEMO (no storage for it): a placeholder, not the fallback.
    @Test func withoutAnEngine() async throws {
        _ = try await engine(juliet)
        let message = try await encrypted("x", from: try await engine(romeo), to: juliet, id: "m1")
        _ = try await InboundStore(database: database, accountID: account.id, omemo: nil).store(message)
        #expect(try rows().map(\.body) == [InboundStore.undecryptableBody])
    }

    /// A contact whose device speaks only OMEMO 2: its message
    /// is read, and answered in OMEMO 2.
    @Test func omemo2Contact() async throws {
        // Romeo's engine stands in for an OMEMO 2-only client: with Juliet's device out of
        // her OMEMO 0.3 list, OMEMO 2 is all it can use.
        let romeoPhone = try await engine(romeo)
        try await pep.directory(for: romeo).publishDeviceList([], version: .legacy)
        let julietPhone = try await engine(juliet)
        try await pep.directory(for: juliet).publishDeviceList([], version: .legacy)
        let store = InboundStore(database: database, accountID: account.id, omemo: julietPhone)

        let arrived = try await encrypted("hello in OMEMO 2", from: romeoPhone, to: juliet, id: "m1")
        #expect(arrived.message.omemoEncrypted?.elements.map(\.version) == [.v2])
        let stored = try await store.store(arrived)
        #expect(stored.inbound.message.body == "hello in OMEMO 2")
        #expect(stored.acknowledge?.version == .v2)
        #expect(try rows().map(\.encryption) == [.omemo])

        let reply = try await julietPhone.encrypt("hi", to: [romeo])
        #expect(reply.message.elements.map(\.version) == [.v2])
        #expect(try await romeoPhone.decrypt(reply.message, from: juliet).body == "hi")
    }

    /// An OMEMO 2 message whose envelope names another chat is not shown as
    /// if it were for this one.
    @Test func omemo2ReplayIntoAnotherChat() async throws {
        // Romeo's engine stands in for an OMEMO 2-only client: with Juliet's device out of
        // her OMEMO 0.3 list, OMEMO 2 is all it can use.
        let romeoPhone = try await engine(romeo)
        try await pep.directory(for: romeo).publishDeviceList([], version: .legacy)
        let julietPhone = try await engine(juliet)
        try await pep.directory(for: juliet).publishDeviceList([], version: .legacy)
        let store = InboundStore(database: database, accountID: account.id, omemo: julietPhone)

        let meant = try await romeoPhone.encrypt("for the group", to: [juliet], conversation: try JID("group@muc.example.org"))
        var message = Message.chat(to: juliet, body: "x", id: "m1").encrypted(with: meant.message)
        message.element["from"] = "romeo@example.net/phone"
        let stored = try await store.store(InboundMessage(message: message, source: .live, isOutgoing: false, peer: romeo,
                                                          timestamp: nil, archiveID: nil))
        #expect(stored.inbound.message.body == InboundStore.undecryptableBody)
        #expect(try rows().map(\.encryption) == [.undecryptable])
    }

    @Test func keyTransportForAnotherDeviceIsIgnored() async throws {
        let romeoPhone = try await engine(romeo)
        let julietPhone = try await engine(juliet)
        let julietLaptop = try await engine(juliet)
        let element = try await romeoPhone.keyTransport(to: SessionAddress(DeviceAddress(jid: juliet, deviceID: await julietPhone.deviceID!), .legacy))
        var message = Message(type: .chat, to: juliet).encrypted(with: element)
        message.element["from"] = "romeo@example.net/phone"
        let inbound = InboundMessage(message: message, source: .live, isOutgoing: false, peer: romeo, timestamp: nil,
                                     archiveID: nil)
        let stored = try await InboundStore(database: database, accountID: account.id, omemo: julietLaptop).store(inbound)
        #expect(stored.events.isEmpty)
        #expect(try rows().isEmpty)
    }

    /// Our other device's message, as a carbon: stored as ours, decrypted.
    @Test func ownCarbon() async throws {
        _ = try await engine(romeo)
        let julietPhone = try await engine(juliet)
        let julietLaptop = try await engine(juliet)
        try await julietPhone.deviceListChanged(try await pep.directory(for: juliet).deviceList(of: juliet, version: .legacy), of: juliet, version: .legacy)
        let carbon = try await encrypted("from my phone", from: julietPhone, to: romeo, id: "m1")
        let stored = try await InboundStore(database: database, accountID: account.id, omemo: julietLaptop).store(carbon)
        #expect(stored.inbound.isOutgoing)
        #expect(try rows().map(\.body) == ["from my phone"])
        #expect(try rows().first?.isOutgoing == true)
        #expect(try rows().first?.encryption == .omemo)
    }

    /// An archive page keeps its order across plain and encrypted messages.
    @Test func pageOrder() async throws {
        let romeoPhone = try await engine(romeo)
        let store = InboundStore(database: database, accountID: account.id, omemo: try await engine(juliet))
        func plain(_ text: String, _ id: String) -> InboundMessage {
            var message = Message.chat(to: juliet, body: text, id: id)
            message.element["from"] = "romeo@example.net/phone"
            return InboundMessage(message: message, source: .archive, isOutgoing: false, peer: romeo,
                                  timestamp: nil, archiveID: "a-\(id)")
        }
        let page = [plain("one", "1"),
                    try await encrypted("two", from: romeoPhone, to: juliet, id: "2", source: .archive, archiveID: "a-2"),
                    plain("three", "3")]
        let acknowledge = try await store.store(page: page, alreadyRead: false)
        #expect(acknowledge.count == 1)
        #expect(try rows().map(\.body) == ["one", "two", "three"])
    }
}
