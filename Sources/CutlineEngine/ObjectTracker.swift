import CutlineCore
import Foundation
import Vision

/// Samples a tracker followed and, when it stopped at a cut, where.
public struct TrackRun: Sendable {
    public var samples: [TrackSample]
    public var cut: ShotBoundary?

    public init(samples: [TrackSample], cut: ShotBoundary?) {
        self.samples = samples
        self.cut = cut
    }
}

/// Follows a box through a media file with Vision's object tracker.
public enum ObjectTracker {
    static let analysisSize = CGSize(width: 640, height: 640)

    /// Tracks `box` (where the object is at `start`) toward `end`, backwards when `end < start`.
    /// Samples are spaced `1 / fps` seconds and returned in time order; tracking stops early when Vision gives up or
    /// at a cut (`cuts` from scene analysis, or detected from the frames).
    public static func track(media url: URL, from start: Seconds, to end: Seconds, box: NormRect, fps: Double = 15, cuts: [Seconds] = [], progress: (@Sendable (Double) -> Void)? = nil) async throws -> [TrackSample] {
        try await run(media: url, from: start, to: end, box: box, fps: fps, cuts: cuts, progress: progress).samples
    }

    /// `track`, saying where it stopped at a cut.
    public static func run(media url: URL, from start: Seconds, to end: Seconds, box: NormRect, fps: Double = 15, cuts: [Seconds] = [], progress: (@Sendable (Double) -> Void)? = nil) async throws -> TrackRun {
        let forward = end >= start
        let step = 1 / max(1, fps)
        let n = Int((abs(end - start) / step + 1e-6).rounded(.down))
        let times = (0...n).map { start + (forward ? 1 : -1) * Double($0) * step } + (abs(Double(n) * step - abs(end - start)) > 1e-6 ? [end] : [])
        let frames = try await SourceFrames.open(url: url, maxSize: analysisSize, forward: forward, from: start)
        let result = try await runBlocking { cancelled -> TrackRun in
            let shots = TrackerShotGuard(cuts: cuts, frameDuration: max(step, frames.frameDuration))
            let request = VNTrackObjectRequest(detectedObjectObservation: VNDetectedObjectObservation(boundingBox: visionRect(box)))
            request.trackingLevel = .accurate
            let handler = VNSequenceRequestHandler()
            let first = try frames.frame(near: start)
            // The tracker learns the object's appearance from the frame its first observation belongs to.
            try handler.perform([request], on: first.buffer, orientation: .up)
            var samples = [TrackSample(t: start, box: box, confidence: 1)]
            var last = first.time
            var cut = shots.feed(first.buffer, time: first.time)
            for (k, t) in times.enumerated().dropFirst() {
                if cancelled() { throw CancellationError() }
                let frame = try frames.frame(near: t)
                if frame.time == last, let prev = samples.last {
                    samples.append(TrackSample(t: t, box: prev.box, confidence: prev.confidence))
                    continue
                }
                last = frame.time
                if let b = shots.feed(frame.buffer, time: frame.time) {
                    cut = b
                    break
                }
                do {
                    try handler.perform([request], on: frame.buffer, orientation: .up)
                    guard let obs = request.results?.first as? VNDetectedObjectObservation else { throw EditError("No tracking result") }
                    request.inputObservation = obs
                    samples.append(TrackSample(t: t, box: normRect(obs.boundingBox), confidence: Double(obs.confidence)))
                } catch {
                    samples.append(TrackSample(t: t, box: samples[samples.count - 1].box, confidence: 0))
                    break
                }
                if k % 10 == 0 { progress?(Double(k) / Double(times.count)) }
            }
            if cut == nil { cut = shots.finish() }
            if let cut { samples.removeAll { forward ? $0.t >= cut.time : $0.t <= cut.time } }
            if samples.isEmpty { samples = [TrackSample(t: start, box: box, confidence: 1)] }
            return TrackRun(samples: samples, cut: cut)
        }
        progress?(1)
        return TrackRun(samples: result.samples.sorted { $0.t < $1.t }, cut: result.cut)
    }

    static func visionRect(_ r: NormRect) -> CGRect {
        CGRect(x: r.x, y: 1 - r.y - r.height, width: r.width, height: r.height)
    }

    static func normRect(_ r: CGRect) -> NormRect {
        NormRect(x: Double(r.minX), y: Double(1 - r.maxY), width: Double(r.width), height: Double(r.height))
    }
}
