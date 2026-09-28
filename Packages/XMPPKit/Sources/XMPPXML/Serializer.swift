import Foundation

/// Turns `Element` trees back into XML text.
///
/// Namespaces are re-declared from each element's `namespaceURI`: an element
/// whose namespace differs from the one inherited from its parent emits a default
/// `xmlns`. That produces prefix-free output, which every XMPP implementation
/// accepts, and keeps the serializer free of prefix bookkeeping.
public enum Serializer {

    /// Serializes `element`, assuming the reader is already inside a scope whose
    /// default namespace is `inheritedNamespace`.
    public static func string(for element: Element, inheritedNamespace: String? = nil) -> String {
        var out = ""
        append(element, inheritedNamespace: inheritedNamespace, to: &out)
        return out
    }

    private static func append(_ element: Element, inheritedNamespace: String?, to out: inout String) {
        out += "<"
        out += element.name

        if element.namespaceURI != inheritedNamespace {
            out += " xmlns='"
            out += escapeAttribute(element.namespaceURI ?? "")
            out += "'"
        }

        // Sorted so output is deterministic (tests, XML console diffing).
        for key in element.attributes.keys.sorted() {
            out += " "
            out += key
            out += "='"
            out += escapeAttribute(element.attributes[key]!)
            out += "'"
        }

        if element.children.isEmpty {
            out += "/>"
            return
        }

        out += ">"
        for child in element.children {
            switch child {
            case .text(let s): out += escapeText(s)
            case .element(let e): append(e, inheritedNamespace: element.namespaceURI, to: &out)
            }
        }
        out += "</"
        out += element.name
        out += ">"
    }

    // MARK: - Escaping

    /// Escapes character data. `>` is escaped too: it is only required inside
    /// `]]>`, but escaping it unconditionally is cheaper than detecting that.
    ///
    /// Characters XML 1.0 does not allow at all (most C0 controls, U+FFFE,
    /// U+FFFF) are dropped: no escape makes them legal, and one pasted into a
    /// message would otherwise earn a stream error — and, replayed by XEP-0198
    /// after the reconnect, another one, indefinitely.
    public static func escapeText(_ string: String) -> String {
        var out = ""
        out.reserveCapacity(string.utf8.count)
        for scalar in string.unicodeScalars where isAllowed(scalar) {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\r": out += "&#xD;"
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    /// Escapes an attribute value. Tab, LF and CR must be escaped or they are
    /// normalized to spaces by a conforming parser.
    public static func escapeAttribute(_ string: String) -> String {
        var out = ""
        out.reserveCapacity(string.utf8.count)
        for scalar in string.unicodeScalars where isAllowed(scalar) {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "'": out += "&apos;"
            case "\"": out += "&quot;"
            case "\t": out += "&#x9;"
            case "\n": out += "&#xA;"
            case "\r": out += "&#xD;"
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    /// XML 1.0 §2.2 `Char`. Swift strings cannot hold surrogates, so only the
    /// controls and the two noncharacters at the end of the BMP remain.
    static func isAllowed(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x9, 0xA, 0xD: true
        case 0x0..<0x20: false
        case 0xFFFE, 0xFFFF: false
        default: true
        }
    }

    // MARK: - Stream framing

    /// The opening `<stream:stream>` tag. Unbalanced by design: the closing tag
    /// is only sent at the end of the session.
    ///
    /// No XML declaration is emitted. RFC 6120 §11.5 permits one at the very
    /// start of a stream only, and emitting one mid-stream (after a TLS or SASL
    /// restart) is a protocol violation, so we never emit one at all.
    public static func streamOpen(
        to domain: String,
        from: String? = nil,
        defaultNamespace: String = Namespaces.client,
        version: String = "1.0",
        lang: String? = "en"
    ) -> String {
        var out = "<stream:stream"
        if let from { out += " from='\(escapeAttribute(from))'" }
        out += " to='\(escapeAttribute(domain))'"
        out += " version='\(escapeAttribute(version))'"
        if let lang { out += " xml:lang='\(escapeAttribute(lang))'" }
        out += " xmlns='\(escapeAttribute(defaultNamespace))'"
        out += " xmlns:stream='\(escapeAttribute(Namespaces.stream))'"
        out += ">"
        return out
    }

    public static let streamClose = "</stream:stream>"
}
