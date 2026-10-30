import AVFoundation
import CoreImage
import CutlineCore
import Foundation

/// Decoded frames of a video file, upright and downscaled, for queries whose times only move one way.
/// Forward cursors stream one reader; backward cursors decode short chunks from the end toward the start.
/// Only the frames around the latest query stay in memory.
final class SourceFrames {
    struct Frame {
        /// Source seconds.
        let time: Seconds
        /// 32BGRA at `size`.
        let buffer: CVPixelBuffer
    }

    let asset: AVURLAsset
    let track: AVAssetTrack
    /// Output pixels, even.
    let size: CGSize
    let frameDuration: Seconds
    let span: TimeRange
    let forward: Bool
    let context: CIContext

    private let orient: CGAffineTransform
    private let pool: CVPixelBufferPool
    private var frames: [Frame] = []
    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    private var exhausted = false
    /// Backward: start of the earliest chunk read so far.
    private var lowWater: Seconds
    private let chunk: Seconds

    private init(asset: AVURLAsset, track: AVAssetTrack, natural: CGSize, transform: CGAffineTransform, frameDuration: Seconds, span: TimeRange, maxSize: CGSize, forward: Bool, from: Seconds) throws {
        self.asset = asset
        self.track = track
        self.frameDuration = frameDuration
        self.span = span
        self.forward = forward
        context = CIContext(options: [.workingColorSpace: NSNull(), .cacheIntermediates: false])

        let rect = CGRect(origin: .zero, size: natural).applying(transform)
        let shown = CGSize(width: abs(rect.width), height: abs(rect.height))
        let s = min(1, maxSize.width / max(shown.width, 1), maxSize.height / max(shown.height, 1))
        let w = max(2, Int(shown.width * s) / 2 * 2), h = max(2, Int(shown.height * s) / 2 * 2)
        size = CGSize(width: w, height: h)
        // Flip to y-down, apply the track transform, flip back, then scale to the output size.
        let flipIn = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: natural.height)
        let flipOut = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: shown.height)
        orient = flipIn.concatenating(transform)
            .concatenating(CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
            .concatenating(flipOut)
            .concatenating(CGAffineTransform(scaleX: CGFloat(w) / shown.width, y: CGFloat(h) / shown.height))

        var p: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, nil, [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ] as CFDictionary, &p)
        guard let p else { throw EditError("Cannot allocate frames") }
        pool = p
        chunk = max(0.4, 12 * frameDuration)
        lowWater = min(span.end, from + 2 * frameDuration)
        if forward { try startStream(from: max(span.start, from - 2 * frameDuration)) }
    }

    static func open(url: URL, maxSize: CGSize, forward: Bool = true, from: Seconds) async throws -> SourceFrames {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw EditError("\(url.lastPathComponent) has no video") }
        let (natural, transform, range, minDur, rate) = try await track.load(.naturalSize, .preferredTransform, .timeRange, .minFrameDuration, .nominalFrameRate)
        var fd = minDur.isValid && minDur.seconds > 0 ? minDur.seconds : 0
        if fd == 0 || (rate > 0 && abs(1 / fd - Double(rate)) > 1) { fd = rate > 0 ? 1 / Double(rate) : 1.0 / 30 }
        let span = TimeRange(range.start.seconds, range.end.seconds)
        return try SourceFrames(asset: asset, track: track, natural: natural, transform: transform, frameDuration: fd, span: span, maxSize: maxSize, forward: forward, from: from)
    }

    var fps: Double { 1 / frameDuration }

    /// The frames on either side of source time `s` and the fraction of the way from `a` to `b`.
    /// Times before the first or after the last frame return that frame twice.
    func bracket(_ s: Seconds) throws -> (a: Frame, b: Frame, p: Double) {
        let eps = 1e-4
        if forward {
            while !exhausted, frames.last.map({ $0.time <= s + eps }) ?? true {
                if let f = try pull() { frames.append(f) } else { exhausted = true }
            }
            if let i = frames.lastIndex(where: { $0.time <= s + eps }), i > 0 { frames.removeFirst(i) }
        } else {
            while !exhausted, frames.first.map({ $0.time > s + eps }) ?? true { try loadChunk() }
            if let j = frames.firstIndex(where: { $0.time > s + eps }), j + 1 < frames.count { frames.removeLast(frames.count - j - 1) }
        }
        guard !frames.isEmpty else { throw EditError("No video frames near \(String(format: "%.3f", s)) s") }
        let i = frames.lastIndex { $0.time <= s + eps } ?? 0
        let a = frames[i], b = frames[min(i + 1, frames.count - 1)]
        let p = b.time > a.time ? min(1, max(0, (s - a.time) / (b.time - a.time))) : 0
        return (a, b, p)
    }

    /// The frame nearest to source time `s`.
    func frame(near s: Seconds) throws -> Frame {
        let (a, b, p) = try bracket(s)
        return p < 0.5 ? a : b
    }

    /// A buffer from this cursor's pool with `image` rendered into it.
    func render(_ image: CIImage) throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
        guard let pb else { throw EditError("Cannot allocate a frame") }
        context.render(image, to: pb, bounds: CGRect(origin: .zero, size: size), colorSpace: nil)
        return pb
    }

    private func makeReader(_ range: TimeRange) throws -> (AVAssetReader, AVAssetReaderTrackOutput) {
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: range.start, preferredTimescale: 600_000), end: CMTime(seconds: range.end, preferredTimescale: 600_000))
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        out.alwaysCopiesSampleData = false
        reader.add(out)
        guard reader.startReading() else { throw reader.error ?? EditError("Cannot read video") }
        return (reader, out)
    }

    private func startStream(from start: Seconds) throws {
        (reader, output) = try makeReader(TimeRange(start, span.end))
    }

    private func next(_ out: AVAssetReaderTrackOutput, _ reader: AVAssetReader) throws -> Frame? {
        while let sample = out.copyNextSampleBuffer() {
            guard let image = CMSampleBufferGetImageBuffer(sample) else { continue }
            let t = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            let upright = CIImage(cvPixelBuffer: image).transformed(by: orient)
            return Frame(time: t, buffer: try render(upright))
        }
        if reader.status == .failed { throw reader.error ?? EditError("Cannot decode video") }
        return nil
    }

    private func pull() throws -> Frame? {
        guard let reader, let output else { return nil }
        return try next(output, reader)
    }

    private func loadChunk() throws {
        let end = lowWater
        let lo = max(span.start, end - chunk)
        lowWater = lo
        if lo <= span.start + 1e-6 { exhausted = true }
        guard end > lo else { return }
        let (reader, out) = try makeReader(TimeRange(lo, end))
        let limit = frames.first?.time ?? .infinity
        var fresh: [Frame] = []
        while let f = try next(out, reader) {
            if f.time < limit - 1e-4 { fresh.append(f) } else { reader.cancelReading(); break }
        }
        frames.insert(contentsOf: fresh, at: 0)
    }
}

/// Runs blocking decode, Vision and encode work on its own thread, so it never holds Swift's cooperative pool
/// while framework work it waits on needs threads. `work` should poll `cancelled`.
public func runBlocking<T>(_ work: @escaping (_ cancelled: () -> Bool) throws -> T) async throws -> T {
    let flag = CancelFlag()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<T, Error>) in
            let thread = Thread { c.resume(with: Result { try work { flag.isSet } }) }
            thread.stackSize = 8 << 20
            thread.qualityOfService = .userInitiated
            thread.start()
        }
    } onCancel: {
        flag.set()
    }
}

final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}
