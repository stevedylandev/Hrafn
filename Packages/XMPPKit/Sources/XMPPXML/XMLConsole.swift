import Foundation

/// Which way a chunk of XML was travelling.
public enum XMLDirection: Sendable, Hashable {
    case sent
    case received

    public var arrow: String { self == .sent ? "»" : "«" }
}

/// Sink for the debug XML console.
public protocol XMLConsole: Sendable {
    func log(_ direction: XMLDirection, _ xml: String)
}

/// Removes credentials before XML reaches a log.
///
/// SASL exchanges carry the password (PLAIN) or material derived from it
/// (SCRAM), so their character data is replaced wholesale. Redaction is textual
/// on purpose: it runs over raw bytes before parsing, so it still applies to
/// stanzas the parser rejects.
public struct RedactingXMLConsole: XMLConsole {
    /// Elements whose character data is never logged.
    public static let sensitiveElements = [
        "auth", "response", "challenge", "success",   // urn:ietf:params:xml:ns:xmpp-sasl
        "initial-response", "additional-data",        // XEP-0388 SASL2
        "password",                                   // XEP-0077 registration
        "token", "secret",                            // XEP-0484 FAST
    ]

    /// Attributes whose values are never logged: XEP-0484 hands the token
    /// over as `<token token='…'/>`.
    public static let sensitiveAttributes = ["token"]

    private let underlying: any XMLConsole

    public init(_ underlying: any XMLConsole) {
        self.underlying = underlying
    }

    public func log(_ direction: XMLDirection, _ xml: String) {
        underlying.log(direction, Self.redact(xml))
    }

    public static func redact(_ xml: String) -> String {
        var output = xml
        for name in sensitiveElements {
            output = replaceContent(in: output, element: name)
        }
        for name in sensitiveAttributes {
            output = replaceAttribute(in: output, attribute: name)
        }
        return output
    }

    /// Replaces the value of ` name='…'` / ` name="…"` everywhere.
    private static func replaceAttribute(in xml: String, attribute name: String) -> String {
        var output = ""
        var rest = Substring(xml)
        while let found = rest.range(of: " \(name)=") {
            output += rest[..<found.upperBound]
            rest = rest[found.upperBound...]
            guard let quote = rest.first, quote == "'" || quote == "\"" else { continue }
            let value = rest.dropFirst()
            guard let close = value.firstIndex(of: quote) else { break }
            output += "\(quote)[redacted]\(quote)"
            rest = value[value.index(after: close)...]
        }
        return output + rest
    }

    /// Replaces the content of `<name …>…</name>` with a placeholder, leaving
    /// attributes (`mechanism`, for instance) intact because they are diagnostic
    /// and carry no secret.
    private static func replaceContent(in xml: String, element name: String) -> String {
        let openMarker = "<\(name)"
        let closeMarker = "</\(name)>"
        var output = ""
        var rest = Substring(xml)

        while let open = rest.range(of: openMarker) {
            let afterName = rest[open.upperBound...]
            // Guard against matching a longer name, e.g. <passwordPolicy>.
            guard let boundary = afterName.first,
                  ">/ \t\n\r".contains(boundary) else {
                output += rest[..<open.upperBound]
                rest = afterName
                continue
            }
            guard let tagEnd = afterName.firstIndex(of: ">") else { break }

            // Attributes are diagnostic (`mechanism`, `xmlns`) and hold no secret.
            let tagRemainder = afterName[..<tagEnd]
            output += rest[..<open.lowerBound]
            output += openMarker + tagRemainder + ">"
            rest = afterName[afterName.index(after: tagEnd)...]

            if tagRemainder.hasSuffix("/") { continue }   // empty element

            if let close = rest.range(of: closeMarker) {
                let content = rest[..<close.lowerBound]
                if !content.isEmpty { output += "[redacted \(content.count) chars]" }
                output += closeMarker
                rest = rest[close.upperBound...]
            }
        }
        output += rest
        return output
    }
}

/// Prints to standard output. Debug builds only.
public struct PrintXMLConsole: XMLConsole {
    public init() {}

    public func log(_ direction: XMLDirection, _ xml: String) {
        print("\(direction.arrow) \(xml)")
    }
}

/// Keeps the last `capacity` lines for a debug screen in the app.
public final class RingBufferXMLConsole: XMLConsole, @unchecked Sendable {
    public struct Entry: Sendable, Hashable {
        public let direction: XMLDirection
        public let xml: String
        public let timestamp: Date
    }

    private let lock = NSLock()
    private let capacity: Int
    private var storage: [Entry] = []

    public init(capacity: Int = 500) {
        self.capacity = capacity
    }

    public func log(_ direction: XMLDirection, _ xml: String) {
        lock.withLock {
            storage.append(Entry(direction: direction, xml: xml, timestamp: Date()))
            if storage.count > capacity { storage.removeFirst(storage.count - capacity) }
        }
    }

    public var entries: [Entry] { lock.withLock { storage } }

    public func clear() { lock.withLock { storage.removeAll() } }
}
