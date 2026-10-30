import CutlineCore
import Foundation

/// Sufficient statistics of a full-covariance Gaussian over frame features.
struct GaussStats {
    var n: Double
    var sum: [Double]
    var outer: [Double]

    init(dims d: Int) {
        n = 0
        sum = [Double](repeating: 0, count: d)
        outer = [Double](repeating: 0, count: d * d)
    }

    var dims: Int { sum.count }

    mutating func add(_ x: UnsafeBufferPointer<Float>) {
        let d = dims
        n += 1
        for i in 0..<d {
            let a = Double(x[i])
            sum[i] += a
            for j in i..<d { outer[i * d + j] += a * Double(x[j]) }
        }
    }

    static func + (a: GaussStats, b: GaussStats) -> GaussStats {
        var c = a
        c.n += b.n
        for i in c.sum.indices { c.sum[i] += b.sum[i] }
        for i in c.outer.indices { c.outer[i] += b.outer[i] }
        return c
    }

    /// Mean and covariance (lower triangle filled), with `floor` added to the diagonal.
    func moments(floor: Double) -> (mean: [Double], cov: [Double]) {
        let d = dims
        let mean = sum.map { $0 / max(n, 1) }
        var cov = [Double](repeating: 0, count: d * d)
        for i in 0..<d {
            for j in i..<d {
                let v = outer[i * d + j] / max(n, 1) - mean[i] * mean[j]
                cov[i * d + j] = v
                cov[j * d + i] = v
            }
            cov[i * d + i] += floor
        }
        return (mean, cov)
    }

    /// Log-determinant of the covariance.
    func logDet(floor: Double) -> Double {
        GaussStats.cholesky(moments(floor: floor).cov, dims).logDet
    }

    /// Lower-triangular Cholesky factor (row-major) and log-determinant.
    static func cholesky(_ m: [Double], _ d: Int) -> (l: [Double], logDet: Double) {
        var a = m
        var s = 0.0
        for j in 0..<d {
            var v = a[j * d + j]
            for k in 0..<j { v -= a[j * d + k] * a[j * d + k] }
            let l = max(v, 1e-9).squareRoot()
            a[j * d + j] = l
            s += 2 * log(l)
            for i in (j + 1)..<max(j + 1, d) {
                var u = a[i * d + j]
                for k in 0..<j { u -= a[i * d + k] * a[j * d + k] }
                a[i * d + j] = u / l
            }
            for k in (j + 1)..<max(j + 1, d) { a[j * d + k] = 0 }
        }
        return (a, s)
    }
}

/// A full-covariance Gaussian ready to score frames.
struct GaussModel {
    let mean: [Double]
    let chol: [Double]
    let logDet: Double
    let dims: Int

    init(_ s: GaussStats, floor: Double) {
        let m = s.moments(floor: floor)
        mean = m.mean
        dims = s.dims
        let c = GaussStats.cholesky(m.cov, dims)
        chol = c.l
        logDet = c.logDet
    }

    /// Log-likelihood of one frame, without the constant term.
    func logLikelihood(_ x: UnsafeBufferPointer<Float>) -> Double {
        let d = dims
        var y = [Double](repeating: 0, count: d)
        var q = 0.0
        for i in 0..<d {
            var v = Double(x[i]) - mean[i]
            for k in 0..<i { v -= chol[i * d + k] * y[k] }
            y[i] = v / chol[i * d + i]
            q += y[i] * y[i]
        }
        return -0.5 * (q + logDet)
    }
}

extension Diarizer {
    /// MFCCs c1…c`clusterDims` model a voice; higher ones mostly carry phonetic detail.
    static let clusterDims = 13
    static let covarianceFloor = 0.05
    /// BIC penalty weight; frames overlap, so plain BIC (1.0) over-splits.
    static let bicPenalty = 2.6
    static let minSeedFrames = 60

    /// Speech frames (above the segment's level gate) in `start...end`.
    static func speechFrames(_ f: FrameFeatures, start: Double, end: Double) -> [Int] {
        let r = f.frames(start: start, end: end)
        guard let peak = f.db[r].max() else { return [] }
        let gate = max(peak - 30, f.speechFloor)
        return r.filter { f.db[$0] > gate }
    }

    /// Speech frames of a segment's words.
    static func segmentFrames(_ f: FrameFeatures, _ s: Segment, _ words: [Word]) -> [Int] {
        s.words.flatMap { speechFrames(f, start: words[$0].start, end: words[$0].end) }
    }

    static func stats(_ f: FrameFeatures, frames: [Int]) -> GaussStats {
        var s = GaussStats(dims: clusterDims)
        f.mfcc.withUnsafeBufferPointer { m in
            for i in frames { s.add(UnsafeBufferPointer(rebasing: m[(i * FrameFeatures.mfccCount)..<(i * FrameFeatures.mfccCount + clusterDims)])) }
        }
        return s
    }

    /// Change in BIC from modelling `a` and `b` as one Gaussian; negative means they are better merged.
    static func deltaBIC(_ a: GaussStats, _ b: GaussStats) -> Double {
        let d = Double(a.dims)
        let c = a + b
        let glr = 0.5 * (c.n * c.logDet(floor: covarianceFloor) - a.n * a.logDet(floor: covarianceFloor) - b.n * b.logDet(floor: covarianceFloor))
        let params = d + d * (d + 1) / 2
        return glr - bicPenalty * 0.5 * params * log(c.n)
    }

    /// Agglomerative clustering by ΔBIC: merges the closest pair while merging improves BIC, then keeps merging down
    /// to `maxSpeakers`. Returns a label per input.
    static func bicClusters(_ seeds: [GaussStats], maxSpeakers: Int) -> [Int] {
        var clusters = seeds.map { $0 }
        var members = seeds.indices.map { [$0] }
        var alive = [Bool](repeating: true, count: seeds.count)
        let n = seeds.count
        guard n >= 2 else { return [Int](repeating: 0, count: n) }
        var dist = [Double](repeating: .infinity, count: n * n)
        for i in 0..<n { for j in (i + 1)..<n { dist[i * n + j] = deltaBIC(clusters[i], clusters[j]) } }
        var count = n
        while count > 1 {
            var best = Double.infinity, bi = -1, bj = -1
            for i in 0..<n where alive[i] {
                for j in (i + 1)..<n where alive[j] && dist[i * n + j] < best {
                    best = dist[i * n + j]
                    bi = i
                    bj = j
                }
            }
            guard bi >= 0, best < 0 || count > maxSpeakers else { break }
            clusters[bi] = clusters[bi] + clusters[bj]
            members[bi] += members[bj]
            alive[bj] = false
            count -= 1
            for k in 0..<n where alive[k] && k != bi {
                let v = deltaBIC(clusters[bi], clusters[k])
                if k < bi { dist[k * n + bi] = v } else { dist[bi * n + k] = v }
            }
        }
        var labels = [Int](repeating: 0, count: n)
        var next = 0
        var order: [Int: Int] = [:]
        for i in 0..<n where alive[i] {
            for m in members[i] { labels[m] = i }
        }
        return labels.map { l in
            if let o = order[l] { return o }
            order[l] = next
            next += 1
            return next - 1
        }
    }

    /// Refines word labels with one full-covariance Gaussian per speaker over the words' MFCC frames, decoded by
    /// Viterbi so turns can change between any two words; a change between close words costs more than one at a pause.
    static func resegmentFrames(words: [Word], order: [Int], labels: [Int], features f: FrameFeatures) -> [Int] {
        let k = (labels.max() ?? 0) + 1
        let wordFrames = order.map { speechFrames(f, start: words[$0].start, end: words[$0].end) }
        var current = labels
        for _ in 0..<4 {
            var stats = [GaussStats](repeating: GaussStats(dims: clusterDims), count: k)
            for (t, fr) in wordFrames.enumerated() { stats[current[t]] = stats[current[t]] + Diarizer.stats(f, frames: fr) }
            let active = stats.map { $0.n >= Double(minSeedFrames) * 2 }
            guard active.filter({ $0 }).count >= 2 else { return current }
            let models = stats.map { GaussModel($0, floor: covarianceFloor) }
            let emit: [[Double]] = wordFrames.map { fr in
                guard !fr.isEmpty else { return [Double](repeating: 0, count: k) }
                var ll = [Double](repeating: 0, count: k)
                f.mfcc.withUnsafeBufferPointer { m in
                    for i in fr {
                        let x = UnsafeBufferPointer(rebasing: m[(i * FrameFeatures.mfccCount)..<(i * FrameFeatures.mfccCount + clusterDims)])
                        for c in 0..<k where active[c] { ll[c] += models[c].logLikelihood(x) }
                    }
                }
                // Neighbouring frames overlap, so count them at a fraction of their weight.
                return (0..<k).map { active[$0] ? ll[$0] * frameWeight : -.infinity }
            }
            let path = viterbi(emit, words: words, order: order)
            if path == current { break }
            current = path
        }
        return current
    }

    /// Voice-model distance (see `VoiceModel.distance`) below which two speakers may be one voice.
    static let sameVoiceDistance = 2.8
    /// Single-Gaussian divergence (GLR per frame) below which two speakers may be one voice.
    static let sameVoiceDivergence = 1.2

    static func divergence(_ a: GaussStats, _ b: GaussStats) -> Double {
        let c = a + b
        let glr = 0.5 * (c.n * c.logDet(floor: covarianceFloor) - a.n * a.logDet(floor: covarianceFloor) - b.n * b.logDet(floor: covarianceFloor))
        return glr / c.n
    }

    /// Joins speakers whose voices are too alike to be different people, closest first; labels are renumbered 0….
    static func mergeSimilarSpeakers(words: [Word], order: [Int], labels: [Int], features f: FrameFeatures) -> [Int] {
        let k = (labels.max() ?? 0) + 1
        let d = clusterDims, m = FrameFeatures.mfccCount
        var x = [Float](repeating: 0, count: f.count * d)
        for i in 0..<f.count { for j in 0..<d { x[i * d + j] = f.mfcc[i * m + j] } }
        var perWord = [[[Int]]](repeating: [], count: k)
        for (t, i) in order.enumerated() {
            let fr = speechFrames(f, start: words[i].start, end: words[i].end)
            if !fr.isEmpty { perWord[labels[t]].append(fr) }
        }
        var frames = perWord.map { $0.flatMap { $0 } }
        let ubm = VoiceModel(x, dims: d, frames: frames.flatMap { $0 })
        var acc = frames.map { ubm.accumulate(x, frames: $0) }
        var gauss = frames.map { stats(f, frames: $0) }
        var parent = Array(0..<k)
        func root(_ x: Int) -> Int { parent[x] == x ? x : root(parent[x]) }
        while true {
            var best = (d: Double.infinity, a: -1, b: -1)
            let roots = (0..<k).filter { root($0) == $0 && !frames[$0].isEmpty }
            for (i, a) in roots.enumerated() {
                for b in roots[(i + 1)...] {
                    // The per-class voice distance and the whole-voice divergence must call them alike, and words
                    // held out from each must not be told apart reliably.
                    let dist = ubm.distance(ubm.adapted(acc[a]), ubm.adapted(acc[b]))
                    guard dist < best.d, divergence(gauss[a], gauss[b]) < sameVoiceDivergence,
                          heldOutAccuracy(perWord[a], perWord[b], f) < separableAccuracy else { continue }
                    best = (dist, a, b)
                }
            }
            guard best.a >= 0, best.d < sameVoiceDistance else { break }
            parent[best.b] = best.a
            perWord[best.a] += perWord[best.b]
            frames[best.a] += frames[best.b]
            acc[best.a] = ubm.accumulate(x, frames: frames[best.a])
            gauss[best.a] = gauss[best.a] + gauss[best.b]
        }
        var ids: [Int: Int] = [:]
        return labels.map { l in
            let r = root(l)
            if let id = ids[r] { return id }
            ids[r] = ids.count
            return ids.count - 1
        }
    }

    /// Held-out word accuracy above which two speakers are kept apart.
    static let separableAccuracy = 0.8

    /// How often a Gaussian per speaker, trained on every other word, picks the right speaker for the remaining words.
    static func heldOutAccuracy(_ a: [[Int]], _ b: [[Int]], _ f: FrameFeatures) -> Double {
        guard a.count >= 4, b.count >= 4 else { return 0 }
        var right = 0, total = 0
        for fold in 0..<2 {
            func train(_ ws: [[Int]]) -> GaussModel {
                GaussModel(stats(f, frames: ws.enumerated().filter { $0.offset % 2 == fold }.flatMap(\.element)), floor: covarianceFloor)
            }
            let ma = train(a), mb = train(b)
            for (truthA, ws) in [(true, a), (false, b)] {
                for (j, w) in ws.enumerated() where j % 2 != fold {
                    var la = 0.0, lb = 0.0
                    f.mfcc.withUnsafeBufferPointer { m in
                        for i in w {
                            let v = UnsafeBufferPointer(rebasing: m[(i * FrameFeatures.mfccCount)..<(i * FrameFeatures.mfccCount + clusterDims)])
                            la += ma.logLikelihood(v)
                            lb += mb.logLikelihood(v)
                        }
                    }
                    if (la > lb) == truthA { right += 1 }
                    total += 1
                }
            }
        }
        let acc = Double(right) / Double(max(total, 1))
        return acc
    }

    static let frameWeight = 0.35
    static let closeSwitchCost = 9.0
    static let breakSwitchCost = 4.0
    static let pauseSwitchCost = 2.0
    /// Gap between words that splits a segment and makes a speaker change cheaper.
    static let segmentBreak = 0.12

    /// Viterbi cost in nats of a speaker change between two consecutive words: cheap at pauses and sentence ends,
    /// dear between words that run together.
    static func switchCost(_ a: Word, _ b: Word) -> Double {
        let gap = b.start - a.end
        if gap > maxSegmentGap { return pauseSwitchCost }
        if endsSentence(a.text) || gap > segmentBreak { return breakSwitchCost }
        return closeSwitchCost
    }

    static func endsSentence(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: CharacterSet(charactersIn: "\"')]”’"))
        return t.last.map { ".?!…".contains($0) } ?? false
    }

    static func viterbi(_ emit: [[Double]], words: [Word], order: [Int]) -> [Int] {
        let n = emit.count, k = emit.first?.count ?? 0
        guard n > 0, k > 0 else { return [] }
        var cost = emit[0]
        var back = [[Int]](repeating: [Int](repeating: 0, count: k), count: n)
        for t in 1..<max(1, n) {
            let penalty = switchCost(words[order[t - 1]], words[order[t]])
            var next = [Double](repeating: -.infinity, count: k)
            for c in 0..<k {
                var best = -Double.infinity
                for p in 0..<k {
                    let v = cost[p] - (p == c ? 0 : penalty)
                    if v > best { best = v; back[t][c] = p }
                }
                next[c] = best + emit[t][c]
            }
            cost = next
        }
        var path = [Int](repeating: 0, count: n)
        path[n - 1] = (0..<k).max { cost[$0] < cost[$1] }!
        for t in stride(from: n - 1, to: 0, by: -1) { path[t - 1] = back[t][path[t]] }
        return path
    }
}
