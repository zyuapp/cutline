import Foundation

/// Time maps: a clip's playback as the source seconds it shows over its local time, linear between points, as
/// FCPXML `timeMap`, FCP7 Time Remap and AAF Motion Control offset maps carry speed, reverse, freezes and ramps.
extension Clip {
    /// Plays its source other than forward at 1×: a speed, reverse, freeze or speed ramp.
    var isWarped: Bool { abs(speed - 1) > 1e-9 || reverse || isRetimed }

    /// A speed ramp, reverse or freeze: playback a single forward speed can't describe.
    var needsTimeMap: Bool { reverse || isRetimed }

    /// Source seconds shown at grid frames `lo...hi` from the clip start: the ends, the speed curve's keys, and every
    /// `step` frames where the speed changes between keys, so straight lines between them follow the clip.
    func timeMap(frames lo: Int, _ hi: Int, grid: FrameGrid, step: Int = 3) -> [(frame: Int, source: Seconds)] {
        func sec(_ f: Int) -> Seconds { Double(f * grid.num) / Double(grid.den) }
        var at: Set<Int> = [lo, hi]
        if let c = anim["time.speed"] {
            var varying: [(Int, Int)] = []
            if c.expression != nil {
                varying = [(lo, hi)]
            } else {
                for k in c.keys { at.insert(grid.frames(k.t)) }
                for (a, b) in zip(c.keys, c.keys.dropFirst()) where b.ease != .hold && (a.v != b.v || b.bezier != nil) {
                    varying.append((grid.frames(a.t), grid.frames(b.t)))
                }
            }
            for (a, b) in varying { for f in stride(from: a, to: b, by: max(1, step)) { at.insert(f) } }
        }
        return at.filter { $0 >= lo && $0 <= hi }.sorted().map { ($0, sourceTime(atTimeline: start + sec($0))) }
    }
}

extension Importer {
    /// Sets `c`'s speed, reverse, freeze or speed ramp (held speeds between keys) from a time map: source seconds at
    /// local seconds from the clip start, linear between points and beyond the ends. Points within `tolerance` of a
    /// straight line merge. Returns a warning when the map can't be played as given.
    static func retime(_ c: inout Clip, map input: [(t: Seconds, source: Seconds)], tolerance: Seconds = 0.002) -> String? {
        var pts: [(t: Seconds, source: Seconds)] = []
        for p in input.sorted(by: { $0.t < $1.t }) {
            if let last = pts.last, p.t - last.t < 1e-9 { pts[pts.count - 1] = p } else { pts.append(p) }
        }
        guard let first = pts.first else { return nil }
        c.anim["time.speed"] = nil
        c.reverse = false
        guard pts.count >= 2 else {
            c.sourceIn = first.source
            freeze(&c)
            return nil
        }
        if c.duration > 0 {
            // Only the stretch the clip plays.
            let all = pts
            func at(_ t: Seconds) -> (t: Seconds, source: Seconds) {
                let i = min(max(0, (all.firstIndex { $0.t > t } ?? all.count) - 1), all.count - 2)
                let a = all[i], b = all[i + 1]
                return (t, a.source + (t - a.t) * (b.source - a.source) / (b.t - a.t))
            }
            pts = [at(0)] + all.filter { $0.t > 1e-9 && $0.t < c.duration - 1e-9 } + [at(c.duration)]
        }
        pts = simplified(pts, tolerance: tolerance)
        let slopes = zip(pts, pts.dropFirst()).map { a, b -> Double in
            let s = (b.source - a.source) / (b.t - a.t)
            return abs(s) < 1e-6 ? 0 : s
        }
        func source(at t: Seconds) -> Seconds {
            let i = min(max(0, (pts.firstIndex { $0.t > t } ?? pts.count) - 1), slopes.count - 1)
            return pts[i].source + (t - pts[i].t) * slopes[i]
        }
        let s0 = slopes[0]
        let forward = slopes.allSatisfy { $0 >= 0 }, backward = slopes.allSatisfy { $0 <= 0 }
        var warning: String?
        func clamped(_ s: Double) -> Double {
            if s > 100 || s < 0.01 { warning = "Speed \(String(format: "%.3g", s))× of \(c.name ?? "a clip") clamped to 0.01–100×" }
            return Importer.niceSpeed(min(max(s, 0.01), 100))
        }
        if slopes.allSatisfy({ abs($0 - s0) <= 1e-3 * max(1, abs(s0)) }) {
            if s0 == 0 {
                c.sourceIn = source(at: 0)
                freeze(&c)
            } else {
                c.speed = clamped(abs(s0))
                c.reverse = s0 < 0
                c.sourceIn = c.reverse ? source(at: 0) - c.duration * c.speed : source(at: 0)
            }
            return warning
        }
        guard forward || backward else {
            let average = (source(at: c.duration) - source(at: 0)) / max(c.duration, 1e-9)
            c.speed = clamped(abs(average))
            c.reverse = average < 0
            c.sourceIn = c.reverse ? source(at: 0) - c.duration * c.speed : source(at: 0)
            return "\(c.name ?? "A clip") plays forwards and backwards; imported at its average \(String(format: "%.3g", average))×"
        }
        var keys: [CurveKey] = []
        for (i, s) in slopes.enumerated() {
            let v = abs(s) == 0 ? 0 : min(max(abs(s), 0.01), 100)
            if abs(s) > 100 { warning = "Speed of \(c.name ?? "a clip") clamped to 100×" }
            if let last = keys.last, case .number(let lv) = last.v, abs(lv - v) < 1e-9 { continue }
            keys.append(CurveKey(t: i == 0 ? min(pts[0].t, 0) : pts[i].t, v: .number(v), ease: .hold))
        }
        c.speed = abs(s0) >= 0.01 ? clamped(abs(s0)) : 1
        c.reverse = backward
        c.anim["time.speed"] = Curve(keys: keys)
        c.sourceIn = backward ? source(at: 0) - c.sourceOffset(atLocal: c.duration) : source(at: 0)
        return warning
    }

    /// Douglas–Peucker: the fewest points whose straight segments stay within `tolerance` source seconds of `pts`.
    static func simplified(_ pts: [(t: Seconds, source: Seconds)], tolerance: Seconds) -> [(t: Seconds, source: Seconds)] {
        guard pts.count > 2 else { return pts }
        var keep = [Bool](repeating: false, count: pts.count)
        keep[0] = true
        keep[pts.count - 1] = true
        var stack = [(0, pts.count - 1)]
        while let (a, b) = stack.popLast() {
            guard b > a + 1 else { continue }
            let slope = (pts[b].source - pts[a].source) / (pts[b].t - pts[a].t)
            var worst = (index: -1, error: tolerance)
            for i in (a + 1)..<b {
                let e = abs(pts[a].source + (pts[i].t - pts[a].t) * slope - pts[i].source)
                if e > worst.error { worst = (i, e) }
            }
            if worst.index >= 0 {
                keep[worst.index] = true
                stack += [(a, worst.index), (worst.index, b)]
            }
        }
        return pts.indices.filter { keep[$0] }.map { pts[$0] }
    }
}
