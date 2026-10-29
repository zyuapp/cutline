import Foundation

/// Where a tracked object is at one source time.
public struct TrackSample: Codable, Equatable, Sendable {
    /// Source seconds.
    public var t: Seconds
    public var box: NormRect
    /// Tracker confidence, 0…1.
    public var confidence: Double

    public init(t: Seconds, box: NormRect, confidence: Double) {
        self.t = t
        self.box = box
        self.confidence = confidence
    }
}

/// An object followed through one media file.
public struct ObjectTrack: Codable, Equatable, Sendable {
    public var id: String
    public var mediaId: String
    public var label: String
    /// Sorted by time.
    public var samples: [TrackSample]

    /// Below this a sample counts as lost.
    public static let lostConfidence = 0.3

    public init(id: String, mediaId: String, label: String, samples: [TrackSample]) {
        self.id = id
        self.mediaId = mediaId
        self.label = label
        self.samples = samples.sorted { $0.t < $1.t }
    }

    public var range: TimeRange? { samples.first.map { TimeRange($0.t, samples[samples.count - 1].t) } }

    /// The box at source time `t`, linearly interpolated between samples; nil outside the tracked range.
    public func box(at t: Seconds) -> NormRect? {
        ObjectTrack.box(in: samples, at: t)
    }

    /// Spans where confidence stays below `lostConfidence`, from the first lost sample to the next confident one.
    public var lost: [TimeRange] {
        var out: [TimeRange] = []
        var begin: Seconds?
        for s in samples {
            if s.confidence < ObjectTrack.lostConfidence {
                if begin == nil { begin = s.t }
            } else if let b = begin {
                out.append(TimeRange(b, s.t))
                begin = nil
            }
        }
        if let b = begin, let last = samples.last { out.append(TimeRange(b, last.t)) }
        return out
    }

    static func box(in samples: [TrackSample], at t: Seconds) -> NormRect? {
        guard let first = samples.first, let last = samples.last, t >= first.t - 1e-9, t <= last.t + 1e-9 else { return nil }
        var lo = 0, hi = samples.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if samples[mid].t <= t { lo = mid } else { hi = mid }
        }
        let a = samples[lo], b = samples[hi]
        guard b.t > a.t else { return a.box }
        let p = min(1, max(0, (t - a.t) / (b.t - a.t)))
        func mix(_ x: Double, _ y: Double) -> Double { x + (y - x) * p }
        return NormRect(x: mix(a.box.x, b.box.x), y: mix(a.box.y, b.box.y), width: mix(a.box.width, b.box.width), height: mix(a.box.height, b.box.height))
    }

    /// Gaussian smoothing of box centers and sizes over time, weighted by confidence. Times and confidences are kept.
    public static func smoothed(_ samples: [TrackSample], sigma: Seconds) -> [TrackSample] {
        guard sigma > 0, samples.count > 1 else { return samples }
        let sorted = samples.sorted { $0.t < $1.t }
        var lo = 0
        return sorted.map { s in
            while sorted[lo].t < s.t - 3 * sigma { lo += 1 }
            var sw = 0.0, cx = 0.0, cy = 0.0, w = 0.0, h = 0.0
            var i = lo
            while i < sorted.count, sorted[i].t <= s.t + 3 * sigma {
                let o = sorted[i]
                let d = (o.t - s.t) / sigma
                let k = exp(-0.5 * d * d) * max(o.confidence, 1e-3)
                sw += k
                cx += k * o.box.midX
                cy += k * o.box.midY
                w += k * o.box.width
                h += k * o.box.height
                i += 1
            }
            guard sw > 0 else { return s }
            let bw = w / sw, bh = h / sw
            return TrackSample(t: s.t, box: NormRect(x: cx / sw - bw / 2, y: cy / sw - bh / 2, width: bw, height: bh), confidence: s.confidence)
        }
    }
}
