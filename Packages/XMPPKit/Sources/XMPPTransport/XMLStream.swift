import Foundation
import XMPPCore
import XMPPXML

/// Chooses the transport implementation for an endpoint.
public enum TransportFactory {
    public static func make(endpoint: Endpoint, policy: TLSPolicy) -> any StreamTransport {
        switch endpoint.security {
        case .directTLS:
            // Network.framework: ALPN and the TLS exporter for channel binding.
            NetworkTransport(endpoint: endpoint, policy: policy)
        case .startTLS:
            // URLSessionStreamTask: the only in-place TLS upgrade available
            // without a second TLS stack.
            StreamTaskTransport(endpoint: endpoint, policy: policy)
        }
    }
}

/// An XML stream over one transport: framing, the TLS upgrade, and the stream
/// restarts those require.
///
/// Stops short of authentication and binding — those are the session state
/// machine's job (Phase 2) and are driven through `nextEvent()` and `send(_:)`.
public actor XMLStream {

    public enum Failure: Error, Sendable, Equatable {
        case notOpen
        case streamClosedByPeer
        /// `<stream:error/>` from the server, with the defining condition.
        case streamError(condition: String, text: String?)
        case unexpectedElement(String)
        case tlsRequiredButNotOffered
        case tlsRefusedByServer
        case timedOut
    }

    public let endpoint: Endpoint
    public let domain: JID

    private let transport: any StreamTransport
    private let console: (any XMLConsole)?
    private let parser: StreamParser
    /// Bounds every wait during negotiation. Once a session is established the
    /// stream is legitimately idle for long stretches and liveness becomes
    /// XEP-0199 ping and XEP-0198 `<r/>`'s job, so this applies to negotiation
    /// only — `nextEvent()` itself never times out.
    private let negotiationTimeout: Duration

    private var pump: Task<Void, Never>?
    private var buffered: [StreamEvent] = []
    private var waiter: CheckedContinuation<StreamEvent?, any Error>?
    private var failure: (any Error)?
    private var isFinished = false
    private var hasOpened = false

    public init(
        endpoint: Endpoint,
        domain: JID,
        policy: TLSPolicy,
        transport: (any StreamTransport)? = nil,
        console: (any XMLConsole)? = nil,
        limits: StreamParser.Limits = StreamParser.Limits(),
        negotiationTimeout: Duration = .seconds(20)
    ) {
        self.endpoint = endpoint
        self.domain = domain
        self.transport = transport ?? TransportFactory.make(endpoint: endpoint, policy: policy)
        self.console = console
        self.parser = StreamParser(limits: limits)
        self.negotiationTimeout = negotiationTimeout
    }

    public var isEncrypted: Bool {
        get async { await transport.isEncrypted }
    }

    // MARK: - Opening

    /// Connects and sends the stream header, returning the server's own header.
    /// With `onlyIfEncrypted`, `from` is sent only when the connection is
    /// already encrypted (Direct TLS): RFC 6120 §4.7.1 keeps the account name
    /// off a plaintext link, and a server may need it to offer XEP-0484 FAST.
    @discardableResult
    public func open(from jid: JID? = nil, onlyIfEncrypted: Bool = false) async throws -> Element {
        try await transport.connect()
        startPump()
        let encrypted = await isEncrypted
        let header = try await sendHeaderAndAwaitResponse(from: onlyIfEncrypted && !encrypted ? nil : jid)
        hasOpened = true
        return header
    }

    /// Reads the next `<stream:features/>`.
    public func awaitFeatures() async throws -> Element {
        while let event = try await nextNegotiationEvent() {
            guard case .stanza(let element) = event else { continue }
            if element.matches(name: "features", namespaceURI: Namespaces.stream) { return element }
            if element.matches(name: "error", namespaceURI: Namespaces.stream) {
                throw Self.failure(for: element)
            }
        }
        throw Failure.streamClosedByPeer
    }

    /// Performs the STARTTLS exchange when the server offers it, then restarts
    /// the stream (RFC 6120 §5.4.3.3: both parties discard everything negotiated
    /// so far, including the stream header).
    ///
    /// Returns the features of the encrypted stream, or `nil` when TLS was not
    /// offered and was not required.
    @discardableResult
    public func negotiateTLS(features: Element, required: Bool = true, from jid: JID? = nil) async throws -> Element? {
        if await transport.isEncrypted { return nil }

        guard let starttls = features.firstChild(name: "starttls", namespaceURI: Namespaces.tls) else {
            if required { throw Failure.tlsRequiredButNotOffered }
            return nil
        }
        let serverRequires = starttls.firstChild(name: "required") != nil
        guard required || serverRequires else { return nil }

        try await send(Element(name: "starttls", namespaceURI: Namespaces.tls))

        guard let event = try await nextNegotiationEvent(), case .stanza(let answer) = event else {
            throw Failure.streamClosedByPeer
        }
        switch answer.name {
        case "proceed" where answer.namespaceURI == Namespaces.tls:
            break
        case "failure" where answer.namespaceURI == Namespaces.tls:
            throw Failure.tlsRefusedByServer
        default:
            throw Failure.unexpectedElement(answer.name)
        }

        try await transport.startTLS()
        return try await restart(from: jid)
    }

    /// Discards parser state and sends a fresh header, as required after TLS and
    /// after SASL.
    ///
    /// `from` should be the account's bare JID once the stream is encrypted
    /// (RFC 6120 §4.7.1), and omitted before, where it would leak in cleartext.
    @discardableResult
    public func restart(from jid: JID? = nil) async throws -> Element {
        parser.reset()
        buffered.removeAll()
        _ = try await sendHeaderAndAwaitResponse(from: jid)
        return try await awaitFeatures()
    }

    private func sendHeaderAndAwaitResponse(from jid: JID?) async throws -> Element {
        let header = Serializer.streamOpen(to: domain.domainpart, from: jid?.description)
        try await sendRaw(header)

        while let event = try await nextNegotiationEvent() {
            switch event {
            case .streamOpen(let element):
                return element
            case .stanza(let element) where element.matches(name: "error", namespaceURI: Namespaces.stream):
                throw Self.failure(for: element)
            case .stanza, .streamClose:
                throw Failure.streamClosedByPeer
            }
        }
        throw Failure.streamClosedByPeer
    }

    // MARK: - Sending

    public func send(_ element: Element) async throws {
        try await sendRaw(Serializer.string(for: element, inheritedNamespace: Namespaces.client))
    }

    public func sendRaw(_ xml: String) async throws {
        console?.log(.sent, xml)
        try await transport.send(Data(xml.utf8))
    }

    /// Sends `</stream:stream>` and waits briefly for the peer to close back, so
    /// the server records a clean logout rather than a dropped connection.
    public func close(gracePeriod: Duration = .milliseconds(500)) async {
        // A stream that never opened — a refused certificate, a failed dial — has
        // nothing to close politely, and the transport is already gone.
        if hasOpened, !isFinished {
            try? await sendRaw(Serializer.streamClose)
            let deadline = ContinuousClock.now.advanced(by: gracePeriod)
            while ContinuousClock.now < deadline, !parser.isClosed {
                guard let event = try? await withDeadline(gracePeriod, { try await self.nextEvent() }) else { break }
                if case .streamClose = event { break }
            }
        }
        await abort()
    }

    /// Drops the connection without `</stream:stream>`. A closing tag ends a
    /// XEP-0198 session for good; a connection abandoned as stale — which may
    /// still be half alive — must leave it resumable.
    public func abort() async {
        pump?.cancel()
        pump = nil
        await transport.close()
        finish(with: nil)
    }

    /// The next top-level element during negotiation (SASL, binding), bounded by
    /// `negotiationTimeout`. A `<stream:error/>` is thrown rather than returned,
    /// and the stream ending is `streamClosedByPeer`.
    public func nextNegotiationElement() async throws -> Element {
        while let event = try await nextNegotiationEvent() {
            switch event {
            case .stanza(let element) where element.matches(name: "error", namespaceURI: Namespaces.stream):
                throw Self.failure(for: element)
            case .stanza(let element):
                return element
            case .streamOpen:
                continue
            case .streamClose:
                throw Failure.streamClosedByPeer
            }
        }
        throw Failure.streamClosedByPeer
    }

    /// RFC 9266 exporter from the underlying transport, for SCRAM-*-PLUS.
    public func channelBindingExporter() async -> Data? {
        await transport.channelBindingExporter()
    }

    // MARK: - Event delivery

    /// `nextEvent()` bounded by `negotiationTimeout`.
    private func nextNegotiationEvent() async throws -> StreamEvent? {
        try await withDeadline(negotiationTimeout) { try await self.nextEvent() }
    }

    /// The next framing event, or `nil` once the stream has ended.
    public func nextEvent() async throws -> StreamEvent? {
        if !buffered.isEmpty { return buffered.removeFirst() }
        if let failure { throw failure }
        if isFinished { return nil }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    // One reader at a time. A second caller — `close()` while a
                    // session's read loop is parked here — takes over, and the
                    // first is released rather than leaked.
                    waiter?.resume(throwing: CancellationError())
                    waiter = continuation
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter() }
        }
    }

    /// Resumes a pending `nextEvent()` on cancellation. A `CheckedContinuation`
    /// is not cancellation-aware by itself, and a timeout built on a task group
    /// cannot complete while a child task is parked on one.
    private func cancelWaiter() {
        guard let waiter else { return }
        self.waiter = nil
        waiter.resume(throwing: CancellationError())
    }

    private func startPump() {
        guard pump == nil else { return }
        let inbound = transport.inbound
        pump = Task { [weak self] in
            do {
                for try await chunk in inbound {
                    guard let self else { return }
                    await self.ingest(chunk)
                }
                await self?.finish(with: nil)
            } catch {
                await self?.finish(with: error)
            }
        }
    }

    private func ingest(_ data: Data) {
        console?.log(.received, String(decoding: data, as: UTF8.self))
        do {
            for event in try parser.parse(data) { deliver(event) }
        } catch {
            finish(with: error)
        }
    }

    private func deliver(_ event: StreamEvent) {
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: event)
        } else {
            buffered.append(event)
        }
    }

    private func finish(with error: (any Error)?) {
        guard !isFinished else { return }
        isFinished = true
        failure = error
        if let waiter {
            self.waiter = nil
            if let error { waiter.resume(throwing: error) } else { waiter.resume(returning: nil) }
        }
    }

    public static func failure(for streamError: Element) -> Failure {
        let condition = streamError.elements
            .first { $0.namespaceURI == Namespaces.streamErrors && $0.name != "text" }?.name
            ?? "undefined-condition"
        let text = streamError.firstChild(name: "text", namespaceURI: Namespaces.streamErrors)?.text
        return .streamError(condition: condition, text: text)
    }
}
