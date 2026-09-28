import Testing
import Foundation
@testable import HrafnServices
import HrafnStore
import XMPPCore
import XMPPIM
import XMPPXML

private let account = try! JID("juliet@example.com")
private let verona = try! JID("verona@conference.example.com")

private func parse(_ xml: String) throws -> Message {
    let parser = StreamParser()
    _ = try parser.parse(Array("<stream:stream xmlns='jabber:client' xmlns:stream='http://etherx.jabber.org/streams'>".utf8))
    guard case .stanza(let element) = try parser.parse(Array(xml.utf8)).first,
          let message = Message(element) else { throw AccountError.notFound }
    return message
}

private func inbound(_ xml: String) throws -> InboundMessage {
    try #require(InboundMessage(live: try parse(xml), account: account))
}

private func roomMessage(_ xml: String) throws -> RoomMessage {
    let info = RoomInfo(features: [Namespaces.stableIDs, Namespaces.occupantID, Namespaces.muc])
    return try #require(RoomMessage(live: try parse(xml), info: info))
}

@Suite struct ModernUXMappingTests {

    @Test func reactionsInAChat() throws {
        let events = try inbound("""
        <message from='romeo@example.net/a' type='chat' id='r1'>\
        <reactions xmlns='urn:xmpp:reactions:0' id='m1'><reaction>👍</reaction></reactions>\
        <stanza-id xmlns='urn:xmpp:sid:0' by='juliet@example.com' id='A9'/></message>
        """).events(accountID: "a")
        #expect(events.map(\.content) == [.reactions(to: "m1", ["👍"])])
        #expect(!events[0].isOutgoing)
    }

    /// The quote goes; what it quoted is kept apart, for when the original
    /// is not stored here.
    @Test func repliesLoseTheirFallback() throws {
        let events = try inbound("""
        <message from='romeo@example.net/a' type='chat' id='m2'><body>&gt; hello\nhi yourself</body>\
        <reply xmlns='urn:xmpp:reply:0' to='juliet@example.com' id='m1'/>\
        <fallback xmlns='urn:xmpp:fallback:0' for='urn:xmpp:reply:0'><body start='0' end='8'/></fallback></message>
        """).events(accountID: "a")
        #expect(events.map(\.content) == [.body("hi yourself", markable: false)])
        #expect(events[0].reply == ReplyReference(id: "m1", to: "juliet@example.com", quote: "hello"))
    }

    @Test func correctionsOfRepliesLoseTheirFallbackToo() throws {
        let events = try inbound("""
        <message from='romeo@example.net/a' type='chat' id='c1'><body>&gt; hello\nhi!</body>\
        <replace xmlns='urn:xmpp:message-correct:0' id='m2'/><reply xmlns='urn:xmpp:reply:0' id='m1'/>\
        <fallback xmlns='urn:xmpp:fallback:0' for='urn:xmpp:reply:0'><body start='0' end='8'/></fallback></message>
        """).events(accountID: "a")
        #expect(events.map(\.content) == [.correction(of: "m2", body: "hi!")])
    }

    @Test func unstyledIsKept() throws {
        let events = try inbound("""
        <message from='romeo@example.net/a' type='chat' id='m'><body>*a*</body><unstyled xmlns='urn:xmpp:styling:0'/></message>
        """).events(accountID: "a")
        #expect(events.first?.unstyled == true)
    }

    @Test func reactionsInARoom() throws {
        let events = try roomMessage("""
        <message type='groupchat' from='verona@conference.example.com/Romeo' id='r1'>\
        <reactions xmlns='urn:xmpp:reactions:0' id='S1'><reaction>❤️</reaction></reactions>\
        <occupant-id xmlns='urn:xmpp:occupant-id:0' id='oR'/></message>
        """).events(accountID: "a", me: RoomSelf(account: account, nick: "Juliet"))
        #expect(events.map(\.content) == [.reactions(to: "S1", ["❤️"])])
        #expect(events[0].sender == .init(nick: "Romeo", occupantID: "oR"))
    }

    /// A reply to one of our messages in a room is as good as a mention.
    @Test func aReplyToUsInARoomMentionsUs() throws {
        let me = RoomSelf(account: account, nick: "Juliet")
        let toUs = try roomMessage("""
        <message type='groupchat' from='verona@conference.example.com/Romeo' id='m2'><body>yes</body>\
        <reply xmlns='urn:xmpp:reply:0' to='verona@conference.example.com/Juliet' id='S1'/></message>
        """).events(accountID: "a", me: me)
        #expect(toUs.first?.mentionsMe == true)
        #expect(toUs.first?.reply?.id == "S1")
        let toOthers = try roomMessage("""
        <message type='groupchat' from='verona@conference.example.com/Romeo' id='m3'><body>yes</body>\
        <reply xmlns='urn:xmpp:reply:0' to='verona@conference.example.com/Tybalt' id='S2'/></message>
        """).events(accountID: "a", me: me)
        #expect(toOthers.first?.mentionsMe == false)
    }

    @Test func outgoingRepliesQuoteTheOriginal() throws {
        let reply = ReplyReference(id: "m1", to: "romeo@example.net", quote: "line one\nline two")
        let message = Message.chat(to: try JID("romeo@example.net"), body: "ok", id: "m2").replying(to: reply)
        #expect(message.body == "> line one\n> line two\nok")
        #expect(message.displayBody == "ok")
        #expect(message.replyReference == reply)
        #expect(Message.chat(to: account, body: "x").replying(to: nil).reply == nil)
    }
}
