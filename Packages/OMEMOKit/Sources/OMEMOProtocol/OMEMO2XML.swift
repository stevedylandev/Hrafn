import Foundation
import OMEMOCrypto
import XMPPCore
import XMPPIM
import XMPPXML

extension Namespaces {
    /// XEP-0384 version 0.8 and later, OMEMO 2.
    public static let omemo2 = "urn:xmpp:omemo:2"
    /// XEP-0420 Stanza Content Encryption, OMEMO 2's payload.
    public static let stanzaContentEncryption = "urn:xmpp:sce:1"
}

extension OMEMOVersion {
    /// The namespace of the version's elements.
    public var namespace: String {
        switch self {
        case .legacy: Namespaces.legacyOMEMO
        case .v2: Namespaces.omemo2
        }
    }

    /// The PEP node of the version's device list.
    public var deviceListNode: String {
        switch self {
        case .legacy: LegacyOMEMONodes.deviceList
        case .v2: OMEMO2Nodes.devices
        }
    }
}

/// OMEMO 2's PEP nodes (XEP-0384 0.8 §5.3). Unlike 0.3, all of a device's
/// bundles share one node, one item per device, its id the device id.
public enum OMEMO2Nodes {
    public static let devices = Namespaces.omemo2 + ":devices"
    /// Advertise this to be sent device list changes (XEP-0163 §4).
    public static let devicesNotify = devices + "+notify"
    public static let bundles = Namespaces.omemo2 + ":bundles"
}

extension PreKeyBundle {
    /// §5.3.2 `<bundle><spk id=''/><spks/><ik/><prekeys><pk id=''/>…</prekeys></bundle>`.
    /// The identity key is Ed25519, the others X25519, all bare 32 bytes.
    init(omemo2 element: Element, deviceID: UInt32) throws {
        let ns = Namespaces.omemo2
        guard let spk = element.firstChild(name: "spk", namespaceURI: ns),
              let spkID = spk["id"].flatMap(UInt32.init), let signed = Self.base64(spk.text),
              let signature = element.firstChild(name: "spks", namespaceURI: ns).flatMap({ Self.base64($0.text) }),
              let identity = element.firstChild(name: "ik", namespaceURI: ns).flatMap({ Self.base64($0.text) })
        else { throw OMEMOProtocolError.malformedBundle }
        var preKeys: [UInt32: PublicKey] = [:]
        for preKey in element.firstChild(name: "prekeys", namespaceURI: ns)?.childElements(name: "pk", namespaceURI: ns) ?? [] {
            guard let id = preKey["id"].flatMap(UInt32.init), let data = Self.base64(preKey.text),
                  let key = try? PublicKey(rawRepresentation: data) else { continue }
            preKeys[id] = key
        }
        do {
            try self.init(deviceID: deviceID, ed25519IdentityKey: identity, signedPreKeyID: spkID,
                          signedPreKey: try PublicKey(rawRepresentation: signed), signedPreKeySignature: signature,
                          preKeys: preKeys)
        } catch {
            throw OMEMOProtocolError.malformedBundle
        }
    }

    var omemo2Element: Element {
        let ns = Namespaces.omemo2
        var prekeys = Element(name: "prekeys", namespaceURI: ns)
        for (id, key) in preKeys.sorted(by: { $0.key < $1.key }) {
            prekeys.addChild(Element(name: "pk", namespaceURI: ns, attributes: ["id": String(id)],
                                     text: key.rawRepresentation.base64EncodedString()))
        }
        return Element(name: "bundle", namespaceURI: ns)
            .adding(Element(name: "spk", namespaceURI: ns, attributes: ["id": String(signedPreKeyID)],
                            text: signedPreKey.rawRepresentation.base64EncodedString()))
            .adding(Element(name: "spks", namespaceURI: ns, text: signedPreKeySignature.base64EncodedString()))
            .adding(Element(name: "ik", namespaceURI: ns, text: (ed25519IdentityKey ?? Data()).base64EncodedString()))
            .adding(prekeys)
    }
}

/// XEP-0420's `<envelope/>` as OMEMO 2 profiles it (XEP-0384 0.8 §6.1): the
/// protected elements in `<content/>`, random padding, and who it is from and
/// to, so a message cannot be replayed into another conversation.
public struct SCEEnvelope: Sendable, Equatable {
    public var content: [Element]
    /// The sender's bare JID.
    public var from: JID?
    /// The recipient's bare JID, or the room's.
    public var to: JID?

    public init(content: [Element], from: JID?, to: JID?) {
        self.content = content
        self.from = from?.bare
        self.to = to?.bare
    }

    public init?(element: Element) {
        let ns = Namespaces.stanzaContentEncryption
        guard element.matches(name: "envelope", namespaceURI: ns),
              let content = element.firstChild(name: "content", namespaceURI: ns) else { return nil }
        self.content = content.elements
        from = element.firstChild(name: "from", namespaceURI: ns)?["jid"].flatMap { try? JID($0) }
        to = element.firstChild(name: "to", namespaceURI: ns)?["jid"].flatMap { try? JID($0) }
    }

    /// With 0–200 characters of `<rpad/>` (§4.1), so the length of the
    /// ciphertext does not give away the length of the text.
    public var element: Element {
        let ns = Namespaces.stanzaContentEncryption
        var content = Element(name: "content", namespaceURI: ns)
        for child in self.content { content.addChild(child) }
        var envelope = Element(name: "envelope", namespaceURI: ns).adding(content)
        let padding = String((0..<Int.random(in: 0...200)).map { _ in
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789".randomElement()!
        })
        envelope.addChild(Element(name: "rpad", namespaceURI: ns, text: padding))
        if let from { envelope.addChild(Element(name: "from", namespaceURI: ns, attributes: ["jid": from.description])) }
        if let to { envelope.addChild(Element(name: "to", namespaceURI: ns, attributes: ["jid": to.description])) }
        return envelope
    }

    /// The body text in `<content/>`, if any.
    public var body: String? {
        content.first { $0.matches(name: "body", namespaceURI: Namespaces.client) }?.text
    }
}
