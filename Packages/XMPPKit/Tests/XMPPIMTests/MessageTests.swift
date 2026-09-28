import Testing
import Foundation
import XMPPIM
import XMPPCore
import XMPPXML
import XMPPTestSupport

@Suite struct DateTimeTests {
    @Test func parsesTheXEP0082Forms() throws {
        let reference = try #require(XMPPDateTime.parse("2002-09-10T23:08:25Z"))
        #expect(reference.timeIntervalSince1970 == 1_031_699_305)
        #expect(abs(XMPPDateTime.parse("2002-09-10T23:08:25.123Z")!.timeIntervalSince(reference) - 0.123) < 0.0001)
        // ejabberd sends microseconds.
        #expect(abs(XMPPDateTime.parse("2002-09-10T23:08:25.123456Z")!.timeIntervalSince(reference) - 0.123) < 0.001)
        #expect(XMPPDateTime.parse("2002-09-10T18:08:25-05:00") == reference)
        #expect(XMPPDateTime.parse("2002-09-10") == nil)
        #expect(XMPPDateTime.parse("yesterday") == nil)
        #expect(XMPPDateTime.parse(XMPPDateTime.string(from: reference)) == reference)
    }
}

@Suite struct MessageExtensionTests {
    let romeo = try! JID("romeo@example.net")

    @Test func chatMessagesCarryEveryRequest() throws {
        let sent = Message.chat(to: romeo, body: "hi", id: "m1")
        let m = try message(sent.element.xmlString)
        #expect(m.body == "hi")
        #expect(m.id == "m1")
        #expect(m.originID == "m1")
        #expect(m.requestsReceipt)
        #expect(m.isMarkable)
        #expect(m.chatState == .active)
        #expect(m.type == .chat)
    }

    @Test func correctionsAndRetractionsReferenceTheOriginal() throws {
        let fix = try message(Message.correction(of: "m1", to: romeo, body: "hello").element.xmlString)
        #expect(fix.replacedID == "m1")
        #expect(fix.body == "hello")
        #expect(fix.id != "m1")

        let retract = try message(Message.retraction(of: "m1", to: romeo).element.xmlString)
        #expect(retract.retractedID == "m1")
        #expect(retract.isFallback(for: Namespaces.retraction))
        #expect(retract.body != nil)
    }

    @Test func receiptsMarkersAndStates() throws {
        #expect(try message(Message.receipt(for: "m1", to: romeo).element.xmlString).receiptID == "m1")
        #expect(try message(Message.displayed("m1", to: romeo).element.xmlString).displayedID == "m1")
        let typing = try message(Message.chatState(.composing, to: romeo).element.xmlString)
        #expect(typing.chatState == .composing)
        #expect(typing.isTransient)
        #expect(typing.body == nil)
    }

    @Test func stanzaIDsAreOnlyReadFromTheNamedAssigner() throws {
        let m = try message("""
        <message from='romeo@example.net/a' type='chat'>\
        <stanza-id xmlns='urn:xmpp:sid:0' id='forged' by='romeo@example.net'/>\
        <stanza-id xmlns='urn:xmpp:sid:0' id='real' by='juliet@example.com'/>\
        <body>x</body></message>
        """)
        #expect(m.stanzaID(by: juliet) == "real")
        #expect(m.stanzaID(by: romeo) == "forged")
    }
}

@Suite struct InboundMessageTests {

    @Test func liveMessagesUseTheOwnArchiveIDAndDelay() throws {
        let m = try message("""
        <message from='romeo@example.net/a' to='juliet@example.com/x' type='chat' id='r1'>\
        <body>hi</body><delay xmlns='urn:xmpp:delay' stamp='2002-09-10T23:08:25Z'/>\
        <stanza-id xmlns='urn:xmpp:sid:0' id='A1' by='juliet@example.com'/></message>
        """)
        let inbound = try #require(InboundMessage(live: m, account: try JID("juliet@example.com/x")))
        #expect(inbound.source == .live)
        #expect(!inbound.isOutgoing)
        #expect(inbound.peer == (try JID("romeo@example.net")))
        #expect(inbound.archiveID == "A1")
        #expect(inbound.senderID == "r1")
        #expect(inbound.timestamp == XMPPDateTime.parse("2002-09-10T23:08:25Z"))
    }

    @Test func unwrapsSentAndReceivedCarbons() throws {
        let sentCarbon = try message("""
        <message from='juliet@example.com' to='juliet@example.com/x' type='chat'>\
        <sent xmlns='urn:xmpp:carbons:2'><forwarded xmlns='urn:xmpp:forward:0'>\
        <message xmlns='jabber:client' from='juliet@example.com/phone' to='romeo@example.net' type='chat' id='o1'>\
        <body>from my phone</body></message></forwarded></sent></message>
        """)
        let sent = try #require(InboundMessage(live: sentCarbon, account: juliet))
        #expect(sent.source == .carbon)
        #expect(sent.isOutgoing)
        #expect(sent.peer == (try JID("romeo@example.net")))
        #expect(sent.message.body == "from my phone")

        let receivedCarbon = try message("""
        <message from='juliet@example.com' to='juliet@example.com/x' type='chat'>\
        <received xmlns='urn:xmpp:carbons:2'><forwarded xmlns='urn:xmpp:forward:0'>\
        <message xmlns='jabber:client' from='romeo@example.net/a' to='juliet@example.com/phone' type='chat' id='i1'>\
        <body>to my phone</body></message></forwarded></received></message>
        """)
        let received = try #require(InboundMessage(live: receivedCarbon, account: juliet))
        #expect(!received.isOutgoing)
        #expect(received.peer == (try JID("romeo@example.net")))
    }

    /// A note to self comes back from our own address: outgoing, so it
    /// shows once, on our side.
    @Test func notesToSelfAreOutgoing() throws {
        let echo = try message("""
        <message from='juliet@example.com/phone' to='juliet@example.com' type='chat' id='n1'>\
        <body>remember milk</body></message>
        """)
        let live = try #require(InboundMessage(live: echo, account: try JID("juliet@example.com/x")))
        #expect(live.isOutgoing)
        #expect(live.peer == juliet.bare)

        let receivedCarbon = try message("""
        <message from='juliet@example.com' to='juliet@example.com/x' type='chat'>\
        <received xmlns='urn:xmpp:carbons:2'><forwarded xmlns='urn:xmpp:forward:0'>\
        <message xmlns='jabber:client' from='juliet@example.com/phone' to='juliet@example.com/tablet' type='chat' id='n2'>\
        <body>and eggs</body></message></forwarded></received></message>
        """)
        let received = try #require(InboundMessage(live: receivedCarbon, account: juliet))
        #expect(received.isOutgoing)
        #expect(received.peer == juliet.bare)
    }

    /// XEP-0045 §7.5: a private message through a room, live and as a sent
    /// carbon; the marker, and invitations that use the same element.
    @Test func privateMessagesThroughARoom() throws {
        let juliet = try JID("juliet@example.com/x")
        let occupant = try JID("hall@chat.example.com/Romeo")
        let live = try message("""
        <message from='hall@chat.example.com/Romeo' to='juliet@example.com/x' type='chat' id='p1'>\
        <body>psst</body><x xmlns='http://jabber.org/protocol/muc#user'/></message>
        """)
        #expect(live.isMarkedRoomPrivate)
        let inbound = try #require(InboundMessage(live: live, account: juliet))
        #expect(inbound.peer == occupant.bare)
        #expect(inbound.counterpart == occupant)
        #expect(inbound.throughRoom()?.peer == occupant)

        let sentCarbon = try message("""
        <message from='juliet@example.com' to='juliet@example.com/x' type='chat'>\
        <sent xmlns='urn:xmpp:carbons:2'><forwarded xmlns='urn:xmpp:forward:0'>\
        <message xmlns='jabber:client' from='juliet@example.com/phone' to='hall@chat.example.com/Romeo' type='chat' id='p2'>\
        <body>hush</body><x xmlns='http://jabber.org/protocol/muc#user'/></message></forwarded></sent></message>
        """)
        let sent = try #require(InboundMessage(live: sentCarbon, account: juliet)?.throughRoom())
        #expect(sent.isOutgoing && sent.peer == occupant)

        // No nickname, no occupant; invitations and room messages are not private.
        #expect(try #require(InboundMessage(live: try message(
            "<message from='hall@chat.example.com' type='chat'><body>x</body></message>"), account: juliet))
            .throughRoom() == nil)
        #expect(!(try message("""
        <message from='hall@chat.example.com' to='juliet@example.com'><x xmlns='http://jabber.org/protocol/muc#user'>\
        <invite from='romeo@example.net'/></x></message>
        """)).isMarkedRoomPrivate)
        #expect(!(try message("""
        <message from='hall@chat.example.com/Romeo' type='groupchat'><body>all</body>\
        <x xmlns='http://jabber.org/protocol/muc#user'/></message>
        """)).isMarkedRoomPrivate)
        #expect(Message.chat(to: occupant, body: "hi").privateThroughRoom().isMarkedRoomPrivate)
    }

    /// XEP-0280 §11: a "carbon" from anyone else could plant words in our mouth.
    @Test func refusesForgedCarbons() throws {
        let forged = try message("""
        <message from='mallory@evil.example/x' to='juliet@example.com/x' type='chat'>\
        <sent xmlns='urn:xmpp:carbons:2'><forwarded xmlns='urn:xmpp:forward:0'>\
        <message xmlns='jabber:client' from='juliet@example.com/phone' to='romeo@example.net' type='chat'>\
        <body>I never said this</body></message></forwarded></sent></message>
        """)
        #expect(InboundMessage(live: forged, account: juliet) == nil)
    }

    @Test func classifiesArchivedMessagesByDirection() throws {
        let out = try message("<message from='juliet@example.com/x' to='romeo@example.net' type='chat'><body>a</body></message>")
        let outgoing = try #require(InboundMessage(archived: out, id: "A2", timestamp: nil, account: juliet))
        #expect(outgoing.isOutgoing)
        #expect(outgoing.peer == (try JID("romeo@example.net")))
        #expect(outgoing.archiveID == "A2")

        let into = try message("<message from='romeo@example.net/a' to='juliet@example.com' type='chat'><body>b</body></message>")
        #expect(InboundMessage(archived: into, id: "A3", timestamp: nil, account: juliet)?.isOutgoing == false)
    }
}

@Suite struct XMPPURITests {
    /// OMEMO fingerprints in verification QR codes, with or without an
    /// action, round-tripped.
    @Test func omemoFingerprints() throws {
        let hex = String(repeating: "ab", count: 32)
        let bare = try #require(XMPPURI("xmpp:romeo@example.net?omemo-sid-123=\(hex);omemo-sid-7=05\(hex.uppercased())"))
        #expect(bare.action == nil)
        #expect(bare.omemoFingerprints == [123: hex, 7: hex])
        #expect(bare.description == "xmpp:romeo@example.net?omemo-sid-7=\(hex);omemo-sid-123=\(hex)")
        #expect(XMPPURI(bare.description) == bare)

        let withAction = try #require(XMPPURI("xmpp:romeo@example.net?roster;name=Romeo;omemo-sid-5=\(hex)"))
        #expect(withAction.action == .roster(name: "Romeo"))
        #expect(withAction.omemoFingerprints == [5: hex])
        #expect(XMPPURI(withAction.description) == withAction)

        // Not a fingerprint: dropped.
        #expect(XMPPURI("xmpp:romeo@example.net?omemo-sid-5=xyz")?.omemoFingerprints == [:])
        #expect(XMPPURI("xmpp:romeo@example.net?omemo-sid-x=\(hex)")?.omemoFingerprints == [:])
    }

    /// Links arrive from anywhere (QR codes, other apps). Whatever parses
    /// must print as a URI that parses back to the same thing.
    @Test func arbitraryLinksNeverTrap() {
        var generator = Fuzz.generator()
        let pieces = ["xmpp:", "//", "@", "/", "?", ";", "=", "&", "#", "%", "%2", "%41", "%C3%A9", "%00", "%FF",
                      "a", "b.c", "é", "message", "roster", "subscribe", "join", "body", "name", "group", " "]
        for _ in 0..<Fuzz.iterations(3000) {
            var link = Bool.random(using: &generator) ? "xmpp:" : ""
            for _ in 0..<Int.random(in: 0..<10, using: &generator) { link += pieces.randomElement(using: &generator)! }
            guard let uri = XMPPURI(link) else { continue }
            #expect(XMPPURI(uri.description) == uri, "\(link.debugDescription) -> \(uri.description)")
        }
    }

    @Test func parsesTheCommonForms() throws {
        #expect(XMPPURI("xmpp:romeo@montague.net")?.jid == (try JID("romeo@montague.net")))
        #expect(XMPPURI("xmpp:romeo@montague.net")?.action == nil)
        #expect(XMPPURI("xmpp:romeo@montague.net?message;body=Here%27s%20a%20test")?.action
                == .message(body: "Here's a test"))
        #expect(XMPPURI("XMPP:romeo@montague.net?roster;name=Romeo%20Montague")?.action == .roster(name: "Romeo Montague"))
        #expect(XMPPURI("xmpp:romeo@montague.net?subscribe")?.action == .subscribe)
        #expect(XMPPURI("xmpp:room@conference.example?join")?.action == .join)
        #expect(XMPPURI("xmpp:romeo@montague.net?unknown;x=y")?.action == nil)
        // Percent-encoded internationalised localpart.
        #expect(XMPPURI("xmpp:%C3%A9lise@example.fr")?.jid.localpart == "élise")
    }

    @Test func refusesWhatIsNotAnAddress() {
        #expect(XMPPURI("https://example.com") == nil)
        #expect(XMPPURI("xmpp://guest@example.com/support@example.com") == nil)
        #expect(XMPPURI("xmpp:") == nil)
        #expect(XMPPURI("xmpp:@example.com") == nil)
    }

    @Test func roundTrips() throws {
        let uri = XMPPURI(jid: try JID("élise@example.fr"), action: .message(body: "a;b=c & d?"))
        #expect(XMPPURI(uri.description) == uri)
        #expect(!uri.description.contains(" "))
    }
}

@Suite struct PresenceBookTests {
    func presence(_ xml: String) throws -> Presence { try #require(Presence(try parse(xml))) }

    @Test func summarisesTheMostReachableResource() throws {
        var book = PresenceBook()
        let romeo = try JID("romeo@example.net")
        #expect(book.availability(of: romeo) == .offline)
        #expect(book.update(try presence("<presence from='romeo@example.net/a'><show>away</show></presence>")))
        #expect(book.availability(of: romeo) == .away)
        #expect(book.update(try presence("<presence from='romeo@example.net/b'><status>here</status></presence>")))
        #expect(book.summary(for: romeo)?.status == "here")
        #expect(book.onlineResources(of: romeo) == ["a", "b"])
        #expect(book.update(try presence("<presence from='romeo@example.net/b' type='unavailable'/>")))
        #expect(book.availability(of: romeo) == .away)
        // Subscription presences do not change who is online.
        #expect(!book.update(try presence("<presence from='romeo@example.net' type='subscribe'/>")))
        #expect(book.update(try presence("<presence from='romeo@example.net/a' type='unavailable'/>")))
        #expect(book.availability(of: romeo) == .offline)
    }

    @Test func buildsOwnPresenceWithCaps() throws {
        let p = Presence.available(.dnd, status: "busy", caps: Element(name: "c", namespaceURI: "http://jabber.org/protocol/caps"))
        let parsed = try presence(p.element.xmlString)
        #expect(parsed.availability == .dnd)
        #expect(parsed.status == "busy")
        #expect(parsed.element.firstChild(name: "c") != nil)
    }
}
