import Accelerate
import CutlineCore
import Foundation

/// A short sound that stands out of its surroundings, as `AudioDSP.repairCandidates` finds it.
public struct RepairCandidate: Equatable, Sendable {
    public enum Kind: String, Sendable {
        /// A broadband tick or pop under 25 ms.
        case click
        /// A low-frequency thump: mic bump, handling noise, plosive pop.
        case thump
        /// A steady narrow tone: beep, phone ring, whistle.
        case tone
    }

    public var kind: Kind
    /// Seconds in the analyzed buffer.
    public var start: Double
    public var end: Double
    /// Band to repair, Hz; 0 high means up to the top.
    public var low: Double
    public var high: Double
    /// dB above the surrounding sound.
    public var strength: Double
}

/// Dialogue tools: leveling, match EQ, de-reverb, spectral repair and the measurements they rest on.
extension AudioDSP {
    /// A timeline's stereo mix at the stem rate (48 kHz), over `range` or all of it.
    public static func mix(of built: BuiltTimeline, range: TimeRange? = nil) async throws -> [[Float]] {
        var l: [Float] = [], r: [Float] = []
        try await AudioIO.read(built, range: range) { s, n in
            l.reserveCapacity(l.count + n)
            r.reserveCapacity(r.count + n)
            for i in 0..<n {
                l.append(s[2 * i])
                r.append(s[2 * i + 1])
            }
        }
        return [l, r]
    }

    // MARK: - Loudness

    /// BS.1770 K-weighting as two biquads `[b0, b1, b2, a1, a2]` for any sample rate.
    static func kWeighting(_ sr: Double) -> [[Double]] {
        var k = tan(.pi * 1681.974450955533 / sr)
        var q = 0.7071752369554196
        let vh = pow(10, 3.999843853973347 / 20), vb = pow(vh, 0.4996667741545416)
        var a0 = 1 + k / q + k * k
        let shelf = [(vh + vb * k / q + k * k) / a0, 2 * (k * k - vh) / a0, (vh - vb * k / q + k * k) / a0, 2 * (k * k - 1) / a0, (1 - k / q + k * k) / a0]
        k = tan(.pi * 38.13547087602444 / sr)
        q = 0.5003270373238773
        a0 = 1 + k / q + k * k
        return [shelf, [1, -2, 1, 2 * (k * k - 1) / a0, (1 - k / q + k * k) / a0]]
    }

    /// K-weighted mean power of each `hop`-sample block, summed over channels.
    static func kPower(_ x: [[Float]], sampleRate: Double, hop: Int) -> [Double] {
        let n = x.first?.count ?? 0
        var p = [Double](repeating: 0, count: (n + hop - 1) / hop)
        let k = kWeighting(sampleRate)
        for ch in x {
            let y = filter(ch, k)
            y.withUnsafeBufferPointer { yp in
                for b in p.indices {
                    let lo = b * hop, hi = min(n, lo + hop)
                    var s: Float = 0
                    vDSP_svesq(yp.baseAddress! + lo, 1, &s, vDSP_Length(hi - lo))
                    p[b] += Double(s) / Double(hi - lo)
                }
            }
        }
        return p
    }

    static func lufs(_ power: Double) -> Double { -0.691 + 10 * log10(max(power, 1e-20)) }

    /// BS.1770 gated loudness of K-weighted hop powers (`hopSeconds` each): 400 ms blocks every hop, −70 LUFS
    /// absolute and −10 LU relative gates. A span shorter than a block is its mean.
    static func gatedLoudness(_ p: ArraySlice<Double>, hopSeconds: Double) -> Double {
        guard !p.isEmpty else { return -.infinity }
        let size = max(1, Int((0.4 / hopSeconds).rounded()))
        let v = Array(p)
        guard v.count > size else { return lufs(v.reduce(0, +) / Double(v.count)) }
        var sums = [Double](repeating: 0, count: v.count + 1)
        for i in v.indices { sums[i + 1] = sums[i] + v[i] }
        let blocks = (0...(v.count - size)).map { (sums[$0 + size] - sums[$0]) / Double(size) }
        let gated = blocks.filter { lufs($0) > -70 }
        guard !gated.isEmpty else { return -.infinity }
        let relative = lufs(gated.reduce(0, +) / Double(gated.count)) - 10
        let kept = gated.filter { lufs($0) > relative }
        return kept.isEmpty ? -.infinity : lufs(kept.reduce(0, +) / Double(kept.count))
    }

    /// Gated loudness (LUFS) of `x` between `from` and `to` seconds.
    public static func loudness(_ x: [[Float]], sampleRate: Double, from: Double = 0, to: Double? = nil) -> Double {
        let n = x.first?.count ?? 0
        let lo = max(0, min(n, Int(from * sampleRate))), hi = max(lo, min(n, Int((to ?? Double(n) / sampleRate) * sampleRate)))
        guard hi > lo else { return -.infinity }
        let hop = max(1, Int(sampleRate * 0.01))
        let part = x.map { Array($0[lo..<hi]) }
        return gatedLoudness(kPower(part, sampleRate: sampleRate, hop: hop)[...], hopSeconds: Double(hop) / sampleRate)
    }

    static func percentile(_ v: [Double], _ q: Double) -> Double {
        guard !v.isEmpty else { return -.infinity }
        let s = v.sorted()
        return s[min(s.count - 1, max(0, Int(Double(s.count - 1) * q)))]
    }

    /// Hops that carry foreground sound: loudness over 100 ms above `floor` LUFS and 6–10 dB over the background
    /// (the 5th percentile of non-silent hops), and within 20 dB of the loud passages when the noise allows.
    static func activity(_ power: [Double], hopSeconds: Double, floor: Double) -> [Bool] {
        let m = power.count
        guard m > 0 else { return [] }
        let r = max(1, Int((0.05 / hopSeconds).rounded()))
        var sums = [Double](repeating: 0, count: m + 1)
        for i in 0..<m { sums[i + 1] = sums[i] + power[i] }
        let short = (0..<m).map { i -> Double in
            let lo = max(0, i - r), hi = min(m, i + r + 1)
            return lufs((sums[hi] - sums[lo]) / Double(hi - lo))
        }
        let audible = short.filter { $0 > -100 }
        let noise = percentile(audible, 0.05), loud = percentile(audible, 0.95)
        let threshold = max(floor, max(noise + 6, min(noise + 10, loud - 20)))
        return short.map { $0 > threshold }
    }

    /// Spans (seconds) of foreground sound, joined across pauses under `bridge` seconds; spans under `shortest`
    /// are dropped. What `clip_gain_ride` rides when there is no transcript.
    public static func soundSpans(_ x: [[Float]], sampleRate: Double, floor: Double = -50, bridge: Double = 0.3, shortest: Double = 0.2) -> [TimeRange] {
        let hop = max(1, Int(sampleRate * 0.01)), hs = Double(hop) / sampleRate
        let active = activity(kPower(x, sampleRate: sampleRate, hop: hop), hopSeconds: hs, floor: floor)
        var spans: [TimeRange] = []
        var i = 0
        while i < active.count {
            guard active[i] else { i += 1; continue }
            var j = i
            while j < active.count, active[j] { j += 1 }
            let r = TimeRange(Double(i) * hs, Double(j) * hs)
            if let last = spans.last, r.start - last.end < bridge { spans[spans.count - 1].end = r.end } else { spans.append(r) }
            i = j
        }
        return spans.filter { $0.duration >= shortest }
    }

    /// The sample range holding sound, padded by `pad` samples; nil for digital silence.
    static func audibleSpan(_ x: [[Float]], pad: Int) -> Range<Int>? {
        let n = x.first?.count ?? 0
        var lo = n, hi = 0
        for ch in x {
            if let f = ch.firstIndex(where: { $0 != 0 }) { lo = min(lo, f) }
            if let l = ch.lastIndex(where: { $0 != 0 }) { hi = max(hi, l + 1) }
        }
        guard hi > lo else { return nil }
        return max(0, lo - pad)..<min(n, hi + pad)
    }

    /// Runs `body` on the audible part of `x` only, leaving the silence around it as it is.
    static func onAudible(_ x: [[Float]], sampleRate: Double, _ body: ([[Float]], Double) -> [[Float]]) -> [[Float]] {
        let n = x.first?.count ?? 0
        guard let span = audibleSpan(x, pad: Int(sampleRate * 0.25)) else { return x }
        if span.count == n { return body(x, 0) }
        let part = body(x.map { Array($0[span]) }, Double(span.lowerBound) / sampleRate)
        return zip(x, part).map { full, p in
            var y = full
            y.replaceSubrange(span, with: p.prefix(span.count))
            return y
        }
    }

    // MARK: - Leveler

    /// Dialogue leveler. The gain holds speech at `target` LUFS, measured over a centered window (3 s at `speed` 0,
    /// 0.4 s at 1) of the foreground hops only (`activity`), within −`maxCut`…+`maxBoost` dB. Where the window holds
    /// no foreground sound the gain is held, so pauses and background never drive it. The gain is smoothed both
    /// ways (no lag) and held low enough that sample peaks stay under −1 dBFS.
    public static func level(_ x: [[Float]], sampleRate: Double, target: Double, maxBoost: Double, maxCut: Double, speed: Double, floor: Double) -> [[Float]] {
        onAudible(x, sampleRate: sampleRate) { x, _ in levelGain(x, sampleRate: sampleRate, target: target, maxBoost: maxBoost, maxCut: maxCut, speed: speed, floor: floor).map { applyGain(x, $0) } ?? x }
    }

    /// Per-sample linear gain of `level`; nil when there is no foreground sound.
    static func levelGain(_ x: [[Float]], sampleRate: Double, target: Double, maxBoost: Double, maxCut: Double, speed: Double, floor: Double) -> [Float]? {
        let n = x.first?.count ?? 0
        let hop = max(1, Int(sampleRate * 0.01)), hs = Double(hop) / sampleRate
        let power = kPower(x, sampleRate: sampleRate, hop: hop)
        let active = activity(power, hopSeconds: hs, floor: floor)
        let m = power.count
        guard m > 0, active.contains(true) else { return nil }
        let window = 3.0 * pow(0.4 / 3.0, min(max(speed, 0), 1))
        let half = max(1, Int(window / hs / 2))
        var pSum = [Double](repeating: 0, count: m + 1), cSum = [Int](repeating: 0, count: m + 1)
        for i in 0..<m {
            pSum[i + 1] = pSum[i] + (active[i] ? power[i] : 0)
            cSum[i + 1] = cSum[i] + (active[i] ? 1 : 0)
        }
        let needed = max(1, Int(0.15 / hs))
        var gain = [Double?](repeating: nil, count: m)
        for i in 0..<m {
            let lo = max(0, i - half), hi = min(m, i + half + 1)
            let count = cSum[hi] - cSum[lo]
            guard count >= needed else { continue }
            let l = lufs((pSum[hi] - pSum[lo]) / Double(count))
            gain[i] = min(max(target - l, -abs(maxCut)), abs(maxBoost))
        }
        guard let first = gain.first(where: { $0 != nil }) ?? nil else { return nil }
        var held = [Double](repeating: first, count: m)
        var last = first
        for i in 0..<m {
            if let g = gain[i] { last = g }
            held[i] = last
        }
        let a = exp(-1 / max(1, window / 4 / hs))
        for i in 1..<m { held[i] = a * held[i - 1] + (1 - a) * held[i] }
        for i in stride(from: m - 2, through: 0, by: -1) { held[i] = a * held[i + 1] + (1 - a) * held[i] }
        // Peak ceiling: −1 dBFS against each hop's loudest sample, looked at ±50 ms ahead and behind.
        var peak = [Float](repeating: 0, count: m)
        for ch in x {
            ch.withUnsafeBufferPointer { p in
                for b in 0..<m {
                    let lo = b * hop, hi = min(n, lo + hop)
                    var v: Float = 0
                    vDSP_maxmgv(p.baseAddress! + lo, 1, &v, vDSP_Length(hi - lo))
                    peak[b] = max(peak[b], v)
                }
            }
        }
        let reach = max(1, Int(0.05 / hs))
        for i in 0..<m {
            let lo = max(0, i - reach), hi = min(m, i + reach + 1)
            let loudest = peak[lo..<hi].max() ?? 0
            if loudest > 0 { held[i] = min(held[i], -1 - 20 * log10(Double(loudest))) }
        }
        let linear = held.map { Float(pow(10, $0 / 20)) }
        var g = [Float](repeating: 1, count: n)
        for s in 0..<n {
            let pos = Double(s) / Double(hop) - 0.5
            let i = Int(pos.rounded(.down))
            if i < 0 { g[s] = linear[0]; continue }
            if i >= m - 1 { g[s] = linear[m - 1]; continue }
            let f = Float(pos - Double(i))
            g[s] = linear[i] + f * (linear[i + 1] - linear[i])
        }
        return g
    }

    static func applyGain(_ x: [[Float]], _ g: [Float]) -> [[Float]] { x.map { vDSP.multiply($0, g) } }

    // MARK: - Match EQ

    /// Third-octave band centers from 50 Hz to 16 kHz, below 0.45 × the sample rate.
    public static func eqBands(sampleRate: Double) -> [Double] {
        (-13...12).map { 1000 * pow(2, Double($0) / 3) }.filter { $0 <= min(16_000, sampleRate * 0.45) }
    }

    /// Long-term average power per STFT bin over the frames that carry the main sound (speech): frames within
    /// 25 dB of the loud ones (95th percentile) and 10 dB over the quiet ones (5th), so pauses and room tone
    /// don't color it.
    public static func longTermSpectrum(_ x: [[Float]], sampleRate: Double) -> [Float] {
        let stft = STFT(sampleRate: sampleRate)
        let n = x.first?.count ?? 0
        var out = [Float](repeating: 0, count: stft.bins)
        guard n >= stft.size else { return out }
        let starts = Array(stride(from: 0, through: n - stft.size, by: stft.hop))
        var frame = [Float](repeating: 0, count: stft.size)
        let energy = starts.map { s -> Double in
            x.reduce(0) { acc, ch in
                ch.withUnsafeBufferPointer { stft.windowed($0, start: s, into: &frame) }
                return acc + Double(vDSP.sumOfSquares(frame))
            }
        }
        let levels = energy.map { 10 * log10(max($0, 1e-20)) }
        let audible = levels.filter { $0 > -150 }
        let hi = percentile(audible, 0.95), lo = percentile(audible, 0.05)
        var keep = starts.indices.filter { levels[$0] > max(hi - 25, lo + 10) }
        if keep.count < 4 { keep = starts.indices.filter { levels[$0] > -150 } }
        guard !keep.isEmpty else { return out }
        let spectrum = Spectrum(stft.half)
        out.withUnsafeMutableBufferPointer { p in
            for i in keep {
                for ch in x {
                    ch.withUnsafeBufferPointer { stft.forward($0, start: starts[i], into: spectrum) }
                    stft.addPower(spectrum, to: p.baseAddress!, scale: 1 / Float(keep.count * x.count))
                }
            }
        }
        return out
    }

    /// Mean power density (dB) in a third octave around each band center; bands too narrow for a bin read the
    /// spectrum interpolated at the center.
    public static func bandLevels(_ spectrum: [Float], sampleRate: Double, bands: [Double]) -> [Double] {
        let bins = spectrum.count
        guard bins > 1 else { return bands.map { _ in -200 } }
        let hz = sampleRate / Double(2 * (bins - 1))
        return bands.map { fc in
            let lo = Int((fc * pow(2, -1.0 / 6) / hz).rounded(.up)), hi = min(bins - 1, Int((fc * pow(2, 1.0 / 6) / hz).rounded(.down)))
            var p: Double
            if hi >= lo, lo >= 0 {
                p = (lo...hi).reduce(0) { $0 + Double(spectrum[$1]) } / Double(hi - lo + 1)
            } else {
                let pos = fc / hz, i = min(bins - 2, Int(pos)), f = pos - Double(i)
                p = Double(spectrum[i]) * (1 - f) + Double(spectrum[i + 1]) * f
            }
            return 10 * log10(max(p, 1e-20))
        }
    }

    /// Bands of a band-level list that carry content: within `range` dB of its strongest band.
    static func contentBands(_ levels: [Double], range: Double = 50) -> [Bool] {
        let top = levels.max() ?? 0
        return levels.map { $0 > top - range }
    }

    /// The EQ that turns `source`'s long-term spectrum into `reference`'s: the difference per third-octave band,
    /// smoothed over neighboring bands, with the overall level difference taken out so loudness holds (shifted
    /// by up to 3 dB when that keeps more of the curve's shape inside ±`maxDb`), within ±`maxDb`. A band where the source has no
    /// content is never boosted, so hiss above a band-limited source isn't lifted: with `sourceNoise`
    /// (`noiseProfile`), its speech stands less than 6 dB over the noise or lies 70 dB under the strongest band;
    /// without, it lies 50 dB under. Bands where neither has content stay flat.
    public static func matchCurve(source: [Float], reference: [Float], sampleRate: Double, maxDb: Double = 12, sourceNoise: [Float]? = nil, referenceNoise: [Float]? = nil) -> EQCurve {
        let bands = eqBands(sampleRate: sampleRate)
        let src = bandLevels(source, sampleRate: sampleRate, bands: bands), ref = bandLevels(reference, sampleRate: sampleRate, bands: bands)
        func content(_ levels: [Double], _ noise: [Float]?) -> [Bool] {
            guard let noise else { return contentBands(levels) }
            let top = levels.max() ?? 0
            return zip(levels, bandLevels(resample(noise, to: source.count), sampleRate: sampleRate, bands: bands)).map { $0 > top - 70 && $0 > $1 + 6 }
        }
        let srcOK = content(src, sourceNoise), refOK = content(ref, referenceNoise)
        let raw = zip(ref, src).map { $0 - $1 }
        var d = raw.indices.map { i in 0.5 * raw[i] + 0.25 * (raw[max(i - 1, 0)] + raw[min(i + 1, raw.count - 1)]) }
        func limitContent() {
            for i in d.indices where !srcOK[i] { d[i] = refOK[i] ? min(d[i], 0) : 0 }
        }
        limitContent()
        let weights = zip(src, bands).map { pow(10, $0 / 10) * $1 }
        let total = weights.reduce(0, +)
        if total > 0 {
            let after = zip(weights, d).reduce(0) { $0 + $1.0 * pow(10, $1.1 / 10) }
            let offset = 10 * log10(after / total)
            for i in d.indices { d[i] -= offset }
        }
        let bound = abs(maxDb)
        let shaped = d.indices.filter { srcOK[$0] }.map { d[$0] }
        if let hi = shaped.max(), let lo = shaped.min() {
            if hi > bound { let s = min(hi - bound, max(0, lo + bound), 3); for i in d.indices { d[i] -= s } }
            if lo < -bound { let s = min(-bound - lo, max(0, bound - hi), 3); for i in d.indices { d[i] += s } }
        }
        limitContent()
        return EQCurve(points: zip(bands, d).map { ($0, (min(max($1, -bound), bound) * 10).rounded() / 10) })
    }

    /// How far apart two long-term spectra are in tone: RMS over third-octave bands between `low` and `high` Hz
    /// where both have content (within 60 dB of their strongest band), after removing their mean level difference. dB.
    public static func spectralDistance(_ a: [Float], _ b: [Float], sampleRate: Double, low: Double = 100, high: Double = 8000) -> Double {
        let bands = eqBands(sampleRate: sampleRate)
        let la = bandLevels(a, sampleRate: sampleRate, bands: bands), lb = bandLevels(b, sampleRate: sampleRate, bands: bands)
        let okA = contentBands(la, range: 60), okB = contentBands(lb, range: 60)
        let d = bands.indices.filter { bands[$0] >= low && bands[$0] <= high && okA[$0] && okB[$0] }.map { la[$0] - lb[$0] }
        guard !d.isEmpty else { return 0 }
        let mean = d.reduce(0, +) / Double(d.count)
        return (d.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(d.count)).squareRoot()
    }

    /// Applies an EQ curve, scaled by `amount`, as a zero-phase STFT filter.
    public static func matchEQ(_ x: [[Float]], sampleRate: Double, curve: EQCurve, amount: Double) -> [[Float]] {
        guard !curve.points.isEmpty, amount > 0, (x.first?.count ?? 0) > 0 else { return x }
        let stft = STFT(sampleRate: sampleRate)
        let hz = sampleRate / Double(stft.size)
        let gain = (0..<stft.bins).map { k in Float(pow(10, amount * curve.gain(at: max(1, Double(k) * hz)) / 20)) }
        return onAudible(x, sampleRate: sampleRate) { x, _ in filterSpectrum(x, stft: stft) { _, _ in gain } }
    }

    /// Overlap-adds every channel through the STFT, multiplying each frame by the gains `body` returns for it
    /// (given the frame start and the frame's mean power per bin over channels).
    static func filterSpectrum(_ x: [[Float]], stft: STFT, _ body: (Int, [Float]) -> [Float]) -> [[Float]] {
        let n = x.first?.count ?? 0, c = x.count
        var out = [[Float]](repeating: [Float](repeating: 0, count: n), count: c)
        let spectra = (0..<c).map { _ in Spectrum(stft.half) }
        var power = [Float](repeating: 0, count: stft.bins)
        for start in stride(from: stft.hop - stft.size, to: n, by: stft.hop) {
            power.withUnsafeMutableBufferPointer { p in
                vDSP.fill(&p, with: 0)
                for ch in 0..<c {
                    x[ch].withUnsafeBufferPointer { stft.forward($0, start: start, into: spectra[ch]) }
                    stft.addPower(spectra[ch], to: p.baseAddress!, scale: 1 / Float(c))
                }
            }
            let g = body(start, power)
            for ch in 0..<c {
                stft.apply(g, to: spectra[ch])
                out[ch].withUnsafeMutableBufferPointer { stft.inverse(spectra[ch], start: start, addTo: $0) }
            }
        }
        for ch in 0..<c { out[ch].withUnsafeMutableBufferPointer { stft.normalize($0) } }
        return out
    }

    // MARK: - De-reverb

    /// The room's reverb time from free decays in the sound: after each offset of 20 dB or more, the energy
    /// (300 Hz–4 kHz, 50 ms average) from 10 to 30 dB down is fitted with a line (past the fall of the direct
    /// sound) and the slopes' median, weighted by the dB each spans, is the room's. Nil with fewer than two decays.
    public static func estimateRT60(_ x: [[Float]], sampleRate: Double) -> Double? {
        let stft = STFT(sampleRate: sampleRate, seconds: 0.016)
        let n = x.first?.count ?? 0
        guard n > stft.size * 8 else { return nil }
        let hz = sampleRate / Double(stft.size)
        let k0 = max(1, Int(300 / hz)), k1 = min(stft.half - 1, Int(4000 / hz))
        guard k1 > k0 else { return nil }
        let spectrum = Spectrum(stft.half)
        var power: [Double] = []
        for start in stride(from: 0, through: n - stft.size, by: stft.hop) {
            var e = 0.0
            for ch in x {
                ch.withUnsafeBufferPointer { stft.forward($0, start: start, into: spectrum) }
                for k in k0...k1 { e += Double(spectrum.re[k] * spectrum.re[k] + spectrum.im[k] * spectrum.im[k]) }
            }
            power.append(e)
        }
        // A 50 ms moving average evens out the tail's random fluctuation without changing its slope.
        let r = max(1, Int((0.025 / (Double(stft.hop) / sampleRate)).rounded()))
        let levels = power.indices.map { i in 10 * log10(max(power[max(0, i - r)...min(power.count - 1, i + r)].reduce(0, +) / Double(2 * r + 1), 1e-20)) }
        let audible = levels.filter { $0 > -150 }
        let floorLevel = percentile(audible, 0.05), loud = percentile(audible, 0.95)
        guard loud - floorLevel > 25 else { return nil }
        let dt = Double(stft.hop) / sampleRate
        var slopes: [(rate: Double, span: Double)] = []
        var i = 1
        while i < levels.count - 1 {
            guard levels[i] >= levels[i - 1], levels[i] > levels[i + 1], levels[i] > floorLevel + 25 else { i += 1; continue }
            var j = i, k = i
            while k + 1 < levels.count, levels[k + 1] < levels[j] + 3, levels[k + 1] > floorLevel + 6 {
                k += 1
                if levels[k] < levels[j] { j = k }
            }
            if levels[i] - levels[j] >= 20 {
                // Fit from 10 to 30 dB down, past the fall of the direct sound and early reflections.
                var a = i
                while a < j, levels[i] - levels[a] < 10 { a += 1 }
                var b = a
                while b < j, levels[i] - levels[b] < 30 { b += 1 }
                let ts = (a...b).map { Double($0) * dt }, ls = (a...b).map { levels[$0] }
                if levels[a] - levels[b] >= 10, ts.count >= 4 {
                    let mt = ts.reduce(0, +) / Double(ts.count), ml = ls.reduce(0, +) / Double(ls.count)
                    let num = zip(ts, ls).reduce(0) { $0 + ($1.0 - mt) * ($1.1 - ml) }
                    let den = ts.reduce(0) { $0 + ($1 - mt) * ($1 - mt) }
                    if den > 0, num / den < 0 { slopes.append((-num / den, levels[a] - levels[b])) }
                }
            }
            i = max(k, i + 1)
        }
        guard slopes.count >= 2 else { return nil }
        // Median weighted by how many dB each decay spans.
        let sorted = slopes.sorted { $0.rate < $1.rate }
        let total = sorted.reduce(0) { $0 + $1.span }
        var acc = 0.0
        let rate = sorted.first { acc += $0.span; return acc >= total / 2 }?.rate ?? sorted[sorted.count / 2].rate
        return min(4, max(0.15, 60 / rate))
    }

    /// Late-reverb suppression (Lebart's model): each bin's late reverb is predicted as its power (averaged over
    /// neighboring bins and 50 ms) 50 ms earlier, decayed by the room's reverb time, and `0.5 + 1.5 × strength`
    /// times that prediction is subtracted from the averaged power (power subtraction, one gain for all channels);
    /// the gain is smoothed over neighboring bins, released over 30 ms and floored at −`reduction` dB. `rt60` 0 measures the room (`estimateRT60`;
    /// unchanged when it can't).
    public static func dereverb(_ x: [[Float]], sampleRate: Double, strength: Double, reduction: Double, rt60: Double) -> [[Float]] {
        guard strength > 0, reduction > 0 else { return x }
        return onAudible(x, sampleRate: sampleRate) { x, _ in
            guard let rt = rt60 > 0 ? rt60 : estimateRT60(x, sampleRate: sampleRate) else { return x }
            let stft = STFT(sampleRate: sampleRate, seconds: 0.032)
            let bins = stft.bins
            let hs = Double(stft.hop) / sampleRate
            let lag = max(1, Int((0.05 / hs).rounded()))
            let decay = Float(exp(-2 * 3 * log(10.0) / rt * Double(lag) * hs))
            let beta = Float(0.5 + 1.5 * min(max(strength, 0), 1))
            let smooth = Float(exp(-hs / 0.05))
            let release = Float(exp(-hs / 0.03))
            let floorGain = Float(pow(10, -min(reduction, 60) / 20))
            var history = [[Float]](repeating: [Float](repeating: 0, count: bins), count: lag)
            var slot = 0
            var smoothed = [Float](repeating: 0, count: bins)
            var held = [Float](repeating: 1, count: bins)
            var raw = [Float](repeating: 1, count: bins)
            var gain = [Float](repeating: 1, count: bins)
            return filterSpectrum(x, stft: stft) { _, power in
                let late = history[slot]
                for k in 0..<bins {
                    // Power averaged over neighboring bins and 50 ms, so the gain follows the reverb's level
                    // rather than its random peaks.
                    let pf = 0.5 * power[k] + 0.25 * (power[max(k - 1, 0)] + power[min(k + 1, bins - 1)])
                    smoothed[k] = smooth * smoothed[k] + (1 - smooth) * pf
                    raw[k] = max(1 - beta * decay * late[k] / max(smoothed[k], 1e-20), floorGain * floorGain).squareRoot()
                }
                history[slot] = smoothed
                slot = (slot + 1) % lag
                for k in 0..<bins {
                    let s = 0.5 * raw[k] + 0.25 * (raw[max(k - 1, 0)] + raw[min(k + 1, bins - 1)])
                    held[k] = s >= held[k] ? s : release * held[k] + (1 - release) * s
                    gain[k] = max(floorGain, held[k])
                }
                return gain
            }
        }
    }

    // MARK: - Spectral repair

    public enum RepairMode: String, Sendable { case interpolate, attenuate }

    /// Repairs the patch from `from` to `to` seconds between `low` and `high` Hz (0 high: to the top) with 21 ms
    /// STFT frames. interpolate: each bin of the frames touching the patch is brought down to the level
    /// interpolated (over log magnitude, in time) between the three frames just before and just after it,
    /// keeping its phase, so a cough, click or beep takes on the sound around it and nothing gets louder.
    /// attenuate: the patch is turned down by `reduction` dB, weighted by how much of each frame lies inside.
    /// Two bins outside each band edge are blended in; samples outside the touched frames are untouched.
    public static func spectralRepair(_ x: [[Float]], sampleRate: Double, from: Double, to: Double, low: Double, high: Double, mode: RepairMode, reduction: Double) -> [[Float]] {
        let n = x.first?.count ?? 0
        let s0 = max(0, Int(from * sampleRate)), s1 = min(n, Int(to * sampleRate))
        guard s1 > s0 else { return x }
        let stft = STFT(sampleRate: sampleRate, seconds: 0.021)
        let size = stft.size, hop = stft.hop, half = stft.half
        let hz = sampleRate / Double(size)
        let top = high > 0 ? min(high, sampleRate / 2) : sampleRate / 2
        let k0 = max(0, Int((max(0, low) / hz).rounded(.down))), k1 = min(half, Int((top / hz).rounded(.up)))
        guard k1 >= k0 else { return x }
        func weight(_ k: Int) -> Float {
            let outside = max(k0 - k, k - k1)
            return outside <= 0 ? 1 : outside >= 3 ? 0 : Float(3 - outside) / 3
        }
        let bandLo = max(0, k0 - 2), bandHi = min(half, k1 + 2)
        // Frames on a hop grid: the patch's frames, three anchors each side, and what overlaps them.
        let firstTouch = Int((Double(s0 - size + 1) / Double(hop)).rounded(.up))
        let lastTouch = Int((Double(s1 - 1) / Double(hop)).rounded(.down))
        let before = (1...3).map { firstTouch - $0 }.reversed().map { $0 * hop }
        let after = (1...3).map { lastTouch + $0 }.map { $0 * hop }
        let usable = { (s: Int) in s >= -size / 2 && s + size / 2 <= n }
        let anchorsBefore = before.filter(usable), anchorsAfter = after.filter(usable)
        guard !(anchorsBefore.isEmpty && anchorsAfter.isEmpty) else { return x }
        let reduce = Float(pow(10, -min(max(reduction, 0), 120) / 20))
        let windowEnergy = vDSP.sumOfSquares(stft.window)
        let spectrum = Spectrum(half)
        var out = x
        for (c, ch) in x.enumerated() {
            func magnitudes(_ start: Int) -> [Float] {
                ch.withUnsafeBufferPointer { stft.forward($0, start: start, into: spectrum) }
                return (0...half).map { k in
                    let (re, im) = k == 0 ? (spectrum.re[0], Float(0)) : k == half ? (spectrum.im[0], Float(0)) : (spectrum.re[k], spectrum.im[k])
                    return re * re + im * im
                }
            }
            func anchor(_ starts: [Int]) -> [Float]? {
                guard !starts.isEmpty else { return nil }
                var sum = [Float](repeating: 0, count: half + 1)
                for s in starts { vDSP.add(sum, magnitudes(s), result: &sum) }
                return sum.map { ($0 / Float(starts.count)).squareRoot() }
            }
            let mb = anchor(anchorsBefore), ma = anchor(anchorsAfter)
            let tb = anchorsBefore.isEmpty ? nil : Double(anchorsBefore.reduce(0, +)) / Double(anchorsBefore.count)
            let ta = anchorsAfter.isEmpty ? nil : Double(anchorsAfter.reduce(0, +)) / Double(anchorsAfter.count)
            // Overlap-adds the frames into a buffer from the first frame's start.
            let base = (firstTouch - 3) * hop
            var acc = [Float](repeating: 0, count: (lastTouch + 3) * hop + size - base)
            acc.withUnsafeMutableBufferPointer { o in
                for f in (firstTouch - 3)...(lastTouch + 3) {
                    let start = f * hop
                    ch.withUnsafeBufferPointer { stft.forward($0, start: start, into: spectrum) }
                    if f >= firstTouch && f <= lastTouch {
                        let inside: Float
                        if mode == .attenuate {
                            let a = max(s0, start), b = min(s1, start + size)
                            inside = b > a ? stft.window[(a - start)..<(b - start)].reduce(0) { $0 + $1 * $1 } / windowEnergy : 0
                        } else {
                            inside = 1
                        }
                        let w: Double = {
                            guard let tb, let ta else { return tb == nil ? 1 : 0 }
                            return min(max((Double(start) - tb) / (ta - tb), 0), 1)
                        }()
                        for k in bandLo...bandHi {
                            let wk = weight(k) * inside
                            guard wk > 0 else { continue }
                            let isDC = k == 0, isNyquist = k == half
                            let re = isDC ? spectrum.re[0] : isNyquist ? spectrum.im[0] : spectrum.re[k]
                            let im = isDC || isNyquist ? 0 : spectrum.im[k]
                            let mag = (re * re + im * im).squareRoot()
                            guard mag > 0 else { continue }
                            var g: Float
                            if mode == .attenuate {
                                g = 1 - wk * (1 - reduce)
                            } else {
                                let b = Double(mb?[k] ?? ma![k]), a = Double(ma?[k] ?? mb![k])
                                let target = Float(exp((1 - w) * log(max(b, 1e-12)) + w * log(max(a, 1e-12))))
                                g = 1 - wk * (1 - min(1, target / mag))
                            }
                            if isDC { spectrum.re[0] *= g } else if isNyquist { spectrum.im[0] *= g } else {
                                spectrum.re[k] *= g
                                spectrum.im[k] *= g
                            }
                        }
                    }
                    stft.inverse(spectrum, start: start - base, addTo: o)
                }
                stft.normalize(o)
            }
            // Samples every frame of the grid covers in full: the touched frames' span.
            let a = max(0, firstTouch * hop), b = min(n, lastTouch * hop + size)
            guard b > a else { continue }
            out[c].replaceSubrange(a..<b, with: acc[(a - base)..<(b - base)])
        }
        return out
    }

    // MARK: - Sound events

    /// Clicks, thumps and tones that stand out of their surroundings, in time order.
    /// Clicks: energy above 3 kHz (2.5 ms hops) 32 dB over its ±100 ms median, under 25 ms.
    /// Thumps: energy under 150 Hz (10 ms hops) 15 dB over its ±0.5 s median and 3 dB over the 300 Hz–3 kHz energy,
    /// under 0.25 s, and 6 dB over the lows of the 0.3 s after it (louder than the voice's own lows).
    /// Tones: a spectral peak 20 dB (30 at its strongest) over the mean level of the bins 3–15 away, holding its frequency within a bin
    /// for 0.2 s or more.
    public static func repairCandidates(_ x: [[Float]], sampleRate: Double) -> [RepairCandidate] {
        let n = x.first?.count ?? 0
        guard n > Int(sampleRate * 0.1) else { return [] }
        var mono = x[0]
        for ch in x.dropFirst() { vDSP.add(mono, ch, result: &mono) }
        if x.count > 1 { vDSP.multiply(1 / Float(x.count), mono, result: &mono) }
        var events: [RepairCandidate] = []

        func envelope(_ y: [Float], hop: Int) -> [Double] {
            (0..<(n / hop)).map { b in
                var s: Float = 0
                y.withUnsafeBufferPointer { vDSP_svesq($0.baseAddress! + b * hop, 1, &s, vDSP_Length(hop)) }
                return 10 * log10(max(Double(s) / Double(hop), 1e-20))
            }
        }
        func runs(_ flags: [Bool]) -> [Range<Int>] {
            var out: [Range<Int>] = []
            var i = 0
            while i < flags.count {
                guard flags[i] else { i += 1; continue }
                var j = i
                while j < flags.count, flags[j] { j += 1 }
                out.append(i..<j)
                i = j
            }
            return out
        }
        func localMedian(_ v: [Double], radius: Int) -> [Double] {
            (0..<v.count).map { i in
                let w = v[max(0, i - radius)..<min(v.count, i + radius + 1)].sorted()
                return w[w.count / 2]
            }
        }

        let nyquist = sampleRate / 2
        if nyquist > 4000 {
            let hp = Biquad.highPass(3000, q: 0.5.squareRoot(), sampleRate)
            let hop = max(1, Int(sampleRate * 0.0025)), hs = Double(hop) / sampleRate
            let env = envelope(filter(mono, [hp, hp]), hop: hop)
            let med = localMedian(env, radius: Int(0.1 / hs))
            for r in runs(env.indices.map { env[$0] > med[$0] + 32 && env[$0] > -70 }) where Double(r.count) * hs <= 0.025 {
                let strength = r.map { env[$0] - med[$0] }.max() ?? 0
                events.append(RepairCandidate(kind: .click, start: Double(r.lowerBound) * hs, end: Double(r.upperBound) * hs, low: 0, high: 0, strength: strength))
            }
        }

        let lp = Biquad.lowPass(150, q: 0.5.squareRoot(), sampleRate)
        let bp = [Biquad.highPass(300, q: 0.5.squareRoot(), sampleRate), Biquad.lowPass(min(3000, nyquist * 0.9), q: 0.5.squareRoot(), sampleRate)]
        let hop = max(1, Int(sampleRate * 0.01)), hs = Double(hop) / sampleRate
        let lowEnv = envelope(filter(mono, [lp, lp]), hop: hop), midEnv = envelope(filter(mono, bp), hop: hop)
        let lowMed = localMedian(lowEnv, radius: Int(0.5 / hs))
        for r in runs(lowEnv.indices.map { lowEnv[$0] > lowMed[$0] + 15 && lowEnv[$0] > midEnv[$0] + 3 && lowEnv[$0] > -60 }) where Double(r.count) * hs <= 0.25 {
            let top = r.map { lowEnv[$0] }.max() ?? 0
            let following = lowEnv[min(lowEnv.count, r.upperBound + 2)..<min(lowEnv.count, r.upperBound + Int(0.3 / hs))].max() ?? -200
            guard top > following + 6 else { continue }
            let strength = r.map { lowEnv[$0] - lowMed[$0] }.max() ?? 0
            events.append(RepairCandidate(kind: .thump, start: Double(r.lowerBound) * hs, end: Double(r.upperBound) * hs, low: 0, high: 200, strength: strength))
        }

        let stft = STFT(sampleRate: sampleRate)
        let binHz = sampleRate / Double(stft.size)
        let spectrum = Spectrum(stft.half)
        let tHop = Double(stft.hop) / sampleRate
        let starts = Array(stride(from: 0, through: n - stft.size, by: stft.hop))
        var open: [Int: (first: Int, last: Int, bins: [Int], prominence: Double)] = [:]
        var tones: [RepairCandidate] = []
        func close(_ t: (first: Int, last: Int, bins: [Int], prominence: Double)) {
            guard Double(t.last - t.first + 1) * tHop >= 0.2, t.prominence >= 30 else { return }
            let f = Double(t.bins.reduce(0, +)) / Double(t.bins.count) * binHz
            let width = max(100, f * 0.03)
            tones.append(RepairCandidate(kind: .tone, start: Double(starts[t.first]) / sampleRate, end: Double(starts[t.last] + stft.size) / sampleRate, low: max(0, f - width), high: f + width, strength: t.prominence))
        }
        let kMin = max(16, Int(150 / binHz)), kMax = min(stft.half - 16, Int(min(16_000, nyquist * 0.95) / binHz))
        var level = [Double](repeating: 0, count: stft.half)
        var sums = [Double](repeating: 0, count: stft.half + 1)
        for (fi, s) in starts.enumerated() {
            mono.withUnsafeBufferPointer { stft.forward($0, start: s, into: spectrum) }
            for k in 1..<stft.half { level[k] = 10 * log10(max(Double(spectrum.re[k] * spectrum.re[k] + spectrum.im[k] * spectrum.im[k]), 1e-20)) }
            for k in 0..<stft.half { sums[k + 1] = sums[k] + level[k] }
            var peaks: [Int: Double] = [:]
            if kMax > kMin {
                for k in kMin...kMax where level[k] >= level[k - 1] && level[k] >= level[k + 1] && level[k] > -100 {
                    // Mean dB of the bins 3 to 15 away on each side, outside the peak's own main lobe.
                    let around = (sums[k - 2] - sums[k - 15] + sums[k + 16] - sums[k + 3]) / 26
                    let prominence = level[k] - around
                    if prominence >= 20 { peaks[k] = prominence }
                }
            }
            var next: [Int: (first: Int, last: Int, bins: [Int], prominence: Double)] = [:]
            for (k, prom) in peaks {
                if let key = [k, k - 1, k + 1].first(where: { open[$0] != nil }), var t = open.removeValue(forKey: key) {
                    t.last = fi
                    t.bins.append(k)
                    t.prominence = max(t.prominence, prom)
                    next[k] = t
                } else {
                    next[k] = (fi, fi, [k], prom)
                }
            }
            for t in open.values { close(t) }
            open = next
        }
        for t in open.values { close(t) }
        // Overlapping tone tracks a bin apart are one tone.
        for t in tones.sorted(by: { $0.start < $1.start }) {
            if let i = events.lastIndex(where: { $0.kind == .tone && $0.start < t.end && t.start < $0.end && $0.low < t.high && t.low < $0.high }) {
                events[i].start = min(events[i].start, t.start)
                events[i].end = max(events[i].end, t.end)
                events[i].low = min(events[i].low, t.low)
                events[i].high = max(events[i].high, t.high)
                events[i].strength = max(events[i].strength, t.strength)
            } else {
                events.append(t)
            }
        }
        return events.sorted { $0.start < $1.start }
    }
}
