import Accelerate
import AVFoundation
import CutlineCore
import Foundation

/// Speaker diarization and word emphasis from audio plus a word-level transcript.
public enum Diarizer {
    static let decodeRate = 16_000.0
    static let maxSegmentGap = 0.3
    static let maxSegmentDuration = 2.0

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
        var seeds: [GaussStats] = []
        for (i, s) in segments.enumerated() {
            let frames = segmentFrames(features, s, words)
            guard frames.count >= minSeedFrames else { continue }
            embedded.append(i)
            seeds.append(stats(features, frames: frames))
        }

        var clusterOf = [Int](repeating: 0, count: segments.count)
        if embedded.count >= 2 {
            let labels = bicClusters(seeds, maxSpeakers: max(1, maxSpeakers))
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
            wordCluster = resegmentFrames(words: words, order: order, labels: wordCluster, features: features)
            let merged = mergeSimilarSpeakers(words: words, order: order, labels: wordCluster, features: features)
            if merged != wordCluster {
                wordCluster = Set(merged).count > 1 ? resegmentFrames(words: words, order: order, labels: merged, features: features) : merged
            }
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

    // MARK: Segments

    struct Segment {
        var start: Double
        var end: Double
        var words: [Int]
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
