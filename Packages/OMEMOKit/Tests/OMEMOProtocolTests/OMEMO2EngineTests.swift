import Foundation
import Testing
import OMEMOCrypto
@testable import OMEMOProtocol
import XMPPCore
import XMPPIM
import XMPPXML

/// Both versions in one engine: OMEMO 0.3 for devices that list themselves
/// there, OMEMO 2 for devices that speak only that.
@Suite struct OMEMO2EngineTests {
    let alice = try! JID("alice@example.org")
    let bob = try! JID("bob@example.net")
    let pep = FakePEP()

    func engine(_ jid: JID, store: OMEMOStore = InMemoryOMEMOStore()) async throws -> OMEMOEngine {
        let engine = OMEMOEngine(account: jid, store: store, directory: pep.directory(for: jid))
        try await engine.setUp()
        return engine
    }

    /// An engine whose device is in OMEMO 2's list only, as those of OMEMO 2-only clients are.
    func v2Only(_ jid: JID, store: OMEMOStore = InMemoryOMEMOStore()) async throws -> OMEMOEngine {
        let engine = try await engine(jid, store: store)
        pep.withdraw(await engine.deviceID!, of: jid, from: .legacy)
        return engine
    }

    @Test func setUpPublishesBothVersions() async throws {
        let phone = try await engine(alice)
        let id = await phone.deviceID!
        for version in OMEMOVersion.allCases {
            #expect(pep.list(of: alice, version: version) == [id])
            let bundle = try await pep.directory(for: bob).bundle(of: alice, deviceID: id, version: version)
            #expect(bundle.version == version)
            #expect(bundle.isSignatureValid)
            #expect(bundle.identityKey == (await phone.identityKey))
        }
    }

    /// Two OMEMO 2-only devices: pre-key messages, the empty acknowledgement,
    /// ordinary messages, replies.
    @Test func conversation() async throws {
        let alicePhone = try await v2Only(alice)
        let bobPhone = try await v2Only(bob)

        let first = try await alicePhone.encrypt("hello bob", to: [bob])
        #expect(first.skipped.isEmpty)
        let wire = try overTheWire(first.message)
        #expect(wire.elements.map(\.version) == [.v2])
        #expect(wire.keys.allSatisfy { $0.isPreKey && $0.jid == bob })

        let atBob = try await bobPhone.decrypt(wire, from: alice, conversations: [bob, alice])
        #expect(atBob.body == "hello bob")
        #expect(atBob.version == .v2)
        #expect(atBob.shouldAcknowledge)
        #expect(atBob.senderIdentity == (await alicePhone.identityKey))

        // Bob's used pre-key is gone from both of his bundles.
        let bobID = await bobPhone.deviceID!
        for version in OMEMOVersion.allCases {
            let bundle = try await pep.directory(for: alice).bundle(of: bob, deviceID: bobID, version: .v2)
            #expect(bundle.preKeys.count == LocalDevice.preKeyTarget, "\(version)")
        }

        let ack = try overTheWire(try await bobPhone.keyTransport(to: atBob.session))
        #expect(ack.elements.map(\.version) == [.v2])
        #expect(!ack.hasPayload)
        #expect(try await alicePhone.decrypt(ack, from: bob).body == nil)

        let second = try await alicePhone.encrypt("no more pre-keys", to: [bob])
        #expect(second.message.keys.first { $0.deviceID == bobID }?.isPreKey == false)
        #expect(try await bobPhone.decrypt(try overTheWire(second.message), from: alice).body == "no more pre-keys")

        for n in 0..<3 {
            let reply = try await bobPhone.encrypt("reply \(n)", to: [alice])
            #expect(try await alicePhone.decrypt(try overTheWire(reply.message), from: bob).body == "reply \(n)")
        }
    }

    /// Bob has a phone with an OMEMO 2-only client and a laptop with both: one
    /// message carries an element of each version, and each device reads
    /// its own. Alice's other device, which has both, gets OMEMO 0.3.
    @Test func mixedDevices() async throws {
        let alicePhone = try await engine(alice)
        let aliceLaptop = try await engine(alice)
        let bobPhone = try await v2Only(bob)
        let bobLaptop = try await engine(bob)
        try await alicePhone.refreshDeviceIDs(of: alice)

        let sent = try await alicePhone.encrypt("to everyone", to: [bob])
        let wire = try overTheWire(sent.message)
        #expect(wire.elements.map(\.version) == [.legacy, .v2])
        #expect(Set(wire.element(.legacy)!.keys.map(\.deviceID)) == [await aliceLaptop.deviceID!, await bobLaptop.deviceID!])
        #expect(wire.element(.v2)!.keys.map(\.deviceID) == [await bobPhone.deviceID!])

        #expect(try await bobPhone.decrypt(wire, from: alice).version == .v2)
        #expect(try await bobLaptop.decrypt(wire, from: alice).version == .legacy)
        #expect(try await aliceLaptop.decrypt(wire, from: alice).body == "to everyone")
        // A replay is refused, as in OMEMO 0.3.
        await #expect(throws: (any Error).self) { try await bobPhone.decrypt(wire, from: alice) }

        // Bob's phone answers (it is Hrafn with its 0.3 list entry removed):
        // Alice's phone in the OMEMO 2 session it already has, her laptop
        // and Bob's laptop in OMEMO 0.3, which they list.
        let reply = try overTheWire(try await bobPhone.encrypt("answer", to: [alice]).message)
        #expect(reply.element(.v2)!.keys.map(\.deviceID) == [await alicePhone.deviceID!])
        #expect(Set(reply.element(.legacy)!.keys.map(\.deviceID)) == [await aliceLaptop.deviceID!, await bobLaptop.deviceID!])
        #expect(try await alicePhone.decrypt(reply, from: bob).body == "answer")
        #expect(try await aliceLaptop.decrypt(reply, from: bob).body == "answer")
    }

    /// A device already reached in OMEMO 2 stays there, though it lists
    /// OMEMO 0.3 too: switching would start a needless new session.
    @Test func keepsAnExistingSession() async throws {
        let alicePhone = try await engine(alice)
        let bobPhone = try await v2Only(bob)
        _ = try await bobPhone.decrypt(try await alicePhone.encrypt("hi", to: [bob]).message, from: alice)
        // Bob's client learns OMEMO 0.3 later.
        pep.setList(DeviceList(deviceIDs: [await bobPhone.deviceID!], version: .legacy).element, of: bob)
        try await alicePhone.refreshDeviceIDs(of: bob)
        let next = try await alicePhone.encrypt("still 2", to: [bob])
        #expect(next.message.elements.map(\.version) == [.v2])
    }

    /// The envelope names who wrote the message and where it went: a
    /// message replayed from another sender, or into another chat, is
    /// refused.
    @Test func envelopeIsChecked() async throws {
        let carol = try JID("carol@example.com")
        let alicePhone = try await v2Only(alice)
        let bobPhone = try await v2Only(bob)
        let sent = try await alicePhone.encrypt("for bob", to: [bob])
        await #expect(throws: OMEMOProtocolError.envelopeMismatch) {
            try await bobPhone.decrypt(sent.message, from: alice, conversations: [carol])
        }
        await #expect(throws: OMEMOProtocolError.envelopeMismatch) {
            try await bobPhone.decrypt(sent.message, from: carol)
        }
        // Nothing was committed by the refusals.
        #expect(try await bobPhone.decrypt(sent.message, from: alice, conversations: [bob]).body == "for bob")
    }

    /// A room message names the room.
    @Test func groupEnvelopeNamesTheRoom() async throws {
        let room = try JID("group@muc.example.org")
        let alicePhone = try await v2Only(alice)
        let bobPhone = try await v2Only(bob)
        let carolPhone = try await v2Only(try JID("carol@example.com"))
        let sent = try await alicePhone.encrypt("to the group", to: [bob, try JID("carol@example.com")], conversation: room)
        #expect(try await bobPhone.decrypt(sent.message, from: alice, conversations: [room]).body == "to the group")
        #expect(try await carolPhone.decrypt(sent.message, from: alice, conversations: [room]).body == "to the group")
    }

    /// A server that refuses OMEMO 2's nodes: OMEMO 0.3 still works.
    @Test func withoutOMEMO2() async throws {
        pep.refused = [.v2]
        let alicePhone = OMEMOEngine(account: alice, store: InMemoryOMEMOStore(), directory: pep.directory(for: alice))
        await #expect(throws: FakePEP.Directory.Refused.self) { try await alicePhone.setUp() }
        let bobPhone = OMEMOEngine(account: bob, store: InMemoryOMEMOStore(), directory: pep.directory(for: bob))
        _ = try? await bobPhone.setUp()
        #expect(pep.list(of: alice, version: .legacy) == [await alicePhone.deviceID!])
        let sent = try await alicePhone.encrypt("still works", to: [bob])
        #expect(sent.message.elements.map(\.version) == [.legacy])
        #expect(try await bobPhone.decrypt(sent.message, from: alice).body == "still works")
    }

    @Test func deviceListNotification() throws {
        let xml = """
        <message from='bob@example.net' to='alice@example.org/phone' type='headline'>\
        <event xmlns='http://jabber.org/protocol/pubsub#event'>\
        <items node='urn:xmpp:omemo:2:devices'>\
        <item id='current'><devices xmlns='urn:xmpp:omemo:2'>\
        <device id='12345' label='Phone'/><device id='4223'/><device id='0'/>\
        </devices></item></items></event></message>
        """
        let message = try #require(Message(try Element(xmlFragment: xml)))
        let change = try #require(PEPDirectory.deviceListChange(in: message, account: alice))
        #expect(change == DeviceListChange(jid: bob, deviceIDs: [12345, 4223], version: .v2))
    }

    /// XEP-0384 0.8 §6's example layout, parsed and written back.
    @Test func encryptedElement() throws {
        let xml = """
        <encrypted xmlns='urn:xmpp:omemo:2'><header sid='27183'>\
        <keys jid='juliet@capulet.lit'><key rid='31415'>AQID</key></keys>\
        <keys jid='romeo@montague.lit'><key kex='true' rid='1066'>BA==</key><key rid='4223'>BQ==</key></keys>\
        </header><payload>CQk=</payload></encrypted>
        """
        let element = try #require(EncryptedElement(element: try Element(xmlFragment: xml)))
        #expect(element.version == .v2)
        #expect(element.senderDeviceID == 27183)
        #expect(element.keys.map(\.deviceID) == [31415, 1066, 4223])
        #expect(element.keys.map(\.isPreKey) == [false, true, false])
        #expect(element.keys.map { $0.jid?.description } == ["juliet@capulet.lit", "romeo@montague.lit", "romeo@montague.lit"])
        #expect(element.payload == Data([9, 9]))
        #expect(EncryptedElement(element: try Element(xmlFragment: element.element.xmlString)) == element)
    }

    @Test func bundleElement() throws {
        let bundle = try LocalDevice.generate(deviceID: 7).bundle(for: .v2)
        let parsed = try PreKeyBundle(element: try Element(xmlFragment: bundle.element.xmlString), deviceID: 7)
        #expect(parsed == bundle)
        #expect(parsed.isSignatureValid)
        #expect(bundle.element.firstChild(name: "ik", namespaceURI: Namespaces.omemo2) != nil)
    }

    /// Everything in the envelope's content is put back into the message.
    @Test func envelopeContentReplaces() throws {
        let sent = Message.chat(to: bob, body: "secret", id: "m1")
            .encrypted(with: EncryptedElement(version: .v2, senderDeviceID: 1,
                                              keys: [.init(deviceID: 2, data: Data([1]), isPreKey: false, jid: bob)],
                                              payload: Data([1])))
        #expect(sent.body == Message.omemoFallbackBody)
        let reply = Element(name: "reply", namespaceURI: "urn:xmpp:reply:0", attributes: ["id": "x"])
        let received = sent.decrypted(content: [Element(name: "body", namespaceURI: Namespaces.client, text: "secret"),
                                                reply])
        #expect(received.body == "secret")
        #expect(received.omemoEncrypted == nil)
        #expect(received.element.firstChild(name: "reply", namespaceURI: "urn:xmpp:reply:0") == reply)
        #expect(received.requestsReceipt)
    }

    @Test func envelopeRoundTrips() throws {
        let envelope = SCEEnvelope(content: [Element(name: "body", namespaceURI: Namespaces.client, text: "hi")],
                                   from: try JID("alice@example.org/phone"), to: bob)
        let parsed = try #require(SCEEnvelope(element: try Element(xmlFragment: envelope.element.xmlString)))
        #expect(parsed == envelope)
        #expect(parsed.from == alice)
        #expect(parsed.body == "hi")
    }
}

/// A contact seen without devices early in a session sets OMEMO up later:
/// the empty answer is fetched again rather than failing the message.
@Suite struct DeviceListFreshnessTests {
    @Test func emptyListIsFetchedAgain() async throws {
        let alice = try JID("alice@example.org"), bob = try JID("bob@example.net")
        let pep = FakePEP()
        let alicePhone = OMEMOEngine(account: alice, store: InMemoryOMEMOStore(), directory: pep.directory(for: alice))
        try await alicePhone.setUp()
        #expect(try await alicePhone.refreshDeviceIDs(of: bob).isEmpty)

        let bobPhone = OMEMOEngine(account: bob, store: InMemoryOMEMOStore(), directory: pep.directory(for: bob))
        try await bobPhone.setUp()
        #expect(try await alicePhone.deviceIDs(of: bob) == [await bobPhone.deviceID!])
        let sent = try await alicePhone.encrypt("found you", to: [bob])
        #expect(try await bobPhone.decrypt(sent.message, from: alice).body == "found you")
    }
}
