import CoreVideo
import CutlineCore
import Foundation

/// A small color fingerprint of a 32BGRA frame: block means and per-channel histograms.
struct FrameSignature {
    static let cols = 32, rows = 18, bins = 16
    /// Mean RGB of each block, 0…1, rows from the top.
    var blocks: [Float]
    /// Per-channel histograms (R, G, B), each summing to 1.
    var histogram: [Float]

    init(_ pb: CVPixelBuffer) {
        let view = PixelView(pb)
        defer { view.unlock() }
        let w = view.width, h = view.height
        let cols = FrameSignature.cols, rows = FrameSignature.rows, bins = FrameSignature.bins
        var sums = [Float](repeating: 0, count: cols * rows * 3)
        var counts = [Float](repeating: 0, count: cols * rows)
        var hist = [Float](repeating: 0, count: bins * 3)
        let step = max(1, min(w, h) / 90)
        var n: Float = 0
        for y in stride(from: step / 2, to: h, by: step) {
            let row = view.base + y * view.rowBytes
            let by = min(rows - 1, y * rows / h)
            for x in stride(from: step / 2, to: w, by: step) {
                let p = row + x * 4
                let r = Int(p[2]), g = Int(p[1]), b = Int(p[0])
                let o = by * cols + min(cols - 1, x * cols / w)
                sums[o * 3] += Float(r)
                sums[o * 3 + 1] += Float(g)
                sums[o * 3 + 2] += Float(b)
                counts[o] += 1
                hist[r * bins / 256] += 1
                hist[bins + g * bins / 256] += 1
                hist[2 * bins + b * bins / 256] += 1
                n += 1
            }
        }
        for o in counts.indices where counts[o] > 0 {
            for c in 0..<3 { sums[o * 3 + c] /= counts[o] * 255 }
        }
        blocks = sums
        histogram = hist.map { $0 / max(1, n) }
    }

    /// Mean absolute block difference (0…1) and histogram distance (half the L1 distance averaged over channels, 0…1).
    func distance(_ other: FrameSignature) -> (blocks: Float, histogram: Float) {
        var b: Float = 0
        for i in blocks.indices { b += abs(blocks[i] - other.blocks[i]) }
        var hd: Float = 0
        for i in histogram.indices { hd += abs(histogram[i] - other.histogram[i]) }
        return (b / Float(max(1, blocks.count)), hd / 6)
    }
}

/// Splits a sequence of frames (read forward or backward) into shots. Hard cuts are found on the fly from frame
/// differences measured against the shot's own motion; `cuts` from scene analysis (sampled, so up to `slack` seconds
/// late) make detection more sensitive near them and force a cut at the largest change there when none is found.
final class ShotSplitter {
    static let slack: Seconds = 0.3

    private let cuts: [Seconds]
    private let frameDuration: Seconds
    private var last: FrameSignature?
    private var lastTime: Seconds?
    private var recent: [(blocks: Float, histogram: Float)] = []
    private(set) var times: [Seconds] = []
    /// Whether frame `k` (in feed order) starts a new shot.
    private(set) var flags: [Bool] = []
    private var scores: [Float] = []
    /// Transitions inside each analysis cut's window, while the window is open.
    private var open: [Int: [Int]] = [:]
    private var closed = Set<Int>()

    init(cuts: [Seconds], frameDuration: Seconds) {
        self.cuts = cuts.sorted()
        self.frameDuration = max(1e-3, frameDuration)
    }

    /// Feeds the next frame.
    func feed(_ pb: CVPixelBuffer, time: Seconds) {
        feed(FrameSignature(pb), time: time)
    }

    func feed(_ sig: FrameSignature, time: Seconds) {
        let k = flags.count
        times.append(time)
        guard let prev = last, let pt = lastTime else {
            flags.append(false)
            scores.append(0)
            last = sig
            lastTime = time
            return
        }
        let d = sig.distance(prev)
        let mid = (pt + time) / 2
        let windows = cuts.indices.filter { !closed.contains($0) && mid >= cuts[$0] - ShotSplitter.slack && mid <= cuts[$0] + frameDuration }
        let cut = ShotSplitter.isCut(d, recent: recent, sensitive: !windows.isEmpty)
        flags.append(cut)
        scores.append(d.blocks + d.histogram)
        if cut { recent.removeAll() } else {
            recent.append(d)
            if recent.count > 24 { recent.removeFirst() }
        }
        for c in windows { open[c, default: []].append(k) }
        for c in Array(open.keys) where !windows.contains(c) { close(c) }
        last = sig
        lastTime = time
    }

    /// Closes every open analysis window, at the end of the sequence.
    func finish() {
        for c in Array(open.keys) { close(c) }
    }

    /// Whether frame `k`'s flag can still change.
    func isFinal(_ k: Int) -> Bool {
        !open.values.contains { $0.contains(k) }
    }

    private func close(_ c: Int) {
        guard let ks = open.removeValue(forKey: c) else { return }
        closed.insert(c)
        guard !ks.contains(where: { flags[$0] }), let best = ks.max(by: { scores[$0] < scores[$1] }), scores[best] > 0.02 else { return }
        flags[best] = true
    }

    /// A hard cut: a change several times the shot's own frame-to-frame motion and noise, mostly in colors, mostly in
    /// structure, or very large in structure. Pans move structure but keep colors; grain moves neither much.
    static func isCut(_ d: (blocks: Float, histogram: Float), recent: [(blocks: Float, histogram: Float)], sensitive: Bool) -> Bool {
        func median(_ v: [Float]) -> Float { v.isEmpty ? 0 : v.sorted()[v.count / 2] }
        let mb = median(recent.map(\.blocks)), mh = median(recent.map(\.histogram))
        let k: Float = sensitive ? 0.5 : 1
        let colors = d.histogram > max(0.2 * k, 5 * k * mh + 0.02) && d.blocks > max(0.03 * k, 1.8 * k * mb)
        let structure = d.blocks > max(0.06 * k, 3.5 * k * mb + 0.01) && d.histogram > max(0.08 * k, 2.5 * k * mh + 0.01)
        return colors || structure || d.blocks > max(0.18 * k, 4 * mb + 0.02)
    }

    /// Whether frames `a` and `b` (feed order) are in the same shot, by flags as they stand.
    func sameShot(_ a: Int, _ b: Int) -> Bool {
        let lo = min(a, b), hi = max(a, b)
        guard lo >= 0, hi < flags.count else { return false }
        if lo == hi { return true }
        for k in (lo + 1)...hi where flags[k] { return false }
        return true
    }
}

/// Where a tracker leaves the shot it started in.
public struct ShotBoundary: Sendable, Equatable {
    /// Source time between the last frame of the starting shot and the first of the next.
    public var time: Seconds
    /// Whether scene analysis placed a cut there, rather than only the frame difference.
    public var fromAnalysis: Bool
}

/// Follows a tracker's frames and says when they cross a cut; analysis cuts may be found a little after the frame
/// that crosses them, so the tracker drops samples past the boundary it is given.
final class TrackerShotGuard {
    private let splitter: ShotSplitter
    private let cuts: [Seconds]

    init(cuts: [Seconds], frameDuration: Seconds) {
        self.cuts = cuts
        splitter = ShotSplitter(cuts: cuts, frameDuration: frameDuration)
    }

    /// Feeds the next frame read; returns the boundary once one is certain.
    func feed(_ pb: CVPixelBuffer, time: Seconds) -> ShotBoundary? {
        splitter.feed(pb, time: time)
        return boundary()
    }

    /// The boundary at the end of the frames, with open analysis windows resolved.
    func finish() -> ShotBoundary? {
        splitter.finish()
        return boundary()
    }

    private func boundary() -> ShotBoundary? {
        let flags = splitter.flags
        guard let k = flags.indices.dropFirst().first(where: { flags[$0] }), splitter.isFinal(k) else { return nil }
        let t = (splitter.times[k - 1] + splitter.times[k]) / 2
        let near = cuts.contains { abs($0 - t) <= ShotSplitter.slack + 0.05 }
        return ShotBoundary(time: t, fromAnalysis: near)
    }
}
