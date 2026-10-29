import Foundation

/// Every effect the engine can render, with its parameters.
///
/// Units: lengths are fractions of the frame height (0.01 is 1% of the height),
/// positions are fractions of the clip's frame with the origin at the top left,
/// angles are degrees clockwise.
public enum EffectCatalog {
    public static func type(_ id: String) -> EffectType? { byId[id] }

    public static let categories: [(String, String)] = [
        ("blur", "Blurs and focus"),
        ("color", "Color correction and looks"),
        ("stylize", "Glow, grain, vignette, shadows and other looks"),
        ("distort", "Warps and lens effects"),
        ("mask", "Limit the clip to a shape; feather, invert, animate"),
        ("audio", "Sound processing on tracks (and the master bus): EQ, dynamics, voice cleanup, space, character"),
    ]

    public static func isAudio(_ type: String) -> Bool { type.hasPrefix("audio.") }

    static func db(_ name: String, _ d: Double, _ lo: Double, _ hi: Double, _ summary: String) -> ParamSpec {
        ParamSpec(name, .number, .number(d), min: lo, max: hi, unit: "dB", animatable: false, summary)
    }

    static func num(_ name: String, _ d: Double, _ lo: Double, _ hi: Double, _ unit: String, _ summary: String) -> ParamSpec {
        ParamSpec(name, .number, .number(d), min: lo, max: hi, unit: unit, animatable: false, summary)
    }

    static let center: [ParamSpec] = [
        ParamSpec("center_x", .number, .number(0.5), min: 0, max: 1, "Horizontal center, 0 left to 1 right"),
        ParamSpec("center_y", .number, .number(0.5), min: 0, max: 1, "Vertical center, 0 top to 1 bottom"),
    ]

    static let shape: [ParamSpec] = center + [
        ParamSpec("width", .number, .number(0.5), min: 0, max: 2, "Width as a fraction of the clip's width"),
        ParamSpec("height", .number, .number(0.5), min: 0, max: 2, "Height as a fraction of the clip's height"),
        ParamSpec("feather", .number, .number(0), min: 0, max: 0.3, unit: "of frame height", "Soft edge width"),
        ParamSpec("invert", .bool, .bool(false), "Keep the outside instead of the inside"),
    ]

    public static let all: [EffectType] = [
        EffectType(id: "blur.gaussian", category: "blur", summary: "Even soft blur", params: [
            ParamSpec("radius", .number, .number(0.01), min: 0, max: 0.2, unit: "of frame height", "Blur radius"),
        ]),
        EffectType(id: "blur.motion", category: "blur", summary: "Directional streak blur, as from fast movement", params: [
            ParamSpec("amount", .number, .number(0.03), min: 0, max: 0.3, unit: "of frame height", "Streak length"),
            ParamSpec("angle", .number, .number(0), min: -360, max: 360, unit: "degrees", "Direction; 0 is horizontal"),
        ]),
        EffectType(id: "blur.zoom", category: "blur", summary: "Radial blur from a point, as from a fast zoom", params: [
            ParamSpec("amount", .number, .number(0.05), min: 0, max: 0.5, unit: "of frame height", "Streak length"),
        ] + center),
        EffectType(id: "blur.sharpen", category: "blur", summary: "Unsharp mask to add crispness", params: [
            ParamSpec("amount", .number, .number(0.6), min: 0, max: 4, "Strength"),
            ParamSpec("radius", .number, .number(0.002), min: 0, max: 0.02, unit: "of frame height", "Detail size"),
        ]),
        EffectType(id: "color.adjust", category: "color", summary: "Primary correction: exposure, contrast, saturation, white balance", params: [
            ParamSpec("exposure", .number, .number(0), min: -4, max: 4, unit: "stops", "Brightness in photographic stops"),
            ParamSpec("contrast", .number, .number(0), min: -1, max: 1, "0 unchanged; negative flattens, positive punches"),
            ParamSpec("saturation", .number, .number(0), min: -1, max: 1, "-1 black and white, 0 unchanged, 1 doubled"),
            ParamSpec("vibrance", .number, .number(0), min: -1, max: 1, "Saturation that spares skin and already-vivid colors"),
            ParamSpec("brightness", .number, .number(0), min: -1, max: 1, "Linear lift of all tones"),
            ParamSpec("gamma", .number, .number(1), min: 0.25, max: 4, "Midtones; below 1 brightens, above 1 darkens"),
            ParamSpec("temperature", .number, .number(0), min: -100, max: 100, "Negative cooler (blue), positive warmer (orange)"),
            ParamSpec("tint", .number, .number(0), min: -100, max: 100, "Negative green, positive magenta"),
        ]),
        EffectType(id: "color.monochrome", category: "color", summary: "Black and white, or a single-color tint", params: [
            ParamSpec("color", .color, .string("#FFFFFF"), "Tint color; white gives neutral black and white"),
            ParamSpec("amount", .number, .number(1), min: 0, max: 1, "Strength"),
        ]),
        EffectType(id: "color.invert", category: "color", summary: "Negative image", params: []),
        EffectType(id: "stylize.glow", category: "stylize", summary: "Bloom that makes highlights glow", params: [
            ParamSpec("amount", .number, .number(0.6), min: 0, max: 2, "Strength"),
            ParamSpec("radius", .number, .number(0.02), min: 0, max: 0.2, unit: "of frame height", "Spread"),
        ]),
        EffectType(id: "stylize.vignette", category: "stylize", summary: "Darkened edges that draw the eye to the center", params: [
            ParamSpec("amount", .number, .number(0.6), min: 0, max: 2, "Darkness of the edges"),
            ParamSpec("size", .number, .number(0.8), min: 0.05, max: 1.5, "Clear area; 1 reaches the corners"),
            ParamSpec("softness", .number, .number(0.6), min: 0, max: 1, "How gradually the edges darken"),
        ] + center),
        EffectType(id: "stylize.grain", category: "stylize", summary: "Film grain that changes every frame", params: [
            ParamSpec("amount", .number, .number(0.15), min: 0, max: 1, "Visibility"),
            ParamSpec("size", .number, .number(1), min: 0.5, max: 4, "Grain size"),
            ParamSpec("mono", .bool, .bool(true), "Gray grain instead of colored"),
        ]),
        EffectType(id: "stylize.pixelate", category: "stylize", summary: "Blocky pixels, for censoring or a retro look", params: [
            ParamSpec("size", .number, .number(0.03), min: 0.002, max: 0.2, unit: "of frame height", "Block size"),
        ]),
        EffectType(id: "stylize.posterize", category: "stylize", summary: "Reduces the number of color levels", params: [
            ParamSpec("levels", .number, .number(6), min: 2, max: 30, "Levels per channel"),
        ]),
        EffectType(id: "stylize.drop_shadow", category: "stylize", summary: "Soft shadow behind the clip's shape; use with masks, text and picture-in-picture", params: [
            ParamSpec("color", .color, .string("#000000"), "Shadow color"),
            ParamSpec("opacity", .number, .number(0.5), min: 0, max: 1, "Shadow strength"),
            ParamSpec("radius", .number, .number(0.02), min: 0, max: 0.1, unit: "of frame height", "Softness"),
            ParamSpec("x", .number, .number(0), min: -0.2, max: 0.2, unit: "of frame height", "Offset right"),
            ParamSpec("y", .number, .number(0.01), min: -0.2, max: 0.2, unit: "of frame height", "Offset down"),
        ]),
        EffectType(id: "stylize.border", category: "stylize", summary: "Solid outline around the clip's shape", params: [
            ParamSpec("color", .color, .string("#FFFFFF"), "Line color"),
            ParamSpec("width", .number, .number(0.005), min: 0, max: 0.05, unit: "of frame height", "Line width"),
        ]),
        EffectType(id: "distort.bulge", category: "distort", summary: "Bulges outward (positive) or pinches inward (negative)", params: [
            ParamSpec("amount", .number, .number(0.5), min: -1, max: 1, "Strength and direction"),
            ParamSpec("radius", .number, .number(0.3), min: 0, max: 1.5, "Size as a fraction of the frame height"),
        ] + center),
        EffectType(id: "distort.twirl", category: "distort", summary: "Swirls the image around a point", params: [
            ParamSpec("angle", .number, .number(180), min: -1440, max: 1440, unit: "degrees", "Rotation at the center"),
            ParamSpec("radius", .number, .number(0.4), min: 0, max: 1.5, "Size as a fraction of the frame height"),
        ] + center),
        EffectType(id: "mask.rect", category: "mask", summary: "Keeps a rectangle, optionally rounded; e.g. rounded picture-in-picture or a letterbox", params: shape + [
            ParamSpec("roundness", .number, .number(0), min: 0, max: 0.5, "Corner radius as a fraction of the shorter side"),
        ]),
        EffectType(id: "mask.ellipse", category: "mask", summary: "Keeps an ellipse; e.g. a spotlight or a circular face cam", params: shape),
        EffectType(id: "audio.eq", category: "audio", summary: "Equalizer: low cut, low shelf, mid bell, high shelf, high cut", params: [
            num("highpass_hz", 0, 0, 2000, "Hz", "Remove rumble below this frequency; 0 off. 80 is typical for voice"),
            num("lowpass_hz", 0, 0, 22000, "Hz", "Remove hiss above this frequency; 0 off"),
            num("low_hz", 120, 20, 1000, "Hz", "Low shelf corner"),
            db("low_gain", 0, -24, 24, "Low shelf boost or cut"),
            num("mid_hz", 1000, 100, 12000, "Hz", "Mid bell center"),
            db("mid_gain", 0, -24, 24, "Mid bell boost or cut; +3 at 3000 Hz adds presence to voice"),
            num("mid_width", 1, 0.1, 5, "octaves", "Mid bell width"),
            num("high_hz", 8000, 1000, 20000, "Hz", "High shelf corner"),
            db("high_gain", 0, -24, 24, "High shelf boost or cut; + adds air, - softens sibilance"),
        ]),
        EffectType(id: "audio.compressor", category: "audio", summary: "Evens out loud and quiet moments; makes voices sit forward", params: [
            db("threshold", -20, -60, 0, "Level where compression starts"),
            db("headroom", 5, 0.1, 40, "Smaller compresses harder"),
            num("attack_ms", 10, 1, 300, "ms", "How fast it reacts"),
            num("release_ms", 150, 10, 3000, "ms", "How fast it lets go"),
            db("makeup", 0, -20, 40, "Gain after compression"),
        ]),
        EffectType(id: "audio.gate", category: "audio", summary: "Quiets the track below a level; removes room noise between words", params: [
            db("threshold", -45, -120, 0, "Level below which sound is reduced"),
            num("ratio", 4, 1, 50, "", "How strongly quiet parts are reduced"),
        ]),
        EffectType(id: "audio.limiter", category: "audio", summary: "Stops peaks from going over a ceiling; use last in a chain", params: [
            db("ceiling", -1, -20, 0, "Maximum peak level"),
            db("input_gain", 0, -20, 20, "Gain before limiting; more makes it louder and denser"),
            num("release_ms", 10, 1, 40, "ms", "How fast gain recovers"),
        ]),
        EffectType(id: "audio.voice_isolation", category: "audio", summary: "Apple's on-device voice isolation; removes background noise, music and room sound from speech", params: [
            num("amount", 1, 0, 1, "", "1 fully isolated voice, 0 original"),
        ]),
        EffectType(id: "audio.reverb", category: "audio", summary: "Adds a room or hall around the sound", params: [
            ParamSpec("space", .choice(["small_room", "medium_room", "large_room", "medium_hall", "large_hall", "plate", "cathedral"]), .string("medium_room"), "Type of space"),
            num("wet", 0.2, 0, 1, "", "How much reverb"),
        ]),
        EffectType(id: "audio.delay", category: "audio", summary: "Echo", params: [
            num("time_ms", 250, 1, 2000, "ms", "Echo spacing"),
            num("feedback", 0.3, 0, 0.95, "", "How many repeats"),
            num("wet", 0.25, 0, 1, "", "Echo level"),
        ]),
        EffectType(id: "audio.character", category: "audio", summary: "Characterful distortion: radio, phone, broken speaker, lo-fi, alien", params: [
            ParamSpec("style", .choice(["radio", "phone", "broken_speaker", "lofi", "alien"]), .string("radio"), "Sound"),
            num("wet", 1, 0, 1, "", "How much of the effect"),
        ]),
        EffectType(id: "audio.pitch", category: "audio", summary: "Shifts pitch without changing speed", params: [
            num("semitones", 0, -24, 24, "semitones", "Pitch change"),
        ]),
    ]

    static let byId: [String: EffectType] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    /// The base for effect ids: "blur.gaussian" → "blur", "stylize.drop_shadow" → "shadow".
    public static func shortName(_ type: String) -> String {
        let overrides = ["blur.gaussian": "blur", "color.adjust": "grade", "color.monochrome": "mono"]
        if let o = overrides[type] { return o }
        let last = type.split(separator: ".").last.map(String.init) ?? type
        return last.split(separator: "_").last.map(String.init) ?? last
    }

    /// A readable name for history labels: "blur.gaussian" → "blur", "stylize.drop_shadow" → "drop shadow".
    public static func title(_ type: String) -> String {
        let titles = [
            "blur.gaussian": "blur", "blur.motion": "motion blur", "blur.zoom": "zoom blur", "blur.sharpen": "sharpening",
            "color.adjust": "color correction", "color.monochrome": "black and white", "color.invert": "invert",
            "stylize.drop_shadow": "drop shadow", "mask.rect": "rectangle mask", "mask.ellipse": "ellipse mask",
            "distort.bulge": "bulge", "distort.twirl": "twirl",
        ]
        return titles[type] ?? shortName(type)
    }
}
