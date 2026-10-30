import Accelerate
import AVFoundation
import CutlineCore
import Foundation

/// What export did to meet the master's loudness target: the mix as measured, the gain applied, and the result.
public struct LoudnessConform: Sendable {
    public var target: Double
    public var ceiling: Double
    public var before: LoudnessReport
    public var after: LoudnessReport
    public var gainDb: Double
    /// Largest gain reduction the true-peak limiter applied, in dB (0 when it never acted).
    public var limitedDb: Double

    public var summary: String {
        func f(_ v: Double) -> String { v.isFinite && v > -150 ? String(format: "%.1f", v) : "silent" }
        let gated = before.dialogue != nil
        let unit = gated ? "LUFS dialogue-gated" : "LUFS"
        var s = "Loudness target \(f(target)) \(unit) / \(f(ceiling)) dBTP: mix measured \(f(before.gatedIntegrated)) \(unit), \(f(before.truePeakDb)) dBTP"
        guard before.integrated.isFinite else { return s + "; silent, left as it is" }
        s += String(format: "; applied %+.1f dB", gainDb)
        if limitedDb > 0.05 { s += String(format: ", limiter up to %.1f dB", limitedDb) }
        return s + "; delivered \(f(after.gatedIntegrated)) \(unit)" + (gated ? " (\(f(after.integrated)) LUFS overall)" : "") + ", \(f(after.truePeakDb)) dBTP"
    }

    /// Gains `frames` of `source` (48 kHz float in `layout`) to `target` LUFS with a look-ahead true-peak limiter at
    /// `ceiling` dBTP, writing a float CAF of exactly that many frames. Limiting costs loudness, so the gain is
    /// re-measured and corrected up to three times. With `dialogue` (spans in source-file time) the target is
    /// dialogue-gated: met by the loudness of the blocks where dialogue plays.
    public static func run(_ source: URL, layout: AudioLayout, frames: Range<Int64>, target: Double, ceiling: Double, dialogue: [TimeRange]? = nil, to url: URL) async throws -> LoudnessConform {
        try await runBlocking { _ in try conform(source, layout: layout, frames: frames, target: target, ceiling: ceiling, dialogue: dialogue, to: url) }
    }

    static func conform(_ source: URL, layout: AudioLayout, frames: Range<Int64>, target: Double, ceiling: Double, dialogue: [TimeRange]? = nil, to url: URL) throws -> LoudnessConform {
        let rate = AudioStems.sampleRate
        let before = try LoudnessMeter.measure(file: source, layout: layout, range: TimeRange(Double(frames.lowerBound) / rate, Double(frames.upperBound) / rate), dialogue: dialogue)
        // The written file starts at the first conformed frame.
        let origin = Double(frames.lowerBound) / rate
        let gate = dialogue.map { $0.map { TimeRange($0.start - origin, $0.end - origin) } }
        guard before.integrated.isFinite else {
            try pass(source, layout: layout, frames: frames, gain: 1, ceiling: nil, to: url)
            return LoudnessConform(target: target, ceiling: ceiling, before: before, after: before, gainDb: 0, limitedDb: 0)
        }
        var gainDb = min(40, max(-60, target - before.gatedIntegrated))
        // The limiter holds sample-and-interpolated peaks a little under the ceiling.
        var limit = ceiling - 0.2
        var result = (after: before, limited: 0.0)
        var applied = gainDb
        for _ in 0..<4 {
            applied = gainDb
            result = try pass(source, layout: layout, frames: frames, gain: pow(10, gainDb / 20), ceiling: pow(10, limit / 20), gate: gate, to: url)
            let off = target - result.after.gatedIntegrated
            let over = result.after.truePeakDb - ceiling
            if abs(off) <= 0.2 && over <= 0.05 { break }
            if over > 0.05 { limit -= over + 0.05 }
            if abs(off) > 0.2 { gainDb = min(40, max(-60, gainDb + off)) }
        }
        return LoudnessConform(target: target, ceiling: ceiling, before: before, after: result.after, gainDb: applied, limitedDb: result.limited)
    }

    /// One gain-and-limit pass, measuring what it writes.
    @discardableResult
    static func pass(_ source: URL, layout: AudioLayout, frames: Range<Int64>, gain: Double, ceiling: Double?, gate: [TimeRange]? = nil, to url: URL) throws -> (after: LoudnessReport, limited: Double) {
        let n = layout.channelCount
        try? FileManager.default.removeItem(at: url)
        let settings = layout == .stereo ? AudioIO.format.settings : layout.floatFileSettings
        let output = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let input = try AVAudioFile(forReading: source)
        var acc = LoudnessMeter.Accumulator(layout: layout)
        var limiter = ceiling.map { TruePeakLimiter(channels: n, ceiling: Float($0)) }
        let identity = (0..<n).map { o in (0..<n).map { $0 == o ? 1.0 : 0 } }
        let g = Float(gain)
        func emit(_ y: [[Float]]) throws {
            let count = y.first?.count ?? 0
            guard count > 0 else { return }
            var interleaved = [Float](repeating: 0, count: count * n)
            for c in 0..<n { for i in 0..<count { interleaved[i * n + c] = y[c][i] } }
            interleaved.withUnsafeBufferPointer { acc.feed($0.baseAddress!, count) }
            try AudioIO.write(y, to: output)
        }
        try AudioIO.remix(input, matrix: identity, frames: frames) { x in
            let gained = x.map { ch in ch.map { $0 * g } }
            try emit(limiter == nil ? gained : limiter!.process(gained))
        }
        if limiter != nil { try emit(limiter!.flush()) }
        output.close()
        return (acc.report(gate: gate), limiter.map { -20 * log10(Double(max($0.minGain, 1e-6))) } ?? 0)
    }
}

/// Look-ahead peak limiter on sample and 4× interpolated peaks: the gain needed at each frame is held over a
/// window ahead of it, released over 50 ms and smoothed by a box filter, so peaks are caught without overshoot.
/// The output is delayed by the look-ahead, which `flush` drains.
struct TruePeakLimiter {
    let channels: Int
    let ceiling: Float
    static let half = 32
    let window = 2 * TruePeakLimiter.half
    let release: Float = 1 - exp(-1 / Float(0.05 * AudioStems.sampleRate))
    /// The last 11 input samples per channel, oldest first, for the interpolation filter.
    var history: [[Float]]
    /// Delayed input, one ring per channel.
    var delay: [[Float]]
    var written = 0
    /// Monotonic queue of (frame, required gain) for the running minimum over the window.
    var queue: [(Int, Float)] = []
    var released: Float = 1
    var box: [Float]
    var boxSum: Double
    var boxAt = 0
    var minGain: Float = 1

    init(channels: Int, ceiling: Float) {
        self.channels = channels
        self.ceiling = ceiling
        history = [[Float]](repeating: [Float](repeating: 0, count: 11), count: channels)
        delay = [[Float]](repeating: [Float](repeating: 0, count: 2 * TruePeakLimiter.half - 1), count: channels)
        box = [Float](repeating: 1, count: TruePeakLimiter.half)
        boxSum = Double(TruePeakLimiter.half)
    }

    /// Taps of the 4× interpolation filter, reversed for `vDSP_conv`.
    static let taps: [[Float]] = LoudnessMeter.Accumulator.phases.map { $0.reversed().map(Float.init) }

    /// The largest sample or interpolated magnitude across channels at each frame.
    mutating func peaks(_ x: [[Float]], _ n: Int) -> [Float] {
        var peak = [Float](repeating: 0, count: n)
        for c in 0..<channels {
            let input = c < x.count ? x[c] : [Float](repeating: 0, count: n)
            peak = vDSP.maximum(peak, vDSP.absolute(input))
            let ext = history[c] + input
            for taps in TruePeakLimiter.taps {
                var y = [Float](repeating: 0, count: n)
                vDSP_conv(ext, 1, taps, 1, &y, 1, vDSP_Length(n), vDSP_Length(taps.count))
                peak = vDSP.maximum(peak, vDSP.absolute(y))
            }
            history[c] = Array(ext.suffix(11))
        }
        return peak
    }

    mutating func process(_ x: [[Float]]) -> [[Float]] {
        let n = x.first?.count ?? 0
        guard n > 0 else { return [[Float]](repeating: [], count: channels) }
        let peak = peaks(x, n)
        var y = [[Float]](repeating: [Float](repeating: 0, count: n), count: channels)
        var out = 0
        let d = window - 1
        for i in 0..<n {
            let need = peak[i] > ceiling ? ceiling / peak[i] : 1
            let frame = written
            while let last = queue.last, last.1 >= need { queue.removeLast() }
            queue.append((frame, need))
            if let first = queue.first, first.0 <= frame - window { queue.removeFirst() }
            let slot = frame % d
            written += 1
            guard frame >= d else {
                for c in 0..<channels { delay[c][slot] = c < x.count ? x[c][i] : 0 }
                continue
            }
            // The minimum over the window ending now applies to the frame leaving the delay line.
            released = min(queue.first!.1, released + (1 - released) * release)
            boxSum += Double(released) - Double(box[boxAt])
            box[boxAt] = released
            boxAt = (boxAt + 1) % box.count
            let gain = min(1, Float(boxSum / Double(box.count)))
            minGain = min(minGain, gain)
            for c in 0..<channels {
                y[c][out] = delay[c][slot] * gain
                delay[c][slot] = c < x.count ? x[c][i] : 0
            }
            out += 1
        }
        return y.map { Array($0.prefix(out)) }
    }

    /// Drains the delay line with silence after the last input.
    mutating func flush() -> [[Float]] {
        process([[Float]](repeating: [Float](repeating: 0, count: window - 1), count: channels))
    }
}
