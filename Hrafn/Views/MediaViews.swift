import AVFoundation
import AVKit
import ImageIO
import QuickLook
import SwiftUI
import UniformTypeIdentifiers
import HrafnServices
import HrafnStore

// MARK: - Thumbnails

/// Small images for the chat, decoded off the main thread and kept while
/// memory allows.
actor Thumbnails {
    static let shared = Thumbnails()
    private let cache = NSCache<NSURL, UIImage>()

    func image(for url: URL, kind: Attachment.Kind, maxPixels: Int = 600) async -> UIImage? {
        if let cached = cache.object(forKey: url as NSURL) { return cached }
        let image: UIImage?
        switch kind {
        case .image: image = Self.downsample(url, maxPixels: maxPixels)
        case .video: image = await Self.frame(of: url, maxPixels: maxPixels)
        default: image = nil
        }
        if let image { cache.setObject(image, forKey: url as NSURL) }
        return image
    }

    static func downsample(_ url: URL, maxPixels: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map(UIImage.init(cgImage:))
    }

    static func frame(of url: URL, maxPixels: Int) async -> UIImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixels, height: maxPixels)
        guard let (image, _) = try? await generator.image(at: .zero) else { return nil }
        return UIImage(cgImage: image)
    }
}

// MARK: - The attachment in a bubble

/// A shared file in a message: a picture or video thumbnail, a voice message
/// player, or a file row — with download and upload progress.
struct AttachmentView: View {
    let message: StoredMessage
    let attachment: Attachment
    let accountID: String

    @Environment(AppModel.self) private var app
    @State private var thumbnail: UIImage?
    @State private var viewing = false
    @State private var previewURL: URL?
    @State private var errorMessage: String?

    private var localURL: URL? { attachment.localPath.map { app.media.url(for: $0) } }
    private var progress: Double? { message.id.flatMap { app.manager.status(for: accountID).transfers[$0] } }

    var body: some View {
        Group {
            switch attachment.kind {
            case .image, .video: visual
            case .audio: AudioMessageView(attachment: attachment, url: localURL, isOutgoing: message.isOutgoing,
                                          progress: progress, download: download)
            case .file: fileRow
            }
        }
        .task(id: attachment.localPath) {
            guard let localURL else { return }
            thumbnail = await Thumbnails.shared.image(for: localURL, kind: attachment.kind)
        }
        .fullScreenCover(isPresented: $viewing) {
            if let localURL { MediaViewer(url: localURL, kind: attachment.kind, fileName: attachment.fileName) }
        }
        .quickLookPreview($previewURL)
        .alert("Couldn't Download", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
    }

    // MARK: Pictures and videos

    private var aspectRatio: CGFloat {
        if let thumbnail, thumbnail.size.height > 0 { return thumbnail.size.width / thumbnail.size.height }
        if let width = attachment.width, let height = attachment.height, height > 0 { return CGFloat(width) / CGFloat(height) }
        return 4 / 3
    }

    private var visual: some View {
        ZStack {
            if let thumbnail {
                Image(uiImage: thumbnail).resizable().scaledToFill()
            } else if let data = attachment.thumbnail, let preview = UIImage(data: data) {
                // XEP-0264: the sender's small preview, until the file is here.
                Image(uiImage: preview).resizable().scaledToFill().blur(radius: 6)
            } else {
                Rectangle().fill(Color(.tertiarySystemFill))
                Image(systemName: attachment.kind == .video ? "video" : "photo")
                    .font(.largeTitle).foregroundStyle(.secondary)
            }
            overlay
        }
        .aspectRatio(min(max(aspectRatio, 0.5), 2), contentMode: .fit)
        .frame(width: 240)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .contentShape(RoundedRectangle(cornerRadius: 16))
        .onTapGesture {
            if localURL != nil { viewing = true } else { download() }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(attachment.kind == .video ? "Video" : "Photo")
        .accessibilityHint(localURL == nil ? "Double-tap to download" : "Double-tap to view")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("attachment.\(attachment.kind.rawValue)")
    }

    @ViewBuilder
    private var overlay: some View {
        if let progress {
            ProgressRing(progress: progress)
        } else if localURL == nil {
            VStack(spacing: 4) {
                Image(systemName: "arrow.down.circle.fill").font(.largeTitle)
                if let size = attachment.size { Text(Self.format(size)).font(.caption.bold()) }
            }
            .foregroundStyle(.white)
            .shadow(radius: 3)
        } else if attachment.kind == .video {
            Image(systemName: "play.circle.fill").font(.system(size: 48)).foregroundStyle(.white).shadow(radius: 3)
        }
    }

    // MARK: Files

    private var fileRow: some View {
        Button {
            if let localURL { previewURL = localURL } else { download() }
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    if let progress {
                        ProgressRing(progress: progress, size: 32)
                    } else {
                        Image(systemName: localURL == nil ? "arrow.down.doc.fill" : "doc.fill").font(.title)
                    }
                }
                .frame(width: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(attachment.fileName).font(.callout.weight(.medium)).lineLimit(2)
                    Text(fileDetail).font(.caption).opacity(0.8)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: 260, alignment: .leading)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("attachment.file")
    }

    private var fileDetail: String {
        var parts: [String] = []
        if let size = attachment.size { parts.append(Self.format(size)) }
        if let type = attachment.mimeType.flatMap({ UTType(mimeType: $0)?.localizedDescription }) { parts.append(type) }
        if let error = attachment.error { parts.append(error) }
        return parts.isEmpty ? String(localized: "File") : parts.joined(separator: " · ")
    }

    static func format(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private func download() {
        guard let id = message.id, attachment.url != nil, progress == nil,
              let session = app.manager.session(for: accountID) else { return }
        Task {
            do { try await session.download(messageID: id) } catch { errorMessage = String(describing: error) }
        }
    }
}

struct ProgressRing: View {
    let progress: Double
    var size: CGFloat = 44

    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.35), lineWidth: 4)
            Circle().trim(from: 0, to: max(0.02, progress))
                .stroke(.white, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
        .padding(6)
        .background(Circle().fill(.black.opacity(0.35)))
        .animation(.linear(duration: 0.2), value: progress)
        .accessibilityLabel("Transferring")
        .accessibilityValue("\(Int(progress * 100)) percent")
    }
}

// MARK: - Full screen

struct MediaViewer: View {
    let url: URL
    let kind: Attachment.Kind
    let fileName: String
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?

    var body: some View {
        NavigationStack {
            Group {
                if kind == .video {
                    VideoPlayer(player: player)
                        .onAppear {
                            player = AVPlayer(url: url)
                            player?.play()
                        }
                        .onDisappear { player?.pause() }
                } else if let image = UIImage(contentsOfFile: url.path) {
                    ZoomableImage(image: image)
                } else {
                    ContentUnavailableView("Can't Show This Image", systemImage: "photo")
                }
            }
            .ignoresSafeArea(edges: .bottom)
            .background(.black)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .navigationTitle(fileName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { ShareLink(item: url) }
            }
        }
    }
}

/// Pinch and double-tap zoom, as in Photos.
private struct ZoomableImage: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> UIScrollView {
        let scroll = UIScrollView()
        scroll.delegate = context.coordinator
        scroll.maximumZoomScale = 5
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.frame = scroll.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scroll.addSubview(imageView)
        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.zoom(_:)))
        doubleTap.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(doubleTap)
        context.coordinator.imageView = imageView
        return scroll
    }

    func updateUIView(_ scroll: UIScrollView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var imageView: UIImageView?

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        @objc func zoom(_ gesture: UITapGestureRecognizer) {
            guard let scroll = gesture.view as? UIScrollView else { return }
            if scroll.zoomScale > 1 {
                scroll.setZoomScale(1, animated: true)
            } else {
                let point = gesture.location(in: imageView)
                scroll.zoom(to: CGRect(x: point.x - 50, y: point.y - 50, width: 100, height: 100), animated: true)
            }
        }
    }
}

// MARK: - Voice messages and audio

/// One sound at a time, app-wide.
@MainActor
@Observable
final class AudioPlayback: NSObject, AVAudioPlayerDelegate {
    static let shared = AudioPlayback()

    private(set) var current: URL?
    private(set) var isPlaying = false
    private(set) var elapsed: TimeInterval = 0
    private var player: AVAudioPlayer?
    private var timer: Timer?

    func toggle(_ url: URL) {
        if current == url, let player {
            if player.isPlaying { pause() } else { resume() }
            return
        }
        stop()
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        guard let player = try? AVAudioPlayer(contentsOf: url) else { return }
        player.delegate = self
        self.player = player
        current = url
        resume()
    }

    func duration(of url: URL) -> TimeInterval? {
        (try? AVAudioPlayer(contentsOf: url))?.duration
    }

    private func resume() {
        player?.play()
        isPlaying = true
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.elapsed = self?.player?.currentTime ?? 0 }
        }
    }

    private func pause() {
        player?.pause()
        isPlaying = false
        timer?.invalidate()
    }

    func stop() {
        pause()
        player = nil
        current = nil
        elapsed = 0
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.stop() }
    }
}

struct AudioMessageView: View {
    let attachment: Attachment
    let url: URL?
    let isOutgoing: Bool
    let progress: Double?
    let download: () -> Void

    @State private var playback = AudioPlayback.shared
    @State private var duration: TimeInterval?

    private var isCurrent: Bool { url != nil && playback.current == url }

    var body: some View {
        HStack(spacing: 10) {
            Button {
                if let url { playback.toggle(url) } else { download() }
            } label: {
                ZStack {
                    if let progress {
                        ProgressRing(progress: progress, size: 26)
                    } else {
                        Image(systemName: url == nil ? "arrow.down.circle.fill"
                              : isCurrent && playback.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 34))
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(url == nil ? "Download" : isCurrent && playback.isPlaying ? "Pause" : "Play")
            .accessibilityIdentifier("attachment.audio")
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: isCurrent ? min(playback.elapsed, total) : 0, total: max(total, 0.1))
                    .tint(isOutgoing ? .white : .accentColor)
                Text(label).font(.caption.monospacedDigit()).opacity(0.8)
            }
            .frame(width: 140)
        }
        .task(id: url) {
            if let url { duration = playback.duration(of: url) }
        }
    }

    private var total: TimeInterval { duration ?? attachment.duration ?? 0 }

    private var label: String {
        let shown = isCurrent ? playback.elapsed : total
        let name = attachment.isVoiceMessage ? String(localized: "Voice message") : attachment.fileName
        return total > 0 ? "\(Duration.seconds(shown).formatted(.time(pattern: .minuteSecond))) · \(name)" : name
    }
}

/// Records a voice message as AAC in an .m4a file (PLAN.md Phase 7).
@MainActor
@Observable
final class VoiceRecorder {
    private(set) var isRecording = false
    private(set) var elapsed: TimeInterval = 0
    private var recorder: AVAudioRecorder?
    private var timer: Timer?

    func start() async -> Bool {
        guard await AVAudioApplication.requestRecordPermission() else { return false }
        // Activating the session can take a while (or hang, in a simulator
        // without the Mac's microphone): never on the main thread.
        let started = await Task.detached { () -> RecorderBox? in
            let session = AVAudioSession.sharedInstance()
            do {
                try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
                try session.setActive(true)
                let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).m4a")
                let recorder = try AVAudioRecorder(url: url, settings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 44_100,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderBitRateKey: 64_000,
                ])
                return recorder.record() ? RecorderBox(recorder) : nil
            } catch {
                return nil
            }
        }.value
        guard let started else { return false }
        recorder = started.recorder
        AudioPlayback.shared.stop()
        isRecording = true
        elapsed = 0
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.elapsed = self?.recorder?.currentTime ?? 0 }
        }
        return true
    }

    /// Stops and returns the file and its length; `nil` if nothing usable.
    func finish() -> (URL, TimeInterval)? {
        guard let recorder else { return nil }
        let duration = recorder.currentTime
        recorder.stop()
        reset()
        guard duration >= 0.5 else {
            try? FileManager.default.removeItem(at: recorder.url)
            return nil
        }
        return (recorder.url, duration)
    }

    func cancel() {
        recorder?.stop()
        if let url = recorder?.url { try? FileManager.default.removeItem(at: url) }
        reset()
    }

    private func reset() {
        timer?.invalidate()
        recorder = nil
        isRecording = false
        Task.detached { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
    }
}

/// Carries a recorder out of the task that set it up.
nonisolated private final class RecorderBox: @unchecked Sendable {
    let recorder: AVAudioRecorder
    init(_ recorder: AVAudioRecorder) { self.recorder = recorder }
}
