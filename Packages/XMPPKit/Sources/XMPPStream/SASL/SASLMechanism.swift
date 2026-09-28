import Foundation

/// One SASL mechanism's client side (RFC 4422), independent of how the
/// exchange is framed — so the same mechanisms serve RFC 6120 SASL now and
/// XEP-0388 SASL2 later.
///
/// Mechanisms are stateful values: `start`, then `respond` per challenge, then
/// `finish` with whatever data arrived on success.
public protocol SASLMechanism: Sendable {
    /// The IANA mechanism name, e.g. `SCRAM-SHA-256-PLUS`.
    var name: String { get }

    /// The initial response for `<auth/>`, or `nil` to send none. An empty
    /// `Data` is an empty initial response, encoded as `=` on the wire.
    mutating func start() throws -> Data?

    mutating func respond(to challenge: Data) throws -> Data

    /// Called with the additional data of `<success/>`. Mechanisms with mutual
    /// authentication must throw here if the server did not prove itself —
    /// otherwise a fake server could simply answer `<success/>`.
    mutating func finish(additionalData: Data?) throws
}

public enum SASLError: Error, Sendable, Equatable, CustomStringConvertible {
    case malformedServerMessage(String)
    /// The server sent a mandatory extension (`m=`) we do not implement.
    case unsupportedExtension
    /// The server nonce does not extend ours: a replay or a broken server.
    case nonceMismatch
    case iterationCountOutOfRange(Int)
    /// SCRAM `e=` from the server.
    case serverError(String)
    case serverSignatureMismatch
    /// `<success/>` without the server's proof.
    case serverSignatureMissing
    case unexpectedChallenge

    public var description: String {
        switch self {
        case .malformedServerMessage(let detail): "malformed server message: \(detail)"
        case .unsupportedExtension: "server requires an unsupported SCRAM extension"
        case .nonceMismatch: "server nonce does not extend the client nonce"
        case .iterationCountOutOfRange(let count): "iteration count \(count) out of range"
        case .serverError(let value): "server error: \(value)"
        case .serverSignatureMismatch: "server signature mismatch"
        case .serverSignatureMissing: "server did not prove its identity"
        case .unexpectedChallenge: "unexpected challenge"
        }
    }
}

/// RFC 4616 PLAIN. Sends the password itself, so the negotiator only offers it
/// over TLS, and only when nothing better is available.
public struct PlainMechanism: SASLMechanism {
    public let name = "PLAIN"
    private let username: String
    private let password: String

    public init(username: String, password: String) {
        self.username = username
        self.password = password
    }

    public mutating func start() throws -> Data? {
        // authzid is empty: we always act as ourselves.
        Data([0]) + Data(username.utf8) + Data([0]) + Data(password.utf8)
    }

    public mutating func respond(to challenge: Data) throws -> Data {
        throw SASLError.unexpectedChallenge
    }

    public mutating func finish(additionalData: Data?) throws {}
}
