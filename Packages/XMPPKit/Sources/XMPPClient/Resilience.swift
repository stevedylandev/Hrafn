import Foundation
import XMPPStream
import XMPPTransport

/// Exponential backoff with jitter between reconnection attempts.
public struct ReconnectPolicy: Sendable {
    /// Delay before the second attempt; the first follows a drop immediately,
    /// which is what makes a quick XEP-0198 resume possible.
    public var initialDelay: Duration
    public var maximumDelay: Duration
    public var multiplier: Double
    /// A session that stayed up this long resets the backoff. A server that
    /// accepts and then drops at once is not hammered.
    public var stableAfter: Duration

    public init(initialDelay: Duration = .seconds(1), maximumDelay: Duration = .seconds(300),
                multiplier: Double = 2, stableAfter: Duration = .seconds(60)) {
        self.initialDelay = initialDelay
        self.maximumDelay = maximumDelay
        self.multiplier = multiplier
        self.stableAfter = stableAfter
    }

    /// The wait before attempt `attempt` (0-based): zero for the first, then
    /// exponential and capped, with "equal jitter" — uniformly between half and
    /// all of the ceiling — so a server restart is not met by every client at once.
    public func delay(forAttempt attempt: Int,
                      random: (ClosedRange<Double>) -> Double = { Double.random(in: $0) }) -> Duration {
        guard attempt > 0 else { return .zero }
        let growth = pow(multiplier, Double(min(attempt - 1, 64)))
        let ceiling = min(maximumDelay, initialDelay * growth)
        return ceiling * random(0.5...1.0)
    }
}

/// Stale-connection detection. A TCP connection whose peer vanished (a NAT
/// timeout, a network switch) can stay "open" for a long time; only traffic
/// proves it is alive.
public struct LivenessPolicy: Sendable {
    /// Silence from the server after which it is probed — with `<r/>` when
    /// XEP-0198 is on, otherwise a XEP-0199 ping.
    public var idleInterval: Duration
    /// How long a probe may go unanswered before the connection is abandoned.
    public var timeout: Duration

    public init(idleInterval: Duration = .seconds(90), timeout: Duration = .seconds(20)) {
        self.idleInterval = idleInterval
        self.timeout = timeout
    }
}

/// How the client keeps a session alive on an unreliable network.
public struct ResilienceOptions: Sendable {
    /// Use XEP-0198 when the server offers it.
    public var streamManagement: Bool
    /// Reconnect after an unexpected drop; `nil` to report the drop and stop
    /// (the notification service extension's one-shot sessions).
    public var reconnect: ReconnectPolicy?
    public var liveness: LivenessPolicy?
    /// Pauses reconnection while there is no network, retries at once when it
    /// returns, and checks the connection when the path changes.
    public var pathMonitor: (any NetworkPathMonitor)?

    public init(streamManagement: Bool = true,
                reconnect: ReconnectPolicy? = ReconnectPolicy(),
                liveness: LivenessPolicy? = LivenessPolicy(),
                pathMonitor: (any NetworkPathMonitor)? = SystemPathMonitor()) {
        self.streamManagement = streamManagement
        self.reconnect = reconnect
        self.liveness = liveness
        self.pathMonitor = pathMonitor
    }

    /// Stream management only: no reconnection, no probing, no path monitor.
    public static let oneShot = ResilienceOptions(reconnect: nil, liveness: nil, pathMonitor: nil)
}

/// XEP-0352: whether the user is looking. `inactive` lets the server hold back
/// presence and other chatter until something matters.
public enum ClientState: Sendable, Equatable {
    case active
    case inactive
}

enum Reconnection {
    /// Errors that would recur on every attempt: retrying cannot help and may
    /// get the account locked.
    static func isFatal(_ error: any Error) -> Bool {
        switch error {
        case let error as SessionError:
            return error.isFatal
        case let error as TransportError:
            return error.kind == .certificateRejected
        case let error as XMLStream.Failure:
            guard case .streamError(let condition, _) = error else { return false }
            // `conflict`: another login took our resource; reconnecting would
            // take it back and start a tug of war.
            return ["conflict", "not-authorized", "host-unknown", "policy-violation",
                    "invalid-namespace", "unsupported-version"].contains(condition)
        default:
            return false
        }
    }
}
