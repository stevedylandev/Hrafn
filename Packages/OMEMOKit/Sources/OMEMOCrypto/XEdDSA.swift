import Clibsodium
import CryptoKit
import Foundation

/// XEdDSA over Curve25519 ("The XEdDSA and VXEdDSA Signature Schemes",
/// Perrin, 2016, §2.3 and §4): EdDSA-compatible signatures made with an X25519
/// key pair. OMEMO 0.3 identity keys are X25519 keys and sign the signed
/// pre-key this way.
///
/// The Edwards-curve operations are libsodium's (ISC); the hashing is
/// CryptoKit's SHA-512.
enum XEdDSA {
    /// L, the order of the base point, is < 2^253 (§2.2: |q| = 253).
    private static let scalarBits = 253

    /// §4.4 `xeddsa_sign`. `random` is the 64 bytes Z; tests pass it in.
    static func sign(_ message: Data, privateKey: Data, random: Data = .random(count: 64)) throws -> Data {
        try Sodium.ensureReady()
        guard privateKey.count == 32, random.count == 64 else { throw OMEMOCryptoError.malformed }

        // §4.3 calculate_key_pair: the clamped X25519 scalar k, A = kB, and
        // a = ±k so that A's sign bit is 0.
        var k = [UInt8](privateKey)
        k[0] &= 248; k[31] &= 127; k[31] |= 64
        defer { sodium_memzero(&k, k.count) }

        var a = reduce(k + [UInt8](repeating: 0, count: 32))
        defer { sodium_memzero(&a, a.count) }
        var A = try baseMultiply(a)
        if A[31] & 0x80 != 0 {
            var negated = [UInt8](repeating: 0, count: 32)
            crypto_core_ed25519_scalar_negate(&negated, a)
            a = negated
            sodium_memzero(&negated, negated.count)
            A[31] &= 0x7F
        }

        // r = hash1(a || M || Z) (mod q), R = rB.
        var r = reduce(hash(prefix: 1, a + [UInt8](message) + [UInt8](random)))
        defer { sodium_memzero(&r, r.count) }
        let R = try baseMultiply(r)

        // h = hash(R || A || M) (mod q), s = r + ha (mod q).
        let h = reduce([UInt8](SHA512.hash(data: Data(R + A) + message)))
        var ha = [UInt8](repeating: 0, count: 32)
        defer { sodium_memzero(&ha, ha.count) }
        crypto_core_ed25519_scalar_mul(&ha, h, a)
        var s = [UInt8](repeating: 0, count: 32)
        crypto_core_ed25519_scalar_add(&s, r, ha)
        return Data(R + s)
    }

    /// §4.4 `xeddsa_verify`, also accepting the older convention in which
    /// the signer does not force its Edwards key's sign bit to 0 but sends
    /// it in the top bit of the signature's last byte (unused, since
    /// s < 2^253). Deployed OMEMO 0.3 implementations sign that way: about
    /// half of their signatures set the bit (found by the interop tests).
    static func verify(_ signature: Data, for message: Data, publicKey u: Data) -> Bool {
        guard Sodium.isReady, signature.count == 64, u.count == 32 else { return false }
        let R = [UInt8](signature.prefix(32))
        var s = [UInt8](signature.suffix(32))
        let signBit = s[31] & 0x80
        s[31] &= 0x7F

        // Reject u ≥ p, R.y ≥ 2^|p| (the sign bit aside), s ≥ 2^|q|.
        guard let uField = Field25519(bytes: u),
              s[31] & 0xE0 == 0 else { return false }
        guard var A = edwardsPoint(fromMontgomery: uField) else { return false }
        A[31] |= signBit
        guard crypto_core_ed25519_is_valid_point(A) == 1 else { return false }

        // R == sB − hA, with h = hash(R || A || M) (mod q).
        let h = reduce([UInt8](SHA512.hash(data: Data(R + A) + message)))
        var sB = [UInt8](repeating: 0, count: 32)
        var hA = [UInt8](repeating: 0, count: 32)
        var check = [UInt8](repeating: 0, count: 32)
        guard crypto_scalarmult_ed25519_base_noclamp(&sB, s) == 0,
              crypto_scalarmult_ed25519_noclamp(&hA, h, A) == 0,
              crypto_core_ed25519_sub(&check, sB, hA) == 0 else { return false }
        return sodium_memcmp(check, R, 32) == 0
    }

    /// §4.1 `convert_mont`: y = (u − 1) / (u + 1), sign bit 0.
    static func edwardsPoint(fromMontgomery u: Field25519) -> [UInt8]? {
        let denominator = u + .one
        guard denominator != .zero else { return nil }
        let y = (u - .one) * denominator.inverse
        var bytes = [UInt8](y.bytes)
        bytes[31] &= 0x7F
        return bytes
    }

    // MARK: -

    /// §2.5 hash_i(X) = SHA-512((2^256 − 1 − i) as 32 little-endian bytes || X).
    private static func hash(prefix i: UInt8, _ x: [UInt8]) -> [UInt8] {
        let prefix = [0xFF - i] + [UInt8](repeating: 0xFF, count: 31)
        return [UInt8](SHA512.hash(data: Data(prefix + x)))
    }

    /// A 64-byte value reduced modulo q.
    private static func reduce(_ wide: [UInt8]) -> [UInt8] {
        precondition(wide.count == 64)
        var out = [UInt8](repeating: 0, count: 32)
        crypto_core_ed25519_scalar_reduce(&out, wide)
        return out
    }

    private static func baseMultiply(_ scalar: [UInt8]) throws -> [UInt8] {
        var point = [UInt8](repeating: 0, count: 32)
        guard crypto_scalarmult_ed25519_base_noclamp(&point, scalar) == 0 else {
            throw OMEMOCryptoError.internalFailure
        }
        return point
    }
}
