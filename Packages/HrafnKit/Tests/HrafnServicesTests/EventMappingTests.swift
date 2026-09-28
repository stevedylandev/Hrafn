import Testing
import Foundation
@testable import HrafnServices
import HrafnStore
import XMPPCore
import XMPPIM
import XMPPXML

private let account = try! JID("juliet@example.com")

private func inbound(_ xml: String) throws -> InboundMessage {
    let parser = StreamParser()
    _ = try parser.parse(Array("<stream:stream xmlns='jabber:client' xmlns:stream='http://etherx.jabber.org/streams'>".utf8))
    guard case .stanza(let element) = try parser.parse(Array(xml.utf8)).first,
          let message = Message(element) else { throw AccountError.notFound }
    return try #require(InboundMessage(live: message, account: account))
}

@Suite struct EventMappingTests {

    @Test func bodyWithReceiptRequest() throws {
        let events = try inbound("""
        <message from='romeo@example.net/a' type='chat' id='m1'><body>hi</body><request xmlns='urn:xmpp:receipts'/>\
        <markable xmlns='urn:xmpp:chat-markers:0'/><stanza-id xmlns='urn:xmpp:sid:0' by='juliet@example.com' id='A1'/></message>
        """).events(accountID: "a")
        #expect(events.count == 1)
        #expect(events[0].content == .body("hi", markable: true))
        #expect(events[0].peer == "romeo@example.net")
        #expect(events[0].archiveID == "A1")
        #expect(events[0].senderID == "m1")
    }

    /// The fallback body of a retraction is not a message.
    @Test func retractionIgnoresItsFallbackBody() throws {
        let events = try inbound("""
        <message from='romeo@example.net/a' type='chat' id='r1'><body>fallback</body>\
        <retract xmlns='urn:xmpp:message-retract:1' id='m1'/><fallback xmlns='urn:xmpp:fallback:0' for='urn:xmpp:message-retract:1'/></message>
        """).events(accountID: "a")
        #expect(events.map(\.content) == [.retraction(of: "m1")])
    }

    @Test func correctionReceiptAndMarker() throws {
        let correction = try inbound("""
        <message from='romeo@example.net/a' type='chat' id='c1'><body>fixed</body><replace xmlns='urn:xmpp:message-correct:0' id='m1'/></message>
        """).events(accountID: "a")
        #expect(correction.map(\.content) == [.correction(of: "m1", body: "fixed")])

        let receipt = try inbound("""
        <message from='romeo@example.net/a' id='x'><received xmlns='urn:xmpp:receipts' id='o1'/>\
        <stanza-id xmlns='urn:xmpp:sid:0' by='juliet@example.com' id='A5'/></message>
        """).events(accountID: "a")
        #expect(receipt.map(\.content) == [.receipt(for: "o1")])
        // A receipt must not claim the archive id, or a body with it would be
        // taken for a duplicate.
        #expect(receipt[0].archiveID == nil)

        let marker = try inbound("""
        <message from='romeo@example.net/a' type='chat'><displayed xmlns='urn:xmpp:chat-markers:0' id='o1'/></message>
        """).events(accountID: "a")
        #expect(marker.map(\.content) == [.displayed(upTo: "o1")])
    }

    /// XEP-0447: metadata fills in the attachment before any download, and
    /// a share without a body still becomes a message.
    @Test func statelessFileSharing() throws {
        let events = try inbound("""
        <message type='chat' from='romeo@example.net/a' id='f1'>\
        <file-sharing xmlns='urn:xmpp:sfs:0'><file xmlns='urn:xmpp:file:metadata:0'>\
        <media-type>image/png</media-type><name>balcony.png</name><size>2048</size><width>30</width><height>20</height>\
        <hash xmlns='urn:xmpp:hashes:2' algo='sha-256'>abc=</hash>\
        <thumbnail xmlns='urn:xmpp:thumbs:1' uri='data:image/jpeg;base64,AQID' media-type='image/jpeg'/></file>\
        <sources><url-data xmlns='http://jabber.org/protocol/url-data' target='https://up.example/x/balcony.png'/></sources>\
        </file-sharing></message>
        """).events(accountID: "a")
        #expect(events.count == 1)
        let attachment = try #require(events.first?.attachment)
        #expect(attachment.url?.absoluteString == "https://up.example/x/balcony.png")
        #expect(attachment.fileName == "balcony.png" && attachment.mimeType == "image/png")
        #expect(attachment.size == 2048 && attachment.width == 30 && attachment.height == 20)
        #expect(attachment.sha256 == "abc=")
        #expect(attachment.thumbnail == Data([1, 2, 3]))
    }

    @Test func chatStatesAndGroupchatAreNotStored() throws {
        #expect(try inbound("""
        <message from='romeo@example.net/a' type='chat'><composing xmlns='http://jabber.org/protocol/chatstates'/></message>
        """).events(accountID: "a").isEmpty)
        #expect(try inbound("""
        <message from='room@conference.example.net/romeo' type='groupchat'><body>hi all</body></message>
        """).events(accountID: "a").isEmpty)
    }

    @Test func bouncesFailTheOriginal() throws {
        let events = try inbound("""
        <message from='romeo@example.net' type='error' id='o1'><error type='cancel'>\
        <service-unavailable xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/></error></message>
        """).events(accountID: "a")
        #expect(events.map(\.content) == [.error(stanzaID: "o1", text: "service-unavailable")])
    }
}

private func roomMessage(_ xml: String, info: RoomInfo? = RoomInfo(features: [Namespaces.muc, Namespaces.stableIDs,
                                                                               Namespaces.occupantID])) throws -> RoomMessage {
    let parser = StreamParser()
    _ = try parser.parse(Array("<stream:stream xmlns='jabber:client' xmlns:stream='http://etherx.jabber.org/streams'>".utf8))
    guard case .stanza(let element) = try parser.parse(Array(xml.utf8)).first,
          let message = Message(element) else { throw AccountError.notFound }
    return try #require(RoomMessage(live: message, info: info))
}

@Suite struct RoomEventMappingTests {

    @Test func ownMessagesByOccupantIDThenRealJIDThenNick() throws {
        let message = try roomMessage("""
        <message type='groupchat' from='verona@conference.example.com/Jules' id='m1'><body>hi</body>\
        <occupant-id xmlns='urn:xmpp:occupant-id:0' id='oJ'/>\
        <stanza-id xmlns='urn:xmpp:sid:0' by='verona@conference.example.com' id='S1'/></message>
        """)
        // Occupant ids decide when both sides have one, whatever the nick.
        #expect(message.isOwn(RoomSelf(account: account, nick: "Juliet", occupantID: "oJ")))
        #expect(!message.isOwn(RoomSelf(account: account, nick: "Jules", occupantID: "other")))
        // Without, the nick.
        let plain = try roomMessage("""
        <message type='groupchat' from='verona@conference.example.com/Jules' id='m1'><body>hi</body></message>
        """, info: nil)
        #expect(plain.isOwn(RoomSelf(account: account, nick: "Jules")))
        #expect(!plain.isOwn(RoomSelf(account: account, nick: "Juliet")))

        let events = message.events(accountID: "a", me: RoomSelf(account: account, nick: "Juliet", occupantID: "x"))
        #expect(events.count == 1)
        #expect(events[0].peer == "verona@conference.example.com")
        #expect(events[0].archiveID == "S1")
        #expect(events[0].sender == .init(nick: "Jules", occupantID: "oJ"))
        #expect(!events[0].isOutgoing)
    }

    /// XEP-0372: a reference to our occupant JID or account is a mention,
    /// even when the text does not use our nick.
    @Test func referencesMentionUs() throws {
        let byOccupant = try roomMessage("""
        <message type='groupchat' from='verona@conference.example.com/Romeo' id='m1'><body>hey, you</body>\
        <reference xmlns='urn:xmpp:reference:0' type='mention' uri='xmpp:verona@conference.example.com/Jules'/></message>
        """)
        #expect(byOccupant.events(accountID: "a", me: RoomSelf(account: account, nick: "Jules")).first?.mentionsMe == true)
        #expect(byOccupant.events(accountID: "a", me: RoomSelf(account: account, nick: "Juliet")).first?.mentionsMe == false)
        let byAccount = try roomMessage("""
        <message type='groupchat' from='verona@conference.example.com/Romeo' id='m2'><body>hey, you</body>\
        <reference xmlns='urn:xmpp:reference:0' type='mention' uri='xmpp:\(account)'/></message>
        """)
        #expect(byAccount.events(accountID: "a", me: RoomSelf(account: account, nick: "Juliet")).first?.mentionsMe == true)
    }

    @Test func mentions() {
        #expect(RoomMessage.mentions("juliet: hi", nick: "Juliet"))
        #expect(RoomMessage.mentions("hi @Juliet!", nick: "juliet"))
        #expect(RoomMessage.mentions("Julíet?", nick: "Juliet"))
        #expect(!RoomMessage.mentions("Juliets", nick: "Juliet"))
        #expect(!RoomMessage.mentions("myjuliet", nick: "Juliet"))
        #expect(RoomMessage.mentions("myjuliet and juliet", nick: "Juliet"))
    }

    @Test func subjectsAndNoticesAreNotMessages() throws {
        let me = RoomSelf(account: account, nick: "Juliet")
        #expect(try roomMessage("""
        <message type='groupchat' from='verona@conference.example.com/R'><subject>s</subject></message>
        """).events(accountID: "a", me: me).isEmpty)
        #expect(try roomMessage("""
        <message type='groupchat' from='verona@conference.example.com'><body>Room is now logged</body></message>
        """).events(accountID: "a", me: me).isEmpty)
        let mention = try roomMessage("""
        <message type='groupchat' from='verona@conference.example.com/R' id='m'><body>Juliet, come</body></message>
        """).events(accountID: "a", me: me)
        #expect(mention.first?.mentionsMe == true)
    }
}

@Suite struct FileMappingTests {

    @Test func fileSharesBecomeAttachments() throws {
        let events = try inbound("""
        <message type='chat' from='romeo@example.net/a' id='f1'><body>https://up.example.net/x/My%20Photo.JPG</body>\
        <x xmlns='jabber:x:oob'><url>https://up.example.net/x/My%20Photo.JPG</url></x></message>
        """).events(accountID: "a")
        let attachment = try #require(events.first?.attachment)
        #expect(attachment.fileName == "My Photo.JPG")
        #expect(attachment.mimeType == "image/jpeg")
        #expect(attachment.url?.absoluteString == "https://up.example.net/x/My%20Photo.JPG")

        let captioned = try inbound("""
        <message type='chat' from='romeo@example.net/a' id='f2'><body>see https://up.example.net/x/a.png</body>\
        <x xmlns='jabber:x:oob'><url>https://up.example.net/x/a.png</url></x></message>
        """).events(accountID: "a")
        #expect(captioned.first?.attachment == nil)
    }

    @Test func fileNamesFromURLsAreSafe() {
        #expect(MediaStore.safeFileName("..%2F..%2Fetc%2Fpasswd") == "_.._etc_passwd")
        #expect(MediaStore.safeFileName("...") == "file")
        #expect(MediaStore.safeFileName("a:b\\c.txt") == "a_b_c.txt")
    }
}

@Suite struct BannerWithdrawalTests {
    /// Only banners that announce a message no longer unread are stale.
    @Test func staleBannersAreThoseOfMessagesNoLongerUnread() {
        let delivered: [(id: String, userInfo: [AnyHashable: Any])] = [
            ("m1", [MessageNotification.messageKey: NSNumber(value: Int64(1))]),
            ("m2", [MessageNotification.messageKey: NSNumber(value: Int64(2))]),
            ("generic", [:]),
        ]
        #expect(MessageNotification.stale(delivered, keeping: [2]) == ["m1"])
        #expect(MessageNotification.stale(delivered, keeping: [1, 2]).isEmpty)
        #expect(MessageNotification.stale(delivered, keeping: []) == ["m1", "m2"])
    }
}
