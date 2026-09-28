import Testing
import XMPPTestSupport
import Foundation
@testable import XMPPIM
import XMPPCore
import XMPPXML

@Suite struct ReactionTests {
    let romeo = try! JID("romeo@example.net")

    @Test func roundTripsAFullSet() throws {
        let sent = Message.reactions(["👋", "🐢"], to: "m1", peer: romeo, id: "r1")
        let m = try message(sent.element.xmlString)
        #expect(m.reactions == MessageReactions(id: "m1", emojis: ["👋", "🐢"]))
        #expect(m.body == nil)
        #expect(m.originID == "r1")
        #expect(m.type == .chat)
        // Stored, so our other devices and an offline peer see it.
        #expect(m.element.firstChild(name: "store", namespaceURI: Namespaces.hints) != nil)
    }

    @Test func anEmptySetRemovesEverything() throws {
        let m = try message(Message.reactions([], to: "m1", peer: romeo).element.xmlString)
        #expect(m.reactions == MessageReactions(id: "m1", emojis: []))
    }

    @Test func inRoomsTheyGoToTheRoom() throws {
        let occupant = try JID("verona@rooms.example.net/Romeo")
        let m = Message.reactions(["👍"], to: "room-id", peer: occupant, type: .groupchat)
        #expect(m.to == occupant.bare)
        #expect(m.type == .groupchat)
    }

    /// §3: one emoji per reaction; the rest is dropped, as are duplicates.
    @Test func keepsOnlySingleEmojis() throws {
        let m = try message("""
        <message from='romeo@example.net/a' type='chat'>\
        <reactions xmlns='urn:xmpp:reactions:0' id='m1'>\
        <reaction>👍</reaction><reaction>👍</reaction><reaction>lol</reaction><reaction>1</reaction>\
        <reaction>👍👍</reaction><reaction> ❤️ </reaction><reaction>👩‍👩‍👧</reaction><reaction>👍🏽</reaction>\
        <reaction>1️⃣</reaction><reaction></reaction>\
        </reactions></message>
        """)
        #expect(m.reactions?.emojis == ["👍", "❤️", "👩‍👩‍👧", "👍🏽", "1️⃣"])
    }

    @Test func needsAnID() throws {
        let m = try message("""
        <message type='chat'><reactions xmlns='urn:xmpp:reactions:0'><reaction>👍</reaction></reactions></message>
        """)
        #expect(m.reactions == nil)
    }
}

@Suite struct ReplyTests {
    let anna = try! JID("anna@example.com")

    /// The XEP-0461 example: the fallback is the quote in front of the body.
    @Test func stripsTheQuotedFallback() throws {
        let m = try message("""
        <message to='anna@example.com' id='message-id2' type='chat'>\
        <body>&gt; Anna wrote:\n&gt; We should bake a cake\nGreat idea!</body>\
        <reply to='anna@example.com/laptop' id='message-id1' xmlns='urn:xmpp:reply:0'/>\
        <fallback xmlns='urn:xmpp:fallback:0' for='urn:xmpp:reply:0'><body start='0' end='38'/></fallback>\
        </message>
        """)
        #expect(m.reply == MessageReply(id: "message-id1", to: try JID("anna@example.com/laptop")))
        let stripped = try #require(m.body(strippingFallbackFor: Namespaces.reply))
        #expect(stripped.body == "Great idea!")
        #expect(Message.unquote(stripped.fallback) == "Anna wrote:\nWe should bake a cake")
    }

    /// Ranges count code points, not UTF-16 units or grapheme clusters.
    @Test func rangesCountCodePoints() throws {
        let m = try message("""
        <message type='chat'><body>&gt; 👩‍👩‍👧 é\nok</body>\
        <reply xmlns='urn:xmpp:reply:0' id='x'/>\
        <fallback xmlns='urn:xmpp:fallback:0' for='urn:xmpp:reply:0'><body start='0' end='10'/></fallback></message>
        """)
        // "> " 2 + family 5 + " " 1 + "é" 1 + "\n" 1 = 10
        #expect(m.body(strippingFallbackFor: Namespaces.reply)?.body == "ok")
    }

    @Test func ignoresBadRangesAndOtherFallbacks() throws {
        let m = try message("""
        <message type='chat'><body>hello</body>\
        <fallback xmlns='urn:xmpp:fallback:0' for='urn:xmpp:reply:0'><body start='3' end='99'/></fallback>\
        <fallback xmlns='urn:xmpp:fallback:0' for='urn:other'><body start='0' end='2'/></fallback></message>
        """)
        #expect(m.body(strippingFallbackFor: Namespaces.reply)?.body == "hello")
        #expect(m.body(strippingFallbackFor: "urn:other")?.body == "llo")
    }

    @Test func buildsAReplyWithAQuote() throws {
        var sent = Message.chat(to: anna, body: "Great idea!", id: "m2")
        sent.setReply(MessageReply(id: "m1", to: anna), quoting: "We should\nbake a cake")
        let m = try message(sent.element.xmlString)
        #expect(m.body == "> We should\n> bake a cake\nGreat idea!")
        #expect(m.reply == MessageReply(id: "m1", to: anna))
        #expect(m.body(strippingFallbackFor: Namespaces.reply)?.body == "Great idea!")
        #expect(m.element.childElements(name: "body", namespaceURI: Namespaces.client).count == 1)
        // Still a normal chat message in every other way.
        #expect(m.isMarkable)
        #expect(m.originID == "m2")
    }

    @Test func aReplyWithoutAQuoteHasNoFallback() throws {
        var sent = Message.chat(to: anna, body: "yes", id: "m2")
        sent.setReply(MessageReply(id: "m1", to: nil), quoting: nil)
        #expect(sent.body == "yes")
        #expect(sent.element.firstChild(name: "fallback", namespaceURI: Namespaces.fallback) == nil)
        #expect(sent.reply?.to == nil)
    }
}

@Suite struct StylingTests {
    typealias A = MessageStyling.Attributes

    private func styled(_ text: String) -> [MessageStyling.Run] {
        let runs = MessageStyling.parse(text)
        #expect(runs.map(\.text).joined() == text, "runs must join to the original")
        return runs
    }

    /// The text of the runs with `predicate`, directives excluded.
    private func text(_ text: String, where predicate: (A) -> Bool) -> [String] {
        styled(text).filter { predicate($0.attributes) && !$0.attributes.directive }.map(\.text)
    }

    @Test func plainTextIsOneRun() {
        #expect(styled("just words") == [.init("just words", A())])
        #expect(!MessageStyling.hasStyling("2 * 3 = 6, snake_case_name, a~b"))
        #expect(styled("") == [])
    }

    @Test func spans() {
        #expect(text("I *really* mean it", where: \.strong) == ["really"])
        #expect(text("an _emphasis_ here", where: \.emphasis) == ["emphasis"])
        #expect(text("~gone~", where: \.strike) == ["gone"])
        #expect(text("run `ls *.swift` now", where: \.code) == ["ls *.swift"])
        // Nothing inside a preformatted span is styled.
        #expect(text("`*x*`", where: \.strong).isEmpty)
    }

    @Test func directivesStayInTheText() {
        let runs = styled("*hi*")
        var strong = A()
        strong.strong = true
        var directive = strong
        directive.directive = true
        #expect(runs == [.init("*", directive), .init("hi", strong), .init("*", directive)])
    }

    /// §5.2: openings at the start, after whitespace or after an opening;
    /// not followed by whitespace; closings not preceded by it; not empty.
    @Test func spanRules() {
        #expect(!MessageStyling.hasStyling("a*b*"))
        #expect(!MessageStyling.hasStyling("* not strong*"))
        #expect(!MessageStyling.hasStyling("*not strong *"))
        #expect(!MessageStyling.hasStyling("**"))
        #expect(!MessageStyling.hasStyling("*unclosed"))
        #expect(!MessageStyling.hasStyling("*across\nlines*"))
        #expect(text("*a* *b*", where: \.strong) == ["a", "b"])
        // The first matching directive closes the span.
        #expect(text("*a*b*", where: \.strong) == ["a"])
    }

    @Test func nestedSpans() {
        let runs = styled("*_both_ strong*")
        #expect(runs.contains { $0.text == "both" && $0.attributes.strong && $0.attributes.emphasis })
        #expect(runs.contains { $0.text == " strong" && $0.attributes.strong && !$0.attributes.emphasis })
        // A span inside itself is not a new span.
        #expect(text("*a *b* c*", where: \.strong) == ["a *b"])
    }

    @Test func preformattedBlocks() {
        let text = "look:\n```swift\nlet *x* = 1\n```\nafter *this*"
        let runs = styled(text)
        #expect(runs.contains { $0.text.contains("let *x* = 1\n") && $0.attributes.preformatted && !$0.attributes.strong })
        #expect(runs.contains { $0.text == "```swift" && $0.attributes.directive })
        #expect(runs.contains { $0.text == "this" && $0.attributes.strong && !$0.attributes.preformatted })
        // Unclosed: to the end of the message.
        #expect(self.text("```\n*a*", where: \.preformatted) == ["\n*a*"])
    }

    @Test func quotes() {
        let runs = styled("> quoted *bold*\n>> deeper\nplain")
        #expect(runs.contains { $0.text == "bold" && $0.attributes.strong && $0.attributes.quoteDepth == 1 })
        #expect(runs.contains { $0.text.hasPrefix("deeper") && $0.attributes.quoteDepth == 2 })
        #expect(runs.contains { $0.text == "plain" && $0.attributes.quoteDepth == 0 })
        // Every ">" is kept, marked as a directive.
        let markers = runs.filter { $0.attributes.directive && $0.text.hasPrefix(">") }.map(\.text).joined()
        #expect(markers.filter { $0 == ">" }.count == 3)
    }

    @Test func aPreformattedBlockEndsWithItsQuote() {
        let runs = styled("> ```\n> *code*\nafter *x*")
        #expect(runs.contains { $0.text.contains("*code*") && $0.attributes.preformatted && $0.attributes.quoteDepth == 1 })
        #expect(runs.contains { $0.text == "x" && $0.attributes.strong && !$0.attributes.preformatted })
    }

    @Test func emptyQuotedLinesKeepTheirMarker() {
        _ = styled(">\n> a\n>")
    }

    @Test func survivesArbitraryInput() {
        var generator = Fuzz.generator()
        let alphabet = Array("*_~`> \n```ab👍é")
        for _ in 0..<Fuzz.iterations(2000) {
            let length = Int.random(in: 0..<40, using: &generator)
            let text = String((0..<length).map { _ in alphabet.randomElement(using: &generator)! })
            _ = styled(text)
        }
    }

    @Test func unstyledHint() throws {
        let m = try message("<message type='chat'><body>*x*</body><unstyled xmlns='urn:xmpp:styling:0'/></message>")
        #expect(m.isUnstyled)
    }
}

@Suite struct DisplayedSyncTests {
    let juliet = try! JID("juliet@capulet.lit")

    private func notification(_ items: String, from: String = "juliet@capulet.lit") throws -> Message {
        try message("""
        <message from='\(from)' to='juliet@capulet.lit/phone' type='headline'>\
        <event xmlns='http://jabber.org/protocol/pubsub#event'>\
        <items node='urn:xmpp:mds:displayed:0'>\(items)</items></event></message>
        """)
    }

    @Test func readsMarkersForChatsAndRooms() throws {
        let changes = try #require(DisplayedSync.changes(in: notification("""
        <item id='romeo@montague.lit'><displayed xmlns='urn:xmpp:mds:displayed:0'>\
        <stanza-id xmlns='urn:xmpp:sid:0' id='s1' by='juliet@capulet.lit'/></displayed></item>\
        <item id='verona@rooms.lit'><displayed xmlns='urn:xmpp:mds:displayed:0'>\
        <stanza-id xmlns='urn:xmpp:sid:0' id='s2' by='verona@rooms.lit'/></displayed></item>
        """), account: juliet))
        #expect(changes == [
            .init(conversation: try JID("romeo@montague.lit"), stanzaID: "s1", by: juliet),
            .init(conversation: try JID("verona@rooms.lit"), stanzaID: "s2", by: try JID("verona@rooms.lit")),
        ])
    }

    /// An id assigned by someone else names nothing in our archives.
    @Test func refusesIDsFromElsewhere() throws {
        let changes = try #require(DisplayedSync.changes(in: notification("""
        <item id='romeo@montague.lit'><displayed xmlns='urn:xmpp:mds:displayed:0'>\
        <stanza-id xmlns='urn:xmpp:sid:0' id='s1' by='romeo@montague.lit'/></displayed></item>\
        <item id='romeo@montague.lit'><displayed xmlns='urn:xmpp:mds:displayed:0'>\
        <stanza-id xmlns='urn:xmpp:sid:0' id='s1' by='evil@example.org'/></displayed></item>
        """), account: juliet))
        // "by the conversation" is only right for a room, but a contact's
        // own id cannot match one of our archive ids either.
        #expect(changes.count == 1)
    }

    @Test func onlyOurOwnAccountMayNotify() throws {
        let changes = try DisplayedSync.changes(in: notification("""
        <item id='romeo@montague.lit'><displayed xmlns='urn:xmpp:mds:displayed:0'>\
        <stanza-id xmlns='urn:xmpp:sid:0' id='s1' by='juliet@capulet.lit'/></displayed></item>
        """, from: "evil@example.org"), account: juliet)
        #expect(changes == [])
    }

    @Test func publishesOneItemPerConversationPrivately() throws {
        let marker = DisplayedSync.Marker(conversation: try JID("romeo@montague.lit/phone"), stanzaID: "s1", by: juliet)
        let pubsub = DisplayedSync.publish(marker)
        let item = try #require(pubsub.firstChild(name: "publish")?.firstChild(name: "item"))
        #expect(item["id"] == "romeo@montague.lit")
        #expect(DisplayedSync.Marker(item: item) == marker)
        let form = try #require(pubsub.firstChild(name: "publish-options")?.firstChild(name: "x"))
        #expect(form.xmlString.contains("whitelist"))
        #expect(form.xmlString.contains("pubsub#max_items"))
    }
}

@Suite struct MentionTests {
    let room = try! JID("verona@conference.example.com")

    /// Whole words, any case, longest nick first; offsets in code points.
    @Test func findsNicksAsWords() {
        let found = Mention.find(["Romeo", "Romeo Jr", "Tybalt"], in: "👋 @romeo jr, romeos and TYBALT:")
        #expect(found.map(\.nick) == ["Romeo Jr", "Tybalt"])
        // 👋 is one code point: "@" at 2, "romeo jr" at 3..<11.
        #expect(found.first?.range == 3..<11)
        #expect(found.last?.range == 24..<30)
        #expect(Mention.find(["Ro"], in: "Romeo").isEmpty)
    }

    /// Mentions go outside a reply's quote, as occupant JIDs; and read back.
    @Test func marksUpOccupantsOutsideTheQuote() throws {
        var message = Message.groupchat(to: room, body: "Tybalt, you rat-catcher", id: "m1")
        message.setReply(MessageReply(id: "S1", to: try room.withResource("Tybalt")), quoting: "Tybalt said hi")
        let marked = message.mentioningOccupants(["Tybalt", "Benvolio"], in: room)
        let mentions = marked.mentions
        #expect(mentions.count == 1)
        #expect(mentions.first?.jid == (try room.withResource("Tybalt")))
        let body = Array(try #require(marked.body).unicodeScalars)
        let range = try #require(mentions.first?.range)
        #expect(String(String.UnicodeScalarView(body[range])) == "Tybalt")
        #expect(range.lowerBound >= "> Tybalt said hi\n".unicodeScalars.count)
    }

    @Test func readsReferences() throws {
        let parser = StreamParser()
        _ = try parser.parse(Array("<stream:stream xmlns='jabber:client' xmlns:stream='http://etherx.jabber.org/streams'>".utf8))
        guard case .stanza(let element) = try parser.parse(Array("""
        <message type='groupchat' from='verona@conference.example.com/Mercutio'><body>hey you</body>\
        <reference xmlns='urn:xmpp:reference:0' type='mention' uri='xmpp:juliet@example.com' begin='4' end='7'/>\
        <reference xmlns='urn:xmpp:reference:0' type='data' uri='https://example.com'/>\
        <reference xmlns='urn:xmpp:reference:0' type='mention' uri='xmpp:verona@conference.example.com/Romeo'/>\
        </message>
        """.utf8)).first, let message = Message(element) else { Issue.record("parse"); return }
        #expect(message.mentions == [Mention(jid: try JID("juliet@example.com"), range: 4..<7),
                                     Mention(jid: try room.withResource("Romeo"), range: nil)])
    }
}
