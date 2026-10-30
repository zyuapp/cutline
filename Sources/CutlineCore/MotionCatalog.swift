import Foundation

/// Shape layers, particles, the 3D camera and designed title presets.
extension GeneratorCatalog {
    static func num(_ name: String, _ d: Double, _ lo: Double, _ hi: Double, unit: String = "", animatable: Bool? = nil, _ summary: String) -> ParamSpec {
        ParamSpec(name, .number, .number(d), min: lo, max: hi, unit: unit, animatable: animatable, summary)
    }

    static func text(_ name: String, _ d: String, _ summary: String) -> ParamSpec {
        ParamSpec(name, .text, .string(d), summary)
    }

    /// Timing shared by the title presets, which build on and off by themselves.
    static let timing: [ParamSpec] = [
        num("in", 0.9, 0, 10, unit: "seconds", animatable: false, "Length of the build-on from the clip start (after delay); 0 shows it fully at once"),
        num("out", 0.6, 0, 10, unit: "seconds", animatable: false, "Length of the build-off before the clip end; 0 cuts"),
        num("delay", 0, 0, 60, unit: "seconds", animatable: false, "Wait this long after the clip start before building on"),
    ]

    static let defaultShapes = ##"[{"id": "ring", "type": "ellipse", "width": 0.3, "height": 0.3, "stroke": "#FFFFFF", "stroke_width": 0.012}]"##

    static let motion: [EffectType] = [
        EffectType(id: "shape", category: "generator", summary: "Shape layer: rects, ellipses, polygons, stars, lines and SVG paths with solid or gradient fills, strokes, dashes, trim paths, path morphing and repeaters; every shape property animates as fx.gen.<shape id>.<property>", params: [
            ParamSpec("shapes", .text, .string(defaultShapes), ShapeLayers.docs),
        ]),
        EffectType(id: "particles", category: "generator", summary: "Particle emitter: sparks, confetti, snow, dust, bubbles, stars or an image, with gravity, wind, drag, turbulence, size and color over life; the same seed always gives the same particles", params: [
            ParamSpec("emitter", .choice(["point", "line", "box", "circle"]), .string("point"), "Where particles are born: a point, a horizontal line, a box or an ellipse of emitter_width × emitter_height"),
            pos("x", 0.5, "Emitter center, horizontal; animate it and particles trail behind"),
            pos("y", 0.6, "Emitter center, vertical"),
            len("emitter_width", 0.3, 5, "Emitter width (line, box, circle)"),
            len("emitter_height", 0.1, 5, "Emitter height (box, circle)"),
            num("rate", 40, 0, 2000, unit: "per second", animatable: false, "Particles born per second"),
            num("burst", 0, 0, 5000, animatable: false, "Particles born at once at the clip start (after prewarm)"),
            num("lifetime", 2.5, 0.05, 30, unit: "seconds", animatable: false, "How long each particle lives"),
            num("lifetime_random", 0.3, 0, 1, animatable: false, "Random variation of lifetime"),
            num("direction", 0, -360, 360, unit: "degrees", "Launch direction, CSS style: 0 up, 90 right, 180 down; read when each particle is born"),
            num("spread", 30, 0, 180, unit: "degrees", "Random deviation either side of direction; 180 sprays every way"),
            num("speed", 0.45, 0, 20, unit: "frame heights per second", "Launch speed"),
            num("speed_random", 0.4, 0, 1, "Random variation of speed"),
            num("gravity", 0.35, -20, 20, unit: "frame heights per second²", "Downward pull; negative rises"),
            num("wind", 0, -20, 20, unit: "frame heights per second²", "Sideways push, positive to the right"),
            num("drag", 0, 0, 20, unit: "per second", "Air resistance that slows particles"),
            num("turbulence", 0, 0, 2, unit: "of frame height", "Smooth random wandering"),
            len("size", 0.012, 1, "Particle size"),
            num("size_random", 0.5, 0, 1, "Random variation of size"),
            num("size_end", 1, 0, 10, "Size at the end of life relative to the start"),
            color("color", "#FFFFFF", "Color at birth"),
            text("color_end", "", "Color at the end of life (hex); empty keeps color"),
            text("palette", "", "Comma-separated colors each particle picks from, e.g. \"#FF375F,#FFD60A,#30D158\"; confetti has a festive default"),
            num("fade_in", 0.05, 0, 1, animatable: false, "Fraction of life spent fading in"),
            num("fade_out", 0.35, 0, 1, animatable: false, "Fraction of life spent fading out"),
            num("spin", 90, 0, 3600, unit: "degrees per second", "Random spin of sprites, either way"),
            ParamSpec("sprite", .choice(["dot", "soft", "spark", "confetti", "snow", "star", "bubble", "image"]), .string("soft"), "dot: crisp disc; soft: glowing dot; spark: streak along the motion; confetti: tumbling paper; snow: soft flake drifting; star; bubble: ring with a highlight; image: the image file"),
            text("image", "", "Image file used when sprite is image"),
            num("prewarm", 0, 0, 60, unit: "seconds", animatable: false, "Start as if the emitter had already run this long (fills the frame with snow from the first frame)"),
            num("seed", 1, 0, 1_000_000, animatable: false, "Random seed; preview and export always match"),
        ]),
        EffectType(id: "camera", category: "generator", summary: "3D camera: while this clip plays, layers with transform.3d true are seen through it (transform.z, rotate_x/y, rotation); orbit, dolly (distance), zoom and focus animate. Draws nothing itself", params: [
            num("target_x", 0, -10, 10, unit: "of frame width", "Point of interest, horizontal offset from the frame center (pans the camera with it)"),
            num("target_y", 0, -10, 10, unit: "of frame height", "Point of interest, vertical offset from the center; positive is lower"),
            num("target_z", 0, -100, 100, unit: "frame heights", "Point of interest depth; positive is farther away"),
            num("orbit", 0, -36000, 36000, unit: "degrees", "Swings the camera around the target; positive moves it to the right"),
            num("tilt", 0, -89, 89, unit: "degrees", "Raises the camera around the target to look down; negative looks up"),
            num("roll", 0, -36000, 36000, unit: "degrees", "Rolls the picture clockwise"),
            num("distance", 0, 0, 200, unit: "frame heights", "Camera distance from the target (dolly); 0 is the distance at which the target plane appears at its 2D size"),
            num("fov", 40, 5, 150, unit: "degrees", "Vertical field of view; with distance 0 the target plane keeps its size (a dolly zoom)"),
            num("zoom", 1, 0.05, 50, "Lens magnification"),
            num("focus_distance", 0, 0, 200, unit: "frame heights", "Depth of field: distance in focus from the camera; 0 focuses on the target"),
            num("blur", 0, 0, 0.2, unit: "of frame height", "Depth of field strength: blur radius of layers far out of focus; 0 turns it off"),
        ]),
    ] + titles

    static let titles: [EffectType] = [
        EffectType(id: "title.lower_third_modern", category: "generator", summary: "Lower third: an accent bar springs up, the name slides out from behind it, the role follows in spaced capitals", params: [
            text("title", "Ada Lovelace", "Name"),
            text("subtitle", "Mathematician", "Role or description; empty for none"),
            color("accent", "#FFC531", "Bar color"),
            color("text_color", "#FFFFFF", "Text color"),
            pos("x", 0.07, "Left edge"),
            pos("y", 0.8, "Vertical center"),
            len("size", 0.05, 0.3, "Name font size"),
            font,
        ] + timing),
        EffectType(id: "title.lower_third_box", category: "generator", summary: "Lower third: news-style stacked boxes, the name on an accent box and the role on a dark box, wiping on one after the other", params: [
            text("title", "Ada Lovelace", "Name"),
            text("subtitle", "Mathematician · London", "Role; empty for none"),
            color("accent", "#E5322D", "Name box color"),
            color("panel", "#141416", "Role box color"),
            color("text_color", "#FFFFFF", "Text color"),
            pos("x", 0.07, "Left edge"),
            pos("y", 0.8, "Vertical center"),
            len("size", 0.046, 0.3, "Name font size"),
            font,
        ] + timing),
        EffectType(id: "title.lower_third_pill", category: "generator", summary: "Lower third: a round badge with initials pops in, its ring draws on, then a frosted pill unrolls with the name and handle", params: [
            text("title", "Ada Lovelace", "Name"),
            text("subtitle", "@ada", "Handle or role; empty for none"),
            text("badge", "", "Badge text; empty uses the name's initials"),
            color("accent", "#6E8BFF", "Badge and ring color"),
            color("panel", "#16161ACC", "Pill color; keep some transparency"),
            color("text_color", "#FFFFFF", "Text color"),
            pos("x", 0.06, "Left edge"),
            pos("y", 0.82, "Vertical center"),
            len("size", 0.042, 0.3, "Name font size"),
            font,
        ] + timing),
        EffectType(id: "title.lower_third_line", category: "generator", summary: "Lower third: a fine rule draws across, the name rises above it and the role drops below; quiet documentary style", params: [
            text("title", "Ada Lovelace", "Name"),
            text("subtitle", "Mathematician", "Role; empty for none"),
            color("accent", "#FFFFFF", "Rule color"),
            color("text_color", "#FFFFFF", "Text color"),
            ParamSpec("align", .choice(["left", "center"]), .string("left"), "left: from x; center: centered on x"),
            pos("x", 0.07, "Left edge, or center with align center"),
            pos("y", 0.8, "Height of the rule"),
            len("size", 0.048, 0.3, "Name font size"),
            font,
        ] + timing),
        EffectType(id: "title.card", category: "generator", summary: "Title card: a spaced kicker, a big title rising out of a mask, an accent rule growing from the center and a subtitle; optional full-frame background", params: [
            text("kicker", "CHAPTER ONE", "Small line above the title; empty for none"),
            text("title", "The Analytical Engine", "Title"),
            text("subtitle", "London, 1843", "Line under the rule; empty for none"),
            color("accent", "#FFC531", "Rule and kicker color"),
            color("text_color", "#FFFFFF", "Title color"),
            color("background", "#00000000", "Full-frame background; transparent to lay the card over video"),
            pos("x", 0.5, "Horizontal center"),
            pos("y", 0.5, "Vertical center"),
            len("size", 0.1, 0.5, "Title font size"),
            font,
        ] + timing),
        EffectType(id: "title.quote", category: "generator", summary: "Quote card: a large quotation mark scales in, the quote reveals line by line, the attribution follows a short rule", params: [
            text("quote", "The Analytical Engine weaves algebraic patterns just as the Jacquard loom weaves flowers and leaves.", "Quote text; wraps to width"),
            text("author", "Ada Lovelace", "Attribution; empty for none"),
            color("accent", "#FFC531", "Quotation mark and rule color"),
            color("text_color", "#FFFFFF", "Text color"),
            color("background", "#00000000", "Full-frame background; transparent over video"),
            pos("x", 0.5, "Horizontal center"),
            pos("y", 0.5, "Vertical center"),
            ParamSpec("width", .number, .number(0.66), min: 0.1, max: 1, unit: "of frame width", "Wrap width"),
            len("size", 0.056, 0.3, "Quote font size"),
            ParamSpec("font", .text, .string("serif"), "\"system\", \"rounded\", \"serif\", \"mono\" or a font family name"),
        ] + timing),
        EffectType(id: "title.end_card", category: "generator", summary: "End card: title and line, outlined slots for end-screen videos that draw on, and a button that pops in", params: [
            text("title", "Thanks for watching", "Title"),
            text("subtitle", "New videos every week", "Line under the title; empty for none"),
            text("button", "Subscribe", "Button text; empty for none"),
            num("slots", 2, 0, 2, animatable: false, "Outlined 16:9 placeholders for end-screen videos"),
            color("accent", "#FF3B30", "Button color"),
            color("text_color", "#FFFFFF", "Text and outline color"),
            color("background", "#0E0E12", "Full-frame background; transparent over video"),
            len("size", 0.075, 0.3, "Title font size"),
            font,
        ] + timing),
        EffectType(id: "title.data_callout", category: "generator", summary: "Data callout: a number counts up inside a ring (or over a bar) that fills to its share, with a label", params: [
            num("value", 87, -1e12, 1e12, "Number counted to"),
            num("from", 0, -1e12, 1e12, "Number counted from"),
            num("decimals", 0, 0, 6, animatable: false, "Digits after the decimal point"),
            text("prefix", "", "Before the number, e.g. \"$\""),
            text("suffix", "%", "After the number"),
            text("label", "of viewers watch to the end", "Line under the number; empty for none"),
            ParamSpec("style", .choice(["ring", "bar", "plain"]), .string("ring"), "ring: circular gauge around the number; bar: horizontal gauge under it; plain: number and label only"),
            num("fill", 0.87, 0, 1, "Share of the ring or bar filled"),
            color("accent", "#30D158", "Gauge color"),
            color("track", "#FFFFFF2E", "Unfilled part of the gauge"),
            color("text_color", "#FFFFFF", "Text color"),
            pos("x", 0.5, "Horizontal center"),
            pos("y", 0.48, "Vertical center"),
            len("size", 0.14, 0.6, "Number font size"),
            num("count", 1.4, 0, 30, unit: "seconds", animatable: false, "How long the number counts and the gauge fills, from the build-on"),
            font,
        ] + timing),
    ]

    /// Generators whose look depends on the clip's own time, not only on parameter values.
    public static func isTimed(_ type: String) -> Bool { type == "particles" || type.hasPrefix("title.") }

    /// The spec of a parameter of a generator effect, including shape properties named "<shape id>.<property>".
    public static func spec(type: String, name: String, params: [String: ParamValue]) -> ParamSpec? {
        guard let t = GeneratorCatalog.type(type) else { return nil }
        if let s = t.spec(name) { return s }
        guard type == "shape", name.contains(".") else { return nil }
        let json = params["shapes"]?.string ?? t.spec("shapes")?.defaultValue.string ?? ""
        return ShapeLayers.spec(name, shapes: json)
    }
}
