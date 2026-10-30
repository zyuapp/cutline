import Foundation

/// An ASC Color Decision List primary (v1.2): `out = clamp(in × slope + offset) ^ power` per channel,
/// then saturation around Rec. 709 luma. Values are on the display-encoded picture, like Cutline's grades.
public struct CDL: Codable, Equatable, Sendable {
    public var slope: SIMD3<Double>
    public var offset: SIMD3<Double>
    public var power: SIMD3<Double>
    public var saturation: Double

    public init(slope: SIMD3<Double> = .one, offset: SIMD3<Double> = .zero, power: SIMD3<Double> = .one, saturation: Double = 1) {
        self.slope = slope
        self.offset = offset
        self.power = power
        self.saturation = saturation
    }

    public static let identity = CDL()

    public var isIdentity: Bool { distance(to: .identity) < 1e-4 }

    /// The largest difference between any two corresponding values.
    public func distance(to o: CDL) -> Double {
        func d(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double { max(abs(a.x - b.x), abs(a.y - b.y), abs(a.z - b.z)) }
        return max(d(slope, o.slope), d(offset, o.offset), d(power, o.power), abs(saturation - o.saturation))
    }

    public func apply(_ c: SIMD3<Double>) -> SIMD3<Double> {
        var v = (c * slope + offset).clamped(lowerBound: .zero, upperBound: .one)
        v = SIMD3(pow(v.x, power.x), pow(v.y, power.y), pow(v.z, power.z))
        let l = CDL.luma(v)
        return (l + (v - l) * saturation).clamped(lowerBound: .zero, upperBound: .one)
    }

    public var transform: ColorMath.Transform {
        let cdl = self
        return { c in
            let v = cdl.apply(SIMD3(Double(c.x), Double(c.y), Double(c.z)))
            return SIMD3(Float(v.x), Float(v.y), Float(v.z))
        }
    }

    static func luma(_ c: SIMD3<Double>) -> Double { (c * SIMD3(0.2126, 0.7152, 0.0722)).sum() }

    // MARK: Text

    static func number(_ v: Double) -> String {
        var s = String(format: "%.6f", v)
        while s.hasSuffix("0") && !s.hasSuffix(".0") { s.removeLast() }
        return s == "-0.0" ? "0.0" : s
    }

    /// "(slope r g b)(offset r g b)(power r g b)", as in an EDL's `*ASC_SOP` line.
    public var sop: String {
        [slope, offset, power].map { v in "(" + [v.x, v.y, v.z].map(CDL.number).joined(separator: " ") + ")" }.joined()
    }

    public var sat: String { CDL.number(saturation) }

    /// Reads the nine numbers of an `ASC_SOP` value and an optional `ASC_SAT` value.
    public init?(sop: String, sat: String? = nil) {
        let v = sop.split(whereSeparator: { "() \t,".contains($0) }).compactMap { Double($0) }
        guard v.count >= 9 else { return nil }
        self.init(slope: SIMD3(v[0], v[1], v[2]), offset: SIMD3(v[3], v[4], v[5]), power: SIMD3(v[6], v[7], v[8]),
                  saturation: sat.flatMap { Double($0.trimmingCharacters(in: .whitespaces)) } ?? 1)
    }

    /// Finds `ASC_SOP …` and `ASC_SAT …` in free text, such as a clip note or comment.
    public init?(text: String) {
        guard let r = text.range(of: "ASC_SOP") else { return nil }
        let rest = text[r.upperBound...]
        var sat: String?
        if let s = text.range(of: "ASC_SAT") {
            sat = text[s.upperBound...].split(whereSeparator: { $0.isWhitespace || $0 == ";" }).first.map(String.init)
        }
        let sopText = rest.prefix { $0 != "A" && $0 != ";" && $0 != "\n" }
        self.init(sop: String(sopText), sat: sat)
    }

    /// `ASC_SOP (…)(…)(…) ASC_SAT n`, for notes and comments.
    public var text: String { "ASC_SOP \(sop) ASC_SAT \(sat)" }

    // MARK: Effect

    static let channels = ["r", "g", "b"]

    /// A `color.cdl` effect applying this CDL.
    public func effect(id: String) -> Effect {
        var p: [String: ParamValue] = ["saturation": .number(saturation)]
        for (i, ch) in CDL.channels.enumerated() {
            p["slope_\(ch)"] = .number(slope[i])
            p["offset_\(ch)"] = .number(offset[i])
            p["power_\(ch)"] = .number(power[i])
        }
        return Effect(id: id, type: "color.cdl", params: p)
    }

    /// The CDL a `color.cdl` effect applies.
    public init(effect e: Effect) {
        func n(_ name: String) -> Double { CDL.param(e, name) }
        self.init(slope: SIMD3(n("slope_r"), n("slope_g"), n("slope_b")), offset: SIMD3(n("offset_r"), n("offset_g"), n("offset_b")),
                  power: SIMD3(n("power_r"), n("power_g"), n("power_b")), saturation: n("saturation"))
    }

    static func param(_ e: Effect, _ name: String) -> Double {
        e.params[name]?.number ?? EffectCatalog.type(e.type)?.spec(name)?.defaultValue.number ?? 0
    }

    // MARK: From Cutline color

    /// The CDL of `color.adjust`, an approximation: exposure scales slope by 2^stops, brightness adds half
    /// itself to offset, contrast pivots slope and offset around 0.5 (as the engine's contrast does), gamma
    /// multiplies power, saturation scales saturation by 1 + saturation and vibrance by 1 + vibrance / 2, and
    /// temperature and tint tilt the slopes: ±100 is ±12% red and ∓12% blue, ∓10% green.
    static func adjust(_ e: Effect) -> CDL {
        func n(_ name: String) -> Double { param(e, name) }
        var c = CDL()
        c.slope *= pow(2, n("exposure"))
        c.offset += 0.5 * n("brightness")
        let k = n("contrast") >= 0 ? 1 + n("contrast") : 1 + 0.75 * n("contrast")
        c.slope *= k
        c.offset = c.offset * k + 0.5 * (1 - k)
        let warm = n("temperature") / 100, tint = n("tint") / 100
        c.slope *= SIMD3(1 + 0.12 * warm, 1 - 0.1 * tint, 1 - 0.12 * warm)
        c.power *= max(n("gamma"), 0.01)
        c.saturation = max(0, (1 + n("saturation")) * (1 + 0.5 * n("vibrance")))
        return c
    }

    /// The CDL of an untinted `color.grade`, exactly: slope gain − lift, offset lift, power 1 / gamma.
    static func grade(_ e: Effect) -> CDL? {
        func n(_ name: String) -> Double { param(e, name) }
        let tinted = ["shadows", "midtones", "highlights"].contains { n("\($0)_amount") != 0 }
        guard !tinted else { return nil }
        let lift = n("lift"), gain = n("gain")
        return CDL(slope: SIMD3(repeating: gain - lift), offset: SIMD3(repeating: lift), power: SIMD3(repeating: 1 / max(n("gamma"), 0.01)))
    }

    static let types: Set<String> = ["color.cdl", "color.adjust", "color.grade", "color.look", "color.curves"]

    /// The picture transform of one effect `types` holds, or nil when its parameters don't parse.
    static func transform(_ e: Effect) -> ColorMath.Transform? {
        func n(_ name: String) -> Float { Float(param(e, name)) }
        let f: ColorMath.Transform?
        switch e.type {
        case "color.cdl": f = CDL(effect: e).transform
        case "color.adjust": f = adjust(e).transform
        case "color.grade":
            func tint(_ name: String) -> RGBA? { (e.params[name] ?? EffectCatalog.type(e.type)?.spec(name)?.defaultValue)?.color }
            f = ColorMath.grade(lift: n("lift"), gamma: n("gamma"), gain: n("gain"), shadowsTint: tint("shadows"), shadowsAmount: n("shadows_amount"),
                                midtonesTint: tint("midtones"), midtonesAmount: n("midtones_amount"), highlightsTint: tint("highlights"), highlightsAmount: n("highlights_amount"))
        case "color.look": f = try? ColorMath.look(e.params["look"]?.string ?? "teal_orange", amount: e.params["amount"]?.number.map(Float.init) ?? 1)
        case "color.curves":
            func s(_ name: String) -> String? { e.params[name]?.string.flatMap { $0.isEmpty ? nil : $0 } }
            f = try? ColorMath.curves(master: s("master"), red: s("red"), green: s("green"), blue: s("blue"))
        default: f = nil
        }
        return f.map { ColorMath.blend($0, amount: Float(e.mix)) }
    }

    /// The CDL closest to `f`: per channel, slope, offset and power fitted to a gray ramp, then the
    /// saturation that best matches a set of color patches.
    public static func fit(_ f: ColorMath.Transform) -> CDL {
        func run(_ c: SIMD3<Double>) -> SIMD3<Double> {
            let v = f(SIMD3(Float(c.x), Float(c.y), Float(c.z)))
            return SIMD3(Double(v.x), Double(v.y), Double(v.z))
        }
        let xs = (0...32).map { Double($0) / 32 }
        let raw = xs.map { run(SIMD3(repeating: $0)) }
        let patches: [SIMD3<Double>] = [
            SIMD3(0.6, 0.4, 0.3), SIMD3(0.3, 0.5, 0.6), SIMD3(0.5, 0.5, 0.2), SIMD3(0.2, 0.3, 0.6),
            SIMD3(0.7, 0.3, 0.5), SIMD3(0.4, 0.6, 0.4), SIMD3(0.55, 0.45, 0.45), SIMD3(0.35, 0.4, 0.5),
        ]
        let graded = patches.map(run)
        // Saturation also tints the ramp when the channels differ: for each saturation tried, the ramp is
        // desaturated back before fitting, and the saturation whose CDL best matches the patches wins.
        func candidate(_ sat: Double) -> (cdl: CDL, err: Double) {
            let ramp = raw.map { y in luma(y) + (y - luma(y)) / sat }
            let c = fitSOP(xs, ramp, saturation: sat)
            var err = 0.0
            for (p, y) in zip(patches, graded) {
                let d = c.apply(p) - y
                err += (d * d).sum()
            }
            return (c, err)
        }
        var lo = 0.05, hi = 3.0
        for _ in 0..<24 {
            let a = lo + (hi - lo) * 0.382, b = lo + (hi - lo) * 0.618
            if candidate(a).err < candidate(b).err { hi = b } else { lo = a }
        }
        let best = candidate((lo + hi) / 2), neutral = candidate(1)
        return neutral.err <= best.err + 1e-12 ? neutral.cdl : best.cdl
    }

    /// Slope, offset and power per channel for a gray ramp `xs` mapped to `ys`.
    static func fitSOP(_ xs: [Double], _ ramp: [SIMD3<Double>], saturation: Double) -> CDL {
        var out = CDL(saturation: saturation)
        for ch in 0..<3 {
            let ys = ramp.map { $0[ch] }
            // Least squares of y^(1/p) = s·x + o over unclipped samples, then the error of the clipped model.
            func solve(_ p: Double) -> (err: Double, s: Double, o: Double) {
                var n = 0.0, sx = 0.0, sy = 0.0, sxx = 0.0, sxy = 0.0
                for (x, y) in zip(xs, ys) where y > 1e-4 && y < 1 - 1e-4 {
                    let z = pow(y, 1 / p)
                    n += 1; sx += x; sy += z; sxx += x * x; sxy += x * z
                }
                guard n >= 2 else { return (.infinity, 1, 0) }
                let vxx = sxx - sx * sx / n, vxy = sxy - sx * sy / n
                let s = vxx > 1e-12 ? vxy / vxx : 1, o = (sy - s * sx) / n
                var err = 0.0
                for (x, y) in zip(xs, ys) {
                    let m: Double = pow(min(max(x * s + o, 0), 1), p) - y
                    err += m * m
                }
                return (err, s, o)
            }
            var best = (p: 1.0, r: solve(1))
            for i in 0...80 {
                let p = exp(log(0.2) + Double(i) / 80 * (log(5) - log(0.2)))
                let r = solve(p)
                if r.err < best.r.err { best = (p, r) }
            }
            var lo = best.p / 1.05, hi = best.p * 1.05
            for _ in 0..<28 {
                let a = lo + (hi - lo) * 0.382, b = lo + (hi - lo) * 0.618
                if solve(a).err < solve(b).err { hi = b } else { lo = a }
            }
            let p = (lo + hi) / 2, r = solve(p)
            if r.err <= best.r.err { best = (p, r) }
            out.slope[ch] = best.r.s
            out.offset[ch] = best.r.o
            out.power[ch] = best.p
        }
        return out
    }
}

extension Clip {
    /// The clip's primary color correction as an ASC CDL, for interchange; nil when it has none.
    ///
    /// Enabled, unlimited `color.cdl`, `color.adjust`, `color.grade`, `color.look` and `color.curves` effects count,
    /// at their static values. A single `color.cdl` or untinted `color.grade` is exact and a single `color.adjust`
    /// uses `CDL.adjust`'s approximation; anything else (tints, looks, curves, several effects, partial mix) is
    /// sampled and fitted. HSL, LUT, monochrome and secondary (windowed or qualified) corrections have no CDL.
    public var cdl: CDL? {
        let color = effects.filter { e in
            e.enabled && e.mix > 0 && CDL.types.contains(e.type) && (e.params["limit"]?.string ?? "none") == "none"
        }
        guard !color.isEmpty else { return nil }
        var result: CDL?
        if color.count == 1, color[0].mix >= 1 {
            switch color[0].type {
            case "color.cdl": result = CDL(effect: color[0])
            case "color.adjust": result = CDL.adjust(color[0])
            case "color.grade": result = CDL.grade(color[0])
            default: break
            }
        }
        if result == nil {
            let fs = color.compactMap(CDL.transform)
            guard !fs.isEmpty else { return nil }
            result = CDL.fit { c in fs.reduce(c) { $1($0) } }
        }
        return result!.isIdentity ? nil : result
    }
}
