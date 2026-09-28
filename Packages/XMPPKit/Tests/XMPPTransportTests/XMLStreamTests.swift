import Testing
import Foundation
@testable import XMPPTransport
import XMPPCore
import XMPPXML

/// In-process transport that answers with whatever the test scripts, so the
/// framing and TLS-upgrade logic can be driven without a server.
final class FakeTransport: StreamTransport, @unchecked Sendable {
    let inbound: AsyncThrowingStream<Data, any Error>
    private let continuation: AsyncThrowingStream<Data, any Error>.Continuation
    private let lock = NSLock()
    private var sentChunks: [String] = []
    private var encrypted: Bool
    private(set) var startTLSCalls = 0
    var startTLSFails = false

    /// Invoked for every outgoing chunk; use `inject` to answer.
    var respond: (@Sendable (String, FakeTransport) -> Void)?

    init(encrypted: Bool = false) {
        self.encrypted = encrypted
        (inbound, continuation) = AsyncThrowingStream.makeStream(of: Data.self)
    }

    var sent: [String] { lock.withLock { sentChunks } }
    var isEncrypted: Bool { get async { lock.withLock { encrypted } } }

    func connect() async throws {}

    func send(_ data: Data) async throws {
        let xml = String(decoding: data, as: UTF8.self)
        lock.withLock { sentChunks.append(xml) }
        respond?(xml, self)
    }

    func startTLS() async throws {
        lock.withLock { startTLSCalls += 1 }
        if startTLSFails { throw TransportError(.tlsFailed("scripted failure")) }
        lock.withLock { encrypted = true }
    }

    func close() async { continuation.finish() }
    func channelBindingExporter() async -> Data? { nil }

    func inject(_ xml: String) { continuation.yield(Data(xml.utf8)) }
    func fail(_ error: any Error) { continuation.finish(throwing: error) }
    func endOfStream() { continuation.finish() }
}

private let serverHeader = """
<?xml version='1.0'?><stream:stream id='s1' from='example.com' version='1.0' \
xmlns='jabber:client' xmlns:stream='http://etherx.jabber.org/streams'>
"""

private func makeStream(_ transport: FakeTransport) throws -> XMLStream {
    XMLStream(endpoint: Endpoint(host: "example.com", port: 5222, security: .startTLS,
                                domain: "example.com"),
              domain: try JID("example.com"),
              policy: .insecureAcceptAll,
              transport: transport)
}

@Suite struct XMLStreamTests {

    @Test func sendsHeaderAndReturnsTheServerHeader() async throws {
        let transport = FakeTransport()
        transport.respond = { xml, transport in
            if xml.contains("<stream:stream") { transport.inject(serverHeader) }
        }
        let stream = try makeStream(transport)
        let header = try await stream.open()
        #expect(header["id"] == "s1")
        #expect(transport.sent.first?.contains("to='example.com'") == true)
        #expect(transport.sent.first?.contains("xmlns='jabber:client'") == true)
    }

    @Test func negotiatesSTARTTLSAndRestartsTheStream() async throws {
        let transport = FakeTransport()
        transport.respond = { xml, transport in
            if xml.contains("<stream:stream") {
                transport.inject(serverHeader)
                // Pre-TLS features: STARTTLS only.
                if transport.startTLSCalls == 0 {
                    transport.inject("""
                    <stream:features><starttls xmlns='urn:ietf:params:xml:ns:xmpp-tls'>\
                    <required/></starttls></stream:features>
                    """)
                } else {
                    transport.inject("""
                    <stream:features><mechanisms xmlns='urn:ietf:params:xml:ns:xmpp-sasl'>\
                    <mechanism>SCRAM-SHA-256</mechanism></mechanisms></stream:features>
                    """)
                }
            } else if xml.contains("<starttls") {
                transport.inject("<proceed xmlns='urn:ietf:params:xml:ns:xmpp-tls'/>")
            }
        }

        let stream = try makeStream(transport)
        try await stream.open()
        let features = try await stream.awaitFeatures()
        #expect(features.firstChild(name: "starttls", namespaceURI: Namespaces.tls) != nil)

        let secured = try #require(try await stream.negotiateTLS(features: features))
        #expect(await stream.isEncrypted)
        #expect(transport.startTLSCalls == 1)
        // The restarted stream offers SASL, proving parser state was discarded.
        let mechanisms = try #require(secured.firstChild(name: "mechanisms", namespaceURI: Namespaces.sasl))
        #expect(mechanisms.childElements(name: "mechanism").map(\.text) == ["SCRAM-SHA-256"])
        // Two headers sent: one per stream.
        #expect(transport.sent.filter { $0.contains("<stream:stream") }.count == 2)
    }

    @Test func failsWhenTLSIsRequiredButNotOffered() async throws {
        let transport = FakeTransport()
        transport.respond = { xml, transport in
            if xml.contains("<stream:stream") {
                transport.inject(serverHeader)
                transport.inject("<stream:features/>")
            }
        }
        let stream = try makeStream(transport)
        try await stream.open()
        let features = try await stream.awaitFeatures()
        await #expect(throws: XMLStream.Failure.tlsRequiredButNotOffered) {
            try await stream.negotiateTLS(features: features)
        }
    }

    @Test func surfacesSTARTTLSRefusal() async throws {
        let transport = FakeTransport()
        transport.respond = { xml, transport in
            if xml.contains("<stream:stream") {
                transport.inject(serverHeader)
                transport.inject("""
                <stream:features><starttls xmlns='urn:ietf:params:xml:ns:xmpp-tls'/></stream:features>
                """)
            } else if xml.contains("<starttls") {
                transport.inject("<failure xmlns='urn:ietf:params:xml:ns:xmpp-tls'/>")
            }
        }
        let stream = try makeStream(transport)
        try await stream.open()
        let features = try await stream.awaitFeatures()
        await #expect(throws: XMLStream.Failure.tlsRefusedByServer) {
            try await stream.negotiateTLS(features: features)
        }
    }

    @Test func reportsStreamErrorsWithTheirCondition() async throws {
        let transport = FakeTransport()
        transport.respond = { xml, transport in
            if xml.contains("<stream:stream") {
                transport.inject(serverHeader)
                transport.inject("""
                <stream:error><host-unknown xmlns='urn:ietf:params:xml:ns:xmpp-streams'/>\
                <text xmlns='urn:ietf:params:xml:ns:xmpp-streams'>no such host</text></stream:error>
                """)
            }
        }
        let stream = try makeStream(transport)
        try await stream.open()
        await #expect(throws: XMLStream.Failure.streamError(condition: "host-unknown",
                                                            text: "no such host")) {
            try await stream.awaitFeatures()
        }
    }

    @Test func propagatesTransportFailures() async throws {
        let transport = FakeTransport()
        transport.respond = { xml, transport in
            if xml.contains("<stream:stream") {
                transport.inject(serverHeader)
                transport.fail(TransportError(.connectionFailed("cable unplugged")))
            }
        }
        let stream = try makeStream(transport)
        try await stream.open()
        await #expect(throws: TransportError(.connectionFailed("cable unplugged"))) {
            try await stream.awaitFeatures()
        }
    }

    @Test func endOfStreamEndsEventDelivery() async throws {
        let transport = FakeTransport()
        transport.respond = { xml, transport in
            if xml.contains("<stream:stream") {
                transport.inject(serverHeader)
                transport.endOfStream()
            }
        }
        let stream = try makeStream(transport)
        try await stream.open()
        await #expect(throws: XMLStream.Failure.streamClosedByPeer) {
            try await stream.awaitFeatures()
        }
    }

    @Test func logsBothDirectionsThroughTheConsole() async throws {
        let console = RingBufferXMLConsole()
        let transport = FakeTransport()
        transport.respond = { xml, transport in
            if xml.contains("<stream:stream") { transport.inject(serverHeader) }
        }
        let stream = XMLStream(
            endpoint: Endpoint(host: "example.com", port: 5222, security: .startTLS, domain: "example.com"),
            domain: try JID("example.com"),
            policy: .insecureAcceptAll,
            transport: transport,
            console: RedactingXMLConsole(console))
        try await stream.open()
        #expect(console.entries.contains { $0.direction == .sent })
        #expect(console.entries.contains { $0.direction == .received })
    }
}

@Suite struct RedactionTests {

    @Test func redactsSASLPayloadsButKeepsTheMechanism() {
        let xml = "<auth xmlns='urn:ietf:params:xml:ns:xmpp-sasl' mechanism='PLAIN'>AGp1bGlldAByMG0zMA==</auth>"
        let redacted = RedactingXMLConsole.redact(xml)
        #expect(redacted.contains("mechanism='PLAIN'"))
        #expect(!redacted.contains("AGp1bGlldAByMG0zMA=="))
        #expect(redacted.contains("[redacted"))
    }

    @Test func redactsChallengeResponseAndPassword() {
        for element in ["response", "challenge", "success", "password", "token", "secret"] {
            let redacted = RedactingXMLConsole.redact("<\(element)>sensitive</\(element)>")
            #expect(!redacted.contains("sensitive"), "\(element) leaked")
        }
    }

    /// SASL2 payloads, and the FAST token handed over as an attribute.
    @Test func redactsSASL2AndFASTTokens() {
        let xml = """
        <authenticate xmlns='urn:xmpp:sasl:2' mechanism='HT-SHA-256-EXPR'><initial-response>c2VjcmV0</initial-response>\
        <fast xmlns='urn:xmpp:fast:0' count='3'/></authenticate>\
        <token xmlns='urn:xmpp:fast:0' expiry='2026-10-01T00:00:00Z' token="WXZzciBwYXNz"/>\
        <additional-data>cHJvb2Y=</additional-data>
        """
        let redacted = RedactingXMLConsole.redact(xml)
        for secret in ["c2VjcmV0", "WXZzciBwYXNz", "cHJvb2Y="] { #expect(!redacted.contains(secret), "\(secret) leaked") }
        #expect(redacted.contains("mechanism='HT-SHA-256-EXPR'") && redacted.contains("count='3'"))
        #expect(redacted.contains("expiry='2026-10-01T00:00:00Z'"))
    }

    @Test func leavesOrdinaryStanzasAlone() {
        let xml = "<message to='a@b'><body>the password is hunter2</body></message>"
        #expect(RedactingXMLConsole.redact(xml) == xml)
    }

    @Test func handlesEmptyElementsAndRepeats() {
        #expect(RedactingXMLConsole.redact("<auth mechanism='EXTERNAL'/>")
            == "<auth mechanism='EXTERNAL'/>")
        let repeated = RedactingXMLConsole.redact("<response>a</response><response>b</response>")
        #expect(!repeated.contains(">a<") && !repeated.contains(">b<"))
    }

    @Test func doesNotMatchLongerElementNames() {
        let xml = "<passwordPolicy>strict</passwordPolicy>"
        #expect(RedactingXMLConsole.redact(xml) == xml)
    }
}

/// A transport that accepts a connection and then says nothing, which is how a
/// half-open connection or a wedged server behaves.
private final class SilentTransport: StreamTransport, @unchecked Sendable {
    let inbound: AsyncThrowingStream<Data, any Error>
    private let continuation: AsyncThrowingStream<Data, any Error>.Continuation
    private let lock = NSLock()
    private var closed = false
    var connectHangs = false

    init() { (inbound, continuation) = AsyncThrowingStream.makeStream(of: Data.self) }

    var isEncrypted: Bool { get async { false } }
    var didClose: Bool { lock.withLock { closed } }

    func connect() async throws {
        guard connectHangs else { return }
        // Never resumes on its own; only cancellation can end this.
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (_: CheckedContinuation<Void, any Error>) in }
        } onCancel: {}
    }

    func send(_ data: Data) async throws {}
    func startTLS() async throws {}
    func close() async {
        lock.withLock { closed = true }
        continuation.finish()
    }
    func channelBindingExporter() async -> Data? { nil }
}

/// Every wait during negotiation must be bounded, and every bound must actually
/// fire: a checked continuation ignores cancellation unless it is made to notice,
/// and a task-group timeout cannot return while a child is parked on one.
@Suite struct StreamLivenessTests {

    private func stream(_ transport: any StreamTransport, timeout: Duration = .milliseconds(200)) throws -> XMLStream {
        XMLStream(endpoint: Endpoint(host: "example.com", port: 5222, security: .startTLS,
                                    domain: "example.com"),
                  domain: try JID("example.com"),
                  policy: .insecureAcceptAll,
                  transport: transport,
                  negotiationTimeout: timeout)
    }

    @Test func openTimesOutWhenTheServerSendsNoHeader() async throws {
        let stream = try stream(SilentTransport())
        let started = ContinuousClock.now
        await #expect(throws: TransportError(.timedOut)) { try await stream.open() }
        #expect(started.duration(to: .now) < .seconds(2))
    }

    @Test func awaitFeaturesTimesOutWhenTheServerStalls() async throws {
        let transport = FakeTransport()
        transport.respond = { xml, transport in
            if xml.contains("<stream:stream") { transport.inject(serverHeader) }
            // …and then nothing: no features ever arrive.
        }
        let stream = try stream(transport)
        try await stream.open()
        await #expect(throws: TransportError(.timedOut)) { _ = try await stream.awaitFeatures() }
    }

    @Test func starttlsProceedTimesOut() async throws {
        let transport = FakeTransport()
        transport.respond = { xml, transport in
            if xml.contains("<stream:stream") {
                transport.inject(serverHeader)
                transport.inject("""
                <stream:features><starttls xmlns='urn:ietf:params:xml:ns:xmpp-tls'/></stream:features>
                """)
            }
            // <starttls/> is never answered.
        }
        let stream = try stream(transport)
        try await stream.open()
        let features = try await stream.awaitFeatures()
        await #expect(throws: TransportError(.timedOut)) {
            _ = try await stream.negotiateTLS(features: features)
        }
    }

    /// A stream that never opened has nothing to close politely; closing must not
    /// wait for a peer that was never there.
    @Test func closingAStreamThatNeverOpenedReturnsImmediately() async throws {
        let transport = SilentTransport()
        let stream = try stream(transport)
        _ = try? await stream.open()
        let started = ContinuousClock.now
        await stream.close(gracePeriod: .seconds(30))
        #expect(started.duration(to: .now) < .seconds(1))
        #expect(transport.didClose)
    }

    @Test func closingAnOpenStreamDoesNotWaitOutTheGracePeriod() async throws {
        let transport = FakeTransport()
        transport.respond = { xml, transport in
            if xml.contains("<stream:stream") { transport.inject(serverHeader) }
            if xml.contains("</stream:stream>") { transport.inject("</stream:stream>") }
        }
        let stream = try stream(transport)
        try await stream.open()
        let started = ContinuousClock.now
        await stream.close(gracePeriod: .seconds(30))
        #expect(started.duration(to: .now) < .seconds(1))
    }

    @Test func cancellingTheCallerUnblocksAPendingWait() async throws {
        let stream = try stream(FakeTransport(), timeout: .seconds(60))
        let task = Task { try await stream.nextEvent() }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
