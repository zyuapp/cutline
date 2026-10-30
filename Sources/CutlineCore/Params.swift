import Foundation

/// A parameter value: numbers, booleans and strings. Colors are hex strings.
public enum ParamValue: Codable, Equatable, Hashable, Sendable, CustomStringConvertible {
    case number(Double)
    case bool(Bool)
    case string(String)

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else { self = .string(try c.decode(String.self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .string(let s): try c.encode(s)
        }
    }

    public var number: Double? { if case .number(let n) = self { return n }; return nil }
    public var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var string: String? { if case .string(let s) = self { return s }; return nil }
    public var color: RGBA? { string.flatMap { RGBA(hex: $0) } }

    public var description: String {
        switch self {
        case .number(let n): return n.rounded() == n && abs(n) < 1e9 ? String(Int(n)) : String(format: "%.4g", n)
        case .bool(let b): return b ? "true" : "false"
        case .string(let s): return "\"\(s)\""
        }
    }
}

public struct CurveKey: Codable, Equatable, Hashable, Sendable {
    /// Seconds from the clip start.
    public var t: Seconds
    public var v: ParamValue
    /// Easing of the segment that arrives at this key.
    public var ease: Easing
    /// Custom timing for the arriving segment as cubic-bezier control points [x1, y1, x2, y2]; overrides `ease`.
    public var bezier: [Double]?

    public init(t: Seconds, v: ParamValue, ease: Easing = .easeInOut, bezier: [Double]? = nil) {
        self.t = t
        self.v = v
        self.ease = ease
        self.bezier = bezier?.count == 4 ? bezier : nil
    }

    /// Eased progress through the segment arriving at this key.
    public func progress(_ x: Double) -> Double {
        guard let b = bezier else { return ease.apply(x) }
        return CurveKey.cubicBezier(x, b[0], b[1], b[2], b[3])
    }

    /// CSS-style cubic-bezier timing: solves x(s) = t by Newton then bisection, returns y(s).
    public static func cubicBezier(_ t: Double, _ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> Double {
        let t = min(max(t, 0), 1)
        func bez(_ s: Double, _ a: Double, _ b: Double) -> Double { 3 * a * s * (1 - s) * (1 - s) + 3 * b * s * s * (1 - s) + s * s * s }
        func dbez(_ s: Double, _ a: Double, _ b: Double) -> Double { 3 * a * (1 - s) * (1 - s) + 6 * (b - a) * s * (1 - s) + 3 * (1 - b) * s * s }
        var s = t
        for _ in 0..<8 {
            let err = bez(s, x1, x2) - t
            if abs(err) < 1e-7 { return bez(s, y1, y2) }
            let d = dbez(s, x1, x2)
            if abs(d) < 1e-6 { break }
            s = min(max(s - err / d, 0), 1)
        }
        var lo = 0.0, hi = 1.0
        s = t
        for _ in 0..<40 {
            let x = bez(s, x1, x2)
            if abs(x - t) < 1e-7 { break }
            if x < t { lo = s } else { hi = s }
            s = (lo + hi) / 2
        }
        return bez(s, y1, y2)
    }
}

/// Keyframed values. Numbers and colors interpolate; other values hold until the next key.
public struct Curve: Codable, Equatable, Hashable, Sendable {
    public var keys: [CurveKey]
    /// Procedural motion layered on the keys: wiggle, loop, steady rate.
    public var expression: CurveExpression?
    /// Keys kept in step with another clip's parameter (`Project.refreshLinks`).
    public var link: CurveLink?

    public init(keys: [CurveKey]) {
        self.keys = keys.sorted { $0.t < $1.t }
    }

    public func value(at t: Seconds) -> ParamValue? {
        guard let x = expression else { return keyed(at: t) }
        return x.apply(self, at: t)
    }

    /// The value from the keys alone.
    public func keyed(at t: Seconds) -> ParamValue? {
        guard let first = keys.first else { return nil }
        if t <= first.t { return first.v }
        for (a, b) in zip(keys, keys.dropFirst()) where t < b.t {
            let p = b.progress((t - a.t) / max(b.t - a.t, 1e-9))
            return Curve.mix(a.v, b.v, p)
        }
        return keys.last!.v
    }

    static func mix(_ a: ParamValue, _ b: ParamValue, _ p: Double) -> ParamValue {
        switch (a, b) {
        case (.number(let x), .number(let y)):
            return .number(x + (y - x) * p)
        case (.string(let sa), .string(let sb)):
            if let pa = Curve.points(sa), let pb = Curve.points(sb), pa.count == pb.count {
                return .string(zip(pa, pb).map { String(format: "%.4f,%.4f", $0.0.0 + ($0.1.0 - $0.0.0) * p, $0.0.1 + ($0.1.1 - $0.0.1) * p) }.joined(separator: " "))
            }
            if let ca = a.color, let cb = b.color {
                let c = RGBA(r: ca.r + (cb.r - ca.r) * p, g: ca.g + (cb.g - ca.g) * p, b: ca.b + (cb.b - ca.b) * p, a: ca.a + (cb.a - ca.a) * p)
                return .string(c.hex)
            }
            return p < 1 ? a : b
        default:
            return p < 1 ? a : b
        }
    }

    /// "x,y x,y …" point lists, used by shape masks; nil for any other text.
    public static func points(_ s: String) -> [(Double, Double)]? {
        let pairs = s.split(whereSeparator: \.isWhitespace)
        guard pairs.count >= 2 else { return nil }
        var out: [(Double, Double)] = []
        for p in pairs {
            let xy = p.split(separator: ",")
            guard xy.count == 2, let x = Double(xy[0]), let y = Double(xy[1]) else { return nil }
            out.append((x, y))
        }
        return out
    }

    public func shifted(by dt: Seconds) -> Curve {
        var c = self
        c.keys = keys.map { var k = $0; k.t += dt; return k }
        c.expression?.origin += dt
        return c
    }
}

/// One entry in a clip's or track's effect stack. Parameters not set use the catalog default.
public struct Effect: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var id: String
    public var type: String
    public var enabled: Bool
    /// 0 shows the input unchanged, 1 shows the full effect.
    public var mix: Double
    public var params: [String: ParamValue]

    public init(id: String, type: String, enabled: Bool = true, mix: Double = 1, params: [String: ParamValue] = [:]) {
        self.id = id
        self.type = type
        self.enabled = enabled
        self.mix = mix
        self.params = params
    }

    enum CodingKeys: String, CodingKey { case id, type, enabled, mix, params }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        type = try c.decode(String.self, forKey: .type)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        mix = try c.decodeIfPresent(Double.self, forKey: .mix) ?? 1
        params = try c.decodeIfPresent([String: ParamValue].self, forKey: .params) ?? [:]
    }
}

// MARK: Parameter specs

public enum ParamKind: Codable, Equatable, Hashable, Sendable {
    case number
    case color
    case bool
    case choice([String])
    case text

    public var label: String {
        switch self {
        case .number: return "number"
        case .color: return "color"
        case .bool: return "bool"
        case .choice(let v): return v.joined(separator: "|")
        case .text: return "text"
        }
    }
}

public struct ParamSpec: Equatable, Hashable, Sendable {
    public var name: String
    public var kind: ParamKind
    public var defaultValue: ParamValue
    public var min: Double?
    public var max: Double?
    public var unit: String
    public var animatable: Bool
    public var summary: String

    public init(_ name: String, _ kind: ParamKind, _ defaultValue: ParamValue, min: Double? = nil, max: Double? = nil, unit: String = "", animatable: Bool? = nil, _ summary: String) {
        self.name = name
        self.kind = kind
        self.defaultValue = defaultValue
        self.min = min
        self.max = max
        self.unit = unit
        switch kind {
        case .number, .color: self.animatable = animatable ?? true
        default: self.animatable = animatable ?? false
        }
        self.summary = summary
    }

    /// Checks and normalizes a value for this parameter.
    public func validate(_ v: ParamValue, path: String) throws -> ParamValue {
        switch kind {
        case .number:
            guard let n = v.number else { throw EditError("\(path) needs a number, got \(v)") }
            if let min, n < min - 1e-9 { throw EditError("\(path) must be ≥ \(ParamValue.number(min)), got \(v)") }
            if let max, n > max + 1e-9 { throw EditError("\(path) must be ≤ \(ParamValue.number(max)), got \(v)") }
            return .number(n)
        case .color:
            guard let s = v.string, let c = RGBA(hex: s) ?? RGBA.named(s) else { throw EditError("\(path) needs a hex color like \"#FFD60A\", got \(v)") }
            return .string(c.hex)
        case .bool:
            if let b = v.bool { return .bool(b) }
            if let n = v.number { return .bool(n != 0) }
            throw EditError("\(path) needs true or false, got \(v)")
        case .choice(let values):
            guard let s = v.string, values.contains(s) else { throw EditError("\(path) must be one of \(values.joined(separator: ", ")), got \(v)") }
            return .string(s)
        case .text:
            guard let s = v.string else { throw EditError("\(path) needs text, got \(v)") }
            return .string(s)
        }
    }

    public var line: String {
        var s = "\(name): \(kind.label)"
        if let min, let max { s += " \(ParamValue.number(min))…\(ParamValue.number(max))" }
        else if let min { s += " ≥\(ParamValue.number(min))" }
        if !unit.isEmpty { s += " \(unit)" }
        s += ", default \(defaultValue)"
        if animatable { s += ", animatable" }
        return s + ". " + summary
    }
}

public struct EffectType: Sendable {
    public var id: String
    public var category: String
    public var summary: String
    public var params: [ParamSpec]

    public init(id: String, category: String, summary: String, params: [ParamSpec]) {
        self.id = id
        self.category = category
        self.summary = summary
        self.params = params
    }

    public func spec(_ name: String) -> ParamSpec? { params.first { $0.name == name } }

    static let synonyms: [String: [String]] = [
        "file": ["path", "lut", "lut_file", "file_path", "cube", "url"],
        "amount": ["strength", "intensity", "level"],
        "strength": ["amount", "intensity"],
        "intensity": ["amount", "strength"],
        "radius": ["size", "blur_radius"],
        "color": ["colour", "tint_color"],
        "angle": ["rotation", "direction"],
    ]

    /// The parameter an agent most likely meant: the name itself, a known synonym, or the one unambiguous
    /// near-miss (edit distance ≤ 2); nil when there's no confident match.
    public func paramName(for name: String) -> String? {
        if spec(name) != nil || ["mix", "enabled"].contains(name) { return name }
        let lower = name.lowercased().replacingOccurrences(of: "-", with: "_")
        if spec(lower) != nil { return lower }
        let viaSynonym = params.map(\.name).filter { Self.synonyms[$0]?.contains(lower) == true }
        if viaSynonym.count == 1 { return viaSynonym[0] }
        let near = params.map(\.name).filter { editDistance($0, lower) <= 2 }
        return near.count == 1 ? near[0] : nil
    }
}

extension RGBA {
    public static func named(_ s: String) -> RGBA? {
        let names: [String: String] = [
            "black": "#000000", "white": "#FFFFFF", "red": "#FF3B30", "orange": "#FF9F0A", "yellow": "#FFD60A",
            "green": "#30D158", "blue": "#0A84FF", "purple": "#BF5AF2", "pink": "#FF375F", "gray": "#8E8E93",
            "transparent": "#00000000",
        ]
        return names[s.lowercased()].flatMap { RGBA(hex: $0) }
    }
}
