import Foundation
import Testing
import OMEMOCrypto
@testable import OMEMOProtocol
import XMPPCore
import XMPPIM
import XMPPXML

@Suite struct EngineTests {
    let alice = try! JID("alice@example.org")
    let bob = try! JID("bob@example.net")
    let pep = FakePEP()

    func engine(_ jid: JID, store: OMEMOStore = InMemoryOMEMOStore()) async throws -> OMEMOEngine {
        let engine = OMEMOEngine(account: jid, store: store, directory: pep.directory(for: jid))
        try await engine.setUp()
        return engine
    }

    @Test func setUpPublishesTheDevice() async throws {
        let phone = try await engine(alice)
        let laptop = try await engine(alice)
        let ids = try await pep.directory(for: alice).deviceList(of: alice, version: .legacy)
        #expect(ids == [await phone.deviceID!, await laptop.deviceID!])
        let bundle = try await pep.directory(for: bob).bundle(of: alice, deviceID: await phone.deviceID!, version: .legacy)
        #expect(bundle.isSignatureValid)
        #expect(bundle.preKeys.count == LocalDevice.preKeyTarget)
    }

    /// Alice (two devices) writes to Bob; Bob and Alice's other device read
    /// it; Bob acknowledges; the rest are ordinary ratchet messages.
    @Test func conversation() async throws {
        let alicePhone = try await engine(alice)
        let aliceLaptop = try await engine(alice)
        let bobPhone = try await engine(bob)
        // The laptop joined after the phone cached the list: PEP notifies.
        try await alicePhone.deviceListChanged(try await pep.directory(for: alice).deviceList(of: alice, version: .legacy), of: alice, version: .legacy)

        let first = try await alicePhone.encrypt("hello bob", to: [bob])
        #expect(first.skipped.isEmpty)
        let wire = try overTheWire(first.message)
        #expect(wire.keys.count == 2)
        #expect(wire.keys.allSatisfy { $0.isPreKey })

        let atBob = try await bobPhone.decrypt(wire, from: alice)
        #expect(atBob.body == "hello bob")
        #expect(atBob.shouldAcknowledge)
        let aliceIdentity = await alicePhone.identityKey
        #expect(atBob.senderIdentity == aliceIdentity)
        let atLaptop = try await aliceLaptop.decrypt(wire, from: alice)
        #expect(atLaptop.body == "hello bob")

        // Bob's used pre-key is gone from his published bundle.
        let republished = try await pep.directory(for: alice).bundle(of: bob, deviceID: await bobPhone.deviceID!, version: .legacy)
        #expect(republished.preKeys.count == LocalDevice.preKeyTarget)

        let ack = try await bobPhone.keyTransport(to: atBob.session)
        #expect(!ack.hasPayload)
        #expect(try await alicePhone.decrypt(try overTheWire(ack), from: bob).body == nil)

        let second = try await alicePhone.encrypt("no more pre-keys", to: [bob])
        let bobID = await bobPhone.deviceID!
        #expect(second.message.keys.first { $0.deviceID == bobID }?.isPreKey == false)
        #expect(try await bobPhone.decrypt(try overTheWire(second.message), from: alice).body == "no more pre-keys")

        // Bob's reply reaches both of Alice's devices; the laptop never had
        // a session with Bob, so it gets a pre-key message.
        let reply = try await bobPhone.encrypt("hi alice", to: [alice])
        #expect(reply.message.keys.count == 2)
        #expect(try await alicePhone.decrypt(try overTheWire(reply.message), from: bob).body == "hi alice")
        #expect(try await aliceLaptop.decrypt(try overTheWire(reply.message), from: bob).body == "hi alice")
    }

    @Test func notForThisDevice() async throws {
        let alicePhone = try await engine(alice)
        let bobPhone = try await engine(bob)
        let message = try await alicePhone.encrypt("x", to: [bob])
        let late = try await engine(bob)
        _ = bobPhone
        await #expect(throws: OMEMOProtocolError.notEncryptedForThisDevice) {
            try await late.decrypt(message.message, from: alice)
        }
    }

    @Test func recipientWithoutDevices() async throws {
        let alicePhone = try await engine(alice)
        await #expect(throws: OMEMOProtocolError.noDevices(bob)) { try await alicePhone.encrypt("x", to: [bob]) }
    }

    /// A device whose identity key changes: its messages are read but
    /// marked, and nothing is encrypted for it until the user decides.
    @Test func changedIdentityWaitsForTheUser() async throws {
        let aliceStore = InMemoryOMEMOStore()
        let alicePhone = try await engine(alice, store: aliceStore)
        let bobPhone = try await engine(bob)
        let bobID = await bobPhone.deviceID!
        let address = DeviceAddress(jid: bob, deviceID: bobID)
        _ = try await alicePhone.encrypt("first", to: [bob])
        #expect(try aliceStore.identity(of: address)?.trust == .blind)

        // Someone takes over Bob's device id with other keys.
        let impostor = OMEMOEngine(account: bob, store: storeWith(try LocalDevice.generate(deviceID: bobID)),
                                   directory: pep.directory(for: bob))
        try await impostor.setUp()
        let forged = try await impostor.encrypt("trust me", to: [alice])
        let read = try await alicePhone.decrypt(forged.message, from: bob)
        #expect(read.body == "trust me")
        #expect(read.senderTrust == .undecided)
        #expect(try aliceStore.identity(of: address)?.key == read.senderIdentity)

        await #expect(throws: OMEMOProtocolError.noTrustedDevices(bob)) { try await alicePhone.encrypt("x", to: [bob]) }
        aliceStore.setTrust(.blind, of: address)
        let after = try await alicePhone.encrypt("accepted", to: [bob])
        #expect(after.message.keys.contains { $0.deviceID == bobID })
    }

    /// Blind Trust Before Verification: once one of Bob's devices is
    /// verified, his new devices wait.
    @Test func blindTrustUntilVerification() async throws {
        let aliceStore = InMemoryOMEMOStore()
        let alicePhone = try await engine(alice, store: aliceStore)
        let bobPhone = try await engine(bob)
        let phoneAddress = DeviceAddress(jid: bob, deviceID: await bobPhone.deviceID!)
        _ = try await alicePhone.encrypt("hi", to: [bob])
        #expect(try aliceStore.identity(of: phoneAddress)?.trust == .blind)

        aliceStore.setTrust(.verified, of: phoneAddress)
        let bobLaptop = try await engine(bob)
        let laptopAddress = DeviceAddress(jid: bob, deviceID: await bobLaptop.deviceID!)
        try await alicePhone.deviceListChanged(try await pep.directory(for: alice).deviceList(of: bob, version: .legacy), of: bob, version: .legacy)

        let next = try await alicePhone.encrypt("to the verified phone only", to: [bob])
        #expect(next.message.keys.map(\.deviceID) == [phoneAddress.deviceID])
        #expect(next.skipped.contains { $0.address == laptopAddress })
        #expect(try aliceStore.identity(of: laptopAddress)?.trust == .undecided)

        // The laptop's messages are read, marked.
        let fromLaptop = try await bobLaptop.encrypt("new laptop", to: [alice])
        #expect(try await alicePhone.decrypt(fromLaptop.message, from: bob).senderTrust == .undecided)

        // Distrusted: never encrypted for, even with blind trust elsewhere.
        aliceStore.setTrust(.untrusted, of: phoneAddress)
        aliceStore.setTrust(.untrusted, of: laptopAddress)
        await #expect(throws: OMEMOProtocolError.noTrustedDevices(bob)) { try await alicePhone.encrypt("x", to: [bob]) }
    }

    private func storeWith(_ device: LocalDevice) -> InMemoryOMEMOStore {
        InMemoryOMEMOStore(localDevice: device)
    }

    /// `persist` failing commits nothing: the same message decrypts again,
    /// and the pre-key it used is still there.
    @Test func persistFailureCommitsNothing() async throws {
        let alicePhone = try await engine(alice)
        let bobStore = InMemoryOMEMOStore()
        let bobPhone = try await engine(bob, store: bobStore)
        let first = try await alicePhone.encrypt("keep me", to: [bob])
        let preKeys = try bobStore.localDevice()!.preKeys.count

        struct DiskFull: Error {}
        await #expect(throws: DiskFull.self) {
            try await bobPhone.decrypt(first.message, from: alice) { _ in throw DiskFull() }
        }
        #expect(try bobStore.session(with: SessionAddress(DeviceAddress(jid: alice, deviceID: first.message.senderDeviceID), .legacy)) == nil)
        #expect(try bobStore.localDevice()!.preKeys.count == preKeys)

        let persisted = Box()
        let again = try await bobPhone.decrypt(first.message, from: alice) { persisted.set($0.body) }
        #expect(again.body == "keep me")
        #expect(persisted.value == "keep me")
    }

    /// The process dies after the message is stored but before the session
    /// is: the redelivered message decrypts again (and the app deduplicates).
    @Test func crashAfterPersistIsRecoverable() async throws {
        let alicePhone = try await engine(alice)
        let bobStore = FailingCommitStore()
        let bobPhone = try await engine(bob, store: bobStore)
        _ = try await bobPhone.decrypt(try await alicePhone.encrypt("one", to: [bob]).message, from: alice)
        let second = try await alicePhone.encrypt("two", to: [bob])

        bobStore.failNextCommit = true
        let stored = Box()
        await #expect(throws: FailingCommitStore.Crash.self) {
            try await bobPhone.decrypt(second.message, from: alice) { stored.set($0.body) }
        }
        #expect(stored.value == "two")
        #expect(try await bobPhone.decrypt(second.message, from: alice).body == "two")
    }

    @Test func deviceListNotification() throws {
        let xml = """
        <message from='bob@example.net' to='alice@example.org/phone' type='headline'>\
        <event xmlns='http://jabber.org/protocol/pubsub#event'>\
        <items node='eu.siacs.conversations.axolotl.devicelist'>\
        <item id='current'><list xmlns='eu.siacs.conversations.axolotl'>\
        <device id='12345'/><device id='4223'/><device id='0'/><device id='12345'/><device id='x'/>\
        </list></item></items></event></message>
        """
        let parser = StreamParser()
        _ = try parser.parse(Array("<stream:stream xmlns='jabber:client' xmlns:stream='http://etherx.jabber.org/streams'>".utf8))
        guard case .stanza(let element) = try parser.parse(Array(xml.utf8)).first else { Issue.record(); return }
        let message = try #require(Message(element))
        let change = try #require(PEPDirectory.deviceListChange(in: message, account: alice))
        #expect(change.jid == bob)
        #expect(change.deviceIDs == [12345, 4223])
    }

    @Test func messageElement() throws {
        let encrypted = EncryptedElement(senderDeviceID: 27183,
                                         keys: [.init(deviceID: 31415, data: Data([1, 2, 3]), isPreKey: true),
                                                .init(deviceID: 12321, data: Data([4]), isPreKey: false)],
                                         iv: Data(repeating: 7, count: 12), payload: Data([9, 9]))
        let message = Message.omemo(encrypted, to: bob, id: "m1")
        #expect(message.omemoEncrypted == EncryptedMessage(encrypted))
        #expect(message.body == Message.omemoFallbackBody)
        #expect(message.element.firstChild(name: "store", namespaceURI: Namespaces.hints) != nil)
        let xml = encrypted.element.xmlString
        #expect(xml.contains("<key rid=\"31415\" prekey=\"true\">AQID</key>") || xml.contains("<key prekey=\"true\" rid=\"31415\">AQID</key>")
                || xml.contains("rid='31415'"))
        // A key transport message has no payload and no body.
        var transport = encrypted
        transport.payload = nil
        #expect(Message.omemo(transport, to: bob).body == nil)
    }

    /// Only the body is encrypted; the rest of the message stays, and
    /// decrypting puts the body back.
    @Test func encryptsTheBodyOnly() throws {
        let plain = Message.chat(to: bob, body: "secret", id: "m1")
        let encrypted = EncryptedElement(senderDeviceID: 1, keys: [.init(deviceID: 2, data: Data([1]), isPreKey: false)],
                                         iv: Data(count: 12), payload: Data([1]))
        let sent = plain.encrypted(with: encrypted)
        #expect(sent.body == Message.omemoFallbackBody)
        #expect(sent.omemoEncrypted == EncryptedMessage(encrypted))
        #expect(sent.originID == "m1")
        #expect(sent.requestsReceipt)
        #expect(!sent.element.xmlString.contains("secret"))

        let received = sent.decrypted(body: "secret")
        #expect(received.body == "secret")
        #expect(received.omemoEncrypted == nil)
        #expect(received.element.firstChild(name: "encryption", namespaceURI: Namespaces.explicitEncryption) == nil)
        #expect(received.requestsReceipt)
        #expect(sent.decrypted(body: nil).body == nil)
    }
}
