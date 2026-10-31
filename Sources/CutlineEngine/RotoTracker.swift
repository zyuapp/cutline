import CoreImage
import CutlineCore
import Foundation
import simd

/// Tracked roto: moves the control points of a shape mask through a media file, following a planar track (the
/// homography of the surface the shape lies on), the points as a group (`ShapeTracker`), or the shape's bounding box
/// (translation); or draws the shape from a person or subject matte's outline on every frame. Positions are source
/// frame fractions with a top-left origin.
public enum RotoTracker {
    public enum Mode: String, Sendable, CaseIterable { case planar, points, translate, person, subject }

    public struct Key: Sendable, Equatable {
        /// Source seconds.
        public var t: Seconds
        public var points: [SIMD2<Double>]
        /// 0 where the tracker lost the shape and the points were held or carried by the others.
        public var confidence: Double

        public init(t: Seconds, points: [SIMD2<Double>], confidence: Double) {
            self.t = t
            self.points = points
            self.confidence = confidence
        }
    }

    public struct Result: Sendable {
        public var keys: [Key]
        public var cut: ShotBoundary?
    }

    /// Tracks `points` (at source time `start`) toward `end`, backwards when `end < start`. `quad` is the surface the
    /// shape lies on for planar mode (tl, tr, br, bl); by default the points' bounding box. `pointSize` is the patch
    /// side for point tracking, in frame heights. Points mode with `refine` snaps every frame's shape to that matte
    /// within `snap` frame heights before tracking on. Person and subject modes outline the matte region `points`
    /// covers (any region when empty) with `count` points.
    public static func track(media url: URL, from start: Seconds, to end: Seconds, points: [SIMD2<Double>], mode: Mode, quad: [SIMD2<Double>]? = nil, pointSize: Double = 0.08, fps: Double = 25, cuts: [Seconds] = [], refine: Segmentation.Kind? = nil, snap: Double = 0.03, count: Int = 32) async throws -> Result {
        if mode == .person || mode == .subject {
            let run = try await ShapeTracker.contour(media: url, from: start, to: end, seed: points.count >= 3 ? points : nil, kind: mode == .person ? .person(.balanced) : .subject, count: count, fps: fps, cuts: cuts)
            return Result(keys: run.keys, cut: run.cut)
        }
        guard points.count >= 3 else { throw EditError("A shape needs at least three points to track") }
        switch mode {
        case .planar:
            let q = quad ?? boundingQuad(points)
            let run = try await PlanarTracker.run(media: url, from: start, to: end, corners: q, fps: fps, cuts: cuts)
            return Result(keys: carried(points, quad: q, samples: run.samples), cut: run.cut)
        case .translate:
            let box = bounds(points)
            let run = try await ObjectTracker.run(media: url, from: start, to: end, box: box, fps: fps, cuts: cuts)
            return Result(keys: translated(points, box: box, samples: ObjectTrack.smoothed(run.samples, sigma: 0.06)), cut: run.cut)
        case .points, .person, .subject:
            let run = try await ShapeTracker.points(media: url, from: start, to: end, points: points, patch: pointSize, fps: fps, cuts: cuts, refine: refine, snap: snap)
            return Result(keys: run.keys, cut: run.cut)
        }
    }

    /// A shape known to be right at source time `t`: where tracking starts, or a correction it re-anchors on.
    public struct Anchor: Sendable {
        public var t: Seconds
        public var points: [SIMD2<Double>]

        public init(t: Seconds, points: [SIMD2<Double>]) {
            self.t = t
            self.points = points
        }
    }

    /// Keys over `lo`…`hi` from shapes known at `anchors`, like keyframed planar tracking: backward from the first
    /// anchor, forward from the last, and between two anchors tracked from both ends and cross-faded so each
    /// correction holds exactly at its time. With `blend` false (outlines) a stretch takes the run from its earlier
    /// anchor, anchor frame included. `run` tracks a shape from one time to another, nil when they are the same frame.
    public static func anchored(_ anchors: [Anchor], lo: Seconds, hi: Seconds, blend: Bool = true, run: (Seconds, Seconds, [SIMD2<Double>]) async throws -> Result?) async throws -> (keys: [Key], cuts: [ShotBoundary]) {
        let list = anchors.sorted { $0.t < $1.t }
        guard let first = list.first, let last = list.last else { return ([], []) }
        var keys: [Key] = []
        var cuts: [ShotBoundary] = []
        if let back = try await run(first.t, lo, first.points) {
            keys += back.keys.filter { $0.t < first.t - 1e-6 }
            if let c = back.cut { cuts.append(c) }
        }
        for (a, b) in zip(list, list.dropFirst()) {
            if blend { keys.append(Key(t: a.t, points: a.points, confidence: 1)) }
            guard b.t - a.t > 1e-3, let fwd = try await run(a.t, b.t, a.points) else { continue }
            if let c = fwd.cut { cuts.append(c) }
            let ahead = fwd.keys.filter { $0.t > a.t + (blend ? 1e-6 : -1e-6) && $0.t < b.t - 1e-6 }
            guard blend, let bwd = try await run(b.t, a.t, b.points) else { keys += ahead; continue }
            if let c = bwd.cut { cuts.append(c) }
            let behind = bwd.keys.filter { $0.t > a.t + 1e-6 && $0.t < b.t - 1e-6 }.sorted { $0.t < $1.t }
            for k in ahead {
                guard let lo2 = behind.first?.t, k.t >= lo2 - 1e-6, let other = interpolated(behind, at: k.t), other.points.count == k.points.count else { keys.append(k); continue }
                let u = (k.t - a.t) / (b.t - a.t), w = u * u * (3 - 2 * u)
                keys.append(Key(t: k.t, points: zip(k.points, other.points).map { $0 + ($1 - $0) * w }, confidence: max(k.confidence, other.confidence)))
            }
            // Where the forward run stopped short (a cut), the backward run covers the rest.
            let end = ahead.last?.t ?? a.t
            keys += behind.filter { $0.t > end + 1e-6 }
        }
        if blend { keys.append(Key(t: last.t, points: last.points, confidence: 1)) }
        if let fwd = try await run(last.t, hi, last.points) {
            keys += fwd.keys.filter { $0.t > last.t + (blend ? 1e-6 : -1e-6) }
            if let c = fwd.cut { cuts.append(c) }
        }
        return (keys.sorted { $0.t < $1.t }, cuts)
    }

    /// `base` taken over by `overlay` near `times`: fully at each time, fading back to `base` over `radius` seconds.
    public static func blended(base: [Key], overlay: [Key], near times: [Seconds], radius: Seconds) -> [Key] {
        let b = base.sorted { $0.t < $1.t }, o = overlay.sorted { $0.t < $1.t }
        let stamps = Set(b.map(\.t) + times.filter { t in !b.contains { abs($0.t - t) < 1e-6 } }).sorted()
        return stamps.compactMap { t in
            guard let k = interpolated(b, at: t) else { return nil }
            let w = times.map { max(0, 1 - abs(t - $0) / radius) }.max() ?? 0
            guard w > 0, let v = interpolated(o, at: t), v.points.count == k.points.count else { return k }
            let u = w * w * (3 - 2 * w)
            return Key(t: t, points: zip(k.points, v.points).map { $0 + ($1 - $0) * u }, confidence: max(k.confidence, v.confidence * u))
        }
    }

    /// The key at `t` interpolated between `keys` (sorted), clamped to the ends.
    static func interpolated(_ keys: [Key], at t: Seconds) -> Key? {
        guard let j = keys.firstIndex(where: { $0.t >= t }) else { return keys.last }
        guard j > 0 else { return keys[0] }
        let a = keys[j - 1], b = keys[j]
        guard a.points.count == b.points.count else { return b }
        let f = (t - a.t) / max(b.t - a.t, 1e-9)
        return Key(t: t, points: zip(a.points, b.points).map { $0 + ($1 - $0) * f }, confidence: min(a.confidence, b.confidence))
    }

    static func bounds(_ pts: [SIMD2<Double>]) -> NormRect {
        let xs = pts.map(\.x), ys = pts.map(\.y)
        return NormRect(x: xs.min()!, y: ys.min()!, width: max(0.01, xs.max()! - xs.min()!), height: max(0.01, ys.max()! - ys.min()!))
    }

    static func boundingQuad(_ pts: [SIMD2<Double>]) -> [SIMD2<Double>] {
        let b = bounds(pts)
        return [SIMD2(b.x, b.y), SIMD2(b.x + b.width, b.y), SIMD2(b.x + b.width, b.y + b.height), SIMD2(b.x, b.y + b.height)]
    }

    /// The points carried by the homography from `quad` to each sample's corners.
    public static func carried(_ points: [SIMD2<Double>], quad: [SIMD2<Double>], samples: [TrackSample]) -> [Key] {
        var keys: [Key] = []
        var last: simd_double3x3?
        for s in samples {
            var h: simd_double3x3?
            if let c = s.corners, c.count == 8 {
                h = PlanarTracker.fourPoint(from: quad, to: (0..<4).map { SIMD2(c[2 * $0], c[2 * $0 + 1]) })
            }
            guard let m = h ?? last else { continue }
            last = m
            keys.append(Key(t: s.t, points: points.map { PlanarTracker.apply(m, $0) }, confidence: h == nil ? 0 : s.confidence))
        }
        return keys
    }

    /// The points moved with the tracked box's center and scaled with its size about it.
    public static func translated(_ points: [SIMD2<Double>], box: NormRect, samples: [TrackSample]) -> [Key] {
        let c0 = SIMD2(box.midX, box.midY)
        return samples.map { s in
            let c = SIMD2(s.box.midX, s.box.midY)
            return Key(t: s.t, points: points.map { c + ($0 - c0) }, confidence: s.confidence)
        }
    }

    /// Least-squares affine map [a, b, c, d, e, f] with x' = a·x + b·y + c, y' = d·x + e·y + f.
    static func affine(_ pairs: [(SIMD2<Double>, SIMD2<Double>)]) -> [Double]? {
        var ata = simd_double3x3(0), atx = SIMD3<Double>.zero, aty = SIMD3<Double>.zero
        for (p, q) in pairs {
            let r = SIMD3(p.x, p.y, 1)
            ata += simd_double3x3(rows: [r * r.x, r * r.y, r * r.z])
            atx += r * q.x
            aty += r * q.y
        }
        guard abs(ata.determinant) > 1e-12 else { return nil }
        let inv = ata.inverse
        let u = inv * atx, v = inv * aty
        return [u.x, u.y, u.z, v.x, v.y, v.z]
    }

    static func median(_ v: [Double]) -> Double {
        let s = v.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    /// Drops keys that linear interpolation between the kept ones reproduces within `tolerance` (frame fractions).
    public static func thinned(_ keys: [Key], tolerance: Double = 0.0004) -> [Key] {
        guard keys.count > 2 else { return keys }
        var out = [keys[0]]
        var anchor = 0
        var i = 1
        while i < keys.count - 1 {
            // Extend the run from the anchor while every key inside stays on the line to the next candidate.
            let next = i + 1
            let a = keys[anchor], b = keys[next]
            var ok = true
            for k in (anchor + 1)..<next {
                let f = (keys[k].t - a.t) / max(b.t - a.t, 1e-9)
                for (j, p) in keys[k].points.enumerated() {
                    let q = a.points[j] + (b.points[j] - a.points[j]) * f
                    if simd_distance(p, q) > tolerance { ok = false; break }
                }
                if !ok { break }
            }
            if !ok {
                out.append(keys[i])
                anchor = i
            }
            i += 1
        }
        out.append(keys[keys.count - 1])
        return out
    }

    /// Magnetic refinement: moves each point along the shape's normal to the nearest edge of the segmentation matte
    /// region (`kind`) the shape covers, within `radius` frame heights, on every key. Points with no edge in reach
    /// stay put.
    public static func snapped(_ keys: [Key], media url: URL, kind: Segmentation.Kind, radius: Double, aspect: Double) async throws -> (keys: [Key], moved: Int) {
        guard !keys.isEmpty else { return (keys, 0) }
        let sorted = keys.sorted { $0.t < $1.t }
        let frames = try await SourceFrames.open(url: url, maxSize: CGSize(width: 1024, height: 1024), forward: true, from: sorted[0].t)
        return try await runBlocking { cancelled -> (keys: [Key], moved: Int) in
            var out: [Key] = []
            var moved = 0
            for k in sorted {
                if cancelled() { throw CancellationError() }
                let frame = try frames.frame(near: k.t)
                guard let full = Segmentation.lowRes(kind, CIImage(cvPixelBuffer: frame.buffer)), full.width > 1, let mask = Contour.region(full, seed: k.points) else { out.append(k); continue }
                var key = k
                for (i, p) in k.points.enumerated() {
                    if let q = snap(p, prev: k.points[(i - 1 + k.points.count) % k.points.count], next: k.points[(i + 1) % k.points.count], mask: mask, radius: radius, aspect: aspect) {
                        key.points[i] = q
                        moved += 1
                    }
                }
                out.append(key)
            }
            return (out, moved)
        }
    }

    /// The nearest 0.5 crossing of `mask` along the normal through `p`, within `radius` frame heights.
    static func snap(_ p: SIMD2<Double>, prev: SIMD2<Double>, next: SIMD2<Double>, mask: MaskBuffer, radius: Double, aspect: Double) -> SIMD2<Double>? {
        // Work in frame-height units so the normal is perpendicular on screen.
        let scale = SIMD2(aspect, 1.0)
        let tangent = (next - prev) * scale
        let len = simd_length(tangent)
        guard len > 1e-9 else { return nil }
        let normal = SIMD2(-tangent.y, tangent.x) / len
        func value(_ s: Double) -> Double {
            let q = p + normal * s / scale
            let x = q.x * Double(mask.width) - 0.5, y = q.y * Double(mask.height) - 0.5
            let cx = min(max(x, 0), Double(mask.width - 1)), cy = min(max(y, 0), Double(mask.height - 1))
            let x0 = Int(cx), y0 = Int(cy), x1 = min(x0 + 1, mask.width - 1), y1 = min(y0 + 1, mask.height - 1)
            let fx = cx - Double(x0), fy = cy - Double(y0)
            let v = mask.values
            let top = Double(v[y0 * mask.width + x0]) * (1 - fx) + Double(v[y0 * mask.width + x1]) * fx
            let bottom = Double(v[y1 * mask.width + x0]) * (1 - fx) + Double(v[y1 * mask.width + x1]) * fx
            return top * (1 - fy) + bottom * fy - 0.5
        }
        let steps = 64
        var best: Double?
        var prevS = -radius, prevV = value(-radius)
        for k in 1...steps {
            let s = -radius + 2 * radius * Double(k) / Double(steps)
            let v = value(s)
            if prevV * v <= 0, prevV != v {
                let root = prevS + (s - prevS) * prevV / (prevV - v)
                if best == nil || abs(root) < abs(best!) { best = root }
            }
            prevS = s
            prevV = v
        }
        guard let best else { return nil }
        let q = p + normal * best / scale
        return SIMD2(min(max(q.x, 0), 1), min(max(q.y, 0), 1))
    }
}
