import CutlineCore
import Foundation

public enum JSON: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSON])
    case object([String: JSON])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSON].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSON].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n):
            if n.rounded() == n, abs(n) < 1e15 { try c.encode(Int64(n)) } else { try c.encode(n) }
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    public subscript(key: String) -> JSON? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    public var string: String? { if case .string(let s) = self { return s }; return nil }
    public var double: Double? {
        switch self {
        case .number(let n): return n
        case .string(let s): return Double(s)
        default: return nil
        }
    }
    public var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var array: [JSON]? { if case .array(let a) = self { return a }; return nil }
    public var object: [String: JSON]? { if case .object(let o) = self { return o }; return nil }
    public var isNull: Bool { self == .null }

    public static func from<T: Encodable>(_ value: T) -> JSON {
        guard let data = try? JSONEncoder().encode(value), let j = try? JSONDecoder().decode(JSON.self, from: data) else { return .null }
        return j
    }

    public func encoded(pretty: Bool = false) -> String {
        let e = JSONEncoder()
        e.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        return (try? String(data: e.encode(self), encoding: .utf8)) ?? "null"
    }
}

extension JSON: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral, ExpressibleByFloatLiteral, ExpressibleByIntegerLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(arrayLiteral elements: JSON...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSON)...) { self = .object(Dictionary(elements, uniquingKeysWith: { a, _ in a })) }
}

/// Typed access to tool arguments with errors an agent can act on.
public struct Args {
    public let raw: [String: JSON]
    /// Collects the names read through the accessors below (not through `raw`).
    let reads: ArgReads?

    public init(_ json: JSON?) {
        raw = json?.object ?? [:]
        reads = nil
    }

    public init(raw: [String: JSON]) {
        self.raw = raw
        reads = nil
    }

    init(_ json: JSON?, reads: ArgReads) {
        raw = json?.object ?? [:]
        self.reads = reads
    }

    /// The raw value of one argument.
    public func value(_ k: String) -> JSON? {
        reads?.names.insert(k)
        return raw[k]
    }

    public func has(_ k: String) -> Bool { value(k).map { !$0.isNull } ?? false }

    public func string(_ k: String) throws -> String {
        guard let s = optString(k) else { throw EditError("Missing string argument '\(k)'") }
        return s
    }

    public func optString(_ k: String) -> String? {
        guard let v = value(k) else { return nil }
        if let s = v.string { return s }
        if let d = v.double { return d.rounded() == d ? String(Int(d)) : String(d) }
        return nil
    }

    /// Accepts seconds as a number or "m:ss.ff" / "h:mm:ss.ff" strings.
    public func time(_ k: String) throws -> Seconds {
        guard let t = try optTime(k) else { throw EditError("Missing time argument '\(k)' (seconds)") }
        return t
    }

    public func optTime(_ k: String) throws -> Seconds? {
        guard let v = value(k), !v.isNull else { return nil }
        return try Args.parseTime(v, name: k)
    }

    /// Resolves anchors such as "talk.w12" or "clip_x.end" in timeline time; set per tool call.
    nonisolated(unsafe) static var timelineResolver: ((String) throws -> Seconds)?
    /// Resolves word anchors to source time, for arguments that are positions in a media file.
    nonisolated(unsafe) static var sourceResolver: ((String) throws -> Seconds)?

    static func parseTime(_ v: JSON, name: String) throws -> Seconds {
        if case .number(let n) = v { return n }
        if let s = v.string {
            if let d = Double(s) { return d }
            let parts = s.split(separator: ":").map { Double($0) }
            if !parts.isEmpty, parts.allSatisfy({ $0 != nil }) {
                return parts.reduce(0.0) { $0 * 60 + $1! }
            }
            if let r = timelineResolver { return try r(s) }
        }
        throw EditError("'\(name)' must be seconds or an anchor, got \(v.encoded())")
    }

    static func parseSourceTime(_ v: JSON, name: String) throws -> Seconds {
        if let s = v.string, Double(s) == nil, !s.contains(":") || s.contains("@"), let r = sourceResolver { return try r(s) }
        let saved = timelineResolver
        timelineResolver = nil
        defer { timelineResolver = saved }
        return try parseTime(v, name: name)
    }

    /// A position in a media file: seconds, a word anchor like "talk.w12.end", or a source timecode like "talk@01:00:12:10".
    public func optSourceTime(_ k: String) throws -> Seconds? {
        guard let v = value(k), !v.isNull else { return nil }
        return try Args.parseSourceTime(v, name: k)
    }

    public func sourceTime(_ k: String) throws -> Seconds {
        guard let t = try optSourceTime(k) else { throw EditError("Missing source time '\(k)'") }
        return t
    }

    public func double(_ k: String) throws -> Double {
        guard let d = optDouble(k) else { throw EditError("Missing number argument '\(k)'") }
        return d
    }

    public func optDouble(_ k: String) -> Double? { value(k)?.double }
    public func optInt(_ k: String) -> Int? { optDouble(k).map { Int($0) } }
    public func optBool(_ k: String) -> Bool? {
        guard let v = value(k) else { return nil }
        if let b = v.bool { return b }
        if let s = v.string { return ["true", "yes", "1"].contains(s.lowercased()) }
        return nil
    }
    public func bool(_ k: String, default d: Bool) -> Bool { optBool(k) ?? d }

    public func strings(_ k: String) -> [String]? {
        guard let v = value(k) else { return nil }
        if let a = v.array { return a.compactMap { $0.string } }
        if let s = v.string { return [s] }
        return nil
    }

    public func color(_ k: String) throws -> RGBA? {
        guard let s = optString(k) else { return nil }
        if s.lowercased() == "none" || s.isEmpty { return nil }
        guard let c = RGBA(hex: s) ?? Args.namedColors[s.lowercased()] else { throw EditError("'\(k)' must be a hex color like #FFD60A, got \(s)") }
        return c
    }

    public func clearsColor(_ k: String) -> Bool {
        guard let s = value(k)?.string?.lowercased() else { return raw[k]?.isNull ?? false }
        return s == "none" || s.isEmpty
    }

    public func enumValue<T: RawRepresentable>(_ k: String, _ type: T.Type) throws -> T? where T.RawValue == String {
        guard let s = optString(k) else { return nil }
        guard let v = T(rawValue: s) else { throw EditError("Invalid value '\(s)' for '\(k)'") }
        return v
    }

    static let namedColors: [String: RGBA] = [
        "black": .black, "white": .white,
        "red": RGBA(hex: "#FF3B30")!, "yellow": RGBA(hex: "#FFD60A")!, "green": RGBA(hex: "#30D158")!,
        "blue": RGBA(hex: "#0A84FF")!, "orange": RGBA(hex: "#FF9F0A")!, "pink": RGBA(hex: "#FF375F")!,
        "purple": RGBA(hex: "#BF5AF2")!, "gray": RGBA(hex: "#8E8E93")!, "transparent": RGBA(r: 0, g: 0, b: 0, a: 0),
    ]
}

/// Argument names a tool read, to check them against what it declares.
final class ArgReads {
    var names = Set<String>()
}

/// Builds JSON Schema fragments for tool definitions.
enum Schema {
    static func object(_ props: [String: JSON], required: [String] = []) -> JSON {
        var o: [String: JSON] = ["type": "object", "properties": .object(props)]
        if !required.isEmpty { o["required"] = .array(required.map { .string($0) }) }
        return .object(o)
    }

    static func string(_ d: String, values: [String]? = nil) -> JSON {
        var o: [String: JSON] = ["type": "string", "description": .string(d)]
        if let values { o["enum"] = .array(values.map { .string($0) }) }
        return .object(o)
    }

    static func number(_ d: String) -> JSON { ["type": "number", "description": .string(d)] }
    static func time(_ d: String) -> JSON { ["type": ["number", "string"], "description": .string(d + " (seconds)")] }
    static func integer(_ d: String) -> JSON { ["type": "integer", "description": .string(d)] }
    static func bool(_ d: String) -> JSON { ["type": "boolean", "description": .string(d)] }
    static func array(_ items: JSON, _ d: String) -> JSON { ["type": "array", "items": items, "description": .string(d)] }
    static func strings(_ d: String) -> JSON { array(["type": "string"], d) }
    static func numbers(_ d: String) -> JSON { array(["type": "number"], d) }
}
