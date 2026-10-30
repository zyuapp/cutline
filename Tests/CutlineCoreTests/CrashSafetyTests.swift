@testable import CutlineCore
import Foundation
import Testing

/// Levels at 100/s: loud, with quiet runs of `quiet` samples between loud runs of `loud` samples.
private func choppy(quiet: Int, loud: Int, count: Int) -> AudioAnalysis {
    var levels: [Float] = []
    while levels.count < count {
        levels += Array(repeating: -20, count: loud)
        levels += Array(repeating: -60, count: quiet)
    }
    return AudioAnalysis(mediaId: "m", levelRate: 100, levels: Array(levels.prefix(count)), silences: [], silenceThresholdDb: -50, loudnessDb: -23)
}

@Test func roomToneSpanSurvivesRunsShorterThanItsMargins() {
    for quiet in 1...25 {
        let a = choppy(quiet: quiet, loud: 7, count: 3000)
        let span = a.roomToneSpan()
        if let span { #expect(span.range.duration >= 0.5 - 1e-9) }
        _ = a.roomToneSpan(minLength: 0, maxLength: 0)
        _ = a.roomToneSpan(within: TimeRange(10.1, 11.7))
        _ = a.roomToneSpan(within: TimeRange(.nan, .infinity))
    }
    let steady = choppy(quiet: 200, loud: 5, count: 3000)
    #expect(steady.roomToneSpan() != nil)
}

@Test func saturatingIntConversion() {
    #expect(Int(saturating: .nan) == 0)
    #expect(Int(saturating: .infinity) == .max)
    #expect(Int(saturating: -.infinity) == .min)
    #expect(Int(saturating: 1e300) == .max)
    #expect(Int(saturating: -2.7) == -2)
}

@Test func timeHelpersDoNotTrapOnHugeOrNonFiniteInput() {
    let f = TimecodeFormat(fps: 25)
    #expect(f.frameCount(.nan) == 0)
    #expect(f.frameCount(1e300) == .max)
    #expect(f.seconds(.max) > 0)
    #expect(Project.timecode("99999999999999999:00:00:00", fps: 25) == nil)
    #expect(Project.timecode("01:00:00:00", fps: 25) == 3600)
    #expect(Project.timecode("00:01:00;02", fps: 29.97).map { abs($0 - 60.06) < 0.01 } == true)
    _ = Project.timecodeString(.nan, fps: 25)
    _ = Project.timecodeString(1e300, fps: 25)
}

@Test func expressionsThatBlowUpEvaluateToNoValue() {
    var c = Curve(keys: [CurveKey(t: 0, v: .number(.infinity), ease: .linear)])
    #expect(c.value(at: 0) == nil)
    c = Curve(keys: [CurveKey(t: 0, v: .number(2), ease: .linear)])
    #expect(c.value(at: 0) == .number(2))
}

@Test func particlesWithAbsurdParametersStayBounded() {
    let values: [String: ParamValue] = ["rate": .number(1e12), "lifetime": .number(1e12), "lifetime_random": .number(.nan), "burst": .number(.infinity), "seed": .number(1e30), "size": .number(0.01)]
    let out = ParticleSystem.particles(at: 5, width: 320, height: 180) { k, _ in values[k] ?? .number(0) }
    #expect(out.count <= 60_000)
}

@Test func svgArcsWithHugeNumbersDoNotTrap() {
    #expect(throws: EditError.self) { _ = try ShapePath.svg("M0 0 A1e999 1 0 0 1 1 1") }
    _ = ShapePath.arc(from: PathPoint(0, 0), to: PathPoint(1e300, -1e300), rx: 1e-300, ry: 1e300, rotation: 0, large: true, sweep: false)
}
