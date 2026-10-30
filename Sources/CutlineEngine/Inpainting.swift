import Foundation
import simd

/// Exemplar-based image completion: fills a hole with patches copied from the rest of the picture, so texture and
/// edges carry across it. Multi-scale expectation-maximization over a PatchMatch nearest-neighbour field (Wexler,
/// Shechtman and Irani 2007; Barnes et al. 2009), with luma gradients in the patch distance so matches line up
/// structure, and an optional guide (the previous frame's fill, moved with the camera) that seeds the field and
/// votes in the result so a filled region holds still from frame to frame.
enum Inpainter {
    struct Options {
        /// Patches are (2·radius + 1)² pixels.
        var radius = 3
        /// Weight of the luma gradient against color in patch distances.
        var gradientWeight: Float = 2
        /// EM steps at the coarsest level and at the finest.
        var coarseSteps = 10
        var fineSteps = 3
        /// PatchMatch passes per EM step.
        var searchPasses = 2
        /// Weight of the guide's vote against the patches' (at full weight per pixel, the guide counts as much as
        /// all the patches together).
        var guideWeight: Float = 0.5
        /// Draws straight lines and edges across the hole before the patch fill.
        var structure = true
        /// Evens out tone steps at the hole's edge (gradient-domain blending of the fill into the picture).
        var blend = true
    }

    /// Adds to the hole the smooth correction that makes it meet the picture around it: the harmonic function whose
    /// value across each edge of the hole is the step there, so the fill keeps its own detail but not its seams.
    static func blendSeams(_ rgb: inout [Float], width w: Int, height h: Int, hole: [Bool], limit: Float = 0.05) {
        let pixels = hole.indices.filter { hole[$0] }
        guard !pixels.isEmpty else { return }
        var x0 = w, x1 = 0, y0 = h, y1 = 0
        for i in pixels { x0 = min(x0, i % w); x1 = max(x1, i % w); y0 = min(y0, i / w); y1 = max(y1, i / w) }
        // Per hole pixel: its hole neighbours, and the summed step to its known neighbours.
        var index = [Int32](repeating: -1, count: w * h)
        for (k, i) in pixels.enumerated() { index[i] = Int32(k) }
        var links = [Int32](repeating: -1, count: pixels.count * 4)
        var step = [SIMD3<Float>](repeating: .zero, count: pixels.count)
        var boundary = [Float](repeating: 0, count: pixels.count)
        for (k, i) in pixels.enumerated() {
            let x = i % w, y = i / w
            let here = SIMD3(rgb[i * 3], rgb[i * 3 + 1], rgb[i * 3 + 2])
            for (n, (dx, dy)) in [(-1, 0), (1, 0), (0, -1), (0, 1)].enumerated() {
                let nx = x + dx, ny = y + dy
                guard nx >= 0, ny >= 0, nx < w, ny < h else { continue }
                let j = ny * w + nx
                if hole[j] { links[k * 4 + n] = index[j] } else {
                    // Small steps are tone seams; big ones are mostly edges in the picture, so they count only a little.
                    let there = SIMD3<Float>(rgb[j * 3], rgb[j * 3 + 1], rgb[j * 3 + 2])
                    step[k] += simd_clamp(there - here, SIMD3<Float>(repeating: -limit), SIMD3<Float>(repeating: limit))
                    boundary[k] += 1
                }
            }
        }
        // Successive over-relaxation. A capped number of sweeps settles the band along the edge, where seams show;
        // deep inside a large hole the correction stays partial.
        var correction = [SIMD3<Float>](repeating: .zero, count: pixels.count)
        let sweeps = min(120, 2 * max(x1 - x0, y1 - y0) + 20)
        let omega: Float = 1.9
        for _ in 0..<sweeps {
            for k in 0..<pixels.count {
                var sum = step[k]
                var n = boundary[k]
                for l in 0..<4 {
                    let j = links[k * 4 + l]
                    if j >= 0 { sum += correction[Int(j)]; n += 1 }
                }
                guard n > 0 else { continue }
                correction[k] += omega * (sum / n - correction[k])
            }
        }
        for (k, i) in pixels.enumerated() {
            for c in 0..<3 { rgb[i * 3 + c] += correction[k][c] }
        }
    }

    /// The previous result for this region: color per pixel (valid where `has`) and the source each pixel's patch
    /// came from (pixel index in this region, or -1).
    struct Guide {
        var rgb: [Float]
        var has: [Bool]
        var nnf: [Int32]
    }

    struct Result {
        /// Finest-level nearest-neighbour field: per pixel, the source patch center (-1 where the pixel's patch
        /// doesn't touch the hole).
        var nnf: [Int32]
        var levels: Int
        /// Straight structures drawn across the hole.
        var lines: Int
    }

    /// Fills `hole` pixels of `rgb` (width·height·3, rows from the top) in place.
    @discardableResult
    static func fill(_ rgb: inout [Float], width w: Int, height h: Int, hole: [Bool], guide: Guide? = nil, options o: Options = Options()) -> Result {
        let holeCount = hole.reduce(0) { $0 + ($1 ? 1 : 0) }
        guard holeCount > 0, w > 2 * o.radius + 2, h > 2 * o.radius + 2 else { return Result(nnf: [Int32](repeating: -1, count: w * h), levels: 0, lines: 0) }
        // A guide that covers most of the hole replaces the coarse levels: the fill is refined where it was.
        let guided = guide.map { g in zip(hole, g.has).reduce(0) { $0 + ($1.0 && $1.1 ? 1 : 0) } > holeCount * 7 / 10 } ?? false
        // Straight lines and edges that run into the hole from both sides are drawn across it first and held fixed,
        // so the patch fill builds texture around them instead of losing them at coarse scales.
        var work = rgb
        let lines = o.structure ? Structure.lines(work, width: w, height: h, hole: hole) : []
        let drawn = Structure.propagate(lines, &work, width: w, height: h, hole: hole)
        let open = zip(hole, drawn).map { $0 && !$1 }
        var pyramid = [Level(width: w, height: h, rgb: work, hole: open, blocked: drawn)]
        if !guided {
            // Coarsen until the hole is a few patches across in its narrow direction.
            while true {
                let top = pyramid.last!
                let (bw, bh) = top.holeExtent
                guard min(bw, bh) > 3 * o.radius, top.width / 2 > 6 * o.radius, top.height / 2 > 6 * o.radius else { break }
                pyramid.append(top.downsampled())
            }
        }
        var nnf: [Int32]? = nil
        for k in stride(from: pyramid.count - 1, through: 0, by: -1) {
            var level = pyramid[k]
            level.prepareSources(radius: o.radius)
            guard !level.sources.isEmpty else { continue }
            let coarsest = k == pyramid.count - 1
            var field: [Int32]
            if let nnf, k + 1 < pyramid.count {
                field = level.upsampled(nnf, from: pyramid[k + 1], radius: o.radius)
                level.vote(field, radius: o.radius, sharp: false, guide: nil, guideWeight: 0)
            } else if guided, let g = guide {
                field = level.seeded(g, radius: o.radius)
                for i in 0..<level.count where level.hole[i] && g.has[i] {
                    for c in 0..<3 { level.rgb[i * 3 + c] = g.rgb[i * 3 + c] }
                }
                level.peel(skip: g.has)
            } else {
                level.peel(skip: nil)
                field = [Int32](repeating: -1, count: level.count)
            }
            let steps = guided ? o.fineSteps : coarsest ? o.coarseSteps : k == 0 ? o.fineSteps : max(o.fineSteps, o.coarseSteps / 2)
            var distance = [Float](repeating: .infinity, count: level.count)
            for step in 0..<steps {
                level.computeFeatures(gradientWeight: o.gradientWeight)
                level.search(&field, &distance, radius: o.radius, passes: o.searchPasses, seed: UInt64(k * 1000 + step))
                let last = k == 0 && step == steps - 1
                level.vote(field, radius: o.radius, sharp: last, distance: distance, guide: k == 0 ? guide : nil, guideWeight: o.guideWeight)
            }
            pyramid[k] = level
            nnf = field
        }
        let finest = pyramid[0]
        for i in 0..<finest.count where hole[i] {
            for c in 0..<3 { rgb[i * 3 + c] = finest.rgb[i * 3 + c] }
        }
        if o.blend { blendSeams(&rgb, width: w, height: h, hole: hole) }
        return Result(nnf: nnf ?? [Int32](repeating: -1, count: w * h), levels: pyramid.count, lines: lines.count)
    }

    /// One scale of the picture being completed.
    struct Level {
        let width: Int
        let height: Int
        var rgb: [Float]
        var hole: [Bool]
        /// Known pixels that patches may not be copied from (drawn structure).
        var blocked: [Bool]
        /// Color plus weighted luma gradients, `featureCount` per pixel.
        var features: [Float] = []
        /// Pixel indices whose whole patch is known and inside the region.
        var sources: [Int32] = []
        var isSource: [Bool] = []
        /// Pixels whose patch touches the hole, by row.
        var targets: [Int32] = []
        static let featureCount = 5

        init(width: Int, height: Int, rgb: [Float], hole: [Bool], blocked: [Bool]? = nil) {
            self.width = width
            self.height = height
            self.rgb = rgb
            self.hole = hole
            self.blocked = blocked ?? [Bool](repeating: false, count: width * height)
        }

        var count: Int { width * height }

        /// Width and height of the hole's bounding box.
        var holeExtent: (Int, Int) {
            var x0 = width, y0 = height, x1 = -1, y1 = -1
            for y in 0..<height {
                for x in 0..<width where hole[y * width + x] {
                    x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
                }
            }
            return x1 < 0 ? (0, 0) : (x1 - x0 + 1, y1 - y0 + 1)
        }

        /// Half size: known pixels average their known children; a pixel with any unknown child is unknown, and one
        /// with any blocked child is blocked.
        func downsampled() -> Level {
            let w = width / 2, h = height / 2
            var out = [Float](repeating: 0, count: w * h * 3)
            var unknown = [Bool](repeating: false, count: w * h)
            var fixed = [Bool](repeating: false, count: w * h)
            for y in 0..<h {
                for x in 0..<w {
                    var s = SIMD3<Float>(repeating: 0)
                    var n: Float = 0
                    for (dx, dy) in [(0, 0), (1, 0), (0, 1), (1, 1)] {
                        let i = (2 * y + dy) * width + 2 * x + dx
                        if blocked[i] { fixed[y * w + x] = true }
                        if hole[i] { unknown[y * w + x] = true } else {
                            s += SIMD3(rgb[i * 3], rgb[i * 3 + 1], rgb[i * 3 + 2])
                            n += 1
                        }
                    }
                    if n > 0 { s /= n }
                    let o = (y * w + x) * 3
                    out[o] = s.x; out[o + 1] = s.y; out[o + 2] = s.z
                }
            }
            return Level(width: w, height: h, rgb: out, hole: unknown, blocked: zip(fixed, unknown).map { $0 && !$1 })
        }

        /// Finds the patch centers that can serve as sources and those whose patch touches the hole.
        mutating func prepareSources(radius r: Int) {
            let w = width, h = height
            func table(_ m: [Bool]) -> [Int32] {
                var sat = [Int32](repeating: 0, count: (w + 1) * (h + 1))
                for y in 0..<h {
                    var row: Int32 = 0
                    for x in 0..<w {
                        row += m[y * w + x] ? 1 : 0
                        sat[(y + 1) * (w + 1) + x + 1] = sat[y * (w + 1) + x + 1] + row
                    }
                }
                return sat
            }
            let holes = table(hole), excluded = table(zip(hole, blocked).map { $0 || $1 })
            func sum(_ sat: [Int32], _ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) -> Int32 {
                sat[(y1 + 1) * (w + 1) + x1 + 1] - sat[y0 * (w + 1) + x1 + 1] - sat[(y1 + 1) * (w + 1) + x0] + sat[y0 * (w + 1) + x0]
            }
            isSource = [Bool](repeating: false, count: w * h)
            sources = []
            targets = []
            for y in r..<(h - r) {
                for x in r..<(w - r) {
                    if sum(holes, x - r, y - r, x + r, y + r) > 0 {
                        targets.append(Int32(y * w + x))
                    } else if sum(excluded, x - r, y - r, x + r, y + r) == 0 {
                        isSource[y * w + x] = true
                        sources.append(Int32(y * w + x))
                    }
                }
            }
        }

        /// Fills hole pixels inward from known neighbours (an initial guess), leaving pixels in `skip` as they are.
        mutating func peel(skip: [Bool]?) {
            let w = width, h = height
            var known = (0..<count).map { !hole[$0] || (skip?[$0] ?? false) }
            var pending = (0..<count).filter { !known[$0] }
            while !pending.isEmpty {
                var next: [Int] = []
                var set: [(Int, SIMD3<Float>)] = []
                for i in pending {
                    let x = i % w, y = i / w
                    var s = SIMD3<Float>(repeating: 0)
                    var n: Float = 0
                    for dy in -1...1 {
                        for dx in -1...1 where dx != 0 || dy != 0 {
                            let nx = x + dx, ny = y + dy
                            guard nx >= 0, ny >= 0, nx < w, ny < h, known[ny * w + nx] else { continue }
                            let j = (ny * w + nx) * 3
                            s += SIMD3(rgb[j], rgb[j + 1], rgb[j + 2])
                            n += 1
                        }
                    }
                    if n > 0 { set.append((i, s / n)) } else { next.append(i) }
                }
                if set.isEmpty { break }
                for (i, v) in set {
                    rgb[i * 3] = v.x; rgb[i * 3 + 1] = v.y; rgb[i * 3 + 2] = v.z
                    known[i] = true
                }
                pending = next
            }
        }

        mutating func computeFeatures(gradientWeight g: Float) {
            let w = width, h = height, f = Level.featureCount
            if features.count != count * f { features = [Float](repeating: 0, count: count * f) }
            rgb.withUnsafeBufferPointer { cb in
                features.withUnsafeMutableBufferPointer { fb in
                    nonisolated(unsafe) let c = cb.baseAddress!, out = fb.baseAddress!
                    parallelRows(h) { rows in
                        for y in rows {
                            let up = max(0, y - 1), down = min(h - 1, y + 1)
                            for x in 0..<w {
                                let i = y * w + x
                                @inline(__always) func luma(_ j: Int) -> Float { 0.3 * c[j * 3] + 0.59 * c[j * 3 + 1] + 0.11 * c[j * 3 + 2] }
                                let gx = luma(y * w + min(w - 1, x + 1)) - luma(y * w + max(0, x - 1))
                                let gy = luma(down * w + x) - luma(up * w + x)
                                let o = i * f
                                out[o] = c[i * 3]
                                out[o + 1] = c[i * 3 + 1]
                                out[o + 2] = c[i * 3 + 2]
                                out[o + 3] = g * 0.5 * gx
                                out[o + 4] = g * 0.5 * gy
                            }
                        }
                    }
                }
            }
        }

        /// Patch distance between centers `p` and `q`, giving up once it passes `limit`.
        @inline(__always) static func distance(_ f: UnsafePointer<Float>, _ p: Int, _ q: Int, width w: Int, radius r: Int, limit: Float) -> Float {
            let n = Level.featureCount
            let span = (2 * r + 1) * n
            var d: Float = 0
            for dy in -r...r {
                let a = f + ((p + dy * w) - r) * n, b = f + ((q + dy * w) - r) * n
                var row: Float = 0
                for k in 0..<span {
                    let e = a[k] - b[k]
                    row += e * e
                }
                d += row
                if d >= limit { return d }
            }
            return d
        }

        /// The coarser level's field doubled onto this level.
        func upsampled(_ coarse: [Int32], from c: Level, radius r: Int) -> [Int32] {
            var field = [Int32](repeating: -1, count: count)
            for t in targets {
                let x = Int(t) % width, y = Int(t) / width
                let cx = min(c.width - 1, x / 2), cy = min(c.height - 1, y / 2)
                let s = coarse[cy * c.width + cx]
                guard s >= 0 else { continue }
                let qx = 2 * (Int(s) % c.width) + (x - 2 * cx), qy = 2 * (Int(s) / c.width) + (y - 2 * cy)
                let q = clampedSource(qx, qy, radius: r)
                if let q { field[Int(t)] = Int32(q) }
            }
            return field
        }

        /// The guide's field where it points at a source here.
        func seeded(_ g: Guide, radius r: Int) -> [Int32] {
            var field = [Int32](repeating: -1, count: count)
            for t in targets {
                let s = g.nnf[Int(t)]
                if s >= 0, isSource[Int(s)] { field[Int(t)] = s }
            }
            return field
        }

        /// The nearest source center to (x, y) within a few pixels, or nil.
        func clampedSource(_ x: Int, _ y: Int, radius r: Int) -> Int? {
            let cx = min(max(x, r), width - 1 - r), cy = min(max(y, r), height - 1 - r)
            if isSource[cy * width + cx] { return cy * width + cx }
            for d in 1...3 {
                for (dx, dy) in [(d, 0), (-d, 0), (0, d), (0, -d)] {
                    let nx = cx + dx, ny = cy + dy
                    if nx >= r, ny >= r, nx < width - r, ny < height - r, isSource[ny * width + nx] { return ny * width + nx }
                }
            }
            return nil
        }

        /// PatchMatch: random fill of missing matches, then passes of propagation from scan neighbours and random
        /// search around the best match, in bands of rows run concurrently.
        func search(_ field: inout [Int32], _ distance: inout [Float], radius r: Int, passes: Int, seed: UInt64) {
            let w = width, h = height
            let rowsOfTargets = Dictionary(grouping: targets, by: { Int($0) / w })
            let rows = rowsOfTargets.keys.sorted()
            guard !rows.isEmpty else { return }
            let chunks = min(rows.count, ProcessInfo.processInfo.activeProcessorCount * 2)
            features.withUnsafeBufferPointer { fb in
                field.withUnsafeMutableBufferPointer { nb in
                    distance.withUnsafeMutableBufferPointer { db in
                        sources.withUnsafeBufferPointer { sb in
                            isSource.withUnsafeBufferPointer { ib in
                                nonisolated(unsafe) let f = fb.baseAddress!, nnf = nb.baseAddress!, dist = db.baseAddress!, src = sb.baseAddress!, valid = ib.baseAddress!
                                let sourceCount = sb.count
                                DispatchQueue.concurrentPerform(iterations: chunks) { k in
                                    let band = Array(rows[rows.count * k / chunks..<rows.count * (k + 1) / chunks])
                                    guard let firstRow = band.first, let lastRow = band.last else { return }
                                    var rng = seed &* 0x9E3779B97F4A7C15 &+ UInt64(k + 1) &* 0xBF58476D1CE4E5B9
                                    @inline(__always) func next() -> UInt64 {
                                        rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17
                                        return rng
                                    }
                                    let mine = band.flatMap { rowsOfTargets[$0]! }
                                    for t in mine {
                                        let p = Int(t)
                                        if nnf[p] < 0 || !valid[Int(nnf[p])] { nnf[p] = src[Int(next() % UInt64(sourceCount))] }
                                        dist[p] = Level.distance(f, p, Int(nnf[p]), width: w, radius: r, limit: .infinity)
                                    }
                                    @inline(__always) func attempt(_ p: Int, _ q: Int) {
                                        guard q >= 0, q < w * h, valid[q], q != Int(nnf[p]) else { return }
                                        let d = Level.distance(f, p, q, width: w, radius: r, limit: dist[p])
                                        if d < dist[p] { dist[p] = d; nnf[p] = Int32(q) }
                                    }
                                    for pass in 0..<passes {
                                        let forward = pass % 2 == 0
                                        let order = forward ? mine : mine.reversed()
                                        let step = forward ? 1 : -1
                                        for t in order {
                                            let p = Int(t)
                                            let x = p % w, y = p / w
                                            // Propagation: a neighbour's match, shifted back by the same step.
                                            let nx = x - step
                                            if nx >= 0, nx < w, nnf[p - step] >= 0 {
                                                attempt(p, Int(nnf[p - step]) + step)
                                            }
                                            let ny = y - step
                                            if ny >= firstRow, ny <= lastRow, nnf[p - step * w] >= 0 {
                                                attempt(p, Int(nnf[p - step * w]) + step * w)
                                            }
                                            // Random search in shrinking windows around the best match.
                                            var span = max(w, h)
                                            let bx = Int(nnf[p]) % w, by = Int(nnf[p]) / w
                                            while span >= 1 {
                                                let qx = bx + Int(next() % UInt64(2 * span + 1)) - span
                                                let qy = by + Int(next() % UInt64(2 * span + 1)) - span
                                                if qx >= r, qy >= r, qx < w - r, qy < h - r { attempt(p, qy * w + qx) }
                                                span /= 2
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        /// Each hole pixel becomes the weighted mean of what the patches covering it propose, weights falling with
        /// patch distance; `sharp` narrows the weights so the final picture keeps the sources' detail. A guide adds
        /// its own vote where it has one.
        mutating func vote(_ field: [Int32], radius r: Int, sharp: Bool, distance: [Float]? = nil, guide: Guide?, guideWeight: Float) {
            let w = width, h = height
            var sigma2: Float = 1
            if let distance {
                var ds = targets.compactMap { distance[Int($0)].isFinite ? distance[Int($0)] : nil }
                if !ds.isEmpty {
                    ds.sort()
                    sigma2 = max(1e-6, ds[min(ds.count - 1, ds.count * 3 / 4)])
                }
            }
            if sharp { sigma2 *= 0.25 }
            let useWeights = distance != nil
            var out = rgb
            rgb.withUnsafeBufferPointer { cb in
                out.withUnsafeMutableBufferPointer { ob in
                    field.withUnsafeBufferPointer { nb in
                        hole.withUnsafeBufferPointer { hb in
                            nonisolated(unsafe) let c = cb.baseAddress!, o = ob.baseAddress!, nnf = nb.baseAddress!, isHole = hb.baseAddress!
                            let dist = distance
                            parallelRows(h) { rows in
                                for y in rows {
                                    for x in 0..<w where isHole[y * w + x] {
                                        var s = SIMD3<Float>(repeating: 0)
                                        var total: Float = 0
                                        for dy in -r...r {
                                            let py = y + dy
                                            guard py >= r, py < h - r else { continue }
                                            for dx in -r...r {
                                                let px = x + dx
                                                guard px >= r, px < w - r else { continue }
                                                let p = py * w + px
                                                let q = nnf[p]
                                                guard q >= 0 else { continue }
                                                let src = Int(q) - dy * w - dx
                                                let weight: Float = useWeights ? exp(-dist![p] / (2 * sigma2)) + 1e-12 : 1
                                                s += weight * SIMD3(c[src * 3], c[src * 3 + 1], c[src * 3 + 2])
                                                total += weight
                                            }
                                        }
                                        let i = y * w + x
                                        if let guide, guide.has[i] {
                                            let gw = guideWeight * max(total, 1e-6)
                                            s += gw * SIMD3(guide.rgb[i * 3], guide.rgb[i * 3 + 1], guide.rgb[i * 3 + 2])
                                            total += gw
                                        }
                                        guard total > 0 else { continue }
                                        s /= total
                                        o[i * 3] = s.x; o[i * 3 + 1] = s.y; o[i * 3 + 2] = s.z
                                    }
                                }
                            }
                        }
                    }
                }
            }
            rgb = out
        }
    }
}

/// Straight structure crossing a hole: lines and edges found around it by a Hough transform of strong gradients,
/// kept when they show on both sides, and drawn across by carrying their cross-section along them.
enum Structure {
    /// A band along a straight line: points p with `lo ≤ p·normal ≤ hi`.
    struct Band: Equatable {
        var normal: SIMD2<Float>
        var lo: Float
        var hi: Float
        var votes: Float

        var direction: SIMD2<Float> { SIMD2(-normal.y, normal.x) }
    }

    static let angleBins = 180

    static func lines(_ rgb: [Float], width w: Int, height h: Int, hole: [Bool]) -> [Band] {
        var x0 = w, y0 = h, x1 = -1, y1 = -1
        for i in hole.indices where hole[i] {
            let x = i % w, y = i / w
            x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
        }
        guard x1 >= 0 else { return [] }
        let size = Float(max(x1 - x0, y1 - y0) + 1)
        let reach = Int(min(80, max(16, 0.8 * size)))
        let luma = (0..<(w * h)).map { (i: Int) -> Float in 0.3 * rgb[i * 3] + 0.59 * rgb[i * 3 + 1] + 0.11 * rgb[i * 3 + 2] }
        // Strong gradients on known pixels around the hole (Sobel), off the hole's edge.
        struct Edge { var x: Float; var y: Float; var angle: Int; var strength: Float }
        var edges: [Edge] = []
        var strengths: [Float] = []
        let gx0 = max(1, x0 - reach), gx1 = min(w - 2, x1 + reach), gy0 = max(1, y0 - reach), gy1 = min(h - 2, y1 + reach)
        guard gx1 > gx0, gy1 > gy0 else { return [] }
        for y in gy0...gy1 {
            for x in gx0...gx1 {
                var near = false
                for dy in -1...1 { for dx in -1...1 where hole[(y + dy) * w + x + dx] { near = true } }
                if near { continue }
                @inline(__always) func l(_ dx: Int, _ dy: Int) -> Float { luma[(y + dy) * w + x + dx] }
                let gx = (l(1, -1) + 2 * l(1, 0) + l(1, 1) - l(-1, -1) - 2 * l(-1, 0) - l(-1, 1)) / 8
                let gy = (l(-1, 1) + 2 * l(0, 1) + l(1, 1) - l(-1, -1) - 2 * l(0, -1) - l(1, -1)) / 8
                let m = (gx * gx + gy * gy).squareRoot()
                strengths.append(m)
                guard m > 0.04 else { continue }
                var a = atan2(gy, gx)
                if a < 0 { a += .pi }
                edges.append(Edge(x: Float(x), y: Float(y), angle: Int(a / .pi * Float(angleBins)) % angleBins, strength: m))
            }
        }
        guard edges.count > 8 else { return [] }
        strengths.sort()
        // Texture is everywhere; structure is the strongest few percent.
        let floor = max(0.04, strengths[strengths.count * 9 / 10])
        edges = edges.filter { $0.strength >= floor }
        let diag = Int((Float(w * w + h * h)).squareRoot()) + 1
        let rhoBins = 2 * diag + 1
        var acc = [Float](repeating: 0, count: angleBins * rhoBins)
        let cosines = (0..<angleBins).map { cos(Float($0) / Float(angleBins) * .pi) }, sines = (0..<angleBins).map { sin(Float($0) / Float(angleBins) * .pi) }
        for e in edges {
            for da in -2...2 {
                let a = (e.angle + da + angleBins) % angleBins
                let rho = Int((e.x * cosines[a] + e.y * sines[a]).rounded()) + diag
                acc[a * rhoBins + rho] += e.strength
            }
        }
        let corners = [SIMD2(Float(x0), Float(y0)), SIMD2(Float(x1), Float(y0)), SIMD2(Float(x0), Float(y1)), SIMD2(Float(x1), Float(y1))]
        let center = SIMD2(Float(x0 + x1) / 2, Float(y0 + y1) / 2)
        var peaks: [(Int, Int, Float)] = []
        for a in 0..<angleBins {
            for r in 1..<(rhoBins - 1) {
                let v = acc[a * rhoBins + r]
                guard v > 0, v >= acc[a * rhoBins + r - 1], v > acc[a * rhoBins + r + 1] else { continue }
                peaks.append((a, r - diag, v))
            }
        }
        peaks.sort { $0.2 > $1.2 }
        var found: [Band] = []
        for (a, rho, votes) in peaks.prefix(60) {
            let n = SIMD2(cosines[a], sines[a])
            let d = SIMD2(-n.y, n.x)
            // The line has to pass through the hole.
            let across = corners.map { simd_dot($0, n) }
            guard Float(rho) >= across.min()! - 1, Float(rho) <= across.max()! + 1 else { continue }
            // Support on both sides of the hole: edges on the line with a matching orientation.
            let mid = simd_dot(center, d)
            let halfSpan = corners.map { abs(simd_dot($0, d) - mid) }.max()!
            // Support on both sides of the hole: the line's edge runs unbroken over most of the scanned stretch
            // (a dashed edge, like the head joints of running-bond bricks, does not continue across).
            let length = reach
            var before = [Bool](repeating: false, count: length), after = [Bool](repeating: false, count: length)
            for e in edges {
                let p = SIMD2(e.x, e.y)
                guard abs(simd_dot(p, n) - Float(rho)) <= 1.5, min(abs(e.angle - a), angleBins - abs(e.angle - a)) <= 6 else { continue }
                let s = simd_dot(p, d) - mid
                let k = Int(abs(s) - halfSpan)
                guard k >= 0, k < length else { continue }
                if s < 0 { before[k] = true } else { after[k] = true }
            }
            // Only the stretch inside the picture counts.
            func inside(_ sign: Float) -> Int {
                (0..<length).filter { k in
                    let q = center + sign * (halfSpan + Float(k)) * d + (Float(rho) - simd_dot(center, n)) * n
                    return q.x >= 1 && q.y >= 1 && q.x <= Float(w - 2) && q.y <= Float(h - 2)
                }.count
            }
            let reachBefore = inside(-1), reachAfter = inside(1)
            let coverBefore = Float(before.filter { $0 }.count) / Float(max(1, reachBefore)), coverAfter = Float(after.filter { $0 }.count) / Float(max(1, reachAfter))
            guard reachBefore >= 6, reachAfter >= 6, coverBefore >= 0.6, coverAfter >= 0.6 else { continue }
            let parallel = { (b: Band) in simd_dot(b.normal, n) > cos(4 * Float.pi / 180) }
            if found.contains(where: { parallel($0) && Float(rho) >= $0.lo - 2 && Float(rho) <= $0.hi + 2 }) { continue }
            // Two edges of one line (or two rails close together) become one band.
            if let k = found.firstIndex(where: { parallel($0) && min(abs(Float(rho) - $0.lo), abs(Float(rho) - $0.hi)) < 14 }) {
                found[k].lo = min(found[k].lo, Float(rho))
                found[k].hi = max(found[k].hi, Float(rho))
                found[k].votes += votes
                continue
            }
            found.append(Band(normal: n, lo: Float(rho), hi: Float(rho), votes: votes))
            if found.count >= 6 { break }
        }
        return found.map { var b = $0; b.lo -= 1.5; b.hi += 1.5; return b }
    }

    /// Fills hole pixels inside each band by carrying the band's cross-section from both sides of the hole and
    /// blending by position; returns the pixels it drew.
    static func propagate(_ bands: [Band], _ rgb: inout [Float], width w: Int, height h: Int, hole: [Bool]) -> [Bool] {
        var drawn = [Bool](repeating: false, count: w * h)
        guard !bands.isEmpty else { return drawn }
        let source = rgb
        var owner = [Float](repeating: .infinity, count: w * h)
        func known(_ x: Int, _ y: Int) -> Bool { x >= 0 && y >= 0 && x < w && y < h && !hole[y * w + x] }
        for band in bands {
            let n = band.normal, d = band.direction
            let mid = (band.lo + band.hi) / 2
            for i in hole.indices where hole[i] {
                let p = SIMD2(Float(i % w), Float(i / w))
                let off = simd_dot(p, n)
                guard off >= band.lo, off <= band.hi else { continue }
                // Where bands cross, the pixel goes to the band it is most central in.
                let centrality = abs(off - mid) / max(1, band.hi - band.lo)
                guard centrality < owner[i] else { continue }
                func side(_ sign: Float) -> (SIMD3<Float>, Float)? {
                    var t: Float = 1
                    while t < Float(w + h) {
                        let q = p + sign * t * d
                        let qx = Int(q.x.rounded()), qy = Int(q.y.rounded())
                        guard qx >= 0, qy >= 0, qx < w, qy < h else { return nil }
                        if known(qx, qy) {
                            // The median of a short run along the line, so a crossing structure just outside the
                            // hole doesn't stand in for the line's profile.
                            var r: [Float] = [], g: [Float] = [], b: [Float] = []
                            for k in 0..<7 {
                                let q = p + sign * (t + Float(k) * 1.5) * d
                                let qx = Int(q.x.rounded()), qy = Int(q.y.rounded())
                                guard known(qx, qy) else { continue }
                                let o = (qy * w + qx) * 3
                                r.append(source[o]); g.append(source[o + 1]); b.append(source[o + 2])
                            }
                            let m = r.count / 2
                            return (SIMD3(r.sorted()[m], g.sorted()[m], b.sorted()[m]), t)
                        }
                        t += 1
                    }
                    return nil
                }
                guard let (a, ta) = side(-1), let (b, tb) = side(1) else { continue }
                let v = a + (b - a) * (ta / (ta + tb))
                rgb[i * 3] = v.x; rgb[i * 3 + 1] = v.y; rgb[i * 3 + 2] = v.z
                drawn[i] = true
                owner[i] = centrality
            }
        }
        return drawn
    }
}
