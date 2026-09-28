import Testing
import Foundation
import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import HrafnServices

private func image(width: Int, height: Int) throws -> CGImage {
    let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 0.8, green: 0.2, blue: 0.4, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return try #require(context.makeImage())
}

private func encoded(_ image: CGImage, as type: UTType, properties: [CFString: Any] = [:]) throws -> Data {
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
}

private func properties(of url: URL) throws -> [CFString: Any] {
    let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
    return try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
}

@Suite struct MediaPreparationTests {

    @Test func photosLoseTheirLocationAndShrink() throws {
        let media = MediaStore.temporary()
        let gps: [CFString: Any] = [kCGImagePropertyGPSLatitude: 45.43, kCGImagePropertyGPSLatitudeRef: "N",
                                    kCGImagePropertyGPSLongitude: 10.99, kCGImagePropertyGPSLongitudeRef: "E"]
        let data = try encoded(try image(width: 4000, height: 3000), as: .jpeg,
                               properties: [kCGImagePropertyGPSDictionary: gps])
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let before = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(before[kCGImagePropertyGPSDictionary] != nil)

        let file = try MediaPreparation.image(data, media: media, fileName: "Verona.HEIC")
        #expect(file.fileName == "Verona.jpg")
        #expect(file.mimeType == "image/jpeg")
        #expect(file.width == 2560 && file.height == 1920)
        let after = try properties(of: media.url(for: file.localPath))
        #expect(after[kCGImagePropertyGPSDictionary] == nil)
        #expect(after[kCGImagePropertyPixelWidth] as? Int == 2560)
    }

    @Test func gifsStayAnimatable() throws {
        let media = MediaStore.temporary()
        let data = try encoded(try image(width: 10, height: 10), as: .gif)
        let file = try MediaPreparation.image(data, media: media, fileName: "dance.gif")
        #expect(file.mimeType == "image/gif")
        #expect(try Data(contentsOf: media.url(for: file.localPath)) == data)
    }

    @Test func avatarsAreSmallSquarePNGs() throws {
        let (png, side) = try MediaPreparation.avatar(try encoded(try image(width: 900, height: 600), as: .jpeg))
        #expect(side == MediaPreparation.avatarPixels)
        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        #expect(CGImageSourceGetType(source) as String? == UTType.png.identifier)
        let props = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(props[kCGImagePropertyPixelWidth] as? Int == side)
        #expect(props[kCGImagePropertyPixelHeight] as? Int == side)
    }

    @Test func videosBecomeMP4() async throws {
        let media = MediaStore.temporary()
        let movie = try await Self.writeMovie(width: 320, height: 240, frames: 15)
        let file = try await MediaPreparation.video(movie, media: media, fileName: "clip.mov")
        #expect(file.fileName == "clip.mp4")
        #expect(file.mimeType == "video/mp4")
        #expect(file.width == 320 && file.height == 240)
        #expect((file.duration ?? 0) > 0.4)
        let asset = AVURLAsset(url: media.url(for: file.localPath))
        #expect(try await !asset.loadTracks(withMediaType: .video).isEmpty)
    }

    @Test func voiceMessagesAreMarked() throws {
        let media = MediaStore.temporary()
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).m4a")
        try Data([0, 1, 2]).write(to: url)
        let file = try MediaPreparation.voice(url, duration: 3.5, media: media)
        #expect(file.isVoiceMessage && file.duration == 3.5 && file.mimeType == "audio/mp4")
        #expect(file.fileName.hasPrefix("Voice ") && file.fileName.hasSuffix(".m4a"))
    }

    /// A short H.264 QuickTime movie of solid frames.
    static func writeMovie(width: Int, height: Int, frames: Int) async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var buffer: CVPixelBuffer?
            let pool = try #require(adaptor.pixelBufferPool)
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            let pixels = try #require(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            memset(CVPixelBufferGetBaseAddress(pixels), Int32(frame * 16), CVPixelBufferGetDataSize(pixels))
            CVPixelBufferUnlockBaseAddress(pixels, [])
            adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
        }
        input.markAsFinished()
        // The async `finishWriting()` crashes here (a continuation resumed
        // twice); the completion handler does not.
        nonisolated(unsafe) let finishing = writer
        await withCheckedContinuation { continuation in finishing.finishWriting { continuation.resume() } }
        #expect(writer.status == .completed)
        return url
    }
}
