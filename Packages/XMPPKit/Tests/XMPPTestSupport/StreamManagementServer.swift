import Foundation
import XMPPTransport

/// A fake server with XEP-0198 and XEP-0352 that outlives its connections, so
/// drops, resumption, expiry and replay can be scripted deterministically.
///
/// One account, PLAIN auth. Every connection comes from `makeTransport()`.
/// Stanzas the client sends are logged in `received` once each time the server
/// "handles" one; stanzas for the client go through `deliver(_:)` and are kept
/// until acknowledged, then resent on resumption, like a real server.
public final class StreamManagementServer: @unchecked Sendable {
    public struct Options: Sendable {
        public var offersStreamManagement = true
        public var offersCSI = true
        public var resumable = true
        /// `max` on `<enabled/>`, in seconds.
        public var maxResumption: Int?
        public var location: String?
        public init() {}
    }

    private let lock = NSLock()
    public var options: Options
    public var password = "secret"

    private var transportsMade: [ScriptedTransport] = []
    private var current: ScriptedTransport?
    private var blackholed: Set<ObjectIdentifier> = []
    private var binds = 0

    // The server's view of the XEP-0198 session, which survives the connection.
    private var sessionID: String?
    private var sessions = 0
    private var enabled = false
    private var handled: UInt32 = 0
    private var unackedToClient: [String] = []
    private var clientAcked: UInt32 = 0
    private var sentToClient: UInt32 = 0

    private var receivedStanzas: [String] = []
    private var receivedNonzas: [String] = []
    private var failuresLeft = 0
    private var swallowLeft = 0
    private var failedIncludesH = true

    public init(options: Options = Options()) {
        self.options = options
    }

    // MARK: Observation

    /// Stanzas handled by the server, in order.
    public var received: [String] { lock.withLock { receivedStanzas } }
    /// SM and CSI elements the client sent, in order.
    public var nonzas: [String] { lock.withLock { receivedNonzas } }
    public var transports: [ScriptedTransport] { lock.withLock { transportsMade } }
    public var isConnected: Bool { lock.withLock { current != nil } }
    public var bindCount: Int { lock.withLock { binds } }

    /// Bodies of the messages handled, in order.
    public var receivedBodies: [String] {
        received.filter { $0.hasPrefix("<message") }.compactMap { Script.text(of: "body", in: $0) }
    }

    // MARK: Control

    /// The next `count` connection attempts are refused.
    public func refuseConnections(_ count: Int) { lock.withLock { failuresLeft = count } }

    /// The next `count` stanzas from the client vanish in transit: not handled,
    /// not counted.
    public func loseNextStanzas(_ count: Int) { lock.withLock { swallowLeft = count } }

    /// Drops the connection abruptly, keeping the session for resumption.
    public func drop() {
        let transport = lock.withLock { () -> ScriptedTransport? in
            defer { current = nil }
            return current
        }
        transport?.endOfStream()
    }

    /// The current connection goes silent both ways but stays open, like a
    /// peer behind a NAT that forgot the mapping.
    public func blackholeCurrentConnection() {
        lock.withLock {
            if let current { blackholed.insert(ObjectIdentifier(current)) }
            current = nil
        }
    }

    /// Forgets the session, as after a server restart or hibernation timeout.
    public func expireSession(reportHandledCount: Bool = true) {
        lock.withLock {
            sessionID = nil
            failedIncludesH = reportHandledCount
        }
    }

    /// Sends a stanza to the client — at once if connected, and in any case
    /// kept until acknowledged.
    public func deliver(_ xml: String) {
        let transport = lock.withLock { () -> ScriptedTransport? in
            if enabled {
                unackedToClient.append(xml)
                sentToClient &+= 1
            }
            return current
        }
        transport?.inject(xml)
    }

    /// Injects raw XML on the current connection, bypassing all bookkeeping.
    public func injectRaw(_ xml: String) {
        lock.withLock { current }?.inject(xml)
    }

    public func requestAck() {
        injectRaw("<r xmlns='urn:xmpp:sm:3'/>")
    }

    // MARK: Connections

    public func makeTransport() -> ScriptedTransport {
        let transport = ScriptedTransport()
        lock.withLock {
            transportsMade.append(transport)
            if failuresLeft > 0 {
                failuresLeft -= 1
                transport.connectError = TransportError(.connectionFailed("refused"))
            }
        }
        transport.respond = { [weak self] xml, t in self?.handle(xml, on: t) }
        transport.onClose = { [weak self] t in
            self?.lock.withLock {
                if self?.current === t { self?.current = nil }
            }
        }
        return transport
    }

    private func handle(_ xml: String, on t: ScriptedTransport) {
        var replies: [String] = []
        lock.withLock {
            guard !blackholed.contains(ObjectIdentifier(t)) else { return }
            replies = respond(to: xml, on: t)
        }
        for reply in replies { t.inject(reply) }
    }

    /// Runs under the lock; returns what to inject.
    private func respond(to xml: String, on t: ScriptedTransport) -> [String] {
        if xml.hasPrefix("<stream:stream") {
            let authenticated = t.sent.contains { $0.hasPrefix("<auth") && $0.contains(authPayload) }
            var features = Script.mechanisms("PLAIN")
            if authenticated {
                features = Script.bind
                if options.offersStreamManagement { features += "<sm xmlns='urn:xmpp:sm:3'/>" }
                if options.offersCSI { features += "<csi xmlns='urn:xmpp:csi:0'/>" }
            }
            return [Script.header, Script.features(features)]
        }
        if xml.hasPrefix("<auth") {
            return [xml.contains(authPayload)
                ? "<success xmlns='urn:ietf:params:xml:ns:xmpp-sasl'/>"
                : "<failure xmlns='urn:ietf:params:xml:ns:xmpp-sasl'><not-authorized/></failure>"]
        }
        if xml.contains("urn:ietf:params:xml:ns:xmpp-bind") {
            // A bind starts a fresh session; the old one is gone.
            binds += 1
            current = t
            sessionID = nil
            enabled = false
            unackedToClient = []
            let id = Script.attribute("id", in: xml)!
            return ["<iq type='result' id='\(id)'><bind xmlns='urn:ietf:params:xml:ns:xmpp-bind'><jid>juliet@example.com/r\(binds)</jid></bind></iq>"]
        }
        if xml.hasPrefix("<enable ") {
            receivedNonzas.append(xml)
            guard options.offersStreamManagement else { return [] }
            sessions += 1
            enabled = true
            handled = 0
            sentToClient = 0
            clientAcked = 0
            unackedToClient = []
            var attributes = ""
            if options.resumable {
                sessionID = "sm\(sessions)"
                attributes += " id='sm\(sessions)' resume='true'"
            }
            if let max = options.maxResumption { attributes += " max='\(max)'" }
            if let location = options.location { attributes += " location='\(location)'" }
            return ["<enabled xmlns='urn:xmpp:sm:3'\(attributes)/>"]
        }
        if xml.hasPrefix("<resume ") {
            receivedNonzas.append(xml)
            guard let previd = Script.attribute("previd", in: xml), previd == sessionID,
                  let h = Script.attribute("h", in: xml).flatMap(UInt32.init) else {
                let hAttribute = failedIncludesH && enabled ? " h='\(handled)'" : ""
                enabled = false
                return ["<failed xmlns='urn:xmpp:sm:3'\(hAttribute)><item-not-found xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/></failed>"]
            }
            acknowledgeClient(h)
            current = t
            return ["<resumed xmlns='urn:xmpp:sm:3' previd='\(previd)' h='\(handled)'/>"] + unackedToClient
        }
        if xml.hasPrefix("<r ") {
            receivedNonzas.append(xml)
            return enabled ? ["<a xmlns='urn:xmpp:sm:3' h='\(handled)'/>"] : []
        }
        if xml.hasPrefix("<a ") {
            receivedNonzas.append(xml)
            if let h = Script.attribute("h", in: xml).flatMap(UInt32.init) { acknowledgeClient(h) }
            return []
        }
        if xml.hasPrefix("<active ") || xml.hasPrefix("<inactive ") || xml.hasPrefix("<error ") {
            receivedNonzas.append(xml)
            return []
        }
        if xml == "</stream:stream>" {
            // A clean close ends the session: nothing to resume.
            sessionID = nil
            enabled = false
            if current === t { current = nil }
            return ["</stream:stream>"]
        }
        if xml.hasPrefix("<message") || xml.hasPrefix("<presence") || xml.hasPrefix("<iq") {
            if swallowLeft > 0 {
                swallowLeft -= 1
                return []
            }
            receivedStanzas.append(xml)
            if enabled { handled &+= 1 }
        }
        return []
    }

    private func acknowledgeClient(_ h: UInt32) {
        let newly = Int(h &- clientAcked)
        guard newly <= unackedToClient.count else { return }
        unackedToClient.removeFirst(newly)
        clientAcked = h
    }

    private var authPayload: String {
        Data("\0juliet\0\(password)".utf8).base64EncodedString()
    }
}
