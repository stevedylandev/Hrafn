import Foundation
import XMPPCore
import XMPPStream
import XMPPTransport
import XMPPXML

public enum ClientError: Error, Sendable, Equatable {
    case notConnected
    case alreadyConnected
    /// No reply arrived within the IQ's timeout.
    case timedOut
    /// The connection ended while the request was outstanding.
    case disconnected
    /// The server stopped answering probes; the connection was abandoned.
    case connectionStale
    /// The server acknowledged more stanzas than were sent (XEP-0198 §4).
    case handledCountTooHigh
}

/// How this client describes itself in XEP-0030 and XEP-0115.
public struct ClientIdentity: Sendable {
    public var name: String
    /// XEP-0030 registry: `phone` for iPhone, `handheld`/`pc` elsewhere.
    public var type: String
    /// XEP-0115 node: a URI identifying the software, not this installation.
    public var node: String

    public init(name: String, type: String = "phone", node: String) {
        self.name = name
        self.type = type
        self.node = node
    }
}

/// Answers an IQ get/set. Return the result payload (or `nil` for an empty
/// result); throw a `StanzaError` to answer with that error.
public typealias IQHandler = @Sendable (IQ) async throws -> Element?

/// Sees each inbound message before it reaches `events`, in stream order.
/// Return `true` to claim it — it then counts as handled and is not delivered.
/// Runs on the client actor: keep it synchronous and quick.
public typealias MessageInterceptor = @Sendable (Message) -> Bool

/// Sees each inbound presence before it reaches `events`, in stream order;
/// the same contract as `MessageInterceptor`.
public typealias PresenceInterceptor = @Sendable (Presence) -> Bool

/// One account's connection: session establishment, the serial writer, the IQ
/// tracker, routing of inbound stanzas, and keeping the session alive.
///
/// Messages and presences are delivered on `events`, in stream order. IQ
/// requests are answered by registered handlers — and with
/// `service-unavailable` when there is none, as RFC 6120 §8.4 requires.
///
/// Resilience (see `ResilienceOptions`): XEP-0198 counts and acknowledges
/// stanzas both ways, so a dropped connection is resumed with nothing lost or
/// repeated; drops are retried with backoff, paused while there is no network;
/// silent connections are probed and abandoned; XEP-0352 tells the server
/// when nobody is looking.
public actor XMPPClient {

    public enum State: Sendable, Equatable {
        case disconnected
        case connecting(SessionNegotiator.Phase)
        case connected(JID)
        /// The session dropped; attempt `attempt` (1-based) is waiting out its backoff.
        case reconnecting(attempt: Int)
        /// The session dropped and there is no network to retry on.
        case waitingForNetwork
    }

    public enum Event: Sendable {
        case stateChanged(State)
        /// A session is up. `resumed`: XEP-0198 continued the previous one, so
        /// presence, room joins and in-flight stanzas carried over. Otherwise it
        /// is fresh: send initial presence and rejoin rooms.
        case established(jid: JID, resumed: Bool)
        case message(Message)
        case presence(Presence)
        /// The connection dropped and the client is reconnecting.
        case interrupted(any Error)
        /// The session ended for good. `nil` after `disconnect()`; otherwise why.
        case disconnected((any Error)?)
    }

    public nonisolated let events: AsyncStream<Event>
    private let eventSink: AsyncStream<Event>.Continuation

    public nonisolated let configuration: SessionConfiguration
    public nonisolated let identity: ClientIdentity
    public nonisolated let resilience: ResilienceOptions
    private let negotiator: SessionNegotiator

    public private(set) var state: State = .disconnected
    private var session: EstablishedSession?
    /// Bumped per installed session, so a stale reader, writer or probe cannot
    /// tear down the session that replaced its own.
    private var generation = 0
    private var outbox: AsyncStream<Element>.Continuation?
    private var writerTask: Task<Void, Never>?
    private var readerTask: Task<Void, Never>?

    private var sm = StreamManagement()
    /// Where the last session was, for resuming it.
    private var lastJID: JID?
    private var lastEndpoint: Endpoint?

    /// Bumped by `disconnect()`: a connection attempt that started before it
    /// must not install its session after it.
    private var epoch = 0
    private var supervisor: Task<Void, Never>?
    private var reconnectAttempt = 0
    private var sessionStartedAt: ContinuousClock.Instant?
    private var wakeWaiter: CheckedContinuation<Void, Never>?

    private var pathTask: Task<Void, Never>?
    private var lastPath: NetworkPath?
    private var pathSatisfied = true

    private var livenessTask: Task<Void, Never>?
    private var probeTask: Task<Void, Never>?
    private var lastInbound = ContinuousClock.now

    private var clientState = ClientState.active

    private struct PendingIQ {
        let continuation: CheckedContinuation<IQ, any Error>
        let request: IQ
        let timeout: Task<Void, Never>
    }
    private var pending: [String: PendingIQ] = [:]

    private struct HandlerKey: Hashable {
        let name: String
        let namespace: String
    }
    private var handlers: [HandlerKey: IQHandler] = [:]
    /// The last request handed to a handler. Each waits for the one before
    /// it, so requests are processed in stream order (RFC 6120 §10.1) — two
    /// roster pushes in quick succession must not apply out of order.
    private var lastHandled: Task<Void, Never>?
    private var extraFeatures: [String] = []
    private var interceptors: [MessageInterceptor] = []
    private var presenceInterceptors: [PresenceInterceptor] = []

    public init(configuration: SessionConfiguration, identity: ClientIdentity,
                resilience: ResilienceOptions = ResilienceOptions()) {
        self.init(configuration: configuration, identity: identity,
                  negotiator: SessionNegotiator(configuration: configuration), resilience: resilience)
    }

    init(configuration: SessionConfiguration, identity: ClientIdentity, negotiator: SessionNegotiator,
         resilience: ResilienceOptions) {
        self.configuration = configuration
        self.identity = identity
        self.negotiator = negotiator
        self.resilience = resilience
        (events, eventSink) = AsyncStream.makeStream(of: Event.self)
    }

    /// The full JID bound for the current session.
    public var jid: JID? { session?.jid }

    /// The SASL mechanism that authenticated the current session.
    public var sessionMechanism: String? { session?.mechanism }

    /// Features of the authenticated stream (XEP-0198, XEP-0352 live here).
    public var streamFeatures: Element? { session?.features }

    /// XEP-0198 is enabled on the current session.
    public var isStreamManagementEnabled: Bool { sm.phase == .enabled }

    /// The current session could be resumed if the connection dropped now.
    public var isResumable: Bool { sm.phase == .enabled && sm.resumptionID != nil }

    /// Stanzas sent but not yet acknowledged by the server.
    public var unacknowledgedCount: Int { sm.unacked.count }

    // MARK: - Lifecycle

    /// Makes one attempt to establish a session, throwing if it fails. Once up,
    /// drops are handled by reconnecting (when `resilience.reconnect` allows).
    public func connect() async throws {
        guard state == .disconnected, supervisor == nil else { throw ClientError.alreadyConnected }
        startPathMonitor()
        do {
            try await establish()
        } catch {
            if session == nil, supervisor == nil { setState(.disconnected) }
            throw error
        }
    }

    /// Connects in the background, retrying with backoff until a session is up
    /// or a failure proves hopeless (reported as `.disconnected(error)`).
    /// Suits an app launch that may be offline.
    public func start() {
        guard state == .disconnected, supervisor == nil else { return }
        startPathMonitor()
        beginReconnecting()
    }

    /// Flushes queued stanzas, then closes the stream politely. This ends the
    /// XEP-0198 session too: nothing is left to resume.
    public func disconnect() async {
        epoch += 1
        supervisor?.cancel()
        supervisor = nil
        wake()
        pathTask?.cancel()
        pathTask = nil
        lastPath = nil
        if session != nil {
            await teardown(error: nil, graceful: true, retry: false)
        } else {
            failPendingIQs()
            sm.reset()
            if state != .disconnected {
                setState(.disconnected)
                eventSink.yield(.disconnected(nil))
            }
        }
    }

    /// One negotiation, resuming the previous session when that is possible.
    private func establish() async throws {
        let epoch = self.epoch
        setState(.connecting(.resolving))
        let resuming = lastJID.flatMap { sm.resumptionRequest(jid: $0, endpoint: lastEndpoint) }
        let sink = eventSink
        let established = try await negotiator.establish(resuming: resuming,
                                                         streamManagement: resilience.streamManagement) { phase in
            sink.yield(.stateChanged(.connecting(phase)))
        }
        // A disconnect() during negotiation wins; honour it.
        guard self.epoch == epoch, !Task.isCancelled else {
            await established.stream.close()
            throw ClientError.disconnected
        }
        install(established)
    }

    private func install(_ established: EstablishedSession) {
        session = established
        generation += 1
        supervisor = nil
        lastJID = established.jid
        lastEndpoint = established.endpoint
        sessionStartedAt = .now
        lastInbound = .now
        startWriter(established.stream)
        startReader(established.stream)
        setState(.connected(established.jid))

        let resumed: Bool
        switch established.resumption {
        case .resumed(let handled):
            resumed = true
            for element in sm.resumed(handled: handled) { enqueue(element) }
            requestAckIfNeeded()
        case .none, .failed:
            resumed = false
            var handled: UInt32?
            if case .failed(let h) = established.resumption { handled = h }
            // Presence is not replayed: the app sends fresh presence for a
            // fresh session, and stale directed presence could rejoin a room.
            let undelivered = sm.takeUndelivered(handled: handled).filter { $0.name != "presence" }
            let replayedIQs = Set(undelivered.compactMap { $0.name == "iq" ? $0["id"] : nil })
            // An IQ the old session delivered cannot be answered on this one.
            failPendingIQs(except: replayedIQs)

            if let enabled = established.streamManagementEnabled {
                // Enabled inside the authentication (Bind 2): counting starts now.
                sm.beginEnabling()
                sm.enabled(enabled)
            } else if resilience.streamManagement,
               established.features.firstChild(name: "sm", namespaceURI: Namespaces.streamManagement) != nil {
                sm.beginEnabling()
                outbox?.yield(Element(name: "enable", namespaceURI: Namespaces.streamManagement,
                                      attributes: ["resume": "true"]))
            }
            for element in undelivered { enqueue(element) }
        }

        // CSI state belongs to a stream; say it again on a fresh one when it
        // is not the default, and always on a resumed one to be sure.
        if resumed || clientState != .active { sendClientState() }
        startLiveness()
        eventSink.yield(.established(jid: established.jid, resumed: resumed))
    }

    private func teardown(error: (any Error)?, graceful: Bool, retry: Bool) async {
        guard let session else { return }
        self.session = nil

        let writer = writerTask
        let reader = readerTask
        writerTask = nil
        readerTask = nil
        livenessTask?.cancel()
        livenessTask = nil
        probeTask?.cancel()
        probeTask = nil
        if graceful, sm.phase == .enabled {
            // XEP-0198 §4: acknowledge before closing. A server that thinks
            // stanzas went unhandled re-routes them — to offline storage, and
            // so back to us a second time on the next login.
            outbox?.yield(Element(name: "a", namespaceURI: Namespaces.streamManagement,
                                  attributes: ["h": String(sm.inbound)]))
        }
        outbox?.finish()
        outbox = nil

        if retry {
            // With XEP-0198, pending IQs and unacknowledged stanzas are kept
            // for the next session: resumed, or replayed on a fresh one.
            // Without it nothing can be replayed, so nothing can be answered.
            if !sm.isCountingOutbound { failPendingIQs() }
            sm.interrupted()
            eventSink.yield(.interrupted(error ?? ClientError.disconnected))
            if let started = sessionStartedAt, let policy = resilience.reconnect,
               started.duration(to: .now) >= policy.stableAfter {
                reconnectAttempt = 0
            }
            beginReconnecting()
        } else {
            failPendingIQs()
            sm.reset()
            setState(.disconnected)
            eventSink.yield(.disconnected(error))
        }

        if graceful { await writer?.value } else { writer?.cancel() }
        reader?.cancel()
        // `close()` takes over the stream's read side from the reader loop.
        if graceful {
            await session.stream.close()
        } else {
            await session.stream.abort()
        }
    }

    private func connectionLost(_ error: any Error, generation: Int) async {
        guard session != nil, generation == self.generation else { return }
        let retry = resilience.reconnect != nil && !Reconnection.isFatal(error)
        await teardown(error: error, graceful: false, retry: retry)
    }

    private func failPendingIQs(except kept: Set<String> = []) {
        for (id, entry) in pending where !kept.contains(id) {
            pending[id] = nil
            entry.timeout.cancel()
            entry.continuation.resume(throwing: ClientError.disconnected)
        }
    }

    private func setState(_ newState: State) {
        state = newState
        eventSink.yield(.stateChanged(newState))
    }

    // MARK: - Reconnection

    private func beginReconnecting() {
        guard supervisor == nil else { return }
        supervisor = Task { [weak self] in await self?.reconnectLoop() }
    }

    private func reconnectLoop() async {
        let epoch = self.epoch
        while !Task.isCancelled, self.epoch == epoch {
            if !pathSatisfied {
                setState(.waitingForNetwork)
                await waitForWake()
                continue
            }
            let delay = resilience.reconnect?.delay(forAttempt: reconnectAttempt) ?? .zero
            setState(.reconnecting(attempt: reconnectAttempt + 1))
            if delay > .zero {
                // A returning network cuts the wait short.
                await sleepUnlessWoken(delay)
                guard !Task.isCancelled, self.epoch == epoch else { return }
                if !pathSatisfied { continue }
            }
            do {
                try await establish()
                return
            } catch {
                guard !Task.isCancelled, self.epoch == epoch else { return }
                if resilience.reconnect == nil || Reconnection.isFatal(error) {
                    supervisor = nil
                    failPendingIQs()
                    sm.reset()
                    setState(.disconnected)
                    eventSink.yield(.disconnected(error))
                    return
                }
                reconnectAttempt += 1
            }
        }
    }

    private func sleepUnlessWoken(_ duration: Duration) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { try? await Task.sleep(for: duration) }
            group.addTask { await self.waitForWake() }
            await group.next()
            group.cancelAll()
        }
    }

    private func waitForWake() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if Task.isCancelled {
                    continuation.resume()
                } else {
                    wakeWaiter?.resume()
                    wakeWaiter = continuation
                }
            }
        } onCancel: {
            Task { await self.wake() }
        }
    }

    private func wake() {
        wakeWaiter?.resume()
        wakeWaiter = nil
    }

    // MARK: - Network path

    private func startPathMonitor() {
        guard pathTask == nil, let monitor = resilience.pathMonitor else { return }
        let paths = monitor.paths()
        pathTask = Task { [weak self] in
            for await path in paths { await self?.pathChanged(path) }
        }
    }

    private func pathChanged(_ path: NetworkPath) {
        let changed = lastPath.map { $0 != path } ?? false
        lastPath = path
        pathSatisfied = path.isSatisfied
        guard path.isSatisfied, changed else { return }
        if supervisor != nil {
            // The network is back, or different: retry now, from the start.
            reconnectAttempt = 0
            wake()
        } else if session != nil {
            // A new interface usually means the old socket is dead but will
            // not say so for minutes.
            checkConnection()
        }
    }

    // MARK: - Liveness

    private func startLiveness() {
        guard let policy = resilience.liveness else { return }
        let generation = self.generation
        livenessTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let idle = await self?.idleTime() else { return }
                if idle < policy.idleInterval {
                    try? await Task.sleep(for: policy.idleInterval - idle)
                    continue
                }
                guard let alive = await self?.probe(timeout: policy.timeout), !Task.isCancelled else { return }
                if !alive {
                    await self?.connectionLost(ClientError.connectionStale, generation: generation)
                    return
                }
            }
        }
    }

    private func idleTime() -> Duration {
        lastInbound.duration(to: .now)
    }

    /// Probes the connection now and abandons it if the server stays silent —
    /// on returning to the foreground, or after a network change, rather than
    /// waiting out the idle interval.
    public func checkConnection(timeout: Duration? = nil) {
        guard session != nil, probeTask == nil else { return }
        let timeout = timeout ?? resilience.liveness?.timeout ?? .seconds(20)
        let generation = self.generation
        probeTask = Task { [weak self] in
            guard let alive = await self?.probe(timeout: timeout), !Task.isCancelled else { return }
            await self?.probeFinished(alive: alive, generation: generation)
        }
    }

    private func probeFinished(alive: Bool, generation: Int) async {
        guard generation == self.generation else { return }
        probeTask = nil
        if !alive { await connectionLost(ClientError.connectionStale, generation: generation) }
    }

    /// Solicits traffic and reports whether any arrived within `timeout`.
    private func probe(timeout: Duration) async -> Bool {
        guard let session, let outbox else { return true }
        let sentAt = ContinuousClock.now
        if sm.phase == .enabled {
            sm.ackRequested = true
            outbox.yield(Element(name: "r", namespaceURI: Namespaces.streamManagement))
        } else {
            let ping = IQ(type: .get, to: session.jid.domain,
                          payload: Element(name: "ping", namespaceURI: Namespaces.ping))
            Task { _ = try? await self.send(ping, timeout: timeout) }
        }
        try? await Task.sleep(for: timeout)
        return lastInbound > sentAt
    }

    // MARK: - Client state (XEP-0352)

    /// Tie to the scene phase: `inactive` in the background, `active` in the
    /// foreground. Becoming active also checks the connection, which the
    /// system may have killed while the app was suspended.
    public func setClientState(_ newState: ClientState) {
        guard newState != clientState else { return }
        clientState = newState
        sendClientState()
        if newState == .active { checkConnection() }
    }

    private func sendClientState() {
        guard let session, let outbox,
              session.features.firstChild(name: "csi", namespaceURI: Namespaces.csi) != nil else { return }
        outbox.yield(Element(name: clientState == .active ? "active" : "inactive", namespaceURI: Namespaces.csi))
    }

    // MARK: - Sending

    /// While a dropped XEP-0198 session is being recovered, stanzas are held
    /// with the unacknowledged ones and go out once it is back.
    private var canAcceptStanzas: Bool {
        outbox != nil || (supervisor != nil && sm.isCountingOutbound)
    }

    /// Queues a stanza on the serial writer.
    public func send(_ element: Element) throws {
        guard canAcceptStanzas else { throw ClientError.notConnected }
        enqueue(element)
    }

    public func send(_ message: Message) throws {
        try send(message.element)
    }

    public func send(_ presence: Presence) throws {
        try send(presence.element)
    }

    /// Sends an IQ get/set and returns its `result`. An `error` reply is thrown
    /// as `StanzaError`.
    public func send(_ request: IQ, timeout: Duration = .seconds(30)) async throws -> IQ {
        precondition(request.type.isRequest, "only get and set IQs expect a reply")
        guard canAcceptStanzas else { throw ClientError.notConnected }
        let id = request.requestID

        let reply = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<IQ, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let timer = Task { [weak self] in
                    try? await Task.sleep(for: timeout)
                    guard !Task.isCancelled else { return }
                    await self?.resolve(id, with: .failure(ClientError.timedOut))
                }
                pending[id] = PendingIQ(continuation: continuation, request: request, timeout: timer)
                enqueue(request.element)
            }
        } onCancel: {
            Task { await self.resolve(id, with: .failure(CancellationError())) }
        }

        if let error = reply.error { throw error }
        return reply
    }

    private func resolve(_ id: String, with result: Result<IQ, any Error>) {
        guard let entry = pending.removeValue(forKey: id) else { return }
        entry.timeout.cancel()
        entry.continuation.resume(with: result)
    }

    /// Counts the stanza for XEP-0198 and hands it to the writer — or, with no
    /// connection, just keeps it with the unacknowledged ones for replay.
    private func enqueue(_ element: Element) {
        let isStanza = StreamManagement.isStanza(element)
        if isStanza { sm.recordOutbound(element) }
        guard let outbox else { return }
        outbox.yield(element)
        if isStanza { requestAckIfNeeded() }
    }

    /// Keeps one `<r/>` in flight while anything is unacknowledged.
    private func requestAckIfNeeded() {
        guard sm.phase == .enabled, !sm.ackRequested, !sm.unacked.isEmpty, let outbox else { return }
        sm.ackRequested = true
        outbox.yield(Element(name: "r", namespaceURI: Namespaces.streamManagement))
    }

    // MARK: - Handlers

    /// Routes IQ get/set requests whose payload is `<name xmlns=namespace/>` to
    /// `handler`, and advertises `namespace` in disco unless told otherwise.
    public func setHandler(name: String, namespace: String, advertise: Bool = true,
                           _ handler: @escaping IQHandler) {
        handlers[HandlerKey(name: name, namespace: namespace)] = handler
        if advertise { addFeature(namespace) }
    }

    /// Lets a module claim messages addressed to it (XEP-0313 results, say)
    /// before they reach `events`.
    public func addMessageInterceptor(_ interceptor: @escaping MessageInterceptor) {
        interceptors.append(interceptor)
    }

    /// Lets a module see (or claim) presences first — a MUC join waiting for
    /// its self-presence, say.
    public func addPresenceInterceptor(_ interceptor: @escaping PresenceInterceptor) {
        presenceInterceptors.append(interceptor)
    }

    /// Advertises a feature in disco#info (and so in the caps hash).
    public func addFeature(_ feature: String) {
        if !extraFeatures.contains(feature) { extraFeatures.append(feature) }
    }

    // MARK: - Writer and reader

    private func startWriter(_ stream: XMLStream) {
        let (queue, continuation) = AsyncStream.makeStream(of: Element.self)
        outbox = continuation
        let generation = self.generation
        writerTask = Task { [weak self] in
            do {
                for await element in queue { try await stream.send(element) }
            } catch {
                await self?.connectionLost(error, generation: generation)
            }
        }
    }

    private func startReader(_ stream: XMLStream) {
        let generation = self.generation
        readerTask = Task { [weak self] in
            do {
                while let event = try await stream.nextEvent() {
                    guard let self else { return }
                    await self.handle(event, generation: generation)
                }
                await self?.connectionLost(XMLStream.Failure.streamClosedByPeer, generation: generation)
            } catch is CancellationError {
                // Superseded by teardown, which already reported why.
            } catch {
                await self?.connectionLost(error, generation: generation)
            }
        }
    }

    // MARK: - Routing

    private func handle(_ event: StreamEvent, generation: Int) async {
        guard generation == self.generation, session != nil else { return }
        switch event {
        case .streamOpen:
            break
        case .streamClose:
            await connectionLost(XMLStream.Failure.streamClosedByPeer, generation: generation)
        case .stanza(let element):
            lastInbound = .now
            if element.matches(name: "error", namespaceURI: Namespaces.stream) {
                await connectionLost(XMLStream.failure(for: element), generation: generation)
                return
            }
            if element.namespaceURI == Namespaces.streamManagement {
                await handleStreamManagement(element, generation: generation)
                return
            }
            if element.matches(name: "features", namespaceURI: Namespaces.stream), session?.usedSASL2 == true {
                // After SASL2 some servers (Prosody) still say what the
                // authenticated stream offers: roster versioning, CSI.
                session?.mergeFeatures(element)
                return
            }
            if let iq = IQ(element) {
                route(iq)
            } else if let message = Message(element) {
                if !interceptors.contains(where: { $0(message) }) { eventSink.yield(.message(message)) }
            } else if let presence = Presence(element) {
                if !presenceInterceptors.contains(where: { $0(presence) }) { eventSink.yield(.presence(presence)) }
            } else {
                return
            }
            // Handled means delivered to its handler or onto `events`.
            sm.recordInbound()
        }
    }

    private func handleStreamManagement(_ element: Element, generation: Int) async {
        switch element.name {
        case "r":
            guard sm.phase == .enabled else { return }
            outbox?.yield(Element(name: "a", namespaceURI: Namespaces.streamManagement,
                                  attributes: ["h": String(sm.inbound)]))
        case "a":
            guard sm.phase == .enabled, let h = element["h"].flatMap(UInt32.init) else { return }
            do {
                try sm.acknowledge(h)
            } catch {
                guard case .handledCountTooHigh(let h, let sent) = error else { return }
                // §4: say why, then start over; a server whose count is wrong
                // cannot be trusted to resume. Unacknowledged stanzas go again.
                var streamError = Element(name: "error", namespaceURI: Namespaces.stream)
                streamError.addChild(Element(name: "undefined-condition", namespaceURI: Namespaces.streamErrors))
                streamError.addChild(Element(name: "handled-count-too-high",
                                             namespaceURI: Namespaces.streamManagement,
                                             attributes: ["h": String(h), "send-count": String(sent)]))
                // Directly, not via the outbox: the teardown below cancels the writer.
                try? await session?.stream.send(streamError)
                sm.forgetResumption()
                await connectionLost(ClientError.handledCountTooHigh, generation: generation)
                return
            }
            sm.ackRequested = false
            requestAckIfNeeded()
        case "enabled":
            sm.enabled(element)
            requestAckIfNeeded()
        case "failed":
            if sm.phase == .enabling { sm.enableFailed() }
        default:
            break
        }
    }

    private func route(_ iq: IQ) {
        switch iq.type {
        case .result, .error:
            guard let entry = pending[iq.requestID] else { return }
            // RFC 6120 §8.2.3 / §10.1: a reply must come from where the request
            // went. Anything else is a forgery, or a late reply to a reused id.
            guard isExpectedResponder(iq.from, for: entry.request) else { return }
            resolve(iq.requestID, with: .success(iq))
        case .get, .set:
            respond(to: iq)
        }
    }

    private func isExpectedResponder(_ from: JID?, for request: IQ) -> Bool {
        guard let account = session?.jid else { return false }
        // A request with no `to` is handled by the server on our behalf, which
        // may answer from nothing, our bare or full JID, or its own domain.
        // One sent to our bare JID is answered the same way, less the domain.
        switch request.to {
        case nil:
            return from == nil || from == account.bare || from == account || from == account.domain
        case account.bare:
            return from == nil || from == account.bare || from == account
        case let to:
            return from == to
        }
    }

    private func respond(to request: IQ) {
        guard let payload = request.payload, request.element.elements.count == 1 else {
            // §8.2.3: a get/set carries exactly one payload.
            try? send(request.makeError(StanzaError(.badRequest)).element)
            return
        }
        guard let namespace = payload.namespaceURI else {
            try? send(request.makeError(StanzaError(.serviceUnavailable)).element)
            return
        }

        let handler = builtInHandler(for: payload, type: request.type)
            ?? handlers[HandlerKey(name: payload.name, namespace: namespace)]
        guard let handler else {
            try? send(request.makeError(StanzaError(.serviceUnavailable)).element)
            return
        }

        let previous = lastHandled
        lastHandled = Task { [weak self] in
            await previous?.value
            let reply: IQ
            do {
                reply = request.makeResult(payload: try await handler(request))
            } catch let error as StanzaError {
                reply = request.makeError(error)
            } catch {
                reply = request.makeError(StanzaError(.internalServerError))
            }
            try? await self?.send(reply.element)
        }
    }

    // MARK: - Built-in responders

    private func builtInHandler(for payload: Element, type: IQ.Kind) -> IQHandler? {
        guard type == .get else { return nil }
        switch (payload.name, payload.namespaceURI) {
        case ("ping", Namespaces.ping):
            // XEP-0199 §4: an empty result.
            return { _ in nil }
        case ("query", Namespaces.discoInfo):
            let info = ownDiscoInfo
            let ownNode = (try? info.capsVerification()).map { "\(identity.node)#\($0)" }
            return { request in
                let node = request.payload?["node"]
                // XEP-0115 §6.2: the caps node is answered with our own info.
                guard node == nil || node == ownNode else { throw StanzaError(.itemNotFound) }
                return info.query(node: node)
            }
        case ("query", Namespaces.discoItems):
            return { request in
                let node = request.payload?["node"]
                guard node == nil else { throw StanzaError(.itemNotFound) }
                return Element(name: "query", namespaceURI: Namespaces.discoItems)
            }
        default:
            return nil
        }
    }

    /// What this client advertises in disco#info.
    public var ownDiscoInfo: DiscoInfo {
        let builtIn = [Namespaces.caps, Namespaces.discoInfo, Namespaces.discoItems, Namespaces.ping]
        return DiscoInfo(
            identities: [.init(category: "client", type: identity.type, name: identity.name)],
            features: builtIn + extraFeatures.filter { !builtIn.contains($0) })
    }

    /// The XEP-0115 `<c/>` element to include in outgoing presence.
    public var capsElement: Element {
        Element(name: "c", namespaceURI: Namespaces.caps, attributes: [
            "hash": "sha-1",
            "node": identity.node,
            "ver": (try? ownDiscoInfo.capsVerification()) ?? "",
        ])
    }

    // MARK: - Queries

    /// XEP-0199 ping. Answers of `service-unavailable` or
    /// `feature-not-implemented` still prove the entity is reachable (§4.2).
    @discardableResult
    public func ping(_ jid: JID? = nil, timeout: Duration = .seconds(30)) async throws -> Duration {
        let started = ContinuousClock.now
        do {
            _ = try await send(IQ(type: .get, to: jid, payload: Element(name: "ping", namespaceURI: Namespaces.ping)),
                               timeout: timeout)
        } catch let error as StanzaError
                    where jid != nil && [.serviceUnavailable, .featureNotImplemented].contains(error.condition) {
        }
        return started.duration(to: .now)
    }

    public func discoInfo(_ jid: JID? = nil, node: String? = nil) async throws -> DiscoInfo {
        var query = Element(name: "query", namespaceURI: Namespaces.discoInfo)
        query["node"] = node
        let reply = try await send(IQ(type: .get, to: jid, payload: query))
        return DiscoInfo(query: reply.payload ?? query)
    }

    public func discoItems(_ jid: JID? = nil, node: String? = nil) async throws -> DiscoItems {
        var query = Element(name: "query", namespaceURI: Namespaces.discoItems)
        query["node"] = node
        let reply = try await send(IQ(type: .get, to: jid, payload: query))
        return DiscoItems(query: reply.payload ?? query)
    }
}
