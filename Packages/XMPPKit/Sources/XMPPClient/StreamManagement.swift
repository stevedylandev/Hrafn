import Foundation
import XMPPCore
import XMPPStream
import XMPPTransport
import XMPPXML

/// XEP-0198 bookkeeping for one account: the counters, the queue of stanzas
/// the server has not acknowledged, and what is needed to resume.
///
/// Pure state — the client decides when to send `<enable/>`, `<r/>` and `<a/>`.
/// Outbound stanzas are counted when they are *queued*, not when written: the
/// outbox is FIFO, so the order is the same, and a stanza still sitting in the
/// outbox when the connection drops is then already in `unacked` for replay.
///
/// Counters wrap at 2^32 (XEP-0198 §4), so all comparisons are on differences.
struct StreamManagement: Sendable {

    enum Phase: Sendable, Equatable {
        case off
        /// `<enable/>` is queued; outbound stanzas count from here.
        case enabling
        /// `<enabled/>` arrived; inbound stanzas count from here.
        case enabled
    }

    enum AckError: Error, Equatable {
        /// The server acknowledged more than was sent (XEP-0198 §4).
        case handledCountTooHigh(h: UInt32, sent: UInt32)
    }

    private(set) var phase = Phase.off
    /// Stanzas queued since `<enable/>`.
    private(set) var outbound: UInt32 = 0
    /// The server's last `h`.
    private(set) var acknowledged: UInt32 = 0
    /// Stanzas handled since `<enabled/>` — our `h`.
    private(set) var inbound: UInt32 = 0
    /// Counted stanzas the server has not acknowledged, oldest first.
    /// Always `outbound - acknowledged` long.
    private(set) var unacked: [Element] = []
    /// An `<r/>` is outstanding; at most one is kept in flight.
    var ackRequested = false

    private(set) var resumptionID: String?
    private(set) var location: String?
    /// How long the server keeps the session after a drop, if it said.
    private(set) var maxResumption: Duration?
    /// When the connection that carried the session was lost.
    private(set) var interruptedAt: ContinuousClock.Instant?

    var isCountingOutbound: Bool { phase != .off }

    static func isStanza(_ element: Element) -> Bool {
        element.namespaceURI == Namespaces.client
            && (element.name == "message" || element.name == "presence" || element.name == "iq")
    }

    // MARK: Enabling

    /// `<enable/>` has been queued.
    mutating func beginEnabling() {
        phase = .enabling
        outbound = 0
        acknowledged = 0
        inbound = 0
        unacked = []
        ackRequested = false
        resumptionID = nil
        location = nil
        maxResumption = nil
        interruptedAt = nil
    }

    /// `<enabled/>` arrived.
    mutating func enabled(_ element: Element) {
        guard phase == .enabling else { return }
        phase = .enabled
        inbound = 0
        if element["resume"] == "true" || element["resume"] == "1" {
            resumptionID = element["id"]
        }
        location = element["location"]
        maxResumption = element["max"].flatMap(Int.init).map { .seconds($0) }
    }

    /// `<failed/>` in answer to `<enable/>`: the stanzas sent meanwhile went out
    /// uncounted, and nothing is kept for them.
    mutating func enableFailed() {
        reset()
    }

    // MARK: Counting

    mutating func recordOutbound(_ element: Element) {
        guard isCountingOutbound else { return }
        outbound &+= 1
        unacked.append(element)
    }

    mutating func recordInbound() {
        guard phase == .enabled else { return }
        inbound &+= 1
    }

    /// `<a h=''/>` (or the `h` of `<resumed/>`): drops what the server has handled.
    mutating func acknowledge(_ h: UInt32) throws(AckError) {
        let newly = h &- acknowledged
        guard newly <= UInt32(unacked.count) else {
            throw .handledCountTooHigh(h: h, sent: outbound)
        }
        unacked.removeFirst(Int(newly))
        acknowledged = h
    }

    // MARK: Interruption and resumption

    mutating func interrupted(at instant: ContinuousClock.Instant = .now) {
        interruptedAt = instant
    }

    /// Whether `<resume/>` is still worth trying: the session was resumable
    /// and, as far as we know, the server has not yet given up on it.
    func resumptionRequest(jid: JID, endpoint: Endpoint?,
                           now: ContinuousClock.Instant = .now) -> ResumptionRequest? {
        guard phase == .enabled, let resumptionID else { return nil }
        if let maxResumption, let interruptedAt, interruptedAt.duration(to: now) > maxResumption {
            return nil
        }
        let preferred = location.flatMap { location in
            endpoint.flatMap { ResumptionRequest.endpoint(forLocation: location, like: $0) }
        }
        return ResumptionRequest(id: resumptionID, jid: jid, handled: inbound, endpoint: preferred)
    }

    /// `<resumed h=''/>`: the stanzas to send again, which are counted afresh
    /// as they are re-queued. A server claiming too much is treated as having
    /// handled nothing — resending risks a duplicate, not a loss.
    mutating func resumed(handled h: UInt32) -> [Element] {
        try? acknowledge(h)
        let replay = unacked
        outbound = acknowledged
        unacked = []
        ackRequested = false
        interruptedAt = nil
        return replay
    }

    /// A fresh session replaced this one: returns the stanzas the old one may
    /// not have delivered (all unacknowledged ones, less those `<failed h=''/>`
    /// says were handled) and forgets everything else.
    mutating func takeUndelivered(handled h: UInt32?) -> [Element] {
        if let h { try? acknowledge(h) }
        let undelivered = unacked
        reset()
        return undelivered
    }

    /// Keeps the unacknowledged stanzas for a fresh session but never resumes
    /// this one.
    mutating func forgetResumption() {
        resumptionID = nil
    }

    /// Starts the counters near the wrap point.
    mutating func setCountersForTesting(outbound: UInt32, acknowledged: UInt32) {
        self.outbound = outbound
        self.acknowledged = acknowledged
    }

    mutating func reset() {
        self = StreamManagement()
    }
}
