import Foundation

/// A color fill across a shape's bounds.
public struct ShapeGradient: Equatable, Sendable {
    public enum Kind: String, Sendable { case linear, radial }
    public var kind: Kind
    public var colors: [RGBA]
    /// Positions 0…1 of each color.
    public var stops: [Double]
    /// Linear: direction of travel, CSS style (0 upward, 90 rightward, 180 downward).
    public var angle: Double
    /// Radial: center in fractions of the shape's bounds and radius in fractions of their larger side.
    public var center: (Double, Double)
    public var radius: Double

    public static func == (a: ShapeGradient, b: ShapeGradient) -> Bool {
        a.kind == b.kind && a.colors == b.colors && a.stops == b.stops && a.angle == b.angle && a.center == b.center && a.radius == b.radius
    }
}

/// One shape of a `shape` generator, parsed from its `shapes` JSON.
public struct ShapeItem: Equatable, Sendable {
    public static let kinds = ["rect", "ellipse", "polygon", "star", "line", "path"]

    public var id: String
    public var type: String
    /// Values given in the JSON for animatable properties, by property name.
    public var values: [String: ParamValue]
    public var gradient: ShapeGradient?
    /// SVG path data for type path, and the path `morph` blends toward.
    public var d: String?
    public var dTo: String?
    /// [minX, minY, width, height] of the path's own coordinates; the path is fitted into width × height.
    public var viewBox: [Double]?
    public var dash: [Double]
    public var cap: String
    public var join: String
    public var evenOdd: Bool
    public var sides: Int

    /// The value of an animatable property from the JSON, or its default.
    public func value(_ prop: String) -> ParamValue {
        if let v = values[prop] { return v }
        if prop == "stroke_width" { return .number(values["stroke"] != nil ? 0.006 : 0) }
        if prop == "fill" { return .string(values["stroke"] != nil || gradient != nil ? "#00000000" : "#FFFFFFFF") }
        return ShapeLayers.prop(prop)?.defaultValue ?? .number(0)
    }

    /// The path in shape-local units (frame heights, centered on the position) with `morph` applied.
    public func path(_ num: (String) -> Double) throws -> ShapePath {
        let w = num("width"), h = num("height")
        switch type {
        case "rect": return .rect(width: w, height: h, radius: num("radius"))
        case "ellipse": return .ellipse(width: w, height: h)
        case "polygon": return .polygon(width: w, height: h, sides: sides, roundness: num("roundness"))
        case "star": return .polygon(width: w, height: h, sides: sides, inner: num("inner"), roundness: num("roundness"))
        case "line": return .line(length: w)
        default:
            var p = try ShapeLayers.cachedPath(d ?? "")
            if let to = dTo {
                let q = try ShapeLayers.cachedPath(to)
                p = p.morph(to: q, num("morph")) ?? p
            }
            guard let vb = viewBox, vb.count == 4, vb[2] > 0, vb[3] > 0 else { return p }
            let s = min(w / vb[2], h / vb[3])
            let cx = vb[0] + vb[2] / 2, cy = vb[1] + vb[3] / 2
            return p.mapped { PathPoint(($0.x - cx) * s, ($0.y - cy) * s) }
        }
    }
}

/// The `shape` generator's shape list and its per-shape animatable properties, addressed as
/// fx.gen.<shape id>.<property>.
public enum ShapeLayers {
    static func n(_ name: String, _ d: Double, _ lo: Double?, _ hi: Double?, _ unit: String = "", _ summary: String) -> ParamSpec {
        ParamSpec(name, .number, .number(d), min: lo, max: hi, unit: unit, summary)
    }

    public static let props: [ParamSpec] = [
        n("x", 0.5, -2, 3, "of frame width", "Position (center of rect/ellipse/polygon/star/line; origin of a path), 0 left to 1 right"),
        n("y", 0.5, -2, 3, "of frame height", "Position, 0 top to 1 bottom"),
        n("width", 0.3, 0, 10, "of frame height", "Width; a line's length; a path with view_box is fitted into width × height"),
        n("height", 0.3, 0, 10, "of frame height", "Height"),
        n("radius", 0, 0, 5, "of frame height", "Rect corner radius"),
        n("roundness", 0, 0, 1, "", "Polygon and star corner rounding"),
        n("inner", 0.45, 0, 1, "", "Star inner radius as a fraction of the outer"),
        n("scale", 1, 0, 50, "", "Uniform scale around the position"),
        n("scale_x", 1, -50, 50, "", "Horizontal scale"),
        n("scale_y", 1, -50, 50, "", "Vertical scale"),
        n("rotation", 0, -36000, 36000, "degrees", "Clockwise rotation around the position"),
        n("opacity", 1, 0, 1, "", "Opacity of fill and stroke"),
        ParamSpec("fill", .color, .string("#FFFFFF"), "Fill color; default white, or none when the shape has a stroke or gradient. \"none\" or #00000000 for no fill"),
        n("fill_opacity", 1, 0, 1, "", "Fill opacity"),
        ParamSpec("stroke", .color, .string("#00000000"), "Stroke color; default none"),
        n("stroke_width", 0, 0, 1, "of frame height", "Stroke width; defaults to 0.006 when stroke is set"),
        n("stroke_opacity", 1, 0, 1, "", "Stroke opacity"),
        n("trim_start", 0, 0, 1, "", "Trim paths: start of the stroked part as a fraction of the path length"),
        n("trim_end", 1, 0, 1, "", "Trim paths: end of the stroked part; animate 0→1 to draw the stroke on"),
        n("trim_offset", 0, -100, 100, "", "Trim paths: shifts the stroked part along the path, in path lengths (wraps)"),
        n("dash_offset", 0, -100, 100, "of frame height", "Shifts the dash pattern along the path; animate for marching ants"),
        n("morph", 0, 0, 1, "", "Path morph: 0 shows d, 1 shows d_to (same number of segments per contour)"),
        n("repeat_count", 1, 0, 200, "", "Repeater: number of copies; fractional counts fade the last copy"),
        n("repeat_x", 0, -10, 10, "of frame height", "Repeater: horizontal offset added per copy"),
        n("repeat_y", 0, -10, 10, "of frame height", "Repeater: vertical offset added per copy"),
        n("repeat_rotation", 0, -3600, 3600, "degrees", "Repeater: rotation added per copy"),
        n("repeat_scale", 1, 0, 10, "", "Repeater: scale multiplied per copy"),
        n("repeat_opacity", 1, 0, 1, "", "Repeater: opacity of the last copy (the first is 1)"),
        n("repeat_anchor_x", 0, -10, 10, "of frame height", "Repeater: pivot for rotation and scale, offset from the position"),
        n("repeat_anchor_y", 0, -10, 10, "of frame height", "Repeater: pivot, vertical offset from the position"),
    ]

    static let byName: [String: ParamSpec] = Dictionary(uniqueKeysWithValues: props.map { ($0.name, $0) })

    public static func prop(_ name: String) -> ParamSpec? { byName[name] }

    public static let docs = """
        JSON list of shapes drawn in order (later on top). Each shape: {id, type: rect|ellipse|polygon|star|line|path, \
        x, y (position: fractions of the frame), width, height (fractions of frame height), radius (rect corners), sides (polygon sides / star points, default 5), inner, roundness, \
        d (SVG path data for type path, in frame heights around x,y — or in its own units with view_box [minX, minY, w, h], fitted into width × height), d_to (path that morph blends toward), \
        fill (hex, "none", or {"gradient": "linear"|"radial", "colors": [...], "stops": [...], "angle": 90, "center": [0.5, 0.5], "radius": 0.5} across the shape's bounds), fill_opacity, fill_rule (nonzero|evenodd), \
        stroke, stroke_width, stroke_opacity, dash ([on, off, …] in frame heights), cap (butt|round|square), join (miter|round|bevel), \
        scale, scale_x, scale_y, rotation, opacity, trim_start, trim_end, trim_offset (trim paths act on the stroke), dash_offset, morph, \
        repeat_count, repeat_x, repeat_y, repeat_rotation, repeat_scale, repeat_opacity, repeat_anchor_x/y (repeater copies)}. \
        Ids default to s1, s2… by position. Animate any number or color property with param_set path fx.gen.<id>.<property>, e.g. fx.gen.ring.trim_end
        """

    // MARK: Parsing

    private static let lock = NSLock()
    nonisolated(unsafe) private static var parsed: [String: [ShapeItem]] = [:]
    nonisolated(unsafe) private static var paths: [String: ShapePath] = [:]

    static func cachedPath(_ d: String) throws -> ShapePath {
        if let hit = lock.withLock({ paths[d] }) { return hit }
        let p = try ShapePath.svg(d)
        lock.withLock {
            if paths.count > 256 { paths.removeAll() }
            paths[d] = p
        }
        return p
    }

    /// Parses and checks a `shapes` value; results are cached by the JSON text.
    public static func parse(_ json: String) throws -> [ShapeItem] {
        if let hit = lock.withLock({ parsed[json] }) { return hit }
        let items = try decode(json)
        lock.withLock {
            if parsed.count > 128 { parsed.removeAll() }
            parsed[json] = items
        }
        return items
    }

    static func decode(_ json: String) throws -> [ShapeItem] {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return [] }
        guard let data = trimmed.data(using: .utf8), let any = try? JSONSerialization.jsonObject(with: data) else {
            throw EditError("shapes must be a JSON list of shape objects, e.g. [{\"type\": \"ellipse\", \"width\": 0.2, \"height\": 0.2}]")
        }
        let list: [[String: Any]]
        if let l = any as? [[String: Any]] { list = l } else if let one = any as? [String: Any] { list = [one] } else {
            throw EditError("shapes must be a list of objects")
        }
        var out: [ShapeItem] = []
        var ids = Set<String>()
        let known: Set<String> = Set(props.map(\.name)).union(["id", "type", "d", "d_to", "view_box", "dash", "cap", "join", "fill_rule", "sides", "points"])
        for (i, o) in list.enumerated() {
            let id = (o["id"] as? String) ?? "s\(i + 1)"
            guard id.range(of: #"^[A-Za-z][A-Za-z0-9_]*$"#, options: .regularExpression) != nil else { throw EditError("Shape id \(id) must be letters, digits and _, starting with a letter") }
            guard ids.insert(id).inserted else { throw EditError("Two shapes have the id \(id)") }
            let type = (o["type"] as? String) ?? (o["d"] != nil ? "path" : "rect")
            guard ShapeItem.kinds.contains(type) else { throw EditError("Shape \(id): type must be one of \(ShapeItem.kinds.joined(separator: ", ")), got \(type)") }
            if let unknown = o.keys.sorted().first(where: { !known.contains($0) }) {
                let guess = known.min { editDistance($0, unknown) < editDistance($1, unknown) } ?? ""
                throw EditError("Shape \(id) has no property \(unknown). Did you mean \(guess)? Properties: \(known.sorted().joined(separator: ", "))")
            }
            var item = ShapeItem(id: id, type: type, values: [:], gradient: nil, d: o["d"] as? String, dTo: o["d_to"] as? String, viewBox: nil, dash: [], cap: (o["cap"] as? String) ?? "round", join: (o["join"] as? String) ?? "round", evenOdd: (o["fill_rule"] as? String) == "evenodd", sides: (o["sides"] as? NSNumber)?.intValue ?? (o["points"] as? NSNumber)?.intValue ?? 5)
            guard ["butt", "round", "square"].contains(item.cap) else { throw EditError("Shape \(id): cap is butt, round or square") }
            guard ["miter", "round", "bevel"].contains(item.join) else { throw EditError("Shape \(id): join is miter, round or bevel") }
            guard (3...64).contains(item.sides) else { throw EditError("Shape \(id): sides must be 3…64") }
            if let vb = o["view_box"] {
                guard let a = vb as? [NSNumber], a.count == 4, a[2].doubleValue > 0, a[3].doubleValue > 0 else { throw EditError("Shape \(id): view_box is [minX, minY, width, height]") }
                item.viewBox = a.map(\.doubleValue)
            }
            if let dash = o["dash"] {
                guard let a = dash as? [NSNumber], a.allSatisfy({ $0.doubleValue >= 0 }), a.contains(where: { $0.doubleValue > 0 }) else { throw EditError("Shape \(id): dash is a list of lengths such as [0.02, 0.01]") }
                item.dash = a.map(\.doubleValue)
            }
            if type == "path" {
                guard let d = item.d else { throw EditError("Shape \(id): a path needs d (SVG path data such as \"M -0.2 0 C 0 -0.2 0 0.2 0.2 0\")") }
                let p = try ShapePath.svg(d)
                if let to = item.dTo, !p.morphs(with: try ShapePath.svg(to)) {
                    throw EditError("Shape \(id): d and d_to need the same number of contours and segments to morph")
                }
            }
            if let g = o["fill"] as? [String: Any] {
                item.gradient = try gradient(g, id: id)
            } else if let s = o["fill"] as? String, s.lowercased() == "none" {
                item.values["fill"] = .string("#00000000")
            }
            for p in props {
                guard let raw = o[p.name], !(p.name == "fill" && (item.gradient != nil || item.values["fill"] != nil)) else { continue }
                let v: ParamValue
                if let s = raw as? String {
                    v = p.name == "stroke" && s.lowercased() == "none" ? .string("#00000000") : .string(s)
                } else if let num = raw as? NSNumber {
                    v = .number(num.doubleValue)
                } else {
                    throw EditError("Shape \(id): \(p.name) needs a \(p.kind.label)")
                }
                item.values[p.name] = try p.validate(v, path: "\(id).\(p.name)")
            }
            out.append(item)
        }
        return out
    }

    static func gradient(_ o: [String: Any], id: String) throws -> ShapeGradient {
        let kind = ShapeGradient.Kind(rawValue: (o["gradient"] as? String) ?? (o["type"] as? String) ?? "linear")
        guard let kind else { throw EditError("Shape \(id): gradient is linear or radial") }
        let colors = ((o["colors"] as? [String]) ?? []).compactMap { RGBA(hex: $0) ?? RGBA.named($0) }
        guard colors.count >= 2 else { throw EditError("Shape \(id): a gradient fill needs colors: [\"#hex\", \"#hex\", …]") }
        var stops = ((o["stops"] as? [NSNumber]) ?? []).map(\.doubleValue)
        if stops.count != colors.count { stops = colors.indices.map { Double($0) / Double(colors.count - 1) } }
        let c = (o["center"] as? [NSNumber]).map(\.self).flatMap { $0.count == 2 ? ($0[0].doubleValue, $0[1].doubleValue) : nil } ?? (0.5, 0.5)
        return ShapeGradient(kind: kind, colors: colors, stops: stops, angle: (o["angle"] as? NSNumber)?.doubleValue ?? 180, center: c, radius: (o["radius"] as? NSNumber)?.doubleValue ?? 0.5)
    }

    /// The spec of "<shape id>.<property>" for a `shapes` value; its default is the value in the JSON.
    public static func spec(_ name: String, shapes json: String) -> ParamSpec? {
        let parts = name.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2, var p = prop(parts[1]), let items = try? parse(json), let item = items.first(where: { $0.id == parts[0] }) else { return nil }
        p.defaultValue = item.value(parts[1])
        p.name = name
        return p
    }

    /// Every "<shape id>.<property>" name with its value from the JSON.
    public static func names(shapes json: String) -> [(String, ParamValue)] {
        guard let items = try? parse(json) else { return [] }
        return items.flatMap { item in props.map { ("\(item.id).\($0.name)", item.value($0.name)) } }
    }
}
