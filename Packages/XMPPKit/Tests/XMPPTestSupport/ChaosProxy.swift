import Foundation
import Network

/// A TCP proxy in front of a live server that can break the link on demand:
/// `sever()` resets every connection (a network flap), `blackhole()` keeps them
/// open but silently discards traffic both ways (a NAT that forgot the mapping,
/// or a phone that walked out of Wi-Fi range).
///
/// Byte-level, so TLS runs end to end through it and certificate validation is
/// the real thing.
public final class ChaosProxy: @unchecked Sendable {
    private let listener: NWListener
    private let targetHost: NWEndpoint.Host
    private let targetPort: NWEndpoint.Port
    private let queue = DispatchQueue(label: "hrafn.chaos-proxy")
    private var links: [Link] = []

    public private(set) var port: UInt16 = 0

    public init(targetHost: String, targetPort: UInt16) async throws {
        listener = try NWListener(using: .tcp, on: .any)
        self.targetHost = NWEndpoint.Host(targetHost)
        self.targetPort = NWEndpoint.Port(rawValue: targetPort)!
        listener.newConnectionHandler = { [weak self] inbound in self?.accept(inbound) }

        let listener = self.listener
        port = try await withCheckedThrowingContinuation { continuation in
            let resumed = OnceFlag()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if resumed.set() { continuation.resume(returning: listener.port?.rawValue ?? 0) }
                case .failed(let error):
                    if resumed.set() { continuation.resume(throwing: error) }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    /// Connections made through the proxy so far.
    public var connectionCount: Int { queue.sync { links.count } }

    /// Resets every live connection.
    public func sever() {
        queue.sync { for link in links { link.sever() } }
    }

    /// Existing connections stay open but carry nothing; new ones work.
    public func blackhole() {
        queue.sync { for link in links { link.isBlackholed = true } }
    }

    public func stop() {
        queue.sync {
            for link in links { link.sever() }
            listener.cancel()
        }
    }

    private func accept(_ inbound: NWConnection) {
        let outbound = NWConnection(host: targetHost, port: targetPort, using: .tcp)
        let link = Link(client: inbound, server: outbound)
        links.append(link)
        link.start(on: queue)
    }

    private final class Link: @unchecked Sendable {
        let client: NWConnection
        let server: NWConnection
        /// Touched only on the proxy's queue.
        var isBlackholed = false
        private var isSevered = false

        init(client: NWConnection, server: NWConnection) {
            self.client = client
            self.server = server
        }

        func start(on queue: DispatchQueue) {
            client.start(queue: queue)
            server.start(queue: queue)
            pump(from: client, to: server)
            pump(from: server, to: client)
        }

        func sever() {
            guard !isSevered else { return }
            isSevered = true
            client.forceCancel()
            server.forceCancel()
        }

        private func pump(from source: NWConnection, to destination: NWConnection) {
            source.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
                guard let self, !self.isSevered else { return }
                if let data, !data.isEmpty, !self.isBlackholed {
                    destination.send(content: data, completion: .contentProcessed { _ in })
                }
                if isComplete || error != nil {
                    // A blackholed link swallows closes too.
                    if !self.isBlackholed { self.sever() }
                    return
                }
                self.pump(from: source, to: destination)
            }
        }
    }
}

private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    /// True the first time only.
    func set() -> Bool {
        lock.withLock {
            defer { done = true }
            return !done
        }
    }
}
