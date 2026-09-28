import Testing
import Foundation
@testable import XMPPClient
@testable import XMPPStream
import XMPPTransport
import XMPPTestSupport
import XMPPCore
import XMPPXML

private let identity = ClientIdentity(name: "Hrafn", node: "https://example.org/hrafn")
private let romeo = try! JID("romeo@example.com")

/// Fast enough for tests; the first retry is immediate anyway.
private let quickReconnect = ReconnectPolicy(initialDelay: .milliseconds(20), maximumDelay: .milliseconds(80))

private func makeClient(
    _ server: StreamManagementServer,
    reconnect: ReconnectPolicy? = quickReconnect,
    liveness: LivenessPolicy? = nil,
    pathMonitor: (any NetworkPathMonitor)? = nil
) throws -> XMPPClient {
    let endpoint = Endpoint(host: "example.com", port: 5223, security: .directTLS, domain: "example.com")
    let configuration = SessionConfiguration(
        credentials: try Credentials(jid: try JID("juliet@example.com"), password: "secret"),
        tlsPolicy: .insecureAcceptAll,
        endpoints: [endpoint],
        negotiationTimeout: .seconds(2))
    let negotiator = SessionNegotiator(configuration: configuration) { endpoint, configuration in
        XMLStream(endpoint: endpoint, domain: configuration.credentials.jid.domain,
                  policy: configuration.tlsPolicy, transport: server.makeTransport(),
                  negotiationTimeout: configuration.negotiationTimeout)
    }
    return XMPPClient(configuration: configuration, identity: identity, negotiator: negotiator,
                      resilience: ResilienceOptions(reconnect: reconnect, liveness: liveness,
                                                    pathMonitor: pathMonitor))
}

/// Polls until `condition` holds, failing the test after `timeout`.
private func eventually(
    _ what: String, timeout: Duration = .seconds(3),
    _ condition: @Sendable () async -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("timed out waiting for: \(what)")
    throw ClientError.timedOut
}

/// Collects a client's events from a background task.
private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [XMPPClient.Event] = []
    private var task: Task<Void, Never>?

    init(_ client: XMPPClient) {
        task = Task { [weak self] in
            for await event in client.events { self?.append(event) }
        }
    }

    deinit { task?.cancel() }

    private func append(_ event: XMPPClient.Event) { lock.withLock { events.append(event) } }

    var all: [XMPPClient.Event] { lock.withLock { events } }

    var messageBodies: [String] {
        all.compactMap { if case .message(let m) = $0 { m.body } else { nil } }
    }

    var establishments: [Bool] {
        all.compactMap { if case .established(_, let resumed) = $0 { resumed } else { nil } }
    }

    var states: [XMPPClient.State] {
        all.compactMap { if case .stateChanged(let s) = $0 { s } else { nil } }
    }

    var finalError: (any Error)?? {
        for event in all.reversed() {
            if case .disconnected(let error) = event { return .some(error) }
        }
        return nil
    }
}

private func message(_ body: String) -> Message {
    Message(to: romeo, body: body)
}

private func inbound(_ body: String) -> String {
    "<message type='chat' from='romeo@example.com/x' id='\(body)'><body>\(body)</body></message>"
}

@Suite struct StreamManagementTests {

    // MARK: Counting and acknowledgement

    @Test func enablesAndAnswersAckRequestsWithTheHandledCount() async throws {
        let server = StreamManagementServer()
        let client = try makeClient(server)
        try await client.connect()
        try await eventually("enabled") { await client.isStreamManagementEnabled }
        #expect(await client.isResumable)

        for body in ["s1", "s2", "s3"] { server.deliver(inbound(body)) }
        server.requestAck()
        try await eventually("<a h='3'/>") { server.nonzas.contains("<a xmlns='urn:xmpp:sm:3' h='3'/>") }
        await client.disconnect()
    }

    @Test func requestsAcksAndForgetsWhatTheServerHandled() async throws {
        let server = StreamManagementServer()
        let client = try makeClient(server)
        try await client.connect()
        try await eventually("enabled") { await client.isStreamManagementEnabled }

        for body in ["m1", "m2", "m3"] { try await client.send(message(body)) }
        try await eventually("all acknowledged") { await client.unacknowledgedCount == 0 }
        #expect(server.receivedBodies == ["m1", "m2", "m3"])
        // One <r/> in flight at a time, not one per stanza.
        #expect(server.nonzas.filter { $0.hasPrefix("<r ") }.count <= 3)
        await client.disconnect()
    }

    @Test func withoutServerSupportNothingIsCounted() async throws {
        var options = StreamManagementServer.Options()
        options.offersStreamManagement = false
        let server = StreamManagementServer(options: options)
        let client = try makeClient(server)
        try await client.connect()
        try await client.send(message("m1"))
        try await eventually("delivered") { server.receivedBodies == ["m1"] }
        #expect(await client.isStreamManagementEnabled == false)
        #expect(await client.unacknowledgedCount == 0)
        #expect(!server.transports[0].sent.contains { $0.hasPrefix("<enable") || $0.hasPrefix("<r ") })
        await client.disconnect()
    }

    // MARK: Resumption

    /// The core exit criterion: a drop loses nothing and repeats nothing, in
    /// either direction.
    @Test func resumesAfterADropWithoutLossOrDuplication() async throws {
        let server = StreamManagementServer()
        let client = try makeClient(server)
        let log = EventLog(client)
        try await client.connect()
        let jid = try #require(await client.jid)
        try await eventually("enabled") { await client.isStreamManagementEnabled }

        // Acknowledged traffic both ways.
        for body in ["m1", "m2", "m3"] { try await client.send(message(body)) }
        for body in ["s1", "s2", "s3"] { server.deliver(inbound(body)) }
        try await eventually("acked") { await client.unacknowledgedCount == 0 }
        try await eventually("received") { log.messageBodies.count == 3 }

        // Two stanzas lost in transit, then the connection dies; the server
        // queues one more meanwhile.
        server.loseNextStanzas(2)
        try await client.send(message("m4"))
        try await client.send(message("m5"))
        try await eventually("m4, m5 sent") {
            server.transports[0].sent.contains { $0.contains("<body>m5</body>") }
        }
        server.drop()
        server.deliver(inbound("s4"))

        try await eventually("resumed") { log.establishments == [false, true] }
        try await eventually("m4, m5 replayed") { server.receivedBodies.count == 5 }
        try await eventually("s4 delivered") { log.messageBodies.count == 4 }
        try await Task.sleep(for: .milliseconds(100))

        #expect(server.receivedBodies == ["m1", "m2", "m3", "m4", "m5"])
        // s1–s3 were never acked with <a/>, only by <resume h='3'/>: the server
        // must not resend them, and did not.
        #expect(log.messageBodies == ["s1", "s2", "s3", "s4"])
        #expect(await client.jid == jid)
        #expect(server.bindCount == 1)
        #expect(server.nonzas.contains { $0.hasPrefix("<resume ") && $0.contains("h='3'") })
        await client.disconnect()
    }

    @Test func holdsStanzasSentWhileReconnecting() async throws {
        let server = StreamManagementServer()
        let client = try makeClient(server, reconnect: ReconnectPolicy(initialDelay: .milliseconds(50),
                                                                         maximumDelay: .milliseconds(50)))
        try await client.connect()
        try await eventually("enabled") { await client.isStreamManagementEnabled }

        server.refuseConnections(3)
        server.drop()
        try await eventually("reconnecting") {
            if case .reconnecting = await client.state { true } else { false }
        }
        try await client.send(message("offline"))

        try await eventually("delivered after resumption") { server.receivedBodies == ["offline"] }
        #expect(server.bindCount == 1)
        await client.disconnect()
    }

    @Test func aPendingIQIsAnsweredAfterResumption() async throws {
        let server = StreamManagementServer()
        let client = try makeClient(server)
        try await client.connect()
        try await eventually("enabled") { await client.isStreamManagementEnabled }

        let reply = Task {
            try await client.send(IQ(type: .get, payload: Element(name: "q", namespaceURI: "urn:example")),
                                  timeout: .seconds(5))
        }
        try await eventually("IQ handled") { server.received.contains { $0.hasPrefix("<iq") } }
        let id = try #require(server.received.first { $0.hasPrefix("<iq") }.flatMap { Script.attribute("id", in: $0) })
        server.drop()
        // The reply is produced while the client is away and queued for it.
        server.deliver("<iq type='result' id='\(id)'><ok xmlns='urn:example'/></iq>")

        let result = try await reply.value
        #expect(result.payload?.name == "ok")
        await client.disconnect()
    }

    // MARK: Resumption failing

    /// After a server restart or a long background: the server forgot the
    /// session, but its `h` still says exactly what to send again.
    @Test func replaysOnlyUndeliveredStanzasWhenResumptionFails() async throws {
        let server = StreamManagementServer()
        let client = try makeClient(server)
        let log = EventLog(client)
        try await client.connect()
        try await eventually("enabled") { await client.isStreamManagementEnabled }

        for body in ["m1", "m2"] { try await client.send(message(body)) }
        try await eventually("acked") { await client.unacknowledgedCount == 0 }

        server.loseNextStanzas(2)
        try await client.send(Presence())
        try await client.send(message("m3"))
        try await eventually("sent") { server.transports[0].sent.contains { $0.contains("<body>m3</body>") } }
        server.expireSession()
        server.drop()

        try await eventually("fresh session") { log.establishments == [false, false] }
        try await eventually("m3 replayed") { server.receivedBodies.count == 3 }
        try await Task.sleep(for: .milliseconds(100))
        #expect(server.receivedBodies == ["m1", "m2", "m3"])
        // The presence was not replayed: a fresh session gets fresh presence.
        #expect(!server.received.contains { $0.hasPrefix("<presence") })
        #expect(server.bindCount == 2)
        #expect(await client.jid == (try JID("juliet@example.com/r2")))
        #expect(await client.isStreamManagementEnabled)
        await client.disconnect()
    }

    @Test func failsPendingIQsAFreshSessionCannotAnswer() async throws {
        let server = StreamManagementServer()
        let client = try makeClient(server)
        try await client.connect()
        try await eventually("enabled") { await client.isStreamManagementEnabled }

        let reply = Task {
            try await client.send(IQ(type: .get, payload: Element(name: "q", namespaceURI: "urn:example")),
                                  timeout: .seconds(5))
        }
        try await eventually("IQ acked") {
            let acked = await client.unacknowledgedCount == 0
            return acked && server.received.contains { $0.hasPrefix("<iq") }
        }
        server.expireSession()
        server.drop()
        await #expect(throws: ClientError.disconnected) { try await reply.value }
        await client.disconnect()
    }

    @Test func aServerOverclaimingItsCountGetsAFreshSession() async throws {
        let server = StreamManagementServer()
        let client = try makeClient(server)
        let log = EventLog(client)
        try await client.connect()
        try await eventually("enabled") { await client.isStreamManagementEnabled }
        server.loseNextStanzas(1)
        try await client.send(message("m1"))
        try await eventually("sent") { server.transports[0].sent.contains { $0.contains("<body>m1</body>") } }

        server.injectRaw("<a xmlns='urn:xmpp:sm:3' h='5'/>")
        try await eventually("fresh session") { log.establishments == [false, false] }
        #expect(server.nonzas.contains { $0.hasPrefix("<error ") && $0.contains("handled-count-too-high") })
        #expect(!server.nonzas.contains { $0.hasPrefix("<resume ") })
        try await eventually("m1 replayed") { server.receivedBodies == ["m1"] }
        await client.disconnect()
    }

    @Test func aCleanDisconnectEndsTheSession() async throws {
        let server = StreamManagementServer()
        let client = try makeClient(server)
        try await client.connect()
        try await eventually("enabled") { await client.isStreamManagementEnabled }
        let log = EventLog(client)
        for body in ["s1", "s2"] { server.deliver(inbound(body)) }
        try await eventually("received") { log.messageBodies.count == 2 }
        await client.disconnect()
        #expect(await client.isResumable == false)
        // The final <a/> tells the server nothing needs re-routing.
        #expect(Array(server.transports[0].sent.suffix(2))
                == ["<a xmlns='urn:xmpp:sm:3' h='2'/>", "</stream:stream>"])

        // A later connect binds afresh rather than resuming.
        try await client.connect()
        #expect(server.bindCount == 2)
        #expect(!server.nonzas.contains { $0.hasPrefix("<resume ") })
        await client.disconnect()
    }
}

@Suite struct ReconnectionTests {

    @Test func backoffGrowsIsCappedAndJittered() {
        let policy = ReconnectPolicy(initialDelay: .seconds(1), maximumDelay: .seconds(30), multiplier: 2)
        #expect(policy.delay(forAttempt: 0) == .zero)
        #expect(policy.delay(forAttempt: 1) { _ in 1 } == .seconds(1))
        #expect(policy.delay(forAttempt: 4) { _ in 1 } == .seconds(8))
        #expect(policy.delay(forAttempt: 50) { _ in 1 } == .seconds(30))
        #expect(policy.delay(forAttempt: 1000) { _ in 1 } == .seconds(30))
        #expect(policy.delay(forAttempt: 4) { $0.lowerBound } == .seconds(4))
        for _ in 0..<100 {
            let delay = policy.delay(forAttempt: 3)
            #expect(delay >= .seconds(2) && delay <= .seconds(4))
        }
    }

    @Test func retriesThroughRefusedConnections() async throws {
        let server = StreamManagementServer()
        let client = try makeClient(server)
        let log = EventLog(client)
        try await client.connect()
        try await eventually("enabled") { await client.isStreamManagementEnabled }

        server.refuseConnections(3)
        server.drop()
        try await eventually("resumed") { log.establishments == [false, true] }
        let attempts = log.states.compactMap { if case .reconnecting(let n) = $0 { n } else { nil } }
        #expect(attempts == [1, 2, 3, 4])
        #expect(log.all.contains { if case .interrupted = $0 { true } else { false } })
        await client.disconnect()
    }

    @Test func startKeepsTryingUntilTheServerAnswers() async throws {
        let server = StreamManagementServer()
        server.refuseConnections(2)
        let client = try makeClient(server)
        await client.start()
        try await eventually("connected") {
            if case .connected = await client.state { true } else { false }
        }
        #expect(server.transports.count == 3)
        await client.disconnect()
    }

    @Test func givesUpWhenTheCredentialsStopWorking() async throws {
        let server = StreamManagementServer()
        let client = try makeClient(server)
        let log = EventLog(client)
        try await client.connect()
        try await eventually("enabled") { await client.isStreamManagementEnabled }

        server.password = "changed"
        server.drop()
        try await eventually("gave up") { log.finalError != nil }
        guard case .authenticationFailed = log.finalError?.flatMap({ $0 as? SessionError }) else {
            Issue.record("unexpected: \(String(describing: log.finalError))")
            return
        }
        #expect(await client.state == .disconnected)
        let attempts = server.transports.count
        try await Task.sleep(for: .milliseconds(200))
        #expect(server.transports.count == attempts, "no retries after a fatal error")
    }

    @Test func disconnectingDuringBackoffStopsRetrying() async throws {
        let server = StreamManagementServer()
        let client = try makeClient(server, reconnect: ReconnectPolicy(initialDelay: .seconds(10)))
        let log = EventLog(client)
        try await client.connect()
        try await eventually("enabled") { await client.isStreamManagementEnabled }

        server.refuseConnections(1)
        server.drop()
        try await eventually("backing off") { await client.state == .reconnecting(attempt: 2) }
        await client.disconnect()
        #expect(await client.state == .disconnected)
        try await eventually("reported") { log.finalError != nil }
        #expect(log.finalError! == nil)
        let attempts = server.transports.count
        try await Task.sleep(for: .milliseconds(100))
        #expect(server.transports.count == attempts)
    }

    @Test func withoutStreamManagementPendingIQsFailAtTheDrop() async throws {
        var options = StreamManagementServer.Options()
        options.offersStreamManagement = false
        let server = StreamManagementServer(options: options)
        let client = try makeClient(server, reconnect: ReconnectPolicy(initialDelay: .seconds(30)))
        try await client.connect()
        let reply = Task {
            try await client.send(IQ(type: .get, payload: Element(name: "q", namespaceURI: "urn:example")),
                                  timeout: .seconds(30))
        }
        try await eventually("IQ sent") { server.received.contains { $0.hasPrefix("<iq") } }
        server.refuseConnections(10)
        server.drop()
        await #expect(throws: ClientError.disconnected) { try await reply.value }
        await #expect(throws: ClientError.notConnected) { try await client.send(message("held?")) }
        await client.disconnect()
    }

    @Test func withoutAPolicyADropIsFinal() async throws {
        let server = StreamManagementServer()
        let client = try makeClient(server, reconnect: nil)
        let log = EventLog(client)
        try await client.connect()
        server.drop()
        try await eventually("disconnected") { log.finalError != nil }
        #expect(await client.state == .disconnected)
        #expect(server.transports.count == 1)
    }
}

/// A path monitor the test drives.
private final class FakePathMonitor: NetworkPathMonitor, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<NetworkPath>.Continuation?

    func paths() -> AsyncStream<NetworkPath> {
        let (stream, continuation) = AsyncStream.makeStream(of: NetworkPath.self)
        lock.withLock { self.continuation = continuation }
        return stream
    }

    func send(_ path: NetworkPath) {
        _ = lock.withLock { continuation }?.yield(path)
    }

    static let wifi = NetworkPath(isSatisfied: true, interfaces: ["en0"])
    static let cellular = NetworkPath(isSatisfied: true, interfaces: ["pdp_ip0"])
    static let offline = NetworkPath(isSatisfied: false)
}

@Suite struct LivenessTests {

    @Test func abandonsASilentConnectionWithoutClosingTheSession() async throws {
        let server = StreamManagementServer()
        let client = try makeClient(server, liveness: LivenessPolicy(idleInterval: .milliseconds(100),
                                                                     timeout: .milliseconds(100)))
        let log = EventLog(client)
        try await client.connect()
        try await eventually("enabled") { await client.isStreamManagementEnabled }

        server.blackholeCurrentConnection()
        try await eventually("stale detected") {
            log.all.contains {
                if case .interrupted(let error) = $0 { (error as? ClientError) == .connectionStale } else { false }
            }
        }
        try await eventually("resumed") { log.establishments == [false, true] }
        // Abandoned, not closed: `</stream:stream>` would have ended the session.
        #expect(!server.transports[0].sent.contains("</stream:stream>"))
        await client.disconnect()
    }

    @Test func probesWithPingWhenStreamManagementIsOff() async throws {
        var options = StreamManagementServer.Options()
        options.offersStreamManagement = false
        let server = StreamManagementServer(options: options)
        let client = try makeClient(server, liveness: LivenessPolicy(idleInterval: .milliseconds(100),
                                                                     timeout: .milliseconds(200)))
        try await client.connect()
        try await eventually("pinged") {
            server.received.contains { $0.contains("urn:xmpp:ping") && $0.contains("to='example.com'") }
        }
        await client.disconnect()
    }

    @Test func waitsForTheNetworkThenRetriesAtOnce() async throws {
        let server = StreamManagementServer()
        let monitor = FakePathMonitor()
        // Backoff long enough that only the returning network can explain a
        // quick reconnect.
        let client = try makeClient(server, reconnect: ReconnectPolicy(initialDelay: .seconds(30)),
                                    pathMonitor: monitor)
        let log = EventLog(client)
        try await client.connect()
        try await eventually("enabled") { await client.isStreamManagementEnabled }
        monitor.send(FakePathMonitor.wifi)

        monitor.send(FakePathMonitor.offline)
        try await Task.sleep(for: .milliseconds(20))
        server.drop()
        try await eventually("waiting") { await client.state == .waitingForNetwork }
        let attempts = server.transports.count
        try await Task.sleep(for: .milliseconds(100))
        #expect(server.transports.count == attempts, "no attempts without a network")

        monitor.send(FakePathMonitor.cellular)
        try await eventually("resumed", timeout: .seconds(2)) { log.establishments == [false, true] }
        await client.disconnect()
    }

    @Test func aNetworkChangeCutsTheBackoffShort() async throws {
        let server = StreamManagementServer()
        let monitor = FakePathMonitor()
        let client = try makeClient(server, reconnect: ReconnectPolicy(initialDelay: .seconds(30)),
                                    pathMonitor: monitor)
        let log = EventLog(client)
        try await client.connect()
        try await eventually("enabled") { await client.isStreamManagementEnabled }
        monitor.send(FakePathMonitor.wifi)

        server.refuseConnections(1)
        server.drop()
        try await eventually("backing off") { await client.state == .reconnecting(attempt: 2) }
        monitor.send(FakePathMonitor.cellular)
        try await eventually("resumed", timeout: .seconds(2)) { log.establishments == [false, true] }
        await client.disconnect()
    }

    @Test func aNetworkChangeWhileConnectedProbesTheConnection() async throws {
        let server = StreamManagementServer()
        let monitor = FakePathMonitor()
        let client = try makeClient(server, pathMonitor: monitor)
        try await client.connect()
        try await eventually("enabled") { await client.isStreamManagementEnabled }
        monitor.send(FakePathMonitor.wifi)
        try await Task.sleep(for: .milliseconds(20))
        #expect(!server.nonzas.contains { $0.hasPrefix("<r ") })

        monitor.send(FakePathMonitor.cellular)
        try await eventually("probed") { server.nonzas.contains { $0.hasPrefix("<r ") } }
        await client.disconnect()
    }
}

@Suite struct ClientStateTests {

    @Test func sendsTheStateWhenOffered() async throws {
        let server = StreamManagementServer()
        let client = try makeClient(server)
        let log = EventLog(client)
        try await client.connect()
        await client.setClientState(.inactive)
        await client.setClientState(.inactive)
        try await eventually("inactive") { server.nonzas.contains("<inactive xmlns='urn:xmpp:csi:0'/>") }
        #expect(server.nonzas.filter { $0.hasPrefix("<inactive") }.count == 1, "only changes are sent")

        // A fresh session starts active; the client says otherwise again.
        try await eventually("enabled") { await client.isStreamManagementEnabled }
        server.expireSession()
        server.drop()
        try await eventually("fresh session") { log.establishments == [false, false] }
        try await eventually("inactive again") {
            server.transports.last!.sent.contains("<inactive xmlns='urn:xmpp:csi:0'/>")
        }

        await client.setClientState(.active)
        try await eventually("active") { server.nonzas.contains("<active xmlns='urn:xmpp:csi:0'/>") }
        await client.disconnect()
    }

    @Test func staysQuietWhenNotOffered() async throws {
        var options = StreamManagementServer.Options()
        options.offersCSI = false
        let server = StreamManagementServer(options: options)
        let client = try makeClient(server)
        try await client.connect()
        await client.setClientState(.inactive)
        await client.setClientState(.active)
        try await Task.sleep(for: .milliseconds(50))
        #expect(!server.nonzas.contains { $0.contains("urn:xmpp:csi:0") })
        await client.disconnect()
    }
}

@Suite struct StreamManagementStateTests {

    private func stanza(_ id: String) -> Element {
        Message(id: id, to: romeo, body: id).element
    }

    private func enabledState(resume: Bool = true) -> StreamManagement {
        var sm = StreamManagement()
        sm.beginEnabling()
        sm.enabled(Element(name: "enabled", namespaceURI: Namespaces.streamManagement,
                           attributes: resume ? ["id": "abc", "resume": "true", "max": "300"] : [:]))
        return sm
    }

    @Test func countsOnlyStanzas() {
        #expect(StreamManagement.isStanza(stanza("a")))
        #expect(!StreamManagement.isStanza(Element(name: "r", namespaceURI: Namespaces.streamManagement)))
        #expect(!StreamManagement.isStanza(Element(name: "message", namespaceURI: "urn:other")))
    }

    @Test func acknowledgementsDropHandledStanzas() throws {
        var sm = enabledState()
        for id in ["1", "2", "3"] { sm.recordOutbound(stanza(id)) }
        try sm.acknowledge(2)
        #expect(sm.unacked.map { $0["id"] } == ["3"])
        try sm.acknowledge(2)
        #expect(sm.unacked.count == 1, "a repeated h is harmless")
        #expect(throws: StreamManagement.AckError.handledCountTooHigh(h: 5, sent: 3)) { try sm.acknowledge(5) }
    }

    /// XEP-0198 §4: counters wrap at 2^32.
    @Test func countersWrap() throws {
        var wrapping = StreamManagement()
        wrapping.beginEnabling()
        wrapping.setCountersForTesting(outbound: .max - 1, acknowledged: .max - 1)
        wrapping.recordOutbound(stanza("a"))
        wrapping.recordOutbound(stanza("b"))
        wrapping.recordOutbound(stanza("c"))
        #expect(wrapping.outbound == 1)
        try wrapping.acknowledge(0)
        #expect(wrapping.unacked.map { $0["id"] } == ["c"])
    }

    @Test func inboundCountsOnlyOnceEnabled() {
        var sm = StreamManagement()
        sm.beginEnabling()
        sm.recordInbound()
        #expect(sm.inbound == 0, "the server counts from <enabled/>, so must we")
        sm.enabled(Element(name: "enabled", namespaceURI: Namespaces.streamManagement))
        sm.recordInbound()
        #expect(sm.inbound == 1)
    }

    @Test func resumptionReplaysTheRest() throws {
        var sm = enabledState()
        for id in ["1", "2", "3"] { sm.recordOutbound(stanza(id)) }
        let jid = try JID("juliet@example.com/r1")
        let request = try #require(sm.resumptionRequest(jid: jid, endpoint: nil))
        #expect(request.id == "abc")
        #expect(request.jid == jid)

        let replay = sm.resumed(handled: 1)
        #expect(replay.map { $0["id"] } == ["2", "3"])
        #expect(sm.unacked.isEmpty)
        // Re-queued, the replay counts from the server's h.
        for element in replay { sm.recordOutbound(element) }
        try sm.acknowledge(3)
        #expect(sm.unacked.isEmpty)
    }

    @Test func noResumptionWithoutAnIDOrAfterTheServerGaveUp() throws {
        let jid = try JID("juliet@example.com/r1")
        #expect(enabledState(resume: false).resumptionRequest(jid: jid, endpoint: nil) == nil)

        var sm = enabledState()
        let dropped = ContinuousClock.now
        sm.interrupted(at: dropped)
        #expect(sm.resumptionRequest(jid: jid, endpoint: nil, now: dropped + .seconds(299)) != nil)
        #expect(sm.resumptionRequest(jid: jid, endpoint: nil, now: dropped + .seconds(301)) == nil)
    }

    @Test func aFreshSessionTakesWhatWasNotHandled() {
        var sm = enabledState()
        for id in ["1", "2", "3"] { sm.recordOutbound(stanza(id)) }
        #expect(sm.takeUndelivered(handled: 2).map { $0["id"] } == ["3"])
        #expect(sm.phase == .off)

        var unknown = enabledState()
        for id in ["1", "2"] { unknown.recordOutbound(stanza(id)) }
        #expect(unknown.takeUndelivered(handled: nil).count == 2)
    }

    @Test func parsesResumptionLocations() {
        let base = Endpoint(host: "xmpp.example.com", port: 5223, security: .directTLS, domain: "example.com")
        #expect(ResumptionRequest.endpoint(forLocation: "node2.example.com:5333", like: base)
                == Endpoint(host: "node2.example.com", port: 5333, security: .directTLS, domain: "example.com"))
        #expect(ResumptionRequest.endpoint(forLocation: "node2.example.com", like: base)?.port == 5223)
        #expect(ResumptionRequest.endpoint(forLocation: "[2001:db8::1]:5222", like: base)?.host == "2001:db8::1")
        #expect(ResumptionRequest.endpoint(forLocation: "[2001:db8::1]", like: base)?.port == 5223)
        #expect(ResumptionRequest.endpoint(forLocation: "2001:db8::1", like: base)?.host == "2001:db8::1")
        #expect(ResumptionRequest.endpoint(forLocation: "host:notaport", like: base) == nil)
        #expect(ResumptionRequest.endpoint(forLocation: "[::1", like: base) == nil)
        #expect(ResumptionRequest.endpoint(forLocation: "", like: base) == nil)
    }
}
