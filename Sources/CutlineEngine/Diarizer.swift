import Accelerate
import AVFoundation
import CutlineCore
import Foundation

/// Speaker diarization and word emphasis from audio plus a word-level transcript.
///
/// Turns change only between sentences, or at a pause of at least `turnPause` inside one when the voices differ
/// clearly; unpunctuated transcripts fall back to word-level turns that change most cheaply at pauses.
public enum Diarizer {
    static let decodeRate = 16_000.0
    static let maxSegmentGap = 0.3
    static let maxSegmentDuration = 2.0

    /// Decodes the first audio track to 16 kHz mono and analyzes it. With `faces` (active-speaker analysis of the same
    /// media) and their `faceTracks`, two faces on screen together are never one speaker and turns by the same talking
    /// face (the same person, when tracks carry `person`) join more readily. With `enrollment`, pinned words keep their
    /// speaker and name the rest of their voice.
    public static func analyze(url: URL, transcript: Transcript, faces: ActiveSpeakers? = nil, faceTracks: [FaceTrack] = [], enrollment: Enrollment? = nil) async throws -> SpeakerAnalysis {
        let samples = try await decodeMono(url: url)
        return analyze(samples: samples, sampleRate: decodeRate, transcript: transcript, faces: faces, faceTracks: faceTracks, enrollment: enrollment)
    }

    /// Labels speakers and scores emphasis for `transcript` over mono `samples`.
    public static func analyze(samples: [Float], sampleRate: Double, transcript: Transcript, maxSpeakers: Int = 6, faces: ActiveSpeakers? = nil, faceTracks: [FaceTrack] = [], enrollment: Enrollment? = nil) -> SpeakerAnalysis {
        let words = transcript.words
        let features = FrameFeatures(samples: samples, sampleRate: sampleRate)
        let emphasis = emphasisScores(words: words, features: features)
        let order = words.indices.sorted { words[$0].start < words[$1].start }
        guard !order.isEmpty, features.count > 0 else {
            return SpeakerAnalysis(mediaId: transcript.mediaId, speakers: [], segments: [], wordSpeakers: words.map { _ in nil }, emphasis: emphasis)
        }
        let v = VoiceFrames(features)
        let bySentence = isPunctuated(words)
        var units = bySentence ? sentenceUnits(words, order: order) : order.map { Segment(start: words[$0].start, end: max(words[$0].start, words[$0].end), words: [$0]) }
        if let pinned = enrollment?.pinned, pinned.contains(where: { $0 != nil }) { units = splitAtPins(units, pinned, words: words) }
        let costs = units.indices.map { u -> Double in
            guard u > 0 else { return 0 }
            let a = words[units[u - 1].words.last!], b = words[units[u].words[0]]
            return bySentence ? unitSwitchCost(a, b) : switchCost(a, b)
        }
        let wordFrames = units.map { $0.words.map { v.frames(words[$0]) } }
        let unitFrames = wordFrames.map { $0.flatMap { $0 } }
        let (faceOf, cannot) = faceLinks(faces, tracks: faceTracks, units: units)

        // Seeds for clustering: each sentence, or short runs of words when there are no sentences.
        var seedUnits: [[Int]]
        if bySentence {
            seedUnits = units.indices.map { [$0] }
        } else {
            var unitOfWord: [Int: Int] = [:]
            for (u, unit) in units.enumerated() { unitOfWord[unit.words[0]] = u }
            seedUnits = speechSegments(words).map { $0.words.compactMap { unitOfWord[$0] } }
        }
        seedUnits = seedUnits.filter { $0.reduce(0) { $0 + unitFrames[$1].count } >= minSeedFrames }

        var labels = [Int](repeating: 0, count: units.count)
        if seedUnits.count >= 2 {
            var seedCannot = Set<Pair>()
            if !cannot.isEmpty {
                for i in seedUnits.indices {
                    for j in (i + 1)..<seedUnits.count where seedUnits[i].contains(where: { a in seedUnits[j].contains { cannot.contains(Pair(a, $0)) } }) {
                        seedCannot.insert(Pair(i, j))
                    }
                }
            }
            let seedLabels = bicClusters(seedUnits.map { v.stats($0.flatMap { unitFrames[$0] }) }, maxSpeakers: max(1, maxSpeakers), cannot: seedCannot)
            var known = [Int?](repeating: nil, count: units.count)
            for (s, us) in seedUnits.enumerated() { for u in us { known[u] = seedLabels[s] } }
            let seeded = units.indices.filter { known[$0] != nil }
            for u in units.indices {
                if let l = known[u] { labels[u] = l; continue }
                let nearest = seeded.min { abs(units[$0].start - units[u].start) < abs(units[$1].start - units[u].start) }!
                labels[u] = known[nearest]!
            }
            if Set(labels).count > 1 {
                labels = resegment(unitFrames, costs: costs, labels: labels, v: v)
                let merged = mergeSimilarSpeakers(wordFrames, labels: labels, v: v, cannot: cannot, faceOf: faceOf)
                if merged != labels {
                    labels = Set(merged).count > 1 ? resegment(unitFrames, costs: costs, labels: merged, v: v) : merged
                }
            }
            let split = splitMixedScenes(labels, units: units, wordFrames: wordFrames, unitFrames: unitFrames, v: v, cannot: cannot, faceOf: faceOf)
            if split.labels != labels {
                labels = resegment(unitFrames, costs: costs, labels: split.labels, v: v)
                let apart = cannot.union(split.apart)
                let merged = mergeSimilarSpeakers(wordFrames, labels: labels, v: v, cannot: apart, faceOf: faceOf)
                if merged != labels {
                    labels = Set(merged).count > 1 ? resegment(unitFrames, costs: costs, labels: merged, v: v) : merged
                }
                labels = capSpeakers(labels, max: max(1, maxSpeakers), unitFrames: unitFrames, v: v, cannot: apart)
            }
        }
        let scene = scenes(units)
        labels = renumber(labels)
        let named = enrollment.map { enroll($0, labels: labels, units: units, scene: scene, unitFrames: unitFrames, v: v) } ?? units.map { _ in UnitIdentity() }
        let links = sceneIdentity(labels, scene: scene, unitFrames: unitFrames, v: v)

        // Display names: enrolled names, else S1, S2… for the remaining voices in order of first appearance.
        var numbers: [Int: Int] = [:]
        let display = units.indices.map { u -> String in
            if let n = named[u].name { return n }
            if numbers[labels[u]] == nil { numbers[labels[u]] = numbers.count + 1 }
            return "S\(numbers[labels[u]]!)"
        }
        var speakers: [String] = []
        for n in display where !speakers.contains(n) { speakers.append(n) }
        let ids = display.map { speakers.firstIndex(of: $0)! }
        // Voice confidence is against the voice clusters, whatever names they were given.
        var voiceStats = [GaussStats](repeating: GaussStats(dims: v.dims), count: (labels.max() ?? 0) + 1)
        for (u, fr) in unitFrames.enumerated() { voiceStats[labels[u]] = voiceStats[labels[u]] + v.stats(fr) }
        var segments: [SpeakerSegment] = []
        var wordSpeakers = [String?](repeating: nil, count: words.count)
        var u = 0
        while u < units.count {
            var e = u
            while e + 1 < units.count, ids[e + 1] == ids[u] { e += 1 }
            let name = display[u]
            let turnWords = units[u...e].flatMap(\.words)
            for i in turnWords { wordSpeakers[i] = name }
            var weight: [Int: Int] = [:]
            for k in u...e { weight[labels[k], default: 0] += unitFrames[k].count }
            let voice = weight.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }!.key
            let confidence = turnConfidence((u...e).filter { labels[$0] == voice }.flatMap { unitFrames[$0] }, label: voice, stats: voiceStats, v: v)
            let vias = Set((u...e).map { named[$0].via ?? "" })
            let via = vias.count == 1 ? vias.first.flatMap { $0.isEmpty ? nil : $0 } : nil
            let identity: Double? = via == "pinned" || via == "enrolled" ? 1 : (u...e).compactMap { links[scene[$0]]?[labels[$0]] }.min()
            let start = words[turnWords[0]].start
            let end = turnWords.map { max(words[$0].start, words[$0].end) }.max()!
            if let last = segments.last, last.end > start { segments[segments.count - 1].end = start }
            segments.append(SpeakerSegment(start: start, end: end, speaker: name, confidence: (confidence * 100).rounded() / 100, identity: identity.map { ($0 * 100).rounded() / 100 }, via: via))
            u = e + 1
        }
        let pins = enrollment.flatMap { e -> [SpeakerPin]? in
            var out: [SpeakerPin] = []
            for (i, n) in e.pinned.enumerated() {
                guard let n else { continue }
                if let last = out.last, last.to == i - 1, last.speaker == n { out[out.count - 1].to = i } else { out.append(SpeakerPin(from: i, to: i, speaker: n)) }
            }
            return out.isEmpty ? nil : out
        }
        return SpeakerAnalysis(mediaId: transcript.mediaId, speakers: speakers, segments: segments, wordSpeakers: wordSpeakers, emphasis: emphasis, pins: pins)
    }

    // MARK: Segments

    struct Segment {
        var start: Double
        var end: Double
        var words: [Int]
    }

    /// `units` split wherever the pinned speaker changes between neighbouring words.
    static func splitAtPins(_ units: [Segment], _ pinned: [String?], words: [Word]) -> [Segment] {
        func pin(_ i: Int) -> String? { pinned.indices.contains(i) ? pinned[i] : nil }
        var out: [Segment] = []
        for unit in units {
            var cur: [Int] = []
            for w in unit.words {
                if let last = cur.last, pin(last) != pin(w) {
                    out.append(Segment(start: words[cur[0]].start, end: cur.map { max(words[$0].start, words[$0].end) }.max()!, words: cur))
                    cur = []
                }
                cur.append(w)
            }
            out.append(Segment(start: words[cur[0]].start, end: cur.map { max(words[$0].start, words[$0].end) }.max()!, words: cur))
        }
        return out
    }

    /// Whether the transcript marks sentence ends often enough to trust them as the only places turns change.
    static func isPunctuated(_ words: [Word]) -> Bool {
        words.filter { endsSentence($0.text) }.count * 40 >= words.count
    }

    /// Sentences, split further at pauses of at least `turnPause`.
    static func sentenceUnits(_ words: [Word], order: [Int]) -> [Segment] {
        var out: [Segment] = []
        for i in order {
            let w = words[i]
            let end = max(w.start, w.end)
            if var cur = out.last, !endsSentence(words[cur.words.last!].text), w.start - cur.end < turnPause {
                cur.end = max(cur.end, end)
                cur.words.append(i)
                out[out.count - 1] = cur
            } else {
                out.append(Segment(start: w.start, end: end, words: [i]))
            }
        }
        return out
    }

    /// Groups consecutive words, splitting at pauses, sentence ends, short breaks and at roughly `maxSegmentDuration`,
    /// so a segment rarely holds two people's lines.
    static func speechSegments(_ words: [Word]) -> [Segment] {
        let order = words.indices.sorted { words[$0].start < words[$1].start }
        var out: [Segment] = []
        for i in order {
            let w = words[i]
            let end = max(w.start, w.end)
            if var cur = out.last, w.start - cur.end <= segmentBreak, !endsSentence(words[cur.words.last!].text), end - cur.start <= maxSegmentDuration {
                cur.end = max(cur.end, end)
                cur.words.append(i)
                out[out.count - 1] = cur
            } else {
                out.append(Segment(start: w.start, end: end, words: [i]))
            }
        }
        return out
    }

    /// The face confidently talking in each unit, and pairs of units whose talking faces were on screen together
    /// (so two people). Tracks of one person (`FaceTrack.person`) count as one face, numbered below zero apart from
    /// track ids.
    static func faceLinks(_ faces: ActiveSpeakers?, tracks: [FaceTrack], units: [Segment]) -> (faceOf: [Int?], cannot: Set<Pair>) {
        guard let faces, !faces.spans.isEmpty else { return ([], []) }
        let trackOf: [Int?] = units.map { unit in
            var best: (overlap: Double, span: ActiveSpeakers.Span)?
            for s in faces.spans {
                let o = min(s.end, unit.end) - max(s.start, unit.start)
                if o > 0, o > (best?.overlap ?? 0) { best = (o, s) }
            }
            guard let best, best.overlap >= 0.5 * (unit.end - unit.start), best.span.isConfident else { return nil }
            return best.span.face
        }
        let person = Dictionary(tracks.compactMap { t in t.person.map { (t.id, -1 - $0) } }, uniquingKeysWith: { a, _ in a })
        let faceOf = trackOf.map { $0.map { person[$0] ?? $0 } }
        let ranges = Dictionary(tracks.map { ($0.id, ($0.start, $0.end)) }, uniquingKeysWith: { a, _ in a })
        var cannot = Set<Pair>()
        let talking = units.indices.filter { trackOf[$0] != nil }
        for (i, a) in talking.enumerated() {
            for b in talking[(i + 1)...] {
                guard faceOf[a] != faceOf[b], let ra = ranges[trackOf[a]!], let rb = ranges[trackOf[b]!] else { continue }
                if min(ra.1, rb.1) - max(ra.0, rb.0) > 0.5 { cannot.insert(Pair(a, b)) }
            }
        }
        return (faceOf, cannot)
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

    /// The first audio track as mono at `decodeRate`. Decodes at the track's own rate and resamples here, since
    /// AVFoundation's rate converter dithers and would make every analysis of the same file slightly different.
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
            AVNumberOfChannelsKey: 1,
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? EditError("Cannot read audio of \(url.lastPathComponent)") }
        let samples = try await runBlocking { _ -> [Float] in
            var resampler: Resampler?
            var samples: [Float] = []
            while let buffer = output.nextSample() {
                guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
                if resampler == nil {
                    let rate = CMSampleBufferGetFormatDescription(buffer).flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mSampleRate } ?? decodeRate
                    resampler = Resampler(from: rate > 0 ? rate : decodeRate, to: decodeRate)
                }
                var length = 0
                var ptr: UnsafeMutablePointer<CChar>?
                guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &ptr) == noErr, let ptr else { continue }
                let n = length / MemoryLayout<Float>.size
                ptr.withMemoryRebound(to: Float.self, capacity: n) { resampler!.push(UnsafeBufferPointer(start: $0, count: n), into: &samples) }
            }
            if reader.status == .failed { throw reader.error ?? EditError("Audio decode failed for \(url.lastPathComponent)") }
            resampler?.finish(into: &samples)
            return samples
        }
        return samples
    }
}

/// Windowed-sinc sample-rate conversion, the same for any split of the input into chunks.
struct Resampler {
    static let phases = 512
    let step: Double
    let half: Int
    let kernels: [Float]
    let passthrough: Bool
    private var buffer: [Float]
    /// Input index of `buffer[0]`.
    private var offset: Int
    private var produced = 0
    private var received = 0

    init(from inRate: Double, to outRate: Double) {
        step = inRate / outRate
        passthrough = abs(inRate - outRate) < 1e-6
        let fc = 0.45 * min(1, outRate / inRate)
        half = passthrough ? 1 : Int((6 / fc).rounded(.up))
        let taps = 2 * half
        var k = [Float](repeating: 0, count: (Self.phases + 1) * taps)
        for p in 0...Self.phases {
            let frac = Double(p) / Double(Self.phases)
            var row = [Double](repeating: 0, count: taps)
            for i in 0..<taps {
                let x = Double(i - half + 1) - frac
                let w = abs(x) >= Double(half) ? 0 : 0.42 + 0.5 * cos(.pi * x / Double(half)) + 0.08 * cos(2 * .pi * x / Double(half))
                let arg = 2 * fc * x
                row[i] = w * (abs(arg) < 1e-12 ? 1 : sin(.pi * arg) / (.pi * arg))
            }
            let sum = row.reduce(0, +)
            for i in 0..<taps { k[p * taps + i] = Float(row[i] / sum) }
        }
        kernels = k
        buffer = [Float](repeating: 0, count: half)
        offset = -half
    }

    mutating func push(_ x: UnsafeBufferPointer<Float>, into out: inout [Float]) {
        received += x.count
        if passthrough { out.append(contentsOf: x); return }
        buffer.append(contentsOf: x)
        drain(into: &out, final: false)
    }

    mutating func finish(into out: inout [Float]) {
        guard !passthrough else { return }
        buffer.append(contentsOf: [Float](repeating: 0, count: half))
        drain(into: &out, final: true)
    }

    private mutating func drain(into out: inout [Float], final: Bool) {
        let taps = 2 * half
        let total = Int((Double(received) / step).rounded(.down))
        buffer.withUnsafeBufferPointer { b in
            kernels.withUnsafeBufferPointer { k in
                while true {
                    if final && produced >= total { break }
                    let t = Double(produced) * step
                    var base = Int(t.rounded(.down))
                    var p = Int(((t - Double(base)) * Double(Self.phases)).rounded())
                    if p == Self.phases { base += 1; p = 0 }
                    let first = base - half + 1 - offset
                    guard first + taps <= b.count else { break }
                    var v: Float = 0
                    vDSP_dotpr(b.baseAddress! + first, 1, k.baseAddress! + p * taps, 1, &v, vDSP_Length(taps))
                    out.append(v)
                    produced += 1
                }
            }
        }
        let keep = Int((Double(produced) * step).rounded(.down)) - half + 1 - offset
        if keep > 0 {
            let drop = min(keep, buffer.count)
            buffer.removeFirst(drop)
            offset += drop
        }
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
