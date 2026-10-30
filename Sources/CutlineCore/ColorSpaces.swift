import Foundation
import simd

// MARK: Primaries

/// RGB primaries and white point as CIE 1931 xy chromaticities.
public struct Primaries: Equatable, Sendable {
    public var red: SIMD2<Double>
    public var green: SIMD2<Double>
    public var blue: SIMD2<Double>
    public var white: SIMD2<Double>

    public init(red: SIMD2<Double>, green: SIMD2<Double>, blue: SIMD2<Double>, white: SIMD2<Double>) {
        self.red = red
        self.green = green
        self.blue = blue
        self.white = white
    }

    public static let d65 = SIMD2(0.3127, 0.3290)
    public static let d60 = SIMD2(0.32168, 0.33767)

    public static let rec709 = Primaries(red: [0.64, 0.33], green: [0.30, 0.60], blue: [0.15, 0.06], white: d65)
    public static let p3D65 = Primaries(red: [0.680, 0.320], green: [0.265, 0.690], blue: [0.150, 0.060], white: d65)
    public static let rec2020 = Primaries(red: [0.708, 0.292], green: [0.170, 0.797], blue: [0.131, 0.046], white: d65)
    public static let acesAP0 = Primaries(red: [0.7347, 0.2653], green: [0.0, 1.0], blue: [0.0001, -0.0770], white: d60)
    public static let acesAP1 = Primaries(red: [0.713, 0.293], green: [0.165, 0.830], blue: [0.128, 0.044], white: d60)

    public static let sGamut3Cine = Primaries(red: [0.766, 0.275], green: [0.225, 0.800], blue: [0.089, -0.087], white: d65)
    public static let sGamut3 = Primaries(red: [0.730, 0.280], green: [0.140, 0.855], blue: [0.100, -0.050], white: d65)
    public static let arriWideGamut3 = Primaries(red: [0.6840, 0.3130], green: [0.2210, 0.8480], blue: [0.0861, -0.1020], white: d65)
    public static let arriWideGamut4 = Primaries(red: [0.7347, 0.2653], green: [0.1424, 0.8576], blue: [0.0991, -0.0308], white: d65)
    public static let vGamut = Primaries(red: [0.730, 0.280], green: [0.165, 0.840], blue: [0.100, -0.030], white: d65)
    public static let canonCinemaGamut = Primaries(red: [0.740, 0.270], green: [0.170, 1.140], blue: [0.080, -0.100], white: d65)
    /// Fujifilm F-Gamut shares the BT.2020 primaries.
    public static let fGamut = rec2020
    public static let blackmagicWideGamut = Primaries(red: [0.7177215, 0.3171181], green: [0.2280410, 0.8615690], blue: [0.1005841, -0.0820452], white: [0.3127170, 0.3290312])
    public static let redWideGamutRGB = Primaries(red: [0.780308, 0.304253], green: [0.121595, 1.493994], blue: [0.095612, -0.084589], white: d65)
    public static let djiDGamut = Primaries(red: [0.71, 0.31], green: [0.21, 0.88], blue: [0.09, -0.08], white: d65)

    /// XYZ (Y of white = 1) from xy.
    static func xyz(_ xy: SIMD2<Double>) -> SIMD3<Double> {
        SIMD3(xy.x / xy.y, 1, (1 - xy.x - xy.y) / xy.y)
    }

    /// Linear RGB to CIE XYZ, normalized so white has Y = 1.
    public var toXYZ: simd_double3x3 {
        let m = simd_double3x3(columns: (Self.xyz(red), Self.xyz(green), Self.xyz(blue)))
        let s = m.inverse * Self.xyz(white)
        return simd_double3x3(columns: (m.columns.0 * s.x, m.columns.1 * s.y, m.columns.2 * s.z))
    }

    /// Bradford chromatic adaptation between two white points in XYZ.
    public static func bradford(from src: SIMD2<Double>, to dst: SIMD2<Double>) -> simd_double3x3 {
        let b = simd_double3x3(rows: [
            SIMD3(0.8951, 0.2664, -0.1614),
            SIMD3(-0.7502, 1.7135, 0.0367),
            SIMD3(0.0389, -0.0685, 1.0296),
        ])
        let s = b * xyz(src), d = b * xyz(dst)
        let scale = simd_double3x3(diagonal: d / s)
        return b.inverse * scale * b
    }

    /// Converts linear RGB in `from` to linear RGB in `to`, adapting white with Bradford when the whites differ.
    public static func matrix(from: Primaries, to: Primaries) -> simd_double3x3 {
        var m = from.toXYZ
        if simd_distance(from.white, to.white) > 1e-6 { m = bradford(from: from.white, to: to.white) * m }
        return to.toXYZ.inverse * m
    }
}

extension simd_double3x3 {
    var float: simd_float3x3 {
        simd_float3x3(columns: (SIMD3<Float>(columns.0), SIMD3<Float>(columns.1), SIMD3<Float>(columns.2)))
    }
}

// MARK: Transfer functions

/// Display and HDR transfer functions. `encode` maps linear light to a signal, `decode` the reverse.
public enum TransferFunction: String, CaseIterable, Codable, Sendable {
    case linear, srgb, bt1886, gamma22, gamma26, pq, hlg

    /// For `pq`, linear 1 is 10 000 nits; for `hlg`, linear is the scene light of the OETF (0…1).
    public func encode(_ v: Float) -> Float {
        switch self {
        case .linear: v
        case .srgb: Transfer.srgbEncode(v)
        case .bt1886: Transfer.gammaEncode(v, 2.4)
        case .gamma22: Transfer.gammaEncode(v, 2.2)
        case .gamma26: Transfer.gammaEncode(v, 2.6)
        case .pq: Transfer.pqEncode(nits: v * 10_000)
        case .hlg: Transfer.hlgOETF(v)
        }
    }

    public func decode(_ v: Float) -> Float {
        switch self {
        case .linear: v
        case .srgb: Transfer.srgbDecode(v)
        case .bt1886: Transfer.gammaDecode(v, 2.4)
        case .gamma22: Transfer.gammaDecode(v, 2.2)
        case .gamma26: Transfer.gammaDecode(v, 2.6)
        case .pq: Transfer.pqDecode(v) / 10_000
        case .hlg: Transfer.hlgInverseOETF(v)
        }
    }
}

/// Transfer function math. Negative inputs are mirrored where the curve is a power law.
public enum Transfer {
    public static func srgbEncode(_ v: Float) -> Float {
        let a = abs(v)
        let e = a <= 0.0031308 ? a * 12.92 : 1.055 * pow(a, 1 / 2.4) - 0.055
        return v < 0 ? -e : e
    }

    public static func srgbDecode(_ v: Float) -> Float {
        let a = abs(v)
        let d = a <= 0.04045 ? a / 12.92 : pow((a + 0.055) / 1.055, 2.4)
        return v < 0 ? -d : d
    }

    /// Pure power law: BT.1886 with zero black is `gamma` 2.4.
    public static func gammaEncode(_ v: Float, _ gamma: Float) -> Float {
        v < 0 ? -pow(-v, 1 / gamma) : pow(v, 1 / gamma)
    }

    public static func gammaDecode(_ v: Float, _ gamma: Float) -> Float {
        v < 0 ? -pow(-v, gamma) : pow(v, gamma)
    }

    static let pqM1: Float = 2610 / 16384
    static let pqM2: Float = 2523 / 4096 * 128
    static let pqC1: Float = 3424 / 4096
    static let pqC2: Float = 2413 / 4096 * 32
    static let pqC3: Float = 2392 / 4096 * 32

    /// SMPTE ST 2084 inverse EOTF: absolute luminance in cd/m² to a 0…1 signal.
    public static func pqEncode(nits: Float) -> Float {
        let y = pow(min(max(nits, 0) / 10_000, 1), pqM1)
        return pow((pqC1 + pqC2 * y) / (1 + pqC3 * y), pqM2)
    }

    /// SMPTE ST 2084 EOTF: a 0…1 signal to cd/m².
    public static func pqDecode(_ e: Float) -> Float {
        let p = pow(min(max(e, 0), 1), 1 / pqM2)
        return 10_000 * pow(max(p - pqC1, 0) / (pqC2 - pqC3 * p), 1 / pqM1)
    }

    static let hlgA: Float = 0.17883277
    static let hlgB: Float = 1 - 4 * hlgA
    static let hlgC: Float = 0.5 - hlgA * log(4 * hlgA)

    /// BT.2100 HLG OETF: normalized scene light 0…1 to a 0…1 signal.
    public static func hlgOETF(_ e: Float) -> Float {
        let e = max(e, 0)
        return e <= 1 / 12 ? (3 * e).squareRoot() : hlgA * log(12 * e - hlgB) + hlgC
    }

    public static func hlgInverseOETF(_ v: Float) -> Float {
        let v = max(v, 0)
        return v <= 0.5 ? v * v / 3 : (exp((v - hlgC) / hlgA) + hlgB) / 12
    }

    /// BT.2100 HLG system gamma for a display of nominal peak `peak` cd/m² (1.2 at 1000).
    public static func hlgSystemGamma(peak: Float) -> Float {
        1.2 + 0.42 * log10(peak / 1000)
    }

    static let rec2020Luma = SIMD3<Float>(0.2627, 0.6780, 0.0593)

    /// HLG OOTF: scene light (0…1, BT.2020) to display light in cd/m².
    public static func hlgOOTF(_ scene: SIMD3<Float>, peak: Float = 1000) -> SIMD3<Float> {
        let gamma = hlgSystemGamma(peak: peak)
        let ys = max((scene * rec2020Luma).sum(), 0)
        return ys > 0 ? scene * (peak * pow(ys, gamma - 1)) : .zero
    }

    /// Inverse HLG OOTF: display light in cd/m² (BT.2020) to scene light 0…1.
    public static func hlgInverseOOTF(_ display: SIMD3<Float>, peak: Float = 1000) -> SIMD3<Float> {
        let gamma = hlgSystemGamma(peak: peak)
        let yd = max((display * rec2020Luma).sum() / peak, 0)
        guard yd > 0 else { return .zero }
        let ys = pow(yd, 1 / gamma)
        return display / peak / pow(ys, gamma - 1)
    }

    /// HLG signal to display light in cd/m².
    public static func hlgEOTF(_ signal: SIMD3<Float>, peak: Float = 1000) -> SIMD3<Float> {
        hlgOOTF(SIMD3(hlgInverseOETF(signal.x), hlgInverseOETF(signal.y), hlgInverseOETF(signal.z)), peak: peak)
    }

    /// Display light in cd/m² to an HLG signal.
    public static func hlgInverseEOTF(_ nits: SIMD3<Float>, peak: Float = 1000) -> SIMD3<Float> {
        let s = hlgInverseOOTF(pointwiseMin(pointwiseMax(nits, .zero), SIMD3(repeating: peak)), peak: peak)
        return SIMD3(hlgOETF(s.x), hlgOETF(s.y), hlgOETF(s.z))
    }
}

// MARK: Camera log

/// Camera log encodings with their native gamuts. Decoding gives scene linear light where 0.18 is mid grey.
public enum LogProfile: String, CaseIterable, Codable, Sendable {
    /// Apple Log, BT.2020 primaries.
    case apple_log
    /// Sony S-Log3 / S-Gamut3.Cine.
    case slog3
    /// Sony S-Log3 / S-Gamut3.
    case slog3_sgamut3
    /// ARRI LogC3 (EI 800) / ARRI Wide Gamut 3.
    case logc3
    /// ARRI LogC4 / ARRI Wide Gamut 4.
    case logc4
    /// Panasonic V-Log / V-Gamut.
    case vlog
    /// Canon Log 2 / Cinema Gamut.
    case clog2
    /// Canon Log 3 / Cinema Gamut.
    case clog3
    /// Fujifilm F-Log / F-Gamut.
    case flog
    /// Fujifilm F-Log2 / F-Gamut.
    case flog2
    /// Nikon N-Log / BT.2020.
    case nlog
    /// Blackmagic Film Gen 5 / Blackmagic Wide Gamut Gen 5.
    case bmd_film_gen5
    /// RED Log3G10 / REDWideGamutRGB.
    case redlog3g10
    /// DJI D-Log / D-Gamut.
    case dlog

    public var name: String {
        switch self {
        case .apple_log: "Apple Log (BT.2020)"
        case .slog3: "Sony S-Log3 / S-Gamut3.Cine"
        case .slog3_sgamut3: "Sony S-Log3 / S-Gamut3"
        case .logc3: "ARRI LogC3 EI800 / AWG3"
        case .logc4: "ARRI LogC4 / AWG4"
        case .vlog: "Panasonic V-Log / V-Gamut"
        case .clog2: "Canon Log 2 / Cinema Gamut"
        case .clog3: "Canon Log 3 / Cinema Gamut"
        case .flog: "Fujifilm F-Log / F-Gamut"
        case .flog2: "Fujifilm F-Log2 / F-Gamut"
        case .nlog: "Nikon N-Log / BT.2020"
        case .bmd_film_gen5: "Blackmagic Film Gen 5 / BMD Wide Gamut Gen 5"
        case .redlog3g10: "RED Log3G10 / REDWideGamutRGB"
        case .dlog: "DJI D-Log / D-Gamut"
        }
    }

    public var primaries: Primaries {
        switch self {
        case .apple_log, .nlog: .rec2020
        case .slog3: .sGamut3Cine
        case .slog3_sgamut3: .sGamut3
        case .logc3: .arriWideGamut3
        case .logc4: .arriWideGamut4
        case .vlog: .vGamut
        case .clog2, .clog3: .canonCinemaGamut
        case .flog, .flog2: .fGamut
        case .bmd_film_gen5: .blackmagicWideGamut
        case .redlog3g10: .redWideGamutRGB
        case .dlog: .djiDGamut
        }
    }

    /// How the published curve's 0…1 signal relates to the recorded code values.
    /// `.full` curves are written as code value / 1023 (S-Log3 grey is CV 420 = 0.41);
    /// `.video` curves are written as a normalized video signal (Canon "IRE", Apple Log), 0 at CV 64 and 1 at CV 940.
    public var curveRange: SignalRange {
        switch self {
        case .apple_log, .clog2, .clog3: .video
        default: .full
        }
    }

    /// The published decode: curve signal (in the curve's own 0…1 convention, see `curveRange`) to scene linear.
    public func toLinear(_ v: Float) -> Float {
        switch self {
        case .apple_log:
            let (r0, rt, c, b, g, d) = Self.appleLog
            let pt = c * (rt - r0) * (rt - r0)
            if v >= pt { return pow(2, (v - d) / g) - b }
            return v >= 0 ? (v / c).squareRoot() + r0 : r0
        case .slog3, .slog3_sgamut3:
            let cv = v * 1023
            return cv >= 171.2102946929 ? pow(10, (cv - 420) / 261.5) * 0.19 - 0.01 : (cv - 95) * 0.01125 / (171.2102946929 - 95)
        case .logc3:
            let (cut, a, b, c, d, e, f) = Self.logC3
            return v > e * cut + f ? (pow(10, (v - d) / c) - b) / a : (v - f) / e
        case .logc4:
            let (a, b, c, s, t) = Self.logC4
            return v >= 0 ? (pow(2, 14 * (v - c) / b + 6) - 64) / a : v * s + t
        case .vlog:
            return v < 0.181 ? (v - 0.125) / 5.6 : pow(10, (v - 0.598206) / 0.241514) - 0.00873
        case .clog2:
            let x = v < 0.035388128
                ? -(pow(10, (0.035388128 - v) / 0.281863093) - 1) / 87.09937546
                : (pow(10, (v - 0.035388128) / 0.281863093) - 1) / 87.09937546
            return x * 0.9
        case .clog3:
            let x: Float
            if v < 0.097465473 { x = -(pow(10, (0.12783901 - v) / 0.36726845) - 1) / 14.98325 }
            else if v <= 0.15277891 { x = (v - 0.12512219) / 1.9754798 }
            else { x = (pow(10, (v - 0.12240537) / 0.36726845) - 1) / 14.98325 }
            return x * 0.9
        case .flog, .flog2:
            let (a, b, c, d, e, f, _, cut2) = self == .flog ? Self.fLog : Self.fLog2
            return v >= cut2 ? (pow(10, (v - d) / c) - b) / a : (v - f) / e
        case .nlog:
            let cv = v * 1023
            return cv < 452 ? pow(max(cv, 0) / 650, 3) - 0.0075 : exp((cv - 619) / 150)
        case .bmd_film_gen5:
            let (a, b, c, d, e, linCut) = Self.bmdGen5
            return v < d * linCut + e ? (v - e) / d : exp((v - c) / a) - b
        case .redlog3g10:
            let (a, b, c, g) = Self.log3G10
            return v < 0 ? v / g - c : (pow(10, v / a) - 1) / b - c
        case .dlog:
            return v <= 0.14 ? (v - 0.0929) / 6.025 : (pow(10, 3.89616 * v - 2.27752) - 0.0108) / 0.9892
        }
    }

    /// The published encode: scene linear to the curve signal.
    public func fromLinear(_ x: Float) -> Float {
        switch self {
        case .apple_log:
            let (r0, rt, c, b, g, d) = Self.appleLog
            if x >= rt { return g * log2(x + b) + d }
            return x >= r0 ? c * (x - r0) * (x - r0) : 0
        case .slog3, .slog3_sgamut3:
            let cv = x >= 0.01125 ? 420 + log10((x + 0.01) / 0.19) * 261.5 : x * (171.2102946929 - 95) / 0.01125 + 95
            return cv / 1023
        case .logc3:
            let (cut, a, b, c, d, e, f) = Self.logC3
            return x > cut ? c * log10(a * x + b) + d : e * x + f
        case .logc4:
            let (a, b, c, s, t) = Self.logC4
            return x >= t ? (log2(a * x + 64) - 6) / 14 * b + c : (x - t) / s
        case .vlog:
            return x < 0.01 ? 5.6 * x + 0.125 : 0.241514 * log10(x + 0.00873) + 0.598206
        case .clog2:
            let r = x / 0.9
            return r < 0 ? -0.281863093 * log10(-r * 87.09937546 + 1) + 0.035388128 : 0.281863093 * log10(r * 87.09937546 + 1) + 0.035388128
        case .clog3:
            let r = x / 0.9
            if r < -0.014 { return -0.36726845 * log10(-r * 14.98325 + 1) + 0.12783901 }
            if r <= 0.014 { return 1.9754798 * r + 0.12512219 }
            return 0.36726845 * log10(r * 14.98325 + 1) + 0.12240537
        case .flog, .flog2:
            let (a, b, c, d, e, f, cut1, _) = self == .flog ? Self.fLog : Self.fLog2
            return x >= cut1 ? c * log10(a * x + b) + d : e * x + f
        case .nlog:
            let cv = x < 0.328 ? 650 * cbrt(x + 0.0075) : 150 * log(x) + 619
            return cv / 1023
        case .bmd_film_gen5:
            let (a, b, c, d, e, linCut) = Self.bmdGen5
            return x < linCut ? d * x + e : a * log(x + b) + c
        case .redlog3g10:
            let (a, b, c, g) = Self.log3G10
            let y = x + c
            return y < 0 ? y * g : a * log10(y * b + 1)
        case .dlog:
            return x <= 0.0078 ? 6.025 * x + 0.0929 : log10(x * 0.9892 + 0.0108) * 0.256663 + 0.584555
        }
    }

    /// Decodes a decoder's RGB value: `range` is how the source was recorded (nearly all camera files are `.video`).
    public func toLinear(_ v: Float, recordedIn range: SignalRange) -> Float {
        toLinear(range.convert(v, to: curveRange))
    }

    // Constants from each vendor's published specification.
    static let appleLog: (Float, Float, Float, Float, Float, Float) = (-0.05641088, 0.01, 47.28711236, 0.00964052, 0.08550479, 0.69336945)
    static let logC3: (Float, Float, Float, Float, Float, Float, Float) = (0.010591, 5.555556, 0.052272, 0.247190, 0.385537, 5.367655, 0.092809)
    static let logC4: (Float, Float, Float, Float, Float) = {
        let a: Float = (pow(2, 18) - 16) / 117.45
        let b: Float = (1023 - 95) / 1023
        let c: Float = 95 / 1023
        let s: Float = (7 * log(2) * pow(2, 7 - 14 * c / b)) / (a * b)
        let t: Float = (pow(2, 14 * (-c / b) + 6) - 64) / a
        return (a, b, c, s, t)
    }()
    static let fLog: (Float, Float, Float, Float, Float, Float, Float, Float) = (0.555556, 0.009468, 0.344676, 0.790453, 8.735631, 0.092864, 0.00089, 0.100537775223865)
    static let fLog2: (Float, Float, Float, Float, Float, Float, Float, Float) = (5.555556, 0.064829, 0.245281, 0.384316, 8.799461, 0.092864, 0.000889, 0.100686685370811)
    static let bmdGen5: (Float, Float, Float, Float, Float, Float) = (0.08692876065491224, 0.005494072432257808, 0.5300133392291939, 8.283605932402494, 0.09246575342465753, 0.005)
    static let log3G10: (Float, Float, Float, Float) = (0.224282, 155.975327, 0.01, 15.1927)
}

/// How 10-bit code values map to a decoder's 0…1: video range puts 0 at CV 64 and 1 at CV 940; full range is CV / 1023.
public enum SignalRange: String, Codable, Sendable {
    case video, full

    public func convert(_ v: Float, to other: SignalRange) -> Float {
        switch (self, other) {
        case (.video, .full): (v * 876 + 64) / 1023
        case (.full, .video): (v * 1023 - 64) / 876
        default: v
        }
    }
}

// MARK: Tone mapping

/// Scene-linear to display-linear (0…1) tone curves, applied per channel.
public enum ToneMap: String, CaseIterable, Codable, Sendable {
    /// Clip at 1.
    case none
    /// `x / (1 + x)`.
    case reinhard
    /// ACES 1.x RRT + sRGB ODT approximation (Stephen Hill's fit, with the RRT/ODT saturation in AP1).
    case aces
    /// John Hable's Uncharted 2 filmic curve, white point 11.2, exposure bias 2.
    case hable

    /// `c` is scene linear with Rec.709 primaries; `exposure` is in stops.
    public static func apply(_ c: SIMD3<Float>, _ m: ToneMap, exposure: Float) -> SIMD3<Float> {
        apply(c, m, exposure: exposure, gamut: .rec709)
    }

    /// `c` is scene linear in `gamut`; the result is display linear in the same gamut, 0…1.
    public static func apply(_ c: SIMD3<Float>, _ m: ToneMap, exposure: Float, gamut: Primaries) -> SIMD3<Float> {
        let x = pointwiseMax(c * pow(2, exposure), .zero)
        let out: SIMD3<Float>
        switch m {
        case .none: out = x
        case .reinhard: out = x / (1 + x)
        case .hable: out = SIMD3(hable(x.x), hable(x.y), hable(x.z))
        case .aces:
            let (input, output) = acesMatrices(gamut)
            let v = input * x
            out = output * SIMD3(acesFit(v.x), acesFit(v.y), acesFit(v.z))
        }
        return simd_clamp(out, .zero, SIMD3(repeating: 1))
    }

    /// One channel of the curve, without gamut handling; monotonic, 0 at 0, below 1.
    public static func curve(_ x: Float, _ m: ToneMap) -> Float {
        let x = max(x, 0)
        switch m {
        case .none: return min(x, 1)
        case .reinhard: return x / (1 + x)
        case .hable: return hable(x)
        case .aces: return min(max(acesFit(x), 0), 1)
        }
    }

    static func acesFit(_ v: Float) -> Float {
        (v * (v + 0.0245786) - 0.000090537) / (v * (0.983729 * v + 0.4329510) + 0.238081)
    }

    static func hableCurve(_ x: Float) -> Float {
        let a: Float = 0.15, b: Float = 0.50, c: Float = 0.10, d: Float = 0.20, e: Float = 0.02, f: Float = 0.30
        return (x * (a * x + c * b) + d * e) / (x * (a * x + b) + d * f) - e / f
    }

    static let hableWhite = hableCurve(11.2)

    static func hable(_ x: Float) -> Float { min(max(hableCurve(2 * x) / hableWhite, 0), 1) }

    /// AP1 luminance weights used by the ACES RRT/ODT saturation matrices.
    static let ap1Luma = SIMD3<Double>(0.2722287168, 0.6740817658, 0.0536895174)

    static func saturation(_ s: Double) -> simd_double3x3 {
        let l = ap1Luma * (1 - s)
        return simd_double3x3(rows: [l + SIMD3(s, 0, 0), l + SIMD3(0, s, 0), l + SIMD3(0, 0, s)])
    }

    static let acesCache = Locked<[Primaries: (simd_float3x3, simd_float3x3)]>([:])

    /// (gamut → AP1 with RRT saturation, ODT saturation then AP1 → gamut). For Rec.709 this is Hill's ACESInputMat/ACESOutputMat.
    static func acesMatrices(_ gamut: Primaries) -> (simd_float3x3, simd_float3x3) {
        if let hit = acesCache.withLock({ $0[gamut] }) { return hit }
        let input = saturation(0.96) * Primaries.matrix(from: gamut, to: .acesAP1)
        let output = Primaries.matrix(from: .acesAP1, to: gamut) * saturation(0.93)
        let pair = (input.float, output.float)
        acesCache.withLock { $0[gamut] = pair }
        return pair
    }
}

extension Primaries: Hashable {
    public func hash(into h: inout Hasher) {
        for v in [red, green, blue, white] { h.combine(v.x); h.combine(v.y) }
    }
}

final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func withLock<R>(_ f: (inout T) -> R) -> R { lock.withLock { f(&value) } }
}

// MARK: Pipeline

/// A display encoding the timeline is graded and delivered in.
public enum WorkingSpace: String, CaseIterable, Codable, Sendable {
    /// BT.709 primaries, BT.1886 (gamma 2.4) encoding.
    case rec709
    /// Display P3: P3-D65 primaries, sRGB encoding.
    case p3
    /// BT.2100 HLG, 1000 cd/m² nominal peak.
    case rec2020_hlg
    /// BT.2100 PQ.
    case rec2020_pq

    public var isHDR: Bool { self == .rec2020_hlg || self == .rec2020_pq }

    public var primaries: Primaries {
        switch self {
        case .rec709: .rec709
        case .p3: .p3D65
        case .rec2020_hlg, .rec2020_pq: .rec2020
        }
    }

    public var transfer: TransferFunction {
        switch self {
        case .rec709: .bt1886
        case .p3: .srgb
        case .rec2020_hlg: .hlg
        case .rec2020_pq: .pq
        }
    }

    /// Peak luminance tone curves roll highlights off to, in cd/m².
    public var peakNits: Float { isHDR ? 1000 : 100 }
}

/// Builds transforms from camera or display encodings to a working space's encoding, for baking into 3D LUTs.
///
/// Scene linear is relative: 0.18 is mid grey, 1 is diffuse white. SDR outputs tone-map that to display linear 0…1.
/// HDR outputs put diffuse white at 203 cd/m² (BT.2408) with `.none`; tone curves keep mid grey where `.none` puts it
/// and roll highlights off to the 1000 cd/m² peak.
public enum ColorPipeline {
    /// BT.2408 HDR reference white.
    public static let referenceWhiteNits: Float = 203

    /// Encoded log RGB (0…1, as decoded from a file recorded in `recordedIn`) to the encoded `target` signal.
    /// `exposure` is in stops, applied in scene linear before tone mapping.
    public static func inputTransform(log: LogProfile, target: WorkingSpace, tone: ToneMap, exposure: Float, recordedIn: SignalRange = .video) -> ColorMath.Transform {
        let m = Primaries.matrix(from: log.primaries, to: target.primaries).float
        let encode = output(target: target, tone: tone, exposure: exposure)
        let range = recordedIn
        return { c in
            let lin = SIMD3(log.toLinear(c.x, recordedIn: range), log.toLinear(c.y, recordedIn: range), log.toLinear(c.z, recordedIn: range))
            return encode(m * lin)
        }
    }

    /// One display encoding to another. With `.none` and no exposure, SDR-to-SDR and HDR-to-HDR conversions keep
    /// colors that fit both gamuts unchanged; SDR white lands on 203 cd/m² in HDR.
    public static func displayTransform(from source: WorkingSpace, to target: WorkingSpace, tone: ToneMap, exposure: Float) -> ColorMath.Transform {
        let m = Primaries.matrix(from: source.primaries, to: target.primaries).float
        let decode = sceneLinear(source)
        let encode = output(target: target, tone: tone, exposure: exposure)
        return { c in encode(m * decode(c)) }
    }

    /// The inverse of `output(target:tone: .none, exposure: 0)`: a display signal to relative scene linear.
    public static func sceneLinear(_ source: WorkingSpace) -> ColorMath.Transform {
        switch source {
        case .rec709, .p3:
            let t = source.transfer
            return { c in SIMD3(t.decode(c.x), t.decode(c.y), t.decode(c.z)) }
        case .rec2020_pq:
            return { c in SIMD3(Transfer.pqDecode(c.x), Transfer.pqDecode(c.y), Transfer.pqDecode(c.z)) / referenceWhiteNits }
        case .rec2020_hlg:
            return { c in Transfer.hlgEOTF(c) / referenceWhiteNits }
        }
    }

    /// Relative scene linear in the target's primaries to the encoded target signal, clamped to 0…1.
    public static func output(target: WorkingSpace, tone: ToneMap, exposure: Float) -> ColorMath.Transform {
        let gamut = target.primaries
        let gain = pow(2, exposure)
        if !target.isHDR {
            let t = target.transfer
            return { c in
                let d = ToneMap.apply(pointwiseMax(c, .zero) * gain, tone, exposure: 0, gamut: gamut)
                return SIMD3(t.encode(d.x), t.encode(d.y), t.encode(d.z))
            }
        }
        let peak = target.peakNits
        let curveGain = tone == .none ? 1 : hdrGain(tone, peak: peak)
        let nits: (SIMD3<Float>) -> SIMD3<Float> = tone == .none
            ? { c in c * referenceWhiteNits }
            : { c in ToneMap.apply(c * curveGain, tone, exposure: 0, gamut: gamut) * peak }
        if target == .rec2020_pq {
            return { c in
                let n = nits(pointwiseMax(c, .zero) * gain)
                return SIMD3(Transfer.pqEncode(nits: n.x), Transfer.pqEncode(nits: n.y), Transfer.pqEncode(nits: n.z))
            }
        }
        return { c in Transfer.hlgInverseEOTF(nits(pointwiseMax(c, .zero) * gain), peak: peak) }
    }

    /// Scale applied before an HDR tone curve so mid grey lands where the linear `.none` mapping puts it.
    static func hdrGain(_ tone: ToneMap, peak: Float) -> Float {
        let goal = 0.18 * referenceWhiteNits / peak
        var lo: Float = 1e-4, hi: Float = 1e3
        for _ in 0..<80 {
            let mid = (lo * hi).squareRoot()
            if ToneMap.curve(0.18 * mid, tone) < goal { lo = mid } else { hi = mid }
        }
        return (lo * hi).squareRoot()
    }
}
