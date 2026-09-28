import Foundation

/// Arithmetic modulo p = 2^255 − 19, for the one conversion libsodium does
/// not offer: a Montgomery u-coordinate to an Edwards y-coordinate
/// (RFC 7748 §4.1: y = (u − 1) / (u + 1)).
///
/// Used only on public keys during signature verification, so it is written
/// for clarity, not constant time. Never use it on secrets.
struct Field25519: Equatable {
    /// Little-endian 64-bit limbs, always fully reduced (< p).
    private(set) var limbs: [UInt64]

    static let p = Field25519(unchecked: [0xFFFF_FFFF_FFFF_FFED, .max, .max, 0x7FFF_FFFF_FFFF_FFFF])
    static let zero = Field25519(unchecked: [0, 0, 0, 0])
    static let one = Field25519(unchecked: [1, 0, 0, 0])

    private init(unchecked limbs: [UInt64]) { self.limbs = limbs }

    /// From 32 little-endian bytes. `nil` if the value is not below p.
    init?(bytes: Data) {
        guard bytes.count == 32 else { return nil }
        let raw = [UInt8](bytes)
        var limbs = [UInt64](repeating: 0, count: 4)
        for i in 0..<32 { limbs[i / 8] |= UInt64(raw[i]) << (8 * UInt64(i % 8)) }
        self.limbs = limbs
        guard Self.less(limbs, Self.p.limbs) else { return nil }
    }

    var bytes: Data {
        Data((0..<32).map { UInt8(truncatingIfNeeded: limbs[$0 / 8] >> (8 * UInt64($0 % 8))) })
    }

    static func + (a: Field25519, b: Field25519) -> Field25519 {
        var (sum, carry) = add(a.limbs, b.limbs)
        // a, b < p < 2^255, so the sum fits in 256 bits and carry is 0.
        precondition(carry == 0)
        if !less(sum, p.limbs) { (sum, carry) = sub(sum, p.limbs) }
        return Field25519(unchecked: sum)
    }

    static func - (a: Field25519, b: Field25519) -> Field25519 {
        if less(a.limbs, b.limbs) {
            return Field25519(unchecked: sub(add(a.limbs, p.limbs).0, b.limbs).0)
        }
        return Field25519(unchecked: sub(a.limbs, b.limbs).0)
    }

    static func * (a: Field25519, b: Field25519) -> Field25519 {
        // Schoolbook 256 × 256 → 512 bits.
        var wide = [UInt64](repeating: 0, count: 8)
        for i in 0..<4 {
            var carry: UInt64 = 0
            for j in 0..<4 {
                let (hi, lo) = a.limbs[i].multipliedFullWidth(by: b.limbs[j])
                let (s1, c1) = wide[i + j].addingReportingOverflow(lo)
                let (s2, c2) = s1.addingReportingOverflow(carry)
                wide[i + j] = s2
                carry = hi &+ (c1 ? 1 : 0) &+ (c2 ? 1 : 0)
            }
            wide[i + 4] = carry
        }
        return reduce(wide)
    }

    /// a^(p−2): the inverse by Fermat's little theorem. 0 maps to 0.
    var inverse: Field25519 {
        var exponent = Self.p.limbs
        exponent[0] -= 2
        var result = Self.one
        for limb in exponent.reversed() {
            for bit in (0..<64).reversed() {
                result = result * result
                if (limb >> UInt64(bit)) & 1 == 1 { result = result * self }
            }
        }
        return result
    }

    // MARK: - Limb helpers

    /// Folds a 512-bit value: 2^256 ≡ 38 (mod p).
    private static func reduce(_ wide: [UInt64]) -> Field25519 {
        var low = Array(wide[0..<4])
        var high = Array(wide[4..<8])
        while high.contains(where: { $0 != 0 }) {
            // low + 38·high, as five limbs.
            var product = [UInt64](repeating: 0, count: 5)
            var carry: UInt64 = 0
            for i in 0..<4 {
                let (hi, lo) = high[i].multipliedFullWidth(by: 38)
                let (s, c) = lo.addingReportingOverflow(carry)
                product[i] = s
                carry = hi &+ (c ? 1 : 0)
            }
            product[4] = carry
            let (sum, overflow) = add(low, Array(product[0..<4]))
            low = sum
            high = [product[4] &+ overflow, 0, 0, 0]
        }
        while !less(low, p.limbs) { low = sub(low, p.limbs).0 }
        return Field25519(unchecked: low)
    }

    private static func add(_ a: [UInt64], _ b: [UInt64]) -> ([UInt64], UInt64) {
        var out = [UInt64](repeating: 0, count: 4)
        var carry: UInt64 = 0
        for i in 0..<4 {
            let (s1, c1) = a[i].addingReportingOverflow(b[i])
            let (s2, c2) = s1.addingReportingOverflow(carry)
            out[i] = s2
            carry = (c1 ? 1 : 0) + (c2 ? 1 : 0)
        }
        return (out, carry)
    }

    private static func sub(_ a: [UInt64], _ b: [UInt64]) -> ([UInt64], UInt64) {
        var out = [UInt64](repeating: 0, count: 4)
        var borrow: UInt64 = 0
        for i in 0..<4 {
            let (d1, b1) = a[i].subtractingReportingOverflow(b[i])
            let (d2, b2) = d1.subtractingReportingOverflow(borrow)
            out[i] = d2
            borrow = (b1 ? 1 : 0) + (b2 ? 1 : 0)
        }
        return (out, borrow)
    }

    private static func less(_ a: [UInt64], _ b: [UInt64]) -> Bool {
        for i in (0..<4).reversed() where a[i] != b[i] { return a[i] < b[i] }
        return false
    }
}
