import Foundation
import CryptoKit
import XMPPCore
import XMPPXML

extension Namespaces {
    public static let discoInfo = "http://jabber.org/protocol/disco#info"
    public static let discoItems = "http://jabber.org/protocol/disco#items"
    public static let caps = "http://jabber.org/protocol/caps"
    public static let ping = "urn:xmpp:ping"
}

/// XEP-0030 `disco#info`: who an entity is and what it supports, with the
/// XEP-0128 extension forms.
public struct DiscoInfo: Sendable, Hashable {
    public struct Identity: Sendable, Hashable {
        public var category: String
        public var type: String
        public var name: String?
        public var lang: String?

        public init(category: String, type: String, name: String? = nil, lang: String? = nil) {
            self.category = category
            self.type = type
            self.name = name
            self.lang = lang
        }
    }

    public var identities: [Identity]
    public var features: [String]
    public var forms: [DataForm]

    public init(identities: [Identity], features: [String], forms: [DataForm] = []) {
        self.identities = identities
        self.features = features
        self.forms = forms
    }

    public init(query: Element) {
        identities = query.childElements(name: "identity", namespaceURI: Namespaces.discoInfo).compactMap { e in
            guard let category = e["category"], let type = e["type"] else { return nil }
            return Identity(category: category, type: type, name: e["name"], lang: e.lang)
        }
        features = query.childElements(name: "feature", namespaceURI: Namespaces.discoInfo).compactMap { $0["var"] }
        forms = query.childElements(name: "x", namespaceURI: Namespaces.dataForms).compactMap(DataForm.init(element:))
    }

    public func supports(_ feature: String) -> Bool {
        features.contains(feature)
    }

    public func query(node: String? = nil) -> Element {
        var query = Element(name: "query", namespaceURI: Namespaces.discoInfo)
        query["node"] = node
        for identity in identities {
            var e = Element(name: "identity", namespaceURI: Namespaces.discoInfo,
                            attributes: ["category": identity.category, "type": identity.type])
            e["name"] = identity.name
            e.lang = identity.lang
            query.addChild(e)
        }
        for feature in features {
            query.addChild(Element(name: "feature", namespaceURI: Namespaces.discoInfo, attributes: ["var": feature]))
        }
        for form in forms { query.addChild(form.element) }
        return query
    }
}

public struct DiscoItems: Sendable, Hashable {
    public struct Item: Sendable, Hashable {
        public var jid: JID
        public var node: String?
        public var name: String?
    }

    public var items: [Item]

    public init(query: Element) {
        items = query.childElements(name: "item", namespaceURI: Namespaces.discoItems).compactMap { e in
            guard let jid = e["jid"].flatMap({ try? JID($0) }) else { return nil }
            return Item(jid: jid, node: e["node"], name: e["name"])
        }
    }
}

// MARK: - XEP-0115 verification string

extension DiscoInfo {

    public enum CapsError: Error, Sendable, Equatable {
        /// §5.4: duplicate identities, features or form types make the
        /// advertised hash unverifiable, so the entity's caps must be ignored.
        case duplicateIdentity
        case duplicateFeature
        case duplicateFormType
        case formTypeNotHidden
    }

    /// The XEP-0115 §5.1 `ver` string: SHA-1 over the sorted identities,
    /// features and extension forms, base64-encoded.
    public func capsVerification() throws -> String {
        Data(Insecure.SHA1.hash(data: Data(try capsVerificationInput().utf8))).base64EncodedString()
    }

    /// The string `capsVerification()` hashes; exposed so tests can compare it
    /// with the XEP's worked examples.
    func capsVerificationInput() throws -> String {
        let identityStrings = identities.map {
            "\($0.category)/\($0.type)/\($0.lang ?? "")/\($0.name ?? "")"
        }
        guard Set(identityStrings).count == identityStrings.count else { throw CapsError.duplicateIdentity }
        guard Set(features).count == features.count else { throw CapsError.duplicateFeature }

        var input = ""
        // §5.1: identities by category, type, lang, then name.
        for identity in identities.sorted(by: Self.identityOrder) {
            input += "\(identity.category)/\(identity.type)/\(identity.lang ?? "")/\(identity.name ?? "")<"
        }
        for feature in features.sorted(by: Self.octetOrder) {
            input += "\(feature)<"
        }

        // §5.4: forms without a FORM_TYPE are ignored; duplicate FORM_TYPEs and
        // a FORM_TYPE that is not hidden make the whole result invalid.
        let typedForms = forms.filter { $0.formType != nil }
        let formTypes = typedForms.compactMap(\.formType)
        guard Set(formTypes).count == formTypes.count else { throw CapsError.duplicateFormType }
        for form in typedForms {
            if let type = form.fields.first(where: { $0.variable == "FORM_TYPE" })?.type, type != "hidden" {
                throw CapsError.formTypeNotHidden
            }
        }

        for form in typedForms.sorted(by: { Self.octetOrder($0.formType!, $1.formType!) }) {
            input += "\(form.formType!)<"
            let fields = form.fields
                .filter { $0.variable != nil && $0.variable != "FORM_TYPE" }
                .sorted { Self.octetOrder($0.variable!, $1.variable!) }
            for field in fields {
                input += "\(field.variable!)<"
                for value in field.values.sorted(by: Self.octetOrder) { input += "\(value)<" }
            }
        }
        return input
    }

    /// "i;octet" collation (RFC 4790), which §5.1 specifies. Swift's `<` on
    /// `String` compares by Unicode canonical ordering, not by bytes.
    static func octetOrder(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
    }

    private static func identityOrder(_ lhs: Identity, _ rhs: Identity) -> Bool {
        let l = [lhs.category, lhs.type, lhs.lang ?? "", lhs.name ?? ""]
        let r = [rhs.category, rhs.type, rhs.lang ?? "", rhs.name ?? ""]
        for (a, b) in zip(l, r) where a != b { return octetOrder(a, b) }
        return false
    }
}
