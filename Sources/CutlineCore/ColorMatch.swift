import Foundation

/// Shot matching: robust statistics of a picture in CIELAB, and a transform that moves one shot's
/// tones and colors onto a reference's, softened by `strength`.
public enum ColorMatch {
    public struct Stats: Codable, Equatable, Sendable {
        /// Median L, a and b.
        public var mean: SIMD3<Double>
        /// Half the 16th–84th percentile range of L, a and b (one standard deviation for normal data).
        public var sd: SIMD3<Double>
        /// L at the 5th, 25th, 50th, 75th and 95th percentiles.
        public var lightness: [Double]
        /// Median distance of a pixel's (a, b) from the median color: how colorful the shot is beyond its cast.
        public var chroma: Double
        /// Share of pixels in each of 5 lightness bands × 7 color classes (neutral, then six hue sectors); empty when unknown.
        public var histogram: [Double]

        public init(mean: SIMD3<Double>, sd: SIMD3<Double>, lightness: [Double]? = nil, chroma: Double? = nil, histogram: [Double] = []) {
            self.mean = mean
            self.sd = sd
            self.lightness = lightness ?? [-1.645, -0.674, 0, 0.674, 1.645].map { min(100, max(0, mean.x + $0 * sd.x)) }
            self.chroma = chroma ?? hypot(sd.y, sd.z) * 0.83
            self.histogram = histogram
        }
    }

    static let percentiles = [0.05, 0.25, 0.5, 0.75, 0.95]

    /// Robust statistics of sRGB-encoded pixels (0…1) in Lab; a few extreme pixels barely move them.
    public static func stats(_ pixels: [SIMD3<Float>]) -> Stats {
        guard !pixels.isEmpty else { return Stats(mean: SIMD3(50, 0, 0), sd: SIMD3(1, 1, 1)) }
        let labs = pixels.map(lab)
        func sorted(_ k: Int) -> [Double] { labs.map { $0[k] }.sorted() }
        func at(_ s: [Double], _ q: Double) -> Double { s[min(s.count - 1, Int(q * Double(s.count - 1) + 0.5))] }
        let L = sorted(0), A = sorted(1), B = sorted(2)
        let mean = SIMD3(at(L, 0.5), at(A, 0.5), at(B, 0.5))
        func spread(_ s: [Double]) -> Double { max((at(s, 0.84) - at(s, 0.16)) / 2, 1e-3) }
        let chroma = labs.map { hypot($0.y - mean.y, $0.z - mean.z) }.sorted()
        var histogram = [Double](repeating: 0, count: 35)
        for l in labs { histogram[bin(l)] += 1 }
        histogram = histogram.map { $0 / Double(labs.count) }
        return Stats(mean: mean, sd: SIMD3(spread(L), spread(A), spread(B)), lightness: percentiles.map { at(L, $0) }, chroma: max(at(chroma, 0.5), 1e-3), histogram: histogram)
    }

    static func bin(_ l: SIMD3<Double>) -> Int {
        let band = min(4, max(0, Int(l.x / 20)))
        guard hypot(l.y, l.z) >= 8 else { return band * 7 }
        var h = atan2(l.z, l.y) * 180 / .pi
        if h < 0 { h += 360 }
        return band * 7 + 1 + min(5, Int(h / 60))
    }

    /// Default largest change of lightness a match makes, in L units.
    public static let maxLightnessShift = 20.0

    /// How comparable a shot is with a reference before matching: big gaps mean different scenes or lighting,
    /// which a match LUT can't reconcile without wrecking the shot.
    public struct Comparison: Sendable {
        /// Reference median L minus the shot's.
        public var lightnessGap: Double
        /// Reference colorfulness over the shot's.
        public var colorfulnessRatio: Double
        /// Hellinger distance of the two histograms: 0 identical, 1 nothing in common.
        public var histogramDistance: Double
        /// Vision feature-print distance of the pictures' content, when measured (about 0 same shot, above 0.9 unrelated).
        public var contentDistance: Double?
        /// CIEDE2000 difference of the median colors.
        public var deltaE: Double
        public var warnings: [String]
    }

    public static func compare(_ shot: Stats, to reference: Stats, contentDistance: Double? = nil) -> Comparison {
        let gap = reference.mean.x - shot.mean.x
        let ratio = reference.chroma / max(shot.chroma, 1e-3)
        var bc = 0.0
        if shot.histogram.count == reference.histogram.count {
            for (p, q) in zip(shot.histogram, reference.histogram) { bc += (p * q).squareRoot() }
        }
        let hist = shot.histogram.isEmpty || reference.histogram.isEmpty ? 0 : max(0, 1 - bc).squareRoot()
        var warnings: [String] = []
        if abs(gap) > maxLightnessShift {
            warnings.append(String(format: "median lightness differs by %.0f L (%.0f vs %.0f): this shot is much %@", abs(gap), shot.mean.x, reference.mean.x, gap > 0 ? "darker" : "brighter"))
        }
        if ratio > 2.5 || ratio < 0.4 {
            warnings.append(String(format: "colorfulness differs %.1f× (%.1f vs %.1f)", max(ratio, 1 / ratio), shot.chroma, reference.chroma))
        }
        if hist > 0.6 { warnings.append(String(format: "tones and colors are distributed very differently (histogram distance %.2f)", hist)) }
        if let d = contentDistance, d > 0.9 { warnings.append(String(format: "the pictures show different content (feature-print distance %.2f)", d)) }
        return Comparison(lightnessGap: gap, colorfulnessRatio: ratio, histogramDistance: hist, contentDistance: contentDistance, deltaE: deltaE2000(shot.mean, reference.mean), warnings: warnings)
    }

    /// CIEDE2000 color difference of two Lab colors.
    public static func deltaE2000(_ x: SIMD3<Double>, _ y: SIMD3<Double>) -> Double {
        let (l1, a1, b1) = (x.x, x.y, x.z), (l2, a2, b2) = (y.x, y.y, y.z)
        let cm = (hypot(a1, b1) + hypot(a2, b2)) / 2
        let g = 0.5 * (1 - (pow(cm, 7) / (pow(cm, 7) + pow(25, 7))).squareRoot())
        let a1p = a1 * (1 + g), a2p = a2 * (1 + g)
        let c1p = hypot(a1p, b1), c2p = hypot(a2p, b2)
        func hue(_ b: Double, _ a: Double) -> Double {
            guard a != 0 || b != 0 else { return 0 }
            let h = atan2(b, a) * 180 / .pi
            return h < 0 ? h + 360 : h
        }
        let h1 = hue(b1, a1p), h2 = hue(b2, a2p)
        let dl = l2 - l1, dc = c2p - c1p
        var dh = 0.0
        if c1p * c2p != 0 {
            dh = h2 - h1
            if dh > 180 { dh -= 360 } else if dh < -180 { dh += 360 }
        }
        let dH = 2 * (c1p * c2p).squareRoot() * sin(dh * .pi / 360)
        let lm = (l1 + l2) / 2, cmp = (c1p + c2p) / 2
        var hm = h1 + h2
        if c1p * c2p != 0 {
            if abs(h1 - h2) <= 180 { hm /= 2 } else { hm = h1 + h2 < 360 ? (h1 + h2 + 360) / 2 : (h1 + h2 - 360) / 2 }
        }
        let t = 1 - 0.17 * cos((hm - 30) * .pi / 180) + 0.24 * cos(2 * hm * .pi / 180) + 0.32 * cos((3 * hm + 6) * .pi / 180) - 0.2 * cos((4 * hm - 63) * .pi / 180)
        let sl = 1 + 0.015 * pow(lm - 50, 2) / (20 + pow(lm - 50, 2)).squareRoot()
        let sc = 1 + 0.045 * cmp, sh = 1 + 0.015 * cmp * t
        let rt = -2 * (pow(cmp, 7) / (pow(cmp, 7) + pow(25, 7))).squareRoot() * sin(60 * exp(-pow((hm - 275) / 25, 2)) * .pi / 180)
        return (pow(dl / sl, 2) + pow(dc / sc, 2) + pow(dH / sh, 2) + rt * (dc / sc) * (dH / sh)).squareRoot()
    }

    /// The shot's median L after `transform` with the same arguments.
    public static func matchedLightness(from source: Stats, to reference: Stats, strength: Double = 1, maxLightnessShift cap: Double? = maxLightnessShift) -> Double {
        Double(toneCurve(source.lightness, reference.lightness, strength: min(max(strength, 0), 1), cap: cap).eval(Float(source.mean.x / 100))) * 100
    }

    /// Largest change matching may make: tone slopes stay within 0.5…2, colorfulness within ±25%,
    /// and the cast moves at most 40 Lab units.
    static let maxChromaScale = 1.25, maxCastShift = 40.0

    /// Maps colors of a shot with `source` statistics toward `reference`: lightness through a monotone curve that matches
    /// the percentiles (black and white stay put), the cast by moving the median color, and colorfulness by scaling
    /// chroma around it. Near-black and near-white pixels keep their color so bars and clipped highlights stay neutral.
    /// `strength` blends with the untouched picture; no lightness percentile moves more than `maxLightnessShift` L
    /// (nil: no limit).
    public static func transform(from source: Stats, to reference: Stats, strength: Double = 1, maxLightnessShift cap: Double? = maxLightnessShift) -> ColorMath.Transform {
        let k = min(max(strength, 0), 1)
        let tone = toneCurve(source.lightness, reference.lightness, strength: k, cap: cap)
        var shift = SIMD2(reference.mean.y - source.mean.y, reference.mean.z - source.mean.z)
        let length = (shift * shift).sum().squareRoot()
        if length > maxCastShift { shift *= maxCastShift / length }
        let scale = 1 + (min(max(reference.chroma / source.chroma, 1 / maxChromaScale), maxChromaScale) - 1) * k
        let center = SIMD2(source.mean.y, source.mean.z)
        return { c in
            let l = lab(c)
            let L = Double(tone.eval(Float(l.x / 100))) * 100
            let ab = SIMD2(l.y, l.z)
            let moved = center + shift * k + (ab - center) * scale
            let w = smoothstep(0, 12, l.x) * (1 - smoothstep(92, 100, l.x))
            let out = ab + (moved - ab) * w
            let rgb = srgb(SIMD3(L, out.x, out.y))
            return SIMD3(Float(min(max(rgb.x, 0), 1)), Float(min(max(rgb.y, 0), 1)), Float(min(max(rgb.z, 0), 1)))
        }
    }

    /// Lightness curve in 0…1 through (0, 0), the matched percentiles and (1, 1), with every segment's slope kept in 0.5…2.
    static func toneCurve(_ from: [Double], _ to: [Double], strength k: Double, cap: Double? = nil) -> ColorMath.MonotoneCurve {
        let limit = (cap ?? .infinity) / 100
        var points: [(Float, Float)] = [(0, 0)]
        for (x, y) in zip(from, to) {
            let x = x / 100, target = x + min(max((y / 100 - x) * k, -limit), limit)
            guard let last = points.last, x - Double(last.0) > 0.01, x < 0.99 else { continue }
            let dx = x - Double(last.0)
            let y = min(max(target, Double(last.1) + 0.5 * dx), Double(last.1) + 2 * dx)
            guard y < 0.995 else { continue }
            points.append((Float(x), Float(y)))
        }
        while points.count > 1, let last = points.last, (1 - last.1) > 2 * (1 - last.0) || (1 - last.1) < 0.5 * (1 - last.0) {
            points.removeLast()
        }
        points.append((1, 1))
        return ColorMath.MonotoneCurve(points: points)
    }

    static func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = min(max((x - a) / (b - a), 0), 1)
        return t * t * (3 - 2 * t)
    }

    // MARK: sRGB ↔ CIELAB (D65)

    static func lab(_ c: SIMD3<Float>) -> SIMD3<Double> {
        func lin(_ v: Float) -> Double { let v = Double(v); return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        let r = lin(c.x), g = lin(c.y), b = lin(c.z)
        let x = (0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047
        let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
        let z = (0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883
        func f(_ t: Double) -> Double { t > 0.008856 ? cbrt(t) : 7.787 * t + 16.0 / 116 }
        return SIMD3(116 * f(y) - 16, 500 * (f(x) - f(y)), 200 * (f(y) - f(z)))
    }

    static func srgb(_ l: SIMD3<Double>) -> SIMD3<Double> {
        let fy = (l.x + 16) / 116, fx = fy + l.y / 500, fz = fy - l.z / 200
        func inv(_ t: Double) -> Double { let t3 = t * t * t; return t3 > 0.008856 ? t3 : (t - 16.0 / 116) / 7.787 }
        let x = inv(fx) * 0.95047, y = inv(fy), z = inv(fz) * 1.08883
        let r = 3.2406 * x - 1.5372 * y - 0.4986 * z
        let g = -0.9689 * x + 1.8758 * y + 0.0415 * z
        let b = 0.0557 * x - 0.2040 * y + 1.0570 * z
        func enc(_ v: Double) -> Double { v <= 0.0031308 ? 12.92 * v : 1.055 * pow(max(v, 0), 1 / 2.4) - 0.055 }
        return SIMD3(enc(r), enc(g), enc(b))
    }
}
