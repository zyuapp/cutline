import Foundation

/// Pure color transforms on sRGB-encoded values, baked into 3D LUTs by the engine.
public enum ColorMath {
    /// Maps an sRGB-encoded color in 0…1 to another, clamped to 0…1.
    public typealias Transform = (SIMD3<Float>) -> SIMD3<Float>

    static let lumaWeights = SIMD3<Float>(0.2126, 0.7152, 0.0722)

    static func luma(_ c: SIMD3<Float>) -> Float { (c * lumaWeights).sum() }

    static func clamp(_ c: SIMD3<Float>) -> SIMD3<Float> {
        c.clamped(lowerBound: SIMD3(repeating: 0), upperBound: SIMD3(repeating: 1))
    }

    // MARK: Primaries

    /// Lift/gamma/gain primaries plus split-toning.
    ///
    /// - `lift` (-0.5…0.5) moves black toward `lift` while white stays put.
    /// - `gamma` (0.2…5) is applied as `v^(1/gamma)`: above 1 brightens midtones, below 1 darkens them.
    /// - `gain` (0…4) scales white while black stays put.
    /// - Each tint adds its chroma (the tint minus its own luma) weighted by tonal range and `amount` (0…1),
    ///   so luma is preserved until clamping. Range weights from luma `l`: shadows `(1-l)²`,
    ///   highlights `l²`, midtones `2l(1-l)`.
    public static func grade(lift: Float, gamma: Float, gain: Float,
                             shadowsTint: RGBA?, shadowsAmount: Float,
                             midtonesTint: RGBA?, midtonesAmount: Float,
                             highlightsTint: RGBA?, highlightsAmount: Float) -> Transform {
        func chroma(_ t: RGBA?, _ amount: Float) -> SIMD3<Float> {
            guard let t, amount != 0 else { return .zero }
            let c = SIMD3(Float(t.r), Float(t.g), Float(t.b))
            return (c - luma(c)) * amount
        }
        let shadows = chroma(shadowsTint, shadowsAmount)
        let midtones = chroma(midtonesTint, midtonesAmount)
        let highlights = chroma(highlightsTint, highlightsAmount)
        let toned = shadows != .zero || midtones != .zero || highlights != .zero
        let invGamma = 1 / max(gamma, 0.01)
        return { c in
            var v = c * gain + lift * (1 - c)
            v = pointwiseMax(v, .zero)
            if invGamma != 1 { v = SIMD3(pow(v.x, invGamma), pow(v.y, invGamma), pow(v.z, invGamma)) }
            if toned {
                let l = min(max(luma(v), 0), 1)
                let ws = (1 - l) * (1 - l), wh = l * l
                v += shadows * ws + midtones * (1 - ws - wh) + highlights * wh
            }
            return clamp(v)
        }
    }

    // MARK: Curves

    /// Tone curves from point lists like `"0,0 0.25,0.18 0.75,0.82 1,1"` (x,y in 0…1),
    /// interpolated with monotone cubics. Master applies first, then each channel. Nil or empty is identity.
    public static func curves(master: String?, red: String?, green: String?, blue: String?) throws -> Transform {
        let m = try parseCurve(master, "master")
        let r = try parseCurve(red, "red")
        let g = try parseCurve(green, "green")
        let b = try parseCurve(blue, "blue")
        return { c in
            var v = clamp(c)
            if let m { v = SIMD3(m.eval(v.x), m.eval(v.y), m.eval(v.z)) }
            if let r { v.x = r.eval(v.x) }
            if let g { v.y = g.eval(v.y) }
            if let b { v.z = b.eval(v.z) }
            return clamp(v)
        }
    }

    /// Fritsch–Carlson monotone cubic through sorted points; flat beyond the end points.
    struct MonotoneCurve {
        let xs: [Float], ys: [Float], ms: [Float]

        init(points: [(Float, Float)]) {
            let x = points.map(\.0), y = points.map(\.1)
            let n = x.count
            var d = [Float](repeating: 0, count: n - 1)
            for k in 0..<n - 1 { d[k] = (y[k + 1] - y[k]) / (x[k + 1] - x[k]) }
            var m = [Float](repeating: 0, count: n)
            m[0] = d[0]
            m[n - 1] = d[n - 2]
            for k in 1..<n - 1 {
                m[k] = d[k - 1] * d[k] <= 0 ? 0 : (d[k - 1] + d[k]) / 2
            }
            for k in 0..<n - 1 {
                if d[k] == 0 { m[k] = 0; m[k + 1] = 0; continue }
                let a: Float = m[k] / d[k], b: Float = m[k + 1] / d[k]
                let s: Float = a * a + b * b
                if s > 9 {
                    let t: Float = 3 / s.squareRoot()
                    m[k] = t * a * d[k]
                    m[k + 1] = t * b * d[k]
                }
            }
            xs = x
            ys = y
            ms = m
        }

        func eval(_ x: Float) -> Float {
            if x <= xs[0] { return ys[0] }
            if x >= xs[xs.count - 1] { return ys[ys.count - 1] }
            var k = 0
            while x > xs[k + 1] { k += 1 }
            let h = xs[k + 1] - xs[k]
            let t = (x - xs[k]) / h
            let t2 = t * t, t3 = t2 * t
            let h00: Float = 2 * t3 - 3 * t2 + 1, h10: Float = t3 - 2 * t2 + t
            let h01: Float = 3 * t2 - 2 * t3, h11: Float = t3 - t2
            return h00 * ys[k] + h10 * h * ms[k] + h01 * ys[k + 1] + h11 * h * ms[k + 1]
        }
    }

    static func parseCurve(_ s: String?, _ name: String) throws -> MonotoneCurve? {
        guard let s, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let example = "e.g. \"0,0 0.25,0.18 0.75,0.82 1,1\""
        var points: [(Float, Float)] = []
        for token in s.split(whereSeparator: \.isWhitespace) {
            let parts = token.split(separator: ",", omittingEmptySubsequences: false)
            guard parts.count == 2, let x = Float(parts[0]), let y = Float(parts[1]),
                  (0...1).contains(x), (0...1).contains(y) else {
                throw EditError("Bad \(name) curve point \"\(token)\": use space-separated x,y pairs in 0…1, \(example)")
            }
            points.append((x, y))
        }
        guard points.count >= 2 else {
            throw EditError("The \(name) curve needs at least 2 points, \(example)")
        }
        points.sort { $0.0 < $1.0 }
        for (a, b) in zip(points, points.dropFirst()) where b.0 - a.0 < 1e-4 {
            throw EditError("The \(name) curve has two points at x=\(a.0); each x must be distinct")
        }
        return MonotoneCurve(points: points)
    }

    // MARK: HSL

    /// Hue ranges and their center hues in degrees.
    public static let hueRanges: [(name: String, center: Float)] = [
        ("reds", 0), ("oranges", 30), ("yellows", 60), ("greens", 120),
        ("aquas", 180), ("blues", 225), ("purples", 270), ("magentas", 315),
    ]

    /// Adjusts one hue range. Full effect within ±15° of the range center, raised-cosine falloff
    /// to zero at ±45° (half effect at ±30°), scaled down for low-chroma pixels so grays are untouched.
    /// `hue` shifts in degrees (-180…180); `saturation` and `lightness` (-1…1) are relative:
    /// -1 removes all saturation / goes to black, +1 doubles saturation / goes to white.
    public static func hsl(range: String, hue: Float, saturation: Float, lightness: Float) throws -> Transform {
        guard let center = hueRanges.first(where: { $0.name == range })?.center else {
            throw EditError("Unknown hue range \"\(range)\". Use one of: \(hueRanges.map(\.name).joined(separator: ", "))")
        }
        if hue == 0 && saturation == 0 && lightness == 0 { return { clamp($0) } }
        return { c in
            let c = clamp(c)
            let chroma = c.max() - c.min()
            guard chroma > 1e-5 else { return c }
            var (h, s, l) = rgbToHSL(c)
            var d = abs(h - center).truncatingRemainder(dividingBy: 360)
            if d > 180 { d = 360 - d }
            let falloff: Float = d <= 15 ? 1 : d >= 45 ? 0 : 0.5 * (1 + cos(.pi * (d - 15) / 30))
            let w = falloff * min(1, chroma * 2)
            guard w > 0 else { return c }
            h = (h + hue * w).truncatingRemainder(dividingBy: 360)
            if h < 0 { h += 360 }
            s = min(max(s * (1 + saturation * w), 0), 1)
            let dl = lightness * w
            l = dl > 0 ? l + (1 - l) * dl : l * (1 + dl)
            return clamp(hslToRGB(h, s, l))
        }
    }

    /// Hue in degrees, saturation and lightness in 0…1.
    static func rgbToHSL(_ c: SIMD3<Float>) -> (Float, Float, Float) {
        let mx = c.max(), mn = c.min()
        let l = (mx + mn) / 2
        let d = mx - mn
        guard d > 0 else { return (0, 0, l) }
        let s = d / (1 - abs(2 * l - 1))
        var h: Float
        if mx == c.x { h = ((c.y - c.z) / d).truncatingRemainder(dividingBy: 6) }
        else if mx == c.y { h = (c.z - c.x) / d + 2 }
        else { h = (c.x - c.y) / d + 4 }
        h *= 60
        if h < 0 { h += 360 }
        return (h, min(s, 1), l)
    }

    static func hslToRGB(_ h: Float, _ s: Float, _ l: Float) -> SIMD3<Float> {
        let c = (1 - abs(2 * l - 1)) * s
        let hp = h / 60
        let x = c * (1 - abs(hp.truncatingRemainder(dividingBy: 2) - 1))
        let rgb: SIMD3<Float>
        switch hp {
        case ..<1: rgb = SIMD3(c, x, 0)
        case ..<2: rgb = SIMD3(x, c, 0)
        case ..<3: rgb = SIMD3(0, c, x)
        case ..<4: rgb = SIMD3(0, x, c)
        case ..<5: rgb = SIMD3(x, 0, c)
        default: rgb = SIMD3(c, 0, x)
        }
        return rgb + (l - c / 2)
    }

    // MARK: Looks

    public static let looks: [String] = [
        "teal_orange", "warm_film", "cool_night", "bleach_bypass", "vintage_fade",
        "high_contrast_bw", "golden_hour", "matrix_green", "pastel", "noir",
    ]

    /// A named preset grade. `amount` (0…1) blends from identity to the full look.
    public static func look(_ name: String, amount: Float) throws -> Transform {
        let f: Transform
        switch name {
        case "teal_orange":
            f = chain(
                grade(lift: 0, gamma: 1, gain: 1,
                      shadowsTint: RGBA(hex: "#0F7A80"), shadowsAmount: 0.55,
                      midtonesTint: nil, midtonesAmount: 0,
                      highlightsTint: RGBA(hex: "#FF9A4D"), highlightsAmount: 0.45),
                try curves(master: "0,0 0.25,0.21 0.75,0.8 1,1", red: nil, green: nil, blue: nil),
                saturate(1.1))
        case "warm_film":
            f = chain(
                grade(lift: 0.03, gamma: 1.05, gain: 0.97,
                      shadowsTint: nil, shadowsAmount: 0,
                      midtonesTint: RGBA(hex: "#FFB070"), midtonesAmount: 0.25,
                      highlightsTint: RGBA(hex: "#FFD9A0"), highlightsAmount: 0.2),
                try curves(master: "0,0 0.25,0.22 0.75,0.79 1,1", red: nil, green: nil, blue: nil),
                saturate(0.9))
        case "cool_night":
            f = chain(
                grade(lift: 0, gamma: 0.9, gain: 0.85,
                      shadowsTint: RGBA(hex: "#1A3A80"), shadowsAmount: 0.5,
                      midtonesTint: RGBA(hex: "#4060A0"), midtonesAmount: 0.3,
                      highlightsTint: nil, highlightsAmount: 0),
                saturate(0.75))
        case "bleach_bypass":
            f = chain(
                saturate(0.45),
                try curves(master: "0,0 0.2,0.12 0.5,0.5 0.8,0.9 1,1", red: nil, green: nil, blue: nil),
                grade(lift: 0, gamma: 1, gain: 1.05,
                      shadowsTint: nil, shadowsAmount: 0, midtonesTint: nil, midtonesAmount: 0,
                      highlightsTint: nil, highlightsAmount: 0))
        case "vintage_fade":
            f = chain(
                try curves(master: "0,0.08 0.5,0.5 1,0.92", red: nil, green: nil, blue: "0,0.1 1,0.9"),
                grade(lift: 0, gamma: 1, gain: 1,
                      shadowsTint: RGBA(hex: "#3A5A50"), shadowsAmount: 0.3,
                      midtonesTint: nil, midtonesAmount: 0,
                      highlightsTint: RGBA(hex: "#FFE0B0"), highlightsAmount: 0.3),
                saturate(0.8))
        case "high_contrast_bw":
            f = chain(
                saturate(0),
                try curves(master: "0,0 0.2,0.08 0.5,0.5 0.8,0.93 1,1", red: nil, green: nil, blue: nil))
        case "golden_hour":
            f = chain(
                grade(lift: 0.02, gamma: 1.05, gain: 1.05,
                      shadowsTint: nil, shadowsAmount: 0,
                      midtonesTint: RGBA(hex: "#FFA060"), midtonesAmount: 0.3,
                      highlightsTint: RGBA(hex: "#FFB040"), highlightsAmount: 0.5),
                saturate(1.1))
        case "matrix_green":
            f = chain(
                saturate(0.8),
                grade(lift: 0, gamma: 1, gain: 1,
                      shadowsTint: RGBA(hex: "#003010"), shadowsAmount: 0.4,
                      midtonesTint: RGBA(hex: "#40FF60"), midtonesAmount: 0.35,
                      highlightsTint: RGBA(hex: "#C0FFB0"), highlightsAmount: 0.2),
                try curves(master: "0,0 0.25,0.2 0.75,0.8 1,1", red: nil, green: nil, blue: nil))
        case "pastel":
            f = chain(
                grade(lift: 0.1, gamma: 1.15, gain: 1,
                      shadowsTint: RGBA(hex: "#A0C0E0"), shadowsAmount: 0.2,
                      midtonesTint: nil, midtonesAmount: 0,
                      highlightsTint: RGBA(hex: "#FFE0F0"), highlightsAmount: 0.2),
                saturate(0.7))
        case "noir":
            f = chain(
                saturate(0),
                grade(lift: -0.03, gamma: 0.8, gain: 1,
                      shadowsTint: RGBA(hex: "#506080"), shadowsAmount: 0.1,
                      midtonesTint: nil, midtonesAmount: 0,
                      highlightsTint: nil, highlightsAmount: 0),
                try curves(master: "0,0 0.3,0.18 0.7,0.75 1,0.95", red: nil, green: nil, blue: nil))
        default:
            throw EditError("Unknown look \"\(name)\". Use one of: \(looks.joined(separator: ", "))")
        }
        return blend(f, amount: amount)
    }

    static func chain(_ fs: Transform...) -> Transform {
        { c in fs.reduce(c) { $1($0) } }
    }

    /// Scales chroma around luma; 0 is monochrome.
    static func saturate(_ s: Float) -> Transform {
        { c in let l = luma(c); return clamp(l + (c - l) * s) }
    }

    static func blend(_ f: @escaping Transform, amount: Float) -> Transform {
        let a = min(max(amount, 0), 1)
        if a == 0 { return { clamp($0) } }
        if a == 1 { return f }
        return { c in clamp(c + (f(c) - c) * a) }
    }

    // MARK: Cubes

    /// Parses an Adobe/Resolve `.cube` 3D LUT into RGBA floats (alpha 1), red fastest.
    public static func parseCube(_ text: String) throws -> (size: Int, rgba: [Float], domainMin: SIMD3<Float>, domainMax: SIMD3<Float>) {
        var size: Int?
        var domainMin = SIMD3<Float>(repeating: 0), domainMax = SIMD3<Float>(repeating: 1)
        var rgba: [Float] = []
        func triple(_ parts: [Substring], _ line: Int) throws -> SIMD3<Float> {
            guard parts.count == 3, let a = Float(parts[0]), let b = Float(parts[1]), let c = Float(parts[2]) else {
                throw EditError("Bad .cube line \(line): expected three numbers")
            }
            return SIMD3(a, b, c)
        }
        for (i, raw) in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
            let line = raw.prefix { $0 != "#" }.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            let parts = line.split(whereSeparator: \.isWhitespace)
            let key = parts[0].uppercased()
            switch key {
            case "TITLE":
                continue
            case "LUT_1D_SIZE", "LUT_1D_INPUT_RANGE":
                throw EditError("1D .cube LUTs are not supported; export a 3D LUT (LUT_3D_SIZE)")
            case "LUT_3D_SIZE":
                guard parts.count == 2, let n = Int(parts[1]), n >= 2 else {
                    throw EditError("Bad LUT_3D_SIZE on line \(i + 1)")
                }
                guard n <= 65 else { throw EditError("LUT_3D_SIZE \(n) is too large; the maximum is 65") }
                size = n
                rgba.reserveCapacity(n * n * n * 4)
            case "DOMAIN_MIN":
                domainMin = try triple(Array(parts.dropFirst()), i + 1)
            case "DOMAIN_MAX":
                domainMax = try triple(Array(parts.dropFirst()), i + 1)
            case "LUT_3D_INPUT_RANGE":
                guard parts.count == 3, let lo = Float(parts[1]), let hi = Float(parts[2]) else {
                    throw EditError("Bad LUT_3D_INPUT_RANGE on line \(i + 1)")
                }
                domainMin = SIMD3(repeating: lo)
                domainMax = SIMD3(repeating: hi)
            default:
                if let first = key.first, first.isLetter { continue }
                let v = try triple(parts, i + 1)
                rgba += [v.x, v.y, v.z, 1]
            }
        }
        guard let size else { throw EditError("Missing LUT_3D_SIZE; is this a 3D .cube file?") }
        let expected = size * size * size
        guard rgba.count == expected * 4 else {
            throw EditError("A \(size)³ .cube needs \(expected) entries but has \(rgba.count / 4)")
        }
        guard (domainMax - domainMin).min() > 0 else {
            throw EditError("DOMAIN_MAX must be greater than DOMAIN_MIN")
        }
        return (size, rgba, domainMin, domainMax)
    }

    /// Samples `f` on a `size`³ grid into RGBA floats (alpha 1), red fastest, then green, then blue.
    public static func cubeData(size: Int = 33, _ f: Transform) -> [Float] {
        let n = max(size, 2)
        let step = 1 / Float(n - 1)
        var data = [Float]()
        data.reserveCapacity(n * n * n * 4)
        for b in 0..<n {
            for g in 0..<n {
                for r in 0..<n {
                    let v = clamp(f(SIMD3(Float(r), Float(g), Float(b)) * step))
                    data += [v.x, v.y, v.z, 1]
                }
            }
        }
        return data
    }
}
