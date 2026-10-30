import Foundation

/// A diagonal Gaussian mixture over frame features (a "universal background model" of every voice in a file),
/// used to compare voices one phonetic class at a time: each speaker's frames adapt the component means, and
/// voices are as far apart as their adapted means, weighted by component and scaled by its spread.
struct VoiceModel {
    let dims: Int
    var weights: [Double]
    var means: [[Double]]
    var vars: [[Double]]

    /// Fits `components` Gaussians to the frames listed in `frames` of `x` (row-major, `dims` per frame) by EM,
    /// seeded with quantiles of the first coefficient.
    init(_ x: [Float], dims d: Int, frames all: [Int], components k: Int = 16, iterations: Int = 8, maxFrames: Int = 60_000) {
        dims = d
        let step = max(1, all.count / maxFrames)
        let idx = Array(stride(from: 0, to: all.count, by: step).map { all[$0] })
        let n = idx.count
        var globalMean = [Double](repeating: 0, count: d), globalVar = [Double](repeating: 0, count: d)
        for i in idx { for j in 0..<d { globalMean[j] += Double(x[i * d + j]) } }
        for j in 0..<d { globalMean[j] /= Double(max(n, 1)) }
        for i in idx { for j in 0..<d { let e = Double(x[i * d + j]) - globalMean[j]; globalVar[j] += e * e } }
        for j in 0..<d { globalVar[j] = max(globalVar[j] / Double(max(n, 1)), 1e-3) }
        guard n >= 40 else {
            means = [globalMean]
            weights = [1]
            vars = [globalVar]
            return
        }
        let k = max(1, min(k, n / 20))
        let sorted = idx.sorted { x[$0 * d] < x[$1 * d] }
        means = (0..<k).map { c in
            let chunk = sorted[(c * n / k)..<max(c * n / k + 1, (c + 1) * n / k)]
            return (0..<d).map { j in chunk.reduce(0) { $0 + Double(x[$1 * d + j]) } / Double(chunk.count) }
        }
        weights = [Double](repeating: 1 / Double(k), count: k)
        vars = [[Double]](repeating: globalVar, count: k)
        guard n > k else { return }
        for _ in 0..<iterations {
            var nk = [Double](repeating: 0, count: k)
            var sx = [[Double]](repeating: [Double](repeating: 0, count: d), count: k)
            var sxx = sx
            for i in idx {
                let post = posteriors(x, i)
                for c in 0..<k where post[c] > 1e-6 {
                    nk[c] += post[c]
                    for j in 0..<d {
                        let v = Double(x[i * d + j])
                        sx[c][j] += post[c] * v
                        sxx[c][j] += post[c] * v * v
                    }
                }
            }
            for c in 0..<k where nk[c] > 1 {
                weights[c] = nk[c] / Double(n)
                for j in 0..<d {
                    let m = sx[c][j] / nk[c]
                    self.means[c][j] = m
                    vars[c][j] = max(sxx[c][j] / nk[c] - m * m, globalVar[j] * 0.01)
                }
            }
        }
    }

    /// Component posteriors of frame `i`.
    func posteriors(_ x: [Float], _ i: Int) -> [Double] {
        let k = weights.count
        var lp = [Double](repeating: 0, count: k)
        for c in 0..<k {
            var s = log(max(weights[c], 1e-12))
            for j in 0..<dims {
                let e = Double(x[i * dims + j]) - means[c][j]
                s -= 0.5 * (e * e / vars[c][j] + log(vars[c][j]))
            }
            lp[c] = s
        }
        let m = lp.max() ?? 0
        let z = lp.reduce(0) { $0 + exp($1 - m) }
        return lp.map { exp($0 - m) / z }
    }

    /// Component occupancies and first-order sums of `frames`.
    func accumulate(_ x: [Float], frames: [Int]) -> (n: [Double], sum: [[Double]]) {
        let k = weights.count
        var nk = [Double](repeating: 0, count: k)
        var sx = [[Double]](repeating: [Double](repeating: 0, count: dims), count: k)
        for i in frames {
            let post = posteriors(x, i)
            for c in 0..<k where post[c] > 1e-6 {
                nk[c] += post[c]
                for j in 0..<dims { sx[c][j] += post[c] * Double(x[i * dims + j]) }
            }
        }
        return (nk, sx)
    }

    /// Mean-adapted model of accumulated statistics (relevance MAP).
    func adapted(_ acc: (n: [Double], sum: [[Double]]), relevance r: Double = 8) -> [[Double]] {
        means.indices.map { c in
            (0..<dims).map { j in (acc.sum[c][j] + r * means[c][j]) / (acc.n[c] + r) }
        }
    }

    /// Weighted, variance-scaled squared distance between two adapted mean sets.
    func distance(_ a: [[Double]], _ b: [[Double]]) -> Double {
        var s = 0.0
        for c in weights.indices {
            var t = 0.0
            for j in 0..<dims { let e = a[c][j] - b[c][j]; t += e * e / vars[c][j] }
            s += weights[c] * t
        }
        return s
    }
}
