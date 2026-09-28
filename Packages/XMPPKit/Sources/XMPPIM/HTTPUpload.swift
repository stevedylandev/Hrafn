import Foundation
import XMPPClient
import XMPPCore
import XMPPXML

extension Namespaces {
    /// XEP-0363.
    public static let httpUpload = "urn:xmpp:http:upload:0"
    /// XEP-0066 out-of-band data, the way shared files are announced.
    public static let oob = "jabber:x:oob"
}

/// XEP-0363 HTTP File Upload, the XMPP half: finding the upload service and
/// asking it for a slot. The HTTP PUT itself is the caller's.
public struct HTTPUpload: Sendable {

    /// An upload service found through disco.
    public struct Service: Sendable, Hashable {
        public var jid: JID
        /// §3: advertised in an extension form; `nil` when the service sets no limit.
        public var maxFileSize: Int?

        public init(jid: JID, maxFileSize: Int?) {
            self.jid = jid
            self.maxFileSize = maxFileSize
        }
    }

    /// Where to PUT the file and where it can be fetched from afterwards.
    public struct Slot: Sendable, Hashable {
        public var putURL: URL
        /// §4: only `Authorization`, `Cookie` and `Expires` are passed on;
        /// anything else from the service is dropped.
        public var putHeaders: [String: String]
        public var getURL: URL
    }

    public enum Failure: Error, Sendable, Equatable {
        /// No service on the account's domain.
        case unavailable
        /// §5: the service refused the size; the limit, when it said.
        case fileTooLarge(maxFileSize: Int?)
        /// §5: quota reached; try again after `retryAfter`, when it said.
        case quota(retryAfter: Date?)
        /// The slot is not usable (not HTTPS, missing URLs).
        case invalidSlot
    }

    public let client: XMPPClient

    public init(client: XMPPClient) {
        self.client = client
    }

    /// §2: the first item of the account's domain that supports the protocol.
    public func discover() async throws -> Service? {
        guard let domain = await client.jid?.domainpart, let server = try? JID(domain) else {
            throw ClientError.notConnected
        }
        let items = try await client.discoItems(server).items
        for item in items where item.node == nil {
            guard let info = try? await client.discoInfo(item.jid), info.supports(Namespaces.httpUpload) else { continue }
            return Service(jid: item.jid, maxFileSize: Self.maxFileSize(in: info))
        }
        // Some servers answer on the domain itself.
        if let info = try? await client.discoInfo(server), info.supports(Namespaces.httpUpload) {
            return Service(jid: server, maxFileSize: Self.maxFileSize(in: info))
        }
        return nil
    }

    static func maxFileSize(in info: DiscoInfo) -> Int? {
        info.forms.first { $0.formType == Namespaces.httpUpload }?["max-file-size"]?.first.flatMap { Int($0) }
    }

    /// §4: asks `service` for a slot. `filename` should have no path; the
    /// service may still rename it.
    public func requestSlot(filename: String, size: Int, contentType: String?, service: JID) async throws -> Slot {
        do {
            let reply = try await client.send(IQ(type: .get, to: service,
                                                 payload: Self.request(filename: filename, size: size,
                                                                       contentType: contentType)))
            guard let slot = reply.payload.flatMap(Self.slot(from:)) else { throw Failure.invalidSlot }
            return slot
        } catch let error as StanzaError {
            throw Self.failure(from: error) ?? error
        }
    }

    static func request(filename: String, size: Int, contentType: String?) -> Element {
        var request = Element(name: "request", namespaceURI: Namespaces.httpUpload,
                              attributes: ["filename": filename, "size": String(size)])
        request["content-type"] = contentType
        return request
    }

    static func slot(from element: Element) -> Slot? {
        guard element.matches(name: "slot", namespaceURI: Namespaces.httpUpload),
              let put = element.firstChild(name: "put", namespaceURI: Namespaces.httpUpload),
              let get = element.firstChild(name: "get", namespaceURI: Namespaces.httpUpload),
              let putURL = put["url"].flatMap(URL.init(string:)), let getURL = get["url"].flatMap(URL.init(string:)),
              // §7: both must be HTTPS.
              putURL.scheme?.lowercased() == "https", getURL.scheme?.lowercased() == "https",
              putURL.host != nil, getURL.host != nil else { return nil }
        var headers: [String: String] = [:]
        for header in put.childElements(name: "header", namespaceURI: Namespaces.httpUpload) {
            guard let name = header["name"], let allowed = Self.allowedHeaders[name.lowercased()] else { continue }
            // §4: a header with a line break would smuggle another header.
            let value = header.text
            guard !value.contains(where: { $0 == "\r" || $0 == "\n" }) else { continue }
            headers[allowed] = value
        }
        return Slot(putURL: putURL, putHeaders: headers, getURL: getURL)
    }

    private static let allowedHeaders = ["authorization": "Authorization", "cookie": "Cookie", "expires": "Expires"]

    static func failure(from error: StanzaError) -> Failure? {
        guard let condition = error.applicationCondition, condition.namespaceURI == Namespaces.httpUpload else {
            return nil
        }
        if condition.name == "file-too-large" {
            let max = condition.firstChild(name: "max-file-size", namespaceURI: Namespaces.httpUpload)
                .flatMap { Int($0.text) }
            return .fileTooLarge(maxFileSize: max)
        }
        if condition.name == "retry" {
            return .quota(retryAfter: condition["stamp"].flatMap(XMPPDateTime.parse))
        }
        return nil
    }
}

// MARK: - XEP-0066 in messages

extension Message {

    /// XEP-0066 `<x xmlns='jabber:x:oob'><url/>`: a file shared by URL.
    public var oobURL: URL? {
        guard let text = element.firstChild(name: "x", namespaceURI: Namespaces.oob)?
            .firstChild(name: "url", namespaceURI: Namespaces.oob)?.text.trimmingCharacters(in: .whitespaces),
              let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else { return nil }
        return url
    }

    /// The shared file's URL when this message is a file share as clients
    /// send them (Conversations and others): an OOB element whose URL is the
    /// whole body, so clients without OOB still show a link.
    public var sharedFileURL: URL? {
        guard let url = oobURL, body?.trimmingCharacters(in: .whitespacesAndNewlines) == url.absoluteString else {
            return nil
        }
        return url
    }

    /// Adds the XEP-0066 element for `url`. The body should be the URL too.
    public mutating func addOOB(_ url: URL) {
        element.addChild(Element(name: "x", namespaceURI: Namespaces.oob)
            .adding(Element(name: "url", namespaceURI: Namespaces.oob, text: url.absoluteString)))
    }

    /// A file share in a one-to-one chat: the URL as body, plus OOB.
    public static func file(to: JID, url: URL, id: String = StanzaID.make()) -> Message {
        var message = chat(to: to, body: url.absoluteString, id: id)
        message.addOOB(url)
        return message
    }

    /// A file share in a room.
    public static func groupchatFile(to room: JID, url: URL, id: String = StanzaID.make()) -> Message {
        var message = groupchat(to: room, body: url.absoluteString, id: id)
        message.addOOB(url)
        return message
    }
}
