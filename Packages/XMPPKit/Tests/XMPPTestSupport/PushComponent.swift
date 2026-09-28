import Foundation
import CryptoKit
import Network
import XMPPXML

/// A XEP-0114 external component standing in for the push app server (fpush
/// in a real deployment): it connects to a live server's component port,
/// answers every IQ it is sent with a result — as an app server acknowledges a
/// XEP-0357 publish — and keeps them for the test to inspect.
public final class PushComponent: @unchecked Sendable {

    public enum Failure: Error, Sendable {
        case handshakeRejected(String)
        case timedOut
        case closed
    }

    /// The component's JID, e.g. `push.alpha.test`.
    public let domain: String
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "hrafn.push-component")
    private let parser = StreamParser()
    private let secret: String
    private var received: [Element] = []
    private var ready: CheckedContinuation<Void, any Error>?
    private var failure: (any Error)?

    public init(domain: String, secret: String = "pushsecret", host: String = "127.0.0.1", port: UInt16) {
        self.domain = domain
        self.secret = secret
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
    }

    /// Connects and completes the handshake.
    public func start(timeout: Duration = .seconds(5)) async throws {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.write("<?xml version='1.0'?><stream:stream xmlns='jabber:component:accept' "
                           + "xmlns:stream='http://etherx.jabber.org/streams' to='\(self.domain)'>")
                self.receive()
            case .failed(let error), .waiting(let error):
                self.fail(error)
            default:
                break
            }
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    self.queue.async {
                        if let failure = self.failure { continuation.resume(throwing: failure); return }
                        self.ready = continuation
                        self.connection.start(queue: self.queue)
                    }
                }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw Failure.timedOut
            }
            defer { group.cancelAll() }
            try await group.next()
        }
    }

    public func stop() {
        queue.sync {
            write("</stream:stream>")
            connection.cancel()
        }
    }

    /// Every stanza received so far.
    public var stanzas: [Element] { queue.sync { received } }

    /// Waits for a stanza `match` accepts.
    public func next(timeout: Duration = .seconds(10), where match: @Sendable (Element) -> Bool) async throws -> Element {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let found = stanzas.first(where: match) { return found }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw Failure.timedOut
    }

    // MARK: - Private, on `queue`

    private func write(_ string: String) {
        connection.send(content: Data(string.utf8), completion: .contentProcessed { _ in })
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                do {
                    for event in try self.parser.parse(Array(data)) { self.handle(event) }
                } catch {
                    self.fail(error)
                    return
                }
            }
            if let error { self.fail(error); return }
            if isComplete { self.fail(Failure.closed); return }
            self.receive()
        }
    }

    private func handle(_ event: StreamEvent) {
        switch event {
        case .streamOpen(let open):
            let id = open["id"] ?? ""
            let digest = Insecure.SHA1.hash(data: Data((id + secret).utf8)).map { String(format: "%02x", $0) }.joined()
            write("<handshake>\(digest)</handshake>")
        case .stanza(var stanza):
            if stanza.name == "handshake" {
                ready?.resume()
                ready = nil
                return
            }
            if stanza.name == "error" {
                fail(Failure.handshakeRejected(Serializer.string(for: stanza)))
                return
            }
            // The component namespace plays the part of jabber:client, so the
            // stanza views (`IQ`, `Message`) accept what we keep.
            if stanza.namespaceURI == "jabber:component:accept" { stanza.namespaceURI = "jabber:client" }
            received.append(stanza)
            if stanza.name == "iq", stanza["type"] == "set" || stanza["type"] == "get",
               let id = stanza["id"], let from = stanza["from"] {
                write("<iq type='result' id='\(escape(id))' to='\(escape(from))' from='\(domain)'/>")
            }
        case .streamClose:
            fail(Failure.closed)
        }
    }

    private func fail(_ error: any Error) {
        failure = failure ?? error
        ready?.resume(throwing: error)
        ready = nil
    }

    private func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "'", with: "&apos;")
            .replacingOccurrences(of: "<", with: "&lt;")
    }
}
