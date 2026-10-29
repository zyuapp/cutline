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

    public init(t: Seconds, v: ParamValue, ease: Easing = .easeInOut) {
        self.t = t
        self.v = v
        self.ease = ease
    }
}

/// Keyframed values. Numbers and colors interpolate; other values hold until the next key.
public struct Curve: Codable, Equatable, Hashable, Sendable {
    public var keys: [CurveKey]

    public init(keys: [CurveKey]) {
        self.keys = keys.sorted { $0.t < $1.t }
    }

    public func value(at t: Seconds) -> ParamValue? {
        guard let first = keys.first else { return nil }
        if t <= first.t { return first.v }
        for (a, b) in zip(keys, keys.dropFirst()) where t < b.t {
            let p = b.ease.apply((t - a.t) / max(b.t - a.t, 1e-9))
            return Curve.mix(a.v, b.v, p)
        }
        return keys.last!.v
    }

    static func mix(_ a: ParamValue, _ b: ParamValue, _ p: Double) -> ParamValue {
        switch (a, b) {
        case (.number(let x), .number(let y)):
            return .number(x + (y - x) * p)
        case (.string, .string):
            if let ca = a.color, let cb = b.color {
                let c = RGBA(r: ca.r + (cb.r - ca.r) * p, g: ca.g + (cb.g - ca.g) * p, b: ca.b + (cb.b - ca.b) * p, a: ca.a + (cb.a - ca.a) * p)
                return .string(c.hex)
            }
            return p < 1 ? a : b
        default:
            return p < 1 ? a : b
        }
    }

    public func shifted(by dt: Seconds) -> Curve {
        Curve(keys: keys.map { var k = $0; k.t += dt; return k })
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

    public func spec(_ name: String) -> ParamSpec? { params.first { $0.name == name } }
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
