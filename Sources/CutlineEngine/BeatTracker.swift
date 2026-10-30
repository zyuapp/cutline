import Accelerate
import AVFoundation
import CutlineCore
import Foundation

/// Tempo, beat, downbeat and onset detection: spectral-flux onsets, autocorrelation tempo
/// and dynamic-programming beat tracking (Ellis 2007).
public enum BeatTracker {
    static let sampleRate = 22_050.0
    static let minBPM = 60.0
    static let maxBPM = 200.0
    /// Ellis's transition tightness; higher keeps beats closer to the period.
    static let tightness: Float = 100
    /// Hops by which the flux peak of a centered frame leads its onset.
    static let fluxLead = 0.4

    /// Decodes the first audio track to 22.05 kHz mono and analyzes it.
    public static func analyze(url: URL, mediaId: String) async throws -> BeatAnalysis {
        let samples = try await decodeMono(url: url, mediaId: mediaId)
        return analyze(samples: samples, sampleRate: sampleRate, mediaId: mediaId)
    }

    /// Analyzes mono samples. Silent input yields tempo 0 and no beats.
    public static func analyze(samples: [Float], sampleRate: Double, mediaId: String) -> BeatAnalysis {
        var result = BeatAnalysis(mediaId: mediaId, tempo: 0, beats: [], downbeats: [], onsets: [], energy: [])
        // ~46 ms frames (1024 at 22.05 kHz), ~11.6 ms hops.
        let log2n = min(14, max(8, Int((log2(sampleRate * 1024 / 22_050)).rounded())))
        let hop = (1 << log2n) / 4
        let fps = sampleRate / Double(hop)
        guard samples.count >= 1 << log2n, rms(samples[...]) > 1e-4 else { return result }

        let env = onsetEnvelope(samples, log2n: log2n, hop: hop)
        guard let peak = env.max(), peak > 0 else { return result }
        let toTime = { (frame: Double) in max(0, (frame + fluxLead) / fps) }

        result.onsets = pickOnsets(env, fps: fps).map { toTime(Double($0)) }
        guard let period = estimatePeriod(env, fps: fps) else { return result }
        result.tempo = 60 * fps / period

        let (frames, strength) = trackBeats(env, period: period)
        guard !frames.isEmpty else { return result }
        let beats = frames.map(toTime)
        result.beats = beats
        if let phase = downbeatPhase(strength: strength) {
            result.downbeats = stride(from: phase, to: beats.count, by: 4).map { beats[$0] }
        }
        result.energy = beatEnergy(samples, sampleRate: sampleRate, beats: beats)
        return result
    }

    // MARK: Onset strength

    /// Log-magnitude spectral flux, high-passed, half-wave rectified, smoothed and scaled to max 1.
    static func onsetEnvelope(_ x: [Float], log2n: Int, hop: Int) -> [Float] {
        let n = 1 << log2n, half = n / 2
        let frames = x.count / hop + 1
        guard let setup = vDSP_create_fftsetup(vDSP_Length(log2n), FFTRadix(kFFTRadix2)) else { return [] }
        defer { vDSP_destroy_fftsetup(setup) }

        // Frame f is centered on sample f * hop.
        var padded = [Float](repeating: 0, count: x.count + n)
        padded.replaceSubrange(half..<(half + x.count), with: x)
        var window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))

        let frame = UnsafeMutablePointer<Float>.allocate(capacity: n)
        let re = UnsafeMutablePointer<Float>.allocate(capacity: half)
        let im = UnsafeMutablePointer<Float>.allocate(capacity: half)
        var spec = UnsafeMutablePointer<Float>.allocate(capacity: half)
        var prev = UnsafeMutablePointer<Float>.allocate(capacity: half)
        let diff = UnsafeMutablePointer<Float>.allocate(capacity: half)
        defer { [frame, re, im, spec, prev, diff].forEach { $0.deallocate() } }

        var flux = [Float](repeating: 0, count: frames)
        var split = DSPSplitComplex(realp: re, imagp: im)
        var gain: Float = 1000 / Float(n)
        var zero: Float = 0
        var count = Int32(half)
        padded.withUnsafeBufferPointer { src in
            for f in 0..<frames {
                vDSP_vmul(src.baseAddress! + f * hop, 1, window, 1, frame, 1, vDSP_Length(n))
                frame.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                    vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                }
                vDSP_fft_zrip(setup, &split, 1, vDSP_Length(log2n), FFTDirection(FFT_FORWARD))
                im[0] = 0
                vDSP_zvabs(&split, 1, spec, 1, vDSP_Length(half))
                vDSP_vsmul(spec, 1, &gain, spec, 1, vDSP_Length(half))
                vvlog1pf(spec, spec, &count)
                if f > 0 {
                    vDSP_vsub(prev, 1, spec, 1, diff, 1, vDSP_Length(half))
                    vDSP_vthres(diff, 1, &zero, diff, 1, vDSP_Length(half))
                    vDSP_sve(diff, 1, &flux[f], vDSP_Length(half))
                }
                swap(&spec, &prev)
            }
        }

        // Remove the slowly varying floor (~0.5 s), rectify, then smooth with a 5-tap Gaussian.
        let floor = movingAverage(flux, radius: 20)
        var hp = [Float](repeating: 0, count: frames)
        vDSP_vsub(floor, 1, flux, 1, &hp, 1, vDSP_Length(frames))
        vDSP_vthres(hp, 1, &zero, &hp, 1, vDSP_Length(frames))
        var env = symmetricSmooth(hp, kernel: [0.054, 0.244, 0.403, 0.244, 0.054])
        var peak: Float = 0
        vDSP_maxv(env, 1, &peak, vDSP_Length(frames))
        if peak > 0 {
            var scale = 1 / peak
            vDSP_vsmul(env, 1, &scale, &env, 1, vDSP_Length(frames))
        }
        return env
    }

    /// Mean over `[i - radius, i + radius]`, clipped at the edges.
    static func movingAverage(_ x: [Float], radius: Int) -> [Float] {
        var prefix = [Double](repeating: 0, count: x.count + 1)
        for i in 0..<x.count { prefix[i + 1] = prefix[i] + Double(x[i]) }
        return (0..<x.count).map { i in
            let lo = max(0, i - radius), hi = min(x.count, i + radius + 1)
            return Float((prefix[hi] - prefix[lo]) / Double(hi - lo))
        }
    }

    /// Zero-phase convolution with an odd-length kernel, zero-padded.
    static func symmetricSmooth(_ x: [Float], kernel: [Float]) -> [Float] {
        let r = kernel.count / 2
        var padded = [Float](repeating: 0, count: x.count + 2 * r)
        padded.replaceSubrange(r..<(r + x.count), with: x)
        var out = [Float](repeating: 0, count: x.count)
        vDSP_conv(padded, 1, kernel, 1, &out, 1, vDSP_Length(x.count), vDSP_Length(kernel.count))
        return out
    }

    /// Local maxima within ±30 ms that exceed the ±100 ms mean by 0.07, at least 50 ms apart.
    static func pickOnsets(_ env: [Float], fps: Double) -> [Int] {
        let maxR = max(1, Int((0.03 * fps).rounded()))
        let avg = movingAverage(env, radius: max(1, Int((0.1 * fps).rounded())))
        let wait = Int((0.05 * fps).rounded())
        var out: [Int] = []
        for i in 0..<env.count where env[i] >= avg[i] + 0.07 {
            let lo = max(0, i - maxR), hi = min(env.count - 1, i + maxR)
            var isMax = true
            for j in lo...hi where env[j] > env[i] || (env[j] == env[i] && j < i) { isMax = false; break }
            guard isMax else { continue }
            if let last = out.last, i - last < wait { continue }
            out.append(i)
        }
        return out
    }

    // MARK: Tempo

    /// Beat period in frames: the autocorrelation peak of the onset envelope weighted by a
    /// log-Gaussian prior centered on 120 BPM (σ = 1 octave), searched within 60…200 BPM.
    static func estimatePeriod(_ env: [Float], fps: Double) -> Double? {
        let minLag = max(1, Int(floor(60 * fps / maxBPM)))
        let maxLag = Int(ceil(60 * fps / minBPM))
        guard env.count > maxLag + 2 else { return nil }
        var mean: Float = 0
        vDSP_meanv(env, 1, &mean, vDSP_Length(env.count))
        var negMean = -mean
        var centered = [Float](repeating: 0, count: env.count)
        vDSP_vsadd(env, 1, &negMean, &centered, 1, vDSP_Length(env.count))

        var weighted = [Double](repeating: -.infinity, count: maxLag + 2)
        centered.withUnsafeBufferPointer { e in
            for lag in (minLag - 1)...(maxLag + 1) where lag > 0 {
                var dot: Float = 0
                vDSP_dotpr(e.baseAddress!, 1, e.baseAddress! + lag, 1, &dot, vDSP_Length(env.count - lag))
                let bpm = 60 * fps / Double(lag)
                let prior = exp(-0.5 * pow(log2(bpm / 120), 2))
                weighted[lag] = Double(dot) / Double(env.count - lag) * prior
            }
        }
        var best = -1
        for lag in minLag...maxLag where 60 * fps / Double(lag) >= minBPM && 60 * fps / Double(lag) <= maxBPM {
            if best < 0 || weighted[lag] > weighted[best] { best = lag }
        }
        guard best > 0, weighted[best] > 0 else { return nil }
        let a = weighted[best - 1], b = weighted[best], c = weighted[best + 1]
        let denom = a - 2 * b + c
        let shift = denom < 0 && a.isFinite && c.isFinite ? 0.5 * (a - c) / denom : 0
        return Double(best) + min(0.5, max(-0.5, shift))
    }

    // MARK: Beats

    /// Dynamic-programming beat tracking. Returns fractional beat frames and the onset
    /// strength at each beat.
    static func trackBeats(_ env: [Float], period: Double) -> (frames: [Double], strength: [Float]) {
        let n = env.count
        var mean: Float = 0, std: Float = 0
        vDSP_normalize(env, 1, nil, 1, &mean, &std, vDSP_Length(n))
        guard std > 0 else { return ([], []) }

        // Local score: onset strength / std smoothed by a Gaussian of width period / 32.
        let sigma = max(0.5, period / 32)
        let radius = max(1, Int(ceil(3 * sigma)))
        let kernel = (-radius...radius).map { Float(exp(-0.5 * pow(Double($0) / sigma, 2))) }
        var local = symmetricSmooth(env, kernel: kernel)
        var inv = 1 / std
        vDSP_vsmul(local, 1, &inv, &local, 1, vDSP_Length(n))

        let lo = max(1, Int((period / 2).rounded()))
        let hi = max(lo, Int((period * 2).rounded()))
        let cost = (0...hi).map { d -> Float in
            d < lo ? 0 : -tightness * Float(pow(log(Double(d) / period), 2))
        }
        var cum = [Float](repeating: 0, count: n)
        var back = [Int](repeating: -1, count: n)
        cum.withUnsafeMutableBufferPointer { cum in
            back.withUnsafeMutableBufferPointer { back in
                for t in 0..<n {
                    var best = -Float.infinity, bi = -1
                    if t >= lo {
                        for d in lo...min(hi, t) {
                            let s = cum[t - d] + cost[d]
                            if s > best { best = s; bi = t - d }
                        }
                    }
                    // A chain that only loses score starts afresh here.
                    if bi >= 0 && best > 0 {
                        cum[t] = local[t] + best
                        back[t] = bi
                    } else {
                        cum[t] = local[t]
                    }
                }
            }
        }

        // Cumulative score only grows along a beat chain, so its maximum ends the best chain.
        var top: Float = 0
        var topIndex: vDSP_Length = 0
        vDSP_maxvi(cum, 1, &top, &topIndex, vDSP_Length(n))
        var b = Int(topIndex)

        var path: [Int] = []
        while b >= 0 {
            path.append(b)
            b = back[b]
        }
        path.reverse()

        // Trim weak leading and trailing beats, judged against the median so one loud transient can't make every other beat "weak".
        let sortedAtBeats = path.map { local[$0] }.sorted()
        let weak = 0.5 * sortedAtBeats[sortedAtBeats.count / 2]
        guard let first = path.firstIndex(where: { local[$0] > weak }),
              let last = path.lastIndex(where: { local[$0] > weak }) else { return ([], []) }
        path = Array(path[first...last])

        let frames = path.map { t -> Double in
            guard t > 0, t < n - 1 else { return Double(t) }
            let a = local[t - 1], c = local[t + 1], m = local[t]
            let denom = a - 2 * m + c
            return Double(t) + (denom < 0 ? Double(min(0.5, max(-0.5, 0.5 * (a - c) / denom))) : 0)
        }
        let strength = path.map { t in env[max(0, t - 1)...min(n - 1, t + 1)].max() ?? 0 }
        return (frames, strength)
    }

    /// Phase 0…3 whose every-4th beats have the highest mean onset strength.
    static func downbeatPhase(strength: [Float]) -> Int? {
        guard !strength.isEmpty else { return nil }
        var best = 0, bestScore = -Float.infinity
        for phase in 0..<min(4, strength.count) {
            let picks = stride(from: phase, to: strength.count, by: 4).map { strength[$0] }
            let score = picks.reduce(0, +) / Float(picks.count)
            if score > bestScore { best = phase; bestScore = score }
        }
        return best
    }

    /// RMS over each beat's span (midpoint to midpoint) in dB, mapped so the loudest beat is 1
    /// and 40 dB below it is 0.
    static func beatEnergy(_ x: [Float], sampleRate: Double, beats: [Double]) -> [Float] {
        guard !beats.isEmpty else { return [] }
        let dbs = beats.indices.map { i -> Float in
            let left = i > 0 ? (beats[i] - beats[i - 1]) / 2 : (beats.count > 1 ? (beats[1] - beats[0]) / 2 : 0.25)
            let right = i < beats.count - 1 ? (beats[i + 1] - beats[i]) / 2 : left
            let s = max(0, min(x.count, Int((beats[i] - left) * sampleRate)))
            let e = max(s, min(x.count, Int((beats[i] + right) * sampleRate)))
            return 20 * log10(max(rms(x[s..<e]), 1e-6))
        }
        let top = dbs.max() ?? 0
        return dbs.map { min(1, max(0, 1 + ($0 - top) / 40)) }
    }

    static func rms(_ x: ArraySlice<Float>) -> Float {
        guard !x.isEmpty else { return 0 }
        var out: Float = 0
        x.withUnsafeBufferPointer { vDSP_rmsqv($0.baseAddress!, 1, &out, vDSP_Length($0.count)) }
        return out
    }

    // MARK: Decoding

    static func decodeMono(url: URL, mediaId: String) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw EditError("\(mediaId) has no audio")
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? EditError("Cannot read audio of \(mediaId)") }

        let expected = (try? await asset.load(.duration)).map { $0.seconds.isFinite ? Int($0.seconds * sampleRate) + 1 : 0 } ?? 0
        let samples = try await runBlocking { _ -> [Float] in
            var samples: [Float] = []
            samples.reserveCapacity(expected)
            while let buffer = output.copyNextSampleBuffer() {
                guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
                var length = 0
                var ptr: UnsafeMutablePointer<CChar>?
                guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &ptr) == noErr, let ptr else { continue }
                let n = length / MemoryLayout<Float>.size
                ptr.withMemoryRebound(to: Float.self, capacity: n) { samples.append(contentsOf: UnsafeBufferPointer(start: $0, count: n)) }
            }
            if reader.status == .failed { throw reader.error ?? EditError("Audio decode failed for \(mediaId)") }
            return samples
        }
        return samples
    }
}
