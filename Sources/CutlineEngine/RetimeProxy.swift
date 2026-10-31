import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import CryptoKit
import CutlineCore
import Foundation
import VideoToolbox

/// Retimed copies of a clip's picture with in-between frames, for smooth slow motion and speed ramps.
/// Frame i (at i / fps) shows the clip at local time i / fps − head; the file lasts head + duration + tail.
/// Picture only: upright high-bitrate H.264.
public enum RetimeProxy {
    public enum Interpolation: String, Sendable, CaseIterable {
        /// Weighted dissolve of the two nearest source frames.
        case blend
        /// Optical-flow frame interpolation (VideoToolbox frame rate conversion).
        case flow
    }

    static let directory: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Cutline/retime", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        WriterWait.sweepTemporaries(in: dir)
        return dir
    }()
    static let lock = NSLock()
    nonisolated(unsafe) static var inFlight: [String: Task<URL, Error>] = [:]

    /// The proxy file and whether it was interpolated with optical flow. A `.flow` request that cannot use flow
    /// returns the blended proxy with `usedFlow` false.
    public static func url(for media: MediaAsset, clip: Clip, head: Seconds = 0, tail: Seconds = 0, fps: Double, maxSize: CGSize, interpolation: Interpolation = .blend, progress: (@Sendable (Double) -> Void)? = nil) async throws -> (url: URL, usedFlow: Bool) {
        if interpolation == .flow {
            do {
                return (try await render(media, clip, head, tail, fps, maxSize, flow: true, progress), true)
            } catch is CancellationError {
                throw CancellationError()
            } catch {}
        }
        return (try await render(media, clip, head, tail, fps, maxSize, flow: false, progress), false)
    }

    /// Source seconds shown at local clip time `t`; past either end the clip continues at its edge speed.
    public static func sourceTime(_ clip: Clip, atLocal t: Seconds) -> Seconds {
        sourceTimes(clip, local: [t])[0]
    }

    static func sourceTimes(_ clip: Clip, local: [Seconds]) -> [Seconds] {
        let d = clip.duration
        let offset: (Seconds) -> Seconds
        let total: Seconds
        if clip.isRetimed {
            let steps = max(8, min(2_000_000, Int(saturating: d * 240)))
            let h = d / Double(steps)
            var table = [0.0]
            table.reserveCapacity(steps + 1)
            var prev = clip.speed(atLocal: 0)
            for i in 1...steps {
                let cur = clip.speed(atLocal: Double(i) * h)
                table.append(table[i - 1] + (prev + cur) * h / 2)
                prev = cur
            }
            total = table[steps]
            let v0 = clip.speed(atLocal: 0), v1 = clip.speed(atLocal: d)
            offset = { t in
                if t <= 0 { return t * v0 }
                if t >= d { return total + (t - d) * v1 }
                let f = t / h
                let i = min(steps - 1, Int(f))
                return table[i] + (table[i + 1] - table[i]) * (f - Double(i))
            }
        } else {
            total = d * clip.speed
            offset = { $0 * clip.speed }
        }
        return local.map { clip.reverse ? clip.sourceIn + total - offset($0) : clip.sourceIn + offset($0) }
    }

    static func key(_ media: MediaAsset, _ clip: Clip, _ head: Seconds, _ tail: Seconds, _ fps: Double, _ maxSize: CGSize, flow: Bool) -> String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: media.path)
        let enc = JSONEncoder()
        enc.outputFormatting = .sortedKeys
        let curve = clip.anim["time.speed"].flatMap { try? enc.encode($0) }.map { String(decoding: $0, as: UTF8.self) } ?? "-"
        let stamp = "\(media.path)|\(attrs?[.size] as? Int ?? 0)|\((attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)|\(fmt(clip.sourceIn))|\(fmt(clip.duration))|\(clip.speed)|\(clip.reverse)|\(curve)|\(fmt(head))|\(fmt(tail))|\(fps)|\(Int(maxSize.width))x\(Int(maxSize.height))|\(flow ? "flow" : "blend")|v1"
        return String(SHA256.hash(data: Data(stamp.utf8)).map { String(format: "%02x", $0) }.joined().prefix(24))
    }

    static func render(_ media: MediaAsset, _ clip: Clip, _ head: Seconds, _ tail: Seconds, _ fps: Double, _ maxSize: CGSize, flow: Bool, _ progress: (@Sendable (Double) -> Void)?) async throws -> URL {
        let key = key(media, clip, head, tail, fps, maxSize, flow: flow)
        let url = directory.appendingPathComponent("\(key).mov")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let task = lock.withLock { () -> Task<URL, Error> in
            if let t = inFlight[key] { return t }
            let t = Task<URL, Error> {
                let tmp = directory.appendingPathComponent("tmp-\(UUID().uuidString).mov")
                do {
                    try await write(media, clip: clip, head: head, tail: tail, fps: fps, maxSize: maxSize, flow: flow, to: tmp, progress: progress)
                } catch {
                    try? FileManager.default.removeItem(at: tmp)
                    throw error
                }
                try? FileManager.default.removeItem(at: url)
                try FileManager.default.moveItem(at: tmp, to: url)
                return url
            }
            inFlight[key] = t
            return t
        }
        defer { lock.withLock { _ = inFlight.removeValue(forKey: key) } }
        return try await task.value
    }

    static func write(_ media: MediaAsset, clip: Clip, head: Seconds, tail: Seconds, fps: Double, maxSize: CGSize, flow: Bool, to url: URL, progress: (@Sendable (Double) -> Void)?) async throws {
        guard fps > 0 else { throw EditError("fps must be positive") }
        let count = max(1, Int(((clip.duration + head + tail) * fps).rounded()))
        let times = sourceTimes(clip, local: (0..<count).map { Double($0) / fps - head })
        let forward = times[count - 1] >= times[0]
        let frames = try await SourceFrames.open(url: media.url, maxSize: maxSize, forward: forward, from: forward ? times.min()! : times.max()!)
        let w = Int(frames.size.width), h = Int(frames.size.height)
        let interpolator = flow ? try FlowInterpolator(width: w, height: h, context: frames.context) : nil

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let rate = max(24, fps)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: Int(Double(w * h) * rate * 0.3), AVVideoMaxKeyFrameIntervalKey: 10, AVVideoAllowFrameReorderingKey: false],
        ])
        video.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h])
        writer.add(video)
        guard writer.startWriting() else { throw writer.error ?? EditError("Cannot write a retimed copy") }
        writer.startSession(atSourceTime: .zero)
        let scale = CMTimeScale(min(Double(Int32.max), (fps * 1000).rounded()))
        let dissolve = CIFilter.dissolveTransition()
        do {
            try await runBlocking { cancelled in
                for i in 0..<count {
                    if cancelled() { throw CancellationError() }
                    let (a, b, p) = try frames.bracket(times[i])
                    let image: CIImage
                    if p < 0.01 || p > 0.99 {
                        image = CIImage(cvPixelBuffer: (p < 0.5 ? a : b).buffer)
                    } else if let interpolator {
                        image = try interpolator.interpolate(a, b, phase: p)
                    } else {
                        dissolve.inputImage = CIImage(cvPixelBuffer: a.buffer)
                        dissolve.targetImage = CIImage(cvPixelBuffer: b.buffer)
                        dissolve.time = Float(p)
                        image = dissolve.outputImage!
                    }
                    try WriterWait.readySync(video, writer, "The retimed copy", cancelled: cancelled)
                    guard let pool = adaptor.pixelBufferPool else { throw writer.error ?? EditError("Cannot allocate frames") }
                    var pb: CVPixelBuffer?
                    CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
                    guard let pb else { throw EditError("Cannot allocate a frame") }
                    frames.context.render(image, to: pb, bounds: CGRect(x: 0, y: 0, width: w, height: h), colorSpace: nil)
                    guard adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(i) * 1000, timescale: scale)) else { throw writer.error ?? EditError("Cannot write frame \(i)") }
                    if i % 10 == 0 { progress?(Double(i) / Double(count)) }
                }
            }
        } catch {
            writer.cancelWriting()
            throw error
        }
        video.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue(count) * 1000, timescale: scale))
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? EditError("Cannot finish the retimed copy") }
        progress?(1)
    }
}

/// In-between frames from VideoToolbox frame rate conversion. Blocks the calling thread.
final class FlowInterpolator {
    let processor = VTFrameProcessor()
    let configuration: VTFrameRateConversionConfiguration
    let context: CIContext
    let sourcePool: CVPixelBufferPool
    let destinationPool: CVPixelBufferPool
    private var converted: [(time: Seconds, frame: VTFrameProcessorFrame)] = []
    private var lastPair: (Seconds, Seconds)?

    init(width: Int, height: Int, context: CIContext) throws {
        guard VTFrameRateConversionConfiguration.isSupported,
              let config = VTFrameRateConversionConfiguration(frameWidth: width, frameHeight: height, usePrecomputedFlow: false, qualityPrioritization: .normal, revision: VTFrameRateConversionConfiguration.defaultRevision)
        else { throw EditError("Optical-flow interpolation is not available") }
        configuration = config
        self.context = context
        sourcePool = try FlowInterpolator.pool(config.sourcePixelBufferAttributes)
        destinationPool = try FlowInterpolator.pool(config.destinationPixelBufferAttributes)
        try processor.startSession(configuration: config)
    }

    deinit { processor.endSession() }

    static func pool(_ attrs: [String: Any]) throws -> CVPixelBufferPool {
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
        guard let pool else { throw EditError("Cannot allocate optical-flow frames") }
        return pool
    }

    private func buffer(_ pool: CVPixelBufferPool) throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
        guard let pb else { throw EditError("Cannot allocate an optical-flow frame") }
        return pb
    }

    private func frame(_ f: SourceFrames.Frame) throws -> VTFrameProcessorFrame {
        if let hit = converted.first(where: { $0.time == f.time }) { return hit.frame }
        let pb = try buffer(sourcePool)
        context.render(CIImage(cvPixelBuffer: f.buffer), to: pb, bounds: CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb)), colorSpace: nil)
        guard let vf = VTFrameProcessorFrame(buffer: pb, presentationTimeStamp: CMTime(seconds: f.time, preferredTimescale: 600_000)) else { throw EditError("Cannot wrap an optical-flow frame") }
        converted.append((f.time, vf))
        if converted.count > 4 { converted.removeFirst() }
        return vf
    }

    /// The picture `phase` (0…1) of the way from `a` to `b` in time.
    func interpolate(_ a: SourceFrames.Frame, _ b: SourceFrames.Frame, phase: Double) throws -> CIImage {
        let (first, second, p) = a.time <= b.time ? (a, b, phase) : (b, a, 1 - phase)
        let src = try frame(first), next = try frame(second)
        let t = first.time + (second.time - first.time) * p
        guard let dest = VTFrameProcessorFrame(buffer: try buffer(destinationPool), presentationTimeStamp: CMTime(seconds: t, preferredTimescale: 600_000)) else { throw EditError("Cannot wrap an optical-flow frame") }
        let pair = (first.time, second.time)
        let mode: VTFrameRateConversionParameters.SubmissionMode = lastPair.map { $0 == pair ? .sequentialReferencesUnchanged : ($0.1 == pair.0 ? .sequential : .random) } ?? .random
        guard let params = VTFrameRateConversionParameters(sourceFrame: src, nextFrame: next, opticalFlow: nil, interpolationPhase: [Float(p)], submissionMode: mode, destinationFrames: [dest]) else { throw EditError("Cannot set up optical-flow interpolation") }
        lastPair = pair
        let done = DispatchSemaphore(value: 0)
        var failure: Error?
        processor.process(parameters: params) { _, error in
            failure = error
            done.signal()
        }
        done.wait()
        if let failure { throw failure }
        return CIImage(cvPixelBuffer: dest.buffer)
    }
}
