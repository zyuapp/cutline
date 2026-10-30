import AVFoundation
import CoreImage
import CryptoKit
import CutlineCore
import Foundation
import ImageIO

/// Processed copies of a clip's picture for effects that read neighbouring frames (`video.*`: temporal noise
/// reduction, object removal). A copy covers a source window around what the clip plays, upright, with each frame at
/// its source time minus the window's start, in ProRes 422 HQ. Timelines play the copy once it is cached and the
/// unprocessed picture until then.
public enum ProcessedPicture {
    public struct Request: Sendable {
        public var clipId: String
        public var media: MediaAsset
        /// Source seconds the copy covers.
        public var range: TimeRange
        /// The enabled temporal effects, in stack order.
        public var effects: [Effect]
        public var maxWidth: Int
        public var maxHeight: Int
        public var key: String

        public var url: URL { ProcessedPicture.directory.appendingPathComponent("\(key).mov") }
        public var summary: String { effects.map { EffectCatalog.title($0.type) }.joined(separator: " + ") }
    }

    static let directory: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Cutline/processed", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    static let lock = NSLock()
    nonisolated(unsafe) static var inFlight: [String: Task<URL, Error>] = [:]

    /// What a picture clip needs processed, or nil when it has no active temporal effect. Reversed clips and clips
    /// playing an interpolated slow-motion copy keep their unprocessed picture.
    public static func request(_ clip: Clip, media: MediaAsset, canvas: Canvas, head: Seconds = 0, tail: Seconds = 0) -> Request? {
        guard clip.kind == .media, media.hasVideo, !media.isImage, !clip.reverse else { return nil }
        if clip.interpolate != nil && (clip.isRetimed || clip.speed < 0.99) { return nil }
        let effects = clip.effects.filter { e in
            guard e.enabled, e.mix > 0.001, EffectCatalog.isTemporal(e.type) else { return false }
            if e.type == "video.remove_object" { return !ObjectTrack.decodeBoxes(e.params["boxes"]?.string ?? "").isEmpty }
            return true
        }
        guard !effects.isEmpty else { return nil }
        let times = RetimeProxy.sourceTimes(clip, local: [-head, 0, clip.duration, clip.duration + tail])
        let lo = max(0, ((times.min()! - 0.1) * 2).rounded(.down) / 2)
        let hi = min(media.duration, ((times.max()! + 0.1) * 2).rounded(.up) / 2)
        guard hi > lo else { return nil }
        let range = TimeRange(lo, hi)
        let enc = JSONEncoder()
        enc.outputFormatting = .sortedKeys
        let fx = effects.map { e -> String in
            let params = (try? enc.encode(e.params)).map { String(decoding: $0, as: UTF8.self) } ?? ""
            var plate = ""
            if let path = e.params["clean_plate"]?.string, !path.isEmpty, let a = try? FileManager.default.attributesOfItem(atPath: (path as NSString).expandingTildeInPath) {
                plate = "|\(a[.size] as? Int ?? 0)|\((a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
            }
            return "\(e.type)|\(e.mix)|\(params)\(plate)"
        }.joined(separator: "||")
        let attrs = try? FileManager.default.attributesOfItem(atPath: media.path)
        let stamp = "\(media.path)|\(attrs?[.size] as? Int ?? 0)|\((attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)|\(fmt(range.start))|\(fmt(range.end))|\(canvas.width)x\(canvas.height)|\(fx)|v2"
        let key = String(SHA256.hash(data: Data(stamp.utf8)).map { String(format: "%02x", $0) }.joined().prefix(24))
        return Request(clipId: clip.id, media: media, range: range, effects: effects, maxWidth: canvas.width, maxHeight: canvas.height, key: key)
    }

    /// Every processed copy a project's picture uses, nested sequences included.
    public static func requests(_ project: Project) -> [Request] {
        let project = project.resolvingAudioTransitions()
        var heads: [String: Seconds] = [:], tails: [String: Seconds] = [:]
        for w in project.transitionWindows where w.transition.hasVideo {
            if let id = w.transition.from { tails[id] = max(tails[id] ?? 0, w.tail) }
            if let id = w.transition.to { heads[id] = max(heads[id] ?? 0, w.head) }
        }
        var out: [Request] = []
        for track in project.tracks where track.kind == .video {
            for c in track.clips {
                var clips: [Clip] = []
                if c.kind == .sequence, let seq = c.mediaId.flatMap({ project.sequence($0) }) {
                    for w in project.inside(seq).transitionWindows where w.transition.hasVideo {
                        if let id = w.transition.from { tails["\(c.id)/\(id)"] = w.tail }
                        if let id = w.transition.to { heads["\(c.id)/\(id)"] = w.head }
                    }
                    clips = project.expanded(c).filter { $0.clip.kind == .media && $0.kind == .video }.map(\.clip)
                } else if c.kind == .media {
                    clips = [c]
                }
                for clip in clips {
                    guard let m = clip.mediaId.flatMap({ project.mediaAsset($0) }),
                          let r = request(clip, media: m, canvas: project.canvas, head: heads[clip.id] ?? 0, tail: tails[clip.id] ?? 0) else { continue }
                    out.append(r)
                }
            }
        }
        return out
    }

    public static func cached(_ r: Request) -> URL? {
        FileManager.default.fileExists(atPath: r.url.path) ? r.url : nil
    }

    /// Whether this process is rendering the copy now.
    public static func isRendering(_ r: Request) -> Bool { lock.withLock { inFlight[r.key] != nil } }

    /// Renders every copy the project is missing; returns the clip ids rendered.
    @discardableResult
    public static func renderMissing(_ project: Project, progress: (@Sendable (Double) -> Void)? = nil) async throws -> [String] {
        let missing = requests(project).filter { cached($0) == nil }
        var done: [String] = []
        for (k, r) in missing.enumerated() {
            let n = Double(missing.count)
            _ = try await render(r) { p in progress?((Double(k) + p) / n) }
            done.append(r.clipId)
        }
        return done
    }

    /// The processed copy, rendering it unless it is cached; concurrent calls share one render.
    public static func render(_ r: Request, progress: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
        if let url = cached(r) { return url }
        let task = lock.withLock { () -> Task<URL, Error> in
            if let t = inFlight[r.key] { return t }
            let t = Task<URL, Error> {
                let tmp = directory.appendingPathComponent("tmp-\(UUID().uuidString).mov")
                do {
                    try await write(r, to: tmp, progress: progress)
                } catch {
                    try? FileManager.default.removeItem(at: tmp)
                    throw error
                }
                try? FileManager.default.removeItem(at: r.url)
                try FileManager.default.moveItem(at: tmp, to: r.url)
                return r.url
            }
            inFlight[r.key] = t
            return t
        }
        defer { lock.withLock { _ = inFlight.removeValue(forKey: r.key) } }
        return try await task.value
    }

    /// The clean plate each object removal names, as a frame-sized 32BGRA picture with the object's box in it: an
    /// image file, or a frame of the clip's media decoded like the frames it cleans.
    static func cleanPlates(_ r: Request, width w: Int, height h: Int) async throws -> [String: (CVPixelBuffer, NormRect?)] {
        var out: [String: (CVPixelBuffer, NormRect?)] = [:]
        for e in r.effects where e.type == "video.remove_object" {
            let path = e.params["clean_plate"]?.string ?? "", at = e.params["clean_plate_at"]?.number ?? -1
            if !path.isEmpty {
                let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
                guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { throw EditError("Cannot read the clean plate \(path)") }
                var pb: CVPixelBuffer?
                CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
                guard let pb else { throw EditError("Cannot allocate the clean plate") }
                CVPixelBufferLockBaseAddress(pb, [])
                let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: w, height: h, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: img.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
                ctx?.interpolationQuality = .high
                ctx?.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
                CVPixelBufferUnlockBaseAddress(pb, [])
                guard ctx != nil else { throw EditError("Cannot draw the clean plate \(path)") }
                out[e.id] = (pb, nil)
            } else if at >= 0 {
                let frames = try await SourceFrames.open(url: r.media.url, maxSize: CGSize(width: r.maxWidth, height: r.maxHeight), forward: true, from: max(0, at - 0.5))
                let eps = frames.frameDuration / 2
                let plate = try await runBlocking { _ -> CVPixelBuffer? in
                    var last: CVPixelBuffer?
                    while let f = try frames.next() {
                        last = f.buffer
                        if f.time >= at - eps { break }
                    }
                    return last
                }
                guard let plate, CVPixelBufferGetWidth(plate) == w, CVPixelBufferGetHeight(plate) == h else { throw EditError("No frame at \(at)s of \(r.media.name) to use as the clean plate") }
                out[e.id] = (plate, ObjectTrack.box(ObjectTrack.decodeBoxes(e.params["boxes"]?.string ?? ""), at: at))
            }
        }
        return out
    }

    static func write(_ r: Request, to url: URL, progress: (@Sendable (Double) -> Void)?) async throws {
        let frames = try await SourceFrames.open(url: r.media.url, maxSize: CGSize(width: r.maxWidth, height: r.maxHeight), forward: true, from: r.range.start)
        let w = Int(frames.size.width), h = Int(frames.size.height)
        var color: [String: Any] = [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2, AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2, AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]
        if let fd = try? await frames.track.load(.formatDescriptions).first {
            let ext = { (k: CFString) in CMFormatDescriptionGetExtension(fd, extensionKey: k) as? String }
            if let v = ext(kCMFormatDescriptionExtension_ColorPrimaries) { color[AVVideoColorPrimariesKey] = v }
            if let v = ext(kCMFormatDescriptionExtension_TransferFunction) { color[AVVideoTransferFunctionKey] = v }
            if let v = ext(kCMFormatDescriptionExtension_YCbCrMatrix) { color[AVVideoYCbCrMatrixKey] = v }
        }
        let plates = try await cleanPlates(r, width: w, height: h)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.proRes422HQ, AVVideoWidthKey: w, AVVideoHeightKey: h, AVVideoColorPropertiesKey: color,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? EditError("Cannot write a processed copy") }
        writer.startSession(atSourceTime: .zero)
        let range = r.range
        let total = max(1, range.duration * frames.fps)
        let eps = frames.frameDuration / 4
        var lastTime: Seconds = 0
        do {
            try await runBlocking { cancelled in
                let window = FrameWindow {
                    while let f = try frames.next() {
                        if f.time < range.start - eps { continue }
                        if f.time > range.end + eps { return nil }
                        return (f.time, f.buffer)
                    }
                    return nil
                }
                let stages = PictureProcessor.stages(r.effects, width: w, height: h, fps: frames.fps, context: frames.context, plates: plates)
                try PictureProcessor(stages: stages).run(window, cancelled: cancelled) { i, t, plane in
                    while !input.isReadyForMoreMediaData {
                        if cancelled() { throw CancellationError() }
                        Thread.sleep(forTimeInterval: 0.001)
                    }
                    guard let pool = adaptor.pixelBufferPool else { throw writer.error ?? EditError("Cannot allocate frames") }
                    var pb: CVPixelBuffer?
                    CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
                    guard let pb else { throw EditError("Cannot allocate a frame") }
                    plane.write(to: pb)
                    // The first frame starts the copy, standing in for the sliver of window before it.
                    let pts = i == 0 ? 0 : max(lastTime + 1e-4, t - range.start)
                    lastTime = pts
                    guard adaptor.append(pb, withPresentationTime: CMTime(seconds: pts, preferredTimescale: 600_000)) else { throw writer.error ?? EditError("Cannot write frame \(i)") }
                    if i % 5 == 0 { progress?(min(0.99, Double(i) / total)) }
                }
            }
        } catch {
            writer.cancelWriting()
            throw error
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(seconds: max(lastTime + frames.frameDuration, range.duration), preferredTimescale: 600_000))
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? EditError("Cannot finish the processed copy") }
        progress?(1)
    }
}
