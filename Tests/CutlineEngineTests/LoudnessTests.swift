import Foundation
import Testing
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
