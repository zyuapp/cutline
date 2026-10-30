import Foundation
import simd

/// Secondary curves like Resolve's hue vs hue / hue vs sat / hue vs lum / lum vs sat / sat vs sat.
///
/// Each curve is a point list `"x,y x,y …"`. Hue curves take hue in degrees (0 red, 30 orange, 60 yellow,
/// 120 green, 180 aqua, 225 blue, 270 purple, 315 magenta) and wrap around 360; a single point is a bump that is
/// neutral 60° either side of it. Lum and sat curves take 0…1 and hold flat past their end points. Curves are
/// shape-preserving cubics (periodic for hue), so they never overshoot between points.
public struct HueCurves: Equatable, Sendable {
    public enum Family: String, CaseIterable, Sendable {
        case hue_hue, hue_sat, hue_lum, lum_sat, sat_sat

        /// The y value that leaves a pixel unchanged.
        public var neutral: Float { self == .hue_hue ? 0 : 1 }
        var periodic: Bool { self == .hue_hue || self == .hue_sat || self == .hue_lum }
        var yRange: ClosedRange<Float> { self == .hue_hue ? -180...180 : 0...4 }
    }

    struct Curve: Equatable, Sendable {
        let xs: [Float], ys: [Float], ms: [Float]
        let period: Float?

        init(points: [(Float, Float)], period: Float?) {
            var pts = points.sorted { $0.0 < $1.0 }
            if let period {
                pts = pts.map { (($0.0.truncatingRemainder(dividingBy: period) + period).truncatingRemainder(dividingBy: period), $0.1) }.sorted { $0.0 < $1.0 }
            }
            let n = pts.count
            var x = pts.map(\.0), y = pts.map(\.1)
            if let period {
                // Wrap one point each side so every interval has neighbours.
                x = [x[n - 1] - period] + x + [x[0] + period]
                y = [y[n - 1]] + y + [y[0]]
            }
            let k = x.count
            var d = [Float](repeating: 0, count: max(k - 1, 1))
            for i in 0..<(k - 1) { d[i] = (y[i + 1] - y[i]) / max(x[i + 1] - x[i], 1e-6) }
            var m = [Float](repeating: 0, count: k)
            if k > 1 {
                m[0] = period == nil ? d[0] : 0
                m[k - 1] = period == nil ? d[k - 2] : 0
                for i in 1..<(k - 1) {
                    if d[i - 1] * d[i] <= 0 { m[i] = 0; continue }
                    // Fritsch–Butland harmonic mean with interval weights.
                    let h0 = x[i] - x[i - 1], h1 = x[i + 1] - x[i]
                    let w1 = 2 * h1 + h0, w2 = h1 + 2 * h0
                    m[i] = (w1 + w2) / (w1 / d[i - 1] + w2 / d[i])
                }
                if period != nil, k > 2 {
                    m[0] = m[k - 2]
                    m[k - 1] = m[1]
                }
            }
            xs = x
            ys = y
            ms = m
            self.period = period
        }

        func eval(_ v: Float) -> Float {
            var t = v
            if let period { t = (t.truncatingRemainder(dividingBy: period) + period).truncatingRemainder(dividingBy: period) }
            if xs.count == 1 { return ys[0] }
            if t <= xs[0] { return ys[0] }
            if t >= xs[xs.count - 1] { return ys[ys.count - 1] }
            var k = 0
            while t > xs[k + 1] { k += 1 }
            let h = xs[k + 1] - xs[k]
            let s = (t - xs[k]) / h
            let s2 = s * s, s3 = s2 * s
            return (2 * s3 - 3 * s2 + 1) * ys[k] + (s3 - 2 * s2 + s) * h * ms[k] + (3 * s2 - 2 * s3) * ys[k + 1] + (s3 - s2) * h * ms[k + 1]
        }
    }

    var curves: [Family: Curve] = [:]

    public init() {}

    /// Parses the point lists; nil or empty strings leave a family neutral.
    public init(_ text: (Family) -> String?) throws {
        for f in Family.allCases {
            guard let s = text(f), !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            curves[f] = try Self.parse(s, f)
        }
    }

    public var isIdentity: Bool { curves.isEmpty }

    static func parse(_ s: String, _ f: Family) throws -> Curve {
        let xName = f.periodic ? "hue in degrees" : f == .lum_sat ? "luma 0…1" : "saturation 0…1"
        let yName = f == .hue_hue ? "a hue shift in degrees (-180…180)" : f == .hue_lum ? "a brightness multiplier (0…4, 1 unchanged)" : "a saturation multiplier (0…4, 1 unchanged)"
        let example = f == .hue_hue ? "\"20,0 30,8 60,0\"" : f == .hue_sat ? "\"60,1 120,0.5 180,1\"" : f == .hue_lum ? "\"180,1 225,0.8 270,1\"" : f == .lum_sat ? "\"0,0.6 0.3,1 1,1\"" : "\"0,1 0.6,1 1,0.8\""
        var pts: [(Float, Float)] = []
        for token in s.split(whereSeparator: \.isWhitespace) {
            let parts = token.split(separator: ",", omittingEmptySubsequences: false)
            guard parts.count == 2, let x = Float(parts[0]), let y = Float(parts[1]), x.isFinite, y.isFinite,
                  f.periodic || (0...1).contains(x), f.yRange.contains(y) else {
                throw EditError("Bad \(f.rawValue) point \"\(token)\": each point is x,y with x \(xName) and y \(yName), e.g. \(example)")
            }
            pts.append((x, y))
        }
        guard !pts.isEmpty else { throw EditError("The \(f.rawValue) curve needs at least one point, e.g. \(example)") }
        if f.periodic, pts.count == 1 {
            let (x, y) = pts[0]
            pts = [(x - 60, f.neutral), (x, y), (x + 60, f.neutral)]
        }
        let keys = pts.map { f.periodic ? (($0.0.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)) : $0.0 }.sorted()
        for (a, b) in zip(keys, keys.dropFirst()) where b - a < 1e-3 {
            throw EditError("The \(f.rawValue) curve has two points at x=\(a); each x must be distinct")
        }
        return Curve(points: pts, period: f.periodic ? 360 : nil)
    }

    /// The curve's value at `x`, or the family's neutral value.
    public func value(_ f: Family, _ x: Float) -> Float {
        guard let c = curves[f] else { return f.neutral }
        let v = c.eval(x)
        return min(max(v, f.yRange.lowerBound), f.yRange.upperBound)
    }

    /// The curves on display-encoded RGB. Hue and HSV saturation come from the input pixel; adjustments fade out
    /// toward neutral grays (whose hue is noise). Saturation and brightness changes keep the pixel's luma and hue.
    public var transform: ColorMath.Transform {
        let curves = self
        let w = ColorMath.lumaWeights
        return { input in
            var c = simd_clamp(input, .zero, SIMD3(repeating: 1))
            let mx = c.max(), mn = c.min()
            let chroma = mx - mn
            let y = (c * w).sum()
            let sat: Float = mx > 1e-5 ? chroma / mx : 0
            let strength = min(1, chroma * 4)
            var mult = curves.value(.lum_sat, y) * curves.value(.sat_sat, sat)
            if strength > 0 {
                let (h, _, _) = ColorMath.rgbToHSL(c)
                let shift = curves.value(.hue_hue, h) * strength
                if abs(shift) > 1e-4 {
                    var (hh, s, l) = ColorMath.rgbToHSL(c)
                    hh = (hh + shift).truncatingRemainder(dividingBy: 360)
                    if hh < 0 { hh += 360 }
                    let rotated = ColorMath.hslToRGB(hh, s, l)
                    c = SIMD3(repeating: y) + (rotated - (rotated * w).sum())
                }
                mult *= 1 + (curves.value(.hue_sat, h) - 1) * strength
                let lum = 1 + (curves.value(.hue_lum, h) - 1) * strength
                if abs(lum - 1) > 1e-5 { c *= lum }
            }
            if abs(mult - 1) > 1e-5 {
                let l = (c * w).sum()
                c = SIMD3(repeating: l) + (c - l) * mult
            }
            return simd_clamp(c, .zero, SIMD3(repeating: 1))
        }
    }
}
