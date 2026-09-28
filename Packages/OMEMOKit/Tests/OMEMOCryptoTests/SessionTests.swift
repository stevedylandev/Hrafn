import CryptoKit
import Foundation
import Testing
@testable import OMEMOCrypto

/// Two devices talking through `Session`, the way the XML layer will drive it.
@Suite struct SessionTests {
    var alice = try! LocalDevice.generate(deviceID: 1001)
    var bob = try! LocalDevice.generate(deviceID: 2002)

    /// Alice starts; Bob accepts her first message.
    mutating func handshake(_ text: String = "hello") throws -> (Session, Session) {
        var aliceSession = try Session.initiate(local: alice, bundle: bob.bundle)
        let first = try aliceSession.encrypt(Data(text.utf8))
        #expect(first.isPreKey)
        let accepted = try Session.accept(serialized: first.data, local: bob, existing: nil)
        #expect(accepted.plaintext == Data(text.utf8))
        if let used = accepted.consumedPreKeyID { bob.consumePreKey(used) }
        return (aliceSession, accepted.session)
    }

    /// Alice starts an OMEMO 0.3 session with Bob, for other suites.
    static func legacyHandshake(alice: LocalDevice, bob: inout LocalDevice) throws -> (Session, Session) {
        var a = try Session.initiate(local: alice, bundle: bob.bundle)
        let accepted = try Session.accept(serialized: a.encrypt(Data("x".utf8)).data, local: bob, existing: nil)
        if let used = accepted.consumedPreKeyID { bob.consumePreKey(used) }
        return (a, accepted.session)
    }

    @Test mutating func conversation() throws {
        var (a, b) = try handshake()
        #expect(b.remoteIdentity == alice.identity.publicKey)
        #expect(a.remoteIdentity == bob.identity.publicKey)

        // Alice keeps sending pre-key messages until Bob answers.
        let second = try a.encrypt(Data("still there?".utf8))
        #expect(second.isPreKey)
        #expect(try Session.accept(serialized: second.data, local: bob, existing: b).plaintext == Data("still there?".utf8))

        let reply = try b.encrypt(Data("hi".utf8))
        #expect(!reply.isPreKey)
        #expect(try a.decrypt(serialized: reply.data) == Data("hi".utf8))
        #expect(!a.isAwaitingReply)

        // Back and forth, several ratchet steps.
        for round in 0..<10 {
            for n in 0..<3 {
                let m = try a.encrypt(Data("a\(round).\(n)".utf8))
                #expect(!m.isPreKey)
                #expect(try b.decrypt(serialized: m.data) == Data("a\(round).\(n)".utf8))
            }
            let m = try b.encrypt(Data("b\(round)".utf8))
            #expect(try a.decrypt(serialized: m.data) == Data("b\(round)".utf8))
        }
    }

    @Test mutating func consumesTheOneTimePreKey() throws {
        let before = bob.preKeys.count
        _ = try handshake()
        #expect(bob.preKeys.count == before - 1)
        let refilled = bob.refillPreKeys()
        #expect(refilled)
        #expect(bob.preKeys.count == LocalDevice.preKeyTarget)
    }

    /// X3DH without a one-time pre-key (the bundle ran out).
    @Test mutating func withoutAOneTimePreKey() throws {
        var bundle = bob.bundle
        bundle.preKeys = [:]
        var a = try Session.initiate(local: alice, bundle: bundle)
        let first = try a.encrypt(Data("x".utf8))
        let accepted = try Session.accept(serialized: first.data, local: bob, existing: nil)
        #expect(accepted.plaintext == Data("x".utf8))
        #expect(accepted.consumedPreKeyID == nil)
    }

    @Test mutating func outOfOrderAcrossRatchetSteps() throws {
        var (a, b) = try handshake()
        var reply = try b.encrypt(Data("r".utf8))
        _ = try a.decrypt(serialized: reply.data)

        let early = try (0..<5).map { try a.encrypt(Data("m\($0)".utf8)) }
        reply = try b.encrypt(Data("r2".utf8))
        _ = try a.decrypt(serialized: reply.data)
        let late = try a.encrypt(Data("late".utf8))

        // The new chain first, then the old one backwards.
        #expect(try b.decrypt(serialized: late.data) == Data("late".utf8))
        for (n, message) in early.enumerated().reversed() {
            #expect(try b.decrypt(serialized: message.data) == Data("m\(n)".utf8))
        }
    }

    @Test mutating func rejectsReplays() throws {
        var (a, b) = try handshake()
        let reply = try b.encrypt(Data("r".utf8))
        _ = try a.decrypt(serialized: reply.data)
        let m = try a.encrypt(Data("once".utf8))
        #expect(try b.decrypt(serialized: m.data) == Data("once".utf8))
        #expect(throws: OMEMOCryptoError.self) { try b.decrypt(serialized: m.data) }
    }

    /// A forged or corrupted message fails and leaves the session as it was.
    @Test mutating func tamperingFailsWithoutDamage() throws {
        var (a, b) = try handshake()
        let reply = try b.encrypt(Data("r".utf8))
        _ = try a.decrypt(serialized: reply.data)
        let m = try a.encrypt(Data("intact".utf8))
        for index in [1, m.data.count / 2, m.data.count - 1] {
            var bad = m.data
            bad[index] ^= 0x40
            #expect(throws: OMEMOCryptoError.self) { try b.decrypt(serialized: bad) }
        }
        // A message under an unknown ratchet key forces a (failed) DH step.
        var forged = try LegacySignalMessage(serialized: m.data)
        forged = LegacySignalMessage(ratchetKey: KeyPair.generate().publicKey, counter: 0, previousCounter: 0,
                                     ciphertext: forged.ciphertext, macKey: Data(count: 32),
                                     sender: alice.identity.publicKey, receiver: bob.identity.publicKey)
        #expect(throws: OMEMOCryptoError.self) { try b.decrypt(forged) }
        #expect(try b.decrypt(serialized: m.data) == Data("intact".utf8))
    }

    @Test mutating func refusesTooManySkippedMessages() throws {
        var (a, b) = try handshake()
        let reply = try b.encrypt(Data("r".utf8))
        _ = try a.decrypt(serialized: reply.data)
        for _ in 0...SessionState.maxSkip { _ = try a.encrypt(Data()) }
        let far = try a.encrypt(Data("far".utf8))
        #expect(throws: OMEMOCryptoError.self) { try b.decrypt(serialized: far.data) }
    }

    /// Both sides start a session at once. Each side's newest session wins
    /// for sending, and the other one still decrypts.
    @Test mutating func simultaneousInitiation() throws {
        var a = try Session.initiate(local: alice, bundle: bob.bundle)
        var b = try Session.initiate(local: bob, bundle: alice.bundle)
        let fromAlice = try a.encrypt(Data("from alice".utf8))
        let fromBob = try b.encrypt(Data("from bob".utf8))

        let atBob = try Session.accept(serialized: fromAlice.data, local: bob, existing: b)
        let atAlice = try Session.accept(serialized: fromBob.data, local: alice, existing: a)
        #expect(atBob.plaintext == Data("from alice".utf8))
        #expect(atAlice.plaintext == Data("from bob".utf8))
        b = atBob.session
        a = atAlice.session

        let m = try a.encrypt(Data("after".utf8))
        #expect(try b.decrypt(serialized: m.data) == Data("after".utf8))
        let n = try b.encrypt(Data("after too".utf8))
        #expect(try a.decrypt(serialized: n.data) == Data("after too".utf8))
    }

    @Test mutating func refusesABadlySignedBundle() throws {
        var bundle = bob.bundle
        bundle.signedPreKey = KeyPair.generate().publicKey
        #expect(throws: OMEMOCryptoError.authenticationFailed) { try Session.initiate(local: alice, bundle: bundle) }
    }

    @Test mutating func unknownPreKeyIsReported() throws {
        var a = try Session.initiate(local: alice, bundle: bob.bundle)
        let first = try a.encrypt(Data("x".utf8))
        let message = try LegacyPreKeySignalMessage(serialized: first.data)
        if let id = message.preKeyID { bob.consumePreKey(id) }
        #expect(throws: OMEMOCryptoError.unknownPreKey) { try Session.accept(message, local: bob, existing: nil) }
    }

    /// Messages to the previous signed pre-key still work after rotation.
    @Test mutating func survivesSignedPreKeyRotation() throws {
        var a = try Session.initiate(local: alice, bundle: bob.bundle)
        try bob.rotateSignedPreKey()
        let first = try a.encrypt(Data("in flight".utf8))
        #expect(try Session.accept(serialized: first.data, local: bob, existing: nil).plaintext == Data("in flight".utf8))
    }

    @Test mutating func survivesEncoding() throws {
        var (a, b) = try handshake()
        let decoder = JSONDecoder(), encoder = JSONEncoder()
        a = try decoder.decode(Session.self, from: encoder.encode(a))
        b = try decoder.decode(Session.self, from: encoder.encode(b))
        bob = try decoder.decode(LocalDevice.self, from: encoder.encode(bob))
        let m = try b.encrypt(Data("persisted".utf8))
        #expect(try a.decrypt(serialized: m.data) == Data("persisted".utf8))
        #expect(bob.bundle.isSignatureValid)
    }
}

@Suite struct WireFormatTests {
    @Test func signalMessageRoundTrips() throws {
        let sender = KeyPair.generate().publicKey, receiver = KeyPair.generate().publicKey
        let mac = Data.random(count: 32)
        let message = LegacySignalMessage(ratchetKey: KeyPair.generate().publicKey, counter: 300, previousCounter: 7,
                                          ciphertext: .random(count: 48), macKey: mac, sender: sender, receiver: receiver)
        #expect(message.serialized.first == 0x33)
        let parsed = try LegacySignalMessage(serialized: message.serialized)
        #expect(parsed == message)
        try parsed.verifyMAC(key: mac, sender: sender, receiver: receiver)
        // The MAC binds the direction.
        #expect(throws: OMEMOCryptoError.authenticationFailed) {
            try parsed.verifyMAC(key: mac, sender: receiver, receiver: sender)
        }
    }

    /// Field numbers and wire types, byte for byte.
    @Test func signalMessageLayout() throws {
        let key = try PublicKey(rawRepresentation: Data(repeating: 0xAB, count: 32))
        let message = LegacySignalMessage(ratchetKey: key, counter: 1, previousCounter: 150,
                                          ciphertext: Data([0xC0, 0xDE]), macKey: Data(count: 32),
                                          sender: key, receiver: key)
        let expected = Data([0x33, 0x0A, 33, 0x05]) + Data(repeating: 0xAB, count: 32)
            + Data([0x10, 0x01, 0x18, 0x96, 0x01, 0x22, 0x02, 0xC0, 0xDE])
        #expect(message.serialized.dropLast(8) == expected)
    }

    @Test func rejectsGarbage() {
        for _ in 0..<2000 {
            let data = Data.random(count: Int.random(in: 0..<120))
            _ = try? LegacySignalMessage(serialized: data)
            _ = try? LegacyPreKeySignalMessage(serialized: data)
        }
        #expect(throws: OMEMOCryptoError.malformed) { try LegacySignalMessage(serialized: Data([0x23]) + Data(count: 20)) }
        // A varint that never ends.
        #expect(throws: OMEMOCryptoError.malformed) { try ProtobufReader(Data(repeating: 0xFF, count: 11)) }
        // A length past the end.
        #expect(throws: OMEMOCryptoError.malformed) { try ProtobufReader(Data([0x0A, 0x05, 0x00])) }
    }

    @Test func publicKeySerialization() throws {
        let key = KeyPair.generate().publicKey
        #expect(key.serialized.count == 33)
        #expect(try PublicKey(serialized: key.serialized) == key)
        #expect(try PublicKey(serialized: key.rawRepresentation) == key)
        #expect(throws: OMEMOCryptoError.malformed) { try PublicKey(serialized: Data([0x04]) + key.rawRepresentation) }
        #expect(key.fingerprint.split(separator: " ").count == 8)
    }
}

@Suite struct PayloadTests {
    @Test func sealsAndOpens() throws {
        let sealed = try LegacyPayload.seal(Data("secret".utf8))
        #expect(sealed.iv.count == 12)
        #expect(sealed.keyMaterial.count == 32)
        #expect(try LegacyPayload.open(payload: sealed.payload, iv: sealed.iv, keyMaterial: sealed.keyMaterial)
                == Data("secret".utf8))
        var bad = sealed.payload
        bad[0] ^= 1
        #expect(throws: OMEMOCryptoError.authenticationFailed) {
            try LegacyPayload.open(payload: bad, iv: sealed.iv, keyMaterial: sealed.keyMaterial)
        }
    }

    /// Older senders: tag at the end of the payload, and 16-byte IVs.
    @Test func opensTheOlderLayouts() throws {
        let sealed = try LegacyPayload.seal(Data("old".utf8))
        let key = sealed.keyMaterial.prefix(16), tag = sealed.keyMaterial.suffix(16)
        #expect(try LegacyPayload.open(payload: sealed.payload + tag, iv: sealed.iv, keyMaterial: key) == Data("old".utf8))

        let longIV = Data.random(count: 16)
        let box = try AES.GCM.seal(Data("iv16".utf8), using: SymmetricKey(data: key), nonce: AES.GCM.Nonce(data: longIV))
        #expect(try LegacyPayload.open(payload: box.ciphertext, iv: longIV, keyMaterial: key + box.tag) == Data("iv16".utf8))
    }

    /// The whole 0.3 path: payload sealed once, key material through a session.
    @Test func endToEnd() throws {
        let alice = try LocalDevice.generate(), bob = try LocalDevice.generate()
        let sealed = try LegacyPayload.seal(Data("end to end".utf8))
        var session = try Session.initiate(local: alice, bundle: bob.bundle)
        let key = try session.encrypt(sealed.keyMaterial)
        let accepted = try Session.accept(serialized: key.data, local: bob, existing: nil)
        #expect(try LegacyPayload.open(payload: sealed.payload, iv: sealed.iv, keyMaterial: accepted.plaintext)
                == Data("end to end".utf8))
    }
}

@Suite struct DeviceStorageTests {
    @Test func splitsOffTheIdentity() throws {
        var device = try LocalDevice.generate()
        device.consumePreKey(3)
        let data = try device.encodedWithoutIdentity()
        let secret = device.identity.privateKey
        #expect(data.range(of: secret) == nil)
        #expect(data.range(of: Data(secret.base64EncodedString().utf8)) == nil)

        let restored = try LocalDevice(encodedWithoutIdentity: data, identity: device.identity)
        #expect(restored.deviceID == device.deviceID)
        #expect(restored.bundle == device.bundle)
        #expect(restored.preKeys[3] == nil)

        #expect(throws: OMEMOCryptoError.authenticationFailed) {
            try LocalDevice(encodedWithoutIdentity: data, identity: .generate())
        }
    }
}
