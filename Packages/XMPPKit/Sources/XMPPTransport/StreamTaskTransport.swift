import Foundation

/// `URLSessionStreamTask`-backed transport: the STARTTLS path (RFC 6120 §5).
///
/// `startSecureConnection()` is the only way to add TLS to an established
/// plaintext connection on Apple platforms without pulling in swift-nio and a
/// second TLS stack. The trade-offs, versus `NetworkTransport`:
///
/// * No ALPN control, so this transport is not used for Direct TLS.
/// * No TLS exporter, so SCRAM-*-PLUS channel binding is unavailable here.
/// * Connection failures surface on the first read rather than from `connect()`,
///   because `URLSessionStreamTask` has no "ready" signal.
///
/// See docs/TRANSPORT-SPIKE.md.
public final class StreamTaskTransport: StreamTransport, @unchecked Sendable {

    public let endpoint: Endpoint
    private let policy: TLSPolicy
    private let lock = NSLock()
    private let delegateQueue: OperationQueue

    public nonisolated let inbound: AsyncThrowingStream<Data, any Error>
    private let continuation: AsyncThrowingStream<Data, any Error>.Continuation

    private var session: URLSession?
    private var task: URLSessionStreamTask?
    private var encrypted = false
    private var finished = false
    private let trustDelegate: TrustDelegate

    public init(endpoint: Endpoint, policy: TLSPolicy) {
        self.endpoint = endpoint
        self.policy = policy
        self.trustDelegate = TrustDelegate(domain: endpoint.domain, host: endpoint.host, policy: policy)
        // Serial: read completions must arrive in the order the reads were issued.
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "org.hrafn.xmppkit.streamtask.\(endpoint.host)"
        self.delegateQueue = queue
        (inbound, continuation) = AsyncThrowingStream.makeStream(of: Data.self)
    }

    public var isEncrypted: Bool {
        get async { lock.withLock { encrypted } }
    }

    public func connect() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.waitsForConnectivity = false
        // RFC 7590 §3.3, as on the Direct TLS path. The STARTTLS handshake
        // otherwise takes whatever URLSession's default floor is.
        configuration.tlsMinimumSupportedProtocolVersion = policy.minimumVersion

        let session = URLSession(configuration: configuration,
                                 delegate: trustDelegate,
                                 delegateQueue: delegateQueue)
        let task = session.streamTask(withHostName: endpoint.host, port: Int(endpoint.port))

        try lock.withLock {
            guard self.task == nil else { throw TransportError(.alreadyConnected) }
            self.session = session
            self.task = task
        }

        task.resume()
        if endpoint.security == .directTLS {
            task.startSecureConnection()
            lock.withLock { encrypted = true }
        }
        readNext()
    }

    public func send(_ data: Data) async throws {
        let task = lock.withLock { self.task }
        guard let task else { throw TransportError(.notConnected) }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            task.write(data, timeout: 30) { error in
                if let error {
                    continuation.resume(throwing: TransportError(.connectionFailed(String(describing: error))))
                } else {
                    continuation.resume()
                }
            }
        }
    }

    /// Upgrades in place. `URLSessionStreamTask` enqueues the handshake behind
    /// pending work and reports nothing on success, so a failure appears as an
    /// error on the next read — which is also when the server's post-TLS stream
    /// header would have arrived.
    public func startTLS() async throws {
        let task = lock.withLock { self.task }
        guard let task else { throw TransportError(.notConnected) }
        guard !(lock.withLock { encrypted }) else { throw TransportError(.tlsFailed("already encrypted")) }
        task.startSecureConnection()
        lock.withLock { encrypted = true }
    }

    public func close() async {
        let (task, session) = lock.withLock { () -> (URLSessionStreamTask?, URLSession?) in
            let pair = (self.task, self.session)
            self.task = nil
            self.session = nil
            return pair
        }
        task?.closeWrite()
        task?.closeRead()
        task?.cancel()
        session?.invalidateAndCancel()
        finish(throwing: nil)
    }

    /// Always `nil`: `URLSessionStreamTask` exposes no TLS exporter. Accounts
    /// that need SCRAM-*-PLUS must reach the server over Direct TLS.
    public func channelBindingExporter() async -> Data? { nil }

    // MARK: - Reads

    private func readNext() {
        let task = lock.withLock { self.task }
        guard let task else { return }

        // timeout 0 means "no timeout": an idle XMPP stream is normal, and
        // liveness is the stream layer's job (XEP-0199 ping, XEP-0198 <r/>).
        task.readData(ofMinLength: 1, maxLength: 64 * 1024, timeout: 0) { [weak self] data, atEOF, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.continuation.yield(data)
            }
            if let error {
                return self.finish(throwing: TransportError(.connectionFailed(String(describing: error))))
            }
            if atEOF {
                return self.finish(throwing: nil)
            }
            self.readNext()
        }
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

/// Applies `TLSPolicy` to the URLSession server-trust challenge.
///
/// URLSession would validate the chain against the host it dialled; XMPP needs it
/// validated against the domain instead, so the default handling is replaced
/// outright rather than deferred to.
private final class TrustDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate,
                                  URLSessionStreamDelegate, @unchecked Sendable {
    private let domain: String
    private let host: String
    private let policy: TLSPolicy

    init(domain: String, host: String, policy: TLSPolicy) {
        self.domain = domain
        self.host = host
        self.policy = policy
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        handle(challenge, completionHandler)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        handle(challenge, completionHandler)
    }

    private func handle(
        _ challenge: URLAuthenticationChallenge,
        _ completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            return completionHandler(.performDefaultHandling, nil)
        }
        let certificateChallenge = CertificateChallenge(domain: domain, host: host, trust: trust)
        if policy.evaluate(certificateChallenge) {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}
