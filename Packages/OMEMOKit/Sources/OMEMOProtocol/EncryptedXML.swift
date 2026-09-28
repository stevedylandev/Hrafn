import Foundation
import OMEMOCrypto
import XMPPCore
import XMPPIM
import XMPPXML

/// One version's `<encrypted/>`: the sender's device, one `<key/>` per
/// recipient device, and the payload (absent in a key transport or empty
/// message).
///
/// OMEMO 0.3 (§4.5) lists keys flat in the header beside an `<iv/>`. OMEMO 2
/// (0.8 §6) groups them in `<keys jid=''/>` per account and has no IV.
public struct EncryptedElement: Sendable, Equatable {
    public struct Key: Sendable, Equatable {
        public var deviceID: UInt32
        public var data: Data
        /// `prekey='true'` (0.3) or `kex='true'` (2).
        public var isPreKey: Bool
        /// OMEMO 2: the account the device belongs to.
        public var jid: JID?

        public init(deviceID: UInt32, data: Data, isPreKey: Bool, jid: JID? = nil) {
            self.deviceID = deviceID
            self.data = data
            self.isPreKey = isPreKey
            self.jid = jid?.bare
        }
    }

    public var version: OMEMOVersion
    public var senderDeviceID: UInt32
    public var keys: [Key]
    /// OMEMO 0.3 only; empty in OMEMO 2.
    public var iv: Data
    public var payload: Data?

    public init(version: OMEMOVersion = .legacy, senderDeviceID: UInt32, keys: [Key], iv: Data = Data(),
                payload: Data?) {
        self.version = version
        self.senderDeviceID = senderDeviceID
        self.keys = keys
        self.iv = iv
        self.payload = payload
    }

    public init?(element: Element) {
        if element.matches(name: "encrypted", namespaceURI: Namespaces.omemo2) {
            self.init(omemo2: element)
        } else {
            self.init(legacy: element)
        }
    }

    private init?(legacy element: Element) {
        let ns = Namespaces.legacyOMEMO
        guard element.matches(name: "encrypted", namespaceURI: ns),
              let header = element.firstChild(name: "header", namespaceURI: ns),
              let sid = header["sid"].flatMap(UInt32.init),
              let iv = header.firstChild(name: "iv", namespaceURI: ns).flatMap({ PreKeyBundle.base64($0.text) })
        else { return nil }
        version = .legacy
        senderDeviceID = sid
        self.iv = iv
        keys = header.childElements(name: "key", namespaceURI: ns).compactMap { key in
            guard let rid = key["rid"].flatMap(UInt32.init), let data = PreKeyBundle.base64(key.text) else { return nil }
            return Key(deviceID: rid, data: data, isPreKey: key["prekey"] == "true" || key["prekey"] == "1")
        }
        payload = element.firstChild(name: "payload", namespaceURI: ns).flatMap { PreKeyBundle.base64($0.text) }
    }

    private init?(omemo2 element: Element) {
        let ns = Namespaces.omemo2
        guard let header = element.firstChild(name: "header", namespaceURI: ns),
              let sid = header["sid"].flatMap(UInt32.init) else { return nil }
        version = .v2
        senderDeviceID = sid
        iv = Data()
        keys = header.childElements(name: "keys", namespaceURI: ns).flatMap { group -> [Key] in
            guard let jid = group["jid"].flatMap({ try? JID($0) }) else { return [] }
            return group.childElements(name: "key", namespaceURI: ns).compactMap { key in
                guard let rid = key["rid"].flatMap(UInt32.init), let data = PreKeyBundle.base64(key.text) else {
                    return nil
                }
                return Key(deviceID: rid, data: data, isPreKey: key["kex"] == "true" || key["kex"] == "1", jid: jid)
            }
        }
        payload = element.firstChild(name: "payload", namespaceURI: ns).flatMap { PreKeyBundle.base64($0.text) }
    }

    public var element: Element {
        let ns = version.namespace
        var header = Element(name: "header", namespaceURI: ns, attributes: ["sid": String(senderDeviceID)])
        switch version {
        case .legacy:
            for key in keys {
                var attributes = ["rid": String(key.deviceID)]
                if key.isPreKey { attributes["prekey"] = "true" }
                header.addChild(Element(name: "key", namespaceURI: ns, attributes: attributes,
                                        text: key.data.base64EncodedString()))
            }
            header.addChild(Element(name: "iv", namespaceURI: ns, text: iv.base64EncodedString()))
        case .v2:
            var order: [JID] = []
            for key in keys where !order.contains(key.jid!) { order.append(key.jid!) }
            for jid in order {
                var group = Element(name: "keys", namespaceURI: ns, attributes: ["jid": jid.description])
                for key in keys where key.jid == jid {
                    var attributes = ["rid": String(key.deviceID)]
                    if key.isPreKey { attributes["kex"] = "true" }
                    group.addChild(Element(name: "key", namespaceURI: ns, attributes: attributes,
                                           text: key.data.base64EncodedString()))
                }
                header.addChild(group)
            }
        }
        var encrypted = Element(name: "encrypted", namespaceURI: ns).adding(header)
        if let payload {
            encrypted.addChild(Element(name: "payload", namespaceURI: ns, text: payload.base64EncodedString()))
        }
        return encrypted
    }
}

/// Everything encrypted in one message: an `<encrypted/>` of each version
/// used. Hrafn encrypts each device in one version only, so a message to
/// both kinds of device carries both elements, and each device finds its key
/// in one of them.
public struct EncryptedMessage: Sendable, Equatable {
    /// Not empty; at most one per version, OMEMO 0.3 first.
    public private(set) var elements: [EncryptedElement]

    public init?(_ elements: [EncryptedElement]) {
        guard !elements.isEmpty else { return nil }
        self.elements = elements.sorted { $0.version == .legacy && $1.version != .legacy }
    }

    public init(_ element: EncryptedElement) {
        elements = [element]
    }

    public var senderDeviceID: UInt32 { elements[0].senderDeviceID }
    public var hasPayload: Bool { elements.contains { $0.payload != nil } }
    public var keys: [EncryptedElement.Key] { elements.flatMap(\.keys) }

    public func element(_ version: OMEMOVersion) -> EncryptedElement? {
        elements.first { $0.version == version }
    }
}

extension Message {
    /// Text shown by clients that cannot decrypt (XEP-0380 §4 suggests one).
    public static let omemoFallbackBody =
        "I sent you an OMEMO encrypted message but your client doesn’t seem to support that."

    /// The message's `<encrypted/>` elements, of either version.
    public var omemoEncrypted: EncryptedMessage? {
        EncryptedMessage([Namespaces.legacyOMEMO, Namespaces.omemo2].compactMap {
            element.firstChild(name: "encrypted", namespaceURI: $0).flatMap(EncryptedElement.init(element:))
        })
    }

    /// An encrypted chat message: the `<encrypted/>` elements, an XEP-0380
    /// marker, a `<store/>` hint (servers may not archive a message without
    /// a body otherwise) and, for messages with a payload, a fallback body.
    /// Receipts, markers and chat states can be added as for plain messages.
    public static func omemo(_ encrypted: EncryptedMessage, to: JID, type: Kind = .chat,
                             id: String = StanzaID.make()) -> Message {
        var message = Message(type: type, id: id, to: to)
        message.element.addChild(Element(name: "origin-id", namespaceURI: Namespaces.stableIDs, attributes: ["id": id]))
        return message.encrypted(with: encrypted)
    }

    public static func omemo(_ encrypted: EncryptedElement, to: JID, type: Kind = .chat,
                             id: String = StanzaID.make()) -> Message {
        omemo(EncryptedMessage(encrypted), to: to, type: type, id: id)
    }

    /// This message with its body replaced by `encrypted`. Only the body is
    /// encrypted (OMEMO 0.3 §4.5 allows no more, and OMEMO 2's envelope holds
    /// the same): everything else (receipt requests, replies, corrections)
    /// stays as it is, readable by the servers on the way.
    public func encrypted(with encrypted: EncryptedMessage) -> Message {
        var message = self
        message.element.removeChildren(name: "body", namespaceURI: Namespaces.client)
        for element in encrypted.elements { message.element.addChild(element.element) }
        // XEP-0380 names one method: 0.3's when present, which the most
        // clients know.
        message.element.addChild(Element(name: "encryption", namespaceURI: Namespaces.explicitEncryption,
                                         attributes: ["namespace": encrypted.elements[0].version.namespace,
                                                      "name": "OMEMO"]))
        if message.element.firstChild(name: "store", namespaceURI: Namespaces.hints) == nil {
            message.element.addChild(Element(name: "store", namespaceURI: Namespaces.hints))
        }
        if encrypted.hasPayload {
            message.element.addChild(Element(name: "body", namespaceURI: Namespaces.client, text: Self.omemoFallbackBody))
        }
        return message
    }

    public func encrypted(with encrypted: EncryptedElement) -> Message {
        self.encrypted(with: EncryptedMessage(encrypted))
    }

    /// The message as its sender wrote it: the decrypted body in place of the
    /// fallback, without the `<encrypted/>` and XEP-0380 elements. `nil` for a
    /// key transport message, which has no body.
    public func decrypted(body: String?) -> Message {
        decrypted(content: body.map { [Element(name: "body", namespaceURI: Namespaces.client, text: $0)] } ?? [])
    }

    /// The same with an OMEMO 2 envelope's content: each element in it
    /// replaces any of the same name and namespace outside.
    public func decrypted(content: [Element]) -> Message {
        var message = self
        message.element.removeChildren(name: "encrypted", namespaceURI: Namespaces.legacyOMEMO)
        message.element.removeChildren(name: "encrypted", namespaceURI: Namespaces.omemo2)
        message.element.removeChildren(name: "encryption", namespaceURI: Namespaces.explicitEncryption)
        message.element.removeChildren(name: "body", namespaceURI: Namespaces.client)
        for child in content {
            message.element.removeChildren(name: child.name, namespaceURI: child.namespaceURI)
            message.element.addChild(child)
        }
        return message
    }
}
