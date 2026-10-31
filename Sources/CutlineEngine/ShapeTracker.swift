import CoreImage
import CutlineCore
import Foundation
import simd

/// Moves a roto shape through a media file as a group: corner features inside the shape are tracked with pyramidal
/// Lucas–Kanade checked forward and backward, a RANSAC affine fit of their motion carries every control point, and a
/// control point keeps its own track only where that agrees with the group. With a segmentation `refine`, points on
/// the edge of the matte region the shape covers keep their place along its outline frame to frame (contour
/// following), the rest snap to the nearest edge, and tracking continues from there.
/// `contour` instead draws the shape from that matte region's outline on every frame.
enum ShapeTracker {
    typealias Gray = PointTracker.Gray

    struct Run {
        var keys: [RotoTracker.Key]
        var cut: ShotBoundary?
    }

    /// Calls `visit` for the first frame and every `1 / fps` seconds toward `end` with the frame's buffer, the
    /// sample time and whether the frame differs from the previous visit; stops at a shot cut.
    static func walk(media url: URL, from start: Seconds, to end: Seconds, fps: Double, cuts: [Seconds], _ visit: @escaping (_ buffer: CVPixelBuffer, _ t: Seconds, _ fresh: Bool) throws -> RotoTracker.Key) async throws -> Run {
        let forward = end >= start
        let frames = try await SourceFrames.open(url: url, maxSize: PointTracker.analysisSize, forward: forward, from: start)
        let step = 1 / max(1, min(fps, frames.fps))
        let n = Int((abs(end - start) / step + 1e-6).rounded(.down))
        let times = (0...n).map { start + (forward ? 1 : -1) * Double($0) * step }
        return try await runBlocking { cancelled -> Run in
            let shots = TrackerShotGuard(cuts: cuts, frameDuration: max(step, frames.frameDuration))
            let first = try frames.frame(near: start)
            var cut = shots.feed(first.buffer, time: first.time)
            var out = [try visit(first.buffer, start, true)]
            var prevTime = first.time
            var last = out[0]
            for t in times.dropFirst() {
                if cancelled() { throw CancellationError() }
                let f = try frames.frame(near: t)
                if f.time != prevTime {
                    if let b = shots.feed(f.buffer, time: f.time) {
                        cut = b
                        break
                    }
                    last = try visit(f.buffer, t, true)
                    prevTime = f.time
                } else {
                    last.t = t
                }
                out.append(RotoTracker.Key(t: t, points: last.points, confidence: last.confidence))
            }
            if cut == nil { cut = shots.finish() }
            if let cut { out.removeAll { forward ? $0.t >= cut.time : $0.t <= cut.time } }
            if out.isEmpty { out = [RotoTracker.Key(t: start, points: last.points, confidence: 1)] }
            return Run(keys: out.sorted { $0.t < $1.t }, cut: cut)
        }
    }

    // MARK: Group point tracking

    static let featureRadius = 7
    static let maxFeatures = 160

    static func points(media url: URL, from start: Seconds, to end: Seconds, points: [SIMD2<Double>], patch: Double, fps: Double, cuts: [Seconds], refine: Segmentation.Kind?, snap: Double) async throws -> Run {
        var state: State?
        return try await walk(media: url, from: start, to: end, fps: fps, cuts: cuts) { buffer, t, _ in
            let gray = Gray(buffer)
            let size = SIMD2(Double(gray.width), Double(gray.height))
            let pyr = PointTracker.pyramid(gray, levels: 4)
            guard var s = state else {
                let px = points.map { SIMD2<Float>(Float($0.x * size.x), Float($0.y * size.y)) }
                let radius = max(5, min(24, Int((patch * size.y / 2).rounded())))
                var fresh = State(reference: pyr, origin: px, points: px, features: features(gray, inside: px, limit: maxFeatures), previous: pyr, radius: radius, size: size)
                if let refine, let mask = Segmentation.lowRes(refine, CIImage(cvPixelBuffer: buffer)), mask.width > 1 { fresh.attach(to: mask, reach: snap) }
                state = fresh
                return RotoTracker.Key(t: t, points: points, confidence: 1)
            }
            let confidence = s.advance(to: pyr, gray: gray)
            if let refine, let mask = Segmentation.lowRes(refine, CIImage(cvPixelBuffer: buffer)), mask.width > 1 {
                s.follow(mask, reach: snap)
            }
            state = s
            return RotoTracker.Key(t: t, points: s.points.map { SIMD2(Double($0.x) / size.x, Double($0.y) / size.y) }, confidence: confidence)
        }
    }

    struct State {
        let reference: [Gray]
        let origin: [SIMD2<Float>]
        var points: [SIMD2<Float>]
        var features: [SIMD2<Float>]
        var previous: [Gray]
        let radius: Int
        let size: SIMD2<Double>
        var initialFeatures = 0
        /// Where each point sits along the matte region's outline (an index into `outline`), for points on its edge.
        var along: [Int?] = []
        var outline: [SIMD2<Double>]?
        static let outlineCount = 256

        init(reference: [Gray], origin: [SIMD2<Float>], points: [SIMD2<Float>], features: [SIMD2<Float>], previous: [Gray], radius: Int, size: SIMD2<Double>) {
            self.reference = reference
            self.origin = origin
            self.points = points
            self.features = features
            self.previous = previous
            self.radius = radius
            self.size = size
            initialFeatures = features.count
        }

        /// Moves features and control points onto `next`; returns the share of features that moved with the group.
        mutating func advance(to next: [Gray], gray: Gray) -> Double {
            var pairs: [(SIMD2<Double>, SIMD2<Double>)] = []
            for f in features {
                guard let q = ShapeTracker.checkedTrack(previous, f, next, guess: .zero, radius: ShapeTracker.featureRadius, maxError: 0.8) else { continue }
                pairs.append((SIMD2(Double(f.x), Double(f.y)), SIMD2(Double(q.x), Double(q.y))))
            }
            let fit = ShapeTracker.groupMotion(pairs, threshold: 1.5)
            let model = fit?.map
            let tolerance = Float(max(3, 0.012 * size.y))
            for i in points.indices {
                let p = points[i]
                let predicted = model.map { m -> SIMD2<Float> in let q = m(SIMD2(Double(p.x), Double(p.y))); return SIMD2(Float(q.x), Float(q.y)) }
                var own: SIMD2<Float>?
                if let q = ShapeTracker.checkedTrack(previous, p, next, guess: predicted.map { $0 - p } ?? .zero, radius: radius, maxError: 1.2) {
                    own = q
                    // Re-aligning the starting patch keeps small frame-to-frame errors from adding up.
                    if let fix = PointTracker.track(reference, origin[i], next, guess: q - origin[i], radius: radius), simd_length(origin[i] + fix.d - q) < 1.5, fix.residual < 0.08 {
                        own = origin[i] + fix.d
                    }
                }
                switch (own, predicted) {
                case let (o?, pr?): points[i] = simd_length(o - pr) < tolerance ? o : pr
                case let (o?, nil): points[i] = o
                case let (nil, pr?): points[i] = pr
                case (nil, nil): break
                }
            }
            let inliers = fit?.inliers ?? []
            features = inliers.map { SIMD2(Float(pairs[$0].1.x), Float(pairs[$0].1.y)) }
            if features.count < max(24, initialFeatures / 2) {
                let fresh = ShapeTracker.features(gray, inside: points, limit: ShapeTracker.maxFeatures, avoiding: features)
                features += fresh
            }
            previous = next
            guard inliers.count >= 6 else { return 0 }
            return Double(inliers.count) / Double(max(pairs.count, 1))
        }

        var fractions: [SIMD2<Double>] { points.map { SIMD2(Double($0.x) / size.x, Double($0.y) / size.y) } }

        /// The outline of the matte region the shape covers, `outlineCount` points, started where it best lines up
        /// with the previous frame's.
        func regionOutline(_ mask: MaskBuffer) -> (region: MaskBuffer, outline: [SIMD2<Double>])? {
            guard let region = Contour.region(mask, seed: fractions) else { return nil }
            let aspect = size.x / size.y
            let raw = Contour.boundary(region)
            guard raw.count >= 8 else { return nil }
            var dense = Contour.resampled(raw, count: State.outlineCount, aspect: aspect)
            if let previous = outline { dense = Contour.aligned(dense, to: previous) }
            return (region, dense)
        }

        /// Pins every point within `reach` frame heights of the region's edge to its place along the outline.
        mutating func attach(to mask: MaskBuffer, reach: Double) {
            guard let dense = regionOutline(mask)?.outline else { return }
            let scale = SIMD2(size.x / size.y, 1.0)
            along = fractions.map { p in
                let j = dense.indices.min { simd_distance(dense[$0] * scale, p * scale) < simd_distance(dense[$1] * scale, p * scale) }!
                return simd_distance(dense[j] * scale, p * scale) <= reach ? j : nil
            }
            outline = dense
        }

        /// Contour following: pinned points move to their place along this frame's outline (when that agrees with
        /// the group's motion); the others snap to the nearest edge along the shape's normal within `reach`.
        mutating func follow(_ mask: MaskBuffer, reach: Double) {
            guard let (region, dense) = regionOutline(mask) else { return }
            let aspect = size.x / size.y, scale = SIMD2(aspect, 1.0)
            let poly = fractions
            var moved = poly
            for i in poly.indices {
                if i < along.count, let j = along[i], simd_distance(dense[j] * scale, poly[i] * scale) <= max(3 * reach, 0.06) {
                    moved[i] = dense[j]
                } else if let q = RotoTracker.snap(poly[i], prev: poly[(i - 1 + poly.count) % poly.count], next: poly[(i + 1) % poly.count], mask: region, radius: reach, aspect: aspect) {
                    moved[i] = q
                }
            }
            outline = dense
            points = moved.map { SIMD2(Float($0.x * size.x), Float($0.y * size.y)) }
        }
    }

    /// `p` tracked from `a` to `b` when tracking back lands within `maxError` pixels of where it started.
    static func checkedTrack(_ a: [Gray], _ p: SIMD2<Float>, _ b: [Gray], guess: SIMD2<Float>, radius: Int, maxError: Float) -> SIMD2<Float>? {
        guard let f = PointTracker.track(a, p, b, guess: guess, radius: radius), f.residual < 0.1 else { return nil }
        let q = p + f.d
        guard q.x >= 0, q.y >= 0, q.x < Float(b[0].width), q.y < Float(b[0].height),
              let back = PointTracker.track(b, q, a, guess: -f.d, radius: radius), simd_length(q + back.d - p) <= maxError else { return nil }
        return q
    }

    /// The motion most feature pairs share: RANSAC over affine maps, refit on the inliers.
    static func groupMotion(_ pairs: [(SIMD2<Double>, SIMD2<Double>)], threshold: Double) -> (map: (SIMD2<Double>) -> SIMD2<Double>, inliers: [Int])? {
        guard !pairs.isEmpty else { return nil }
        if pairs.count < 3 {
            let shift = SIMD2(RotoTracker.median(pairs.map { $0.1.x - $0.0.x }), RotoTracker.median(pairs.map { $0.1.y - $0.0.y }))
            return ({ $0 + shift }, Array(pairs.indices))
        }
        func apply(_ m: [Double], _ p: SIMD2<Double>) -> SIMD2<Double> { SIMD2(m[0] * p.x + m[1] * p.y + m[2], m[3] * p.x + m[4] * p.y + m[5]) }
        var rng = SplitMix(seed: UInt64(pairs.count) &* 2_654_435_761)
        var best: [Int] = []
        for _ in 0..<min(200, pairs.count * pairs.count) {
            var pick = Set<Int>()
            while pick.count < 3 { pick.insert(Int(rng.next() % UInt64(pairs.count))) }
            guard let m = RotoTracker.affine(pick.map { pairs[$0] }) else { continue }
            let inliers = pairs.indices.filter { simd_distance(apply(m, pairs[$0].0), pairs[$0].1) < threshold }
            if inliers.count > best.count { best = inliers }
            if best.count == pairs.count { break }
        }
        guard best.count >= 3, let affine = RotoTracker.affine(best.map { pairs[$0] }) else {
            let shift = SIMD2(RotoTracker.median(pairs.map { $0.1.x - $0.0.x }), RotoTracker.median(pairs.map { $0.1.y - $0.0.y }))
            return ({ $0 + shift }, [])
        }
        let inliers = pairs.indices.filter { simd_distance(apply(affine, pairs[$0].0), pairs[$0].1) < threshold }
        return ({ apply(affine, $0) }, inliers)
    }

    /// Shi–Tomasi corners inside polygon `poly` (pixels), strongest first, at least 6 px apart and from `avoiding`.
    static func features(_ g: Gray, inside poly: [SIMD2<Float>], limit: Int, avoiding: [SIMD2<Float>] = []) -> [SIMD2<Float>] {
        guard poly.count >= 3 else { return [] }
        let xs = poly.map(\.x), ys = poly.map(\.y)
        let x0 = max(2, Int(xs.min()!) - 1), x1 = min(g.width - 3, Int(xs.max()!) + 1)
        let y0 = max(2, Int(ys.min()!) - 1), y1 = min(g.height - 3, Int(ys.max()!) + 1)
        guard x1 > x0 + 4, y1 > y0 + 4 else { return [] }
        let w = x1 - x0 + 1, h = y1 - y0 + 1
        var gxx = [Float](repeating: 0, count: w * h), gxy = gxx, gyy = gxx
        for y in 0..<h {
            for x in 0..<w {
                let i = (y + y0) * g.width + (x + x0)
                let dx = (g.v[i + 1] - g.v[i - 1]) / 2, dy = (g.v[i + g.width] - g.v[i - g.width]) / 2
                gxx[y * w + x] = dx * dx; gxy[y * w + x] = dx * dy; gyy[y * w + x] = dy * dy
            }
        }
        func boxed(_ a: [Float]) -> [Float] {
            var integral = [Float](repeating: 0, count: (w + 1) * (h + 1))
            for y in 0..<h {
                var row: Float = 0
                for x in 0..<w {
                    row += a[y * w + x]
                    integral[(y + 1) * (w + 1) + x + 1] = integral[y * (w + 1) + x + 1] + row
                }
            }
            let r = 3
            var out = [Float](repeating: 0, count: w * h)
            for y in 0..<h {
                let ya = max(0, y - r), yb = min(h, y + r + 1)
                for x in 0..<w {
                    let xa = max(0, x - r), xb = min(w, x + r + 1)
                    out[y * w + x] = integral[yb * (w + 1) + xb] - integral[ya * (w + 1) + xb] - integral[yb * (w + 1) + xa] + integral[ya * (w + 1) + xa]
                }
            }
            return out
        }
        let sxx = boxed(gxx), sxy = boxed(gxy), syy = boxed(gyy)
        var score = [Float](repeating: 0, count: w * h)
        var top: Float = 0
        for i in score.indices {
            let a = sxx[i], b = sxy[i], c = syy[i]
            let e = (a + c) / 2 - (((a - c) * (a - c)) / 4 + b * b).squareRoot()
            score[i] = e
            top = max(top, e)
        }
        guard top > 1e-6 else { return [] }
        let margin = featureRadius + 2
        var candidates: [(Float, Int, Int)] = []
        for y in stride(from: 1, to: h - 1, by: 1) {
            for x in stride(from: 1, to: w - 1, by: 1) {
                let s = score[y * w + x]
                guard s > top * 0.02, s >= score[y * w + x - 1], s >= score[y * w + x + 1], s >= score[(y - 1) * w + x], s >= score[(y + 1) * w + x] else { continue }
                let px = x + x0, py = y + y0
                guard px >= margin, py >= margin, px < g.width - margin, py < g.height - margin, Contour.contains(poly, SIMD2(Float(px), Float(py))) else { continue }
                candidates.append((s, px, py))
            }
        }
        candidates.sort { $0.0 > $1.0 }
        var out: [SIMD2<Float>] = []
        let minDistance: Float = 6
        for (_, x, y) in candidates {
            let p = SIMD2(Float(x), Float(y))
            if out.contains(where: { simd_distance($0, p) < minDistance }) || avoiding.contains(where: { simd_distance($0, p) < minDistance }) { continue }
            out.append(p)
            if out.count >= limit { break }
        }
        return out
    }

    // MARK: Contour roto

    /// The outline of the `kind` matte region the shape covers, `count` points, on every frame; the region is
    /// picked by overlap with the previous frame's outline (at the start, `seed`, else the largest region).
    static func contour(media url: URL, from start: Seconds, to end: Seconds, seed: [SIMD2<Double>]?, kind: Segmentation.Kind, count: Int, fps: Double, cuts: [Seconds]) async throws -> Run {
        var previous = seed
        var last: [SIMD2<Double>]?
        var aspect = 16.0 / 9
        let run = try await walk(media: url, from: start, to: end, fps: fps, cuts: cuts) { buffer, t, _ in
            aspect = Double(CVPixelBufferGetWidth(buffer)) / Double(max(1, CVPixelBufferGetHeight(buffer)))
            guard let mask = Segmentation.lowRes(kind, CIImage(cvPixelBuffer: buffer)), mask.width > 1,
                  let region = Contour.region(mask, seed: previous), let outline = Contour.outline(region, count: count, aspect: aspect, after: last) else {
                return RotoTracker.Key(t: t, points: last ?? Contour.resampled(seed ?? [], count: count), confidence: 0)
            }
            previous = outline
            last = outline
            return RotoTracker.Key(t: t, points: outline, confidence: 1)
        }
        guard run.keys.contains(where: { $0.confidence > 0 }) else { return run }
        // Holds before the first outline found; light smoothing over time steadies the edge.
        var keys = run.keys
        if let first = keys.first(where: { $0.confidence > 0 })?.points { for i in keys.indices where keys[i].points.count != count { keys[i].points = first } }
        return Run(keys: Contour.smoothed(keys), cut: run.cut)
    }
}

/// Matte regions and their outlines.
enum Contour {
    /// Even–odd point-in-polygon test.
    static func contains(_ poly: [SIMD2<Float>], _ p: SIMD2<Float>) -> Bool {
        var inside = false
        var j = poly.count - 1
        for i in poly.indices {
            let a = poly[i], b = poly[j]
            if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
            j = i
        }
        return inside
    }

    /// The connected region (mask above 0.5) that `seed` (frame fractions) covers most, as a 0/1 mask; with no seed,
    /// or a seed touching none, the largest region (nearest the seed's center when it has one). Nil when empty.
    static func region(_ mask: MaskBuffer, seed: [SIMD2<Double>]?) -> MaskBuffer? {
        let w = mask.width, h = mask.height
        var labels = [Int32](repeating: -1, count: w * h)
        var sizes: [Int] = [], sumX: [Double] = [], sumY: [Double] = []
        var stack: [Int] = []
        for start in 0..<(w * h) where mask.values[start] > 0.5 && labels[start] < 0 {
            let id = Int32(sizes.count)
            labels[start] = id
            stack.append(start)
            var n = 0, sx = 0.0, sy = 0.0
            while let i = stack.popLast() {
                n += 1
                let x = i % w, y = i / w
                sx += Double(x); sy += Double(y)
                if x > 0, labels[i - 1] < 0, mask.values[i - 1] > 0.5 { labels[i - 1] = id; stack.append(i - 1) }
                if x < w - 1, labels[i + 1] < 0, mask.values[i + 1] > 0.5 { labels[i + 1] = id; stack.append(i + 1) }
                if y > 0, labels[i - w] < 0, mask.values[i - w] > 0.5 { labels[i - w] = id; stack.append(i - w) }
                if y < h - 1, labels[i + w] < 0, mask.values[i + w] > 0.5 { labels[i + w] = id; stack.append(i + w) }
            }
            sizes.append(n); sumX.append(sx); sumY.append(sy)
        }
        guard !sizes.isEmpty else { return nil }
        var best = sizes.indices.max { sizes[$0] < sizes[$1] }!
        if let seed, seed.count >= 3 {
            let poly = seed.map { SIMD2(Float($0.x * Double(w)), Float($0.y * Double(h))) }
            var overlap = [Int](repeating: 0, count: sizes.count)
            let ys = poly.map(\.y), xs = poly.map(\.x)
            let y0 = max(0, Int(ys.min()!)), y1 = min(h - 1, Int(ys.max()!) + 1), x0 = max(0, Int(xs.min()!)), x1 = min(w - 1, Int(xs.max()!) + 1)
            if y1 >= y0, x1 >= x0 {
                for y in y0...y1 {
                    for x in x0...x1 {
                        let l = labels[y * w + x]
                        if l >= 0, contains(poly, SIMD2(Float(x) + 0.5, Float(y) + 0.5)) { overlap[Int(l)] += 1 }
                    }
                }
            }
            if let top = overlap.indices.max(by: { overlap[$0] < overlap[$1] }), overlap[top] > 0 {
                best = top
            } else {
                let cx = seed.map(\.x).reduce(0, +) / Double(seed.count) * Double(w), cy = seed.map(\.y).reduce(0, +) / Double(seed.count) * Double(h)
                best = sizes.indices.min { hypot(sumX[$0] / Double(sizes[$0]) - cx, sumY[$0] / Double(sizes[$0]) - cy) < hypot(sumX[$1] / Double(sizes[$1]) - cx, sumY[$1] / Double(sizes[$1]) - cy) }!
            }
        }
        let id = Int32(best)
        return MaskBuffer(width: w, height: h, values: labels.map { $0 == id ? 1 : 0 })
    }

    /// The outer boundary of a 0/1 region traced pixel by pixel (Moore neighbourhood), as frame fractions in
    /// clockwise order on screen.
    static func boundary(_ region: MaskBuffer) -> [SIMD2<Double>] {
        let w = region.width, h = region.height
        func on(_ x: Int, _ y: Int) -> Bool { x >= 0 && y >= 0 && x < w && y < h && region.values[y * w + x] > 0.5 }
        guard let start = region.values.firstIndex(where: { $0 > 0.5 }) else { return [] }
        // Clockwise on screen (y down): E, SE, S, SW, W, NW, N, NE.
        let dirs = [(1, 0), (1, 1), (0, 1), (-1, 1), (-1, 0), (-1, -1), (0, -1), (1, -1)]
        var c = (start % w, start / w)
        var back = 4
        var out = [c]
        let limit = 4 * (w + h) * 8
        while out.count < limit {
            var next: (Int, Int)?
            for k in 1...8 {
                let d = (back + k) % 8
                let n = (c.0 + dirs[d].0, c.1 + dirs[d].1)
                if on(n.0, n.1) {
                    let pd = (back + k - 1) % 8
                    let b = (c.0 + dirs[pd].0, c.1 + dirs[pd].1)
                    back = dirs.firstIndex { $0.0 == b.0 - n.0 && $0.1 == b.1 - n.1 } ?? 4
                    next = n
                    break
                }
            }
            guard let n = next else { break }
            if n == out[0], out.count > 1 { break }
            out.append(n)
            c = n
        }
        return out.map { SIMD2((Double($0.0) + 0.5) / Double(w), (Double($0.1) + 0.5) / Double(h)) }
    }

    /// `count` points evenly spaced along closed polygon `poly`, starting at its first point.
    static func resampled(_ poly: [SIMD2<Double>], count: Int, aspect: Double = 1) -> [SIMD2<Double>] {
        guard poly.count >= 2, count > 0 else { return poly }
        let scale = SIMD2(aspect, 1.0)
        var lengths = [0.0]
        for i in poly.indices { lengths.append(lengths.last! + simd_distance(poly[i] * scale, poly[(i + 1) % poly.count] * scale)) }
        let total = lengths.last!
        guard total > 0 else { return [SIMD2<Double>](repeating: poly[0], count: count) }
        var out: [SIMD2<Double>] = []
        var seg = 0
        for k in 0..<count {
            let s = total * Double(k) / Double(count)
            while seg < poly.count - 1, lengths[seg + 1] < s { seg += 1 }
            let a = poly[seg], b = poly[(seg + 1) % poly.count]
            let f = (s - lengths[seg]) / max(lengths[seg + 1] - lengths[seg], 1e-12)
            out.append(a + (b - a) * f)
        }
        return out
    }

    /// Drops the point spanning the least area (Visvalingam) until `count` remain.
    static func simplified(_ poly: [SIMD2<Double>], count: Int, aspect: Double) -> [SIMD2<Double>] {
        var pts = poly
        let scale = SIMD2(aspect, 1.0)
        func area(_ i: Int) -> Double {
            let a = pts[(i - 1 + pts.count) % pts.count] * scale, b = pts[i] * scale, c = pts[(i + 1) % pts.count] * scale
            return abs((b.x - a.x) * (c.y - a.y) - (c.x - a.x) * (b.y - a.y))
        }
        var areas = pts.indices.map(area)
        while pts.count > max(3, count) {
            let i = areas.indices.min { areas[$0] < areas[$1] }!
            pts.remove(at: i)
            areas.remove(at: i)
            let n = pts.count
            areas[(i - 1 + n) % n] = area((i - 1 + n) % n)
            areas[i % n] = area(i % n)
        }
        return pts
    }

    /// The region's outline as `count` points: traced, smoothed, simplified, and started where it best lines up
    /// with `after` (the previous frame's outline) so neighbouring keys interpolate without twisting.
    static func outline(_ region: MaskBuffer, count: Int, aspect: Double, after previous: [SIMD2<Double>]?) -> [SIMD2<Double>]? {
        let raw = boundary(region)
        guard raw.count >= 8 else { return nil }
        let dense = resampled(raw, count: min(raw.count, 360), aspect: aspect)
        let smooth = dense.indices.map { i in (dense[(i - 1 + dense.count) % dense.count] + dense[i] * 2 + dense[(i + 1) % dense.count]) / 4 }
        var pts = simplified(smooth, count: count, aspect: aspect)
        while pts.count < count { pts = resampled(pts, count: count, aspect: aspect) }
        if let previous, previous.count == pts.count {
            pts = aligned(pts, to: previous)
        } else if let top = pts.indices.min(by: { pts[$0].y < pts[$1].y }) {
            pts = (0..<pts.count).map { pts[($0 + top) % pts.count] }
        }
        return pts
    }

    /// `pts` started at the point that lines it up best with `previous` (same count), so index k stays at about the
    /// same place along the outline from frame to frame.
    static func aligned(_ pts: [SIMD2<Double>], to previous: [SIMD2<Double>]) -> [SIMD2<Double>] {
        let n = pts.count
        guard n == previous.count, n > 0 else { return pts }
        let step = max(1, n / 64)
        func cost(_ shift: Int) -> Double { stride(from: 0, to: n, by: step).reduce(0.0) { $0 + simd_distance_squared(pts[($1 + shift) % n], previous[$1]) } }
        let shift = (0..<n).min { cost($0) < cost($1) }!
        return (0..<n).map { pts[($0 + shift) % n] }
    }

    /// Keys averaged with their neighbours in time (1-2-1), ends kept.
    static func smoothed(_ keys: [RotoTracker.Key]) -> [RotoTracker.Key] {
        guard keys.count > 2 else { return keys }
        var out = keys
        for i in 1..<(keys.count - 1) where keys[i - 1].points.count == keys[i].points.count && keys[i + 1].points.count == keys[i].points.count {
            out[i].points = keys[i].points.indices.map { (keys[i - 1].points[$0] + keys[i].points[$0] * 2 + keys[i + 1].points[$0]) / 4 }
        }
        return out
    }
}

/// Deterministic pseudo-random numbers for RANSAC.
struct SplitMix {
    var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
