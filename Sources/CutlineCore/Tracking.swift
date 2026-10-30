import Foundation

/// Where a tracked object is at one source time.
public struct TrackSample: Codable, Equatable, Sendable {
    /// Source seconds.
    public var t: Seconds
    public var box: NormRect
    /// Tracker confidence, 0…1.
    public var confidence: Double
    /// For surface tracks: tl, tr, br, bl corners as x, y pairs (frame fractions, top-left origin).
    public var corners: [Double]?

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

extension ObjectTrack {
    /// Samples as "t x y w h" groups separated by ";", the form mask.object and video.remove_object keep them in.
    /// Samples that linear interpolation between the kept ones reproduces within `tolerance` are dropped.
    public static func encodeBoxes(_ samples: [TrackSample], tolerance: Double = 0.002) -> String {
        let s = samples.sorted { $0.t < $1.t }
        guard s.count > 2 else { return s.map(format).joined(separator: ";") }
        var kept = [0]
        var anchor = 0
        for end in 2..<s.count {
            let fits = (anchor + 1..<end).allSatisfy { k in
                guard let b = box(in: [s[anchor], s[end]], at: s[k].t) else { return false }
                return max(abs(b.x - s[k].box.x), abs(b.y - s[k].box.y), abs(b.width - s[k].box.width), abs(b.height - s[k].box.height)) <= tolerance
            }
            if !fits {
                anchor = end - 1
                kept.append(anchor)
            }
        }
        kept.append(s.count - 1)
        return kept.map { format(s[$0]) }.joined(separator: ";")
    }

    static func format(_ s: TrackSample) -> String {
        String(format: "%.3f %.4f %.4f %.4f %.4f", s.t, s.box.x, s.box.y, s.box.width, s.box.height)
    }

    /// Parses `encodeBoxes` text; malformed groups are skipped.
    public static func decodeBoxes(_ text: String) -> [TrackSample] {
        text.split(separator: ";").compactMap { group -> TrackSample? in
            let v = group.split(separator: " ").compactMap { Double($0) }
            guard v.count == 5, v[3] > 0, v[4] > 0 else { return nil }
            return TrackSample(t: v[0], box: NormRect(x: v[1], y: v[2], width: v[3], height: v[4]), confidence: 1)
        }.sorted { $0.t < $1.t }
    }

    /// The box at source time `t` between decoded samples; nil outside them.
    public static func box(_ samples: [TrackSample], at t: Seconds) -> NormRect? { box(in: samples, at: t) }
}
