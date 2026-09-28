import Foundation
import CLibXML2

/// What the framing layer hands up to the stream state machine.
public enum StreamEvent: Sendable, Hashable {
    /// The opening `<stream:stream>` tag. Attributes only — its children are
    /// reported separately as they complete.
    case streamOpen(Element)
    /// A complete top-level stanza (depth 1 inside the stream element).
    case stanza(Element)
    /// The peer's closing `</stream:stream>`.
    case streamClose
}

public struct XMLError: Error, Sendable, Equatable, CustomStringConvertible {
    public enum Kind: Sendable, Equatable {
        case notWellFormed
        case doctypeForbidden
        case depthLimitExceeded
        case sizeLimitExceeded
        case unexpectedSecondRoot
    }
    public let kind: Kind
    public let detail: String

    public var description: String { "\(kind): \(detail)" }
}

/// Incremental XMPP stream reader.
///
/// Wraps the libxml2 SAX push parser. An XMPP stream is not a well-formed
/// document while it is open — the root tag stays unclosed for the lifetime of
/// the session — so a push parser that emits events as elements complete is the
/// only workable shape. Depth-1 elements are emitted as stanzas and dropped, so
/// memory stays flat no matter how long the session runs.
///
/// Not `Sendable`: hold one per connection inside the owning actor.
public final class StreamParser {

    public struct Limits: Sendable {
        /// Largest permitted top-level stanza. RFC 6120 has no limit; servers
        /// commonly cap around 256 KiB–1 MiB.
        public var maxStanzaBytes: Int
        /// Nesting cap inside a stanza, guarding pathological trees.
        public var maxDepth: Int
        /// Cap on children of a single element, guarding wide trees.
        public var maxChildren: Int
        /// Cap on elements in one stanza. The byte cap alone admits about a
        /// quarter of a million `<a/>`s — measured at 16 MB of tree, most of a
        /// notification extension's memory. 65,536 is about 4 MB, and more
        /// than a roster of thousands needs.
        public var maxElements: Int

        public init(maxStanzaBytes: Int = 1 << 20, maxDepth: Int = 64, maxChildren: Int = 8192,
                    maxElements: Int = 65_536) {
            self.maxStanzaBytes = maxStanzaBytes
            self.maxDepth = maxDepth
            self.maxChildren = maxChildren
            self.maxElements = maxElements
        }
    }

    public let limits: Limits

    private var context: xmlParserCtxtPtr?
    private var handler = xmlSAXHandler()

    /// Builder stack. Index 0 is the stream element; depth-1 elements and deeper
    /// are assembled here and detached when they close.
    private var stack: [Element] = []
    private var events: [StreamEvent] = []
    private var failure: XMLError?
    /// Bytes fed since the last top-level boundary, for the stanza size cap.
    private var bytesSinceBoundary = 0
    /// Elements opened since the last top-level boundary.
    private var elementsSinceBoundary = 0
    private var sawRoot = false
    private var closed = false

    public init(limits: Limits = Limits()) {
        self.limits = limits
        makeContext()
    }

    deinit {
        if let context { xmlFreeParserCtxt(context) }
    }

    /// Discards parser state for a stream restart (after TLS or SASL) or a new
    /// connection. Cheaper and safer than allocating a new `StreamParser`
    /// because limits and callbacks stay identical.
    public func reset() {
        if let context { xmlFreeParserCtxt(context) }
        context = nil
        stack.removeAll(keepingCapacity: true)
        events.removeAll(keepingCapacity: true)
        failure = nil
        bytesSinceBoundary = 0
        elementsSinceBoundary = 0
        sawRoot = false
        closed = false
        makeContext()
    }

    /// Feeds bytes from the transport and returns whatever completed.
    ///
    /// Throws on anything that makes the stream unusable; the caller must then
    /// tear the connection down (RFC 6120 §4.9.3.13 `bad-format`).
    @discardableResult
    public func parse(_ bytes: some Collection<UInt8>) throws -> [StreamEvent] {
        guard let context else {
            throw XMLError(kind: .notWellFormed, detail: "parser context unavailable")
        }
        guard !bytes.isEmpty else {
            defer { events.removeAll(keepingCapacity: true) }
            return events
        }

        bytesSinceBoundary += bytes.count
        if bytesSinceBoundary > limits.maxStanzaBytes {
            throw XMLError(kind: .sizeLimitExceeded,
                           detail: "no stanza boundary within \(limits.maxStanzaBytes) bytes")
        }

        let buffer = Array(bytes)
        let status = buffer.withUnsafeBytes { raw -> Int32 in
            xmlParseChunk(context,
                          raw.baseAddress?.assumingMemoryBound(to: CChar.self),
                          Int32(raw.count),
                          0)
        }

        if let failure {
            self.failure = nil
            throw failure
        }
        if status != 0 {
            throw XMLError(kind: .notWellFormed, detail: "libxml2 error \(status)")
        }

        defer { events.removeAll(keepingCapacity: true) }
        return events
    }

    /// True once the peer's closing tag has been seen.
    public var isClosed: Bool { closed }

    // MARK: - libxml2 wiring

    private func makeContext() {
        memset(&handler, 0, MemoryLayout<xmlSAXHandler>.size)
        // Required for libxml2 to take the namespace-aware SAX2 code path.
        handler.initialized = XML_SAX2_MAGIC

        handler.startElementNs = { ctx, localname, _, uri, _, _, attributeCount, _, attributes in
            StreamParser.from(ctx)?.startElement(localname, uri, attributeCount, attributes)
        }
        handler.endElementNs = { ctx, _, _, _ in
            StreamParser.from(ctx)?.endElement()
        }
        handler.characters = { ctx, chars, length in
            StreamParser.from(ctx)?.characters(chars, length)
        }
        handler.cdataBlock = { ctx, chars, length in
            StreamParser.from(ctx)?.characters(chars, length)
        }
        // A DTD in an XMPP stream is always an attack, never a feature
        // (RFC 6120 §11.1 forbids them). Kill the stream on sight, which also
        // makes entity-expansion bombs unreachable: without a DTD no entity
        // beyond the five predefined ones can be declared.
        handler.internalSubset = { ctx, _, _, _ in
            StreamParser.from(ctx)?.fail(.doctypeForbidden, "internal DTD subset")
        }
        handler.externalSubset = { ctx, _, _, _ in
            StreamParser.from(ctx)?.fail(.doctypeForbidden, "external DTD subset")
        }
        handler.processingInstruction = { ctx, _, _ in
            StreamParser.from(ctx)?.fail(.notWellFormed, "processing instruction")
        }

        let userData = Unmanaged.passUnretained(self).toOpaque()
        context = xmlCreatePushParserCtxt(&handler, userData, nil, 0, nil)
        if let context {
            // Never fetch external resources; never substitute entities.
            xmlCtxtUseOptions(context, Int32(XML_PARSE_NONET.rawValue | XML_PARSE_NOCDATA.rawValue))
            context.pointee.replaceEntities = 0
        }
    }

    private static func from(_ ctx: UnsafeMutableRawPointer?) -> StreamParser? {
        guard let ctx else { return nil }
        return Unmanaged<StreamParser>.fromOpaque(ctx).takeUnretainedValue()
    }

    private func fail(_ kind: XMLError.Kind, _ detail: String) {
        guard failure == nil else { return }
        failure = XMLError(kind: kind, detail: detail)
        if let context { xmlStopParser(context) }
    }

    // MARK: - SAX callbacks

    private func startElement(
        _ localname: UnsafePointer<xmlChar>?,
        _ uri: UnsafePointer<xmlChar>?,
        _ attributeCount: Int32,
        _ attributes: UnsafeMutablePointer<UnsafePointer<xmlChar>?>?
    ) {
        guard failure == nil, let localname else { return }
        if stack.count >= limits.maxDepth {
            return fail(.depthLimitExceeded, "depth > \(limits.maxDepth)")
        }
        elementsSinceBoundary += 1
        if elementsSinceBoundary > limits.maxElements {
            return fail(.sizeLimitExceeded, "more than \(limits.maxElements) elements in a stanza")
        }

        let element = Element(
            name: Self.string(localname),
            namespaceURI: uri.map(Self.string),
            attributes: Self.attributes(attributeCount, attributes)
        )

        if stack.isEmpty {
            if sawRoot {
                // libxml2 would report this itself, but a clear error beats
                // "Extra content at the end of the document".
                return fail(.unexpectedSecondRoot, "second root element <\(element.name)>")
            }
            sawRoot = true
            events.append(.streamOpen(element))
            // The stream element is pushed as a sentinel only; depth-1 children
            // are never attached to it.
            stack.append(Element(name: element.name, namespaceURI: element.namespaceURI))
        } else {
            stack.append(element)
        }
    }

    private func endElement() {
        guard failure == nil, !stack.isEmpty else { return }
        let finished = stack.removeLast()

        if stack.isEmpty {
            closed = true
            events.append(.streamClose)
            bytesSinceBoundary = 0
            elementsSinceBoundary = 0
            return
        }

        if stack.count == 1 {
            events.append(.stanza(finished))
            bytesSinceBoundary = 0
            elementsSinceBoundary = 0
        } else {
            if stack[stack.count - 1].children.count >= limits.maxChildren {
                return fail(.depthLimitExceeded, "more than \(limits.maxChildren) children")
            }
            stack[stack.count - 1].addChild(finished)
        }
    }

    private func characters(_ chars: UnsafePointer<xmlChar>?, _ length: Int32) {
        guard failure == nil, let chars, length > 0 else { return }
        // Character data directly inside <stream:stream> is whitespace
        // keepalive; anything else there is not ours to interpret.
        guard stack.count >= 2 else { return }
        let text = Self.string(chars, count: Int(length))
        stack[stack.count - 1].addText(text)
    }

    // MARK: - Byte helpers

    private static func string(_ pointer: UnsafePointer<xmlChar>) -> String {
        String(cString: pointer)
    }

    private static func string(_ pointer: UnsafePointer<xmlChar>, count: Int) -> String {
        let buffer = UnsafeBufferPointer(start: pointer, count: count)
        return String(decoding: buffer, as: UTF8.self)
    }

    /// Without entity substitution libxml2 hands an escaped `&` in an
    /// attribute back as the reference `&#38;` (the other predefined entities
    /// arrive decoded). A literal `&` cannot occur in a well-formed value, so
    /// every `&` here starts that reference. Replaced as bytes: as a `String`,
    /// a combining mark after the `;` would hide the match inside a grapheme.
    private static func attributeValue(_ pointer: UnsafePointer<xmlChar>, count: Int) -> String {
        let buffer = UnsafeBufferPointer(start: pointer, count: count)
        guard buffer.contains(UInt8(ascii: "&")) else { return String(decoding: buffer, as: UTF8.self) }
        let reference = Array("&#38;".utf8)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(count)
        var index = 0
        while index < count {
            if buffer[index] == UInt8(ascii: "&"), count - index >= reference.count,
               buffer[index..<(index + reference.count)].elementsEqual(reference) {
                bytes.append(UInt8(ascii: "&"))
                index += reference.count
            } else {
                bytes.append(buffer[index])
                index += 1
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// libxml2 hands attributes over as 5 pointers each:
    /// localname, prefix, namespace URI, value start, value end.
    private static func attributes(
        _ count: Int32,
        _ raw: UnsafeMutablePointer<UnsafePointer<xmlChar>?>?
    ) -> [String: String] {
        guard count > 0, let raw else { return [:] }
        var result: [String: String] = [:]
        result.reserveCapacity(Int(count))
        for index in 0..<Int(count) {
            let base = index * 5
            guard let localname = raw[base] else { continue }
            let prefix = raw[base + 1].map(string)
            guard let valueStart = raw[base + 3], let valueEnd = raw[base + 4] else { continue }
            let length = valueEnd - valueStart
            let value = length > 0 ? attributeValue(valueStart, count: length) : ""
            let local = string(localname)
            result[prefix.map { "\($0):\(local)" } ?? local] = value
            // Keep the declaration of any prefix other than `xml`, so the
            // element serializes back to well-formed XML (bookmark
            // extensions are republished verbatim).
            if let prefix, prefix != "xml", let uri = raw[base + 2] {
                result["xmlns:\(prefix)"] = string(uri)
            }
        }
        return result
    }
}
