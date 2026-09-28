import Foundation
import ImageIO
import UniformTypeIdentifiers
import HrafnStore
import XMPPIM

/// Where shared files and avatars live on the device: `Media/` and
/// `Avatars/` next to the database, in the App Group container, so the
/// extensions see them too. Attachments record paths relative to `Media/`;
/// avatars are named by their SHA-1.
public struct MediaStore: Sendable {

    public let mediaDirectory: URL
    public let avatarDirectory: URL

    public init(root: URL) {
        mediaDirectory = root.appending(path: "Media", directoryHint: .isDirectory)
        avatarDirectory = root.appending(path: "Avatars", directoryHint: .isDirectory)
        for directory in [mediaDirectory, avatarDirectory] {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    /// A fresh, empty directory, for tests.
    public static func temporary() -> MediaStore {
        MediaStore(root: FileManager.default.temporaryDirectory.appending(path: "HrafnMedia-\(UUID().uuidString)"))
    }

    public func url(for localPath: String) -> URL {
        mediaDirectory.appending(path: localPath)
    }

    /// Moves (or copies, with `copy`) a file into the store under a unique
    /// directory, keeping its name. Returns the path relative to `Media/`.
    public func importFile(_ source: URL, named fileName: String? = nil, copy: Bool = false) throws -> String {
        let name = Self.safeFileName(fileName ?? source.lastPathComponent)
        let folder = UUID().uuidString
        let directory = mediaDirectory.appending(path: folder, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appending(path: name)
        if copy {
            try FileManager.default.copyItem(at: source, to: destination)
        } else {
            try FileManager.default.moveItem(at: source, to: destination)
        }
        return folder + "/" + name
    }

    public func removeFile(_ localPath: String) {
        let url = url(for: localPath)
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    // MARK: Avatars

    public func avatarURL(hash: String) -> URL {
        avatarDirectory.appending(path: hash)
    }

    public func hasAvatar(hash: String) -> Bool {
        FileManager.default.fileExists(atPath: avatarURL(hash: hash).path)
    }

    public func saveAvatar(_ data: Data, hash: String) throws {
        try data.write(to: avatarURL(hash: hash), options: .atomic)
    }

    /// Removes avatar files no profile refers to any more.
    public func pruneAvatars(keeping hashes: Set<String>) {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: avatarDirectory.path) else { return }
        for file in files where !hashes.contains(file) {
            try? FileManager.default.removeItem(at: avatarDirectory.appending(path: file))
        }
    }

    // MARK: Describing files

    /// A name that is safe as a single path component, from what a sender
    /// or URL says (which may contain anything).
    static func safeFileName(_ name: String) -> String {
        let decoded = name.removingPercentEncoding ?? name
        let cleaned = decoded.components(separatedBy: CharacterSet(charactersIn: "/\\:\u{0}")).joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        return cleaned.isEmpty ? "file" : String(cleaned.prefix(120))
    }

    public static func mimeType(forFileName name: String) -> String? {
        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty else { return nil }
        return UTType(filenameExtension: ext)?.preferredMIMEType
    }

    /// An attachment for a file someone shared by URL: its name and type
    /// from the URL's last path component.
    public static func remoteAttachment(_ url: URL) -> Attachment {
        let name = safeFileName(url.lastPathComponent.isEmpty ? (url.host ?? "file") : url.lastPathComponent)
        return Attachment(url: url, fileName: name, mimeType: mimeType(forFileName: name))
    }

    /// Thumbnails larger than this are not kept (they ride in the row).
    static let maxThumbnailBytes = 16 * 1024

    /// Someone else's file described by XEP-0446 metadata (XEP-0447): name,
    /// type, size and dimensions before it is fetched, a digest to check it
    /// by, and a thumbnail to show meanwhile.
    public static func remoteAttachment(_ url: URL, metadata: FileMetadata) -> Attachment {
        var attachment = remoteAttachment(url)
        if let name = metadata.name.map(safeFileName), !name.isEmpty {
            attachment.fileName = name
            attachment.mimeType = mimeType(forFileName: name)
        }
        if let type = metadata.mediaType, type.contains("/") { attachment.mimeType = type }
        attachment.size = metadata.size
        attachment.width = metadata.width
        attachment.height = metadata.height
        attachment.duration = metadata.length.map { Double($0) / 1000 }
        attachment.sha256 = metadata.sha256
        attachment.thumbnail = metadata.thumbnails.lazy.compactMap(\.inlineData)
            .first { $0.count <= maxThumbnailBytes }
        return attachment
    }

    /// Pixel size of an image file, without decoding it.
    public static func imageSize(of url: URL) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        // EXIF orientations 5–8 are rotated a quarter turn.
        if let orientation = properties[kCGImagePropertyOrientation] as? Int, (5...8).contains(orientation) {
            return (height, width)
        }
        return (width, height)
    }

    public static func fileSize(of url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue
    }
}

/// When files others share are fetched without asking.
public struct MediaPolicy: Codable, Sendable, Hashable {
    public enum AutoDownload: String, Codable, Sendable, Hashable, CaseIterable {
        case always
        /// Not over cellular or other expensive networks.
        case wifi
        case never
    }

    public var autoDownload: AutoDownload
    /// Larger files always wait for a tap.
    public var maxAutoDownloadSize: Int

    public init(autoDownload: AutoDownload = .always, maxAutoDownloadSize: Int = 10 * 1024 * 1024) {
        self.autoDownload = autoDownload
        self.maxAutoDownloadSize = maxAutoDownloadSize
    }
}
