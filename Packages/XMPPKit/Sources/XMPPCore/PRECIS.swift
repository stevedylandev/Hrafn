import Foundation

/// PRECIS string preparation (RFC 8264) and the two profiles XMPP addresses
/// need (RFC 8265): `UsernameCaseMapped` for localparts and `OpaqueString` for
/// resourceparts.
///
/// Implemented against the RFCs using the Unicode properties the standard
/// library exposes. Two documented gaps, neither reachable by a conforming
/// server: the Bidi Rule (RFC 5893) is not enforced, and contextual rules
/// (CONTEXTJ/CONTEXTO) are approximated by their category checks.
public enum PRECIS {

    public struct ViolationError: Error, Sendable, Equatable, CustomStringConvertible {
        public enum Kind: Sendable, Equatable {
            case empty
            case disallowedCharacter
            case tooLong
        }
        public let kind: Kind
        public let scalar: Unicode.Scalar?
        public let profile: String

        public var description: String {
            if let scalar {
                return "\(profile): \(kind) U+\(String(scalar.value, radix: 16, uppercase: true))"
            }
            return "\(profile): \(kind)"
        }
    }

    /// RFC 8265 §3.3 — case-mapped IdentifierClass, used for XMPP localparts.
    public static func usernameCaseMapped(_ input: String) throws -> String {
        guard !input.isEmpty else {
            throw ViolationError(kind: .empty, scalar: nil, profile: "UsernameCaseMapped")
        }
        // 1. Width mapping, 2. no additional mapping, 3. case mapping,
        // 4. Unicode normalization form C.
        let prepared = widthMapped(input).lowercased().precomposedStringWithCanonicalMapping

        guard !prepared.isEmpty else {
            throw ViolationError(kind: .empty, scalar: nil, profile: "UsernameCaseMapped")
        }
        for scalar in prepared.unicodeScalars where !isIdentifierClass(scalar) {
            throw ViolationError(kind: .disallowedCharacter, scalar: scalar,
                                 profile: "UsernameCaseMapped")
        }
        return prepared
    }

    /// RFC 8265 §4.3 — OpaqueString, used for XMPP resourceparts. Case and
    /// width are significant; only non-ASCII spaces are folded to U+0020.
    public static func opaqueString(_ input: String) throws -> String {
        guard !input.isEmpty else {
            throw ViolationError(kind: .empty, scalar: nil, profile: "OpaqueString")
        }
        var mapped = String.UnicodeScalarView()
        for scalar in input.unicodeScalars {
            if scalar.properties.generalCategory == .spaceSeparator, scalar != " " {
                mapped.append(" ")
            } else {
                mapped.append(scalar)
            }
        }
        let prepared = String(mapped).precomposedStringWithCanonicalMapping

        guard !prepared.isEmpty else {
            throw ViolationError(kind: .empty, scalar: nil, profile: "OpaqueString")
        }
        for scalar in prepared.unicodeScalars where !isFreeformClass(scalar) {
            throw ViolationError(kind: .disallowedCharacter, scalar: scalar, profile: "OpaqueString")
        }
        return prepared
    }

    // MARK: - Mapping

    /// RFC 8264 §5.2.1 width mapping: fold halfwidth and fullwidth forms to
    /// their compatibility equivalents. Applying full NFKC would also destroy
    /// distinctions PRECIS keeps, so only the width blocks are touched.
    static func widthMapped(_ input: String) -> String {
        guard input.unicodeScalars.contains(where: hasWidthVariant) else { return input }
        var out = String.UnicodeScalarView()
        for scalar in input.unicodeScalars {
            if hasWidthVariant(scalar) {
                let folded = String(scalar).decomposedStringWithCompatibilityMapping
                    .precomposedStringWithCompatibilityMapping
                out.append(contentsOf: folded.unicodeScalars)
            } else {
                out.append(scalar)
            }
        }
        return String(out)
    }

    private static func hasWidthVariant(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3000,                 // ideographic space
             0xFF01...0xFF60,        // fullwidth forms
             0xFFE0...0xFFE6,        // fullwidth signs
             0xFF61...0xFFDC,        // halfwidth forms
             0xFFE8...0xFFEE:
            return true
        default:
            return false
        }
    }

    // MARK: - Character classes

    /// RFC 8264 §4.2 IdentifierClass: letters, digits, combining marks and
    /// printable ASCII. Non-ASCII symbols, punctuation, spaces, compatibility
    /// characters and anything unassigned are excluded.
    static func isIdentifierClass(_ scalar: Unicode.Scalar) -> Bool {
        if isPrintableASCII(scalar) { return true }
        if scalar.isASCII { return false }
        guard isLetterDigit(scalar) else { return false }
        // HasCompat: a compatibility decomposition means the character has a
        // canonical-equivalent spelling, so PRECIS disallows it in identifiers.
        return !hasCompatibilityDecomposition(scalar)
    }

    /// RFC 8264 §4.3 FreeformClass: everything printable, plus spaces. Controls,
    /// default-ignorable code points, surrogates and unassigned are excluded.
    static func isFreeformClass(_ scalar: Unicode.Scalar) -> Bool {
        if isPrintableASCII(scalar) || scalar == " " { return true }
        if scalar.isASCII { return false }  // C0 controls, DEL
        if scalar.properties.isDefaultIgnorableCodePoint { return false }
        switch scalar.properties.generalCategory {
        case .control, .surrogate, .unassigned, .privateUse, .format,
             .lineSeparator, .paragraphSeparator:
            return false
        default:
            return true
        }
    }

    private static func isPrintableASCII(_ scalar: Unicode.Scalar) -> Bool {
        (0x21...0x7E).contains(scalar.value)
    }

    private static func isLetterDigit(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .lowercaseLetter, .uppercaseLetter, .titlecaseLetter, .otherLetter,
             .modifierLetter, .decimalNumber, .nonspacingMark, .spacingMark:
            return true
        default:
            return false
        }
    }

    private static func hasCompatibilityDecomposition(_ scalar: Unicode.Scalar) -> Bool {
        let source = String(scalar)
        let canonical = source.decomposedStringWithCanonicalMapping
        let compatibility = source.decomposedStringWithCompatibilityMapping
        return canonical != compatibility
    }
}
