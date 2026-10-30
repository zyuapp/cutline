import Foundation
import simd
import Testing
@testable import CutlineCore

private func near(_ a: Float, _ b: Float, _ tol: Float) -> Bool { abs(a - b) <= tol }

private let grey = SIMD3<Float>(repeating: 0.18)

/// Mid grey through the CTL by hand: RRT 0.18 → 4.8 cd/m² (OCES), ODT_48nits keeps 4.8, so display linear is
/// (4.8 - 0.02) / (48 - 0.02) = 0.099625, or 0.104064 after the dim-surround 0.9811 power.
@Test func acesSDRMidGreyMatchesTheCTL() {
    #expect(near(ACES.rrtTonescale.forward(0.18), 4.8, 1e-4))
    #expect(near(ACES.odtTonescale48.forward(4.8), 4.8, 1e-4))
    #expect(near(ACES.rrt(grey).y, 4.8, 1e-3))

    let rec709 = ACES.outputTransform(.rec709)(grey)
    #expect(near(rec709.y, 0.389530, 5e-4), "Rec.709 grey \(rec709)")
    #expect(abs(rec709.x - rec709.z) < 1e-4)
    let srgb = ACES.outputTransform(.srgb)(grey)
    #expect(near(srgb.y, 0.355954, 5e-4), "sRGB grey \(srgb)")
    #expect(near(ACES.outputTransform(.display_p3)(grey).y, 0.355954, 5e-4))
    // The cinema P3-D65 ODT skips the dim-surround and ODT saturation steps and encodes with gamma 2.6.
    #expect(near(ACES.outputTransform(.p3d65_48nits)(grey).y, 0.411867, 5e-4))
    #expect(near(ToneMap.apply(SIMD3(repeating: 0.18), .aces, exposure: 0).y, 0.104064, 3e-4))
}

@Test func acesSDRBlackAndHighlights() {
    for display in [ACES.Display.rec709, .srgb, .p3d65_48nits, .display_p3] {
        let f = ACES.outputTransform(display)
        #expect(f(.zero).max() < 1e-3, "\(display) black \(f(.zero))")
        // Five stops over grey still rolls off below white; far above, the ODT clips at 1.
        #expect(f(grey * 32).y < 0.99, "\(display) +5 stops \(f(grey * 32))")
        #expect(f(grey * 32).y > 0.9)
        #expect(near(f(SIMD3(repeating: 1e5)).max(), 1, 1e-4))
        var last: Float = -1
        for i in 0...360 {
            let y = f(grey * pow(2, Float(i) / 20 - 9)).y
            #expect(y >= last - 1e-6, "\(display) decreases at stop \(Float(i) / 20 - 9)")
            last = y
        }
    }
}

@Test func acesLuminanceIsMonotonicForColors() {
    let rec709Luma = SIMD3<Float>(0.2126, 0.7152, 0.0722)
    let colors: [SIMD3<Float>] = [SIMD3(1, 0.5, 0.2), SIMD3(0.2, 0.3, 1), SIMD3(1, 0.05, 0.05), SIMD3(0.4, 1, 0.3), SIMD3(0.9, 0.2, 0.8)]
    let rec709 = ACES.outputTransform(.rec709)
    let pq = ACES.outputTransform(.rec2020_pq_1000)
    for color in colors {
        var lastSDR: Float = -1, lastHDR: Float = -1
        for i in 0...280 {
            let c = color * 0.18 * pow(2, Float(i) / 20 - 7)
            let sdr = rec709(c)
            let sdrY = (SIMD3(pow(sdr.x, 2.4), pow(sdr.y, 2.4), pow(sdr.z, 2.4)) * rec709Luma).sum()
            #expect(sdrY >= lastSDR - 1e-5, "Rec.709 \(color) luminance drops at \(i)")
            lastSDR = sdrY
            let n = pq(c)
            let hdrY = (SIMD3(Transfer.pqDecode(n.x), Transfer.pqDecode(n.y), Transfer.pqDecode(n.z)) * Transfer.rec2020Luma).sum()
            #expect(hdrY >= lastHDR * (1 - 1e-4), "PQ \(color) luminance drops at \(i)")
            lastHDR = hdrY
        }
    }
}

@Test func acesHDRMidGreyAndPeak() {
    let tonescale = ACES.ssts(minNits: 0.0001, midNits: 15, maxNits: 1000)
    #expect(near(tonescale.forward(0.18), 15, 0.01))
    #expect(near(tonescale.forward(1e6), 1000, 0.01))
    #expect(near(tonescale.forward(0), 0.0001, 1e-6))

    let pq = ACES.outputTransform(.rec2020_pq)
    let greyPQ = pq(grey)
    #expect(near(greyPQ.y, Transfer.pqEncode(nits: 15), 5e-4), "PQ grey \(greyPQ)")
    #expect(near(greyPQ.y, 0.3326, 5e-4))
    #expect(abs(greyPQ.x - greyPQ.z) < 1e-4)
    #expect(pq(.zero).max() < 1e-4)

    // Very bright neutrals reach the 1000-nit peak. The CTL limits to Rec.2020 before adapting D60 to D65, which
    // clips the red of the D60 white and leaves white a hair under 1000 cd/m².
    let peak = SIMD3(Transfer.pqDecode(pq(SIMD3(repeating: 1e4)).x), Transfer.pqDecode(pq(SIMD3(repeating: 1e4)).y), Transfer.pqDecode(pq(SIMD3(repeating: 1e4)).z))
    #expect(peak.max() > 990 && peak.max() < 1010, "PQ peak \(peak)")
    #expect((peak * Transfer.rec2020Luma).sum() > 980)

    let hlg = ACES.outputTransform(.rec2020_hlg)
    let greyHLG = hlg(grey)
    #expect(near(greyHLG.y, Transfer.hlgOETF(pow(0.015, 1 / 1.2)), 5e-4), "HLG grey \(greyHLG)")
    #expect(near(Transfer.hlgEOTF(greyHLG).y, 15, 0.05))
    #expect(hlg(SIMD3(repeating: 1e4)).max() > 0.99)

    var last: Float = -1
    for i in 0...400 {
        let y = pq(grey * pow(2, Float(i) / 20 - 12)).y
        #expect(y >= last, "PQ decreases at stop \(Float(i) / 20 - 12)")
        last = y
    }
}

@Test func segmentedSplinesPassThroughTheirKnots() {
    let splines = [
        ("RRT c5", ACES.rrtTonescale),
        ("ODT 48-nit c9", ACES.odtTonescale48),
        ("SSTS 1000", ACES.ssts(minNits: 0.0001, midNits: 15, maxNits: 1000)),
    ]
    for (name, s) in splines {
        let knots = s.knots
        #expect(knots.count == s.coefsLow.count - 2 + s.coefsHigh.count - 3)
        #expect(near(knots.first!.y, s.minPoint.y, s.minPoint.y * 1e-4), "\(name) min knot")
        #expect(near(knots.last!.y, s.maxPoint.y, s.maxPoint.y * 1e-4), "\(name) max knot")
        for k in knots {
            #expect(abs(s.forward(k.x) / k.y - 1) < 1e-4, "\(name) knot \(k) → \(s.forward(k.x))")
            #expect(abs(s.reverse(k.y) / k.x - 1) < 1e-3, "\(name) reverse knot \(k) → \(s.reverse(k.y))")
        }
        let lo = log2(s.minPoint.x), hi = log2(s.maxPoint.x)
        var last: Float = 0
        for i in 1..<200 {
            let x = pow(2, lo + (hi - lo) * Float(i) / 200)
            let y = s.forward(x)
            #expect(y >= last, "\(name) not increasing at \(x)")
            last = y
            #expect(abs(s.reverse(y) / x - 1) < 2e-3, "\(name) round trip \(x) → \(y) → \(s.reverse(y))")
        }
    }
    // RRT_PARAMS knots in log10 luminance from the published coefficients.
    let rrt = ACES.rrtTonescale.knots.map { log10($0.y) }
    #expect(rrt.count == 7)
    for (a, b) in zip(rrt, [-4, -3.5786882887, -1.8213132866, 0.6812412374, 2.8745774205, 3.8340620619, 4] as [Float]) {
        #expect(near(a, b, 1e-4))
    }
}

@Test func acesInputsAgree() {
    let samples: [SIMD3<Float>] = [grey, SIMD3(0.5, 0.2, 0.05), SIMD3(0.01, 0.4, 2), SIMD3(3, 3, 0.1)]
    for display in ACES.Display.allCases {
        let ap0 = ACES.outputTransform(display)
        let cg = ACES.outputTransform(display, input: .acescg)
        for c in samples {
            #expect(simd_distance(ap0(c), cg(ACES.ap0ToAP1 * c)) < 1e-3, "\(display) \(c)")
        }
    }
}

@Test func acesStaysFiniteOnExtremeInput() {
    let values: [Float] = [-1, -0.01, 0, 1e-7, 0.001, 0.18, 1, 50, 1e4, 1e8]
    for display in ACES.Display.allCases {
        let f = ACES.outputTransform(display)
        for r in values { for g in values { for b in values {
            let v = f(SIMD3(r, g, b))
            #expect(v.x.isFinite && v.y.isFinite && v.z.isFinite, "\(display) (\(r), \(g), \(b)) → \(v)")
            #expect(v.min() >= -1e-6 && v.max() <= 1.2, "\(display) (\(r), \(g), \(b)) → \(v)")
        } } }
    }
}

@Test func redModifierAndGlowOnlyTouchColors() {
    #expect(ACES.redHueWeight(SIMD3(1, 0, 0)) == 1)
    #expect(ACES.redHueWeight(SIMD3(0, 1, 0)) == 0)
    #expect(ACES.redHueWeight(grey) == 0)
    #expect(ACES.rrtSweeteners(grey) == ACES.rrtSat * (ACES.ap0ToAP1 * grey))
    // A dark saturated red gets the glow and loses some red.
    let red = SIMD3<Float>(0.05, 0.005, 0.005)
    let swept = ACES.ap1ToAP0 * (ACES.rrtSat.inverse * ACES.rrtSweeteners(red))
    #expect(swept.y > red.y)
    #expect(swept.x / swept.y < red.x / red.y)
}

@Test func slog3GreyThroughTheACESPipeline() {
    let code = LogProfile.slog3.fromLinear(0.18)
    let sdr = ColorPipeline.inputTransform(log: .slog3, target: .rec709, tone: .aces, exposure: 0, recordedIn: .full)(SIMD3(repeating: code))
    #expect(near(sdr.y, 0.3895, 0.002), "S-Log3 grey → \(sdr)")
    #expect(sdr.y > 0.38 && sdr.y < 0.42)
    #expect(abs(sdr.x - sdr.z) < 1e-3)
    let pq = ColorPipeline.inputTransform(log: .slog3, target: .rec2020_pq, tone: .aces, exposure: 0, recordedIn: .full)(SIMD3(repeating: code))
    #expect(near(Transfer.pqDecode(pq.y), 15, 0.1), "S-Log3 grey → \(Transfer.pqDecode(pq.y)) cd/m²")
    // A Rec.709 display round trip renders like ACES on the decoded scene light.
    let display = ColorPipeline.displayTransform(from: .rec709, to: .rec709, tone: .aces, exposure: 0)(SIMD3(repeating: Transfer.gammaEncode(0.18, 2.4)))
    #expect(near(display.y, 0.3895, 0.002))
}

@Test func acesMatchesOpenColorIO() {
    for (name, input, expected) in ocioReference {
        let got = ACES.outputTransform(ACES.Display(rawValue: name)!)(input)
        let tolerance: Float = input == .zero ? 5e-4 : 2e-4
        #expect(abs(got - pointwiseMax(expected, .zero)).max() < tolerance, "\(name) \(input) → \(got), OCIO \(expected)")
    }
}

/// OpenColorIO 2.6 built-in `studio-config-v2.2.0_aces-v1.3_ocio-v2.4` from ACES2065-1 through the "ACES 1.0 - SDR
/// Video", "ACES 1.0 - SDR Cinema" and "ACES 1.1 - HDR Video (1000 nits & Rec.2020 lim)" views. OCIO leaves values
/// outside the display gamut unclipped; the CTL clips them at 0, so negatives compare as 0. HLG rows with negatives are
/// left out because HLG mixes channels.
private let ocioReference: [(String, SIMD3<Float>, SIMD3<Float>)] = [
    ("rec709", SIMD3(0.18, 0.18, 0.18), SIMD3(0.389528, 0.389529, 0.389528)),
    ("rec709", SIMD3(0, 0, 0), SIMD3(0.000214, 0.000214, 0.000214)),
    ("rec709", SIMD3(1, 1, 1), SIMD3(0.821777, 0.821777, 0.821777)),
    ("rec709", SIMD3(0.0045, 0.0045, 0.0045), SIMD3(0.029346, 0.029346, 0.029346)),
    ("rec709", SIMD3(5.76, 5.76, 5.76), SIMD3(0.974271, 0.974271, 0.974271)),
    ("rec709", SIMD3(0.5, 0.2, 0.05), SIMD3(0.832608, 0.363742, 0.150556)),
    ("rec709", SIMD3(0.05, 0.005, 0.005), SIMD3(0.253375, 0.000000, 0.037024)),
    ("rec709", SIMD3(0.01, 0.4, 2.0), SIMD3(0.000000, 0.512657, 0.938711)),
    ("rec709", SIMD3(0.3, 0.6, 0.1), SIMD3(0.279043, 0.762690, 0.191218)),
    ("rec709", SIMD3(3, 3, 0.1), SIMD3(0.979212, 0.948204, 0.364626)),
    ("rec709", SIMD3(0.2, 0.05, 0.6), SIMD3(0.366237, 0.000000, 0.740481)),
    ("srgb", SIMD3(0.18, 0.18, 0.18), SIMD3(0.355952, 0.355953, 0.355952)),
    ("srgb", SIMD3(1, 1, 1), SIMD3(0.811975, 0.811975, 0.811975)),
    ("srgb", SIMD3(0.0045, 0.0045, 0.0045), SIMD3(0.002713, 0.002713, 0.002713)),
    ("srgb", SIMD3(0.5, 0.2, 0.05), SIMD3(0.823402, 0.328748, 0.103837)),
    ("srgb", SIMD3(0.05, 0.005, 0.005), SIMD3(0.212310, -0.030276, 0.004739)),
    ("srgb", SIMD3(0.3, 0.6, 0.1), SIMD3(0.239391, 0.749638, 0.146735)),
    ("display_p3", SIMD3(0.18, 0.18, 0.18), SIMD3(0.355952, 0.355953, 0.355952)),
    ("display_p3", SIMD3(0.5, 0.2, 0.05), SIMD3(0.764591, 0.360333, 0.179508)),
    ("display_p3", SIMD3(0.05, 0.005, 0.005), SIMD3(0.189996, -0.013369, 0.010307)),
    ("display_p3", SIMD3(0.01, 0.4, 2.0), SIMD3(-0.337463, 0.472306, 0.903405)),
    ("display_p3", SIMD3(0.3, 0.6, 0.1), SIMD3(0.397471, 0.739417, 0.261887)),
    ("display_p3", SIMD3(3, 3, 0.1), SIMD3(0.972367, 0.946465, 0.437681)),
    ("p3d65_48nits", SIMD3(0.18, 0.18, 0.18), SIMD3(0.411864, 0.411865, 0.411864)),
    ("p3d65_48nits", SIMD3(0, 0, 0), SIMD3(0.000348, 0.000352, 0.000355)),
    ("p3d65_48nits", SIMD3(1, 1, 1), SIMD3(0.831373, 0.831373, 0.831373)),
    ("p3d65_48nits", SIMD3(0.5, 0.2, 0.05), SIMD3(0.796829, 0.406865, 0.190606)),
    ("p3d65_48nits", SIMD3(0.05, 0.005, 0.005), SIMD3(0.255880, 0.000000, 0.046639)),
    ("p3d65_48nits", SIMD3(0.3, 0.6, 0.1), SIMD3(0.427785, 0.769456, 0.260949)),
    ("p3d65_48nits", SIMD3(0.2, 0.05, 0.6), SIMD3(0.358951, 0.000000, 0.733072)),
    ("rec2020_pq_1000", SIMD3(0.18, 0.18, 0.18), SIMD3(0.332589, 0.332589, 0.332589)),
    ("rec2020_pq_1000", SIMD3(0, 0, 0), SIMD3(0.000001, 0.000001, 0.000001)),
    ("rec2020_pq_1000", SIMD3(1, 1, 1), SIMD3(0.515296, 0.515296, 0.515296)),
    ("rec2020_pq_1000", SIMD3(0.0045, 0.0045, 0.0045), SIMD3(0.041838, 0.041838, 0.041838)),
    ("rec2020_pq_1000", SIMD3(5.76, 5.76, 5.76), SIMD3(0.650547, 0.650547, 0.650547)),
    ("rec2020_pq_1000", SIMD3(100, 100, 100), SIMD3(0.739257, 0.739257, 0.739257)),
    ("rec2020_pq_1000", SIMD3(10000.0, 10000.0, 10000.0), SIMD3(0.749211, 0.751829, 0.751826)),
    ("rec2020_pq_1000", SIMD3(0.5, 0.2, 0.05), SIMD3(0.463665, 0.344092, 0.200549)),
    ("rec2020_pq_1000", SIMD3(0.05, 0.005, 0.005), SIMD3(0.224297, 0.019166, 0.047936)),
    ("rec2020_pq_1000", SIMD3(0.01, 0.4, 2.0), SIMD3(-0.041038, 0.377622, 0.575727)),
    ("rec2020_pq_1000", SIMD3(0.3, 0.6, 0.1), SIMD3(0.380671, 0.475884, 0.265147)),
    ("rec2020_pq_1000", SIMD3(3, 3, 0.1), SIMD3(0.621040, 0.614057, 0.320571)),
    ("rec2020_pq_1000", SIMD3(0.2, 0.05, 0.6), SIMD3(0.308760, -0.051549, 0.463765)),
    ("rec2020_hlg_1000", SIMD3(0.18, 0.18, 0.18), SIMD3(0.301020, 0.301021, 0.301020)),
    ("rec2020_hlg_1000", SIMD3(1, 1, 1), SIMD3(0.642301, 0.642301, 0.642301)),
    ("rec2020_hlg_1000", SIMD3(5.76, 5.76, 5.76), SIMD3(0.855420, 0.855420, 0.855421)),
    ("rec2020_hlg_1000", SIMD3(10000.0, 10000.0, 10000.0), SIMD3(0.995792, 1.000193, 1.000188)),
    ("rec2020_hlg_1000", SIMD3(0.5, 0.2, 0.05), SIMD3(0.576894, 0.305486, 0.115322)),
    ("rec2020_hlg_1000", SIMD3(0.05, 0.005, 0.005), SIMD3(0.184384, 0.008741, 0.022865)),
    ("rec2020_hlg_1000", SIMD3(0.3, 0.6, 0.1), SIMD3(0.356245, 0.579648, 0.175498)),
    ("rec2020_hlg_1000", SIMD3(3, 3, 0.1), SIMD3(0.815026, 0.802421, 0.220119)),
]
