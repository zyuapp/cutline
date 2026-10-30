import Foundation
import simd

/// ACES 1.3 output transforms, following the aces-dev v1.3 CTL: the RRT and SDR ODTs (`ACESlib.RRT_Common`,
/// `ACESlib.ODT_Common`, `ACESlib.Tonescales`) and the single-stage tone scale HDR output transforms
/// (`ACESlib.SSTS`, `ACESlib.OutputTransforms`).
public enum ACES {
    /// Encoding of scene-linear ACES input.
    public enum Input: String, CaseIterable, Sendable {
        /// ACES2065-1, AP0 primaries.
        case aces2065_1
        /// ACEScg, AP1 primaries.
        case acescg
    }

    /// Output transforms by display.
    public enum Display: String, CaseIterable, Sendable {
        /// `ODT.Academy.Rec709_100nits_dim`: BT.1886, dim surround.
        case rec709
        /// `ODT.Academy.sRGB_100nits_dim`.
        case srgb
        /// `ODT.Academy.P3D65_48nits`: cinema, gamma 2.6, dark surround.
        case p3d65_48nits
        /// The Rec.709 100-nit dim rendering on P3-D65 primaries with sRGB encoding (Display P3).
        case display_p3
        /// `RRTODT.Academy.Rec2020_1000nits_15nits_ST2084`.
        case rec2020_pq_1000
        /// `RRTODT.Academy.Rec2020_1000nits_15nits_HLG`.
        case rec2020_hlg_1000

        /// The display a working space is delivered on.
        public init(_ space: WorkingSpace) {
            switch space {
            case .rec709: self = .rec709
            case .p3: self = .display_p3
            case .rec2020_hlg: self = .rec2020_hlg_1000
            case .rec2020_pq: self = .rec2020_pq_1000
            }
        }
    }

    /// Scene-linear ACES2065-1 to the display-encoded signal of `target`.
    public static func outputTransform(_ target: WorkingSpace) -> (SIMD3<Float>) -> SIMD3<Float> {
        outputTransform(Display(target))
    }

    /// Scene-linear ACES (`input`) to the display-encoded signal of `display`, before any range clamp.
    public static func outputTransform(_ display: Display, input: Input = .aces2065_1) -> (SIMD3<Float>) -> SIMD3<Float> {
        let pre = input == .acescg ? ap1ToAP0 : matrix_identity_float3x3
        switch display {
        case .rec709, .srgb, .p3d65_48nits, .display_p3:
            let odt = SDRODT(display)
            return { c in odt.encode(odt.displayLinear(rrt(pre * c))) }
        case .rec2020_pq_1000:
            let hdr = HDROutput.rec2020_1000
            return { c in
                let n = hdr.nits(pre * c)
                return SIMD3(Transfer.pqEncode(nits: n.x), Transfer.pqEncode(nits: n.y), Transfer.pqEncode(nits: n.z))
            }
        case .rec2020_hlg_1000:
            let hdr = HDROutput.rec2020_1000
            return { c in
                let s = Transfer.hlgInverseOOTF(hdr.nits(pre * c), peak: 1000)
                return SIMD3(Transfer.hlgOETF(s.x), Transfer.hlgOETF(s.y), Transfer.hlgOETF(s.z))
            }
        }
    }

    /// The Rec.709 100-nit dim rendering of ACES2065-1 as linear light 0…1 in `gamut`, before display encoding.
    public static func sdrDisplayLinear(_ aces: SIMD3<Float>, gamut: Primaries) -> SIMD3<Float> {
        SDRODT.video(gamut).displayLinear(rrt(aces))
    }

    // MARK: Matrices

    public static let ap0ToAP1 = Primaries.matrix(from: .acesAP0, to: .acesAP1).float
    public static let ap1ToAP0 = Primaries.matrix(from: .acesAP1, to: .acesAP0).float
    static let ap1ToXYZ = Primaries.acesAP1.toXYZ.float
    static let xyzToAP1 = Primaries.acesAP1.toXYZ.inverse.float
    static let rrtSat = ToneMap.saturation(0.96).float
    static let odtSat = ToneMap.saturation(0.93).float

    /// AP1 (D60) to display RGB with Bradford adaptation, as the ODTs' `AP1_2_XYZ`, `D60_2_D65_CAT`, `XYZ_2_DISPLAY`.
    static func ap1To(_ display: Primaries) -> simd_float3x3 {
        Primaries.matrix(from: .acesAP1, to: display).float
    }

    static let halfMin: Float = 5.96046448e-08
    static let halfMax: Float = 65504

    // MARK: RRT

    /// RRT: ACES2065-1 to OCES (AP0, cd/m² at a 48-nit cinema reference).
    public static func rrt(_ aces: SIMD3<Float>) -> SIMD3<Float> {
        let pre = rrtSweeteners(aces)
        let t = rrtTonescale
        return ap1ToAP0 * SIMD3(t.forward(pre.x), t.forward(pre.y), t.forward(pre.z))
    }

    /// Glow, red modifier and global desaturation: ACES2065-1 to AP1 ready for the tone scale.
    static func rrtSweeteners(_ aces: SIMD3<Float>) -> SIMD3<Float> {
        var a = aces
        let sat = saturation(a)
        let s = sigmoidShaper((sat - 0.4) / 0.2)
        a *= 1 + glowForward(yc(a), 0.05 * s, 0.08)
        a.x += redHueWeight(a) * sat * (0.03 - a.x) * (1 - 0.82)
        a = pointwiseMax(a, .zero)
        let pre = simd_clamp(ap0ToAP1 * a, .zero, SIMD3(repeating: halfMax))
        return rrtSat * pre
    }

    static func saturation(_ c: SIMD3<Float>) -> Float {
        let tiny: Float = 1e-10
        return (max(c.max(), tiny) - max(c.min(), tiny)) / max(c.max(), 1e-2)
    }

    /// Luminance-like value that boosts saturated colors: (r + g + b + 1.75 · chroma) / 3.
    static func yc(_ c: SIMD3<Float>) -> Float {
        let chroma = max(c.z * (c.z - c.y) + c.y * (c.y - c.x) + c.x * (c.x - c.z), 0).squareRoot()
        return (c.sum() + 1.75 * chroma) / 3
    }

    static func sigmoidShaper(_ x: Float) -> Float {
        let t = max(1 - abs(x / 2), 0)
        let sign: Float = x > 0 ? 1 : x < 0 ? -1 : 0
        return (1 + sign * (1 - t * t)) / 2
    }

    static func glowForward(_ yc: Float, _ gain: Float, _ mid: Float) -> Float {
        if yc <= 2 / 3 * mid { return gain }
        if yc >= 2 * mid { return 0 }
        return gain * (mid / yc - 0.5)
    }

    /// Cubic B-spline window over hue, 1 at red (0°) and 0 beyond ±67.5°; 0 for neutrals.
    static func redHueWeight(_ c: SIMD3<Float>) -> Float {
        guard c.x != c.y || c.y != c.z else { return 0 }
        var hue = atan2(Float(3).squareRoot() * (c.y - c.z), 2 * c.x - c.y - c.z) * 180 / .pi
        if hue < 0 { hue += 360 }
        if hue > 180 { hue -= 360 }
        let width: Float = 135
        guard hue > -width / 2, hue < width / 2 else { return 0 }
        let coord = (hue + width / 2) * 4 / width
        let j = Int(coord)
        let t = coord - Float(j)
        let y: Float
        switch j {
        case 3: y = (1 - t) * (1 - t) * (1 - t) / 6
        case 2: y = (3 * t * t * t - 6 * t * t + 4) / 6
        case 1: y = (-3 * t * t * t + 3 * t * t + 3 * t + 1) / 6
        case 0: y = t * t * t / 6
        default: y = 0
        }
        return y * 1.5
    }

    // MARK: Tone scales

    /// `RRT_PARAMS`: scene ACES to OCES luminance, 0.18 → 4.8.
    public static let rrtTonescale = SegmentedSpline(
        coefsLow: [-4.0000000000, -4.0000000000, -3.1573765773, -0.4852499958, 1.8477324706, 1.8477324706],
        coefsHigh: [-0.7185482425, 2.0810307172, 3.6681241237, 4.0000000000, 4.0000000000, 4.0000000000],
        minPoint: SIMD2(0.18 * pow(2, -15), 0.0001), midPoint: SIMD2(0.18, 4.8), maxPoint: SIMD2(0.18 * pow(2, 18), 10000),
        slopeLow: 0, slopeHigh: 0)

    /// `ODT_48nits`: OCES to cinema luminance 0.02…48 cd/m².
    public static let odtTonescale48 = SegmentedSpline(
        coefsLow: [-1.6989700043, -1.6989700043, -1.4779000000, -1.2291000000, -0.8648000000, -0.4480000000, 0.0051800000, 0.4511080334, 0.9113744414, 0.9113744414],
        coefsHigh: [0.5154386965, 0.8470437783, 1.1358000000, 1.3802000000, 1.5197000000, 1.5985000000, 1.6467000000, 1.6746091357, 1.6878733390, 1.6878733390],
        minPoint: SIMD2(rrtTonescale.forward(0.18 * pow(2, -6.5)), 0.02),
        midPoint: SIMD2(rrtTonescale.forward(0.18), 4.8),
        maxPoint: SIMD2(rrtTonescale.forward(0.18 * pow(2, 6.5)), 48),
        slopeLow: 0, slopeHigh: 0.04)

    /// The single-stage tone scale for a display from `minNits` to `maxNits`, shifted so 0.18 lands on `midNits`.
    public static func ssts(minNits: Float, midNits: Float, maxNits: Float) -> SegmentedSpline {
        let unshifted = sstsParams(minNits: minNits, maxNits: maxNits, shift: 0)
        let shift = log2(unshifted.reverse(midNits)) - log2(0.18)
        return sstsParams(minNits: minNits, maxNits: maxNits, shift: shift)
    }

    /// `init_TsParams`: knots from the luminance range; `shift` (stops) moves the curve along x only.
    static func sstsParams(minNits: Float, maxNits: Float, shift: Float) -> SegmentedSpline {
        let minStopSDR: Float = -6.5, maxStopSDR: Float = 6.5, minStopRRT: Float = -15, maxStopRRT: Float = 18
        let minLumSDR: Float = 0.02, maxLumSDR: Float = 48, minLumRRT: Float = 0.0001, maxLumRRT: Float = 10000
        let minX = 0.18 * pow(2, interpolate((log10(minLumRRT), minStopRRT), (log10(minLumSDR), minStopSDR), log10(minNits)))
        let maxX = 0.18 * pow(2, interpolate((log10(maxLumSDR), maxStopSDR), (log10(maxLumRRT), maxStopRRT), log10(maxNits)))
        let (minSlope, midSlope, maxSlope): (Float, Float, Float) = (0, 1.55, 0)
        let midX: Float = 0.18, midY: Float = 4.8

        func line(_ x: Float, _ y: Float, _ slope: Float, at logx: Float) -> Float {
            slope * logx + (log10(y) - slope * log10(x))
        }
        let incLow = (log10(midX) - log10(minX)) / 3
        let pctLow = interpolate((minStopRRT, 0.18), (minStopSDR, 0.35), log2(minX / 0.18))
        var low = [Float](repeating: 0, count: 6)
        low[0] = line(minX, minNits, minSlope, at: log10(minX) - 0.5 * incLow)
        low[1] = line(minX, minNits, minSlope, at: log10(minX) + 0.5 * incLow)
        low[2] = log10(minNits) + pctLow * (log10(midY) - log10(minNits))
        low[3] = line(midX, midY, midSlope, at: log10(midX) - 0.5 * incLow)
        low[4] = line(midX, midY, midSlope, at: log10(midX) + 0.5 * incLow)
        low[5] = low[4]

        let incHigh = (log10(maxX) - log10(midX)) / 3
        let pctHigh = interpolate((maxStopSDR, 0.89), (maxStopRRT, 0.90), log2(maxX / 0.18))
        var high = [Float](repeating: 0, count: 6)
        high[0] = line(midX, midY, midSlope, at: log10(midX) - 0.5 * incHigh)
        high[1] = line(midX, midY, midSlope, at: log10(midX) + 0.5 * incHigh)
        high[2] = log10(midY) + pctHigh * (log10(maxNits) - log10(midY))
        high[3] = line(maxX, maxNits, maxSlope, at: log10(maxX) - 0.5 * incHigh)
        high[4] = line(maxX, maxNits, maxSlope, at: log10(maxX) + 0.5 * incHigh)
        high[5] = high[4]

        let s = pow(2, -shift)
        return SegmentedSpline(coefsLow: low, coefsHigh: high,
                               minPoint: SIMD2(minX * s, minNits), midPoint: SIMD2(midX * s, midY), maxPoint: SIMD2(maxX * s, maxNits),
                               slopeLow: minSlope, slopeHigh: maxSlope)
    }

    /// CTL `interpolate1D` over a two-entry table, held flat outside it.
    static func interpolate(_ a: (Float, Float), _ b: (Float, Float), _ x: Float) -> Float {
        if x <= a.0 { return a.1 }
        if x >= b.0 { return b.1 }
        return a.1 + (x - a.0) / (b.0 - a.0) * (b.1 - a.1)
    }

    // MARK: SDR ODTs

    struct SDRODT {
        var toDisplay: simd_float3x3
        var dimSurround: Bool
        var desaturate: Bool
        var encode: (SIMD3<Float>) -> SIMD3<Float>

        init(_ display: Display) {
            switch display {
            case .rec709:
                self = .video(.rec709)
                encode = { c in SIMD3(pow(c.x, 1 / 2.4), pow(c.y, 1 / 2.4), pow(c.z, 1 / 2.4)) }
            case .srgb, .display_p3:
                self = .video(display == .srgb ? .rec709 : .p3D65)
                encode = { c in SIMD3(ACES.moncurveR(c.x), ACES.moncurveR(c.y), ACES.moncurveR(c.z)) }
            default:
                toDisplay = ap1To(.p3D65)
                dimSurround = false
                desaturate = false
                encode = { c in SIMD3(pow(c.x, 1 / 2.6), pow(c.y, 1 / 2.6), pow(c.z, 1 / 2.6)) }
            }
        }

        init(toDisplay: simd_float3x3) {
            self.toDisplay = toDisplay
            dimSurround = true
            desaturate = true
            encode = { $0 }
        }

        static let cache = Locked<[Primaries: SDRODT]>([:])

        /// The 100-nit dim-surround video ODT on `gamut`, returning display linear.
        static func video(_ gamut: Primaries) -> SDRODT {
            if let hit = cache.withLock({ $0[gamut] }) { return hit }
            let odt = SDRODT(toDisplay: ap1To(gamut))
            cache.withLock { $0[gamut] = odt }
            return odt
        }

        /// OCES to display linear 0…1.
        func displayLinear(_ oces: SIMD3<Float>) -> SIMD3<Float> {
            let pre = ap0ToAP1 * oces
            let t = odtTonescale48
            let post = SIMD3(t.forward(pre.x), t.forward(pre.y), t.forward(pre.z))
            var lin = (post - 0.02) / (48 - 0.02)
            if dimSurround { lin = ACES.darkToDim(lin) }
            if desaturate { lin = odtSat * lin }
            return simd_clamp(toDisplay * lin, .zero, SIMD3(repeating: 1))
        }
    }

    /// `darkSurround_to_dimSurround`: AP1 luminance raised to 0.9811 at constant chromaticity.
    static func darkToDim(_ ap1: SIMD3<Float>) -> SIMD3<Float> {
        xyzToAP1 * scaleLuminance(ap1ToXYZ * ap1) { pow(max($0, 0), 0.9811) }
    }

    static func scaleLuminance(_ xyz: SIMD3<Float>, _ f: (Float) -> Float) -> SIMD3<Float> {
        var sum = xyz.sum()
        if sum == 0 { sum = 1e-10 }
        let x = xyz.x / sum, y = xyz.y / sum
        let Y = f(xyz.y)
        let d = max(y, 1e-10)
        return SIMD3(x * Y / d, Y, (1 - x - y) * Y / d)
    }

    /// sRGB-style inverse EOTF (`moncurve_r` with gamma 2.4, offset 0.055).
    static func moncurveR(_ y: Float) -> Float {
        let gamma: Float = 2.4, offs: Float = 0.055
        let yb = pow(offs * gamma / ((gamma - 1) * (1 + offs)), gamma)
        let rs = pow((gamma - 1) / offs, gamma - 1) * pow((1 + offs) / gamma, gamma)
        return y >= yb ? (1 + offs) * pow(y, 1 / gamma) - offs : y * rs
    }

    // MARK: HDR output transforms

    /// `outputTransform` with dark surround, stretched black and no D60 simulation.
    struct HDROutput {
        var tonescale: SegmentedSpline
        var minNits: Float
        var maxNits: Float
        var toLimiting: simd_float3x3
        var fromLimiting: simd_float3x3
        var toDisplay: simd_float3x3

        static let rec2020_1000 = HDROutput(display: .rec2020, minNits: 0.0001, midNits: 15, maxNits: 1000)

        init(display: Primaries, minNits: Float, midNits: Float, maxNits: Float) {
            tonescale = ACES.ssts(minNits: minNits, midNits: midNits, maxNits: maxNits)
            self.minNits = minNits
            self.maxNits = maxNits
            // As in the CTL, limiting happens on unadapted (D60) XYZ, before the D60 → display white adaptation.
            toLimiting = display.toXYZ.inverse.float
            fromLimiting = display.toXYZ.float
            toDisplay = (display.toXYZ.inverse * Primaries.bradford(from: Primaries.d60, to: display.white)).float
        }

        /// ACES2065-1 to display light in cd/m², display primaries.
        func nits(_ aces: SIMD3<Float>) -> SIMD3<Float> {
            let pre = ACES.rrtSweeteners(aces)
            let post = SIMD3(tonescale.forward(pre.x), tonescale.forward(pre.y), tonescale.forward(pre.z))
            let lin = (post - minNits) / (maxNits - minNits)
            let limited = fromLimiting * simd_clamp(toLimiting * (ap1ToXYZ * lin), .zero, SIMD3(repeating: 1))
            return pointwiseMax(toDisplay * limited, .zero) * maxNits
        }
    }
}

// MARK: Segmented spline

/// The ACES segmented quadratic B-spline in log10–log10 space: `coefsLow` spans `minPoint`…`midPoint`, `coefsHigh`
/// spans `midPoint`…`maxPoint`, with linear extensions of `slopeLow` and `slopeHigh` beyond. Knot `i` of a half sits at
/// evenly spaced log x and has log y = (coefs[i] + coefs[i + 1]) / 2.
public struct SegmentedSpline: Sendable {
    public let coefsLow: [Float]
    public let coefsHigh: [Float]
    /// (x, y) linear values.
    public let minPoint: SIMD2<Float>
    public let midPoint: SIMD2<Float>
    public let maxPoint: SIMD2<Float>
    public let slopeLow: Float
    public let slopeHigh: Float
    let logMin: SIMD2<Float>
    let logMid: SIMD2<Float>
    let logMax: SIMD2<Float>

    public init(coefsLow: [Float], coefsHigh: [Float], minPoint: SIMD2<Float>, midPoint: SIMD2<Float>, maxPoint: SIMD2<Float>, slopeLow: Float, slopeHigh: Float) {
        precondition(coefsLow.count >= 4 && coefsHigh.count >= 4)
        self.coefsLow = coefsLow
        self.coefsHigh = coefsHigh
        self.minPoint = minPoint
        self.midPoint = midPoint
        self.maxPoint = maxPoint
        self.slopeLow = slopeLow
        self.slopeHigh = slopeHigh
        logMin = SIMD2(log10(minPoint.x), log10(minPoint.y))
        logMid = SIMD2(log10(midPoint.x), log10(midPoint.y))
        logMax = SIMD2(log10(maxPoint.x), log10(maxPoint.y))
    }

    /// (x, y) of every knot from `minPoint` to `maxPoint`, the mid point once.
    public var knots: [SIMD2<Float>] {
        func half(_ c: [Float], _ a: Float, _ b: Float) -> [SIMD2<Float>] {
            let n = c.count - 2
            return (0..<n).map { i in SIMD2(pow(10, a + Float(i) * (b - a) / Float(n - 1)), pow(10, (c[i] + c[i + 1]) / 2)) }
        }
        return half(coefsLow, logMin.x, logMid.x) + half(coefsHigh, logMid.x, logMax.x).dropFirst()
    }

    public func forward(_ x: Float) -> Float {
        let logx = log10(max(x, ACES.halfMin))
        let logy: Float
        if logx <= logMin.x {
            logy = logx * slopeLow + (logMin.y - slopeLow * logMin.x)
        } else if logx < logMid.x {
            logy = Self.evaluate(coefsLow, (logx - logMin.x) / (logMid.x - logMin.x))
        } else if logx < logMax.x {
            logy = Self.evaluate(coefsHigh, (logx - logMid.x) / (logMax.x - logMid.x))
        } else {
            logy = logx * slopeHigh + (logMax.y - slopeHigh * logMax.x)
        }
        return pow(10, logy)
    }

    /// The inverse inside `minPoint.y`…`maxPoint.y`, clamped to the end points outside it.
    public func reverse(_ y: Float) -> Float {
        let logy = log10(max(y, 1e-10))
        let logx: Float
        if logy <= logMin.y {
            logx = logMin.x
        } else if logy <= logMid.y {
            logx = logMin.x + Self.solve(coefsLow, logy) * (logMid.x - logMin.x)
        } else if logy < logMax.y {
            logx = logMid.x + Self.solve(coefsHigh, logy) * (logMax.x - logMid.x)
        } else {
            logx = logMax.x
        }
        return pow(10, logx)
    }

    /// One half at `u` 0…1 of its span.
    static func evaluate(_ c: [Float], _ u: Float) -> Float {
        let segments = c.count - 3
        let coord = Float(segments) * u
        let j = min(max(Int(coord), 0), segments - 1)
        let t = coord - Float(j)
        let (a, b, k) = basis(c, j)
        return (a * t + b) * t + k
    }

    /// The `u` 0…1 where one half reaches `logy`.
    static func solve(_ c: [Float], _ logy: Float) -> Float {
        let segments = c.count - 3
        var j = 0
        while j < segments - 1, logy > (c[j + 1] + c[j + 2]) / 2 { j += 1 }
        let (a, b, k) = basis(c, j)
        let cc = k - logy
        let d = max(b * b - 4 * a * cc, 0).squareRoot()
        let t = 2 * cc / (-d - b)
        return (t + Float(j)) / Float(segments)
    }

    /// Monomial coefficients (t², t, 1) of segment `j`.
    static func basis(_ c: [Float], _ j: Int) -> (Float, Float, Float) {
        (0.5 * c[j] - c[j + 1] + 0.5 * c[j + 2], c[j + 1] - c[j], 0.5 * (c[j] + c[j + 1]))
    }
}
