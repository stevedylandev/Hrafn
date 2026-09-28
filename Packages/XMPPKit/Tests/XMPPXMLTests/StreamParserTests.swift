import Testing
import Foundation
@testable import XMPPXML
import XMPPTestSupport

private func events(_ parser: StreamParser, _ chunks: String...) throws -> [StreamEvent] {
    var all: [StreamEvent] = []
    for chunk in chunks {
        all += try parser.parse(Array(chunk.utf8))
    }
    return all
}

private let streamHeader = """
<?xml version='1.0'?><stream:stream from='example.com' id='abc' version='1.0' \
xmlns='jabber:client' xmlns:stream='http://etherx.jabber.org/streams'>
"""

@Suite struct StreamFramingTests {

    @Test func emitsStreamOpenBeforeItCloses() throws {
        let parser = StreamParser()
        let result = try events(parser, streamHeader)
        #expect(result.count == 1)
        guard case .streamOpen(let element) = result[0] else { return #expect(Bool(false)) }
        #expect(element.name == "stream")
        #expect(element.namespaceURI == Namespaces.stream)
        #expect(element["id"] == "abc")
        #expect(element["from"] == "example.com")
    }

    @Test func emitsOneEventPerTopLevelStanza() throws {
        let parser = StreamParser()
        _ = try events(parser, streamHeader)
        let result = try events(parser,
            "<message to='a@b'><body>hi</body></message>",
            "<presence/>")
        #expect(result.count == 2)
        guard case .stanza(let message) = result[0], case .stanza(let presence) = result[1] else {
            return #expect(Bool(false))
        }
        #expect(message.name == "message")
        #expect(message.namespaceURI == Namespaces.client)
        #expect(message.firstChild(name: "body")?.text == "hi")
        #expect(presence.name == "presence")
    }

    @Test func reassemblesStanzasSplitAcrossReads() throws {
        let parser = StreamParser()
        _ = try events(parser, streamHeader)
        let stanza = "<message id='1'><body>split across packets</body></message>"
        var collected: [StreamEvent] = []
        for byte in Array(stanza.utf8) {
            collected += try parser.parse([byte])
        }
        #expect(collected.count == 1)
        guard case .stanza(let message) = collected[0] else { return #expect(Bool(false)) }
        #expect(message.firstChild(name: "body")?.text == "split across packets")
    }

    @Test func whitespaceKeepaliveProducesNoEvent() throws {
        let parser = StreamParser()
        _ = try events(parser, streamHeader)
        #expect(try events(parser, "\n", " ", "\t").isEmpty)
    }

    @Test func reportsStreamClose() throws {
        let parser = StreamParser()
        _ = try events(parser, streamHeader)
        let result = try events(parser, "</stream:stream>")
        #expect(result == [.streamClose])
        #expect(parser.isClosed)
    }

    @Test func nestedChildrenKeepOrderAndNamespaces() throws {
        let parser = StreamParser()
        _ = try events(parser, streamHeader)
        let result = try events(parser, """
        <iq type='result'><query xmlns='jabber:iq:roster'>\
        <item jid='a@b'/><item jid='c@d'/></query></iq>
        """)
        guard case .stanza(let iq) = result[0] else { return #expect(Bool(false)) }
        let query = try #require(iq.firstChild(name: "query", namespaceURI: "jabber:iq:roster"))
        #expect(query.childElements(name: "item").map { $0["jid"] } == ["a@b", "c@d"])
    }

    @Test func keepsPrefixedAttributeNames() throws {
        let parser = StreamParser()
        _ = try events(parser, streamHeader)
        let result = try events(parser, "<message xml:lang='de'><body>hallo</body></message>")
        guard case .stanza(let message) = result[0] else { return #expect(Bool(false)) }
        #expect(message.lang == "de")
    }

    @Test func resolvesPredefinedEntitiesAndNumericReferences() throws {
        let parser = StreamParser()
        _ = try events(parser, streamHeader)
        let result = try events(parser,
            "<message><body>a &amp; b &lt;c&gt; &quot;d&quot; &#65;</body></message>")
        guard case .stanza(let message) = result[0] else { return #expect(Bool(false)) }
        #expect(message.firstChild(name: "body")?.text == #"a & b <c> "d" A"#)
    }

    @Test func treatsCDATAAsCharacterData() throws {
        let parser = StreamParser()
        _ = try events(parser, streamHeader)
        let result = try events(parser, "<message><body><![CDATA[<not markup>]]></body></message>")
        guard case .stanza(let message) = result[0] else { return #expect(Bool(false)) }
        #expect(message.firstChild(name: "body")?.text == "<not markup>")
    }

    @Test func resetAllowsANewStreamOnTheSameParser() throws {
        let parser = StreamParser()
        _ = try events(parser, streamHeader, "<presence/>")
        parser.reset()
        #expect(!parser.isClosed)
        let result = try events(parser, streamHeader, "<presence/>")
        #expect(result.count == 2)
    }
}

@Suite struct ParserHardeningTests {

    @Test func rejectsDoctype() throws {
        let parser = StreamParser()
        #expect(throws: XMLError.self) {
            _ = try parser.parse(Array("<!DOCTYPE stream [<!ENTITY x 'y'>]><stream:stream/>".utf8))
        }
    }

    /// The classic billion-laughs shape: unreachable because a DTD is refused
    /// before any entity can be declared.
    @Test func rejectsEntityExpansionBomb() throws {
        let bomb = """
        <!DOCTYPE lolz [<!ENTITY lol "lol">\
        <!ENTITY lol2 "&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;">]>\
        <stream:stream xmlns:stream='http://etherx.jabber.org/streams'><message>&lol2;</message>
        """
        let parser = StreamParser()
        #expect(throws: XMLError.self) { _ = try parser.parse(Array(bomb.utf8)) }
    }

    @Test func rejectsUndeclaredEntity() throws {
        let parser = StreamParser()
        _ = try events(parser, streamHeader)
        #expect(throws: XMLError.self) {
            _ = try parser.parse(Array("<message><body>&mine;</body></message>".utf8))
        }
    }

    @Test func rejectsProcessingInstructionMidStream() throws {
        let parser = StreamParser()
        _ = try events(parser, streamHeader)
        #expect(throws: XMLError.self) {
            _ = try parser.parse(Array("<?evil do-something?>".utf8))
        }
    }

    @Test func enforcesDepthLimit() throws {
        let parser = StreamParser(limits: .init(maxDepth: 8))
        _ = try events(parser, streamHeader)
        let deep = String(repeating: "<a>", count: 32)
        #expect(throws: XMLError.self) { _ = try parser.parse(Array(deep.utf8)) }
    }

    @Test func enforcesStanzaSizeLimit() throws {
        let parser = StreamParser(limits: .init(maxStanzaBytes: 4096))
        _ = try events(parser, streamHeader)
        let huge = "<message><body>" + String(repeating: "x", count: 8192)
        #expect(throws: XMLError.self) { _ = try parser.parse(Array(huge.utf8)) }
    }

    @Test func sizeLimitCountsPerStanzaNotPerStream() throws {
        let parser = StreamParser(limits: .init(maxStanzaBytes: 512))
        _ = try events(parser, streamHeader)
        for _ in 0..<50 {
            let result = try events(parser, "<message><body>\(String(repeating: "y", count: 200))</body></message>")
            #expect(result.count == 1)
        }
    }

    @Test func rejectsMalformedXML() throws {
        let parser = StreamParser()
        _ = try events(parser, streamHeader)
        #expect(throws: XMLError.self) {
            _ = try parser.parse(Array("<message></nope>".utf8))
        }
    }

    @Test func rejectsSecondRootElement() throws {
        let parser = StreamParser()
        _ = try events(parser, streamHeader, "</stream:stream>")
        #expect(throws: XMLError.self) {
            _ = try parser.parse(Array(streamHeader.utf8))
        }
    }

    /// libxml2 without entity substitution returns `&amp;` in attributes as
    /// `&#38;`; an upload slot's query string must come back intact.
    @Test func decodesAmpersandsInAttributes() throws {
        let parser = StreamParser()
        _ = try events(parser, streamHeader)
        let result = try events(parser,
            "<put url='https://h/f?a=1&amp;b=2&#38;c=\u{301}&amp;\u{301}' x='&lt;&amp;amp;&gt;'/>")
        guard case .stanza(let put) = result[0] else { return #expect(Bool(false)) }
        #expect(put["url"] == "https://h/f?a=1&b=2&c=\u{301}&\u{301}")
        #expect(put["x"] == "<&amp;>")
    }

    @Test func enforcesElementCountLimit() throws {
        let parser = StreamParser(limits: .init(maxElements: 100))
        _ = try events(parser, streamHeader)
        #expect(try events(parser, "<message>" + String(repeating: "<a/>", count: 98) + "</message>").count == 1)
        #expect(throws: XMLError.self) {
            try events(parser, "<message>" + String(repeating: "<a/>", count: 100) + "</message>")
        }
    }

    /// A prefix other than `xml` survives the round trip with its declaration,
    /// so what we store and republish (bookmark extensions) stays well formed.
    @Test func prefixedAttributesKeepTheirNamespace() throws {
        let parser = StreamParser()
        _ = try events(parser, streamHeader)
        let result = try events(parser, "<message xmlns:ext='urn:x'><body ext:hint='1'>x</body></message>")
        guard case .stanza(let message) = result[0] else { return #expect(Bool(false)) }
        let body = try #require(message.firstChild(name: "body"))
        #expect(body["ext:hint"] == "1")
        let reparsed = try Element(xmlFragment: body.xmlString)
        #expect(reparsed["ext:hint"] == "1")
    }

    /// Random-byte and mutation fuzzing: the parser may reject anything, but it
    /// must never trap, hang, or leave a usable parser in a wedged state.
    @Test func survivesRandomAndMutatedInput() throws {
        var generator = Fuzz.generator()
        let seeds = [
            streamHeader,
            "<message to='a@b'><body>hi</body></message>",
            "<iq type='get'><query xmlns='x'/></iq>",
            "<?xml version='1.0'?>",
            "<![CDATA[abc]]>",
            "&amp;&#x41;",
        ]
        for iteration in 0..<Fuzz.iterations(600) {
            let parser = StreamParser(limits: .init(maxStanzaBytes: 1 << 16, maxDepth: 16))
            var payload = Array(seeds[iteration % seeds.count].utf8)
            // Mutate: flip, truncate, duplicate, or splice in random noise.
            switch iteration % 4 {
            case 0:
                for _ in 0..<(1 + iteration % 5) where !payload.isEmpty {
                    payload[Int.random(in: 0..<payload.count, using: &generator)] =
                        UInt8.random(in: 0...255, using: &generator)
                }
            case 1:
                payload = Array(payload.prefix(Int.random(in: 0...payload.count, using: &generator)))
            case 2:
                payload += payload
            default:
                payload += (0..<32).map { _ in UInt8.random(in: 0...255, using: &generator) }
            }
            // Feed in random-sized slices to exercise chunk boundaries.
            var offset = 0
            while offset < payload.count {
                let size = min(payload.count - offset, Int.random(in: 1...17, using: &generator))
                do { _ = try parser.parse(payload[offset..<(offset + size)]) }
                catch is XMLError { break }
                offset += size
            }
        }
    }

    /// Whatever text or attribute value is serialized parses back to the same
    /// thing, minus the characters XML cannot carry — never to a stream error.
    @Test func serializedRandomTextAlwaysParsesBack() throws {
        var generator = Fuzz.generator()
        let interesting: [Unicode.Scalar] = ["<", ">", "&", "'", "\"", "\t", "\n", "\r", "\u{0}", "\u{1}",
                                            "\u{1F}", "\u{7F}", "\u{85}", "\u{FFFE}", "\u{FFFF}", "\u{FEFF}",
                                            "é", "\u{1F600}", "]", "\u{2028}"]
        for _ in 0..<Fuzz.iterations(1500) {
            var text = String.UnicodeScalarView()
            for _ in 0..<Int.random(in: 0..<40, using: &generator) {
                if Bool.random(using: &generator) {
                    text.append(interesting.randomElement(using: &generator)!)
                } else if let scalar = Unicode.Scalar(UInt32.random(in: 0...0x10FFFF, using: &generator)) {
                    text.append(scalar)
                }
            }
            let value = String(text)
            let element = Element(name: "body", attributes: ["a": value], text: value)
            let parsed = try Element(xmlFragment: element.xmlString)
            let allowed = String(String.UnicodeScalarView(value.unicodeScalars.filter(Serializer.isAllowed)))
            // A parser normalizes CR and CRLF in text to LF (XML 1.0 §2.11)
            // unless escaped, which the serializer does.
            #expect(parsed.text == allowed)
            #expect(parsed["a"] == allowed)
        }
    }
}
