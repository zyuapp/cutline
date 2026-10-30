import Foundation

/// Graphics the engine draws from parameters alone: shapes, arrows, callouts, lower thirds, counters, guides.
///
/// Units match effects: lengths are fractions of the frame height, positions are fractions of the
/// frame with the origin at the top left, angles are degrees clockwise. Numbers and colors animate.
public enum GeneratorCatalog {
    public static func type(_ id: String) -> EffectType? { byId[id] }

    static func pos(_ name: String, _ d: Double, _ summary: String) -> ParamSpec {
        ParamSpec(name, .number, .number(d), min: -1, max: 2, summary)
    }

    static func len(_ name: String, _ d: Double, _ hi: Double, _ summary: String) -> ParamSpec {
        ParamSpec(name, .number, .number(d), min: 0, max: hi, unit: "of frame height", summary)
    }

    static func color(_ name: String, _ d: String, _ summary: String) -> ParamSpec {
        ParamSpec(name, .color, .string(d), summary)
    }

    static func progress(_ summary: String) -> ParamSpec {
        ParamSpec("progress", .number, .number(1), min: 0, max: 1, summary)
    }

    static let font = ParamSpec("font", .text, .string("system"), "\"system\", \"rounded\", \"serif\", \"mono\" or a font family name")

    static let box: [ParamSpec] = [
        pos("x", 0.5, "Horizontal center, 0 left to 1 right"),
        pos("y", 0.5, "Vertical center, 0 top to 1 bottom"),
        len("width", 0.4, 4, "Width"),
        len("height", 0.25, 2, "Height"),
    ]

    static let paint: [ParamSpec] = [
        color("fill", "#0A84FF", "Fill color; transparent for an outline"),
        color("stroke", "#FFFFFF", "Outline color"),
        len("stroke_width", 0, 0.1, "Outline width; 0 for none"),
        ParamSpec("rotation", .number, .number(0), min: -360, max: 360, unit: "degrees", "Rotation clockwise"),
    ]

    static let segment: [ParamSpec] = [
        pos("x1", 0.3, "Start, horizontal"),
        pos("y1", 0.6, "Start, vertical"),
        pos("x2", 0.7, "End, horizontal"),
        pos("y2", 0.4, "End, vertical"),
    ]

    public static let all: [EffectType] = basic + motion

    static let basic: [EffectType] = [
        EffectType(id: "shape.rect", category: "generator", summary: "Rectangle with optional rounded corners and outline", params: box + [
            len("radius", 0.02, 1, "Corner radius"),
        ] + paint),
        EffectType(id: "shape.ellipse", category: "generator", summary: "Ellipse or circle with optional outline", params: box + paint),
        EffectType(id: "shape.line", category: "generator", summary: "Straight line that can draw itself on", params: segment + [
            color("color", "#FFFFFF", "Line color"),
            len("width", 0.008, 0.2, "Line width"),
            ParamSpec("round", .bool, .bool(true), "Round line caps"),
            ParamSpec("dash", .bool, .bool(false), "Dashed line"),
            progress("How much of the line is drawn, from the start; animate 0→1 to draw it on"),
        ]),
        EffectType(id: "shape.arrow", category: "generator", summary: "Arrow pointing from start to end, straight or bent, that can draw itself on", params: segment + [
            color("color", "#FFD60A", "Arrow color"),
            len("width", 0.008, 0.2, "Shaft width"),
            len("head", 0.04, 0.5, "Head length"),
            ParamSpec("curve", .number, .number(0), min: -1, max: 1, "Bend: 0 straight, positive bows to the left of the direction of travel"),
            progress("How much of the arrow is drawn; the head rides the tip. Animate 0→1 to draw it on"),
        ]),
        EffectType(id: "shape.highlight", category: "generator", summary: "Marker-pen highlight box to place behind text", params: [
            pos("x", 0.5, "Horizontal center"),
            pos("y", 0.5, "Vertical center"),
            len("width", 0.5, 4, "Width"),
            len("height", 0.08, 1, "Height"),
            color("color", "#FFD60A8C", "Ink color; keep some transparency"),
            progress("Wipe from the left; animate 0→1 to swipe it on"),
            ParamSpec("skew", .number, .number(-0.15), min: -1, max: 1, "Slant: positive leans the top to the right"),
        ]),
        EffectType(id: "callout", category: "generator", summary: "Label with a leader line to a dot on a target point", params: [
            pos("target_x", 0.6, "Point the callout marks, horizontal"),
            pos("target_y", 0.45, "Point the callout marks, vertical"),
            ParamSpec("label", .text, .string("Label"), "Label text"),
            pos("label_x", 0.3, "Label center, horizontal"),
            pos("label_y", 0.25, "Label center, vertical"),
            color("color", "#FFFFFF", "Label background, line and dot color"),
            color("text_color", "#111111", "Label text color"),
            len("size", 0.035, 0.3, "Label font size"),
            font,
        ]),
        EffectType(id: "lower_third", category: "generator", summary: "Name and title graphic that builds on", params: [
            ParamSpec("title", .text, .string("Name Surname"), "First line, usually a name"),
            ParamSpec("subtitle", .text, .string("Title"), "Second line; empty for none"),
            ParamSpec("style", .choice(["clean", "bar", "box", "underline"]), .string("bar"), "clean: text only; bar: accent bar at the left; box: dark panel with accent edge; underline: accent rule under the title"),
            color("accent", "#0A84FF", "Accent color of the bar, edge or rule"),
            color("text_color", "#FFFFFF", "Text color"),
            pos("x", 0.06, "Left edge of the graphic"),
            pos("y", 0.8, "Vertical center of the graphic"),
            len("width", 0, 4, "Minimum width; 0 fits the text"),
            len("size", 0.055, 0.3, "Title font size; the subtitle is 58% of it"),
            progress("Build: accent, then title, then subtitle. Animate 0→1 in, 1→0 out"),
            font,
        ]),
        EffectType(id: "progress_bar", category: "generator", summary: "Full-width progress bar, usually animated 0→1 over the video", params: [
            pos("y", 0.994, "Vertical center of the bar"),
            len("height", 0.012, 1, "Bar thickness"),
            color("color", "#FF375F", "Filled part"),
            color("background", "#FFFFFF33", "Unfilled part; transparent for none"),
            ParamSpec("progress", .number, .number(0.5), min: 0, max: 1, "Filled fraction"),
        ]),
        EffectType(id: "counter", category: "generator", summary: "Number that counts from one value to another", params: [
            ParamSpec("from", .number, .number(0), "Value at progress 0"),
            ParamSpec("to", .number, .number(100), "Value at progress 1"),
            progress("Where between from and to; animate 0→1 to count"),
            ParamSpec("prefix", .text, .string(""), "Text before the number, e.g. \"$\""),
            ParamSpec("suffix", .text, .string(""), "Text after the number, e.g. \"%\""),
            ParamSpec("decimals", .number, .number(0), min: 0, max: 6, animatable: false, "Digits after the decimal point"),
            ParamSpec("separator", .bool, .bool(true), "Group thousands with commas"),
            len("size", 0.12, 1, "Font size"),
            color("color", "#FFFFFF", "Text color"),
            pos("x", 0.5, "Horizontal center"),
            pos("y", 0.5, "Vertical center"),
            font,
        ]),
        EffectType(id: "gradient", category: "generator", summary: "Full-frame linear gradient", params: [
            color("color1", "#0A84FF", "Start color"),
            color("color2", "#BF5AF2", "End color"),
            ParamSpec("angle", .number, .number(180), min: -360, max: 360, unit: "degrees", "Direction the gradient travels, CSS style: 0 upward, 90 rightward, 180 downward"),
        ]),
        EffectType(id: "grid_overlay", category: "generator", summary: "Composition guides for checking framing", params: [
            ParamSpec("kind", .choice(["thirds", "safe", "center"]), .string("thirds"), "thirds: rule-of-thirds grid; safe: 90% action and 80% title safe areas; center: crosshair"),
            color("color", "#FFFFFFB3", "Guide color"),
            len("width", 0.002, 0.05, "Line width"),
        ]),
    ]

    static let byId: [String: EffectType] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
}

/// Marks a clip as a generator. Its parameters live in the clip's parameter storage under the catalog names.
public struct GeneratorSpec: Codable, Equatable, Hashable, Sendable {
    /// A `GeneratorCatalog` id such as "shape.arrow".
    public var type: String

    public init(type: String) {
        self.type = type
    }
}

/// Words a graphic puts on screen, for the checks titles get.
public struct GeneratorText: Equatable, Sendable {
    public var text: String
    /// Vertical center and font size, as fractions of the frame height.
    public var y: Double
    public var size: Double
    public var color: RGBA
    /// The panel or pill drawn behind the words, if any.
    public var background: RGBA?
}

extension Clip {
    /// A generator parameter's value at `local` seconds into the clip.
    public func generatorValue(_ name: String, at local: Seconds) -> ParamValue? {
        guard kind == .generator, let gen = effects.first(where: { GeneratorCatalog.type($0.type) != nil }) else { return nil }
        return anim["fx.\(gen.id).\(name)"]?.value(at: local) ?? gen.params[name] ?? GeneratorCatalog.spec(type: gen.type, name: name, params: gen.params)?.defaultValue
    }

    /// The words a lower third, callout or counter shows at `local`; nil for graphics without text or with none showing.
    public func generatorText(at local: Seconds) -> GeneratorText? {
        guard kind == .generator, let type = effects.first(where: { GeneratorCatalog.type($0.type) != nil })?.type else { return nil }
        func str(_ k: String) -> String { generatorValue(k, at: local)?.string ?? "" }
        func num(_ k: String) -> Double { generatorValue(k, at: local)?.number ?? 0 }
        func color(_ k: String) -> RGBA { generatorValue(k, at: local)?.color ?? RGBA(r: 1, g: 1, b: 1, a: 1) }
        switch type {
        case "lower_third":
            let text = [str("title"), str("subtitle")].filter { !$0.isEmpty }.joined(separator: " — ")
            guard !text.isEmpty, num("progress") > 0 else { return nil }
            let fg = color("text_color")
            let light = 0.299 * fg.r + 0.587 * fg.g + 0.114 * fg.b > 0.5
            let panel = str("style") == "box" ? (light ? RGBA(r: 0.06, g: 0.06, b: 0.08, a: 0.72) : RGBA(r: 1, g: 1, b: 1, a: 0.88)) : nil
            return GeneratorText(text: text, y: num("y"), size: num("size"), color: fg, background: panel)
        case "callout":
            guard !str("label").isEmpty else { return nil }
            return GeneratorText(text: str("label"), y: num("label_y"), size: num("size"), color: color("text_color"), background: color("color"))
        case "title.lower_third_modern", "title.lower_third_box", "title.lower_third_pill", "title.lower_third_line":
            let text = [str("title"), str("subtitle")].filter { !$0.isEmpty }.joined(separator: " — ")
            guard !text.isEmpty else { return nil }
            let panel: RGBA? = type == "title.lower_third_box" ? color("panel") : type == "title.lower_third_pill" ? color("panel") : nil
            return GeneratorText(text: text, y: num("y"), size: num("size"), color: color("text_color"), background: panel)
        case "title.card":
            let text = [str("kicker"), str("title"), str("subtitle")].filter { !$0.isEmpty }.joined(separator: " — ")
            guard !text.isEmpty else { return nil }
            let bg = color("background")
            return GeneratorText(text: text, y: num("y"), size: num("size"), color: color("text_color"), background: bg.a > 0.05 ? bg : nil)
        case "title.quote":
            let text = [str("quote"), str("author")].filter { !$0.isEmpty }.joined(separator: " — ")
            guard !text.isEmpty else { return nil }
            let bg = color("background")
            return GeneratorText(text: text, y: num("y"), size: num("size"), color: color("text_color"), background: bg.a > 0.05 ? bg : nil)
        case "title.end_card":
            let text = [str("title"), str("subtitle"), str("button")].filter { !$0.isEmpty }.joined(separator: " — ")
            guard !text.isEmpty else { return nil }
            let bg = color("background")
            return GeneratorText(text: text, y: 0.3, size: num("size"), color: color("text_color"), background: bg.a > 0.05 ? bg : nil)
        case "title.data_callout":
            let n = num("value")
            let text = str("prefix") + String(format: "%.\(Int(num("decimals")))f", n) + str("suffix") + (str("label").isEmpty ? "" : " " + str("label"))
            return GeneratorText(text: text, y: num("y"), size: num("size"), color: color("text_color"), background: nil)
        case "counter":
            let n = num("from") + (num("to") - num("from")) * min(max(num("progress"), 0), 1)
            return GeneratorText(text: str("prefix") + String(format: "%.\(Int(num("decimals")))f", n) + str("suffix"), y: num("y"), size: num("size"), color: color("color"), background: nil)
        default:
            return nil
        }
    }
}
