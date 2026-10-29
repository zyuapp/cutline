import Accelerate
import AVFoundation
import CutlineCore
import Foundation

/// Lines up recordings of the same event by their sound (multicam sync), using GCC-PHAT.
public enum AudioSync {
    static let sampleRate = 8_000.0
    /// Only the start of each file is compared.
    static let window: Seconds = 300

    /// The shift between two recordings: the sound at reference time t is at other time t + offset,
    /// so other synced to the reference starts at reference start − offset.
    /// Confidence (0…1) grows with how far the correlation peak stands above the runner-up; below ~0.5 is unreliable.
    public static func offset(reference: URL, other: URL, maxOffset: Seconds = 60) async throws -> (offset: Seconds, confidence: Double) {
        async let a = decode(reference)
        async let b = decode(other)
        let (r, o) = try await (a, b)
        let result = offset(reference: r, other: o, sampleRate: sampleRate, maxOffset: maxOffset)
        return (result.0, result.1)
    }

    /// `offset(reference:other:maxOffset:)` on mono samples.
    public static func offset(reference: [Float], other: [Float], sampleRate: Double, maxOffset: Seconds) -> (Seconds, Double) {
        guard reference.count > 2, other.count > 2, sampleRate > 0 else { return (0, 0) }
        let maxLag = max(1, min(Int(maxOffset * sampleRate), max(reference.count, other.count) - 1))
        let log2n = vDSP_Length(ceil(log2(Double(max(reference.count, other.count) + maxLag + 1))))
        let n = 1 << Int(log2n)
        let half = n / 2
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return (0, 0) }
        defer { vDSP_destroy_fftsetup(setup) }

        var (rRe, rIm) = spectrum(reference, n: n, log2n: log2n, setup: setup)
        var (oRe, oIm) = spectrum(other, n: n, log2n: log2n, setup: setup)
        var cRe = [Float](repeating: 0, count: half)
        var cIm = [Float](repeating: 0, count: half)
        var corr = [Float](repeating: 0, count: n)
        rRe.withUnsafeMutableBufferPointer { rr in rIm.withUnsafeMutableBufferPointer { ri in
            oRe.withUnsafeMutableBufferPointer { or in oIm.withUnsafeMutableBufferPointer { oi in
                cRe.withUnsafeMutableBufferPointer { cr in cIm.withUnsafeMutableBufferPointer { ci in
                    var r = DSPSplitComplex(realp: rr.baseAddress!, imagp: ri.baseAddress!)
                    var o = DSPSplitComplex(realp: or.baseAddress!, imagp: oi.baseAddress!)
                    var c = DSPSplitComplex(realp: cr.baseAddress!, imagp: ci.baseAddress!)
                    // conj(R)·O peaks at the lag τ where other[t + τ] matches reference[t].
                    vDSP_zvcmul(&r, 1, &o, 1, &c, 1, vDSP_Length(half))
                    // PHAT: keep only the phase of each bin.
                    var mag = [Float](repeating: 0, count: half)
                    vDSP_zvabs(&c, 1, &mag, 1, vDSP_Length(half))
                    var mean: Float = 0
                    vDSP_meanv(mag, 1, &mean, vDSP_Length(half))
                    var eps = max(mean * 1e-3, 1e-20)
                    vDSP_vsadd(mag, 1, &eps, &mag, 1, vDSP_Length(half))
                    vDSP_vdiv(mag, 1, cr.baseAddress!, 1, cr.baseAddress!, 1, vDSP_Length(half))
                    vDSP_vdiv(mag, 1, ci.baseAddress!, 1, ci.baseAddress!, 1, vDSP_Length(half))
                    // DC and Nyquist share bin 0 in the packed format.
                    cr[0] = 0
                    ci[0] = 0
                    vDSP_fft_zrip(setup, &c, 1, log2n, FFTDirection(kFFTDirection_Inverse))
                    corr.withUnsafeMutableBytes { raw in
                        vDSP_ztoc(&c, 1, raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, vDSP_Length(half))
                    }
                }}
            }}
        }}

        func value(_ lag: Int) -> Float { corr[lag >= 0 ? lag : n + lag] }
        var best = 0
        var peak: Float = -1
        for lag in -maxLag...maxLag where abs(value(lag)) > peak {
            peak = abs(value(lag))
            best = lag
        }
        guard peak > 0 else { return (0, 0) }
        let exclusion = max(2, Int(0.005 * sampleRate))
        var second: Float = 0
        for lag in -maxLag...maxLag where abs(lag - best) > exclusion {
            second = max(second, abs(value(lag)))
        }

        var refined = Double(best)
        if best > -maxLag && best < maxLag {
            let sign: Float = value(best) < 0 ? -1 : 1
            let a = Double(sign * value(best - 1)), b = Double(sign * value(best)), c = Double(sign * value(best + 1))
            let denom = a - 2 * b + c
            if abs(denom) > 1e-12 { refined += min(max(0.5 * (a - c) / denom, -0.5), 0.5) }
        }
        let ratio = Double(peak / max(second, peak * 1e-6))
        let confidence = min(max(1 - exp(-(ratio - 1)), 0), 1)
        return (refined / sampleRate, confidence)
    }

    /// Mean-removed, zero-padded FFT in vDSP's packed split format.
    static func spectrum(_ x: [Float], n: Int, log2n: vDSP_Length, setup: FFTSetup) -> ([Float], [Float]) {
        var padded = [Float](repeating: 0, count: n)
        var mean: Float = 0
        vDSP_meanv(x, 1, &mean, vDSP_Length(x.count))
        var negMean = -mean
        padded.withUnsafeMutableBufferPointer { p in
            vDSP_vsadd(x, 1, &negMean, p.baseAddress!, 1, vDSP_Length(x.count))
        }
        var re = [Float](repeating: 0, count: n / 2)
        var im = [Float](repeating: 0, count: n / 2)
        re.withUnsafeMutableBufferPointer { rp in
            im.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                padded.withUnsafeBytes { raw in
                    vDSP_ctoz(raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(n / 2))
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
            }
        }
        return (re, im)
    }

    /// The first `window` seconds of the first audio track as 8 kHz mono.
    static func decode(_ url: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw EditError("\(url.lastPathComponent) has no audio")
        }
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: window, preferredTimescale: 600))
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
        guard reader.startReading() else { throw reader.error ?? EditError("Cannot read audio of \(url.lastPathComponent)") }
        let limit = Int(window * sampleRate)
        var samples: [Float] = []
        samples.reserveCapacity(limit)
        while samples.count < limit, let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            var length = 0
            var ptr: UnsafeMutablePointer<CChar>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &ptr) == noErr, let ptr else { continue }
            let count = min(length / MemoryLayout<Float>.size, limit - samples.count)
            ptr.withMemoryRebound(to: Float.self, capacity: count) { samples.append(contentsOf: UnsafeBufferPointer(start: $0, count: count)) }
        }
        if reader.status == .failed { throw reader.error ?? EditError("Audio decode failed for \(url.lastPathComponent)") }
        reader.cancelReading()
        return samples
    }
}
