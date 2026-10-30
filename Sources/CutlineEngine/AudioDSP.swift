import AVFoundation
import Accelerate
import CutlineCore
import Foundation

/// Offline restoration and stereo processors on deinterleaved float audio (`[[Float]]`, one array per channel,
/// all the same length). Each is a pure function of its input; wrap long buffers in `offline` so the work runs
/// on its own thread instead of Swift's cooperative pool.
public enum AudioDSP {
    /// Runs synchronous DSP on a dedicated thread.
    public static func offline<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await runBlocking { _ in try work() }
    }

    // MARK: - Noise reduction

    /// Spectral noise reduction: a decision-directed Wiener gain per STFT bin (Hann window, 75% overlap),
    /// smoothed across neighboring bins and released over ~40 ms, floored at `reduction` dB. All channels share
    /// one gain so the stereo image stays put. `sensitivity` scales the noise estimate from −6 dB (0) to +6 dB (1).
    /// Without `noiseProfile`, the floor is learned from the quietest 10% of frames.
    public static func denoise(_ x: [[Float]], sampleRate: Double, reduction: Double, sensitivity: Double, noiseProfile profile: [Float]? = nil) -> [[Float]] {
        let n = x.first?.count ?? 0
        guard n > 0, reduction > 0 else { return x }
        let stft = STFT(sampleRate: sampleRate)
        let bins = stft.bins, c = x.count
        let over = Float(pow(10, (min(max(sensitivity, 0), 1) - 0.5) * 1.2))
        let noise = (profile.map { resample($0, to: bins) } ?? noiseProfile(x, sampleRate: sampleRate)).map { $0 * over + 1e-20 }
        let floorGain = Float(pow(10, -min(reduction, 80) / 20))
        let alpha: Float = 0.98
        let release = Float(exp(-Double(stft.hop) / (sampleRate * 0.04)))

        var out = [[Float]](repeating: [Float](repeating: 0, count: n), count: c)
        let spectra = (0..<c).map { _ in Spectrum(stft.half) }
        var power = [Float](repeating: 0, count: bins)
        var prior = [Float](repeating: 0, count: bins)
        var raw = [Float](repeating: 0, count: bins)
        var held = [Float](repeating: 1, count: bins)
        var gain = [Float](repeating: 1, count: bins)
        for start in stride(from: stft.hop - stft.size, to: n, by: stft.hop) {
            power.withUnsafeMutableBufferPointer { p in
                vDSP.fill(&p, with: 0)
                for ch in 0..<c {
                    x[ch].withUnsafeBufferPointer { stft.forward($0, start: start, into: spectra[ch]) }
                    stft.addPower(spectra[ch], to: p.baseAddress!, scale: 1 / Float(c))
                }
            }
            noise.withUnsafeBufferPointer { nz in
                for k in 0..<bins {
                    let gamma = power[k] / nz[k]
                    let xi = alpha * prior[k] + (1 - alpha) * max(gamma - 1, 0)
                    let g = xi / (1 + xi)
                    prior[k] = g * g * gamma
                    raw[k] = g
                }
            }
            for k in 0..<bins {
                let s = 0.5 * raw[k] + 0.25 * (raw[max(k - 1, 0)] + raw[min(k + 1, bins - 1)])
                held[k] = s >= held[k] ? s : release * held[k] + (1 - release) * s
                gain[k] = max(floorGain, held[k])
            }
            for ch in 0..<c {
                stft.apply(gain, to: spectra[ch])
                out[ch].withUnsafeMutableBufferPointer { stft.inverse(spectra[ch], start: start, addTo: $0) }
            }
        }
        for ch in 0..<c { out[ch].withUnsafeMutableBufferPointer { stft.normalize($0) } }
        return out
    }

    /// Mean noise power per STFT bin (DC to Nyquist) over the quietest `quantile` of frames by energy,
    /// averaged across channels. Digital silence is ignored. Feed it a room-tone stretch to steer `denoise`.
    public static func noiseProfile(_ x: [[Float]], sampleRate: Double, quantile: Double = 0.1) -> [Float] {
        let stft = STFT(sampleRate: sampleRate)
        let n = x.first?.count ?? 0
        var profile = [Float](repeating: 0, count: stft.bins)
        guard n > 0 else { return profile }
        let starts = Array(stride(from: 0, through: max(0, n - stft.size), by: stft.hop))
        var energy = [Float](repeating: 0, count: starts.count)
        var frame = [Float](repeating: 0, count: stft.size)
        for (i, s) in starts.enumerated() {
            for ch in x {
                ch.withUnsafeBufferPointer { stft.windowed($0, start: s, into: &frame) }
                energy[i] += vDSP.sumOfSquares(frame)
            }
        }
        let audible = starts.indices.filter { energy[$0] > 1e-14 * Float(stft.size * x.count) }
        guard !audible.isEmpty else { return profile }
        let take = max(1, Int(Double(audible.count) * min(max(quantile, 0.001), 1)))
        let quiet = audible.sorted { energy[$0] < energy[$1] }.prefix(take)
        let spectrum = Spectrum(stft.half)
        profile.withUnsafeMutableBufferPointer { p in
            for i in quiet {
                for ch in x {
                    ch.withUnsafeBufferPointer { stft.forward($0, start: starts[i], into: spectrum) }
                    stft.addPower(spectrum, to: p.baseAddress!, scale: 1 / Float(take * x.count))
                }
            }
        }
        let b = profile.count
        return (0..<b).map { k in 0.5 * profile[k] + 0.25 * (profile[max(k - 1, 0)] + profile[min(k + 1, b - 1)]) }
    }

    static func resample(_ v: [Float], to count: Int) -> [Float] {
        guard v.count != count, v.count > 1, count > 1 else { return v.count == count ? v : [Float](repeating: v.first ?? 0, count: count) }
        let step = Double(v.count - 1) / Double(count - 1)
        return (0..<count).map { k in
            let p = Double(k) * step, i = min(Int(p), v.count - 2), f = Float(p - Double(i))
            return v[i] * (1 - f) + v[i + 1] * f
        }
    }

    // MARK: - De-esser

    /// Split-band de-esser. A sidechain band-pass half an octave above `frequency` drives a 1 ms / 50 ms peak
    /// follower; while it is above `threshold` (dBFS), the band above `frequency` (Linkwitz–Riley 4th order split)
    /// is turned down to hold it at the threshold, by at most `reduction` dB. Below the split nothing changes.
    public static func deEss(_ x: [[Float]], sampleRate: Double, frequency: Double, threshold: Double, reduction: Double) -> [[Float]] {
        let n = x.first?.count ?? 0
        guard n > 0, reduction > 0 else { return x }
        let split = min(max(frequency, 1000), sampleRate * 0.45)
        let center = min(split * 2.0.squareRoot(), sampleRate * 0.45)
        var mono = x[0]
        if x.count > 1 {
            for ch in x.dropFirst() { vDSP.add(mono, ch, result: &mono) }
            vDSP.multiply(1 / Float(x.count), mono, result: &mono)
        }
        let bp = Biquad.bandPass(center, q: 0.9, sampleRate)
        let side = filter(mono, [bp, bp])
        let attack = Float(1 - exp(-1 / (0.001 * sampleRate)))
        let releaseCoef = Float(1 - exp(-1 / (0.05 * sampleRate)))
        let limit = Float(pow(10, threshold / 20))
        let minGain = Float(pow(10, -min(reduction, 80) / 20))
        var gain = [Float](repeating: 1, count: n)
        side.withUnsafeBufferPointer { s in
            gain.withUnsafeMutableBufferPointer { g in
                var env: Float = 0
                for i in 0..<n {
                    let a = abs(s[i])
                    env += (a > env ? attack : releaseCoef) * (a - env)
                    if env > limit { g[i] = max(minGain, limit / env) }
                }
            }
        }
        let lp = Biquad.lowPass(split, q: 0.5.squareRoot(), sampleRate)
        let hp = Biquad.highPass(split, q: 0.5.squareRoot(), sampleRate)
        return x.map { ch in
            let low = filter(ch, [lp, lp])
            var high = filter(ch, [hp, hp])
            vDSP.multiply(high, gain, result: &high)
            return vDSP.add(low, high)
        }
    }

    // MARK: - Hum removal

    /// Notches the hum fundamental and its first `harmonics` multiples (Q 25 biquads). `fundamental` 0 detects
    /// 50 or 60 Hz mains (refined to ±0.02 Hz) and returns the input unchanged when there is no clear hum.
    public static func deHum(_ x: [[Float]], sampleRate: Double, fundamental: Double, harmonics: Int) -> [[Float]] {
        guard (x.first?.count ?? 0) > 0, harmonics > 0 else { return x }
        guard let f0 = fundamental > 0 ? fundamental : detectHum(x, sampleRate: sampleRate) else { return x }
        let sections = (1...harmonics).map { Double($0) * f0 }.filter { $0 < sampleRate * 0.45 }.map { Biquad.notch($0, q: 25, sampleRate) }
        guard !sections.isEmpty else { return x }
        return x.map { filter($0, sections) }
    }

    /// The mains hum frequency near 50 or 60 Hz, or nil when no hum stands 10 dB above its neighborhood
    /// and within 60 dB of the signal.
    public static func detectHum(_ x: [[Float]], sampleRate: Double) -> Double? {
        let n = x.first?.count ?? 0
        let factor = max(1, Int(sampleRate / 2000))
        let rate = sampleRate / Double(factor)
        let span = min(n / factor, Int(rate * 10))
        guard span > Int(rate) else { return nil }
        let first = (n / factor - span) / 2 * factor
        var low = [Double](repeating: 0, count: span)
        for ch in x {
            ch.withUnsafeBufferPointer { p in
                for i in 0..<span {
                    var s: Float = 0
                    let o = first + i * factor
                    for j in 0..<factor { s += p[o + j] }
                    low[i] += Double(s)
                }
            }
        }
        func score(_ f: Double) -> Double {
            (1...4).map { Double($0) * f }.filter { $0 < rate * 0.4 }.reduce(0) { $0 + goertzel(low, $1, rate) }
        }
        let base = score(50) >= score(60) ? 50.0 : 60.0
        let best = stride(from: base - 0.6, through: base + 0.6, by: 0.02).max { score($0) < score($1) } ?? base
        let around = [-8.0, -5, 5, 8].map { score(best + $0) }.reduce(0, +) / 4
        let total = low.reduce(0) { $0 + $1 * $1 } / Double(span)
        return score(best) > 10 * around && score(best) > 1e-6 * total ? best : nil
    }

    static func goertzel(_ x: [Double], _ f: Double, _ rate: Double) -> Double {
        let c = 2 * cos(2 * .pi * f / rate)
        var s1 = 0.0, s2 = 0.0
        x.withUnsafeBufferPointer { p in
            for v in p {
                let s = v + c * s1 - s2
                s2 = s1
                s1 = s
            }
        }
        return (s1 * s1 + s2 * s2 - c * s1 * s2) / Double(x.count * x.count)
    }

    // MARK: - Click removal

    /// Replaces short impulsive clicks (under 5 ms) with a smooth bridge. A click is a second difference
    /// `4 + 8 × (1 − sensitivity)` times above its 20 ms neighborhood.
    public static func deClick(_ x: [[Float]], sampleRate: Double, sensitivity: Double = 0.5) -> [[Float]] {
        let factor = Float(4 + 8 * (1 - min(max(sensitivity, 0), 1)))
        let half = max(8, Int(sampleRate * 0.01)), pad = max(2, Int(sampleRate * 0.0001)), longest = Int(sampleRate * 0.005)
        return x.map { ch in
            let n = ch.count
            guard n > 2 * half else { return ch }
            var y = ch
            var d = [Float](repeating: 0, count: n)
            for i in 2..<n { d[i] = ch[i] - 2 * ch[i - 1] + ch[i - 2] }
            var sums = [Double](repeating: 0, count: n + 1)
            for i in 0..<n { sums[i + 1] = sums[i] + Double(d[i] * d[i]) }
            var regions: [(Int, Int)] = []
            for i in 2..<n {
                let a = max(0, i - half), b = min(n, i + half)
                let rms = Float(((sums[b] - sums[a]) / Double(b - a)).squareRoot())
                guard abs(d[i]) > factor * rms, abs(d[i]) > 1e-4 else { continue }
                let lo = max(1, i - 2 - pad), hi = min(n - 2, i + pad)
                if let last = regions.last, lo <= last.1 + 1 { regions[regions.count - 1].1 = max(last.1, hi) } else { regions.append((lo, hi)) }
            }
            for (lo, hi) in regions where hi - lo <= longest && lo >= 2 && hi + 2 < n {
                let p0 = ch[lo - 1], p1 = ch[hi + 1]
                let len = Float(hi - lo + 2)
                let m0 = (ch[lo - 1] - ch[lo - 2]) * len, m1 = (ch[hi + 2] - ch[hi + 1]) * len
                for i in lo...hi {
                    let t = Float(i - lo + 1) / len, t2 = t * t, t3 = t2 * t
                    y[i] = (2 * t3 - 3 * t2 + 1) * p0 + (t3 - 2 * t2 + t) * m0 + (-2 * t3 + 3 * t2) * p1 + (t3 - t2) * m1
                }
            }
            return y
        }
    }

    // MARK: - Stereo

    /// Constant-power balance: left gain `√2·cos θ`, right `√2·sin θ`, θ = (pan + 1)·π/4, so the center is
    /// unchanged and hard left sends the left channel at +3 dB and mutes the right. Mono input becomes stereo.
    public static func pan(_ x: [[Float]], pan: Double) -> [[Float]] {
        guard let first = x.first else { return x }
        let theta = (min(max(pan, -1), 1) + 1) * .pi / 4
        let gl = Float(2.0.squareRoot() * cos(theta)), gr = Float(2.0.squareRoot() * sin(theta))
        let right = x.count > 1 ? x[1] : first
        return [vDSP.multiply(gl, first), vDSP.multiply(gr, right)] + x.dropFirst(2)
    }

    /// Mid/side width: 0 folds to mono, 1 is unchanged, 2 doubles the side signal. Needs two channels.
    public static func stereoWidth(_ x: [[Float]], width: Double) -> [[Float]] {
        guard x.count == 2 else { return x }
        let w = Float(max(width, 0))
        let mid = vDSP.multiply(0.5, vDSP.add(x[0], x[1]))
        let side = vDSP.multiply(0.5 * w, vDSP.subtract(x[0], x[1]))
        return [vDSP.add(mid, side), vDSP.subtract(mid, side)]
    }

    /// Scales every channel by one gain so the loudest sample reaches `peak` dBFS. Silence is returned as is.
    public static func normalizePeak(_ x: [[Float]], peak: Double = -1) -> [[Float]] {
        let current = x.map { vDSP.maximumMagnitude($0) }.max() ?? 0
        guard current > 0 else { return x }
        let g = Float(pow(10, peak / 20)) / current
        return x.map { vDSP.multiply(g, $0) }
    }

    /// Routes a clip's channels to stereo: one side on both, a half-level sum on both, or the sides swapped.
    /// Mono input counts as both sides.
    public static func route(_ x: [[Float]], _ routing: ChannelRouting) -> [[Float]] {
        guard let first = x.first else { return x }
        let m = routing.matrix(count: x.count)
        func side(_ g: [Double]) -> [Float] {
            var y = [Float](repeating: 0, count: first.count)
            for (c, gain) in g.enumerated() where gain != 0 && c < x.count { y = vDSP.add(y, vDSP.multiply(Float(gain), x[c])) }
            return y
        }
        return [side(m.left), side(m.right)]
    }

    // MARK: - Effects and files

    /// Whether `apply` renders this effect type.
    static func handles(_ type: String) -> Bool { ProAudioCatalog.type(type) != nil || type == AudioStems.channelMapType || type == "audio.limiter" }

    /// Renders one `ProAudioCatalog` effect (or a clip stem's channel routing), blended with the input by `effect.mix`;
    /// nil for other types. `origin` is the buffer time (seconds) of the clip's start, which clip-local params count from.
    public static func apply(_ e: Effect, to x: [[Float]], sampleRate: Double, origin: Double = 0) -> [[Float]]? {
        func p(_ name: String) -> Double { e.params[name]?.number ?? (ProAudioCatalog.type(e.type) ?? EffectCatalog.type(e.type))?.spec(name)?.defaultValue.number ?? 0 }
        if e.type == AudioStems.channelMapType {
            return route(x, ChannelRouting(rawValue: e.params["channels"]?.string ?? "") ?? .stereo)
        }
        let wet: [[Float]]
        switch e.type {
        case "audio.denoise": wet = denoise(x, sampleRate: sampleRate, reduction: p("reduction"), sensitivity: p("sensitivity"))
        case "audio.deess": wet = deEss(x, sampleRate: sampleRate, frequency: p("frequency"), threshold: p("threshold"), reduction: p("reduction"))
        case "audio.dehum": wet = deHum(x, sampleRate: sampleRate, fundamental: p("fundamental"), harmonics: Int(p("harmonics").rounded()))
        case "audio.declick": wet = deClick(x, sampleRate: sampleRate, sensitivity: p("sensitivity"))
        case "audio.pan": wet = pan(x, pan: p("pan"))
        case "audio.width": wet = stereoWidth(x, width: p("width"))
        case "audio.limiter": wet = limit(x, sampleRate: sampleRate, ceilingDb: p("ceiling"), inputGainDb: p("input_gain"), releaseMs: p("release_ms"))
        case "audio.leveler": wet = level(x, sampleRate: sampleRate, target: p("target"), maxBoost: p("max_boost"), maxCut: p("max_cut"), speed: p("speed"), floor: p("floor"))
        case "audio.match_eq": wet = matchEQ(x, sampleRate: sampleRate, curve: EQCurve(text: e.params["curve"]?.string ?? "") ?? EQCurve(points: []), amount: p("amount"))
        case "audio.dereverb": wet = dereverb(x, sampleRate: sampleRate, strength: p("strength"), reduction: p("reduction"), rt60: p("rt60"))
        case "audio.spectral_repair":
            let mode = RepairMode(rawValue: e.params["mode"]?.string ?? "") ?? .interpolate
            wet = spectralRepair(x, sampleRate: sampleRate, from: origin + p("start"), to: origin + p("end"), low: p("freq_low"), high: p("freq_high"), mode: mode, reduction: p("reduction"))
        default: return nil
        }
        let mix = Float(min(max(e.mix, 0), 1))
        guard mix < 1, wet.count == x.count else { return wet }
        return zip(x, wet).map { dry, w in vDSP.add(dry, vDSP.multiply(mix, vDSP.subtract(w, dry))) }
    }

    /// True-peak limiting: `inputGainDb` of gain, then sample and 4× interpolated peaks held under `ceilingDb` dBTP
    /// with look-ahead, so the output lines up with the input.
    static func limit(_ x: [[Float]], sampleRate: Double, ceilingDb: Double, inputGainDb: Double, releaseMs: Double) -> [[Float]] {
        let g = Float(pow(10, inputGainDb / 20))
        let gained = g == 1 ? x : x.map { vDSP.multiply(g, $0) }
        var limiter = TruePeakLimiter(channels: max(1, x.count), ceiling: Float(pow(10, ceilingDb / 20)), release: max(0.001, releaseMs / 1000), sampleRate: sampleRate)
        let head = limiter.process(gained), tail = limiter.flush()
        let n = x.first?.count ?? 0
        return zip(head, tail).map { Array(($0 + $1).prefix(n)) }
    }

    /// Reads a whole audio file as deinterleaved float at its own sample rate.
    public static func read(_ url: URL) throws -> (samples: [[Float]], sampleRate: Double) {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(file.length, 1))) else { throw EditError("Cannot allocate audio for \(url.lastPathComponent)") }
        try file.read(into: buf)
        let n = Int(buf.frameLength)
        let samples = (0..<Int(format.channelCount)).map { Array(UnsafeBufferPointer(start: buf.floatChannelData![$0], count: n)) }
        return (samples, format.sampleRate)
    }

    /// Writes deinterleaved float as an uncompressed float CAF.
    public static func write(_ x: [[Float]], sampleRate: Double, to url: URL) throws {
        let n = x.first?.count ?? 0
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: AVAudioChannelCount(max(x.count, 1)), interleaved: false) else { throw EditError("Unsupported audio format") }
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let chunk = 65_536
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk))!
        for start in stride(from: 0, to: n, by: chunk) {
            let count = min(chunk, n - start)
            buf.frameLength = AVAudioFrameCount(count)
            for (c, ch) in x.enumerated() {
                ch.withUnsafeBufferPointer { buf.floatChannelData![c].update(from: $0.baseAddress! + start, count: count) }
            }
            try file.write(from: buf)
        }
    }

    // MARK: - Filters

    /// RBJ biquad coefficients `[b0, b1, b2, a1, a2]`, normalized by a0.
    enum Biquad {
        static func make(_ b0: Double, _ b1: Double, _ b2: Double, _ a0: Double, _ a1: Double, _ a2: Double) -> [Double] {
            [b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0]
        }

        static func parts(_ f: Double, _ q: Double, _ sr: Double) -> (cos: Double, alpha: Double) {
            let w = 2 * .pi * f / sr
            return (cos(w), sin(w) / (2 * q))
        }

        static func lowPass(_ f: Double, q: Double, _ sr: Double) -> [Double] {
            let (c, a) = parts(f, q, sr)
            return make((1 - c) / 2, 1 - c, (1 - c) / 2, 1 + a, -2 * c, 1 - a)
        }

        static func highPass(_ f: Double, q: Double, _ sr: Double) -> [Double] {
            let (c, a) = parts(f, q, sr)
            return make((1 + c) / 2, -(1 + c), (1 + c) / 2, 1 + a, -2 * c, 1 - a)
        }

        /// Band-pass with 0 dB at the center.
        static func bandPass(_ f: Double, q: Double, _ sr: Double) -> [Double] {
            let (c, a) = parts(f, q, sr)
            return make(a, 0, -a, 1 + a, -2 * c, 1 - a)
        }

        static func notch(_ f: Double, q: Double, _ sr: Double) -> [Double] {
            let (c, a) = parts(f, q, sr)
            return make(1, -2 * c, 1, 1 + a, -2 * c, 1 - a)
        }
    }

    /// Runs a cascade of biquad sections over one channel in double precision, which keeps narrow
    /// low-frequency notches deep.
    static func filter(_ x: [Float], _ sections: [[Double]]) -> [Float] {
        guard !x.isEmpty, !sections.isEmpty, let setup = vDSP_biquad_CreateSetupD(sections.flatMap { $0 }, vDSP_Length(sections.count)) else { return x }
        defer { vDSP_biquad_DestroySetupD(setup) }
        var delay = [Double](repeating: 0, count: 2 * sections.count + 2)
        let input = vDSP.floatToDouble(x)
        var output = [Double](repeating: 0, count: x.count)
        vDSP_biquadD(setup, &delay, input, 1, &output, 1, vDSP_Length(x.count))
        let y = vDSP.doubleToFloat(output)
        return y
    }
}

/// Split-complex half spectrum in vDSP's packed real layout: `im[0]` holds the Nyquist bin.
final class Spectrum {
    let re: UnsafeMutablePointer<Float>
    let im: UnsafeMutablePointer<Float>

    init(_ half: Int) {
        re = .allocate(capacity: half)
        im = .allocate(capacity: half)
        re.initialize(repeating: 0, count: half)
        im.initialize(repeating: 0, count: half)
    }

    deinit {
        re.deallocate()
        im.deallocate()
    }
}

/// Short-time Fourier transform with a Hann window at 75% overlap, ~43 ms frames unless given `seconds`.
final class STFT {
    let size, half, bins, hop: Int
    let log2n: vDSP_Length
    let setup: FFTSetup
    let window: [Float]
    private var frame: [Float]

    init(sampleRate: Double, seconds: Double = 0.043) {
        let target = max(256, min(16_384, sampleRate * seconds))
        log2n = vDSP_Length(log2(target).rounded())
        size = 1 << Int(log2n)
        half = size / 2
        bins = half + 1
        hop = size / 4
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: size, isHalfWindow: false)
        frame = [Float](repeating: 0, count: size)
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    /// The windowed frame starting at `start`, zero past either end of `x`.
    func windowed(_ x: UnsafeBufferPointer<Float>, start: Int, into out: inout [Float]) {
        let lo = max(0, start), hi = min(x.count, start + size)
        out.withUnsafeMutableBufferPointer { o in
            vDSP.fill(&o, with: 0)
            if hi > lo { (o.baseAddress! + (lo - start)).update(from: x.baseAddress! + lo, count: hi - lo) }
        }
        vDSP.multiply(out, window, result: &out)
    }

    func forward(_ x: UnsafeBufferPointer<Float>, start: Int, into s: Spectrum) {
        windowed(x, start: start, into: &frame)
        var split = DSPSplitComplex(realp: s.re, imagp: s.im)
        frame.withUnsafeBufferPointer { f in
            f.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half)) }
        }
        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
    }

    /// Adds `scale ×` the power of each of the `bins` bins to `p`.
    func addPower(_ s: Spectrum, to p: UnsafeMutablePointer<Float>, scale: Float) {
        p[0] += scale * s.re[0] * s.re[0]
        p[half] += scale * s.im[0] * s.im[0]
        for k in 1..<half { p[k] += scale * (s.re[k] * s.re[k] + s.im[k] * s.im[k]) }
    }

    func apply(_ gain: [Float], to s: Spectrum) {
        s.re[0] *= gain[0]
        s.im[0] *= gain[half]
        gain.withUnsafeBufferPointer { g in
            vDSP_vmul(s.re + 1, 1, g.baseAddress! + 1, 1, s.re + 1, 1, vDSP_Length(half - 1))
            vDSP_vmul(s.im + 1, 1, g.baseAddress! + 1, 1, s.im + 1, 1, vDSP_Length(half - 1))
        }
    }

    /// Inverse-transforms `s`, windows it again and overlap-adds it at `start`. Call `normalize` once at the end.
    func inverse(_ s: Spectrum, start: Int, addTo out: UnsafeMutableBufferPointer<Float>) {
        var split = DSPSplitComplex(realp: s.re, imagp: s.im)
        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Inverse))
        frame.withUnsafeMutableBufferPointer { f in
            f.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { vDSP_ztoc(&split, 1, $0, 2, vDSP_Length(half)) }
        }
        vDSP.multiply(1 / Float(2 * size), frame, result: &frame)
        vDSP.multiply(frame, window, result: &frame)
        let lo = max(0, start), hi = min(out.count, start + size)
        guard hi > lo else { return }
        frame.withUnsafeBufferPointer { f in
            vDSP_vadd(out.baseAddress! + lo, 1, f.baseAddress! + (lo - start), 1, out.baseAddress! + lo, 1, vDSP_Length(hi - lo))
        }
    }

    /// Divides out the summed squared window, which every sample sees in full because frames start a hop before 0.
    func normalize(_ out: UnsafeMutableBufferPointer<Float>) {
        var scale = Float(hop) / vDSP.sumOfSquares(window)
        vDSP_vsmul(out.baseAddress!, 1, &scale, out.baseAddress!, 1, vDSP_Length(out.count))
    }
}
