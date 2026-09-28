import Foundation

public struct TransportError: Error, Sendable, Equatable, CustomStringConvertible {
    public enum Kind: Sendable, Equatable {
        case notConnected
        case alreadyConnected
        case connectionFailed(String)
        case tlsFailed(String)
        case certificateRejected
        case startTLSUnsupported
        case closedByPeer
        case timedOut
    }
    public let kind: Kind

    public init(_ kind: Kind) { self.kind = kind }
    public var description: String { "transport: \(kind)" }
}

/// A byte pipe to one XMPP server, with the TLS lifecycle XMPP needs.
///
/// Deliberately byte-level: framing and the stream state machine sit above this,
/// so the same state machine drives Direct TLS and STARTTLS unchanged.
public protocol StreamTransport: Sendable {
    /// Bytes from the server, in order. Finishes on a clean close and fails with
    /// a `TransportError` otherwise.
    nonisolated var inbound: AsyncThrowingStream<Data, any Error> { get }

    /// Dials the endpoint, completing TLS first when the endpoint is Direct TLS.
    func connect() async throws

    func send(_ data: Data) async throws

    /// Negotiates TLS on an established plaintext connection, after the server
    /// has answered `<proceed/>`. Throws `.startTLSUnsupported` on transports
    /// that cannot upgrade in place.
    func startTLS() async throws

    func close() async

    /// True once TLS is in effect; PLAIN authentication must check this.
    var isEncrypted: Bool { get async }

    /// RFC 9266 `tls-exporter` material for SCRAM-*-PLUS channel binding, or
    /// `nil` when the transport cannot expose it. Consumed in v1.1.
    func channelBindingExporter() async -> Data?
}

public extension StreamTransport {
    func send(_ string: String) async throws {
        try await send(Data(string.utf8))
    }
}

/// Races an operation against a deadline. A transport that neither connects nor
/// reports a failure must not strand its caller.
func withDeadline<T: Sendable>(
    _ duration: Duration,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: duration)
            throw TransportError(.timedOut)
        }
        defer { group.cancelAll() }
        guard let result = try await group.next() else { throw TransportError(.timedOut) }
        return result
    }
}
