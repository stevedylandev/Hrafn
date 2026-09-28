import Foundation

/// Punycode (RFC 3492), needed to turn IDN domainparts into the A-labels that
/// DNS queries take. Implemented from the RFC's algorithm description.
public enum Punycode {
    private static let base = 36
    private static let tMin = 1
    private static let tMax = 26
    private static let skew = 38
    private static let damp = 700
    private static let initialBias = 72
    private static let initialN: UInt32 = 0x80
    private static let delimiter: Character = "-"
    static let acePrefix = "xn--"

    public struct Error: Swift.Error, Sendable, Equatable {
        public enum Kind: Sendable, Equatable { case overflow, invalidInput, labelTooLong }
        public let kind: Kind
    }

    /// Encodes one label. ASCII-only labels are returned unchanged; others get
    /// the `xn--` prefix.
    public static func encode(label: String) throws -> String {
        guard label.unicodeScalars.contains(where: { !$0.isASCII }) else { return label }

        let scalars = Array(label.unicodeScalars)
        var output = scalars.filter(\.isASCII).map { Character($0) }
        let basicCount = output.count
        var handled = basicCount
        if basicCount > 0 { output.append(delimiter) }

        var n = initialN
        var delta = 0
        var bias = initialBias

        while handled < scalars.count {
            // Smallest code point not yet handled.
            guard let m = scalars.lazy.map(\.value).filter({ $0 >= n }).min() else {
                throw Error(kind: .invalidInput)
            }
            let (scaled, scaleOverflow) = (Int(m - n)).multipliedReportingOverflow(by: handled + 1)
            if scaleOverflow { throw Error(kind: .overflow) }
            let (bumped, addOverflow) = delta.addingReportingOverflow(scaled)
            if addOverflow { throw Error(kind: .overflow) }
            delta = bumped
            n = m

            for scalar in scalars {
                if scalar.value < n {
                    delta += 1
                    if delta < 0 { throw Error(kind: .overflow) }
                } else if scalar.value == n {
                    var q = delta
                    var k = base
                    while true {
                        let t = max(tMin, min(tMax, k - bias))
                        if q < t { break }
                        output.append(digit((t + (q - t) % (base - t))))
                        q = (q - t) / (base - t)
                        k += base
                    }
                    output.append(digit(q))
                    bias = adapt(delta: delta, numPoints: handled + 1,
                                 firstTime: handled == basicCount)
                    delta = 0
                    handled += 1
                }
            }
            delta += 1
            n += 1
        }

        let encoded = acePrefix + String(output)
        guard encoded.utf8.count <= 63 else { throw Error(kind: .labelTooLong) }
        return encoded
    }

    /// Encodes every label of a dotted domain name.
    public static func encode(domain: String) throws -> String {
        try domain.split(separator: ".", omittingEmptySubsequences: false)
            .map { try encode(label: String($0)) }
            .joined(separator: ".")
    }

    public static func decode(label: String) throws -> String {
        let lowered = label.lowercased()
        guard lowered.hasPrefix(acePrefix) else { return label }
        let encoded = String(lowered.dropFirst(acePrefix.count))

        var output: [UInt32]
        var index: String.Index
        if let lastDelimiter = encoded.lastIndex(of: delimiter) {
            output = encoded[encoded.startIndex..<lastDelimiter].unicodeScalars.map(\.value)
            guard output.allSatisfy({ $0 < 0x80 }) else { throw Error(kind: .invalidInput) }
            index = encoded.index(after: lastDelimiter)
        } else {
            output = []
            index = encoded.startIndex
        }

        var n = initialN
        var i = 0
        var bias = initialBias

        while index < encoded.endIndex {
            let oldI = i
            var w = 1
            var k = base
            while true {
                guard index < encoded.endIndex else { throw Error(kind: .invalidInput) }
                let digitValue = try value(of: encoded[index])
                index = encoded.index(after: index)
                let (product, overflow) = digitValue.multipliedReportingOverflow(by: w)
                if overflow { throw Error(kind: .overflow) }
                let (sum, sumOverflow) = i.addingReportingOverflow(product)
                if sumOverflow { throw Error(kind: .overflow) }
                i = sum
                let t = max(tMin, min(tMax, k - bias))
                if digitValue < t { break }
                let (nextW, wOverflow) = w.multipliedReportingOverflow(by: base - t)
                if wOverflow { throw Error(kind: .overflow) }
                w = nextW
                k += base
            }
            bias = adapt(delta: i - oldI, numPoints: output.count + 1, firstTime: oldI == 0)
            let (deltaN, nOverflow) = (i / (output.count + 1)).addingReportingOverflow(Int(n))
            if nOverflow || deltaN > 0x10FFFF { throw Error(kind: .overflow) }
            n = UInt32(deltaN)
            i %= output.count + 1
            output.insert(n, at: i)
            i += 1
        }

        var result = String.UnicodeScalarView()
        for value in output {
            guard let scalar = Unicode.Scalar(value) else { throw Error(kind: .invalidInput) }
            result.append(scalar)
        }
        return String(result)
    }

    // MARK: - Helpers

    private static func adapt(delta: Int, numPoints: Int, firstTime: Bool) -> Int {
        var delta = firstTime ? delta / damp : delta / 2
        delta += delta / numPoints
        var k = 0
        while delta > ((base - tMin) * tMax) / 2 {
            delta /= base - tMin
            k += base
        }
        return k + ((base - tMin + 1) * delta) / (delta + skew)
    }

    private static func digit(_ value: Int) -> Character {
        // 0..25 -> 'a'..'z', 26..35 -> '0'..'9'
        let scalarValue = value < 26 ? 0x61 + value : 0x30 + value - 26
        return Character(Unicode.Scalar(UInt32(scalarValue))!)
    }

    private static func value(of character: Character) throws -> Int {
        guard let ascii = character.asciiValue else { throw Error(kind: .invalidInput) }
        switch ascii {
        case 0x41...0x5A: return Int(ascii - 0x41)          // A-Z
        case 0x61...0x7A: return Int(ascii - 0x61)          // a-z
        case 0x30...0x39: return Int(ascii - 0x30) + 26     // 0-9
        default: throw Error(kind: .invalidInput)
        }
    }
}
