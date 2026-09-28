import Foundation
import XMPPTransport
import XMPPCore
import XMPPXML

/// A byte-level fake server: every chunk the client sends is handed to
/// `respond`, which answers by injecting XML. Enough to drive negotiation and
/// the client's routing without a network.
public final class ScriptedTransport: StreamTransport, @unchecked Sendable {
    public let inbound: AsyncThrowingStream<Data, any Error>
    private let continuation: AsyncThrowingStream<Data, any Error>.Continuation
    private let lock = NSLock()
    private var sentChunks: [String] = []
    private var encrypted: Bool
    private let exporter: Data?

    public var respond: (@Sendable (String, ScriptedTransport) -> Void)?
    /// Thrown by `connect()`: a refused or unreachable server.
    public var connectError: (any Error)?
    /// Called when the client closes the connection.
    public var onClose: (@Sendable (ScriptedTransport) -> Void)?

    public init(encrypted: Bool = true, exporter: Data? = nil) {
        self.encrypted = encrypted
        self.exporter = exporter
        (inbound, continuation) = AsyncThrowingStream.makeStream(of: Data.self)
    }

    public var sent: [String] { lock.withLock { sentChunks } }
    public var isEncrypted: Bool { get async { lock.withLock { encrypted } } }

    public func connect() async throws {
        if let connectError { throw connectError }
    }

    public func send(_ data: Data) async throws {
        let xml = String(decoding: data, as: UTF8.self)
        lock.withLock { sentChunks.append(xml) }
        respond?(xml, self)
    }

    public func startTLS() async throws { lock.withLock { encrypted = true } }
    public func close() async {
        continuation.finish()
        onClose?(self)
    }
    public func channelBindingExporter() async -> Data? { exporter }

    public func inject(_ xml: String) { continuation.yield(Data(xml.utf8)) }
    public func endOfStream() { continuation.finish() }
}

public enum Script {
    public static let header = """
    <stream:stream id='s' from='example.com' version='1.0' xmlns='jabber:client' \
    xmlns:stream='http://etherx.jabber.org/streams'>
    """

    public static func features(_ inner: String) -> String {
        "<stream:features>\(inner)</stream:features>"
    }

    public static func mechanisms(_ names: String...) -> String {
        "<mechanisms xmlns='urn:ietf:params:xml:ns:xmpp-sasl'>"
            + names.map { "<mechanism>\($0)</mechanism>" }.joined() + "</mechanisms>"
    }

    public static let bind = "<bind xmlns='urn:ietf:params:xml:ns:xmpp-bind'/>"

    /// The value of attribute `name` in the first tag of `xml`.
    public static func attribute(_ name: String, in xml: String) -> String? {
        guard let start = xml.range(of: "\(name)='") else { return nil }
        let rest = xml[start.upperBound...]
        guard let end = rest.firstIndex(of: "'") else { return nil }
        return String(rest[..<end])
    }

    public static func text(of element: String, in xml: String) -> String? {
        guard let open = xml.range(of: "<\(element)"),
              let gt = xml[open.upperBound...].firstIndex(of: ">"),
              let close = xml.range(of: "</\(element)>") else { return nil }
        return String(xml[xml.index(after: gt)..<close.lowerBound])
    }
}

/// A plausible server: PLAIN over TLS, then bind, then whatever `afterBind`
/// does with each later chunk. PLAIN keeps the script free of SCRAM maths;
/// SCRAM is covered by the RFC vectors and the live tests.
public func plainServer(
    jid: String = "juliet@example.com/abc",
    password: String = "secret",
    extraFeatures: String = "",
    afterBind: (@Sendable (String, ScriptedTransport) -> Void)? = nil
) -> ScriptedTransport {
    let transport = ScriptedTransport()
    transport.respond = { xml, t in
        if xml.hasPrefix("<stream:stream") {
            let authenticated = t.sent.contains { $0.contains("<auth") }
            t.inject(Script.header)
            t.inject(Script.features(authenticated ? Script.bind + extraFeatures : Script.mechanisms("PLAIN")))
        } else if xml.hasPrefix("<auth") {
            let payload = Data(base64Encoded: Script.text(of: "auth", in: xml) ?? "") ?? Data()
            if payload == Data("\0juliet\0\(password)".utf8) {
                t.inject("<success xmlns='urn:ietf:params:xml:ns:xmpp-sasl'/>")
            } else {
                t.inject("<failure xmlns='urn:ietf:params:xml:ns:xmpp-sasl'><not-authorized/></failure>")
            }
        } else if xml.contains("urn:ietf:params:xml:ns:xmpp-bind") {
            let id = Script.attribute("id", in: xml)!
            t.inject("<iq type='result' id='\(id)'><bind xmlns='urn:ietf:params:xml:ns:xmpp-bind'><jid>\(jid)</jid></bind></iq>")
        } else if xml == "</stream:stream>" {
            t.inject("</stream:stream>")
        } else {
            afterBind?(xml, t)
        }
    }
    return transport
}
