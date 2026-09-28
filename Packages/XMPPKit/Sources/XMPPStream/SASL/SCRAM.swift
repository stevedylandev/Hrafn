import Foundation
import CryptoKit
import XMPPCore

/// SCRAM (RFC 5802) with SHA-1 and SHA-256 (RFC 7677), optionally with
/// `tls-exporter` channel binding (RFC 9266) as the `-PLUS` variant.
public struct SCRAMMechanism: SASLMechanism {

    public enum Hash: String, Sendable, CaseIterable {
        case sha1 = "SHA-1"
        case sha256 = "SHA-256"
    }

    /// The GS2 channel-binding flag (RFC 5802 §6). Choosing it correctly is what
    /// makes SCRAM resist a downgrade from `-PLUS`.
    public enum ChannelBinding: Sendable, Equatable {
        /// `n`: this client cannot bind to this connection (no exporter).
        case unsupported
        /// `y`: this client could bind, but the server offered no `-PLUS`
        /// mechanism. A server that did offer one will reject this.
        case notOfferedByServer
        /// `p=tls-exporter`: bind to the RFC 9266 exporter value.
        case tlsExporter(Data)
    }

    /// Iteration counts outside this range are refused. RFC 7677 §4 asks for at
    /// least 4096; the ceiling stops a hostile server from pinning the CPU.
    public static let defaultIterationRange = 4096...1_000_000

    public var name: String {
        if case .tlsExporter = binding { "SCRAM-\(hash.rawValue)-PLUS" } else { "SCRAM-\(hash.rawValue)" }
    }

    private let hash: Hash
    private let username: String
    private let password: String
    private let binding: ChannelBinding
    private let clientNonce: String
    private let iterationRange: ClosedRange<Int>

    private enum State: Sendable {
        case initial
        case sentClientFirst(bare: String)
        case sentClientFinal(expectedServerSignature: Data)
        case verified
    }
    private var state: State = .initial

    /// - Parameters:
    ///   - username: the localpart, already PRECIS-prepared by `JID`.
    ///   - nonce: override for test vectors only.
    public init(
        hash: Hash,
        username: String,
        password: String,
        binding: ChannelBinding = .unsupported,
        nonce: String? = nil,
        iterationRange: ClosedRange<Int> = SCRAMMechanism.defaultIterationRange
    ) {
        self.hash = hash
        self.username = username
        self.password = password
        self.binding = binding
        self.clientNonce = nonce ?? Self.makeNonce()
        self.iterationRange = iterationRange
    }

    // MARK: - Exchange

    public mutating func start() throws -> Data? {
        let bare = "n=\(Self.saslName(username)),r=\(clientNonce)"
        state = .sentClientFirst(bare: bare)
        return Data((gs2Header + bare).utf8)
    }

    public mutating func respond(to challenge: Data) throws -> Data {
        switch state {
        case .sentClientFirst(let bare):
            return try clientFinal(serverFirst: challenge, clientFirstBare: bare)
        case .sentClientFinal:
            // Some servers deliver server-final as a challenge and follow with
            // an empty <success/>. Verify it here and answer with nothing.
            try verify(serverFinal: challenge)
            return Data()
        case .initial, .verified:
            throw SASLError.unexpectedChallenge
        }
    }

    public mutating func finish(additionalData: Data?) throws {
        switch state {
        case .verified:
            return
        case .sentClientFinal:
            guard let additionalData, !additionalData.isEmpty else {
                throw SASLError.serverSignatureMissing
            }
            try verify(serverFinal: additionalData)
        case .initial, .sentClientFirst:
            throw SASLError.serverSignatureMissing
        }
    }

    // MARK: - Steps

    private var gs2Header: String {
        switch binding {
        case .unsupported: "n,,"
        case .notOfferedByServer: "y,,"
        case .tlsExporter: "p=tls-exporter,,"
        }
    }

    private var channelBindingData: Data {
        var data = Data(gs2Header.utf8)
        if case .tlsExporter(let exporter) = binding { data += exporter }
        return data
    }

    private mutating func clientFinal(serverFirst: Data, clientFirstBare: String) throws -> Data {
        guard let serverFirstText = String(data: serverFirst, encoding: .utf8) else {
            throw SASLError.malformedServerMessage("server-first is not UTF-8")
        }
        let attributes = try Self.parse(serverFirstText)
        guard let first = attributes.first else {
            throw SASLError.malformedServerMessage("empty server-first")
        }
        if first.key == "m" { throw SASLError.unsupportedExtension }
        if let error = attributes.first(where: { $0.key == "e" }) {
            throw SASLError.serverError(error.value)
        }

        guard let nonce = attributes.value("r"), let saltText = attributes.value("s"),
              let iterationText = attributes.value("i") else {
            throw SASLError.malformedServerMessage("server-first lacks r, s or i")
        }
        guard nonce.hasPrefix(clientNonce), nonce.count > clientNonce.count else {
            throw SASLError.nonceMismatch
        }
        guard let salt = Data(base64Encoded: saltText), !salt.isEmpty else {
            throw SASLError.malformedServerMessage("salt is not base64")
        }
        guard let iterations = Int(iterationText) else {
            throw SASLError.malformedServerMessage("iteration count is not a number")
        }
        guard iterationRange.contains(iterations) else {
            throw SASLError.iterationCountOutOfRange(iterations)
        }

        let withoutProof = "c=\(channelBindingData.base64EncodedString()),r=\(nonce)"
        let authMessage = Data("\(clientFirstBare),\(serverFirstText),\(withoutProof)".utf8)

        let salted = hash.pbkdf2(password: Self.normalize(password), salt: salt, iterations: iterations)
        let clientKey = hash.hmac(key: salted, message: Data("Client Key".utf8))
        let storedKey = hash.digest(clientKey)
        let clientSignature = hash.hmac(key: storedKey, message: authMessage)
        let proof = Data(zip(clientKey, clientSignature).map { $0 ^ $1 })
        let serverKey = hash.hmac(key: salted, message: Data("Server Key".utf8))

        state = .sentClientFinal(expectedServerSignature: hash.hmac(key: serverKey, message: authMessage))
        return Data("\(withoutProof),p=\(proof.base64EncodedString())".utf8)
    }

    private mutating func verify(serverFinal: Data) throws {
        guard case .sentClientFinal(let expected) = state else { throw SASLError.unexpectedChallenge }
        guard let text = String(data: serverFinal, encoding: .utf8) else {
            throw SASLError.malformedServerMessage("server-final is not UTF-8")
        }
        let attributes = try Self.parse(text)
        if let error = attributes.value("e") { throw SASLError.serverError(error) }
        guard let signatureText = attributes.value("v"),
              let signature = Data(base64Encoded: signatureText) else {
            throw SASLError.malformedServerMessage("server-final lacks v")
        }
        guard Self.constantTimeEqual(signature, expected) else {
            throw SASLError.serverSignatureMismatch
        }
        state = .verified
    }

    // MARK: - Helpers

    /// RFC 5802 §5.1: `=` and `,` are escaped in `saslname`.
    static func saslName(_ username: String) -> String {
        username.replacingOccurrences(of: "=", with: "=3D").replacingOccurrences(of: ",", with: "=2C")
    }

    /// Passwords are prepared with the PRECIS OpaqueString profile, which
    /// RFC 8265 defines as the successor to SASLprep. A password the profile
    /// rejects is used as typed: servers that stored it the same way still
    /// accept it, and refusing to try would lock the user out.
    static func normalize(_ password: String) -> Data {
        Data(((try? PRECIS.opaqueString(password)) ?? password).utf8)
    }

    static func makeNonce() -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<24).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return Data(bytes).base64EncodedString()   // no ',' in the base64 alphabet
    }

    /// Splits `k=v,k=v`. Values may contain `=`, so only the first one splits.
    static func parse(_ message: String) throws -> [(key: String, value: String)] {
        try message.split(separator: ",", omittingEmptySubsequences: false).map { part in
            guard part.count >= 2, part.dropFirst().first == "=", let key = part.first else {
                throw SASLError.malformedServerMessage("bad attribute '\(part)'")
            }
            return (String(key), String(part.dropFirst(2)))
        }
    }

    static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

private extension Array where Element == (key: String, value: String) {
    func value(_ key: String) -> String? {
        first { $0.key == key }?.value
    }
}

// MARK: - Primitives

extension SCRAMMechanism.Hash {
    func hmac(key: Data, message: Data) -> Data {
        switch self {
        case .sha1: Self.hmac(Insecure.SHA1.self, key: key, message: message)
        case .sha256: Self.hmac(SHA256.self, key: key, message: message)
        }
    }

    func digest(_ data: Data) -> Data {
        switch self {
        case .sha1: Data(Insecure.SHA1.hash(data: data))
        case .sha256: Data(SHA256.hash(data: data))
        }
    }

    /// RFC 5802's `Hi()`: PBKDF2 with a single output block.
    func pbkdf2(password: Data, salt: Data, iterations: Int) -> Data {
        switch self {
        case .sha1: Self.pbkdf2(Insecure.SHA1.self, password: password, salt: salt, iterations: iterations)
        case .sha256: Self.pbkdf2(SHA256.self, password: password, salt: salt, iterations: iterations)
        }
    }

    private static func hmac<H: HashFunction>(_: H.Type, key: Data, message: Data) -> Data {
        Data(HMAC<H>.authenticationCode(for: message, using: SymmetricKey(data: key)))
    }

    private static func pbkdf2<H: HashFunction>(
        _: H.Type, password: Data, salt: Data, iterations: Int
    ) -> Data {
        let key = SymmetricKey(data: password)
        var block = Array(HMAC<H>.authenticationCode(for: salt + [0, 0, 0, 1], using: key))
        var result = block
        for _ in 1..<iterations {
            block = Array(HMAC<H>.authenticationCode(for: block, using: key))
            for index in result.indices { result[index] ^= block[index] }
        }
        return Data(result)
    }
}
