import AVFoundation
import CoreMedia
import CryptoKit
import CutlineCore
import Foundation

/// Lightweight ProRes 422 Proxy copies of heavy media for preview. A proxy keeps the original's
/// sample times, duration and orientation, and passes its sound through, so it can stand in for
/// the original 1:1 in an AVComposition; only the pixel size differs.
public enum Proxies {
    public enum Quality: String, CaseIterable, Sendable {
        /// A quarter of the width and height.
        case quarter
        /// Half the width and height.
        case half
        /// Fits 1920×1080 (1080×1920 for portrait), never larger than the original.
        case hd
    }

    /// What one transcode did.
    public struct Made: Sendable {
        public var url: URL
        /// Pixel size before orientation.
        public var size: CGSize
        /// Wall-clock seconds; 0 when the proxy was already cached.
        public var elapsed: Seconds
        /// Media seconds transcoded per wall-clock second.
        public var realtimeFactor: Double
    }

    static let directory: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Cutline/proxies", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    static let lock = NSLock()
    nonisolated(unsafe) static var inFlight: [String: Task<Made, Error>] = [:]

    /// Where the proxy of a file at a quality lives; changes when the file's size or date changes.
    public static func url(for media: MediaAsset, quality: Quality) -> URL {
        let attrs = try? FileManager.default.attributesOfItem(atPath: media.path)
        let stamp = "\(media.path)|\(attrs?[.size] as? Int ?? 0)|\((attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)|\(quality.rawValue)|v1"
        let key = SHA256.hash(data: Data(stamp.utf8)).map { String(format: "%02x", $0) }.joined().prefix(24)
        return directory.appendingPathComponent("\(key).mov")
    }

    /// The proxy if it is already made.
    public static func cached(_ media: MediaAsset, quality: Quality) -> URL? {
        let u = url(for: media, quality: quality)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    /// Footage worth proxying: wider than 2560 px on its long side, faster than 60 fps, or
    /// (when `format` is given) 10-bit long-GOP H.264/HEVC.
    public static func shouldProxy(_ media: MediaAsset, format: CMFormatDescription? = nil) -> Bool {
        guard media.hasVideo, !media.isImage else { return false }
        if max(media.width, media.height) > 2560 || media.fps > 60.5 { return true }
        guard let format else { return false }
        let codec = CMFormatDescriptionGetMediaSubType(format)
        let longGOP = [kCMVideoCodecType_HEVC, kCMVideoCodecType_H264, kCMVideoCodecType_HEVCWithAlpha].contains(codec)
        return longGOP && bitDepth(format) > 8
    }

    /// The first video track's format, for `shouldProxy`.
    public static func format(of media: MediaAsset) async -> CMFormatDescription? {
        guard let track = try? await AVURLAsset(url: media.url).loadTracks(withMediaType: .video).first else { return nil }
        return try? await track.load(.formatDescriptions).first
    }

    /// Bits per luma sample, from the format's extension or the HEVC configuration record.
    static func bitDepth(_ fd: CMFormatDescription) -> Int {
        if let bits = CMFormatDescriptionGetExtension(fd, extensionKey: kCMFormatDescriptionExtension_BitsPerComponent) as? Int { return bits }
        if let atoms = CMFormatDescriptionGetExtension(fd, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Any],
           let hvcC = atoms["hvcC"] as? Data, hvcC.count > 17 {
            return Int(hvcC[hvcC.startIndex + 17] & 0x07) + 8
        }
        let transfer = CMFormatDescriptionGetExtension(fd, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String
        if transfer == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String) || transfer == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String) { return 10 }
        return 8
    }

    /// Makes (or reuses) the proxy and returns its file.
    public static func make(_ media: MediaAsset, quality: Quality, progress: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
        try await transcode(media, quality: quality, progress: progress).url
    }

    /// `make`, with the size and speed of the transcode.
    public static func transcode(_ media: MediaAsset, quality: Quality, progress: (@Sendable (Double) -> Void)? = nil) async throws -> Made {
        guard media.hasVideo, !media.isImage else { throw EditError("\(media.name) has no video to proxy") }
        let url = url(for: media, quality: quality)
        if FileManager.default.fileExists(atPath: url.path) {
            let track = try await AVURLAsset(url: url).loadTracks(withMediaType: .video).first
            let size = try await track?.load(.naturalSize) ?? .zero
            return Made(url: url, size: size, elapsed: 0, realtimeFactor: .infinity)
        }
        let key = url.lastPathComponent
        let task = lock.withLock { () -> Task<Made, Error> in
            if let t = inFlight[key] { return t }
            let t = Task<Made, Error> {
                let tmp = directory.appendingPathComponent("tmp-\(UUID().uuidString).mov")
                defer { try? FileManager.default.removeItem(at: tmp) }
                let began = Date()
                let size = try await write(media, quality: quality, to: tmp, progress: progress)
                try? FileManager.default.removeItem(at: url)
                try FileManager.default.moveItem(at: tmp, to: url)
                let elapsed = Date().timeIntervalSince(began)
                return Made(url: url, size: size, elapsed: elapsed, realtimeFactor: media.duration / max(elapsed, 1e-6))
            }
            inFlight[key] = t
            return t
        }
        defer { lock.withLock { _ = inFlight.removeValue(forKey: key) } }
        return try await task.value
    }

    /// Proxy pixel size for a natural (pre-rotation) size, even on both sides.
    static func size(of natural: CGSize, quality: Quality) -> CGSize {
        let s: Double
        switch quality {
        case .quarter: s = 0.25
        case .half: s = 0.5
        case .hd:
            let long = max(natural.width, natural.height), short = min(natural.width, natural.height)
            s = min(1, 1920 / max(long, 1), 1080 / max(short, 1))
        }
        let even = { (v: CGFloat) in CGFloat(max(2, Int((v * s).rounded()) / 2 * 2)) }
        return CGSize(width: even(natural.width), height: even(natural.height))
    }

    /// The track transform's rotation and flips with the translation redone for `size`.
    static func transform(_ t: CGAffineTransform, for size: CGSize) -> CGAffineTransform {
        var linear = t
        linear.tx = 0
        linear.ty = 0
        let r = CGRect(origin: .zero, size: size).applying(linear)
        linear.tx = -r.minX
        linear.ty = -r.minY
        return linear
    }

    /// Decodes every frame with AVAssetReader and encodes ProRes 422 Proxy at the original sample
    /// times; the decoder scales. Audio tracks are copied without re-encoding when the container allows.
    static func write(_ media: MediaAsset, quality: Quality, to url: URL, progress: (@Sendable (Double) -> Void)?) async throws -> CGSize {
        let asset = AVURLAsset(url: media.url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let video = try await asset.loadTracks(withMediaType: .video).first else { throw EditError("\(media.name) has no video") }
        let (natural, preferred, timescale, formats, rate) = try await video.load(.naturalSize, .preferredTransform, .naturalTimeScale, .formatDescriptions, .nominalFrameRate)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let duration = try await asset.load(.duration)
        let format = formats.first
        let deep = format.map { bitDepth($0) > 8 } ?? false
        let size = size(of: natural, quality: quality)

        let reader = try AVAssetReader(asset: asset)
        let videoOut = AVAssetReaderTrackOutput(track: video, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: deep ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: Int(size.width), kCVPixelBufferHeightKey as String: Int(size.height),
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ])
        videoOut.alwaysCopiesSampleData = false
        reader.add(videoOut)

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        writer.movieTimeScale = max(600, timescale)
        var settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.proRes422Proxy,
            AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
            AVVideoScalingModeKey: AVVideoScalingModeResize,
        ]
        if let format, let color = colorProperties(format) { settings[AVVideoColorPropertiesKey] = color }
        if rate > 0 { settings[AVVideoCompressionPropertiesKey] = [AVVideoExpectedSourceFrameRateKey: Double(rate)] }
        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        videoIn.expectsMediaDataInRealTime = false
        videoIn.transform = transform(preferred, for: size)
        videoIn.mediaTimeScale = timescale
        writer.add(videoIn)

        var audio: [(AVAssetReaderTrackOutput, AVAssetWriterInput)] = []
        for track in audioTracks {
            let fds = try await track.load(.formatDescriptions)
            var out = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            var input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: fds.first)
            if !writer.canAdd(input) || fds.first == nil {
                out = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false])
                input = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false, AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false])
            }
            guard reader.canAdd(out), writer.canAdd(input) else { continue }
            out.alwaysCopiesSampleData = false
            input.expectsMediaDataInRealTime = false
            reader.add(out)
            writer.add(input)
            audio.append((out, input))
        }

        guard reader.startReading() else { throw reader.error ?? EditError("Cannot read \(media.name)") }
        guard writer.startWriting() else { throw writer.error ?? EditError("Cannot write a proxy of \(media.name)") }
        writer.startSession(atSourceTime: .zero)
        let total = max(duration.seconds, 0.001)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await Exporter.pump(videoOut, into: videoIn, offset: .zero) { t in progress?(min(1, t / total)) } }
            for (out, input) in audio {
                group.addTask { try await Exporter.pump(out, into: input, offset: .zero, report: nil) }
            }
            try await group.waitForAll()
        }
        if reader.status == .failed {
            writer.cancelWriting()
            throw reader.error ?? EditError("Decoding \(media.name) failed")
        }
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? EditError("Writing the proxy of \(media.name) failed") }
        progress?(1)
        return size
    }

    /// Primaries, transfer and matrix of a format, when all three are tagged.
    static func colorProperties(_ fd: CMFormatDescription) -> [String: Any]? {
        func ext(_ key: CFString) -> String? { CMFormatDescriptionGetExtension(fd, extensionKey: key) as? String }
        guard let p = ext(kCMFormatDescriptionExtension_ColorPrimaries),
              let t = ext(kCMFormatDescriptionExtension_TransferFunction),
              let m = ext(kCMFormatDescriptionExtension_YCbCrMatrix) else { return nil }
        return [AVVideoColorPrimariesKey: p, AVVideoTransferFunctionKey: t, AVVideoYCbCrMatrixKey: m]
    }
}
