import Testing
import XMPPTestSupport
import Foundation
@testable import XMPPStream
import XMPPCore

/// Drives a mechanism with the RFC's messages and checks every byte we send.
private func run(
    _ hash: SCRAMMechanism.Hash, nonce: String, serverFirst: String,
    expectedClientFinal: String, serverFinal: String
) throws {
    var scram = SCRAMMechanism(hash: hash, username: "user", password: "pencil", nonce: nonce)
    let first = try #require(try scram.start())
    #expect(String(decoding: first, as: UTF8.self) == "n,,n=user,r=\(nonce)")
    let final = try scram.respond(to: Data(serverFirst.utf8))
    #expect(String(decoding: final, as: UTF8.self) == expectedClientFinal)
    try scram.finish(additionalData: Data(serverFinal.utf8))
}

@Suite struct SCRAMTests {

    /// RFC 5802 §5.
    @Test func rfc5802SHA1Vector() throws {
        try run(.sha1,
                nonce: "fyko+d2lbbFgONRv9qkxdawL",
                serverFirst: "r=fyko+d2lbbFgONRv9qkxdawL3rfcNHYJY1ZVvWVs7j,s=QSXCR+Q6sek8bf92,i=4096",
                expectedClientFinal: "c=biws,r=fyko+d2lbbFgONRv9qkxdawL3rfcNHYJY1ZVvWVs7j,p=v0X8v3Bz2T0CJGbJQyF0X+HI4Ts=",
                serverFinal: "v=rmF9pqV8S7suAoZWja4dJRkFsKQ=")
    }

    /// RFC 7677 §3.
    @Test func rfc7677SHA256Vector() throws {
        try run(.sha256,
                nonce: "rOprNGfwEbeRWgbNEkqO",
                serverFirst: "r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096",
                expectedClientFinal: "c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,p=dHzbZapWIk4jUhN+Ute9ytag9zjfMHgsqmmiz7AndVQ=",
                serverFinal: "v=6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4=")
    }

    private static let serverFirst = "r=abcdefSERVER,s=QSXCR+Q6sek8bf92,i=4096"

    private func started(_ binding: SCRAMMechanism.ChannelBinding = .unsupported) throws -> SCRAMMechanism {
        var scram = SCRAMMechanism(hash: .sha256, username: "user", password: "pencil",
                                   binding: binding, nonce: "abcdef")
        _ = try scram.start()
        return scram
    }

    @Test func rejectsAWrongServerSignature() throws {
        var scram = try started()
        _ = try scram.respond(to: Data(Self.serverFirst.utf8))
        #expect(throws: SASLError.serverSignatureMismatch) {
            try scram.finish(additionalData: Data("v=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=".utf8))
        }
    }

    /// A bare `<success/>` must not be accepted: it is what a server that does
    /// not know the password would send.
    @Test func rejectsSuccessWithoutAServerSignature() throws {
        var scram = try started()
        _ = try scram.respond(to: Data(Self.serverFirst.utf8))
        #expect(throws: SASLError.serverSignatureMissing) { try scram.finish(additionalData: nil) }
    }

    @Test func rejectsANonceThatDoesNotExtendOurs() throws {
        var scram = try started()
        #expect(throws: SASLError.nonceMismatch) {
            try scram.respond(to: Data("r=zzzzzzSERVER,s=QSXCR+Q6sek8bf92,i=4096".utf8))
        }
        var echoed = try started()
        #expect(throws: SASLError.nonceMismatch) {
            try echoed.respond(to: Data("r=abcdef,s=QSXCR+Q6sek8bf92,i=4096".utf8))
        }
    }

    @Test(arguments: [1, 4095, 1_000_001])
    func rejectsIterationCountsOutsideTheRange(_ count: Int) throws {
        var scram = try started()
        #expect(throws: SASLError.iterationCountOutOfRange(count)) {
            try scram.respond(to: Data("r=abcdefSERVER,s=QSXCR+Q6sek8bf92,i=\(count)".utf8))
        }
    }

    @Test func rejectsMandatoryExtensions() throws {
        var scram = try started()
        #expect(throws: SASLError.unsupportedExtension) {
            try scram.respond(to: Data("m=ext,r=abcdefSERVER,s=QSXCR+Q6sek8bf92,i=4096".utf8))
        }
    }

    @Test func surfacesServerErrors() throws {
        var scram = try started()
        _ = try scram.respond(to: Data(Self.serverFirst.utf8))
        #expect(throws: SASLError.serverError("invalid-proof")) {
            try scram.finish(additionalData: Data("e=invalid-proof".utf8))
        }
    }

    @Test(arguments: [
        "", "r=abcdefSERVER", "r=abcdefSERVER,s=!!!,i=4096", "r=abcdefSERVER,s=QSXCR+Q6sek8bf92,i=many",
        "garbage", "=,=,=", "r=abcdefSERVER,,i=4096",
    ])
    func rejectsMalformedServerFirst(_ message: String) throws {
        var scram = try started()
        #expect(throws: SASLError.self) { try scram.respond(to: Data(message.utf8)) }
    }

    /// Server-final delivered as a challenge, then an empty `<success/>`.
    @Test func acceptsServerFinalAsAChallenge() throws {
        var scram = SCRAMMechanism(hash: .sha1, username: "user", password: "pencil",
                                   nonce: "fyko+d2lbbFgONRv9qkxdawL")
        _ = try scram.start()
        _ = try scram.respond(to: Data("r=fyko+d2lbbFgONRv9qkxdawL3rfcNHYJY1ZVvWVs7j,s=QSXCR+Q6sek8bf92,i=4096".utf8))
        let empty = try scram.respond(to: Data("v=rmF9pqV8S7suAoZWja4dJRkFsKQ=".utf8))
        #expect(empty.isEmpty)
        try scram.finish(additionalData: nil)
    }

    @Test func escapesTheUsername() {
        #expect(SCRAMMechanism.saslName("a=b,c") == "a=3Db=2Cc")
    }

    @Test func gs2HeaderFollowsTheChannelBindingChoice() throws {
        var y = SCRAMMechanism(hash: .sha1, username: "u", password: "p",
                               binding: .notOfferedByServer, nonce: "abc")
        #expect(String(decoding: try #require(try y.start()), as: UTF8.self) == "y,,n=u,r=abc")
        let yFinal = String(decoding: try y.respond(to: Data("r=abcX,s=QSXCR+Q6sek8bf92,i=4096".utf8)), as: UTF8.self)
        #expect(yFinal.hasPrefix("c=\(Data("y,,".utf8).base64EncodedString()),"))

        let exporter = Data((0..<32).map { UInt8($0) })
        var plus = SCRAMMechanism(hash: .sha256, username: "u", password: "p",
                                  binding: .tlsExporter(exporter), nonce: "abc")
        #expect(plus.name == "SCRAM-SHA-256-PLUS")
        #expect(String(decoding: try #require(try plus.start()), as: UTF8.self) == "p=tls-exporter,,n=u,r=abc")
        let plusFinal = String(decoding: try plus.respond(to: Data("r=abcX,s=QSXCR+Q6sek8bf92,i=4096".utf8)), as: UTF8.self)
        let cbind = (Data("p=tls-exporter,,".utf8) + exporter).base64EncodedString()
        #expect(plusFinal.hasPrefix("c=\(cbind),"))
    }

    @Test func noncesAreFreshAndCommaFree() {
        let nonces = (0..<50).map { _ in SCRAMMechanism.makeNonce() }
        #expect(Set(nonces).count == 50)
        #expect(nonces.allSatisfy { !$0.contains(",") && $0.count >= 24 })
    }

    /// Random server messages must be refused with an error, never a crash.
    @Test func fuzzedServerMessagesNeverCrash() throws {
        var generator = Fuzz.generator()
        let alphabet = Array("abcdefrsivme=,+/0123456789!".utf8)
        for _ in 0..<Fuzz.iterations(2000) {
            var scram = try started()
            let length = Int.random(in: 0..<60, using: &generator)
            var bytes = (0..<length).map { _ in alphabet.randomElement(using: &generator)! }
            if Bool.random(using: &generator) { bytes = Array("r=abcdef".utf8) + bytes }
            _ = try? scram.respond(to: Data(bytes))
            _ = try? scram.finish(additionalData: Data(bytes))
        }
    }

    @Test func plainEncodesWithAnEmptyAuthzid() throws {
        var plain = PlainMechanism(username: "juliet", password: "r0m30")
        #expect(try plain.start() == Data("\0juliet\0r0m30".utf8))
        #expect(throws: SASLError.unexpectedChallenge) { try plain.respond(to: Data()) }
    }
}

@Suite struct MechanismSelectorTests {
    private let credentials = try! Credentials(jid: try! JID("juliet@example.com"), password: "secret")

    private func pick(_ offered: [String], types: Set<String> = [], exporter: Data? = nil,
                      encrypted: Bool = true, allowPlain: Bool = true) -> String? {
        MechanismSelector.select(offered: offered, channelBindingTypes: types, exporter: exporter,
                                 isEncrypted: encrypted, allowPlain: allowPlain,
                                 credentials: credentials)?.name
    }

    @Test func prefersSHA256() {
        #expect(pick(["PLAIN", "SCRAM-SHA-1", "SCRAM-SHA-256"]) == "SCRAM-SHA-256")
    }

    @Test func usesPlusOnlyWithAnExporterAndAnAdvertisedType() {
        let offered = ["SCRAM-SHA-1", "SCRAM-SHA-1-PLUS"]
        #expect(pick(offered, types: ["tls-exporter"], exporter: Data(count: 32)) == "SCRAM-SHA-1-PLUS")
        #expect(pick(offered, types: ["tls-server-end-point"], exporter: Data(count: 32)) == "SCRAM-SHA-1")
        #expect(pick(offered, types: ["tls-exporter"], exporter: nil) == "SCRAM-SHA-1")
    }

    @Test func plainRequiresTLSAndPermission() {
        #expect(pick(["PLAIN"]) == "PLAIN")
        #expect(pick(["PLAIN"], encrypted: false) == nil)
        #expect(pick(["PLAIN"], allowPlain: false) == nil)
    }

    @Test func ignoresUnknownMechanisms() {
        #expect(pick(["X-OAUTH2", "OAUTHBEARER", "DIGEST-MD5"]) == nil)
    }

    @Test func accountJIDMustHaveALocalpart() {
        #expect(throws: SessionError.invalidAccountJID) {
            try Credentials(jid: try JID("example.com"), password: "x")
        }
    }
}
