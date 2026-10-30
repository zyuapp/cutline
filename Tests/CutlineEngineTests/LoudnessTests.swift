import Foundation
import Testing
import CutlineCore
@testable import CutlineEngine

@Test func referenceSineReadsMinus23LUFS() {
    // EBU Tech 3341: a stereo 1 kHz sine at −23 dBFS peak measures −23.0 LUFS.
    let amp = Float(pow(10, -23.0 / 20))
    let frames = 48_000 * 10
    var samples = [Float](repeating: 0, count: frames * 2)
    for i in 0..<frames {
        let v = amp * sin(2 * .pi * 1000 * Float(i) / 48_000)
        samples[2 * i] = v
        samples[2 * i + 1] = v
    }
    var acc = LoudnessMeter.Accumulator()
    samples.withUnsafeBufferPointer { acc.feed($0.baseAddress!, frames) }
    let r = acc.report()
    #expect(abs(r.integrated - -23) < 0.2, "integrated \(r.integrated)")
    #expect(abs(r.peakDb - -23) < 0.1)
    #expect(r.range < 0.5)
}

private func truePeak(_ x: [[Float]]) -> LoudnessReport {
    let n = x[0].count
    var inter = [Float](repeating: 0, count: n * 2)
    for i in 0..<n { inter[2 * i] = x[0][i]; inter[2 * i + 1] = x[1][i] }
    var acc = LoudnessMeter.Accumulator()
    inter.withUnsafeBufferPointer { acc.feed($0.baseAddress!, n) }
    return acc.report()
}

@Test func theLimiterHoldsTruePeaksUnderItsCeiling() throws {
    // A sine at a quarter of the rate, 45° off the samples: samples read 0.95 but the wave peaks at 1.34 (+2.6 dBTP).
    let n = 48_000 * 2
    let wave = (0..<n).map { i in Float(0.95 * 2.0.squareRoot()) * sin(.pi / 2 * Float(i) + .pi / 4) }
    let x = [wave, wave]
    #expect(truePeak(x).truePeakDb > 2)
    let limiter = Effect(id: "l", type: "audio.limiter")
    let y = try #require(AudioDSP.apply(limiter, to: x, sampleRate: 48_000))
    #expect(y[0].count == n)
    let r = truePeak(y)
    #expect(r.truePeakDb <= -0.9, "true peak \(r.truePeakDb) dBTP")
    #expect(r.truePeakDb > -2, "limited too hard: \(r.truePeakDb) dBTP")
    // Sound under the ceiling passes untouched and in time.
    let quiet = [wave.map { $0 * 0.3 }, wave.map { $0 * 0.3 }]
    let same = try #require(AudioDSP.apply(limiter, to: quiet, sampleRate: 48_000))
    #expect(zip(same[0], quiet[0]).allSatisfy { abs($0 - $1) < 1e-5 })
}
