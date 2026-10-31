import AVFoundation
import CoreImage
import CutlineCore
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum MediaProbe {
    public static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "tiff", "tif", "gif", "webp", "bmp"]

    /// "lake-tahoe_take2.mov" reads as "Lake Tahoe Take2".
    public static func displayName(_ url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
            .split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    public static func isImage(_ url: URL) -> Bool {
        imageExtensions.contains(url.pathExtension.lowercased())
    }

    public static func probe(_ url: URL, id: String) async throws -> MediaAsset {
        guard FileManager.default.fileExists(atPath: url.path) else { throw EditError("File not found: \(url.path)") }
        let name = displayName(url)
        if isImage(url) {
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
                  let w = props[kCGImagePropertyPixelWidth] as? Int,
                  let h = props[kCGImagePropertyPixelHeight] as? Int
            else { throw EditError("Cannot read image \(url.path)") }
            let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
            let rotated = orientation >= 5
            return MediaAsset(id: id, path: url.path, name: name, duration: 0, width: rotated ? h : w, height: rotated ? w : h, fps: 0, hasVideo: true, hasAudio: false, isImage: true)
        }
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard !videoTracks.isEmpty || !audioTracks.isEmpty else { throw EditError("\(url.lastPathComponent) has no audio or video") }
        var width = 0, height = 0, fps = 0.0
        var fieldOrder: FieldOrder?
        if let v = videoTracks.first {
            let (size, transform, rate, formats) = try await v.load(.naturalSize, .preferredTransform, .nominalFrameRate, .formatDescriptions)
            let r = CGRect(origin: .zero, size: size).applying(transform)
            width = Int(abs(r.width).rounded())
            height = Int(abs(r.height).rounded())
            fps = Double(rate)
            fieldOrder = formats.first.flatMap(Self.fieldOrder)
        }
        var media = MediaAsset(id: id, path: url.path, name: name, duration: duration, width: width, height: height, fps: fps, hasVideo: !videoTracks.isEmpty, hasAudio: !audioTracks.isEmpty)
        media.fieldOrder = fieldOrder
        if let tc = try? await startTimecode(asset) {
            // A short file's nominal rate can be off; its timecode track names the exact one.
            if media.hasVideo, abs(media.fps - tc.format.rate) < 0.05 * tc.format.rate { media.fps = tc.format.rate }
            media.setTimecode(frames: tc.frames, format: tc.format)
            media.reel = tc.reel
        }
        if media.reel == nil { media.reel = await metadataReel(asset) }
        if let a = audioTracks.first, let fd = try? await a.load(.formatDescriptions).first,
           let rate = CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee.mSampleRate, rate > 0 {
            media.sampleRate = rate
        }
        if !audioTracks.isEmpty { media.audioChannels = await SourceChannels.describe(url) }
        return media
    }

    /// Field count and detail of a video format; nil when the file doesn't say.
    public static func fieldOrder(_ fd: CMFormatDescription) -> FieldOrder? {
        guard let count = CMFormatDescriptionGetExtension(fd, extensionKey: kCMFormatDescriptionExtension_FieldCount) as? Int else { return nil }
        guard count == 2 else { return .progressive }
        let detail = CMFormatDescriptionGetExtension(fd, extensionKey: kCMFormatDescriptionExtension_FieldDetail) as? String
        let bottomFirst = [kCMFormatDescriptionFieldDetail_TemporalBottomFirst, kCMFormatDescriptionFieldDetail_SpatialFirstLineLate].map { $0 as String }
        return detail.map(bottomFirst.contains) == true ? .bff : .tff
    }

    /// Source timecode of the first frame from a QuickTime or MP4 timecode track ('tmcd' or 'tc64'): the first
    /// sample's frame number counted at the track's frame duration and quanta, drop frame as its flags say, and
    /// the reel from the sample description's source reference name.
    public struct StartTimecode: Equatable, Sendable {
        public var frames: Int
        public var format: TimecodeFormat
        public var reel: String?
        public var label: String { format.string(frames) }
        public var seconds: Seconds { format.seconds(frames) }
    }

    static func startTimecode(_ asset: AVAsset) async throws -> StartTimecode? {
        guard let track = try await asset.loadTracks(withMediaType: .timecode).first else { return nil }
        // Reading blocks, so it runs off the cooperative pool.
        return try await runBlocking { _ -> StartTimecode? in
            let reader = try AVAssetReader(asset: asset)
            let out = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            reader.add(out)
            guard reader.startReading() else { return nil }
            defer { reader.cancelReading() }
            // The first buffers can be empty markers.
            for _ in 0..<8 {
                guard let sample = out.nextSample() else { return nil }
                guard let block = CMSampleBufferGetDataBuffer(sample), let fd = CMSampleBufferGetFormatDescription(sample) else { continue }
                let wide = CMFormatDescriptionGetMediaSubType(fd) == kCMTimeCodeFormatType_TimeCode64
                var raw = Data(count: CMBlockBufferGetDataLength(block))
                raw.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
                guard raw.count >= (wide ? 8 : 4) else { return nil }
                let bytes = raw.prefix(wide ? 8 : 4)
                let frame = wide ? Int(Int64(bitPattern: bytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) })) : Int(Int32(bitPattern: bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }))
                let frameDuration = CMTimeCodeFormatDescriptionGetFrameDuration(fd)
                let quanta = Int(CMTimeCodeFormatDescriptionGetFrameQuanta(fd))
                guard frameDuration.value > 0, frameDuration.timescale > 0, quanta > 0 else { return nil }
                let flags = CMTimeCodeFormatDescriptionGetTimeCodeFlags(fd)
                let drop = flags & kCMTimeCodeFlag_DropFrame != 0
                let format = TimecodeFormat(fps: Double(frameDuration.timescale) / Double(frameDuration.value), dropFrame: drop)
                let name = CMFormatDescriptionGetExtension(fd, extensionKey: kCMTimeCodeFormatDescriptionExtension_SourceReferenceName) as? [String: Any]
                let reel = (name?[kCMTimeCodeFormatDescriptionKey_Value as String] as? String).flatMap { $0.isEmpty ? nil : $0 }
                return StartTimecode(frames: max(0, frame) % max(1, format.framesPerDay), format: format, reel: reel)
            }
            return nil
        }
    }

    /// A reel or tape name from the file's metadata (QuickTime, iTunes or user data), for files whose timecode track names none.
    static func metadataReel(_ asset: AVAsset) async -> String? {
        guard let items = try? await asset.load(.metadata) else { return nil }
        for item in items {
            let key = (item.identifier?.rawValue ?? (item.key as? String) ?? "").lowercased()
            guard key.contains("reel") || key.contains("tape") else { continue }
            if let v = try? await item.load(.stringValue), !v.trimmingCharacters(in: .whitespaces).isEmpty { return v.trimmingCharacters(in: .whitespaces) }
        }
        return nil
    }
}

/// Opened AVAssets and their tracks, shared by composition building and analysis.
public final class MediaLibrary: @unchecked Sendable {
    public struct Entry {
        public let asset: AVURLAsset
        public let video: AVAssetTrack?
        public let audio: AVAssetTrack?
        public let orientation: CGImagePropertyOrientation
        public let videoRange: CMTimeRange?
        public let audioRange: CMTimeRange?
    }

    private var entries: [String: Entry] = [:]
    private var images: [String: CIImage] = [:]
    private let lock = NSLock()
    /// Set for preview libraries, which read cached proxies; export libraries (nil) always read originals.
    public let proxyQuality: Proxies.Quality?

    public init(proxyQuality: Proxies.Quality? = nil) {
        self.proxyQuality = proxyQuality
    }

    /// Forgets opened files so newly made proxies are picked up.
    public func reset() {
        lock.withLock { entries.removeAll() }
    }

    /// The opened file for `media`. Preview libraries play its proxy when one is made, as `project`'s playback
    /// settings choose (without a project, the proxy at `proxyQuality`).
    public func entry(for media: MediaAsset, project: Project? = nil) async throws -> Entry {
        if media.isTranscoding {
            throw EditError("\(media.id) is still being transcoded from \(media.conformPath) to a playable ProRes file; wait for its job (analysis_read media_id:\(media.id) wait:600)")
        }
        let proxy = proxyQuality.flatMap { q in project.map { Proxies.preview(media, in: $0) } ?? Proxies.cached(media, quality: q) }
        let key = proxy?.path ?? media.path
        if let e = lock.withLock({ entries[key] }) { return e }
        let asset = AVURLAsset(url: proxy ?? media.url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let video = try await asset.loadTracks(withMediaType: .video).first
        let audio = try await asset.loadTracks(withMediaType: .audio).first
        var orientation = CGImagePropertyOrientation.up
        var videoRange: CMTimeRange?
        if let video {
            let (t, range) = try await video.load(.preferredTransform, .timeRange)
            orientation = Self.orientation(of: t)
            videoRange = range
        }
        let audioRange = try await audio?.load(.timeRange)
        let e = Entry(asset: asset, video: video, audio: audio, orientation: orientation, videoRange: videoRange, audioRange: audioRange)
        lock.withLock { entries[key] = e }
        return e
    }

    public func image(for media: MediaAsset) -> CIImage? {
        if let i = lock.withLock({ images[media.path] }) { return i }
        if let raw = media.raw { return CameraRawRender.stillImage(media, settings: raw.settings) }
        guard let img = CIImage(contentsOf: media.url, options: [.applyOrientationProperty: true]) else { return nil }
        let normalized = img.transformed(by: CGAffineTransform(translationX: -img.extent.minX, y: -img.extent.minY))
        lock.withLock { images[media.path] = normalized }
        return normalized
    }

    static func orientation(of t: CGAffineTransform) -> CGImagePropertyOrientation {
        let angle = atan2(t.b, t.a) * 180 / .pi
        switch Int(angle.rounded()) {
        case 90: return .right
        case -90: return .left
        case 180, -180: return .down
        default: return .up
        }
    }
}
