import AVFoundation
import CoreMedia
import CutlineCore
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Deliverables besides the movie: stills, image sequences, audio mixdowns and animated GIFs,
/// all rendered through the same compositor and audio mix as export.
public enum Delivery {
    public enum StillFormat: String, CaseIterable, Sendable {
        case png, jpeg, heic
        /// 16-bit RGB TIFF; the compositor renders 8 bits per channel, so this is lossless, not deeper.
        case tiff16

        public var fileExtension: String { self == .tiff16 ? "tiff" : rawValue }
        var type: UTType {
            switch self {
            case .png: .png
            case .jpeg: .jpeg
            case .heic: .heic
            case .tiff16: .tiff
            }
        }
    }

    /// 48 kHz, in the timeline's layout unless another is asked for. There is no MP3 encoder on macOS.
    public enum AudioFormat: String, CaseIterable, Sendable {
        case wav24, wav32f, aiff24, aac256, alac

        public var fileExtension: String {
            switch self {
            case .wav24, .wav32f: "wav"
            case .aiff24: "aiff"
            case .aac256, .alac: "m4a"
            }
        }

        /// File extensions that pick the right container.
        var extensions: Set<String> {
            switch self {
            case .wav24, .wav32f: ["wav"]
            case .aiff24: ["aiff", "aif"]
            case .aac256, .alac: ["m4a"]
            }
        }

        var settings: [String: Any] { settings(.stereo, tag: kAudioChannelLayoutTag_Stereo) }

        /// The file's channel layout: SMPTE order for PCM, the codec's order for AAC and ALAC, which can't carry 7.1 rears.
        func channelLayoutTag(_ layout: AudioLayout) throws -> AudioChannelLayoutTag {
            guard self == .aac256 || self == .alac else { return layout.channelLayoutTag }
            guard let tag = layout.codecChannelLayoutTag else { throw EditError("\(rawValue) can't carry 7.1 with rear surrounds; use wav24, wav32f or aiff24") }
            return tag
        }

        /// AAC is 256 kb/s for stereo and 64 kb/s per channel for surround.
        func settings(_ layout: AudioLayout, tag: AudioChannelLayoutTag) -> [String: Any] {
            var base: [String: Any] = [AVSampleRateKey: 48_000, AVNumberOfChannelsKey: layout.channelCount]
            if layout != .stereo { base[AVChannelLayoutKey] = AudioLayout.layoutData(tag) }
            func pcm(_ bits: Int, float: Bool, bigEndian: Bool) -> [String: Any] {
                base.merging([AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: bits, AVLinearPCMIsFloatKey: float, AVLinearPCMIsBigEndianKey: bigEndian, AVLinearPCMIsNonInterleaved: false]) { $1 }
            }
            switch self {
            case .wav24: return pcm(24, float: false, bigEndian: false)
            case .wav32f: return pcm(32, float: true, bigEndian: false)
            case .aiff24: return pcm(24, float: false, bigEndian: true)
            case .aac256: return base.merging([AVFormatIDKey: kAudioFormatMPEG4AAC, AVEncoderBitRateKey: max(256_000, 64_000 * layout.channelCount)]) { $1 }
            case .alac: return base.merging([AVFormatIDKey: kAudioFormatAppleLossless, AVEncoderBitDepthHintKey: 24]) { $1 }
            }
        }
    }

    // MARK: Stills

    /// One full-quality frame per time, named "<name>_<frame number>". `size` bounds the output; nil renders the canvas size.
    public static func stills(_ built: BuiltTimeline, times: [Seconds], to dir: URL, format: StillFormat, size: CGSize? = nil, name: String = "still") async throws -> [URL] {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let gen = AVAssetImageGenerator(asset: built.composition)
        gen.videoComposition = built.videoComposition
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        if let size { gen.maximumSize = size }
        let fps = built.scene.project.canvas.fps
        var urls: [URL] = []
        do {
            for t in times {
                let clamped = min(max(0, t), max(0, built.duration - 1 / fps))
                let (img, _) = try await gen.image(at: TimelineBuilder.time(clamped))
                let url = dir.appendingPathComponent(String(format: "%@_%06d.%@", name, Int((clamped * fps).rounded()), format.fileExtension))
                urls.append(url)
                try write(img, to: url, format: format)
            }
        } catch {
            for u in urls { try? FileManager.default.removeItem(at: u) }
            throw error
        }
        return urls
    }

    /// Every frame of `range` (default the whole timeline) as numbered files "<name>_000001.<ext>". Returns the frame count.
    public static func imageSequence(_ built: BuiltTimeline, range: TimeRange? = nil, to dir: URL, format: StillFormat, name: String = "frame", progress: (@Sendable (Double) -> Void)? = nil) async throws -> Int {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let span = timeRange(built, range)
        let (reader, out) = try await videoReader(built, range: span, videoComposition: built.videoComposition)
        let total = max(span.duration.seconds, 0.001)
        let start = span.start.seconds
        return try await runBlocking { cancelled in
            let encode = DispatchQueue(label: "cutline.delivery.encode", attributes: .concurrent)
            let slots = DispatchSemaphore(value: max(2, ProcessInfo.processInfo.activeProcessorCount - 1))
            let group = DispatchGroup()
            let failure = FailureBox()
            var n = 0
            while !cancelled(), failure.error == nil, let sample = out.copyNextSampleBuffer() {
                guard let pb = CMSampleBufferGetImageBuffer(sample), let img = cgImage(pb) else { continue }
                n += 1
                let url = dir.appendingPathComponent(String(format: "%@_%06d.%@", name, n, format.fileExtension))
                slots.wait()
                group.enter()
                encode.async {
                    do { try write(img, to: url, format: format) } catch { failure.set(error) }
                    slots.signal()
                    group.leave()
                }
                progress?(min(1, (CMSampleBufferGetPresentationTimeStamp(sample).seconds - start) / total))
            }
            group.wait()
            reader.cancelReading()
            let error: Error? = failure.error ?? (cancelled() ? CancellationError() : reader.status == .failed ? reader.error ?? EditError("Rendering frames failed") : nil)
            if let error {
                for i in stride(from: 1, through: n, by: 1) { try? FileManager.default.removeItem(at: dir.appendingPathComponent(String(format: "%@_%06d.%@", name, i, format.fileExtension))) }
                throw error
            }
            return n
        }
    }

    // MARK: Audio

    /// The timeline's mix over `range` (default the whole timeline) at 48 kHz, padded with silence to the full length.
    /// It is in the timeline's master layout, or folded down (ITU-R BS.775) to `layout` when given.
    /// Under a master loudness target the mix is conformed to it first; a failed write leaves no file.
    @discardableResult
    public static func audio(_ built: BuiltTimeline, range: TimeRange? = nil, to url: URL, format: AudioFormat, layout: AudioLayout? = nil) async throws -> LoudnessConform? {
        let target = layout ?? built.layout
        return try await Exporter.removingOnFailure(url) {
            if built.layout != .stereo || target != .stereo || built.scene.project.master.loudnessTarget != nil {
                return try await audio(built, range: range, to: url, format: format, target: target)
            }
            try await stereoAudio(built, range: range, to: url, format: format)
            return nil
        }
    }

    static func stereoAudio(_ built: BuiltTimeline, range: TimeRange?, to url: URL, format: AudioFormat) async throws {
        let span = timeRange(built, range)
        let comp = built.composition
        let tracks = try await comp.loadTracks(withMediaType: .audio)
        var reader: AVAssetReader?
        var mix: AVAssetReaderAudioMixOutput?
        if !tracks.isEmpty {
            let r = try AVAssetReader(asset: comp)
            r.timeRange = span
            let out = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
            ])
            out.audioMix = built.audioMix
            out.audioTimePitchAlgorithm = .spectral
            r.add(out)
            guard r.startReading() else { throw r.error ?? EditError("Cannot read the timeline's sound") }
            reader = r
            mix = out
        }

        guard format.extensions.contains(url.pathExtension.lowercased()) else {
            throw EditError("\(format.rawValue) is written as .\(format.fileExtension); \(url.lastPathComponent) has another extension")
        }
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: true)
        let chunk: AVAudioFrameCount = 4_800
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk) else { throw EditError("Cannot allocate audio") }
        let totalFrames = Int64((span.duration.seconds * 48_000).rounded())
        let start = span.start
        try await runBlocking { cancelled in
            var written: Int64 = 0
            func silence(until end: Int64) throws {
                while written < end {
                    let n = AVAudioFrameCount(min(Int64(chunk), end - written))
                    memset(buffer.floatChannelData![0], 0, Int(n) * 8)
                    buffer.frameLength = n
                    try file.write(from: buffer)
                    written += Int64(n)
                }
            }
            while !cancelled(), written < totalFrames, let mix, let sample = mix.copyNextSampleBuffer() {
                guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
                let at = Int64(((CMSampleBufferGetPresentationTimeStamp(sample) - start).seconds * 48_000).rounded())
                try silence(until: min(at, totalFrames))
                var offset = 0
                var frames = min(CMSampleBufferGetNumSamples(sample), CMBlockBufferGetDataLength(block) / 8)
                frames = Int(min(Int64(frames), totalFrames - written))
                while frames > 0 {
                    let n = min(frames, Int(chunk))
                    CMBlockBufferCopyDataBytes(block, atOffset: offset * 8, dataLength: n * 8, destination: buffer.floatChannelData![0])
                    buffer.frameLength = AVAudioFrameCount(n)
                    try file.write(from: buffer)
                    written += Int64(n)
                    offset += n
                    frames -= n
                }
            }
            if cancelled() { throw CancellationError() }
            if let reader, reader.status == .failed { throw reader.error ?? EditError("Mixing the timeline's sound failed") }
            reader?.cancelReading()
            try silence(until: totalFrames)
            file.close()
        }
    }

    static func audio(_ built: BuiltTimeline, range: TimeRange?, to url: URL, format: AudioFormat, target: AudioLayout) async throws -> LoudnessConform? {
        guard format.extensions.contains(url.pathExtension.lowercased()) else {
            throw EditError("\(format.rawValue) is written as .\(format.fileExtension); \(url.lastPathComponent) has another extension")
        }
        let span = timeRange(built, range)
        let count = Int64((span.duration.seconds * 48_000).rounded())
        let master = built.scene.project.master
        let fm = FileManager.default
        let mix = fm.temporaryDirectory.appendingPathComponent("cutline-mix-\(UUID().uuidString).caf")
        let conformed = fm.temporaryDirectory.appendingPathComponent("cutline-loudness-\(UUID().uuidString).caf")
        defer {
            try? fm.removeItem(at: mix)
            try? fm.removeItem(at: conformed)
        }
        var source: URL
        var frames: Range<Int64>
        if built.layout != .stereo {
            guard let s = built.surround else { throw EditError("The \(built.layout.title) mix isn't rendered yet; render the project's stems first") }
            let from = Int64((span.start.seconds * 48_000).rounded())
            (source, frames) = (s, from..<(from + count))
        } else {
            _ = try await AudioIO.mixdown(built, range: TimeRange(span.start.seconds, span.end.seconds), to: mix)
            (source, frames) = (mix, 0..<count)
        }
        var conform: LoudnessConform?
        if let t = master.loudnessTarget {
            conform = try await LoudnessConform.run(source, layout: built.layout, frames: frames, target: t, ceiling: master.ceiling, to: conformed)
            (source, frames) = (conformed, 0..<count)
        }
        try write(source, from: built.layout, frames: frames, to: url, layout: target, format: format)
        return conform
    }

    /// Folds a 48 kHz mono, stereo, 5.1 or 7.1 file (channels in SMPTE order) down to `layout` per ITU-R BS.775:
    /// centre and surrounds at −3 dB into L/R, LFE dropped; mono is the average of that stereo fold.
    public static func downmix(_ source: URL, to url: URL, layout: AudioLayout = .stereo, format: AudioFormat) throws {
        let file = try AVAudioFile(forReading: source)
        guard let from = AudioLayout(channelCount: Int(file.processingFormat.channelCount)) else { throw EditError("\(source.lastPathComponent) has \(file.processingFormat.channelCount) channels; downmix reads mono, stereo, 5.1 and 7.1") }
        guard format.extensions.contains(url.pathExtension.lowercased()) else {
            throw EditError("\(format.rawValue) is written as .\(format.fileExtension); \(url.lastPathComponent) has another extension")
        }
        try write(source, from: from, frames: 0..<file.length, to: url, layout: layout, format: format)
    }

    static func write(_ source: URL, from: AudioLayout, frames: Range<Int64>, to url: URL, layout: AudioLayout, format: AudioFormat) throws {
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Exporter.removingOnFailureSync(url) {
            let tag = try format.channelLayoutTag(layout)
            let input = try AVAudioFile(forReading: source)
            let output = try AVAudioFile(forWriting: url, settings: format.settings(layout, tag: tag), commonFormat: .pcmFormatFloat32, interleaved: false)
            let matrix = from.downmixMatrix(to: layout)
            try AudioIO.remix(input, matrix: layout.channelOrder(in: tag).map { matrix[$0] }, frames: frames) { try AudioIO.write($0, to: output) }
            output.close()
        }
    }

    // MARK: GIF

    /// An endlessly looping GIF of `range`, `width` pixels wide, rendered at `fps` straight from the compositor.
    public static func gif(_ built: BuiltTimeline, range: TimeRange, to url: URL, fps: Double = 12, width: Int = 480) async throws {
        try await Exporter.removingOnFailure(url) { try await writeGIF(built, range: range, to: url, fps: fps, width: width) }
    }

    static func writeGIF(_ built: BuiltTimeline, range: TimeRange, to url: URL, fps: Double, width: Int) async throws {
        guard fps > 0, width >= 2 else { throw EditError("GIF needs a positive fps and width") }
        let span = timeRange(built, range)
        guard let vc = built.videoComposition.mutableCopy() as? AVMutableVideoComposition else { throw EditError("Cannot configure the GIF render") }
        let canvas = built.videoComposition.renderSize
        let w = max(2, width / 2 * 2)
        let h = max(2, Int((Double(w) * canvas.height / max(canvas.width, 1) / 2).rounded()) * 2)
        vc.renderSize = CGSize(width: w, height: h)
        vc.frameDuration = CMTime(value: 1000, timescale: CMTimeScale((fps * 1000).rounded()))
        let (reader, out) = try await videoReader(built, range: span, videoComposition: vc)
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let images: [CGImage] = try await runBlocking { cancelled in
            var images: [CGImage] = []
            while !cancelled(), let sample = out.copyNextSampleBuffer() {
                if let pb = CMSampleBufferGetImageBuffer(sample), let img = cgImage(pb) { images.append(img) }
            }
            reader.cancelReading()
            if cancelled() { throw CancellationError() }
            if reader.status == .failed { throw reader.error ?? EditError("Rendering the GIF failed") }
            return images
        }
        guard !images.isEmpty else { throw EditError("No frames in \(fmt(span.start.seconds))–\(fmt(span.end.seconds))s") }
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, images.count, nil) else { throw EditError("Cannot create \(url.lastPathComponent)") }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for (i, img) in images.enumerated() {
            // Centisecond delays, rounded cumulatively so the loop keeps real time.
            let delay = ((Double(i + 1) * 100 / fps).rounded() - (Double(i) * 100 / fps).rounded()) / 100
            CGImageDestinationAddImage(dest, img, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay, kCGImagePropertyGIFUnclampedDelayTime: delay]] as CFDictionary)
        }
        guard CGImageDestinationFinalize(dest) else { throw EditError("Cannot write \(url.lastPathComponent)") }
    }

    // MARK: Helpers

    static func timeRange(_ built: BuiltTimeline, _ range: TimeRange?) -> CMTimeRange {
        built.readRange(range)
    }

    static func videoReader(_ built: BuiltTimeline, range: CMTimeRange, videoComposition: AVVideoComposition) async throws -> (AVAssetReader, AVAssetReaderVideoCompositionOutput) {
        let reader = try AVAssetReader(asset: built.composition)
        reader.timeRange = range
        let tracks = try await built.composition.loadTracks(withMediaType: .video)
        let out = AVAssetReaderVideoCompositionOutput(videoTracks: tracks, videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        out.videoComposition = videoComposition
        out.alwaysCopiesSampleData = false
        reader.add(out)
        guard reader.startReading() else { throw reader.error ?? EditError("Cannot render the timeline") }
        return (reader, out)
    }

    /// The space AVAssetImageGenerator tags composition frames with.
    static let videoSpace = CGColorSpace(name: CGColorSpace.coreMedia709) ?? CutlineCompositor.colorSpace

    /// An opaque copy of a 32BGRA frame, tagged as Rec. 709 video the way AVFoundation presents it.
    static func cgImage(_ pb: CVPixelBuffer) -> CGImage? {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), row = CVPixelBufferGetBytesPerRow(pb)
        guard let provider = CGDataProvider(data: Data(bytes: base, count: row * h) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: row, space: videoSpace,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    static func write(_ image: CGImage, to url: URL, format: StillFormat) throws {
        var img = image
        var props: [CFString: Any] = [:]
        switch format {
        case .jpeg: props[kCGImageDestinationLossyCompressionQuality] = 0.92
        case .heic: props[kCGImageDestinationLossyCompressionQuality] = 0.9
        case .png: break
        case .tiff16:
            let space = image.colorSpace ?? videoSpace
            guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 16, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue) else { throw EditError("Cannot make a 16-bit image") }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            guard let deep = ctx.makeImage() else { throw EditError("Cannot make a 16-bit image") }
            img = deep
            props[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFCompression: 5]
        }
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, format.type.identifier as CFString, 1, nil) else { throw EditError("Cannot write \(url.lastPathComponent)") }
        CGImageDestinationAddImage(dest, img, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw EditError("Cannot write \(url.lastPathComponent)") }
    }

    final class FailureBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Error?
        var error: Error? { lock.withLock { stored } }
        func set(_ e: Error) { lock.withLock { if stored == nil { stored = e } } }
    }
}
