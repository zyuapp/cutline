import Foundation

/// Every effect the engine can render, with its parameters.
///
/// Units: lengths are fractions of the frame height (0.01 is 1% of the height),
/// positions are fractions of the clip's frame with the origin at the top left,
/// angles are degrees clockwise.
public enum EffectCatalog {
    public static func type(_ id: String) -> EffectType? { limited[id] ?? byId[id] ?? ProAudioCatalog.type(id) ?? GeneratorCatalog.type(id) ?? PluginRegistry.type(id) }

    /// Secondary correction: any picture effect can be limited to a window (rectangle or ellipse), to
    /// pixels matching a hue/saturation/luma qualifier, or to qualified pixels inside a window,
    /// like power windows and qualifiers in a grading suite.
    public static let limitSpecs: [ParamSpec] = [
        ParamSpec("limit", .choice(["none", "rect", "ellipse", "qualifier", "rect+qualifier", "ellipse+qualifier"]), .string("none"), "Apply only inside a window, to qualified colors, or to qualified colors inside a window (ellipse+qualifier: skin on one face)"),
        ParamSpec("limit_x", .number, .number(0.5), min: -1, max: 2, "Window center in the clip's own picture, 0 left to 1 right. Follow a face or object with param_set bind {\"fx.<id>.limit_x\": {\"source\": \"face:<media>[:n].x\"}} (or \"track:<id>.x\" from media_track); same for limit_y with .y"),
        ParamSpec("limit_y", .number, .number(0.5), min: -1, max: 2, "Window center, 0 top to 1 bottom; bind like limit_x"),
        ParamSpec("limit_width", .number, .number(0.5), min: 0, max: 3, "Window width, fraction of the frame"),
        ParamSpec("limit_height", .number, .number(0.5), min: 0, max: 3, "Window height; bind to face:<media>.size or track:<id>.height to follow the subject's size"),
        ParamSpec("limit_roundness", .number, .number(0), min: 0, max: 0.5, "Rounded rectangle corners"),
        ParamSpec("limit_feather", .number, .number(0.05), min: 0, max: 0.5, unit: "of frame height", "Soft edge of the window"),
        ParamSpec("limit_invert", .bool, .bool(false), "Apply outside the window, to everything but the qualified colors, or outside their intersection"),
        ParamSpec("q_preset", .choice(["none", "skin"]), .string("none"), "Starting ranges: skin covers red-orange hues of moderate saturation (any complexion) with matte cleanup; q_* parameters you set refine it. Pair with an ellipse window (ellipse+qualifier) or bind the window to a face for one person's skin. recipe qualify samples ranges from the picture instead"),
        ParamSpec("q_hue", .number, .number(30), min: 0, max: 360, unit: "degrees", animatable: false, "Qualifier hue center, HSV hue of the display picture (0 red, 13 skin, 30 orange, 60 yellow, 120 green, 210 sky blue, 240 blue)"),
        ParamSpec("q_hue_width", .number, .number(40), min: 1, max: 360, unit: "degrees", animatable: false, "Full-strength hue range around the center; 360 ignores hue"),
        ParamSpec("q_hue_soft", .number, .number(10), min: 0, max: 90, unit: "degrees", animatable: false, "Hue falloff beyond the range"),
        ParamSpec("q_sat_min", .number, .number(0.1), min: 0, max: 1, animatable: false, "Low end of the saturation range (HSV saturation; near-black pixels count as unsaturated)"),
        ParamSpec("q_sat_max", .number, .number(1), min: 0, max: 1, animatable: false, "High end of the saturation range"),
        ParamSpec("q_sat_soft", .number, .number(0.05), min: 0, max: 0.5, animatable: false, "Saturation falloff beyond the range"),
        ParamSpec("q_luma_min", .number, .number(0), min: 0, max: 1, animatable: false, "Low end of the luma range (Rec. 709 luma of the display picture)"),
        ParamSpec("q_luma_max", .number, .number(1), min: 0, max: 1, animatable: false, "High end of the luma range"),
        ParamSpec("q_luma_soft", .number, .number(0.05), min: 0, max: 0.5, animatable: false, "Luma falloff beyond the range"),
        ParamSpec("q_softness", .number, .number(0.15), min: 0, max: 1, animatable: false, "Sets hue (×90°), saturation and luma softness at once when they are not set themselves"),
        ParamSpec("q_clean_black", .number, .number(0), min: 0, max: 0.49, animatable: false, "Matte cleanup: key values up to this become black, removing faint noise in the background"),
        ParamSpec("q_clean_white", .number, .number(0), min: 0, max: 0.49, animatable: false, "Matte cleanup: key values above 1 minus this become white, filling a patchy subject"),
        ParamSpec("q_denoise", .number, .number(0.0015), min: 0, max: 0.02, unit: "of frame height", animatable: false, "Matte cleanup: removes specks and fills pinholes smaller than this (morphological open, then close)"),
        ParamSpec("q_blur", .number, .number(0.002), min: 0, max: 0.05, unit: "of frame height", animatable: false, "Matte softness: blurs the key's edge"),
    ]

    /// Grade nodes (see `EffectNodes`): group effects into nodes and mix them in parallel or as layers.
    public static let nodeSpecs: [ParamSpec] = [
        ParamSpec("node", .text, .string(""), "Node label: consecutive effects with the same label form one node (several tools in one grade node); empty makes the effect its own node"),
        ParamSpec("node_mode", .choice(EffectNodes.Mode.allCases.map(\.rawValue)), .string("serial"), "serial: after the node before. parallel: consecutive parallel nodes all start from the same input and their changes add up (mark every branch). layer: consecutive layer nodes start from the same input and are composited in order (later on top) with node_blend and node_opacity, inside their key. outside: applies where the previous node's key (limit) is not, e.g. grade the background around a qualified face"),
        ParamSpec("node_blend", .choice(BlendMode.allCases.map(\.rawValue)), .string("normal"), "Layer nodes: how the layer combines with the layers under it"),
        ParamSpec("node_opacity", .number, .number(1), min: 0, max: 1, "Strength of the whole node: fades its result into its input (for layers, the layer's opacity)"),
    ]

    static let limited: [String: EffectType] = Dictionary(uniqueKeysWithValues: all.filter { ["blur", "color", "stylize", "distort"].contains($0.category) && $0.id != "distort.stabilize" && $0.id != "distort.corner_pin" }.map { t in
        let nodal = !["stylize.drop_shadow", "stylize.border"].contains(t.id)
        return (t.id, EffectType(id: t.id, category: t.category, summary: t.summary, params: t.params + limitSpecs + (nodal ? nodeSpecs : [])))
    })

    public static let categories: [(String, String)] = [
        ("blur", "Blurs and focus"),
        ("color", "Color correction and looks"),
        ("stylize", "Glow, grain, vignette, shadows and other looks"),
        ("distort", "Warps and lens effects"),
        ("mask", "Limit the clip to a shape; feather, invert, animate"),
        ("video", "Finishing that reads neighbouring frames: temporal noise reduction and object removal, rendered in the background as a processed copy of the clip's picture"),
        ("audio", "Sound processing on clips, tracks and the master bus: EQ, dynamics, repair (noise, hum, sibilance, clicks), voice cleanup, stereo, space, character"),
    ]

    /// Every built-in effect type an agent can add: the picture and audio effects plus the restoration effects.
    public static var listed: [EffectType] { all + ProAudioCatalog.all }

    public static func isAudio(_ type: String) -> Bool { type.hasPrefix("audio.") || ProAudioCatalog.isPlugin(type) }

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

    /// A tracked object's box over source time, for effects that follow one object.
    static let trackedBoxSpecs: [ParamSpec] = [
        ParamSpec("track", .text, .string(""), animatable: false, "media_track id (trk1 or track:trk1); effect_add copies its boxes into boxes"),
        ParamSpec("boxes", .text, .string(""), animatable: false, "The object's box over source time: \"t x y w h\" groups separated by \";\" (source seconds; frame fractions from the top left), as filled from track"),
    ]

    /// Effects that read neighbouring frames, rendered ahead of playback as a processed copy of the clip's picture.
    public static func isTemporal(_ type: String) -> Bool { type.hasPrefix("video.") }

    /// Hardening for segmentation mattes, whose raw values are often partly transparent inside the subject.
    static let matteSpecs: [ParamSpec] = [
        ParamSpec("threshold", .number, .number(0.5), min: 0, max: 0.95, "Matte level that becomes the edge: values above are fully opaque, below fully transparent; 0 keeps the raw soft matte"),
        ParamSpec("choke", .number, .number(0), min: 0, max: 0.03, unit: "of frame height", "Pulls the hardened edge inward to drop background fringe"),
    ]

    static let wheelSpecs: [ParamSpec] = {
        let wheels: [(String, Double, Double, String)] = [
            ("lift", -0.5, 0.5, "Blacks: moves black up (positive) or down while white stays put"),
            ("gamma", -1, 1, "Midtones: positive brightens, negative darkens; ends stay put"),
            ("gain", -0.9, 3, "Whites: scales white (0.1 is 10% brighter) while black stays put"),
            ("offset", -0.5, 0.5, "Shifts every tone up or down"),
        ]
        var specs: [ParamSpec] = []
        for (name, lo, hi, summary) in wheels {
            specs.append(ParamSpec(name, .number, .number(0), min: lo, max: hi, "\(summary); master for all channels"))
            for (ch, color) in [("r", "red"), ("g", "green"), ("b", "blue")] {
                specs.append(ParamSpec("\(name)_\(ch)", .number, .number(0), min: lo, max: hi, "Added to \(name) for \(color) only, e.g. \(name)_\(ch) 0.03 pushes \(name == "offset" ? "everything" : name == "lift" ? "the blacks" : name == "gamma" ? "the midtones" : "the whites") toward \(color)"))
            }
        }
        return specs + [
            ParamSpec("temperature", .number, .number(0), min: -100, max: 100, "White balance: negative cooler (blue), positive warmer (orange)"),
            ParamSpec("tint", .number, .number(0), min: -100, max: 100, "Negative green, positive magenta"),
            ParamSpec("contrast", .number, .number(0), min: -1, max: 2, "Stretches tones away from the pivot (0.2 is 20% more contrast); negative flattens"),
            ParamSpec("pivot", .number, .number(0.5), min: 0.05, max: 0.95, "Tone that contrast leaves unchanged; lower keeps shadows, higher keeps highlights"),
            ParamSpec("shadows", .number, .number(0), min: -1, max: 1, "Shadow recovery: positive opens up dark areas, negative deepens them"),
            ParamSpec("highlights", .number, .number(0), min: -1, max: 1, "Highlight recovery: negative pulls bright areas down, positive brightens them"),
            ParamSpec("saturation", .number, .number(0), min: -1, max: 1, "-1 black and white, 0 unchanged, 1 doubled"),
        ]
    }()

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
        EffectType(id: "color.grade", category: "color", summary: "Color wheels: lift, gamma and gain for blacks, midtones and whites, plus split-toning tints per tonal range", params: [
            ParamSpec("lift", .number, .number(0), min: -0.5, max: 0.5, "Raises (positive) or crushes (negative) the blacks"),
            ParamSpec("gamma", .number, .number(1), min: 0.2, max: 5, "Midtones; above 1 brightens, below 1 darkens"),
            ParamSpec("gain", .number, .number(1), min: 0, max: 4, "Scales the whites"),
            ParamSpec("shadows", .color, .string("#000000"), "Tint pushed into the shadows, e.g. teal #2A7B8C"),
            ParamSpec("shadows_amount", .number, .number(0), min: 0, max: 1, "Strength of the shadow tint"),
            ParamSpec("midtones", .color, .string("#000000"), "Tint pushed into the midtones"),
            ParamSpec("midtones_amount", .number, .number(0), min: 0, max: 1, "Strength of the midtone tint"),
            ParamSpec("highlights", .color, .string("#000000"), "Tint pushed into the highlights, e.g. warm #FFB070"),
            ParamSpec("highlights_amount", .number, .number(0), min: 0, max: 1, "Strength of the highlight tint"),
        ]),
        EffectType(id: "color.wheels", category: "color", summary: "Full primary grade like Resolve's wheels: lift/gamma/gain/offset with per-channel RGB balance, white balance, contrast with pivot, shadows/highlights recovery and saturation. Every parameter is 0 when neutral; a wheel's color is its master plus _r/_g/_b, e.g. lift_b 0.03 lift_r -0.02 cools the blacks, gain_r 0.05 warms the whites. Order: white balance, offset, lift/gamma/gain, contrast, shadows/highlights, saturation", params: wheelSpecs),
        EffectType(id: "color.curves", category: "color", summary: "Tone curves for all channels and red, green, blue; points are \"x,y\" pairs 0…1 separated by spaces", params: [
            ParamSpec("master", .text, .string(""), "All channels, e.g. \"0,0 0.25,0.2 0.75,0.82 1,1\" for an S-curve"),
            ParamSpec("red", .text, .string(""), "Red channel curve"),
            ParamSpec("green", .text, .string(""), "Green channel curve"),
            ParamSpec("blue", .text, .string(""), "Blue channel curve, e.g. \"0,0.06 1,0.94\" lifts blue shadows"),
        ]),
        EffectType(id: "color.hsl", category: "color", summary: "Shift the hue, saturation or lightness of one color range, such as making skies deeper or greens warmer; stack one per range", params: [
            ParamSpec("range", .choice(["reds", "oranges", "yellows", "greens", "aquas", "blues", "purples", "magentas"]), .string("blues"), "Which colors to change"),
            ParamSpec("hue", .number, .number(0), min: -180, max: 180, unit: "degrees", "Hue rotation"),
            ParamSpec("saturation", .number, .number(0), min: -1, max: 1, "-1 removes the color, 1 doubles it"),
            ParamSpec("lightness", .number, .number(0), min: -1, max: 1, "Darker or lighter"),
        ]),
        EffectType(id: "color.hue_curves", category: "color", summary: "Secondary curves like Resolve's: hue vs hue, hue vs saturation, hue vs luminance, luminance vs saturation and saturation vs saturation. Each is a point list \"x,y x,y\"; hue x is degrees (0 red, 30 orange, 60 yellow, 120 green, 180 aqua, 225 blue, 270 purple, 315 magenta) and wraps at 360, joined by a smooth periodic spline that never overshoots; one point alone is a bump that fades to neutral 60° either side. Grays are untouched, and saturation and luminance changes keep hue. Examples: greens less saturated hue_sat \"60,1 120,0.5 180,1\"; skin toward orange hue_hue \"0,0 20,6 45,0\"; darker deeper sky hue_lum \"225,0.8\" with hue_sat \"225,1.3\"; desaturate shadows lum_sat \"0,0.5 0.25,1 1,1\"; tame already-vivid colors sat_sat \"0,1 0.6,1 1,0.75\"", params: [
            ParamSpec("hue_hue", .text, .string(""), "Hue shift in degrees (-180…180) by input hue, e.g. \"20,6\" pushes skin (≈20°) 6° toward orange"),
            ParamSpec("hue_sat", .text, .string(""), "Saturation multiplier (0…4, 1 unchanged) by hue, e.g. \"120,0.5\" halves the greens"),
            ParamSpec("hue_lum", .text, .string(""), "Brightness multiplier (0…4, 1 unchanged) by hue, e.g. \"225,0.8\" darkens blues"),
            ParamSpec("lum_sat", .text, .string(""), "Saturation multiplier by luma 0…1, e.g. \"0,0.6 0.3,1 1,1\" pulls color out of the shadows"),
            ParamSpec("sat_sat", .text, .string(""), "Saturation multiplier by input saturation 0…1, e.g. \"0,1.3 0.4,1 1,1\" lifts muted colors only"),
        ]),
        EffectType(id: "color.hdr_zones", category: "color", summary: "HDR palette: exposure (stops) and saturation per luminance zone, like Resolve's HDR wheels. Zones are centered in cd/m² (black 0.1, dark 2, shadow 15, light 80 for skin and diffuse white, highlight 400, specular 1500) and blend with a smooth raised-cosine crossover in stops, so moving one zone never bands. Works on PQ and HLG canvases in absolute nits, and on SDR canvases with white at 100 cd/m². Examples: tame speculars specular_exposure -1; open the shadows shadow_exposure 0.5; less saturated highlights highlight_saturation -0.3. Measure with timeline_measure picture/scopes, which report nits on HDR timelines", params: HDRZones.names.flatMap { z in
            let i = HDRZones.names.firstIndex(of: z)!
            return [
                ParamSpec("\(z)_exposure", .number, .number(0), min: -4, max: 4, unit: "stops", "Exposure of the \(z) zone"),
                ParamSpec("\(z)_saturation", .number, .number(0), min: -1, max: 1, "Saturation of the \(z) zone: -1 gray, 1 double"),
                ParamSpec("\(z)_nits", .number, .number(HDRZones.defaultNits[i]), min: 0.001, max: 10_000, unit: "cd/m²", animatable: false, "Center of the \(z) zone"),
            ]
        } + [ParamSpec("softness", .number, .number(1), min: 0.1, max: 1, "Crossover width as a share of the distance between zone centers; lower confines each zone's change more tightly")]),
        EffectType(id: "color.look", category: "color", summary: "Finished creative grades: teal_orange, warm_film, cool_night, bleach_bypass, vintage_fade, high_contrast_bw, golden_hour, matrix_green, pastel, noir", params: [
            ParamSpec("look", .choice(["teal_orange", "warm_film", "cool_night", "bleach_bypass", "vintage_fade", "high_contrast_bw", "golden_hour", "matrix_green", "pastel", "noir"]), .string("teal_orange"), "Look"),
            ParamSpec("amount", .number, .number(1), min: 0, max: 1, "Strength"),
        ]),
        EffectType(id: "color.lut", category: "color", summary: "Applies a 3D LUT from a .cube file (Resolve, Premiere and camera LUTs)", params: [
            ParamSpec("file", .text, .string(""), "Absolute path to a .cube file"),
        ]),
        EffectType(id: "color.cdl", category: "color", summary: "ASC CDL primary from a colorist: slope, offset and power per channel, then saturation", params: [
            ParamSpec("slope_r", .number, .number(1), min: 0, max: 8, "Red slope (gain)"),
            ParamSpec("slope_g", .number, .number(1), min: 0, max: 8, "Green slope (gain)"),
            ParamSpec("slope_b", .number, .number(1), min: 0, max: 8, "Blue slope (gain)"),
            ParamSpec("offset_r", .number, .number(0), min: -1, max: 1, "Red offset"),
            ParamSpec("offset_g", .number, .number(0), min: -1, max: 1, "Green offset"),
            ParamSpec("offset_b", .number, .number(0), min: -1, max: 1, "Blue offset"),
            ParamSpec("power_r", .number, .number(1), min: 0.1, max: 8, "Red power (gamma)"),
            ParamSpec("power_g", .number, .number(1), min: 0.1, max: 8, "Green power (gamma)"),
            ParamSpec("power_b", .number, .number(1), min: 0.1, max: 8, "Blue power (gamma)"),
            ParamSpec("saturation", .number, .number(1), min: 0, max: 4, "1 unchanged, 0 black and white"),
        ]),
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
        EffectType(id: "stylize.glitch", category: "stylize", summary: "Digital glitch: RGB split, torn slices and blocky pixels that change every frame; animate amount for hits", params: [
            ParamSpec("amount", .number, .number(0.6), min: 0, max: 1, "Strength"),
        ]),
        EffectType(id: "distort.stabilize", category: "distort", summary: "Smooths shaky camera motion (analyzed once per clip, then cached); zooms in just enough to hide the moving edges", params: [
            ParamSpec("smoothing", .number, .number(1), min: 0.1, max: 5, unit: "seconds", animatable: false, "How long a stretch of motion is averaged; larger is steadier"),
            ParamSpec("strength", .number, .number(1), min: 0, max: 1, animatable: false, "1 removes all shake within the smoothing window"),
            ParamSpec("zoom", .number, .number(0), min: 0, max: 0.5, animatable: false, "Extra zoom; 0 picks the smallest zoom that hides the edges"),
        ]),
        EffectType(id: "distort.corner_pin", category: "distort", summary: "Moves the picture's four corners anywhere, e.g. to place a screen recording onto a phone or billboard (pair with media_track to follow it)", params: [
            ParamSpec("tl_x", .number, .number(0), min: -2, max: 3, "Top-left corner x, fraction of the clip's frame"),
            ParamSpec("tl_y", .number, .number(0), min: -2, max: 3, "Top-left corner y, 0 top"),
            ParamSpec("tr_x", .number, .number(1), min: -2, max: 3, "Top-right corner x"),
            ParamSpec("tr_y", .number, .number(0), min: -2, max: 3, "Top-right corner y"),
            ParamSpec("br_x", .number, .number(1), min: -2, max: 3, "Bottom-right corner x"),
            ParamSpec("br_y", .number, .number(1), min: -2, max: 3, "Bottom-right corner y"),
            ParamSpec("bl_x", .number, .number(0), min: -2, max: 3, "Bottom-left corner x"),
            ParamSpec("bl_y", .number, .number(1), min: -2, max: 3, "Bottom-left corner y"),
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
        EffectType(id: "mask.shape", category: "mask", summary: "Keeps a freeform shape drawn as points (a roto or pen mask); animate points to follow movement, with the same number of points in every key", params: [
            ParamSpec("points", .text, .string("0.3,0.3 0.7,0.3 0.7,0.7 0.3,0.7"), animatable: true, "Corners as \"x,y\" pairs, fractions of the clip's frame from the top left"),
            ParamSpec("smooth", .bool, .bool(false), "Curve through the points instead of straight edges"),
            ParamSpec("feather", .number, .number(0.005), min: 0, max: 0.3, unit: "of frame height", "Soft edge"),
            ParamSpec("invert", .bool, .bool(false), "Keep everything outside the shape"),
        ]),
        EffectType(id: "mask.matte", category: "mask", summary: "Track matte: shows this clip only where another track's picture is (its alpha, or its brightness), e.g. video inside text; hide the matte track", params: [
            ParamSpec("track", .text, .string(""), animatable: false, "Track id whose picture is the matte"),
            ParamSpec("mode", .choice(["alpha", "luma"]), .string("alpha"), "Use the matte's transparency or its brightness"),
            ParamSpec("invert", .bool, .bool(false), "Show the clip where the matte is not"),
        ]),
        EffectType(id: "mask.person", category: "mask", summary: "Keeps the people (Apple person segmentation); invert to keep the background, e.g. text behind a person or a background swap", params: [
            ParamSpec("quality", .choice(["fast", "balanced", "accurate"]), .string("balanced"), "Edge quality against speed"),
        ] + matteSpecs + [
            ParamSpec("feather", .number, .number(0.003), min: 0, max: 0.05, unit: "of frame height", "Soft edge"),
            ParamSpec("expand", .number, .number(0), min: -0.05, max: 0.05, unit: "of frame height", "Grow (positive) or shrink the mask"),
            ParamSpec("smoothing", .number, .number(0.4), min: 0, max: 0.95, animatable: false, "Blends each frame's mask with the last to stop flicker"),
            ParamSpec("invert", .bool, .bool(false), "Keep everything except the people"),
        ]),
        EffectType(id: "mask.subject", category: "mask", summary: "Keeps the main subjects, people, animals or objects (Apple foreground segmentation)", params: matteSpecs + [
            ParamSpec("feather", .number, .number(0.003), min: 0, max: 0.05, unit: "of frame height", "Soft edge"),
            ParamSpec("expand", .number, .number(0), min: -0.05, max: 0.05, unit: "of frame height", "Grow or shrink the mask"),
            ParamSpec("smoothing", .number, .number(0.4), min: 0, max: 0.95, animatable: false, "Temporal smoothing against flicker"),
            ParamSpec("invert", .bool, .bool(false), "Keep the background instead"),
        ]),
        EffectType(id: "mask.object", category: "mask", summary: "Automatic roto of one tracked object (a car, a product, a person): keeps the shape Apple foreground segmentation finds inside the media_track box each frame, so effects, keys and grades can isolate it; invert to keep everything else. effect_add {type: \"mask.object\", params: {track: \"trk1\"}} fills boxes from the track", params: trackedBoxSpecs + [
            ParamSpec("padding", .number, .number(0.02), min: 0, max: 0.2, unit: "of frame height", animatable: false, "Room around the tracked box the object's shape may reach into"),
            ParamSpec("fallback", .choice(["box", "none"]), .string("box"), "What to keep when no segmented object overlaps the box: the box itself or nothing"),
        ] + matteSpecs + [
            ParamSpec("feather", .number, .number(0.003), min: 0, max: 0.05, unit: "of frame height", "Soft edge"),
            ParamSpec("expand", .number, .number(0), min: -0.05, max: 0.05, unit: "of frame height", "Grow or shrink the mask"),
            ParamSpec("smoothing", .number, .number(0.3), min: 0, max: 0.95, animatable: false, "Temporal smoothing against flicker"),
            ParamSpec("invert", .bool, .bool(false), "Keep everything except the object"),
        ]),
        EffectType(id: "key.chroma", category: "mask", summary: "Green or blue screen key with spill suppression; put a background on the track below", params: [
            ParamSpec("color", .text, .string("auto"), "Screen color as hex, or auto to detect it"),
            ParamSpec("tolerance", .number, .number(0.35), min: 0, max: 1, "How far from the screen color still counts as screen"),
            ParamSpec("softness", .number, .number(0.25), min: 0, max: 1, "Width of the partly transparent edge"),
            ParamSpec("spill", .number, .number(0.8), min: 0, max: 1, "Removes screen-colored light on the subject"),
            ParamSpec("feather", .number, .number(0.001), min: 0, max: 0.02, unit: "of frame height", "Edge softening"),
        ]),
        EffectType(id: "video.denoise", category: "video", summary: "Temporal noise reduction like Resolve's Temporal NR: removes grain and sensor noise by aligning neighbouring frames with optical flow and averaging them, leaving out pixels that moved; optional spatial pass. Rendered in the background (the preview shows the unprocessed picture until it's ready; export waits)", params: [
            ParamSpec("temporal_frames", .number, .number(2), min: 1, max: 5, animatable: false, "Neighbouring frames each side averaged into each frame; more removes more noise and takes longer"),
            ParamSpec("strength", .number, .number(0.85), min: 0, max: 1, animatable: false, "How much of the averaged picture replaces the original"),
            ParamSpec("motion_threshold", .number, .number(0.04), min: 0.005, max: 0.5, animatable: false, "How far an aligned neighbour pixel may differ from this frame, beyond the measured noise, before it counts as motion and is left out (fraction of full scale); higher removes more noise but can smear moving edges"),
            ParamSpec("spatial", .number, .number(0), min: 0, max: 1, animatable: false, "Edge-preserving spatial noise reduction after the temporal pass, for noise left on moving areas"),
        ]),
        EffectType(id: "video.remove_object", category: "video", summary: "Object removal like Resolve's Object Removal or After Effects' Content-Aware Fill: paints a tracked object out with the background from a clean plate or from other frames where it shows (aligned to this frame, temporal median), and fills what no frame shows by patch-based inpainting that carries straight lines and edges across and holds still from frame to frame. Use recipe remove_object; rendered in the background", params: trackedBoxSpecs + [
            ParamSpec("padding", .number, .number(0.02), min: 0, max: 0.2, unit: "of frame height", animatable: false, "Room around the tracked box that is replaced too, covering shadows, motion blur and tracking slop"),
            ParamSpec("window", .number, .number(1.5), min: 0.2, max: 4, unit: "seconds", animatable: false, "How far before and after each frame to look for the background"),
            ParamSpec("feather", .number, .number(0.004), min: 0, max: 0.05, unit: "of frame height", animatable: false, "Soft edge between the fill and the picture"),
            ParamSpec("fill", .choice(["patch", "smooth"]), .string("patch"), "What fills pixels no frame shows: patches from around the hole (texture and lines continue) or a smooth membrane"),
            ParamSpec("clean_plate", .text, .string(""), animatable: false, "Image file of the background without the object (a still from the same camera), used first wherever it shows"),
            ParamSpec("clean_plate_at", .number, .number(-1), min: -1, max: 1_000_000, unit: "source seconds", animatable: false, "Frame of this clip's media to take the background from, as a clean plate; -1 for none"),
        ]),
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
        let overrides = ["blur.gaussian": "blur", "color.adjust": "grade", "color.monochrome": "mono", "color.grade": "wheels", "video.remove_object": "removal"]
        if let o = overrides[type] { return o }
        if ProAudioCatalog.isPlugin(type) {
            let parts = type.split(separator: ".")
            return parts.count > 2 ? String(parts[2]).filter(\.isLetter).lowercased().ifEmpty("plugin") : "plugin"
        }
        let last = type.split(separator: ".").last.map(String.init) ?? type
        return last.split(separator: "_").last.map(String.init) ?? last
    }

    /// A readable name for history labels: "blur.gaussian" → "blur", "stylize.drop_shadow" → "drop shadow".
    public static func title(_ type: String) -> String {
        let titles = [
            "blur.gaussian": "blur", "blur.motion": "motion blur", "blur.zoom": "zoom blur", "blur.sharpen": "sharpening",
            "color.adjust": "color correction", "color.grade": "color wheels", "color.wheels": "primary grade", "color.curves": "curves", "color.hsl": "HSL", "color.hue_curves": "hue curves", "color.hdr_zones": "HDR zones", "color.look": "look", "color.lut": "LUT", "color.cdl": "CDL", "color.monochrome": "black and white", "color.invert": "invert",
            "stylize.drop_shadow": "drop shadow", "mask.rect": "rectangle mask", "mask.ellipse": "ellipse mask", "mask.person": "person mask", "mask.subject": "subject mask", "key.chroma": "chroma key",
            "distort.bulge": "bulge", "distort.twirl": "twirl",
            "mask.object": "object mask", "video.denoise": "noise reduction", "video.remove_object": "object removal",
        ]
        return titles[type] ?? shortName(type)
    }
}
