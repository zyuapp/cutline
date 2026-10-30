import Foundation
import simd
import Testing
@testable import CutlineCore

private func near(_ a: Float, _ b: Float, _ tol: Float) -> Bool { abs(a - b) <= tol }

/// 18% grey signal values from each vendor's specification, in the curve's own 0…1 convention.
private let midGrey: [LogProfile: Float] = [
    .apple_log: 0.4883,
    .slog3: 420 / 1023,
    .slog3_sgamut3: 420 / 1023,
    .logc3: 0.3910,
    .logc4: 0.2784,
    .vlog: 0.4233,
    .clog2: 0.3920,
    .clog3: 0.3434,
    .flog: 470 / 1023,
    .flog2: 0.3910,
    .nlog: 0.3637,
    .bmd_film_gen5: 0.3835,
    .redlog3g10: 1.0 / 3,
    .dlog: 0.3988,
]

@Test func logCurvesHitPublishedMidGrey() {
    #expect(midGrey.count == LogProfile.allCases.count)
    for p in LogProfile.allCases {
        let grey = midGrey[p]!
        #expect(near(p.fromLinear(0.18), grey, 0.0015), "\(p) encodes 18% to \(p.fromLinear(0.18)), expected \(grey)")
        #expect(near(p.toLinear(grey), 0.18, 0.003), "\(p) decodes \(grey) to \(p.toLinear(grey))")
    }
}

@Test func logCurvesHitPublishedBlackAndWhite() {
    // Sony: 0% black at CV 95, 90% white at CV 598.
    #expect(near(LogProfile.slog3.fromLinear(0) * 1023, 95, 0.1))
    #expect(near(LogProfile.slog3.fromLinear(0.9) * 1023, 598, 0.5))
    // Panasonic: 0% at 0.125, 90% white at 0.588 (61 IRE).
    #expect(near(LogProfile.vlog.fromLinear(0), 0.125, 1e-5))
    #expect(near(LogProfile.vlog.fromLinear(0.9), 0.5882, 0.001))
    // ARRI LogC3 EI800 black is 0.0928 (CV 95); LogC4 black is CV 95.
    #expect(near(LogProfile.logc3.fromLinear(0), 0.092809, 1e-5))
    #expect(near(LogProfile.logc4.fromLinear(0), 95.0 / 1023, 1e-4))
    // RED Log3G10: linear 0 sits at 0.0915 with the 0.01 offset.
    #expect(near(LogProfile.redlog3g10.fromLinear(0), 0.0915, 0.0005))
    // Apple Log black: c·R0².
    #expect(near(LogProfile.apple_log.fromLinear(0), 0.15048, 1e-4))
    // Canon Log 3 black: 12.5% IRE; Canon Log 2: 3.5%.
    #expect(near(LogProfile.clog3.fromLinear(0), 0.12512, 1e-4))
    #expect(near(LogProfile.clog2.fromLinear(0), 0.035388, 1e-5))
}

@Test func logCurvesRoundTripAndIncrease() {
    for p in LogProfile.allCases {
        for x: Float in [0, 0.002, 0.01, 0.05, 0.18, 0.5, 1, 4, 16] {
            let back = p.toLinear(p.fromLinear(x))
            #expect(abs(back - x) <= max(1e-4, x * 2e-3), "\(p) round trip \(x) → \(back)")
        }
        var last = -Float.infinity
        for i in 0...200 {
            let v = p.toLinear(Float(i) / 200)
            #expect(v > last, "\(p) decode is not increasing at \(i)")
            last = v
        }
    }
}

@Test func signalRangeConversion() {
    // S-Log3 grey recorded at CV 420 decodes through video range to (420 - 64) / 876.
    let decoded: Float = (420 - 64) / 876
    #expect(near(LogProfile.slog3.toLinear(decoded, recordedIn: .video), 0.18, 1e-3))
    #expect(near(LogProfile.clog3.toLinear(0.3434, recordedIn: .video), 0.18, 1e-3))
    #expect(near(SignalRange.full.convert(SignalRange.video.convert(0.3, to: .full), to: .video), 0.3, 1e-6))
}

@Test func pqAndHLG() {
    #expect(near(Transfer.pqEncode(nits: 100), 0.5081, 0.0005))
    #expect(near(Transfer.pqEncode(nits: 1000), 0.7518, 0.0005))
    #expect(near(Transfer.pqEncode(nits: 10_000), 1, 1e-5))
    for nits: Float in [0.01, 1, 26, 100, 203, 1000, 4000, 10_000] {
        #expect(abs(Transfer.pqDecode(Transfer.pqEncode(nits: nits)) - nits) <= nits * 1e-3)
    }
    #expect(near(Transfer.hlgOETF(1.0 / 12), 0.5, 1e-6))
    #expect(near(Transfer.hlgOETF(1), 1, 1e-5))
    for e: Float in [0, 0.01, 1.0 / 12, 0.2, 0.5, 1] {
        #expect(near(Transfer.hlgInverseOETF(Transfer.hlgOETF(e)), e, 1e-5))
    }
    #expect(near(Transfer.hlgSystemGamma(peak: 1000), 1.2, 1e-6))
    let display = Transfer.hlgOOTF(SIMD3(0.3, 0.2, 0.1))
    let scene = Transfer.hlgInverseOOTF(display)
    #expect(simd_distance(scene, SIMD3(0.3, 0.2, 0.1)) < 1e-5)
    // HLG peak white is 1000 cd/m².
    #expect(near(Transfer.hlgEOTF(SIMD3(repeating: 1)).y, 1000, 0.5))
    for t in TransferFunction.allCases {
        for v: Float in [0, 0.05, 0.18, 0.5, 0.9] {
            #expect(near(t.decode(t.encode(v)), v, 1e-4), "\(t) round trip \(v)")
        }
    }
    #expect(near(Transfer.srgbEncode(0.5), 0.7354, 1e-4))
}

@Test func primaryMatrices() {
    let m = Primaries.rec709.toXYZ
    let expected = simd_double3x3(rows: [
        SIMD3(0.412391, 0.357584, 0.180481),
        SIMD3(0.212639, 0.715169, 0.072192),
        SIMD3(0.019331, 0.119195, 0.950532),
    ])
    for c in 0..<3 { #expect(simd_distance(m[c], expected[c]) < 1e-5) }

    let toRec709 = Primaries.matrix(from: .rec2020, to: .rec709)
    #expect(simd_distance(toRec709 * SIMD3(1, 1, 1), SIMD3(1, 1, 1)) < 1e-9)
    // BT.2087 Rec.709 → Rec.2020.
    let to2020 = Primaries.matrix(from: .rec709, to: .rec2020)
    let bt2087 = simd_double3x3(rows: [SIMD3(0.6274, 0.3293, 0.0433), SIMD3(0.0691, 0.9195, 0.0114), SIMD3(0.0164, 0.0880, 0.8956)])
    for c in 0..<3 { #expect(simd_distance(to2020[c], bt2087[c]) < 2e-4) }
    // Bradford D65 → D60 with ACES RRT saturation reproduces Hill's ACESInputMat.
    let hill = simd_double3x3(rows: [SIMD3(0.59719, 0.35458, 0.04823), SIMD3(0.07600, 0.90834, 0.01566), SIMD3(0.02840, 0.13383, 0.83777)])
    let input = ToneMap.saturation(0.96) * Primaries.matrix(from: .rec709, to: .acesAP1)
    for c in 0..<3 { #expect(simd_distance(input[c], hill[c]) < 5e-4) }
    // Every camera gamut keeps white white.
    for p in LogProfile.allCases {
        let w = Primaries.matrix(from: p.primaries, to: .rec709) * SIMD3(1, 1, 1)
        #expect(simd_distance(w, SIMD3(1, 1, 1)) < 1e-4, "\(p) white → \(w)")
    }
}

@Test func toneMapsAreMonotonicAndBounded() {
    for m in ToneMap.allCases {
        var last: Float = -1
        for i in 0...400 {
            let x = pow(2, Float(i) / 20 - 10)
            let y = ToneMap.apply(SIMD3(repeating: x), m, exposure: 0)
            #expect(y.min() >= 0 && y.max() <= 1, "\(m) out of range at \(x)")
            #expect(y.y >= last, "\(m) decreases at \(x)")
            last = y.y
        }
        #expect(ToneMap.apply(.zero, m, exposure: 0).max() < 0.01)
        let bright = ToneMap.apply(SIMD3(1, 0.2, 0.05) * 1000, m, exposure: 0)
        #expect(bright.min() >= 0 && bright.max() <= 1)
    }
    #expect(ToneMap.apply(SIMD3(repeating: 0.25), .none, exposure: 1).x == 0.5)
    // ACES puts mid grey near 10% display light.
    #expect(near(ToneMap.apply(SIMD3(repeating: 0.18), .aces, exposure: 0).y, 0.105, 0.01))
}

@Test func pipelineLandsMidGrey() {
    let grey = LogProfile.slog3.fromLinear(0.18)
    let sdr = ColorPipeline.inputTransform(log: .slog3, target: .rec709, tone: .aces, exposure: 0, recordedIn: .full)(SIMD3(repeating: grey))
    #expect(near(sdr.y, 0.39, 0.03), "S-Log3 grey → \(sdr)")
    #expect(abs(sdr.x - sdr.z) < 0.005)
    let pq = ColorPipeline.inputTransform(log: .slog3, target: .rec2020_pq, tone: .none, exposure: 0, recordedIn: .full)(SIMD3(repeating: grey))
    #expect(near(pq.y, Transfer.pqEncode(nits: 0.18 * 203), 0.002))
    for tone in ToneMap.allCases where tone != .none && tone != .aces {
        let mapped = ColorPipeline.inputTransform(log: .slog3, target: .rec2020_pq, tone: tone, exposure: 0, recordedIn: .full)(SIMD3(repeating: grey))
        #expect(near(mapped.y, pq.y, 0.003), "\(tone) moves HDR mid grey to \(mapped)")
    }
    // The ACES 1000-nit output transform puts mid grey at 15 cd/m².
    let aces = ColorPipeline.inputTransform(log: .slog3, target: .rec2020_pq, tone: .aces, exposure: 0, recordedIn: .full)(SIMD3(repeating: grey))
    #expect(near(aces.y, Transfer.pqEncode(nits: 15), 0.002), "ACES HDR mid grey \(aces)")
    let up = ColorPipeline.inputTransform(log: .vlog, target: .rec709, tone: .aces, exposure: 1, recordedIn: .full)(SIMD3(repeating: LogProfile.vlog.fromLinear(0.18)))
    #expect(up.y > sdr.y + 0.05)
}

@Test func displayTransformsKeepIdentity() {
    let samples: [SIMD3<Float>] = [SIMD3(0, 0, 0), SIMD3(0.2, 0.5, 0.8), SIMD3(0.9, 0.1, 0.4), SIMD3(1, 1, 1), SIMD3(0.5, 0.5, 0.5)]
    for space in WorkingSpace.allCases {
        let f = ColorPipeline.displayTransform(from: space, to: space, tone: .none, exposure: 0)
        for c in samples {
            #expect(simd_distance(f(c), c) < 2e-3, "\(space) identity \(c) → \(f(c))")
        }
    }
    let sdrWhite = ColorPipeline.displayTransform(from: .rec709, to: .rec2020_pq, tone: .none, exposure: 0)(SIMD3(repeating: 1))
    #expect(near(Transfer.pqDecode(sdrWhite.y), 203, 1))
    #expect(WorkingSpace.rec2020_pq.isHDR && !WorkingSpace.p3.isHDR)
}

@Test func gamutCompressionPullsNegativesInWithoutTouchingInGamut() {
    let inside = SIMD3<Float>(0.5, 0.4, 0.3)
    #expect(ColorPipeline.compressGamut(inside) == inside)
    let outside = ColorPipeline.compressGamut(SIMD3<Float>(0.8, 0.2, -0.3))
    #expect(outside.z > -0.3 && outside.z >= -0.01)
    #expect(outside.x == 0.8)
}

@Test func colorMatchMovesStatisticsOntoTheReference() {
    let warm: [SIMD3<Float>] = (0..<200).map { i in let v = Float(i) / 200; return SIMD3(min(1, v * 0.95 + 0.04), v * 0.85, v * 0.72) }
    let cool: [SIMD3<Float>] = (0..<200).map { i in let v = Float(i) / 200; return SIMD3(v * 0.78, v * 0.85, min(1, v * 0.95 + 0.04)) }
    let a = ColorMatch.stats(warm), b = ColorMatch.stats(cool)
    let f = ColorMatch.transform(from: a, to: b)
    let matched = ColorMatch.stats(warm.map(f))
    #expect(abs(matched.mean.y - b.mean.y) < 3 && abs(matched.mean.z - b.mean.z) < 3)
    let identity = ColorMatch.transform(from: a, to: a)
    let p = SIMD3<Float>(0.4, 0.3, 0.2)
    #expect(simd_distance(identity(p), p) < 0.01)
}
