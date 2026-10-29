import CutlineCore
import Foundation
import Vision

/// Follows a box through a media file with Vision's object tracker.
public enum ObjectTracker {
    static let analysisSize = CGSize(width: 640, height: 640)

    /// Tracks `box` (where the object is at `start`) toward `end`, backwards when `end < start`.
    /// Samples are spaced `1 / fps` seconds and returned in time order; tracking stops early when Vision gives up.
    public static func track(media url: URL, from start: Seconds, to end: Seconds, box: NormRect, fps: Double = 15, progress: (@Sendable (Double) -> Void)? = nil) async throws -> [TrackSample] {
        let forward = end >= start
        let step = 1 / max(1, fps)
        let n = Int((abs(end - start) / step + 1e-6).rounded(.down))
        let times = (0...n).map { start + (forward ? 1 : -1) * Double($0) * step } + (abs(Double(n) * step - abs(end - start)) > 1e-6 ? [end] : [])
        let frames = try await SourceFrames.open(url: url, maxSize: analysisSize, forward: forward, from: start)
        let samples = try await runBlocking { cancelled -> [TrackSample] in
            let request = VNTrackObjectRequest(detectedObjectObservation: VNDetectedObjectObservation(boundingBox: visionRect(box)))
            request.trackingLevel = .accurate
            let handler = VNSequenceRequestHandler()
            let first = try frames.frame(near: start)
            // The tracker learns the object's appearance from the frame its first observation belongs to.
            try handler.perform([request], on: first.buffer, orientation: .up)
            var samples = [TrackSample(t: start, box: box, confidence: 1)]
            var last = first.time
            for (k, t) in times.enumerated().dropFirst() {
                if cancelled() { throw CancellationError() }
                let frame = try frames.frame(near: t)
                if frame.time == last, let prev = samples.last {
                    samples.append(TrackSample(t: t, box: prev.box, confidence: prev.confidence))
                    continue
                }
                last = frame.time
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
            return samples
        }
        progress?(1)
        return samples.sorted { $0.t < $1.t }
    }

    static func visionRect(_ r: NormRect) -> CGRect {
        CGRect(x: r.x, y: 1 - r.y - r.height, width: r.width, height: r.height)
    }

    static func normRect(_ r: CGRect) -> NormRect {
        NormRect(x: Double(r.minX), y: Double(1 - r.maxY), width: Double(r.width), height: Double(r.height))
    }
}
