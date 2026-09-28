import Foundation

/// A node in an XML tree: either a child element or a run of character data.
public enum Node: Sendable, Hashable {
    case element(Element)
    case text(String)
}

/// An immutable, namespace-aware XML element.
///
/// XMPP only needs a small slice of XML: elements, attributes, character data.
/// Comments, processing instructions and DTDs are rejected by the parser and are
/// therefore not representable here.
public struct Element: Sendable, Hashable {
    /// Local name, never prefixed.
    public var name: String
    /// Resolved namespace URI, or `nil` for an element in no namespace.
    public var namespaceURI: String?
    /// Attributes keyed by qualified name (`id`, `xml:lang`, …). Namespace
    /// declarations are not stored; they are regenerated on serialization.
    public var attributes: [String: String]
    public var children: [Node]

    public init(
        name: String,
        namespaceURI: String? = nil,
        attributes: [String: String] = [:],
        children: [Node] = []
    ) {
        self.name = name
        self.namespaceURI = namespaceURI
        self.attributes = attributes
        self.children = children
    }

    /// Convenience initializer for a leaf element holding character data.
    public init(
        name: String,
        namespaceURI: String? = nil,
        attributes: [String: String] = [:],
        text: String
    ) {
        self.init(name: name, namespaceURI: namespaceURI, attributes: attributes,
                  children: text.isEmpty ? [] : [.text(text)])
    }

    // MARK: - Attributes

    public subscript(attribute: String) -> String? {
        get { attributes[attribute] }
        set {
            if let newValue { attributes[attribute] = newValue }
            else { attributes.removeValue(forKey: attribute) }
        }
    }

    /// `xml:lang`, if present on this element.
    public var lang: String? {
        get { attributes["xml:lang"] }
        set { self["xml:lang"] = newValue }
    }

    // MARK: - Content

    /// All character data in this element, concatenated (child elements skipped).
    public var text: String {
        var out = ""
        for case .text(let s) in children { out += s }
        return out
    }

    public var elements: [Element] {
        children.compactMap { if case .element(let e) = $0 { return e } else { return nil } }
    }

    /// First child element matching the given name and/or namespace.
    /// A `nil` criterion matches anything.
    public func firstChild(name: String? = nil, namespaceURI: String? = nil) -> Element? {
        for case .element(let e) in children where e.matches(name: name, namespaceURI: namespaceURI) {
            return e
        }
        return nil
    }

    public func childElements(name: String? = nil, namespaceURI: String? = nil) -> [Element] {
        elements.filter { $0.matches(name: name, namespaceURI: namespaceURI) }
    }

    public func matches(name: String? = nil, namespaceURI: String? = nil) -> Bool {
        if let name, name != self.name { return false }
        if let namespaceURI, namespaceURI != self.namespaceURI { return false }
        return true
    }

    // MARK: - Mutation

    public mutating func addChild(_ element: Element) {
        children.append(.element(element))
    }

    /// Appends character data, merging with a trailing text node so that a
    /// value split across parser callbacks or transport reads produces the same
    /// tree as one delivered whole — equality and hashing depend on it.
    public mutating func addText(_ string: String) {
        guard !string.isEmpty else { return }
        if case .text(let existing) = children.last {
            children[children.count - 1] = .text(existing + string)
        } else {
            children.append(.text(string))
        }
    }

    /// Returns a copy with `element` appended, so trees can be built inline.
    public func adding(_ element: Element) -> Element {
        var copy = self
        copy.addChild(element)
        return copy
    }

    /// Removes every descendant matching the criteria, one level deep.
    public mutating func removeChildren(name: String? = nil, namespaceURI: String? = nil) {
        children.removeAll { node in
            guard case .element(let e) = node else { return false }
            return e.matches(name: name, namespaceURI: namespaceURI)
        }
    }

    /// Serialized form; `nil` inherited namespace means every namespace is declared.
    public var xmlString: String {
        Serializer.string(for: self)
    }
}

extension Element: CustomStringConvertible {
    public var description: String { xmlString }
}

extension Element {
    /// Parses one element from its serialized form (`xmlString`), with the
    /// same hardening as the stream parser. For XML a client stored itself,
    /// such as another client's bookmark extensions.
    public init(xmlFragment: String) throws {
        let parser = StreamParser()
        let open = "<stream:stream xmlns='jabber:client' xmlns:stream='http://etherx.jabber.org/streams'>"
        _ = try parser.parse(Array(open.utf8))
        let events = try parser.parse(Array(xmlFragment.utf8))
        guard events.count == 1, case .stanza(let element) = events[0] else {
            throw XMLError(kind: .notWellFormed, detail: "expected exactly one element")
        }
        self = element
    }
}
