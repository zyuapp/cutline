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

    static func - (a: GaussStats, b: GaussStats) -> GaussStats {
        var c = a
        c.n -= b.n
        for i in c.sum.indices { c.sum[i] -= b.sum[i] }
        for i in c.outer.indices { c.outer[i] -= b.outer[i] }
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


/// Per-frame vectors the speaker models see: MFCC c1…c`Diarizer.clusterDims`.
struct VoiceFrames {
    let dims = Diarizer.clusterDims
    let x: [Float]
    let features: FrameFeatures

    init(_ f: FrameFeatures) {
        let d = Diarizer.clusterDims
        var x = [Float](repeating: 0, count: f.count * d)
        for i in 0..<f.count { for j in 0..<d { x[i * d + j] = f.mfcc[i * FrameFeatures.mfccCount + j] } }
        self.x = x
        features = f
    }

    /// Speech frames of a word.
    func frames(_ w: Word) -> [Int] { Diarizer.speechFrames(features, start: w.start, end: w.end) }

    func stats(_ frames: [Int]) -> GaussStats {
        var s = GaussStats(dims: dims)
        x.withUnsafeBufferPointer { m in
            for i in frames { s.add(UnsafeBufferPointer(rebasing: m[(i * dims)..<((i + 1) * dims)])) }
        }
        return s
    }

    /// Summed log-likelihood of `frames` under each model; `-inf` for inactive ones.
    func logLikelihoods(_ frames: [Int], _ models: [GaussModel?]) -> [Double] {
        var ll = [Double](repeating: 0, count: models.count)
        x.withUnsafeBufferPointer { m in
            for i in frames {
                let v = UnsafeBufferPointer(rebasing: m[(i * dims)..<((i + 1) * dims)])
                for (c, model) in models.enumerated() { if let model { ll[c] += model.logLikelihood(v) } }
            }
        }
        return models.indices.map { models[$0] == nil ? -.infinity : ll[$0] }
    }
}

extension Diarizer {
    /// MFCCs c1…c`clusterDims` model a voice; higher ones mostly carry phonetic detail.
    static let clusterDims = 13
    static let covarianceFloor = 0.05
    /// BIC penalty weight; frames overlap, so plain BIC (1.0) over-splits.
    static let bicPenalty = 2.6
    static let minSeedFrames = 60
    /// A speaker needs this many usable frames (about this many centiseconds of voiced speech) to stand alone.
    static let minSpeakerFrames = 250

    /// Speech frames (above the segment's level gate) in `start...end`.
    static func speechFrames(_ f: FrameFeatures, start: Double, end: Double) -> [Int] {
        let r = f.frames(start: start, end: end)
        guard let peak = f.db[r].max() else { return [] }
        let gate = max(peak - 30, f.speechFloor)
        return r.filter { f.db[$0] > gate }
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
    /// to `maxSpeakers`. Seeds in `cannot` pairs never share a cluster. Returns a label per seed, numbered from 0.
    static func bicClusters(_ seeds: [GaussStats], maxSpeakers: Int, cannot: Set<Pair> = []) -> [Int] {
        var clusters = seeds
        var members = seeds.indices.map { [$0] }
        var alive = [Bool](repeating: true, count: seeds.count)
        let n = seeds.count
        guard n >= 2 else { return [Int](repeating: 0, count: n) }
        func blocked(_ i: Int, _ j: Int) -> Bool {
            !cannot.isEmpty && members[i].contains { a in members[j].contains { cannot.contains(Pair(a, $0)) } }
        }
        func distance(_ i: Int, _ j: Int) -> Double { blocked(i, j) ? .infinity : deltaBIC(clusters[i], clusters[j]) }
        var dist = [Double](repeating: .infinity, count: n * n)
        for i in 0..<n { for j in (i + 1)..<n { dist[i * n + j] = distance(i, j) } }
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
                let v = distance(min(bi, k), max(bi, k))
                if k < bi { dist[k * n + bi] = v } else { dist[bi * n + k] = v }
            }
        }
        var labels = [Int](repeating: 0, count: n)
        for i in 0..<n where alive[i] { for m in members[i] { labels[m] = i } }
        return renumber(labels)
    }

    /// Labels renumbered 0… in order of first appearance.
    static func renumber(_ labels: [Int]) -> [Int] {
        var ids: [Int: Int] = [:]
        return labels.map { l in
            if let id = ids[l] { return id }
            ids[l] = ids.count
            return ids.count - 1
        }
    }

    /// An unordered pair of indices.
    struct Pair: Hashable {
        let a: Int, b: Int
        init(_ x: Int, _ y: Int) { a = min(x, y); b = max(x, y) }
    }

    /// One Gaussian per speaker over its units' frames; nil for speakers with too little speech to model.
    static func speakerModels(_ unitFrames: [[Int]], _ labels: [Int], _ v: VoiceFrames, minFrames: Int = minSeedFrames * 2) -> [GaussModel?] {
        let k = (labels.max() ?? 0) + 1
        var stats = [GaussStats](repeating: GaussStats(dims: v.dims), count: k)
        for (u, fr) in unitFrames.enumerated() { stats[labels[u]] = stats[labels[u]] + v.stats(fr) }
        return stats.map { $0.n >= Double(minFrames) ? GaussModel($0, floor: covarianceFloor) : nil }
    }

    /// Refines unit labels with one full-covariance Gaussian per speaker, decoded by Viterbi so a turn changes only
    /// between units, at the given cost.
    static func resegment(_ unitFrames: [[Int]], costs: [Double], labels: [Int], v: VoiceFrames) -> [Int] {
        var current = labels
        for _ in 0..<5 {
            let models = speakerModels(unitFrames, current, v)
            guard models.compactMap({ $0 }).count >= 2 else { return current }
            let emit = unitFrames.map { fr in
                // Neighbouring frames overlap, so count them at a fraction of their weight.
                fr.isEmpty ? models.map { $0 == nil ? -Double.infinity : 0 } : v.logLikelihoods(fr, models).map { $0 * frameWeight }
            }
            let path = viterbi(emit, costs: costs)
            if path == current { break }
            current = path
        }
        return renumber(current)
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

    /// Joins speakers whose voices are too alike to be different people, closest first, then folds speakers with
    /// too little speech to stand alone into the voice that explains them best. `wordFrames` lists each unit's words'
    /// frames. Speakers holding units in a `cannot` pair stay apart; speakers seen talking as the same face
    /// (`faceOf`, per unit) need less likeness to join. Labels are renumbered 0….
    static func mergeSimilarSpeakers(_ wordFrames: [[[Int]]], labels: [Int], v: VoiceFrames, cannot: Set<Pair> = [], faceOf: [Int?] = []) -> [Int] {
        let k = (labels.max() ?? 0) + 1
        var perWord = [[[Int]]](repeating: [], count: k)
        var units = [[Int]](repeating: [], count: k)
        for (u, ws) in wordFrames.enumerated() {
            units[labels[u]].append(u)
            for fr in ws where !fr.isEmpty { perWord[labels[u]].append(fr) }
        }
        var frames = perWord.map { $0.flatMap { $0 } }
        let ubm = VoiceModel(v.x, dims: v.dims, frames: frames.flatMap { $0 })
        var acc = frames.map { ubm.accumulate(v.x, frames: $0) }
        var gauss = frames.map { v.stats($0) }
        var parent = Array(0..<k)
        func root(_ x: Int) -> Int { parent[x] == x ? x : root(parent[x]) }
        func apart(_ a: Int, _ b: Int) -> Bool {
            !cannot.isEmpty && units[a].contains { x in units[b].contains { cannot.contains(Pair(x, $0)) } }
        }
        func faces(_ a: Int) -> Set<Int> { Set(units[a].compactMap { faceOf.indices.contains($0) ? faceOf[$0] : nil }) }
        func join(_ a: Int, _ b: Int) {
            parent[b] = a
            perWord[a] += perWord[b]
            frames[a] += frames[b]
            units[a] += units[b]
            acc[a] = ubm.accumulate(v.x, frames: frames[a])
            gauss[a] = gauss[a] + gauss[b]
        }
        while true {
            var best = (d: Double.infinity, a: -1, b: -1)
            let roots = (0..<k).filter { root($0) == $0 && !frames[$0].isEmpty }
            for (i, a) in roots.enumerated() {
                for b in roots[(i + 1)...] where !apart(a, b) {
                    // The per-class voice distance and the whole-voice divergence must call them alike, and words
                    // held out from each must not be told apart reliably.
                    let sameFace = !faces(a).isDisjoint(with: faces(b))
                    let slack = sameFace ? 1.6 : 1.0
                    let dist = ubm.distance(ubm.adapted(acc[a]), ubm.adapted(acc[b])) / slack
                    guard dist < best.d, dist < sameVoiceDistance, divergence(gauss[a], gauss[b]) < sameVoiceDivergence * slack,
                          heldOutAccuracy(perWord[a], perWord[b], v) < (sameFace ? 0.92 : separableAccuracy) else { continue }
                    best = (dist, a, b)
                }
            }
            guard best.a >= 0 else { break }
            join(best.a, best.b)
        }
        // Splitting off a voice heard for only a moment is more often a mistake (a shout, music under a line) than a
        // new person.
        while true {
            let roots = (0..<k).filter { root($0) == $0 && !frames[$0].isEmpty }
            guard roots.count > 1, let small = roots.filter({ frames[$0].count < minSpeakerFrames }).min(by: { frames[$0].count < frames[$1].count }) else { break }
            let others = roots.filter { $0 != small && !apart($0, small) }
            guard !others.isEmpty else { break }
            let models = others.map { GaussModel(gauss[$0], floor: covarianceFloor) }
            let ll = v.logLikelihoods(frames[small], models)
            let target = others[ll.indices.max { ll[$0] < ll[$1] }!]
            join(target, small)
        }
        return renumber(labels.map { root($0) })
    }

    /// Held-out word accuracy above which two speakers are kept apart.
    static let separableAccuracy = 0.8

    /// How often a Gaussian per speaker, trained on every other word, picks the right speaker for the remaining words.
    static func heldOutAccuracy(_ a: [[Int]], _ b: [[Int]], _ v: VoiceFrames) -> Double {
        guard a.count >= 4, b.count >= 4 else { return 0 }
        var right = 0, total = 0
        for fold in 0..<2 {
            func train(_ ws: [[Int]]) -> GaussModel {
                GaussModel(v.stats(ws.enumerated().filter { $0.offset % 2 == fold }.flatMap(\.element)), floor: covarianceFloor)
            }
            let models = [train(a), train(b)]
            for (truthA, ws) in [(true, a), (false, b)] {
                for (j, w) in ws.enumerated() where j % 2 != fold {
                    let ll = v.logLikelihoods(w, models)
                    if (ll[0] > ll[1]) == truthA { right += 1 }
                    total += 1
                }
            }
        }
        return Double(right) / Double(max(total, 1))
    }

    static let frameWeight = 0.35
    static let closeSwitchCost = 9.0
    static let breakSwitchCost = 4.0
    static let pauseSwitchCost = 2.0
    /// A change at a pause inside a sentence needs this much evidence.
    static let midSentenceSwitchCost = 14.0
    /// Gap between words that splits a segment and makes a speaker change cheaper.
    static let segmentBreak = 0.12
    /// A pause inside a sentence at least this long may separate two speakers.
    static let turnPause = 0.25

    /// Viterbi cost in nats of a speaker change between two consecutive words: cheap at pauses and sentence ends,
    /// dear between words that run together.
    static func switchCost(_ a: Word, _ b: Word) -> Double {
        let gap = b.start - a.end
        if gap > maxSegmentGap { return pauseSwitchCost }
        if endsSentence(a.text) || gap > segmentBreak { return breakSwitchCost }
        return closeSwitchCost
    }

    /// Cost of a speaker change between two sentence units: cheap at a sentence end, dearer the shorter the pause,
    /// dearest at a pause inside a sentence.
    static func unitSwitchCost(_ a: Word, _ b: Word) -> Double {
        guard endsSentence(a.text) else { return midSentenceSwitchCost }
        return b.start - a.end > maxSegmentGap ? pauseSwitchCost : breakSwitchCost
    }

    static func endsSentence(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: CharacterSet(charactersIn: "\"')]”’"))
        return t.last.map { ".?!…".contains($0) } ?? false
    }

    /// Best label path; `costs[t]` is the price of a change between items t-1 and t.
    static func viterbi(_ emit: [[Double]], costs: [Double]) -> [Int] {
        let n = emit.count, k = emit.first?.count ?? 0
        guard n > 0, k > 0 else { return [] }
        var cost = emit[0]
        var back = [[Int]](repeating: [Int](repeating: 0, count: k), count: n)
        for t in 1..<max(1, n) {
            let penalty = costs[t]
            var next = [Double](repeating: -.infinity, count: k)
            for c in 0..<k {
                var best = -Double.infinity
                back[t][c] = c
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

    /// The most a turn can score when little else is heard of its voice: nothing else confirms it is a person of its own.
    static let singleTurnConfidence = 0.6

    /// 0…1 per turn: how much better the turn's speaker, modelled without this turn, explains its frames than the
    /// next best speaker, as a per-frame margin in nats scaled by the evidence behind it. A speaker heard little outside
    /// this turn is modelled with it and scores at most `singleTurnConfidence`.
    static func turnConfidence(_ frames: [Int], label: Int, stats: [GaussStats], v: VoiceFrames) -> Double {
        let minFrames = Double(minSeedFrames)
        guard stats.filter({ $0.n >= minFrames }).count >= 2 else { return 1 }
        guard !frames.isEmpty, stats.indices.contains(label) else { return 0.5 }
        let rest = stats[label] - v.stats(frames)
        // A model from only a few seconds of other turns is too rough to judge this one by.
        let heldOut = rest.n >= Double(minSpeakerFrames)
        let own = GaussModel(heldOut ? rest : stats[label], floor: covarianceFloor)
        let models: [GaussModel?] = stats.indices.map { c in c == label ? own : stats[c].n >= minFrames ? GaussModel(stats[c], floor: covarianceFloor) : nil }
        let ll = v.logLikelihoods(frames, models)
        let other = ll.indices.filter { $0 != label }.map { ll[$0] }.max() ?? -.infinity
        guard other.isFinite else { return 1 }
        let perFrame = (ll[label] - other) / Double(frames.count)
        let evidence = perFrame * (Double(frames.count) * frameWeight).squareRoot()
        let score = 1 / (1 + exp(-evidence / 4))
        return heldOut ? score : min(score, singleTurnConfidence)
    }
}
