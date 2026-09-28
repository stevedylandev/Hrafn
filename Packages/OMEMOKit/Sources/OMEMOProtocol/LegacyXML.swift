import Foundation
import OMEMOCrypto
import XMPPCore
import XMPPIM
import XMPPXML

extension Namespaces {
    /// XEP-0384 version 0.3: the namespace of every OMEMO 0.3 element.
    public static let legacyOMEMO = "eu.siacs.conversations.axolotl"
    /// XEP-0380 Explicit Message Encryption.
    public static let explicitEncryption = "urn:xmpp:eme:0"
}

/// OMEMO 0.3's PEP nodes (XEP-0384 0.3 §4.2–4.3).
public enum LegacyOMEMONodes {
    public static let deviceList = Namespaces.legacyOMEMO + ".devicelist"
    /// Advertise this to be sent device list changes (XEP-0163 §4).
    public static let deviceListNotify = deviceList + "+notify"

    public static func bundle(_ deviceID: UInt32) -> String {
        Namespaces.legacyOMEMO + ".bundles:\(deviceID)"
    }
}

/// A device list: OMEMO 0.3's `<list><device id=''/>…</list>` (§4.2) or
/// OMEMO 2's `<devices><device id=''/>…</devices>` (0.8 §5.3.1). Ids outside
/// 1…2^31 − 1 are dropped.
public struct DeviceList: Sendable, Equatable {
    public var version: OMEMOVersion
    public var deviceIDs: [UInt32]

    public init(deviceIDs: [UInt32], version: OMEMOVersion = .legacy) {
        self.version = version
        self.deviceIDs = deviceIDs
    }

    public init?(element: Element) {
        let version: OMEMOVersion
        if element.matches(name: "list", namespaceURI: Namespaces.legacyOMEMO) {
            version = .legacy
        } else if element.matches(name: "devices", namespaceURI: Namespaces.omemo2) {
            version = .v2
        } else {
            return nil
        }
        var seen: Set<UInt32> = []
        self.version = version
        deviceIDs = element.childElements(name: "device", namespaceURI: element.namespaceURI)
            .compactMap { $0["id"].flatMap(UInt32.init) }
            .filter { $0 > 0 && $0 <= 0x7FFF_FFFF && seen.insert($0).inserted }
    }

    public var element: Element {
        let ns = version.namespace
        var list = Element(name: version == .legacy ? "list" : "devices", namespaceURI: ns)
        for id in deviceIDs {
            list.addChild(Element(name: "device", namespaceURI: ns, attributes: ["id": String(id)]))
        }
        return list
    }
}

extension PreKeyBundle {
    /// A `<bundle/>` of either version (the namespace says which).
    public init(element: Element, deviceID: UInt32) throws {
        if element.matches(name: "bundle", namespaceURI: Namespaces.omemo2) {
            try self.init(omemo2: element, deviceID: deviceID)
            return
        }
        try self.init(legacy: element, deviceID: deviceID)
    }

    public var element: Element {
        version == .v2 ? omemo2Element : legacyElement
    }

    /// §4.3 `<bundle/>`. Keys may be serialized (33 bytes) or bare (32).
    /// Pre-keys that do not decode are skipped; the rest must all be there.
    private init(legacy element: Element, deviceID: UInt32) throws {
        let ns = Namespaces.legacyOMEMO
        guard element.matches(name: "bundle", namespaceURI: ns),
              let signedElement = element.firstChild(name: "signedPreKeyPublic", namespaceURI: ns),
              let signedID = signedElement["signedPreKeyId"].flatMap(UInt32.init),
              let signed = Self.base64(signedElement.text),
              let signature = element.firstChild(name: "signedPreKeySignature", namespaceURI: ns).flatMap({ Self.base64($0.text) }),
              let identity = element.firstChild(name: "identityKey", namespaceURI: ns).flatMap({ Self.base64($0.text) })
        else { throw OMEMOProtocolError.malformedBundle }
        var preKeys: [UInt32: PublicKey] = [:]
        for preKey in element.firstChild(name: "prekeys", namespaceURI: ns)?
                .childElements(name: "preKeyPublic", namespaceURI: ns) ?? [] {
            guard let id = preKey["preKeyId"].flatMap(UInt32.init), let data = Self.base64(preKey.text),
                  let key = try? PublicKey(serialized: data) else { continue }
            preKeys[id] = key
        }
        do {
            self.init(deviceID: deviceID, identityKey: try PublicKey(serialized: identity), signedPreKeyID: signedID,
                      signedPreKey: try PublicKey(serialized: signed), signedPreKeySignature: signature,
                      preKeys: preKeys)
        } catch {
            throw OMEMOProtocolError.malformedBundle
        }
    }

    private var legacyElement: Element {
        let ns = Namespaces.legacyOMEMO
        var prekeys = Element(name: "prekeys", namespaceURI: ns)
        for (id, key) in preKeys.sorted(by: { $0.key < $1.key }) {
            prekeys.addChild(Element(name: "preKeyPublic", namespaceURI: ns, attributes: ["preKeyId": String(id)],
                                     text: key.serialized.base64EncodedString()))
        }
        return Element(name: "bundle", namespaceURI: ns)
            .adding(Element(name: "signedPreKeyPublic", namespaceURI: ns,
                            attributes: ["signedPreKeyId": String(signedPreKeyID)],
                            text: signedPreKey.serialized.base64EncodedString()))
            .adding(Element(name: "signedPreKeySignature", namespaceURI: ns,
                            text: signedPreKeySignature.base64EncodedString()))
            .adding(Element(name: "identityKey", namespaceURI: ns, text: identityKey.serialized.base64EncodedString()))
            .adding(prekeys)
    }

    static func base64(_ text: String) -> Data? {
        Data(base64Encoded: text, options: .ignoreUnknownCharacters).flatMap { $0.isEmpty ? nil : $0 }
    }
}
