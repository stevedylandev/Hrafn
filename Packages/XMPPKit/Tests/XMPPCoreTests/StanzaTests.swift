import Testing
@testable import XMPPCore
import XMPPXML

@Suite struct StanzaTests {

    @Test func iqRequiresTypeAndID() {
        let base = Element(name: "iq", namespaceURI: Namespaces.client)
        #expect(IQ(base) == nil)
        #expect(IQ(Element(name: "iq", namespaceURI: Namespaces.client, attributes: ["type": "get"])) == nil)
        #expect(IQ(Element(name: "iq", namespaceURI: Namespaces.client, attributes: ["id": "1"])) == nil)
        #expect(IQ(Element(name: "iq", namespaceURI: Namespaces.client, attributes: ["id": "1", "type": "bogus"])) == nil)
        #expect(IQ(Element(name: "iq", namespaceURI: Namespaces.client, attributes: ["id": "1", "type": "get"])) != nil)
        #expect(IQ(Element(name: "iq", namespaceURI: "jabber:server", attributes: ["id": "1", "type": "get"])) == nil)
    }

    @Test func repliesAreAddressedToTheRequester() throws {
        var request = IQ(type: .get, id: "abc", payload: Element(name: "ping", namespaceURI: "urn:xmpp:ping"))
        request.from = try JID("romeo@example.com/orchard")

        let result = request.makeResult()
        #expect(result.type == .result)
        #expect(result.requestID == "abc")
        #expect(result.to == (try JID("romeo@example.com/orchard")))
        #expect(result.payload == nil)

        let error = request.makeError(StanzaError(.serviceUnavailable))
        #expect(error.type == .error)
        #expect(error.error == StanzaError(.serviceUnavailable, type: .cancel))
        #expect(error.payload == nil, "the request payload is not echoed")
        #expect(error.element.xmlString == """
        <iq xmlns='jabber:client' id='abc' to='romeo@example.com/orchard' type='error'>\
        <error type='cancel'><service-unavailable xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/></error></iq>
        """)
    }

    @Test func parsesStanzaErrors() {
        let element = Element(name: "error", namespaceURI: Namespaces.client, attributes: ["type": "modify", "by": "example.com"], children: [
            .element(Element(name: "gone", namespaceURI: Namespaces.stanzas, text: "xmpp:new@example.com")),
            .element(Element(name: "text", namespaceURI: Namespaces.stanzas, text: "moved")),
            .element(Element(name: "too-many", namespaceURI: "urn:example:app")),
        ])
        let error = StanzaError(element: element)
        #expect(error.condition == .gone)
        #expect(error.type == .modify)
        #expect(error.text == "moved")
        #expect(error.by == "example.com")
        #expect(error.alternateAddress == "xmpp:new@example.com")
        #expect(error.applicationCondition?.name == "too-many")
        #expect(StanzaError(element: error.element) == error, "round trip")
    }

    @Test func unknownConditionsAreUndefined() {
        let element = Element(name: "error", namespaceURI: Namespaces.client, children: [
            .element(Element(name: "made-up", namespaceURI: Namespaces.stanzas)),
        ])
        let error = StanzaError(element: element)
        #expect(error.condition == .undefinedCondition)
        #expect(error.type == .cancel)
    }

    @Test func invalidAddressesReadAsNil() {
        let message = Message(Element(name: "message", namespaceURI: Namespaces.client,
                                      attributes: ["from": "@@bad", "to": "juliet@example.com"]))!
        #expect(message.from == nil)
        #expect(message.to == (try? JID("juliet@example.com")))
        #expect(message.type == .normal, "missing type means normal (RFC 6121 §5.2.2)")
    }

    @Test func presenceTypes() {
        #expect(Presence(Element(name: "presence", namespaceURI: Namespaces.client))!.type == .available)
        #expect(Presence(Element(name: "presence", namespaceURI: Namespaces.client, attributes: ["type": "subscribe"]))!.type == .subscribe)
        #expect(Presence(Element(name: "presence", namespaceURI: Namespaces.client, attributes: ["type": "available"]))!.type == .error)
        #expect(Presence(type: .available).element["type"] == nil)
    }

    @Test func stanzaIDsAreUnique() {
        #expect(Set((0..<1000).map { _ in StanzaID.make() }).count == 1000)
    }
}
