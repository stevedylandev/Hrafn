import Foundation
import Network

/// `NWConnection`-backed transport: the Direct TLS path (XEP-0368).
///
/// Network.framework is the right base for XMPP on Apple platforms — it owns
/// path changes, ALPN, and the TLS exporter needed for channel binding — with one
/// gap: TLS can only be configured at connect time, so it cannot perform a
/// STARTTLS upgrade. `StreamTaskTransport` covers that case.
///
/// A serial queue, not an actor: `NWConnection` delivers reads on a queue of our
/// choosing, and yielding straight from that queue keeps inbound bytes in order.
/// Hopping into an actor per read would not.
public final class NetworkTransport: StreamTransport, @unchecked Sendable {

    public let endpoint: Endpoint
    private let policy: TLSPolicy
    private let connectTimeout: Duration
    private let queue: DispatchQueue
    private let lock = NSLock()

    public nonisolated let inbound: AsyncThrowingStream<Data, any Error>
    private let continuation: AsyncThrowingStream<Data, any Error>.Continuation

    private var connection: NWConnection?
    private var connectContinuation: CheckedContinuation<Void, any Error>?
    private var encrypted = false
    private var finished = false

    public init(endpoint: Endpoint, policy: TLSPolicy, connectTimeout: Duration = .seconds(15)) {
        self.endpoint = endpoint
        self.policy = policy
        self.connectTimeout = connectTimeout
        self.queue = DispatchQueue(label: "org.hrafn.xmppkit.nw.\(endpoint.host)")
        (inbound, continuation) = AsyncThrowingStream.makeStream(of: Data.self)
    }

    public var isEncrypted: Bool {
        get async { lock.withLock { encrypted } }
    }

    // MARK: - Connect

    public func connect() async throws {
        let host = NWEndpoint.Host(endpoint.host)
        guard let port = NWEndpoint.Port(rawValue: endpoint.port) else {
            throw TransportError(.connectionFailed("invalid port \(endpoint.port)"))
        }

        let parameters: NWParameters
        switch endpoint.security {
        case .directTLS:
            parameters = NWParameters(tls: makeTLSOptions(), tcp: makeTCPOptions())
            lock.withLock { encrypted = true }
        case .startTLS:
            parameters = NWParameters(tls: nil, tcp: makeTCPOptions())
        }
        // XMPP is a long-lived, mostly idle, latency-sensitive stream.
        parameters.serviceClass = .responsiveData
        parameters.multipathServiceType = .disabled

        let connection = NWConnection(host: host, port: port, using: parameters)
        lock.withLock {
            guard self.connection == nil else { return }
            self.connection = connection
        }

        do {
            try await withDeadline(connectTimeout) {
                try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                        self.lock.withLock { self.connectContinuation = continuation }
                        connection.stateUpdateHandler = { [weak self] state in
                            self?.handle(state: state)
                        }
                        connection.start(queue: self.queue)
                    }
                } onCancel: {
                    Task { await self.close() }
                }
            }
        } catch {
            await close()
            throw error
        }

        receiveNext()
    }

    private func handle(state: NWConnection.State) {
        switch state {
        case .ready:
            resumeConnect(with: .success(()))
        case .waiting(let error):
            // `.waiting` normally means a transient condition (no route yet) that
            // NWConnection will retry. TLS errors arrive here too and are never
            // retried into success: a rejected certificate reports
            // `.waiting(-9808)` and then no further state at all — measured, not
            // assumed — so treat any TLS error here as terminal.
            if case .tls = error { fail(with: Self.failure(for: error)) }
        case .failed(let error):
            fail(with: Self.failure(for: error))
        case .cancelled:
            resumeConnect(with: .failure(TransportError(.notConnected)))
            finish(throwing: nil)
        case .setup, .preparing:
            break
        @unknown default:
            break
        }
    }

    private func fail(with failure: TransportError) {
        let connection = lock.withLock { () -> NWConnection? in
            let existing = self.connection
            self.connection = nil
            return existing
        }
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        resumeConnect(with: .failure(failure))
        finish(throwing: failure)
    }

    private static func failure(for error: NWError) -> TransportError {
        switch category(of: error) {
        case .tls: TransportError(.tlsFailed(error.debugDescription))
        case .certificate: TransportError(.certificateRejected)
        case .other: TransportError(.connectionFailed(error.debugDescription))
        }
    }

    private enum ErrorCategory { case tls, certificate, other }

    private static func category(of error: NWError) -> ErrorCategory {
        guard case .tls(let status) = error else { return .other }
        switch status {
        case errSSLXCertChainInvalid, errSSLBadCert, errSSLHostNameMismatch,
             errSSLCertExpired, errSSLCertNotYetValid, errSSLUnknownRootCert,
             errSSLNoRootCert, errSSLPeerCertRevoked, errSSLPeerCertUnknown:
            return .certificate
        default:
            return .tls
        }
    }

    // MARK: - TLS configuration

    private func makeTCPOptions() -> NWProtocolTCP.Options {
        let options = NWProtocolTCP.Options()
        options.noDelay = true                  // stanzas are small and latency-visible
        options.enableKeepalive = true
        options.keepaliveIdle = 60
        return options
    }

    private func makeTLSOptions() -> NWProtocolTLS.Options {
        let options = NWProtocolTLS.Options()
        let security = options.securityProtocolOptions

        // SNI carries the XMPP domain, not the SRV target: the server needs it to
        // choose the right certificate for a virtual host.
        // As an A-label: SNI is ASCII only (RFC 6066 §3).
        sec_protocol_options_set_tls_server_name(security, CertificateChallenge.aLabel(endpoint.domain))
        sec_protocol_options_set_min_tls_protocol_version(security, policy.minimumVersion)
        for protocolName in policy.applicationProtocols {
            sec_protocol_options_add_tls_application_protocol(security, protocolName)
        }

        let policy = self.policy
        let domain = endpoint.domain
        let host = endpoint.host
        sec_protocol_options_set_verify_block(security, { _, trustRef, complete in
            let trust = sec_trust_copy_ref(trustRef).takeRetainedValue()
            let challenge = CertificateChallenge(domain: domain, host: host, trust: trust)
            complete(policy.evaluate(challenge))
        }, queue)

        return options
    }

    // MARK: - I/O

    private func receiveNext() {
        let connection = lock.withLock { self.connection }
        guard let connection else { return }

        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.continuation.yield(data)
            }
            if let error {
                return self.finish(throwing: TransportError(.connectionFailed(error.debugDescription)))
            }
            if isComplete {
                // The server closed its side of the TCP connection.
                return self.finish(throwing: nil)
            }
            self.receiveNext()
        }
    }

    public func send(_ data: Data) async throws {
        let connection = lock.withLock { self.connection }
        guard let connection else { throw TransportError(.notConnected) }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: TransportError(.connectionFailed(error.debugDescription)))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    public func startTLS() async throws {
        // Network.framework cannot add TLS to a running connection; see
        // docs/TRANSPORT-SPIKE.md for the measurement behind this split.
        throw TransportError(.startTLSUnsupported)
    }

    public func close() async {
        let connection = lock.withLock { () -> NWConnection? in
            let existing = self.connection
            self.connection = nil
            return existing
        }
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        resumeConnect(with: .failure(TransportError(.notConnected)))
        finish(throwing: nil)
    }

    public func channelBindingExporter() async -> Data? {
        let connection = lock.withLock { self.connection }
        guard let connection,
              let metadata = connection.metadata(definition: NWProtocolTLS.definition)
                as? NWProtocolTLS.Metadata else { return nil }
        // RFC 9266 §4.2: tls-exporter is only safe on TLS 1.2 with the extended
        // master secret, which Network.framework does not report. TLS 1.3 only.
        guard sec_protocol_metadata_get_negotiated_tls_protocol_version(
            metadata.securityProtocolMetadata) == .TLSv13 else { return nil }
        // RFC 9266: 32 octets exported under the label "EXPORTER-Channel-Binding"
        // with an empty context value.
        let label = "EXPORTER-Channel-Binding"
        guard let secret = sec_protocol_metadata_create_secret(
            metadata.securityProtocolMetadata, label.utf8.count, label, 32) else { return nil }
        let exported = Data(secret as DispatchData)
        return exported.isEmpty ? nil : exported
    }

    // MARK: - Lifecycle helpers

    private func resumeConnect(with result: Result<Void, any Error>) {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, any Error>? in
            let existing = connectContinuation
            connectContinuation = nil
            return existing
        }
        continuation?.resume(with: result)
    }

    private func finish(throwing error: (any Error)?) {
        let shouldFinish = lock.withLock { () -> Bool in
            guard !finished else { return false }
            finished = true
            return true
        }
        guard shouldFinish else { return }
        continuation.finish(throwing: error)
    }
}
