import Foundation
import OMEMOCrypto
import XMPPClient
import XMPPCore
import XMPPIM
import XMPPXML

/// Where device lists and bundles are published and fetched, for either
/// version. PEP in the app; a stand-in in tests.
public protocol OMEMODirectory: Sendable {
    /// `jid`'s devices; empty when it has published none.
    func deviceList(of jid: JID, version: OMEMOVersion) async throws -> [UInt32]
    func publishDeviceList(_ deviceIDs: [UInt32], version: OMEMOVersion) async throws
    func bundle(of jid: JID, deviceID: UInt32, version: OMEMOVersion) async throws -> PreKeyBundle
    /// Publishes the bundle in its own version.
    func publishBundle(_ bundle: PreKeyBundle) async throws
}

/// OMEMO over PEP (XEP-0163), with XEP-0060 publish options.
public struct PEPDirectory: OMEMODirectory {
    public let client: XMPPClient

    public init(client: XMPPClient) {
        self.client = client
    }

    public func deviceList(of jid: JID, version: OMEMOVersion) async throws -> [UInt32] {
        // 0.3 §4.2, 0.8 §5.3.1: the list is one item, conventionally
        // `current`; take the last item whatever its id.
        let items = try await fetchItems(of: jid, node: version.deviceListNode, max: 1)
        return items.last?.elements.lazy.compactMap(DeviceList.init(element:)).first { $0.version == version }?
            .deviceIDs ?? []
    }

    public func publishDeviceList(_ deviceIDs: [UInt32], version: OMEMOVersion) async throws {
        try await publish(DeviceList(deviceIDs: deviceIDs, version: version).element, node: version.deviceListNode,
                          id: "current")
    }

    public func bundle(of jid: JID, deviceID: UInt32, version: OMEMOVersion) async throws -> PreKeyBundle {
        let items: [Element]
        switch version {
        case .legacy: items = try await fetchItems(of: jid, node: LegacyOMEMONodes.bundle(deviceID), max: 1)
        case .v2: items = try await fetchItems(of: jid, node: OMEMO2Nodes.bundles, id: String(deviceID))
        }
        guard let element = items.last?.firstChild(name: "bundle", namespaceURI: version.namespace) else {
            throw OMEMOProtocolError.bundleNotFound(jid.bare, deviceID)
        }
        return try PreKeyBundle(element: element, deviceID: deviceID)
    }

    public func publishBundle(_ bundle: PreKeyBundle) async throws {
        switch bundle.version {
        case .legacy:
            try await publish(bundle.element, node: LegacyOMEMONodes.bundle(bundle.deviceID), id: "current")
        case .v2:
            // One node for every device's bundle (0.8 §5.3.2), so it must keep
            // as many items as there are devices.
            try await publish(bundle.element, node: OMEMO2Nodes.bundles, id: String(bundle.deviceID), maxItems: "max")
        }
    }

    /// Contacts must be able to fetch both nodes before they are subscribed
    /// to our presence, so both are published with an open access model.
    /// A server that refuses the options (a node configured otherwise,
    /// `precondition-not-met`, a `<conflict/>` per XEP-0060 §7.1.5) gets the
    /// item without them.
    private func publish(_ payload: Element, node: String, id: String, maxItems: String? = nil) async throws {
        let item = Element(name: "item", namespaceURI: Namespaces.pubsub, attributes: ["id": id]).adding(payload)
        let publish = Element(name: "publish", namespaceURI: Namespaces.pubsub, attributes: ["node": node]).adding(item)
        var fields: [DataForm.Field] = [
            .init(variable: "FORM_TYPE", type: "hidden", values: [Namespaces.publishOptions]),
            .init(variable: "pubsub#access_model", values: ["open"]),
            .init(variable: "pubsub#persist_items", values: ["true"]),
        ]
        if let maxItems { fields.append(.init(variable: "pubsub#max_items", values: [maxItems])) }
        let options = DataForm(type: .submit, fields: fields)
        do {
            _ = try await client.send(IQ(type: .set, payload: Element(name: "pubsub", namespaceURI: Namespaces.pubsub)
                .adding(publish)
                .adding(Element(name: "publish-options", namespaceURI: Namespaces.pubsub).adding(options.element))))
        } catch let error as StanzaError where error.condition == .conflict {
            _ = try await client.send(IQ(type: .set, payload: Element(name: "pubsub", namespaceURI: Namespaces.pubsub)
                .adding(publish)))
        }
    }

    /// The node's newest `max` items, or the one item `id` (XEP-0060 §6.5.8).
    private func fetchItems(of jid: JID, node: String, max: Int? = nil, id: String? = nil) async throws -> [Element] {
        var items = Element(name: "items", namespaceURI: Namespaces.pubsub, attributes: ["node": node])
        if let max { items["max_items"] = String(max) }
        if let id { items.addChild(Element(name: "item", namespaceURI: Namespaces.pubsub, attributes: ["id": id])) }
        do {
            let reply = try await client.send(IQ(type: .get, to: jid.bare,
                                                 payload: Element(name: "pubsub", namespaceURI: Namespaces.pubsub)
                                                    .adding(items)))
            return reply.payload?.firstChild(name: "items", namespaceURI: Namespaces.pubsub)?
                .childElements(name: "item", namespaceURI: Namespaces.pubsub) ?? []
        } catch let error as StanzaError where error.condition == .itemNotFound {
            return []
        }
    }

    /// A device list published in a PEP notification, of either version, or
    /// `nil` when the message is not one. The list belongs to the
    /// notification's sender (no `from` means our own account).
    public static func deviceListChange(in message: Message, account: JID) -> DeviceListChange? {
        guard let items = message.element.firstChild(name: "event", namespaceURI: Namespaces.pubsubEvent)?
                .firstChild(name: "items", namespaceURI: Namespaces.pubsubEvent),
              let version = OMEMOVersion.allCases.first(where: { items["node"] == $0.deviceListNode }),
              let list = items.childElements(name: "item", namespaceURI: Namespaces.pubsubEvent).last?
                .elements.lazy.compactMap(DeviceList.init(element:)).first(where: { $0.version == version })
        else { return nil }
        return DeviceListChange(jid: (message.from ?? account).bare, deviceIDs: list.deviceIDs, version: version)
    }
}

public struct DeviceListChange: Sendable, Equatable {
    public var jid: JID
    public var deviceIDs: [UInt32]
    public var version: OMEMOVersion
}
