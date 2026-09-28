import Foundation

/// An XMPP address (RFC 7622), normalized at construction so that `==` is
/// protocol-correct comparison.
///
/// `localpart@domainpart/resourcepart`, where localpart and resourcepart are
/// optional. Each part is enforced to be 1–1023 bytes and prepared with the
/// PRECIS profile the RFC assigns to it.
public struct JID: Sendable, Hashable, Codable, CustomStringConvertible {

    public enum ParseError: Error, Sendable, Equatable, CustomStringConvertible {
        case emptyAddress
        case emptyDomain
        case emptyLocalpart
        case emptyResourcepart
        case partTooLong(part: String)
        case forbiddenCharacter(part: String, character: Character)
        case invalidDomain(String)
        case precis(PRECIS.ViolationError)

        public var description: String {
            switch self {
            case .emptyAddress: "empty address"
            case .emptyDomain: "empty domainpart"
            case .emptyLocalpart: "empty localpart"
            case .emptyResourcepart: "empty resourcepart"
            case .partTooLong(let part): "\(part) exceeds 1023 bytes"
            case .forbiddenCharacter(let part, let character): "\(part) contains '\(character)'"
            case .invalidDomain(let reason): "invalid domainpart: \(reason)"
            case .precis(let error): error.description
            }
        }
    }

    /// Maximum size of each part, in bytes (RFC 7622 §3.2).
    public static let maxPartBytes = 1023

    public let localpart: String?
    public let domainpart: String
    public let resourcepart: String?

    // MARK: - Construction

    public init(localpart: String?, domainpart: String, resourcepart: String? = nil) throws {
        if let localpart {
            guard !localpart.isEmpty else { throw ParseError.emptyLocalpart }
            // RFC 7622 §3.3: these are excluded from localparts because they are
            // JID delimiters or historically ambiguous.
            for character in localpart where #"\"&'/:<>@ "#.contains(character) {
                throw ParseError.forbiddenCharacter(part: "localpart", character: character)
            }
            let prepared: String
            do { prepared = try PRECIS.usernameCaseMapped(localpart) }
            catch let error as PRECIS.ViolationError { throw ParseError.precis(error) }
            try Self.checkLength(prepared, part: "localpart")
            self.localpart = prepared
        } else {
            self.localpart = nil
        }

        let domain = try Self.prepareDomain(domainpart)
        try Self.checkLength(domain, part: "domainpart")
        self.domainpart = domain

        if let resourcepart {
            guard !resourcepart.isEmpty else { throw ParseError.emptyResourcepart }
            let prepared: String
            do { prepared = try PRECIS.opaqueString(resourcepart) }
            catch let error as PRECIS.ViolationError { throw ParseError.precis(error) }
            try Self.checkLength(prepared, part: "resourcepart")
            self.resourcepart = prepared
        } else {
            self.resourcepart = nil
        }
    }

    /// Parses `[localpart@]domainpart[/resourcepart]`.
    ///
    /// Splitting order matters: the resourcepart may contain `@` and `/`, and the
    /// localpart may contain neither, so the first `/` ends the bare JID and the
    /// first `@` before it ends the localpart.
    public init(_ string: String) throws {
        guard !string.isEmpty else { throw ParseError.emptyAddress }

        let bare: Substring
        let resource: Substring?
        if let slash = string.firstIndex(of: "/") {
            bare = string[string.startIndex..<slash]
            resource = string[string.index(after: slash)...]
        } else {
            bare = string[...]
            resource = nil
        }

        let local: Substring?
        let domain: Substring
        if let at = bare.firstIndex(of: "@") {
            local = bare[bare.startIndex..<at]
            domain = bare[bare.index(after: at)...]
        } else {
            local = nil
            domain = bare
        }

        try self.init(localpart: local.map(String.init),
                      domainpart: String(domain),
                      resourcepart: resource.map(String.init))
    }

    // MARK: - Derived addresses

    /// The address without its resourcepart.
    public var bare: JID {
        resourcepart == nil ? self : JID(unchecked: localpart, domainpart, nil)
    }

    /// The domain alone — the address of the server itself.
    public var domain: JID {
        JID(unchecked: nil, domainpart, nil)
    }

    public var isBare: Bool { resourcepart == nil }
    public var isFull: Bool { resourcepart != nil }
    /// True for a server or component address (`example.com`).
    public var isDomainOnly: Bool { localpart == nil && resourcepart == nil }

    public func withResource(_ resource: String?) throws -> JID {
        try JID(localpart: localpart, domainpart: domainpart, resourcepart: resource)
    }

    /// Domainpart as DNS A-labels, for SRV and A/AAAA lookups.
    public var domainForDNS: String {
        (try? Punycode.encode(domain: domainpart)) ?? domainpart
    }

    public var description: String {
        var out = ""
        if let localpart { out += localpart + "@" }
        out += domainpart
        if let resourcepart { out += "/" + resourcepart }
        return out
    }

    // MARK: - Codable

    public init(from decoder: any Decoder) throws {
        let string = try decoder.singleValueContainer().decode(String.self)
        try self.init(string)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }

    // MARK: - Internals

    /// Skips preparation; only for deriving a JID from an already-prepared one.
    private init(unchecked localpart: String?, _ domainpart: String, _ resourcepart: String?) {
        self.localpart = localpart
        self.domainpart = domainpart
        self.resourcepart = resourcepart
    }

    private static func checkLength(_ part: String, part name: String) throws {
        guard part.utf8.count <= maxPartBytes else { throw ParseError.partTooLong(part: name) }
    }

    /// RFC 7622 §3.2: an IDNA2008-conforming domain name, an IPv4 literal, or a
    /// bracketed IPv6 literal. Case and Unicode form are normalized; the
    /// U-label form is kept for display, with A-labels produced on demand.
    private static func prepareDomain(_ input: String) throws -> String {
        var domain = input
        guard !domain.isEmpty else { throw ParseError.emptyDomain }
        // A trailing root dot is legal in DNS but not in a JID.
        if domain.count > 1 && domain.hasSuffix(".") { domain.removeLast() }
        guard !domain.isEmpty else { throw ParseError.emptyDomain }

        if domain.hasPrefix("[") {
            guard domain.hasSuffix("]"), domain.count > 2 else {
                throw ParseError.invalidDomain("malformed IP literal")
            }
            let inner = String(domain.dropFirst().dropLast())
            guard inner.allSatisfy({ $0.isHexDigit || $0 == ":" || $0 == "." }) else {
                throw ParseError.invalidDomain("malformed IPv6 literal")
            }
            return "[" + inner.lowercased() + "]"
        }

        domain = domain.lowercased().precomposedStringWithCanonicalMapping

        for character in domain where character.isWhitespace || character == "@" || character == "/" {
            throw ParseError.forbiddenCharacter(part: "domainpart", character: character)
        }

        let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
        for label in labels {
            guard !label.isEmpty else { throw ParseError.invalidDomain("empty label") }
            guard label.utf8.count <= 63 else { throw ParseError.invalidDomain("label > 63 bytes") }
            guard label.first != "-", label.last != "-" else {
                throw ParseError.invalidDomain("label '\(label)' starts or ends with '-'")
            }
            // An A-label must decode; a U-label must not look like one.
            if label.lowercased().hasPrefix(Punycode.acePrefix) {
                guard (try? Punycode.decode(label: String(label))) != nil else {
                    throw ParseError.invalidDomain("undecodable A-label '\(label)'")
                }
            }
            for scalar in label.unicodeScalars where !isDomainScalar(scalar) {
                throw ParseError.invalidDomain(
                    "label '\(label)' contains U+\(String(scalar.value, radix: 16, uppercase: true))")
            }
            // Non-ASCII labels must also survive A-label encoding.
            if label.unicodeScalars.contains(where: { !$0.isASCII }) {
                _ = try Punycode.encode(label: String(label))
            }
        }
        return domain
    }

    private static func isDomainScalar(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.isASCII {
            switch scalar {
            case "a"..."z", "0"..."9", "-", "_": return true
            default: return false
            }
        }
        // Non-ASCII: IDNA2008 PVALID is approximated by letters, digits and marks.
        switch scalar.properties.generalCategory {
        case .lowercaseLetter, .otherLetter, .modifierLetter, .decimalNumber,
             .nonspacingMark, .spacingMark:
            return true
        default:
            return false
        }
    }
}

extension JID: Comparable {
    /// Lexicographic by string form, so JID-keyed UI lists sort stably.
    public static func < (lhs: JID, rhs: JID) -> Bool {
        lhs.description < rhs.description
    }
}
