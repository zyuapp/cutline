import Accelerate
import AVFoundation
import CutlineCore
import Foundation

/// Speaker diarization and word emphasis from audio plus a word-level transcript.
public enum Diarizer {
    static let decodeRate = 16_000.0
    static let maxSegmentGap = 0.5
    static let maxSegmentDuration = 3.0
    static let minEmbeddingDuration = 0.6
    /// Average-linkage cosine distance above which clusters stay apart.
    static let mergeThreshold = 1.25
    /// Mean silhouette a split into several speakers must reach.
    static let minSilhouette = 0.25
    /// Silhouette needed to split when the merge threshold proposes one speaker.
    static let confidentSilhouette = 0.35
    /// Floored effect size every pair of speakers must reach (see `minSeparation`).
    static let minClusterSeparation = 2.0

    /// Decodes the first audio track to 16 kHz mono and analyzes it.
    public static func analyze(url: URL, transcript: Transcript) async throws -> SpeakerAnalysis {
        let samples = try await decodeMono(url: url)
        return analyze(samples: samples, sampleRate: decodeRate, transcript: transcript)
    }

    /// Labels speakers and scores emphasis for `transcript` over mono `samples`.
    public static func analyze(samples: [Float], sampleRate: Double, transcript: Transcript, maxSpeakers: Int = 6) -> SpeakerAnalysis {
        let words = transcript.words
        let features = FrameFeatures(samples: samples, sampleRate: sampleRate)
        let emphasis = emphasisScores(words: words, features: features)
        let segments = speechSegments(words)
        guard !segments.isEmpty, features.count > 0 else {
            return SpeakerAnalysis(mediaId: transcript.mediaId, speakers: [], segments: [], wordSpeakers: words.map { _ in nil }, emphasis: emphasis)
        }

        var embedded: [Int] = []
        var vectors: [[Float]] = []
        for (i, s) in segments.enumerated() where s.end - s.start >= minEmbeddingDuration {
            if let v = features.embedding(start: s.start, end: s.end) {
                embedded.append(i)
                vectors.append(v)
            }
        }

        var clusterOf = [Int](repeating: 0, count: segments.count)
        if embedded.count >= 2 {
            let labels = clusterSpeakers(vectors, maxSpeakers: max(1, maxSpeakers))
            var known = [Int?](repeating: nil, count: segments.count)
            for (k, i) in embedded.enumerated() { known[i] = labels[k] }
            for i in segments.indices {
                if let l = known[i] { clusterOf[i] = l; continue }
                var best = Double.infinity
                for j in embedded {
                    let gap = max(segments[j].start - segments[i].end, segments[i].start - segments[j].end, 0)
                    if gap < best { best = gap; clusterOf[i] = known[j]! }
                }
            }
        }

        let order = segments.flatMap(\.words)
        var wordCluster = segments.indices.flatMap { i in segments[i].words.map { _ in clusterOf[i] } }
        if Set(wordCluster).count > 1 {
            wordCluster = resegment(words: words, order: order, labels: wordCluster, features: features)
        }

        var names: [Int: String] = [:]
        var speakers: [String] = []
        var spans: [SpeakerSegment] = []
        var wordSpeakers = [String?](repeating: nil, count: words.count)
        for (k, i) in order.enumerated() {
            let name: String
            if let n = names[wordCluster[k]] {
                name = n
            } else {
                name = "S\(speakers.count + 1)"
                names[wordCluster[k]] = name
                speakers.append(name)
            }
            wordSpeakers[i] = name
            let w = words[i]
            if let last = spans.last, last.speaker == name {
                spans[spans.count - 1].end = max(last.end, w.end)
            } else {
                if let last = spans.last { spans[spans.count - 1].end = min(last.end, w.start) }
                spans.append(SpeakerSegment(start: w.start, end: max(w.start, w.end), speaker: name))
            }
        }
        return SpeakerAnalysis(mediaId: transcript.mediaId, speakers: speakers, segments: spans, wordSpeakers: wordSpeakers, emphasis: emphasis)
    }

    // MARK: Resegmentation

    static let emissionWeight = 0.5
    /// Viterbi cost in nats of a speaker change between words closer than `maxSegmentGap`.
    static let switchPenalty = 12.0
    static let pauseSwitchPenalty = 2.0

    /// Refines word labels with per-speaker diagonal Gaussians over word MFCC means and F0,
    /// decoded by Viterbi so turns can change between segments' words.
    static func resegment(words: [Word], order: [Int], labels: [Int], features: FrameFeatures) -> [Int] {
        let k = (labels.max() ?? 0) + 1
        let feats = order.map { features.wordVector(start: words[$0].start, end: words[$0].end) }
        guard let dims = feats.lazy.compactMap({ $0 }).first?.count else { return labels }
        let floors: [Double] = Array(repeating: 0.01, count: dims - 1) + [0.25]
        var current = labels
        for _ in 0..<3 {
            var means = [[Double]](repeating: [Double](repeating: 0, count: dims), count: k)
            var vars = means
            var counts = means
            for (t, f) in feats.enumerated() {
                guard let f else { continue }
                for d in 0..<dims where !f[d].isNaN {
                    means[current[t]][d] += Double(f[d])
                    counts[current[t]][d] += 1
                }
            }
            for c in 0..<k { for d in 0..<dims { means[c][d] /= max(counts[c][d], 1) } }
            for (t, f) in feats.enumerated() {
                guard let f else { continue }
                for d in 0..<dims where !f[d].isNaN {
                    let e = Double(f[d]) - means[current[t]][d]
                    vars[current[t]][d] += e * e
                }
            }
            let active = (0..<k).map { c in counts[c][0] >= 3 }
            guard active.filter({ $0 }).count >= 2 else { return current }
            for c in 0..<k { for d in 0..<dims { vars[c][d] = vars[c][d] / max(counts[c][d], 1) + floors[d] } }

            let n = order.count
            var cost = [Double](repeating: 0, count: k)
            var back = [[Int]](repeating: [Int](repeating: 0, count: k), count: n)
            for t in 0..<n {
                var emit = [Double](repeating: 0, count: k)
                for c in 0..<k {
                    guard active[c] else { emit[c] = -.infinity; continue }
                    guard let f = feats[t] else { continue }
                    var ll = 0.0
                    for d in 0..<dims where !f[d].isNaN {
                        let e = Double(f[d]) - means[c][d]
                        ll -= 0.5 * (e * e / vars[c][d] + log(vars[c][d]))
                    }
                    emit[c] = emissionWeight * ll
                }
                if t == 0 {
                    cost = emit
                    continue
                }
                let gap = words[order[t]].start - words[order[t - 1]].end
                let penalty = gap > maxSegmentGap ? pauseSwitchPenalty : switchPenalty
                var next = [Double](repeating: -.infinity, count: k)
                for c in 0..<k {
                    var best = -Double.infinity
                    for p in 0..<k {
                        let v = cost[p] - (p == c ? 0 : penalty)
                        if v > best { best = v; back[t][c] = p }
                    }
                    next[c] = best + emit[c]
                }
                cost = next
            }
            var path = [Int](repeating: 0, count: n)
            path[n - 1] = (0..<k).max { cost[$0] < cost[$1] }!
            for t in stride(from: n - 1, to: 0, by: -1) { path[t - 1] = back[t][path[t]] }
            if path == current { break }
            current = path
        }
        return current
    }

    // MARK: Segments

    struct Segment {
        var start: Double
        var end: Double
        var words: [Int]
    }

    /// Groups consecutive words, splitting at pauses and at roughly `maxSegmentDuration`.
    static func speechSegments(_ words: [Word]) -> [Segment] {
        let order = words.indices.sorted { words[$0].start < words[$1].start }
        var out: [Segment] = []
        for i in order {
            let w = words[i]
            let end = max(w.start, w.end)
            if var cur = out.last, w.start - cur.end <= maxSegmentGap, end - cur.start <= maxSegmentDuration {
                cur.end = max(cur.end, end)
                cur.words.append(i)
                out[out.count - 1] = cur
            } else {
                out.append(Segment(start: w.start, end: end, words: [i]))
            }
        }
        return out
    }

    // MARK: Clustering

    /// Per-dimension weights for [20 MFCC means, 20 MFCC stds, median F0, F0 spread].
    static let featureWeights: [Float] = Array(repeating: 1, count: FrameFeatures.mfccCount)
        + Array(repeating: 0.5, count: FrameFeatures.mfccCount) + [2, 0.5]

    /// Z-scores each dimension across segments, filling missing (NaN) values with the mean.
    static func standardized(_ vectors: [[Float]]) -> [[Float]] {
        guard let dims = vectors.first?.count else { return [] }
        var out = vectors
        for d in 0..<dims {
            let present = vectors.map { $0[d] }.filter { !$0.isNaN }
            let mean = present.isEmpty ? 0 : present.reduce(0, +) / Float(present.count)
            let variance = present.isEmpty ? 0 : present.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(present.count)
            let sd = variance.squareRoot()
            let weight = d < featureWeights.count ? featureWeights[d] : 1
            for i in out.indices {
                let x = out[i][d].isNaN ? mean : out[i][d]
                out[i][d] = sd > 1e-6 ? (x - mean) / sd * weight : 0
            }
        }
        return out
    }

    static func cosineDistances(_ vectors: [[Float]]) -> [Double] {
        let n = vectors.count
        let dims = vectors.first?.count ?? 0
        let norms = vectors.map { v in Double(vDSP.sumOfSquares(v)).squareRoot() }
        var dist = [Double](repeating: 0, count: n * n)
        for i in 0..<n {
            for j in (i + 1)..<max(i + 1, n) {
                var dot: Float = 0
                vDSP_dotpr(vectors[i], 1, vectors[j], 1, &dot, vDSP_Length(dims))
                let denom = norms[i] * norms[j]
                let d = denom > 1e-12 ? 1 - Double(dot) / denom : 1
                dist[i * n + j] = d
                dist[j * n + i] = d
            }
        }
        return dist
    }

    /// Cluster labels 0..<k for raw embeddings. The merge threshold proposes k; a split is kept
    /// only if its silhouette and absolute separation are large enough.
    static func clusterSpeakers(_ raw: [[Float]], maxSpeakers: Int) -> [Int] {
        let n = raw.count
        let dist = cosineDistances(standardized(raw))
        let merges = averageLinkage(dist, n: n)
        let kMax = min(maxSpeakers, n - 1)
        guard kMax >= 2 else { return [Int](repeating: 0, count: n) }

        let below = merges.filter { $0.distance <= mergeThreshold }.count
        let kThreshold = min(max(n - below, 1), kMax)
        var cuts: [Int: [Int]] = [:]
        var scores: [Int: Double] = [:]
        var valid: [Int] = []
        for k in 2...kMax {
            let labels = cut(merges, n: n, clusters: k)
            let score = silhouette(labels, dist: dist, n: n)
            cuts[k] = labels
            scores[k] = score
            if score >= minSilhouette, minSeparation(raw, labels: labels) >= minClusterSeparation { valid.append(k) }
        }
        guard let best = valid.max(by: { scores[$0]! < scores[$1]! }) else { return [Int](repeating: 0, count: n) }
        let k: Int
        if valid.contains(kThreshold), scores[kThreshold]! >= scores[best]! - 0.05 {
            k = kThreshold
        } else if kThreshold == 1, scores[best]! < confidentSilhouette {
            k = 1
        } else {
            k = best
        }
        return k == 1 ? [Int](repeating: 0, count: n) : cuts[k]!
    }

    struct Merge {
        var a: Int
        var b: Int
        var distance: Double
    }

    /// Average-linkage dendrogram by nearest-neighbour chain, merges sorted by distance.
    static func averageLinkage(_ dist: [Double], n: Int) -> [Merge] {
        var d = dist
        var size = [Double](repeating: 1, count: n)
        var active = [Bool](repeating: true, count: n)
        var remaining = n
        var chain: [Int] = []
        var merges: [Merge] = []
        merges.reserveCapacity(n - 1)
        while remaining > 1 {
            if chain.isEmpty { chain.append(active.firstIndex(of: true)!) }
            let a = chain[chain.count - 1]
            let prev = chain.count >= 2 ? chain[chain.count - 2] : -1
            var b = prev
            var bestD = prev >= 0 ? d[a * n + prev] : Double.infinity
            for k in 0..<n where active[k] && k != a && d[a * n + k] < bestD {
                bestD = d[a * n + k]
                b = k
            }
            if b == prev {
                chain.removeLast(2)
                merges.append(Merge(a: a, b: b, distance: bestD))
                let total = size[a] + size[b]
                for k in 0..<n where active[k] && k != a && k != b {
                    let v = (size[a] * d[a * n + k] + size[b] * d[b * n + k]) / total
                    d[a * n + k] = v
                    d[k * n + a] = v
                }
                size[a] = total
                active[b] = false
                remaining -= 1
            } else {
                chain.append(b)
            }
        }
        return merges.sorted { $0.distance < $1.distance }
    }

    /// Labels 0..<clusters (by first member) after applying the closest merges.
    static func cut(_ merges: [Merge], n: Int, clusters: Int) -> [Int] {
        var parent = Array(0..<n)
        func find(_ x: Int) -> Int {
            var x = x
            while parent[x] != x {
                parent[x] = parent[parent[x]]
                x = parent[x]
            }
            return x
        }
        for m in merges.prefix(max(0, n - clusters)) {
            parent[find(m.b)] = find(m.a)
        }
        var ids: [Int: Int] = [:]
        return (0..<n).map { i in
            let r = find(i)
            if let id = ids[r] { return id }
            ids[r] = ids.count
            return ids.count - 1
        }
    }

    /// Absolute floors on per-dimension spread, in feature units (log mel energy, semitones).
    static let featureFloors: [Float] = Array(repeating: 1, count: 2 * FrameFeatures.mfccCount) + [2, 1]

    /// Smallest weighted effect size between any two clusters of raw features, with spreads floored by `featureFloors`.
    static func minSeparation(_ raw: [[Float]], labels: [Int]) -> Double {
        guard let dims = raw.first?.count else { return 0 }
        let k = (labels.max() ?? 0) + 1
        var means = [[Double]](repeating: [Double](repeating: 0, count: dims), count: k)
        var counts = [Double](repeating: 0, count: k)
        var columnMeans = [Double](repeating: 0, count: dims)
        for d in 0..<dims {
            let present = raw.map { $0[d] }.filter { !$0.isNaN }
            columnMeans[d] = present.isEmpty ? 0 : Double(present.reduce(0, +)) / Double(present.count)
        }
        func value(_ i: Int, _ d: Int) -> Double { raw[i][d].isNaN ? columnMeans[d] : Double(raw[i][d]) }
        for i in raw.indices {
            counts[labels[i]] += 1
            for d in 0..<dims { means[labels[i]][d] += value(i, d) }
        }
        for c in 0..<k { for d in 0..<dims { means[c][d] /= max(counts[c], 1) } }
        var within = [Double](repeating: 0, count: dims)
        for i in raw.indices {
            for d in 0..<dims {
                let e = value(i, d) - means[labels[i]][d]
                within[d] += e * e
            }
        }
        for d in 0..<dims { within[d] /= Double(max(raw.count - k, 1)) }
        var best = Double.infinity
        for a in 0..<k {
            for b in (a + 1)..<max(a + 1, k) {
                var s = 0.0
                for d in 0..<dims {
                    let w = Double(d < featureWeights.count ? featureWeights[d] : 1)
                    let floor = Double(d < featureFloors.count ? featureFloors[d] : 0.5)
                    let delta = means[a][d] - means[b][d]
                    s += w * w * delta * delta / (within[d] + floor * floor)
                }
                best = min(best, s.squareRoot())
            }
        }
        return best
    }

    static func silhouette(_ labels: [Int], dist: [Double], n: Int) -> Double {
        let k = (labels.max() ?? 0) + 1
        guard k >= 2 else { return 0 }
        var counts = [Double](repeating: 0, count: k)
        for l in labels { counts[l] += 1 }
        var total = 0.0
        var sums = [Double](repeating: 0, count: k)
        for i in 0..<n {
            for c in 0..<k { sums[c] = 0 }
            for j in 0..<n where j != i { sums[labels[j]] += dist[i * n + j] }
            let own = labels[i]
            guard counts[own] > 1 else { continue }
            let a = sums[own] / (counts[own] - 1)
            var b = Double.infinity
            for c in 0..<k where c != own && counts[c] > 0 { b = min(b, sums[c] / counts[c]) }
            let m = max(a, b)
            if m > 0 { total += (b - a) / m }
        }
        return total / Double(n)
    }

    // MARK: Emphasis

    /// 0…1 stress per word from loudness, lengthening and pitch rise relative to context.
    static func emphasisScores(words: [Word], features: FrameFeatures) -> [Float] {
        let n = words.count
        guard n > 0 else { return [] }
        let window = 3.0
        let mids = words.map { ($0.start + $0.end) / 2 }
        let order = words.indices.sorted { mids[$0] < mids[$1] }
        let sortedMids = order.map { mids[$0] }
        let fillers = words.map(\.isFiller)

        var peaks = [Float](repeating: .nan, count: n)
        var pitchPeaks = [Float](repeating: .nan, count: n)
        for (i, w) in words.enumerated() {
            let r = features.frames(start: w.start, end: w.end)
            guard !r.isEmpty else { continue }
            peaks[i] = features.db[r].max()!
            let voiced = features.f0[r].filter { !$0.isNaN }
            if let m = voiced.max() { pitchPeaks[i] = m }
        }

        let chars = words.map { max(1, $0.normalized.count) }
        let durations = words.map { max(0.01, $0.end - $0.start) }
        let content = (0..<n).filter { !fillers[$0] }
        let perChar = median(content.map { Float(durations[$0] / Double(chars[$0])) }) ?? 0.06
        var byLength: [Int: [Float]] = [:]
        for i in content { byLength[min(chars[i], 15), default: []].append(Float(durations[i])) }
        let expected: [Double] = (0..<n).map { i in
            if let group = byLength[min(chars[i], 15)], group.count >= 3, let m = median(group) { return Double(m) }
            return Double(perChar) * Double(chars[i])
        }
        let logRatios = (0..<n).map { log(durations[$0] / max(expected[$0], 0.01)) }
        let contentRatios = content.map { logRatios[$0] }
        let ratioMean = contentRatios.isEmpty ? 0 : contentRatios.reduce(0, +) / Double(contentRatios.count)
        let ratioSD = contentRatios.isEmpty ? 0 : (contentRatios.reduce(0) { $0 + ($1 - ratioMean) * ($1 - ratioMean) } / Double(contentRatios.count)).squareRoot()

        func clampZ(_ z: Double) -> Double { min(max(z, -3), 3) }
        func lowerBound(_ t: Double) -> Int {
            var lo = 0, hi = sortedMids.count
            while lo < hi {
                let m = (lo + hi) / 2
                if sortedMids[m] < t { lo = m + 1 } else { hi = m }
            }
            return lo
        }

        var out = [Float](repeating: 0, count: n)
        for i in 0..<n where !fillers[i] {
            let lo = lowerBound(mids[i] - window)
            let hi = lowerBound(mids[i] + window + 1e-9)
            var neighbours: [Float] = []
            for k in lo..<hi {
                let j = order[k]
                if j != i, !fillers[j], !peaks[j].isNaN { neighbours.append(peaks[j]) }
            }
            var zLoud = 0.0
            if !peaks[i].isNaN, !neighbours.isEmpty {
                let mean = Double(neighbours.reduce(0, +)) / Double(neighbours.count)
                let sd = (neighbours.reduce(0.0) { $0 + (Double($1) - mean) * (Double($1) - mean) } / Double(neighbours.count)).squareRoot()
                zLoud = clampZ((Double(peaks[i]) - mean) / max(sd, 3))
            }
            let zDur = clampZ((logRatios[i] - ratioMean) / max(ratioSD, 0.15))
            var zPitch = 0.0
            if !pitchPeaks[i].isNaN {
                let local = features.f0[features.frames(start: mids[i] - window, end: mids[i] + window)].filter { !$0.isNaN }
                if let m = median(local) { zPitch = clampZ(Double(pitchPeaks[i] - m) / 3) }
            }
            let c = 0.5 * zLoud + 0.3 * zDur + 0.2 * zPitch
            out[i] = Float(1 / (1 + exp(-(1.2 * c - 0.8))))
        }
        return out
    }

    static func median(_ xs: [Float]) -> Float? {
        guard !xs.isEmpty else { return nil }
        let s = xs.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    static func percentile(_ sorted: [Float], _ p: Double) -> Float {
        sorted[min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * p).rounded())))]
    }

    // MARK: Decoding

    static func decodeMono(url: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw EditError("\(url.lastPathComponent) has no audio")
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
            AVSampleRateKey: decodeRate,
            AVNumberOfChannelsKey: 1,
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? EditError("Cannot read audio of \(url.lastPathComponent)") }
        var samples: [Float] = []
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            var length = 0
            var ptr: UnsafeMutablePointer<CChar>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &ptr) == noErr, let ptr else { continue }
            let n = length / MemoryLayout<Float>.size
            ptr.withMemoryRebound(to: Float.self, capacity: n) { samples.append(contentsOf: UnsafeBufferPointer(start: $0, count: n)) }
        }
        if reader.status == .failed { throw reader.error ?? EditError("Audio decode failed for \(url.lastPathComponent)") }
        return samples
    }
}

/// Per-frame level, MFCCs and pitch at a 10 ms hop.
struct FrameFeatures {
    static let mfccCount = 20
    static let melBands = 40
    static let minF0 = 65.0
    static let maxF0 = 400.0

    let sampleRate: Double
    let hop: Int
    let frameLength: Int
    let count: Int
    /// Frame energy in dBFS.
    var db: [Float]
    /// Row-major `count × mfccCount`, excluding c0.
    var mfcc: [Float]
    /// Semitones re 100 Hz; NaN when unvoiced.
    var f0: [Float]
    /// Frames quieter than this are treated as non-speech.
    var speechFloor: Float

    init(samples: [Float], sampleRate: Double) {
        self.sampleRate = sampleRate
        hop = max(1, Int((sampleRate * 0.010).rounded()))
        frameLength = max(32, Int((sampleRate * 0.025).rounded()))
        count = samples.count >= frameLength ? (samples.count - frameLength) / hop + 1 : 0
        db = [Float](repeating: -100, count: count)
        mfcc = [Float](repeating: 0, count: count * Self.mfccCount)
        f0 = [Float](repeating: .nan, count: count)
        speechFloor = -60
        guard count > 0 else { return }

        samples.withUnsafeBufferPointer { x in
            for i in 0..<count {
                var ms: Float = 0
                vDSP_measqv(x.baseAddress! + i * hop, 1, &ms, vDSP_Length(frameLength))
                db[i] = max(-100, 10 * log10(max(ms, 1e-10)))
            }
        }
        let loud = db.filter { $0 > -70 }.sorted()
        if !loud.isEmpty { speechFloor = max(-60, Diarizer.percentile(loud, 0.95) - 35) }

        computeMFCC(samples)
        computePitch(samples)
    }

    /// Frames whose centre lies in `start...end`.
    func frames(start: Double, end: Double) -> Range<Int> {
        let half = Double(frameLength) / 2
        let lo = Int(((start * sampleRate - half) / Double(hop)).rounded(.up))
        let hi = Int(((end * sampleRate - half) / Double(hop)).rounded(.down))
        let a = min(max(lo, 0), count)
        let b = min(max(hi + 1, a), count)
        return a..<b
    }

    /// MFCC mean and std over speech frames plus median F0 and its interquartile spread (NaN if unvoiced).
    func embedding(start: Double, end: Double) -> [Float]? {
        let r = frames(start: start, end: end)
        guard !r.isEmpty, let peak = db[r].max() else { return nil }
        let gate = max(peak - 30, speechFloor)
        let speech = r.filter { db[$0] > gate }
        guard speech.count >= 20 else { return nil }
        let m = Self.mfccCount
        var mean = [Float](repeating: 0, count: m)
        var sq = [Float](repeating: 0, count: m)
        mfcc.withUnsafeBufferPointer { c in
            for f in speech {
                let row = UnsafeBufferPointer(rebasing: c[(f * m)..<(f * m + m)])
                vDSP.add(mean, row, result: &mean)
                vDSP.add(sq, vDSP.square(row), result: &sq)
            }
        }
        let n = Float(speech.count)
        mean = vDSP.divide(mean, n)
        let std = (0..<m).map { max(0, sq[$0] / n - mean[$0] * mean[$0]).squareRoot() }
        let pitches = speech.compactMap { f0[$0].isNaN ? nil : f0[$0] }.sorted()
        var pitch: [Float] = [.nan, .nan]
        if pitches.count >= 5 {
            pitch = [Diarizer.percentile(pitches, 0.5), Diarizer.percentile(pitches, 0.75) - Diarizer.percentile(pitches, 0.25)]
        }
        return mean + std + pitch
    }

    /// MFCC mean over a word's speech frames plus its median F0 (NaN if unvoiced).
    func wordVector(start: Double, end: Double) -> [Float]? {
        let speech = frames(start: start, end: end).filter { db[$0] > speechFloor }
        guard speech.count >= 5 else { return nil }
        let m = Self.mfccCount
        var mean = [Float](repeating: 0, count: m)
        for f in speech { for k in 0..<m { mean[k] += mfcc[f * m + k] } }
        let pitches = speech.compactMap { f0[$0].isNaN ? nil : f0[$0] }
        return mean.map { $0 / Float(speech.count) } + [Diarizer.median(pitches) ?? .nan]
    }

    private mutating func computeMFCC(_ samples: [Float]) {
        let n = frameLength
        let log2n = vDSP_Length(ceil(log2(Double(n))))
        let fftN = 1 << Int(log2n)
        let bins = fftN / 2 + 1
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return }
        defer { vDSP_destroy_fftsetup(setup) }

        var emphasized = samples
        for i in stride(from: samples.count - 1, to: 0, by: -1) { emphasized[i] -= 0.97 * samples[i - 1] }
        var window = [Float](repeating: 0, count: n)
        vDSP_hamm_window(&window, vDSP_Length(n), 0)
        let mel = Self.melFilterbank(bins: bins, fftN: fftN, sampleRate: sampleRate)
        let dct = Self.dctMatrix()

        var frame = [Float](repeating: 0, count: fftN)
        var re = [Float](repeating: 0, count: fftN / 2)
        var im = [Float](repeating: 0, count: fftN / 2)
        var power = [Float](repeating: 0, count: bins)
        var bands = [Float](repeating: 0, count: Self.melBands)
        var coeffs = [Float](repeating: 0, count: Self.mfccCount)
        var floor: Float = 1e-10
        var bandCount = Int32(Self.melBands)

        for i in 0..<count {
            emphasized.withUnsafeBufferPointer { x in
                vDSP_vmul(x.baseAddress! + i * hop, 1, window, 1, &frame, 1, vDSP_Length(n))
            }
            re.withUnsafeMutableBufferPointer { rp in
                im.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    frame.withUnsafeBytes { raw in
                        vDSP_ctoz(raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(fftN / 2))
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
                    power.withUnsafeMutableBufferPointer { p in
                        vDSP_zvmags(&split, 1, p.baseAddress!, 1, vDSP_Length(fftN / 2))
                        p[0] = rp[0] * rp[0]
                        p[bins - 1] = ip[0] * ip[0]
                    }
                }
            }
            vDSP_mmul(mel, 1, power, 1, &bands, 1, vDSP_Length(Self.melBands), 1, vDSP_Length(bins))
            vDSP_vthr(bands, 1, &floor, &bands, 1, vDSP_Length(Self.melBands))
            vvlogf(&bands, bands, &bandCount)
            vDSP_mmul(dct, 1, bands, 1, &coeffs, 1, vDSP_Length(Self.mfccCount), 1, vDSP_Length(Self.melBands))
            for k in 0..<Self.mfccCount { mfcc[i * Self.mfccCount + k] = coeffs[k] }
        }
    }

    private mutating func computePitch(_ samples: [Float]) {
        let minLag = max(2, Int((sampleRate / Self.maxF0).rounded(.down)))
        let maxLag = Int((sampleRate / Self.minF0).rounded(.up))
        let len = Int(sampleRate * 0.048)
        let log2n = vDSP_Length(ceil(log2(Double(len + maxLag + 2))))
        let fftN = 1 << Int(log2n)
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return }
        defer { vDSP_destroy_fftsetup(setup) }

        var window = [Float](repeating: 0, count: len)
        vDSP_hann_window(&window, vDSP_Length(len), Int32(vDSP_HANN_NORM))
        var windowCorr = [Float](repeating: 0, count: maxLag + 2)
        for lag in 0..<(maxLag + 2) {
            var s: Float = 0
            vDSP_dotpr(window, 1, Array(window[lag...]), 1, &s, vDSP_Length(len - lag))
            windowCorr[lag] = s
        }
        windowCorr = vDSP.divide(windowCorr, windowCorr[0])

        var frame = [Float](repeating: 0, count: fftN)
        var corr = [Float](repeating: 0, count: fftN)
        var re = [Float](repeating: 0, count: fftN / 2)
        var im = [Float](repeating: 0, count: fftN / 2)
        let octaveCost: Float = 0.03

        for i in 0..<count where db[i] > speechFloor {
            let centre = i * hop + frameLength / 2
            let first = centre - len / 2
            for k in 0..<fftN { frame[k] = 0 }
            let lo = max(0, first)
            let hi = min(samples.count, first + len)
            guard hi - lo > len / 2 else { continue }
            var mean: Float = 0
            samples.withUnsafeBufferPointer { x in
                vDSP_meanv(x.baseAddress! + lo, 1, &mean, vDSP_Length(hi - lo))
                for k in lo..<hi { frame[k - first] = (x[k] - mean) * window[k - first] }
            }
            re.withUnsafeMutableBufferPointer { rp in
                im.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    frame.withUnsafeBytes { raw in
                        vDSP_ctoz(raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(fftN / 2))
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
                    let dc = rp[0] * rp[0]
                    let nyquist = ip[0] * ip[0]
                    for k in 0..<(fftN / 2) {
                        rp[k] = rp[k] * rp[k] + ip[k] * ip[k]
                        ip[k] = 0
                    }
                    rp[0] = dc
                    ip[0] = nyquist
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Inverse))
                    corr.withUnsafeMutableBytes { raw in
                        vDSP_ztoc(&split, 1, raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, vDSP_Length(fftN / 2))
                    }
                }
            }
            let r0 = corr[0]
            guard r0 > 1e-12 else { continue }
            func value(_ lag: Int) -> Float { min(corr[lag] / r0 / max(windowCorr[lag], 1e-3), 1.1) }
            var bestLag = -1
            var bestScore = -Float.infinity
            var bestValue: Float = 0
            for lag in minLag...maxLag {
                let v = value(lag)
                guard v >= value(lag - 1), v >= value(lag + 1) else { continue }
                let score = v - octaveCost * log2(Float(lag) / Float(minLag))
                if score > bestScore { bestScore = score; bestLag = lag; bestValue = v }
            }
            guard bestLag > 0, bestValue > 0.45 else { continue }
            let a = value(bestLag - 1), b = bestValue, c = value(bestLag + 1)
            let denom = a - 2 * b + c
            let shift = abs(denom) > 1e-9 ? min(max(0.5 * (a - c) / denom, -0.5), 0.5) : 0
            let hz = sampleRate / (Double(bestLag) + Double(shift))
            f0[i] = Float(12 * log2(hz / 100))
        }
    }

    /// Row-major `melBands × bins` triangular filters spanning 20 Hz to min(8 kHz, Nyquist).
    static func melFilterbank(bins: Int, fftN: Int, sampleRate: Double) -> [Float] {
        func mel(_ f: Double) -> Double { 2595 * log10(1 + f / 700) }
        func hz(_ m: Double) -> Double { 700 * (pow(10, m / 2595) - 1) }
        let lo = mel(20), hi = mel(min(8000, sampleRate / 2))
        let edges = (0..<(melBands + 2)).map { hz(lo + (hi - lo) * Double($0) / Double(melBands + 1)) }
        var out = [Float](repeating: 0, count: melBands * bins)
        for b in 0..<melBands {
            let (l, c, r) = (edges[b], edges[b + 1], edges[b + 2])
            for k in 0..<bins {
                let f = Double(k) * sampleRate / Double(fftN)
                let w = f <= c ? (f - l) / (c - l) : (r - f) / (r - c)
                if w > 0 { out[b * bins + k] = Float(w) }
            }
        }
        return out
    }

    /// Row-major `mfccCount × melBands` orthonormal DCT-II rows 1…mfccCount.
    static func dctMatrix() -> [Float] {
        let m = Double(melBands)
        var out = [Float](repeating: 0, count: mfccCount * melBands)
        for k in 0..<mfccCount {
            for j in 0..<melBands {
                out[k * melBands + j] = Float((2 / m).squareRoot() * cos(Double.pi * Double(k + 1) * (Double(j) + 0.5) / m))
            }
        }
        return out
    }
}
