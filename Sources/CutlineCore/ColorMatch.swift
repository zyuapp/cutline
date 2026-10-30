import Foundation

/// Shot matching: statistics of a picture in CIELAB, and a transform that moves one shot's
/// statistics onto a reference's (Reinhard color transfer), softened by `strength`.
public enum ColorMatch {
    public struct Stats: Codable, Equatable, Sendable {
        public var mean: SIMD3<Double>
        public var sd: SIMD3<Double>

        public init(mean: SIMD3<Double>, sd: SIMD3<Double>) {
            self.mean = mean
            self.sd = sd
        }
    }

    /// Mean and spread of sRGB-encoded pixels (0…1) in Lab.
    public static func stats(_ pixels: [SIMD3<Float>]) -> Stats {
        guard !pixels.isEmpty else { return Stats(mean: .zero, sd: SIMD3(1, 1, 1)) }
        var sum = SIMD3<Double>.zero, sq = SIMD3<Double>.zero
        for p in pixels {
            let l = lab(p)
            sum += l
            sq += l * l
        }
        let n = Double(pixels.count)
        let mean = sum / n
        let variance = sq / n - mean * mean
        return Stats(mean: mean, sd: SIMD3(max(variance.x, 1e-6).squareRoot(), max(variance.y, 1e-6).squareRoot(), max(variance.z, 1e-6).squareRoot()))
    }

    /// Maps colors of a shot with `source` statistics toward `reference`. Spread changes are clamped so noisy
    /// or nearly flat shots don't blow up, and `strength` blends with the untouched picture.
    public static func transform(from source: Stats, to reference: Stats, strength: Double = 1) -> ColorMath.Transform {
        let ratio = SIMD3(clampRatio(reference.sd.x / source.sd.x), clampRatio(reference.sd.y / source.sd.y), clampRatio(reference.sd.z / source.sd.z))
        let k = min(max(strength, 0), 1)
        return { c in
            let l = lab(c)
            let moved = (l - source.mean) * ratio + reference.mean
            let mixed = l + (moved - l) * k
            let rgb = srgb(mixed)
            return SIMD3(Float(min(max(rgb.x, 0), 1)), Float(min(max(rgb.y, 0), 1)), Float(min(max(rgb.z, 0), 1)))
        }
    }

    static func clampRatio(_ r: Double) -> Double { min(max(r, 0.5), 2) }

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
