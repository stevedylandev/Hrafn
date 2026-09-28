import Clibsodium
import CryptoKit
import Foundation
import Testing
@testable import OMEMOCrypto

/// OMEMO 2 over the same ratchet core: sessions from the Ed25519 bundle, the
/// OMEMO 2 wire format, and the payload encryption.
@Suite struct OMEMO2SessionTests {
    var alice = try! LocalDevice.generate(deviceID: 1001)
    var bob = try! LocalDevice.generate(deviceID: 2002)

    mutating func handshake(_ text: String = "hello") throws -> (Session, Session) {
        var aliceSession = try Session.initiate(local: alice, bundle: bob.bundle(for: .v2))
        #expect(aliceSession.version == .v2)
        let first = try aliceSession.encrypt(Data(text.utf8))
        #expect(first.isPreKey)
        let accepted = try Session.accept(serialized: first.data, version: .v2, local: bob, existing: nil)
        #expect(accepted.plaintext == Data(text.utf8))
        #expect(accepted.session.version == .v2)
        if let used = accepted.consumedPreKeyID { bob.consumePreKey(used) }
        return (aliceSession, accepted.session)
    }

    @Test mutating func conversation() throws {
        var (a, b) = try handshake()
        // Identities are compared in their X25519 form, whatever the version.
        #expect(b.remoteIdentity == alice.identity.publicKey)
        #expect(a.remoteIdentity == bob.identity.publicKey)

        let second = try a.encrypt(Data("still there?".utf8))
        #expect(second.isPreKey)
        #expect(try Session.accept(serialized: second.data, version: .v2, local: bob, existing: b).plaintext
                == Data("still there?".utf8))

        let reply = try b.encrypt(Data("hi".utf8))
        #expect(!reply.isPreKey)
        #expect(try a.decrypt(serialized: reply.data) == Data("hi".utf8))
        #expect(!a.isAwaitingReply)

        for round in 0..<10 {
            for n in 0..<3 {
                let m = try a.encrypt(Data("a\(round).\(n)".utf8))
                #expect(try b.decrypt(serialized: m.data) == Data("a\(round).\(n)".utf8))
            }
            let m = try b.encrypt(Data("b\(round)".utf8))
            #expect(try a.decrypt(serialized: m.data) == Data("b\(round)".utf8))
        }
    }

    @Test mutating func outOfOrderAndReplay() throws {
        var (a, b) = try handshake()
        _ = try a.decrypt(serialized: try b.encrypt(Data("r".utf8)).data)
        let early = try (0..<5).map { try a.encrypt(Data("m\($0)".utf8)) }
        for m in early.reversed() { _ = try b.decrypt(serialized: m.data) }
        #expect(throws: OMEMOCryptoError.self) { try b.decrypt(serialized: early[2].data) }
    }

    @Test mutating func forgeryLeavesTheSessionIntact() throws {
        var (a, b) = try handshake()
        _ = try a.decrypt(serialized: try b.encrypt(Data("r".utf8)).data)
        let m = try a.encrypt(Data("intact".utf8))
        var forged = m.data
        forged[forged.count - 1] ^= 1
        #expect(throws: OMEMOCryptoError.self) { try b.decrypt(serialized: forged) }
        #expect(try b.decrypt(serialized: m.data) == Data("intact".utf8))
    }

    /// The MAC covers the associated data: a message cannot be moved to a
    /// session with other identities.
    @Test mutating func macBindsTheIdentities() throws {
        var (a, _) = try handshake()
        let carol = try LocalDevice.generate(deviceID: 3003)
        var toCarol = try Session.initiate(local: alice, bundle: carol.bundle(for: .v2))
        let first = try OMEMO2KeyExchange(serialized: toCarol.encrypt(Data("x".utf8)).data)
        let other = try OMEMO2KeyExchange(serialized: a.encrypt(Data("y".utf8)).data)
        // Carol's pre-key exchange with Bob's inner message: X3DH succeeds,
        // the MAC does not.
        var spliced = first
        spliced.message = other.message
        #expect(throws: OMEMOCryptoError.self) { try Session.accept(spliced, local: carol, existing: nil) }
    }

    @Test mutating func needsAOneTimePreKey() throws {
        var bundle = bob.bundle(for: .v2)
        bundle.preKeys = [:]
        #expect(throws: OMEMOCryptoError.unknownPreKey) { try Session.initiate(local: alice, bundle: bundle) }
    }

    @Test mutating func refusesABadSignature() throws {
        var bundle = bob.bundle(for: .v2)
        #expect(bundle.isSignatureValid)
        bundle.signedPreKey = KeyPair.generate().publicKey
        #expect(throws: OMEMOCryptoError.authenticationFailed) { try Session.initiate(local: alice, bundle: bundle) }
        // An OMEMO 0.3 signature (over the serialized key) is not an OMEMO 2 one.
        bundle = bob.bundle(for: .v2)
        bundle.signedPreKeySignature = bob.bundle.signedPreKeySignature
        #expect(!bundle.isSignatureValid)
    }

    /// A pre-key message in one version is never taken for the other's session.
    @Test mutating func versionsStayApart() throws {
        let (_, legacy) = try SessionTests.legacyHandshake(alice: alice, bob: &bob)
        var a = try Session.initiate(local: alice, bundle: bob.bundle(for: .v2))
        let first = try a.encrypt(Data("v2".utf8))
        #expect(throws: OMEMOCryptoError.malformed) {
            try Session.accept(serialized: first.data, version: .v2, local: bob, existing: legacy)
        }
    }

    @Test mutating func survivesEncoding() throws {
        var (a, b) = try handshake()
        let decoder = JSONDecoder(), encoder = JSONEncoder()
        a = try decoder.decode(Session.self, from: encoder.encode(a))
        b = try decoder.decode(Session.self, from: encoder.encode(b))
        #expect(a.version == .v2 && b.version == .v2)
        let m = try b.encrypt(Data("persisted".utf8))
        #expect(try a.decrypt(serialized: m.data) == Data("persisted".utf8))
    }

    /// Our OMEMO 2 signatures are plain Ed25519 under the published key, for
    /// libsodium and CryptoKit alike.
    @Test func signaturesAreEd25519() throws {
        let bundle = try LocalDevice.generate().bundle(for: .v2)
        let ik = try #require(bundle.ed25519IdentityKey)
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: ik)
        #expect(key.isValidSignature(bundle.signedPreKeySignature, for: bundle.signedPreKey.rawRepresentation))
        #expect(crypto_sign_verify_detached([UInt8](bundle.signedPreKeySignature),
                                            [UInt8](bundle.signedPreKey.rawRepresentation), 32, [UInt8](ik)) == 0)
    }

    /// Ed25519 identities made natively (either sign bit) convert to the
    /// X25519 key their owner does X3DH with.
    @Test func ed25519Conversion() throws {
        for _ in 0..<50 {
            let pair = KeyPair.generate()
            #expect(try PublicKey(ed25519: pair.publicKey.ed25519()) == pair.publicKey)

            let signing = Curve25519.Signing.PrivateKey()
            var sk = [UInt8](repeating: 0, count: 64), x = [UInt8](repeating: 0, count: 32)
            var pk = [UInt8](repeating: 0, count: 32)
            _ = crypto_sign_seed_keypair(&pk, &sk, [UInt8](signing.rawRepresentation))
            _ = crypto_sign_ed25519_sk_to_curve25519(&x, sk)
            let converted = try PublicKey(ed25519: signing.publicKey.rawRepresentation)
            #expect(converted == (try KeyPair(privateKey: Data(x))).publicKey)
        }
        #expect(throws: OMEMOCryptoError.malformed) { try PublicKey(ed25519: Data(count: 31)) }
    }

    /// A device stored before OMEMO 2 gains the second signature on load.
    @Test func olderDevicesGainTheSignature() throws {
        let device = try LocalDevice.generate()
        var json = try JSONSerialization.jsonObject(with: device.encodedWithoutIdentity()) as! [String: Any]
        var signed = json["signedPreKey"] as! [String: Any]
        signed.removeValue(forKey: "rawKeySignature")
        json["signedPreKey"] = signed
        let restored = try LocalDevice(encodedWithoutIdentity: JSONSerialization.data(withJSONObject: json),
                                       identity: device.identity)
        #expect(restored.bundle(for: .v2).isSignatureValid)
    }
}

@Suite struct OMEMO2WireFormatTests {
    /// Field numbers and wire types, byte for byte.
    @Test func messageLayout() throws {
        let key = try PublicKey(rawRepresentation: Data(repeating: 0xAB, count: 32))
        let message = OMEMO2Message(ratchetKey: key, counter: 1, previousCounter: 150, ciphertext: Data([0xC0, 0xDE]),
                                    macKey: Data(count: 32), associatedData: Data(count: 64))
        let inner = Data([0x08, 0x01, 0x10, 0x96, 0x01, 0x1A, 32]) + Data(repeating: 0xAB, count: 32)
            + Data([0x22, 0x02, 0xC0, 0xDE])
        let serialized = message.serialized
        #expect(serialized.prefix(2) == Data([0x0A, 16]))
        #expect(serialized.dropFirst(18) == Data([0x12, UInt8(inner.count)]) + inner)
        #expect(try OMEMO2Message(serialized: serialized) == message)
    }

    @Test func keyExchangeRoundTrips() throws {
        let alice = try LocalDevice.generate(), bob = try LocalDevice.generate()
        var session = try Session.initiate(local: alice, bundle: bob.bundle(for: .v2))
        let data = try session.encrypt(Data("x".utf8)).data
        let exchange = try OMEMO2KeyExchange(serialized: data)
        #expect(exchange.identityKey == (try alice.identity.publicKey.ed25519()))
        #expect(exchange.signedPreKeyID == bob.signedPreKey.id)
        #expect(bob.preKeys[exchange.preKeyID] != nil)
        #expect(exchange.serialized == data)
    }

    @Test func rejectsGarbage() {
        for _ in 0..<2000 {
            let data = Data.random(count: Int.random(in: 0..<120))
            _ = try? OMEMO2Message(serialized: data)
            _ = try? OMEMO2KeyExchange(serialized: data)
        }
        // A MAC of the wrong length.
        var writer = ProtobufWriter()
        writer.bytes(1, Data(count: 8))
        writer.bytes(2, Data([0x08, 0x00, 0x10, 0x00, 0x1A, 32]) + Data(count: 32))
        #expect(throws: OMEMOCryptoError.malformed) { try OMEMO2Message(serialized: writer.data) }
    }
}

@Suite struct OMEMO2PayloadTests {
    @Test func sealsAndOpens() throws {
        let sealed = try OMEMO2Payload.seal(Data("<envelope/>".utf8))
        #expect(sealed.keyMaterial.count == 48)
        #expect(try OMEMO2Payload.open(payload: sealed.payload, keyMaterial: sealed.keyMaterial) == Data("<envelope/>".utf8))
        var bad = sealed.payload
        bad[0] ^= 1
        #expect(throws: OMEMOCryptoError.authenticationFailed) {
            try OMEMO2Payload.open(payload: bad, keyMaterial: sealed.keyMaterial)
        }
        #expect(throws: OMEMOCryptoError.malformed) {
            try OMEMO2Payload.open(payload: sealed.payload, keyMaterial: OMEMO2Payload.emptyKeyMaterial)
        }
    }

    @Test func endToEnd() throws {
        let alice = try LocalDevice.generate(), bob = try LocalDevice.generate()
        let sealed = try OMEMO2Payload.seal(Data("end to end".utf8))
        var session = try Session.initiate(local: alice, bundle: bob.bundle(for: .v2))
        let key = try session.encrypt(sealed.keyMaterial)
        let accepted = try Session.accept(serialized: key.data, version: .v2, local: bob, existing: nil)
        #expect(try OMEMO2Payload.open(payload: sealed.payload, keyMaterial: accepted.plaintext) == Data("end to end".utf8))
    }
}
