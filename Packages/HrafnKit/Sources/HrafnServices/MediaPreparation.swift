import AVFoundation
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import HrafnStore

/// Turns what the user picked into a file worth sending, in the media store:
/// photos re-encoded as JPEG without their metadata (no location leaves the
/// device), videos as MP4, anything else as it is.
public enum MediaPreparation {

    /// Longest side of a sent photo.
    public static let maxImagePixels = 2560
    /// Side of a published avatar (XEP-0084 suggests small, square PNGs).
    public static let avatarPixels = 192

    /// A photo. GIFs are kept as they are, so they stay animated.
    public static func image(_ data: Data, media: MediaStore, fileName: String? = nil) throws -> OutgoingFile {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { throw PreparationError.unreadable }
        if let type = CGImageSourceGetType(source) as String?, UTType(type)?.conforms(to: .gif) == true {
            return try store(data, name: base(fileName, "gif"), mimeType: "image/gif", media: media,
                             size: imageSize(source))
        }
        // Thumbnail creation applies the EXIF orientation and drops every
        // other property, GPS included.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxImagePixels,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw PreparationError.unreadable
        }
        let encoded = try encode(image, as: .jpeg, quality: 0.8)
        return try store(encoded, name: base(fileName, "jpg"), mimeType: "image/jpeg", media: media,
                         size: (image.width, image.height))
    }

    /// A video, converted to MP4 at medium quality (it plays everywhere, and
    /// fits upload limits more often).
    public static func video(_ url: URL, media: MediaStore, fileName: String? = nil) async throws -> OutgoingFile {
        let asset = AVURLAsset(url: url)
        let output = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).mp4")
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetMediumQuality) else {
            throw PreparationError.unreadable
        }
        if #available(iOS 18, macOS 15, *) {
            try await export.export(to: output, as: .mp4)
        } else {
            export.outputURL = output
            export.outputFileType = .mp4
            nonisolated(unsafe) let session = export
            await withCheckedContinuation { continuation in
                session.exportAsynchronously { continuation.resume() }
            }
            if let error = session.error { throw error }
        }
        let duration = try? await asset.load(.duration).seconds
        var size: (Int, Int)?
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let natural = try? await track.load(.naturalSize), let transform = try? await track.load(.preferredTransform) {
            let rect = CGRect(origin: .zero, size: natural).applying(transform)
            size = (Int(abs(rect.width)), Int(abs(rect.height)))
        }
        let path = try media.importFile(output, named: base(fileName, "mp4"))
        return OutgoingFile(localPath: path, fileName: (path as NSString).lastPathComponent, mimeType: "video/mp4",
                            width: size?.0, height: size?.1, duration: duration)
    }

    /// Any other file, copied as it is.
    public static func file(_ url: URL, media: MediaStore) throws -> OutgoingFile {
        let path = try media.importFile(url, copy: true)
        let name = (path as NSString).lastPathComponent
        return OutgoingFile(localPath: path, fileName: name, mimeType: MediaStore.mimeType(forFileName: name))
    }

    /// A recorded voice message (AAC in .m4a).
    public static func voice(_ url: URL, duration: TimeInterval, media: MediaStore) throws -> OutgoingFile {
        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
            .replacingOccurrences(of: ":", with: "-")
        let path = try media.importFile(url, named: "Voice \(stamp).m4a")
        return OutgoingFile(localPath: path, fileName: (path as NSString).lastPathComponent, mimeType: "audio/mp4",
                            duration: duration, isVoiceMessage: true)
    }

    /// A square PNG from the middle of `data`, for `AccountSession.setAvatar`.
    public static func avatar(_ data: Data) throws -> (png: Data, side: Int) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: avatarPixels * 3,
              ] as CFDictionary) else { throw PreparationError.unreadable }
        let side = min(image.width, image.height)
        let crop = CGRect(x: (image.width - side) / 2, y: (image.height - side) / 2, width: side, height: side)
        guard let square = image.cropping(to: crop) else { throw PreparationError.unreadable }
        let target = min(side, avatarPixels)
        guard let context = CGContext(data: nil, width: target, height: target, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw PreparationError.unreadable
        }
        context.interpolationQuality = .high
        context.draw(square, in: CGRect(x: 0, y: 0, width: target, height: target))
        guard let scaled = context.makeImage() else { throw PreparationError.unreadable }
        return (try encode(scaled, as: .png, quality: nil), target)
    }

    // MARK: XEP-0446 metadata for our own files

    /// Longest side of the XEP-0264 thumbnail sent with pictures and videos:
    /// enough for a blurred placeholder, small enough to ride in the stanza.
    static let thumbnailPixels = 64

    /// SHA-256 of a file, base64 (XEP-0300), read in chunks.
    public static func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return Data(hasher.finalize()).base64EncodedString()
    }

    /// A small JPEG of a picture or a video's first frame, with its size.
    public static func thumbnail(of url: URL, kind: Attachment.Kind) async -> (data: Data, width: Int, height: Int)? {
        let image: CGImage?
        switch kind {
        case .image:
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: thumbnailPixels,
            ] as CFDictionary)
        case .video:
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: thumbnailPixels, height: thumbnailPixels)
            image = try? await generator.image(at: .zero).image
        case .audio, .file:
            return nil
        }
        guard let image, let data = try? encode(image, as: .jpeg, quality: 0.6),
              data.count <= MediaStore.maxThumbnailBytes else { return nil }
        return (data, image.width, image.height)
    }

    public enum PreparationError: Error, CustomStringConvertible {
        case unreadable
        public var description: String { String(localized: "The file could not be read", bundle: .module) }
    }

    // MARK: Helpers

    private static func encode(_ image: CGImage, as type: UTType, quality: Double?) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            throw PreparationError.unreadable
        }
        var properties: [CFString: Any] = [:]
        if let quality { properties[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw PreparationError.unreadable }
        return data as Data
    }

    private static func imageSize(_ source: CGImageSource) -> (Int, Int)? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (width, height)
    }

    /// `name` with the extension `ext`, or a dated name like the Camera's.
    private static func base(_ name: String?, _ ext: String) -> String {
        let stem = name.map { ($0 as NSString).deletingPathExtension }.flatMap { $0.isEmpty ? nil : $0 }
            ?? "IMG_\(Date().formatted(.iso8601.year().month().day()).replacingOccurrences(of: "-", with: ""))_\(Int(Date().timeIntervalSince1970) % 100_000)"
        return stem + "." + ext
    }

    private static func store(_ data: Data, name: String, mimeType: String, media: MediaStore,
                              size: (Int, Int)?) throws -> OutgoingFile {
        let temporary = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try data.write(to: temporary)
        let path = try media.importFile(temporary, named: name)
        return OutgoingFile(localPath: path, fileName: (path as NSString).lastPathComponent, mimeType: mimeType,
                            width: size?.0, height: size?.1)
    }
}
