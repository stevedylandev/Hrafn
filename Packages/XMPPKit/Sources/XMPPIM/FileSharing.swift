import Foundation
import XMPPCore
import XMPPXML

extension Namespaces {
    /// XEP-0447 Stateless File Sharing.
    public static let fileSharing = "urn:xmpp:sfs:0"
    /// XEP-0446 File Metadata Element.
    public static let fileMetadata = "urn:xmpp:file:metadata:0"
    /// XEP-0300 Use of Cryptographic Hash Functions.
    public static let hashes = "urn:xmpp:hashes:2"
    /// XEP-0264 Jingle Content Thumbnails.
    public static let thumbnails = "urn:xmpp:thumbs:1"
    /// XEP-0103 URL Address Information, a XEP-0447 source.
    public static let urlData = "http://jabber.org/protocol/url-data"
}

/// XEP-0264: a small preview of a file. Hrafn sends and reads it inline, as
/// a `data:` URI; other URIs (`cid:` for XEP-0231, `https:`) are kept but not
/// fetched.
public struct FileThumbnail: Sendable, Hashable {
    public var uri: String
    public var mediaType: String?
    public var width: Int?
    public var height: Int?

    public init(uri: String, mediaType: String?, width: Int?, height: Int?) {
        self.uri = uri
        self.mediaType = mediaType
        self.width = width
        self.height = height
    }

    /// A thumbnail carrying its picture: `data:<type>;base64,<data>`.
    public init(data: Data, mediaType: String, width: Int?, height: Int?) {
        self.init(uri: "data:\(mediaType);base64,\(data.base64EncodedString())", mediaType: mediaType,
                  width: width, height: height)
    }

    /// The picture, when the URI carries it (base64 `data:` only).
    public var inlineData: Data? {
        guard uri.hasPrefix("data:"), let comma = uri.firstIndex(of: ","),
              uri[..<comma].hasSuffix(";base64") else { return nil }
        return Data(base64Encoded: String(uri[uri.index(after: comma)...]))
    }
}

/// XEP-0446: what a shared file is, before anyone fetches it.
public struct FileMetadata: Sendable, Hashable {
    public var mediaType: String?
    public var name: String?
    public var size: Int?
    public var width: Int?
    public var height: Int?
    /// Playing time of audio or video, in milliseconds.
    public var length: Int?
    public var description: String?
    /// XEP-0300: base64 digests by algorithm (`sha-256`, …).
    public var hashes: [String: String]
    public var thumbnails: [FileThumbnail]

    public init(mediaType: String? = nil, name: String? = nil, size: Int? = nil, width: Int? = nil, height: Int? = nil,
                length: Int? = nil, description: String? = nil, hashes: [String: String] = [:],
                thumbnails: [FileThumbnail] = []) {
        self.mediaType = mediaType
        self.name = name
        self.size = size
        self.width = width
        self.height = height
        self.length = length
        self.description = description
        self.hashes = hashes
        self.thumbnails = thumbnails
    }

    public init(element file: Element) {
        func text(_ name: String) -> String? {
            file.firstChild(name: name, namespaceURI: Namespaces.fileMetadata)?.text.nilIfBlank
        }
        func number(_ name: String) -> Int? { text(name).flatMap { Int($0) }.flatMap { $0 >= 0 ? $0 : nil } }
        var hashes: [String: String] = [:]
        for hash in file.childElements(name: "hash", namespaceURI: Namespaces.hashes) {
            if let algo = hash["algo"], let value = hash.text.nilIfBlank { hashes[algo] = value }
        }
        let thumbnails = file.childElements(name: "thumbnail", namespaceURI: Namespaces.thumbnails).compactMap { t in
            t["uri"].map { FileThumbnail(uri: $0, mediaType: t["media-type"], width: t["width"].flatMap { Int($0) },
                                         height: t["height"].flatMap { Int($0) }) }
        }
        self.init(mediaType: text("media-type"), name: text("name"), size: number("size"), width: number("width"),
                  height: number("height"), length: number("length"), description: text("desc"),
                  hashes: hashes, thumbnails: thumbnails)
    }

    public var element: Element {
        var file = Element(name: "file", namespaceURI: Namespaces.fileMetadata)
        func add(_ name: String, _ value: String?) {
            if let value { file.addChild(Element(name: name, namespaceURI: Namespaces.fileMetadata, text: value)) }
        }
        add("media-type", mediaType)
        add("name", name)
        add("size", size.map(String.init))
        add("width", width.map(String.init))
        add("height", height.map(String.init))
        add("length", length.map(String.init))
        add("desc", description)
        for (algo, value) in hashes.sorted(by: { $0.key < $1.key }) {
            file.addChild(Element(name: "hash", namespaceURI: Namespaces.hashes, attributes: ["algo": algo], text: value))
        }
        for thumbnail in thumbnails {
            var attributes = ["uri": thumbnail.uri]
            attributes["media-type"] = thumbnail.mediaType
            attributes["width"] = thumbnail.width.map(String.init)
            attributes["height"] = thumbnail.height.map(String.init)
            file.addChild(Element(name: "thumbnail", namespaceURI: Namespaces.thumbnails, attributes: attributes))
        }
        return file
    }

    /// The SHA-256 digest, base64, when given.
    public var sha256: String? { hashes["sha-256"] }
}

/// XEP-0447: a file shared by value — its metadata and where to fetch it.
public struct SharedFile: Sendable, Hashable {
    public var metadata: FileMetadata
    /// XEP-0103 sources, in the sender's order.
    public var sources: [URL]
    /// `inline` (show it in the conversation) or `attachment`.
    public var disposition: String?

    public init(metadata: FileMetadata, sources: [URL], disposition: String? = nil) {
        self.metadata = metadata
        self.sources = sources
        self.disposition = disposition
    }

    public var element: Element {
        var sharing = Element(name: "file-sharing", namespaceURI: Namespaces.fileSharing)
        sharing["disposition"] = disposition
        sharing.addChild(metadata.element)
        var sourceList = Element(name: "sources", namespaceURI: Namespaces.fileSharing)
        for source in sources {
            sourceList.addChild(Element(name: "url-data", namespaceURI: Namespaces.urlData,
                                        attributes: ["target": source.absoluteString]))
        }
        sharing.addChild(sourceList)
        return sharing
    }

    /// The first source we can fetch: plain HTTPS. (`aesgcm://` and friends
    /// belong to encryption, v2.)
    public var httpsSource: URL? { sources.first { $0.scheme?.lowercased() == "https" } }
}

extension Message {

    /// XEP-0447, when the message shares a file that way.
    public var sharedFileByValue: SharedFile? {
        guard let sharing = element.firstChild(name: "file-sharing", namespaceURI: Namespaces.fileSharing),
              let file = sharing.firstChild(name: "file", namespaceURI: Namespaces.fileMetadata) else { return nil }
        let sources = sharing.firstChild(name: "sources", namespaceURI: Namespaces.fileSharing)?
            .childElements(name: "url-data", namespaceURI: Namespaces.urlData)
            .compactMap { $0["target"].flatMap(URL.init(string:)) } ?? []
        return SharedFile(metadata: FileMetadata(element: file), sources: sources, disposition: sharing["disposition"])
    }

    /// Adds the XEP-0447 element; the body (the URL, with XEP-0066 beside
    /// it) stays for clients that do not know it, marked as its fallback.
    public func sharing(_ file: SharedFile) -> Message {
        var copy = self
        copy.element.addChild(file.element)
        if copy.body != nil {
            copy.element.addChild(Element(name: "fallback", namespaceURI: Namespaces.fallback,
                                          attributes: ["for": Namespaces.fileSharing]))
        }
        return copy
    }
}
