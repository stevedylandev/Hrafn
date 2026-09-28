import Testing
@testable import XMPPXML

@Suite struct SerializerTests {

    @Test func omitsDeclarationForAnElementInNoNamespace() {
        #expect(Serializer.string(for: Element(name: "a")) == "<a/>")
    }

    @Test func declaresNamespaceOnlyWhenItChanges() {
        let stanza = Element(name: "iq", namespaceURI: Namespaces.client, attributes: ["type": "get"])
            .adding(Element(name: "query", namespaceURI: "jabber:iq:roster"))
            .adding(Element(name: "body", namespaceURI: Namespaces.client, text: "x"))
        let xml = Serializer.string(for: stanza, inheritedNamespace: Namespaces.client)
        #expect(xml == "<iq type='get'><query xmlns='jabber:iq:roster'/><body>x</body></iq>")
    }

    @Test func escapesCharacterData() {
        let element = Element(name: "body", text: #"5 < 6 & "quoted" > 4"#)
        #expect(Serializer.string(for: element)
            == #"<body>5 &lt; 6 &amp; "quoted" &gt; 4</body>"#)
    }

    @Test func escapesAttributeValues() {
        let element = Element(name: "message", attributes: ["subject": "it's\na \"test\"\t<>&"])
        #expect(Serializer.string(for: element)
            == "<message subject='it&apos;s&#xA;a &quot;test&quot;&#x9;&lt;&gt;&amp;'/>")
    }

    @Test func attributeOrderIsDeterministic() {
        let element = Element(name: "m", attributes: ["z": "1", "a": "2", "id": "3"])
        #expect(Serializer.string(for: element) == "<m a='2' id='3' z='1'/>")
    }

    @Test func streamOpenIsUnbalancedAndCarriesNoXMLDeclaration() {
        let open = Serializer.streamOpen(to: "example.com")
        #expect(!open.contains("<?xml"))
        #expect(open.hasSuffix(">"))
        #expect(!open.hasSuffix("/>"))
        #expect(open.contains("to='example.com'"))
        #expect(open.contains("version='1.0'"))
        #expect(open.contains("xmlns='jabber:client'"))
        #expect(open.contains("xmlns:stream='http://etherx.jabber.org/streams'"))
    }

    @Test func roundTripsThroughTheParser() throws {
        let original = Element(name: "message", namespaceURI: Namespaces.client,
                              attributes: ["to": "a@b", "xml:lang": "en"])
            .adding(Element(name: "body", namespaceURI: Namespaces.client,
                            text: "emoji 🎉 and <markup> & 'quotes'"))
            .adding(Element(name: "active", namespaceURI: "http://jabber.org/protocol/chatstates"))

        let parser = StreamParser()
        _ = try parser.parse(Array(Serializer.streamOpen(to: "example.com").utf8))
        let serialized = Serializer.string(for: original, inheritedNamespace: Namespaces.client)
        let events = try parser.parse(Array(serialized.utf8))

        guard case .stanza(let parsed) = events.first else { return #expect(Bool(false)) }
        #expect(parsed == original)
    }
}

@Suite struct ElementTests {

    @Test func textConcatenatesCharacterDataAndSkipsElements() {
        var element = Element(name: "body", text: "hello ")
        element.addChild(Element(name: "b", text: "IGNORED"))
        element.addText("world")
        #expect(element.text == "hello world")
    }

    @Test func childLookupMatchesNameAndNamespace() {
        let element = Element(name: "message")
            .adding(Element(name: "x", namespaceURI: "ns1"))
            .adding(Element(name: "x", namespaceURI: "ns2"))
        #expect(element.firstChild(name: "x", namespaceURI: "ns2")?.namespaceURI == "ns2")
        #expect(element.childElements(name: "x").count == 2)
        #expect(element.firstChild(name: "x", namespaceURI: "ns3") == nil)
    }

    @Test func attributeSubscriptRemovesOnNil() {
        var element = Element(name: "iq", attributes: ["id": "1"])
        element["id"] = nil
        #expect(element.attributes.isEmpty)
    }

    @Test func removeChildrenFiltersOneLevel() {
        var element = Element(name: "message")
            .adding(Element(name: "body", text: "keep"))
            .adding(Element(name: "x", namespaceURI: "drop"))
        element.removeChildren(namespaceURI: "drop")
        #expect(element.elements.map(\.name) == ["body"])
    }

    @Test func dropsCharactersXMLCannotCarry() {
        let element = Element(name: "body", attributes: ["a": "x\u{1}y"], text: "a\u{0}b\u{8}c\u{FFFE}d\te")
        #expect(Serializer.string(for: element) == "<body a='xy'>abcd\te</body>")
    }
}
