import CryptoKit
import Foundation

/// The HT (hashed token) SASL mechanisms XEP-0484 FAST uses
/// (draft-schmaus-kitten-sasl-ht): the client proves it holds a token the
/// server issued, bound to the TLS channel, in one round trip; the server
/// proves it in return.
///
///   client: authcid NUL HMAC(token, "Initiator" || cb-data)
///   server: HMAC(token, "Responder" || cb-data)   (in `<success/>`)
///
/// Only SHA-256, with `EXPR` (RFC 9266 tls-exporter) or `NONE` binding.
public struct HTMechanism: SASLMechanism {

    public enum Binding: Sendable, Equatable {
        /// `HT-SHA-256-EXPR`: bound to this TLS connection.
        case tlsExporter(Data)
        /// `HT-SHA-256-NONE`: not bound (STARTTLS here, where no exporter is available).
        case none
    }

    public let name: String
    private let username: String
    private let token: Data
    private let bindingData: Data

    public init(username: String, token: String, binding: Binding) {
        self.username = username
        self.token = Data(token.utf8)
        switch binding {
        case .tlsExporter(let data):
            name = "HT-SHA-256-EXPR"
            bindingData = data
        case .none:
            name = "HT-SHA-256-NONE"
            bindingData = Data()
        }
    }

    /// The mechanism names this client can use, strongest first.
    public static func names(exporterAvailable: Bool) -> [String] {
        exporterAvailable ? ["HT-SHA-256-EXPR", "HT-SHA-256-NONE"] : ["HT-SHA-256-NONE"]
    }

    public mutating func start() throws -> Data? {
        Data(username.utf8) + Data([0]) + mac("Initiator")
    }

    public mutating func respond(to challenge: Data) throws -> Data {
        throw SASLError.unexpectedChallenge
    }

    public mutating func finish(additionalData: Data?) throws {
        guard let additionalData else { throw SASLError.serverSignatureMissing }
        guard SCRAMMechanism.constantTimeEqual(additionalData, mac("Responder")) else {
            throw SASLError.serverSignatureMismatch
        }
    }

    private func mac(_ label: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(label.utf8) + bindingData, using: SymmetricKey(data: token)))
    }
}
