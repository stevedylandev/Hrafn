import Foundation

/// The XMPP-specific identities in a certificate's subjectAltName: SRV-IDs
/// (RFC 4985) and `id-on-xmppAddr` (RFC 6120 §13.7.1.4).
///
/// The Security framework checks DNS-IDs itself but, on iOS, exposes nothing
/// else of a certificate, so the extension is read here with a minimal DER
/// reader written from X.690 and the RFC 5280 ASN.1 module. Everything a
/// server sends is untrusted: any structural surprise yields no identities
/// rather than an error, and the certificate is then judged on its DNS-IDs
/// alone.
public struct CertificateIdentity: Sendable, Equatable {
    /// `SRVName` values, e.g. `_xmpp-client.example.com`, as written.
    public var srvNames: [String] = []
    /// `id-on-xmppAddr` values, e.g. `example.com`, as written.
    public var xmppAddrs: [String] = []

    public init(srvNames: [String] = [], xmppAddrs: [String] = []) {
        self.srvNames = srvNames
        self.xmppAddrs = xmppAddrs
    }

    /// Reads the identities from a DER-encoded X.509 certificate.
    public init(der: Data) {
        guard let names = try? Self.generalNames(in: Array(der)) else { return }
        for name in names {
            // otherName [0] { type-id OID, value [0] EXPLICIT ANY }
            guard name.tag == 0xA0 else { continue }
            var reader = DERReader(name.content)
            guard let typeID = try? reader.read(tag: 0x06),
                  let wrapper = try? reader.read(tag: 0xA0) else { continue }
            var inner = DERReader(wrapper.content)
            guard let value = try? inner.next() else { continue }
            switch Array(typeID.content) {
            case Self.oidSRVName where value.tag == 0x16:            // IA5String
                if let text = String(bytes: value.content, encoding: .ascii) { srvNames.append(text) }
            case Self.oidXMPPAddr where value.tag == 0x0C:           // UTF8String
                if let text = String(bytes: value.content, encoding: .utf8) { xmppAddrs.append(text) }
            default:
                continue
            }
        }
    }

    /// True when an SRV-ID or xmppAddr names `domain` for client service.
    ///
    /// `domain` is the A-label form of the XMPP domain. SRV-IDs carry
    /// A-labels (RFC 4985 §2); xmppAddrs may carry U-labels, so they are
    /// compared after the same conversion. ASCII case never matters.
    public func matches(domain: String, xmppAddrToALabel: (String) -> String? = { $0 }) -> Bool {
        let domain = domain.lowercased()
        for name in srvNames {
            let lower = name.lowercased()
            // RFC 6120 §13.7.1.2.1 names `_xmpp-client`; XEP-0368 servers
            // may present `_xmpps-client`. Wildcards are not allowed in SRV-IDs.
            for service in ["_xmpp-client.", "_xmpps-client."] where lower == service + domain {
                return true
            }
        }
        for addr in xmppAddrs {
            if let converted = xmppAddrToALabel(addr), converted.lowercased() == domain { return true }
        }
        return false
    }

    // MARK: - Certificate structure

    // 1.3.6.1.5.5.7.8.7 and 1.3.6.1.5.5.7.8.5, content octets only.
    static let oidSRVName: [UInt8] = [0x2B, 0x06, 0x01, 0x05, 0x05, 0x07, 0x08, 0x07]
    static let oidXMPPAddr: [UInt8] = [0x2B, 0x06, 0x01, 0x05, 0x05, 0x07, 0x08, 0x05]
    // 2.5.29.17
    static let oidSubjectAltName: [UInt8] = [0x55, 0x1D, 0x11]

    /// The GeneralNames of the subjectAltName extension, or none.
    static func generalNames(in der: [UInt8]) throws -> [DERReader.Value] {
        var outer = DERReader(der[...])
        let certificate = try outer.read(tag: 0x30)
        var certificateFields = DERReader(certificate.content)
        let tbs = try certificateFields.read(tag: 0x30)

        // TBSCertificate: [0] version?, serial, signature, issuer, validity,
        // subject, subjectPublicKeyInfo, [1]?, [2]?, [3] extensions?
        var fields = DERReader(tbs.content)
        while !fields.isAtEnd {
            let field = try fields.next()
            guard field.tag == 0xA3 else { continue }
            var wrapper = DERReader(field.content)
            let extensions = try wrapper.read(tag: 0x30)
            var list = DERReader(extensions.content)
            while !list.isAtEnd {
                // Extension ::= SEQUENCE { extnID, critical BOOLEAN DEFAULT FALSE, extnValue OCTET STRING }
                let ext = try list.read(tag: 0x30)
                var parts = DERReader(ext.content)
                let oid = try parts.read(tag: 0x06)
                guard Array(oid.content) == oidSubjectAltName else { continue }
                var value = try parts.next()
                if value.tag == 0x01 { value = try parts.next() }
                guard value.tag == 0x04 else { throw DERReader.Failure.malformed }
                var octets = DERReader(value.content)
                let sequence = try octets.read(tag: 0x30)
                var names = DERReader(sequence.content)
                var result: [DERReader.Value] = []
                while !names.isAtEnd { result.append(try names.next()) }
                return result
            }
        }
        return []
    }
}

/// Reads DER TLVs. Definite lengths only, as DER requires; single-byte tags
/// only, which is all X.509 uses. Never traps on hostile input.
struct DERReader {
    enum Failure: Error { case malformed }

    struct Value {
        let tag: UInt8
        let content: ArraySlice<UInt8>
    }

    private var bytes: ArraySlice<UInt8>

    init(_ bytes: ArraySlice<UInt8>) { self.bytes = bytes }

    var isAtEnd: Bool { bytes.isEmpty }

    mutating func next() throws -> Value {
        guard let tag = bytes.first else { throw Failure.malformed }
        // High-tag-number form (low five bits all set) is not used in X.509.
        guard tag & 0x1F != 0x1F else { throw Failure.malformed }
        var index = bytes.index(after: bytes.startIndex)
        guard index < bytes.endIndex else { throw Failure.malformed }
        let first = bytes[index]
        index += 1

        var length = 0
        if first & 0x80 == 0 {
            length = Int(first)
        } else {
            let count = Int(first & 0x7F)
            // 0 would be BER's indefinite form; more than 4 bytes of length
            // cannot describe a certificate.
            guard (1...4).contains(count), bytes.endIndex - index >= count else { throw Failure.malformed }
            for _ in 0..<count {
                length = (length << 8) | Int(bytes[index])
                index += 1
            }
        }
        guard length <= bytes.endIndex - index else { throw Failure.malformed }
        let content = bytes[index..<(index + length)]
        bytes = bytes[(index + length)...]
        return Value(tag: tag, content: content)
    }

    mutating func read(tag: UInt8) throws -> Value {
        let value = try next()
        guard value.tag == tag else { throw Failure.malformed }
        return value
    }
}
