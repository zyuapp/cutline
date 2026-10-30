import Foundation

/// An HSL qualifier like a grading suite's: a soft key on the hue, saturation and luma of display-referred
/// (sRGB-encoded) color, then matte cleanup.
///
/// Hue is the HSV hue in degrees (0 red, 30 orange, 60 yellow, 120 green, 210 sky, 240 blue). Saturation is HSV
/// saturation with values under 0.12 treated as 0.12, so noise in near-black pixels does not read as saturated.
/// Luma is Rec. 709 Y′. Each range is full strength from low to high and falls to 0 over its softness.
public struct Qualifier: Equatable, Sendable {
    public var hue: Double
    /// Full-strength hue range, centered on `hue`.
    public var hueWidth: Double
    /// Degrees beyond the range over which the key falls to 0.
    public var hueSoft: Double
    public var satLow: Double, satHigh: Double, satSoft: Double
    public var lumaLow: Double, lumaHigh: Double, lumaSoft: Double
    /// Key values at or below `cleanBlack` become 0; at or above 1 − `cleanWhite` become 1.
    public var cleanBlack: Double, cleanWhite: Double
    /// Matte blur radius, fraction of the frame height.
    public var blur: Double
    /// Morphological open then close radius, fraction of the frame height: drops specks and fills pinholes.
    public var denoise: Double

    public init(hue: Double = 30, hueWidth: Double = 40, hueSoft: Double = 10, satLow: Double = 0.1, satHigh: Double = 1, satSoft: Double = 0.05, lumaLow: Double = 0, lumaHigh: Double = 1, lumaSoft: Double = 0.05, cleanBlack: Double = 0, cleanWhite: Double = 0, blur: Double = 0.002, denoise: Double = 0.0015) {
        self.hue = hue
        self.hueWidth = hueWidth
        self.hueSoft = hueSoft
        self.satLow = satLow
        self.satHigh = satHigh
        self.satSoft = satSoft
        self.lumaLow = lumaLow
        self.lumaHigh = lumaHigh
        self.lumaSoft = lumaSoft
        self.cleanBlack = cleanBlack
        self.cleanWhite = cleanWhite
        self.blur = blur
        self.denoise = denoise
    }

    /// Skin of every complexion under roughly neutral light: red-orange hues, moderate saturation, shadows to highlights.
    public static let skin = Qualifier(hue: 13, hueWidth: 38, hueSoft: 8, satLow: 0.13, satHigh: 0.52, satSoft: 0.07, lumaLow: 0.2, lumaHigh: 0.9, lumaSoft: 0.1, cleanBlack: 0.1, cleanWhite: 0.1, blur: 0.003, denoise: 0.003)

    public static let presets: [String: Qualifier] = ["skin": skin]

    /// Parameter names, as in the effect catalog.
    public static let names: [(String, WritableKeyPath<Qualifier, Double>)] = [
        ("q_hue", \.hue), ("q_hue_width", \.hueWidth), ("q_hue_soft", \.hueSoft),
        ("q_sat_min", \.satLow), ("q_sat_max", \.satHigh), ("q_sat_soft", \.satSoft),
        ("q_luma_min", \.lumaLow), ("q_luma_max", \.lumaHigh), ("q_luma_soft", \.lumaSoft),
        ("q_clean_black", \.cleanBlack), ("q_clean_white", \.cleanWhite), ("q_blur", \.blur), ("q_denoise", \.denoise),
    ]

    /// The qualifier an effect's parameters describe: `q_preset` first, then every q_* parameter set on the effect.
    /// A bare `q_softness` sets all three softnesses (hue softness as that fraction of 90°).
    public init(params: [String: ParamValue]) {
        self = params["q_preset"]?.string.flatMap { Self.presets[$0] } ?? Qualifier()
        if let s = params["q_softness"]?.number {
            if params["q_hue_soft"] == nil { hueSoft = s * 90 }
            if params["q_sat_soft"] == nil { satSoft = s }
            if params["q_luma_soft"] == nil { lumaSoft = s }
        }
        for (name, path) in Self.names { if let v = params[name]?.number { self[keyPath: path] = v } }
    }

    /// The q_* parameters that reproduce this qualifier.
    public var params: [String: ParamValue] {
        var out: [String: ParamValue] = [:]
        for (name, path) in Self.names { out[name] = .number((self[keyPath: path] * 1000).rounded() / 1000) }
        return out
    }

    /// Hue in degrees, guarded saturation and luma of an sRGB-encoded color.
    public static func components(_ c: SIMD3<Float>) -> (hue: Double, sat: Double, luma: Double, chroma: Double) {
        let r = Double(c.x), g = Double(c.y), b = Double(c.z)
        let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
        var h = 0.0
        if d > 1e-6 {
            if mx == r { h = 60 * ((g - b) / d).truncatingRemainder(dividingBy: 6) }
            else if mx == g { h = 60 * ((b - r) / d + 2) } else { h = 60 * ((r - g) / d + 4) }
            if h < 0 { h += 360 }
        }
        return (h, d / max(mx, 0.12), 0.2126 * r + 0.7152 * g + 0.0722 * b, d)
    }

    /// Key strength 0…1 for an sRGB-encoded color, before matte cleanup.
    public func weight(_ c: SIMD3<Float>) -> Float {
        let p = Self.components(c)
        var w = Self.band(p.sat, satLow, satHigh, satSoft) * Self.band(p.luma, lumaLow, lumaHigh, lumaSoft)
        guard w > 0 else { return 0 }
        if hueWidth < 360 {
            // Neutral colors have no hue: they only qualify through a full hue range.
            guard p.chroma > 1e-4 else { return 0 }
            w *= Self.band(Self.hueDistance(p.hue, hue), 0, hueWidth / 2, hueSoft)
        }
        return Float(w)
    }

    /// Key values at `low` map to 0 and at `high` to 1.
    public var cleanLevels: (low: Double, high: Double) {
        (min(max(cleanBlack, 0), 0.49), max(min(1 - cleanWhite, 1), 0.51))
    }

    /// A key value after the clean black/white levels.
    public func clean(_ k: Double) -> Double {
        let l = cleanLevels
        return min(max((k - l.low) / (l.high - l.low), 0), 1)
    }

    static func hueDistance(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b).truncatingRemainder(dividingBy: 360)
        return d > 180 ? 360 - d : d
    }

    /// 1 inside lo…hi, easing to 0 over `soft` outside it.
    static func band(_ x: Double, _ lo: Double, _ hi: Double, _ soft: Double) -> Double {
        let d = max(lo - x, x - hi, 0)
        guard d > 0 else { return 1 }
        guard soft > 1e-6 else { return 0 }
        let t = min(d / soft, 1)
        return 1 - t * t * (3 - 2 * t)
    }

    /// The eyedropper: ranges that cover the sampled colors (sRGB-encoded) with a little margin, ignoring the
    /// most extreme 10% on each side. Nil when the samples are too neutral to give a hue.
    public static func pick(_ samples: [SIMD3<Float>]) -> Qualifier? {
        let parts = samples.map(components)
        guard parts.count >= 4 else { return nil }
        func at(_ s: [Double], _ q: Double) -> Double { s[min(s.count - 1, max(0, Int(q * Double(s.count - 1) + 0.5)))] }
        let colored = parts.filter { $0.chroma > 0.02 }
        guard colored.count >= parts.count / 4 else { return nil }
        // Circular mean of hue, weighted by saturation.
        var x = 0.0, y = 0.0
        for p in colored {
            x += cos(p.hue * .pi / 180) * p.sat
            y += sin(p.hue * .pi / 180) * p.sat
        }
        var center = atan2(y, x) * 180 / .pi
        if center < 0 { center += 360 }
        let offsets = colored.map { p -> Double in
            var d = p.hue - center
            if d > 180 { d -= 360 }
            if d < -180 { d += 360 }
            return d
        }.sorted()
        let lo = at(offsets, 0.05), hi = at(offsets, 0.95)
        var mid = center + (lo + hi) / 2
        if mid < 0 { mid += 360 }
        let width = max(16, hi - lo + 8)
        let sats = parts.map(\.sat).sorted(), lumas = parts.map(\.luma).sorted()
        return Qualifier(
            hue: mid.truncatingRemainder(dividingBy: 360), hueWidth: min(width, 180), hueSoft: max(8, width * 0.35),
            satLow: max(0, at(sats, 0.05) - 0.05), satHigh: min(1, at(sats, 0.95) + 0.08), satSoft: 0.08,
            lumaLow: max(0, at(lumas, 0.05) - 0.1), lumaHigh: min(1, at(lumas, 0.95) + 0.1), lumaSoft: 0.1,
            cleanBlack: 0.1, cleanWhite: 0.2, blur: 0.003, denoise: 0.003
        )
    }

    public var summary: String {
        func f(_ v: Double) -> String { String(format: "%.2f", v) }
        return "hue \(Int(hue.rounded()))° ±\(Int((hueWidth / 2).rounded()))° (soft \(Int(hueSoft.rounded()))°), sat \(f(satLow))–\(f(satHigh)), luma \(f(lumaLow))–\(f(lumaHigh))"
    }
}
