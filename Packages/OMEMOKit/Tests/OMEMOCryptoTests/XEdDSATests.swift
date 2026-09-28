import Clibsodium
import CryptoKit
import Foundation
import Testing
@testable import OMEMOCrypto

@Suite struct XEdDSATests {
    init() { _ = Sodium.isReady }

    /// The u → y conversion inverts libsodium's y → u (RFC 7748 §4.1).
    @Test func convertsMontgomeryToEdwards() throws {
        for _ in 0..<64 {
            var pk = [UInt8](repeating: 0, count: 32)
            var sk = [UInt8](repeating: 0, count: 64)
            crypto_sign_keypair(&pk, &sk)
            var u = [UInt8](repeating: 0, count: 32)
            #expect(crypto_sign_ed25519_pk_to_curve25519(&u, pk) == 0)
            let field = try #require(Field25519(bytes: Data(u)))
            var expected = pk
            expected[31] &= 0x7F
            #expect(XEdDSA.edwardsPoint(fromMontgomery: field) == expected)
        }
    }

    @Test func fieldInverse() throws {
        for _ in 0..<32 {
            var bytes = [UInt8](Data.random(count: 32))
            bytes[31] &= 0x7F
            guard let x = Field25519(bytes: Data(bytes)), x != .zero else { continue }
            #expect(x * x.inverse == .one)
        }
        #expect(Field25519(bytes: Field25519.p.bytes) == nil)
    }

    @Test func signsAndVerifies() throws {
        let pair = KeyPair.generate()
        let message = Data("signed pre-key".utf8)
        let signature = try pair.sign(message)
        #expect(signature.count == 64)
        #expect(pair.publicKey.isValidSignature(signature, for: message))
        #expect(!pair.publicKey.isValidSignature(signature, for: Data("other".utf8)))
        #expect(!KeyPair.generate().publicKey.isValidSignature(signature, for: message))
        for index in [0, 31, 32, 63] {
            var tampered = signature
            tampered[index] ^= 0x01
            #expect(!pair.publicKey.isValidSignature(tampered, for: message))
        }
    }

    /// XEdDSA signatures are Ed25519 signatures under the converted key
    /// (§4.1), so two independent Ed25519 verifiers must accept them.
    @Test func isEd25519Compatible() throws {
        for _ in 0..<64 {
            let pair = KeyPair.generate()
            let message = Data.random(count: Int.random(in: 0..<200))
            let signature = try pair.sign(message)
            let field = try #require(Field25519(bytes: pair.publicKey.rawRepresentation))
            let edwards = try #require(XEdDSA.edwardsPoint(fromMontgomery: field))

            #expect(crypto_sign_verify_detached([UInt8](signature), [UInt8](message),
                                                UInt64(message.count), edwards) == 0)
            let cryptoKitKey = try Curve25519.Signing.PublicKey(rawRepresentation: Data(edwards))
            #expect(cryptoKitKey.isValidSignature(signature, for: message))
        }
    }

    /// Same Z, same signature; different Z, different R.
    @Test func isDeterministicInItsRandomInput() throws {
        let pair = KeyPair.generate()
        let z = Data.random(count: 64)
        let first = try XEdDSA.sign(Data("m".utf8), privateKey: pair.privateKey, random: z)
        let again = try XEdDSA.sign(Data("m".utf8), privateKey: pair.privateKey, random: z)
        let other = try XEdDSA.sign(Data("m".utf8), privateKey: pair.privateKey, random: .random(count: 64))
        #expect(first == again)
        #expect(first != other)
    }

    /// A signature under the Edwards key with sign bit 1, flagged in the top
    /// bit of the last byte, as older signers produce.
    @Test func acceptsTheSignBitInTheSignature() throws {
        var checked = 0
        while checked < 16 {
            var pk = [UInt8](repeating: 0, count: 32)
            var sk = [UInt8](repeating: 0, count: 64)
            crypto_sign_keypair(&pk, &sk)
            guard pk[31] & 0x80 != 0 else { continue }
            var u = [UInt8](repeating: 0, count: 32)
            #expect(crypto_sign_ed25519_pk_to_curve25519(&u, pk) == 0)
            let message = Data.random(count: 40)
            var signature = [UInt8](repeating: 0, count: 64)
            crypto_sign_detached(&signature, nil, [UInt8](message), UInt64(message.count), sk)
            #expect(!XEdDSA.verify(Data(signature), for: message, publicKey: Data(u)))
            signature[63] |= 0x80
            #expect(XEdDSA.verify(Data(signature), for: message, publicKey: Data(u)))
            #expect(!XEdDSA.verify(Data(signature), for: message + Data([0]), publicKey: Data(u)))
            checked += 1
        }
    }

    @Test func rejectsMalformedInput() {
        let pair = KeyPair.generate()
        #expect(!pair.publicKey.isValidSignature(Data(count: 63), for: Data()))
        #expect(!pair.publicKey.isValidSignature(Data(count: 64), for: Data()))
        // u = p − 1 has no Edwards equivalent (u + 1 = 0).
        var pMinusOne = [UInt8](Field25519.p.bytes)
        pMinusOne[0] -= 1
        #expect(!XEdDSA.verify(Data(count: 64), for: Data(), publicKey: Data(pMinusOne)))
    }
}
