import CutlineCore
import Foundation

/// Enum values: spellings matched ignoring case, "_", "-" and spaces, synonyms per argument name, and errors that
/// list the valid values with the closest one.
extension Toolbox {
    /// Other words for enum values, by argument name.
    static let valueAliases: [String: [String: String]] = {
        let entrance = ["fadeup": "slideUp", "rise": "slideUp", "slide": "slideUp", "riseup": "slideUp", "moveup": "slideUp",
                        "typing": "typewriter", "typeon": "typewriter", "type": "typewriter", "scale": "pop", "zoom": "pop", "bounce": "pop",
                        "dissolve": "fade", "fadein": "fade", "popin": "pop", "slidein": "slideUp", "off": "none", "cut": "none"]
        let layouts = ["5.1": "surround51", "51": "surround51", "7.1": "surround71", "71": "surround71", "2.0": "stereo", "1.0": "mono"]
        return [
            "layout": layouts, "downmix": layouts,
            "animation_in": entrance,
            "animation_out": entrance.merging(["fadedown": "slideUp", "sink": "slideUp"]) { a, _ in a },
            // Caption presets.
            "preset": ["subtitle": "clean", "subtitles": "clean", "subs": "clean", "srt": "clean", "boxed": "clean", "box": "clean", "standard": "clean",
                       "plain": "minimal", "simple": "minimal", "subtle": "minimal", "highlight": "karaoke", "wordhighlight": "karaoke",
                       "social": "bold", "tiktok": "bold", "reels": "bold", "shorts": "bold", "punchy": "bold", "typewriter": "reveal", "wordbyword": "reveal"],
            "view": ["beforeafter": "compare", "split": "compare", "ab": "compare", "sidebyside": "compare", "diff": "compare", "mask": "matte", "key": "matte", "normal": "picture"],
        ]
    }()

    static func enumKey(_ s: String) -> String { s.lowercased().filter { $0 != "_" && $0 != "-" && $0 != " " } }

    /// The declared spelling of `s` among `valid`, nil when it isn't one of them.
    static func canonicalValue(_ s: String, valid: [String], name: String) -> String? {
        if valid.contains(s) { return s }
        let key = enumKey(s)
        if let v = valid.first(where: { enumKey($0) == key }) { return v }
        if let to = valueAliases[name]?[key], valid.contains(to) { return to }
        return nil
    }

    /// "Invalid value 'x' for 'k' (did you mean y?). Valid: a, b, c".
    static func invalidValueMessage(_ s: String, name: String, valid: [String]) -> String {
        let key = enumKey(s)
        let close = valid.map { ($0, editDistance(enumKey($0), key)) }
            .filter { $0.1 <= max(2, key.count / 3) || enumKey($0.0).hasPrefix(key) || key.hasPrefix(enumKey($0.0)) }
            .sorted { $0.1 < $1.1 }.prefix(2).map(\.0)
        let shown = valid.count > 40 ? valid.prefix(40).joined(separator: ", ") + ", … (catalog lists all)" : valid.joined(separator: ", ")
        return "Invalid value '\(s)' for '\(name)'" + (close.isEmpty ? "" : " (did you mean \(close.joined(separator: " or "))?)") + ". Valid: " + shown
    }

    /// `value` with enum strings rewritten to the spelling `schema` declares.
    static func normalizingValues(_ value: JSON, schema: JSON, name: String) -> JSON {
        switch value {
        case .string(let s):
            guard let valid = schema["enum"]?.array?.compactMap(\.string), let v = canonicalValue(s, valid: valid, name: name) else { return value }
            return .string(v)
        case .array(let a):
            guard let items = schema["items"] else { return value }
            return .array(a.map { normalizingValues($0, schema: items, name: name) })
        case .object(var o):
            guard let props = schema["properties"]?.object else { return value }
            for (k, v) in o { if let sub = props[k] { o[k] = normalizingValues(v, schema: sub, name: k) } }
            return .object(o)
        default:
            return value
        }
    }

    /// One message per string in `value` that isn't among its schema's enum values.
    static func invalidValues(_ value: JSON, schema: JSON, path: String, name: String) -> [String] {
        switch value {
        case .string(let s):
            guard let valid = schema["enum"]?.array?.compactMap(\.string), !valid.contains(s), !openEnumValue(name, s) else { return [] }
            return [invalidValueMessage(s, name: path, valid: valid)]
        case .array(let a):
            guard let items = schema["items"] else { return [] }
            return a.enumerated().flatMap { invalidValues($0.element, schema: items, path: "\(path)[\($0.offset)]", name: name) }
        case .object(let o):
            guard let props = schema["properties"]?.object else { return [] }
            return o.sorted { $0.key < $1.key }.flatMap { k, v in props[k].map { invalidValues(v, schema: $0, path: path.isEmpty ? k : path + "." + k, name: k) } ?? [] }
        default:
            return []
        }
    }

    /// Values an enum argument takes beyond its listed ones: Audio Unit effect types, and batch tools (batch names
    /// the tools it can't run).
    static func openEnumValue(_ name: String, _ s: String) -> Bool {
        (name == "type" && ProAudioCatalog.isPlugin(s)) || name == "tool"
    }
}

extension Args {
    /// `enumValue` for enums whose cases can be listed: matches spellings loosely and lists the values on error.
    public func enumValue<T: RawRepresentable & CaseIterable>(_ k: String, _ type: T.Type) throws -> T? where T.RawValue == String {
        guard let s = optString(k) else { return nil }
        if let v = T(rawValue: s) { return v }
        let valid = T.allCases.map(\.rawValue)
        guard let c = Toolbox.canonicalValue(s, valid: valid, name: k), let v = T(rawValue: c) else { throw EditError(Toolbox.invalidValueMessage(s, name: k, valid: valid)) }
        return v
    }
}
