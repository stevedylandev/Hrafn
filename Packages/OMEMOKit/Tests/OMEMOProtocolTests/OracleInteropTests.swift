import Foundation
import Testing
import OMEMOCrypto
@testable import OMEMOProtocol
import XMPPCore
import XMPPIM
import XMPPXML

/// Interoperability with other OMEMO implementations, one per version, which
/// proves the parts of the wire formats that XEP-0384 does not spell out
/// (0.3), or that our reading of it got right (2) (see docs/OMEMO.md). Runs
/// when `HRAFN_OMEMO_ORACLE` is a shell command that starts an oracle
/// speaking the JSON-lines protocol below; skipped otherwise.
///
/// The oracle is not in this repository: the only one available is built
/// on copyleft libraries, used as a black box and kept out of the tree
/// (docs/LICENSING.md).
@Suite(.enabled(if: ProcessInfo.processInfo.environment["HRAFN_OMEMO_ORACLE"] != nil))
struct OracleInteropTests {
    let us = try! JID("hrafn@example.org")
    let them = try! JID("oracle@example.net")

    /// Both sides set up, each knowing the other's list and bundle in
    /// `version` only, so that is the version spoken.
    func pair(_ version: OMEMOVersion) async throws -> (Oracle, OMEMOEngine) {
        let oracle = try Oracle()
        let started = try oracle.call(["op": "init", "jid": them.description])
        let pep = FakePEP()
        let theirID = try #require(started["device_id"] as? Int)
        let lists = try #require(started["devicelists"] as? [String: String])
        let bundles = try #require(started["bundles"] as? [String: String])
        pep.setList(try Element(xmlFragment: try #require(lists[version.namespace])), of: them)
        pep.setBundle(try Element(xmlFragment: try #require(bundles[version.namespace])), of: them,
                      deviceID: UInt32(theirID))

        let engine = OMEMOEngine(account: us, store: InMemoryOMEMOStore(), directory: pep.directory(for: us))
        try await engine.setUp()
        let ourID = await engine.deviceID!
        let ourBundle = try await pep.directory(for: them).bundle(of: us, deviceID: ourID, version: version)
        _ = try oracle.call(["op": "put_bundle", "jid": us.description, "device_id": Int(ourID),
                             "xml": ourBundle.element.xmlString])
        _ = try oracle.call(["op": "put_devicelist", "jid": us.description,
                             "xml": DeviceList(deviceIDs: [ourID], version: version).element.xmlString])
        return (oracle, engine)
    }

    /// We start: our X3DH as initiator, our pre-key message, our payload.
    @Test(arguments: OMEMOVersion.allCases)
    func weInitiate(_ version: OMEMOVersion) async throws {
        let (oracle, engine) = try await pair(version)
        let first = try await engine.encrypt("hello from Hrafn", to: [them])
        #expect(first.message.elements.map(\.version) == [version])
        let reply = try oracle.call(["op": "decrypt", "from": us.description, "xml": xml(first.message)])
        #expect(text(reply, version) == "hello from Hrafn", "\(reply)")
        try await converse(oracle, engine, version, rounds: 4)
    }

    /// They start: their pre-key message, our X3DH as responder, and our
    /// signed pre-key's signature checked by them.
    @Test(arguments: OMEMOVersion.allCases)
    func theyInitiate(_ version: OMEMOVersion) async throws {
        let (oracle, engine) = try await pair(version)
        let sent = try oracle.call(["op": "encrypt", "to": us.description, "namespace": version.namespace,
                                    "plaintext": plaintext("hello from the oracle", version)])
        #expect((sent["errors"] as? [String])?.isEmpty == true)
        let encrypted = try encryptedMessage(sent)
        #expect(encrypted.elements.map(\.version) == [version])
        #expect(encrypted.keys.contains { $0.isPreKey })
        let decrypted = try await engine.decrypt(encrypted, from: them, conversations: [us])
        #expect(decrypted.body == "hello from the oracle")
        #expect(decrypted.shouldAcknowledge)

        // Our key transport (empty message) must be readable.
        let ack = try await engine.keyTransport(to: decrypted.session)
        let acked = try oracle.call(["op": "decrypt", "from": us.description, "xml": xml(ack)])
        #expect(acked["error"] == nil, "\(acked)")
        #expect(acked["plaintext"] is NSNull)
        try await converse(oracle, engine, version, rounds: 4)
    }

    /// Several messages in a row each way (chain steps), then replies (DH
    /// ratchet steps), with the oracle's automatic messages read as well.
    func converse(_ oracle: Oracle, _ engine: OMEMOEngine, _ version: OMEMOVersion, rounds: Int) async throws {
        for round in 0..<rounds {
            for n in 0..<3 {
                let text = "hrafn \(round).\(n) ✓"
                let mine = try await engine.encrypt(text, to: [them])
                let reply = try oracle.call(["op": "decrypt", "from": us.description, "xml": xml(mine.message)])
                #expect(self.text(reply, version) == text, "\(reply)")
            }
            for n in 0..<2 {
                let text = "oracle \(round).\(n) ✓"
                let sent = try oracle.call(["op": "encrypt", "to": us.description, "namespace": version.namespace,
                                            "plaintext": plaintext(text, version)])
                #expect(try await engine.decrypt(try encryptedMessage(sent), from: them).body == text)
            }
            for automatic in try oracle.call(["op": "sent"])["messages"] as? [[String: Any]] ?? [] {
                _ = try await engine.decrypt(try encryptedMessage(automatic), from: them)
            }
        }
    }

    /// What the oracle encrypts: the text itself for OMEMO 0.3, an XEP-0420
    /// envelope for OMEMO 2 (the library leaves that to the client).
    func plaintext(_ text: String, _ version: OMEMOVersion) -> String {
        switch version {
        case .legacy: text
        case .v2: SCEEnvelope(content: [Element(name: "body", namespaceURI: Namespaces.client, text: text)],
                              from: them, to: us).element.xmlString
        }
    }

    /// The text the oracle decrypted: the body of our envelope for OMEMO 2.
    func text(_ reply: [String: Any], _ version: OMEMOVersion) -> String? {
        guard let plaintext = reply["plaintext"] as? String else { return nil }
        switch version {
        case .legacy: return plaintext
        case .v2:
            guard let envelope = (try? Element(xmlFragment: plaintext)).flatMap(SCEEnvelope.init(element:)),
                  envelope.from == us, envelope.to == them else { return nil }
            return envelope.body
        }
    }

    func xml(_ message: EncryptedMessage) -> String {
        message.elements[0].element.xmlString
    }
}

/// The oracle process: JSON requests in, JSON replies out, one per line.
final class Oracle: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe(), output = Pipe()
    private var buffer = Data()

    init() throws {
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", ProcessInfo.processInfo.environment["HRAFN_OMEMO_ORACLE"] ?? "false"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    deinit { process.terminate() }

    func call(_ request: [String: Any]) throws -> [String: Any] {
        input.fileHandleForWriting.write(try JSONSerialization.data(withJSONObject: request) + Data([0x0A]))
        while !buffer.contains(0x0A) {
            let chunk = output.fileHandleForReading.availableData
            guard !chunk.isEmpty else { throw OracleError.exited }
            buffer += chunk
        }
        let newline = buffer.firstIndex(of: 0x0A)!
        let line = buffer[buffer.startIndex..<newline]
        buffer = Data(buffer[buffer.index(after: newline)...])
        let reply = try JSONSerialization.jsonObject(with: line) as? [String: Any] ?? [:]
        if let error = reply["error"] as? String, request["op"] as? String != "decrypt" {
            throw OracleError.failed(error)
        }
        return reply
    }

    enum OracleError: Error { case exited, failed(String) }
}

func encryptedMessage(_ reply: [String: Any]) throws -> EncryptedMessage {
    guard let xml = reply["xml"] as? String, let encrypted = EncryptedElement(element: try Element(xmlFragment: xml)) else {
        throw OMEMOCryptoError.malformed
    }
    return EncryptedMessage(encrypted)
}
