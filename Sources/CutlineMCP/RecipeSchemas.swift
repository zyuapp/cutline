import CutlineCore
import Foundation

/// One argument a recipe reads.
struct RecipeArg {
    enum Kind: String {
        case string, number, integer, bool, color, object
        case time = "timeline time"
        case sourceTime = "source time"
        case ids = "id or ids"
        case times = "time or times"
        case objects = "list of objects"
        case any = "value"
    }

    let name: String
    let kind: Kind
    let doc: String
    /// Declared keys of an object, or of each object in a list; nil leaves them unchecked.
    var fields: [RecipeArg]? = nil
    /// Accepted (an alias) but not listed.
    var hidden = false

    init(_ name: String, _ kind: Kind, _ doc: String, fields: [RecipeArg]? = nil, hidden: Bool = false) {
        self.name = name
        self.kind = kind
        self.doc = doc
        self.fields = fields
        self.hidden = hidden
    }

    var schema: JSON {
        var o: [String: JSON] = ["description": .string(doc)]
        if let fields {
            let props = JSON.object(Dictionary(uniqueKeysWithValues: fields.map { ($0.name, $0.schema) }))
            if kind == .objects { o["items"] = ["type": "object", "properties": props] } else { o["properties"] = props }
        }
        return .object(o)
    }

    /// Why `value` can't be this argument; nil when it can.
    func mismatch(_ value: JSON) -> String? {
        if value.isNull { return nil }
        let ok: Bool
        switch kind {
        case .number, .integer: ok = value.double != nil
        case .bool: ok = value.bool != nil || ["true", "false", "yes", "no", "1", "0"].contains(value.string?.lowercased() ?? "")
        case .string, .color: ok = value.string != nil || value.double != nil
        case .time, .sourceTime: ok = value.string != nil || value.double != nil
        case .ids: ok = value.string != nil || value.array?.allSatisfy { $0.string != nil } == true
        case .times: ok = value.string != nil || value.double != nil || value.array != nil
        case .object: ok = value.object != nil
        case .objects: ok = value.array?.allSatisfy { $0.object != nil } == true
        case .any: ok = true
        }
        return ok ? nil : "'\(name)' must be \(kind == .integer ? "an integer" : kind == .object ? "an object" : "a " + kind.rawValue), got \(value.encoded())"
    }
}

/// A recipe's arguments and what it does.
struct RecipeSpec {
    let name: String
    let group: String
    let summary: String
    let args: [RecipeArg]

    var schema: JSON { Schema.object(Dictionary(uniqueKeysWithValues: args.map { ($0.name, $0.schema) })) }

    var listedArgs: [RecipeArg] { args.filter { !$0.hidden } }

    /// One line per argument, for catalog recipe=<name>.
    var manual: String {
        func line(_ a: RecipeArg, indent: String) -> [String] {
            [indent + "\(a.name) (\(a.kind.rawValue)): \(a.doc)"] + (a.fields ?? []).filter { !$0.hidden }.flatMap { line($0, indent: indent + "  ") }
        }
        return (["\(name): \(summary)"] + listedArgs.flatMap { line($0, indent: "  ") }).joined(separator: "\n")
    }
}

extension Toolbox {
    static let recipes: [RecipeSpec] = [
        RecipeSpec(name: "duck", group: "Sound", summary: "Dips music under speech.", args: [
            .init("music", .ids, "Clip or track ids to duck; default audio tracks without speech"),
            .init("under", .ids, "Track ids with the speech; default every other track"),
            .init("amount_db", .number, "Dip depth, default 12"),
            .init("attack", .number, "Seconds to dip, default 0.3"),
            .init("release", .number, "Seconds to recover, default 0.8"),
        ]),
        RecipeSpec(name: "loudness_normalize", group: "Sound", summary: "Sets master gain and a limiter for preview and, with persist, keeps the target on the master so every export measures the mix and conforms it (gain plus true-peak limiter) even after later mix changes.", args: [
            .init("target_lufs", .number, "Integrated loudness, −60…−5, default −14"),
            .init("ceiling_db", .number, "True-peak ceiling, −20…0, default −1.5"),
            .init("limit", .bool, "Add the master limiter, default true"),
            .init("persist", .bool, "Keep the target on the master for every export, default true; false is a one-off gain"),
            .init("off", .bool, "Clear the master loudness target"),
        ]),
        RecipeSpec(name: "dme_buses", group: "Sound", summary: "DME mix structure: adds DIA, MUS and FX buses and routes each track by its role, else its name (VO, Score, SFX, Room tone…), else detected speech; a light compressor on DIA and a −1 dBFS master limiter. Running it again only routes new tracks.", args: [
            .init("compressor", .bool, "Light compressor on DIA, default true"),
            .init("limiter", .bool, "Master limiter at −1 dBFS, default true"),
        ]),
        RecipeSpec(name: "split_edit", group: "Sound", summary: "J or L cut at a cut between two clips.", args: [
            .init("edit", .string, "\"clip_a|clip_b\""),
            .init("offset", .number, "Seconds: + J cut (b's sound starts early), − L cut (a's sound runs on)"),
        ]),
        RecipeSpec(name: "room_tone", group: "Sound", summary: "Fills a range with room tone, looped from varied start points with short crossfades so the repeat isn't heard.", args: [
            .init("start", .time, "Range start"),
            .init("end", .time, "Range end"),
            .init("media", .string, "Media with the room tone"),
            .init("source_start", .sourceTime, "Start of a quiet stretch of that media's sound (2 s or more sounds best)"),
            .init("source_end", .sourceTime, "End of the quiet stretch"),
            .init("track", .string, "Audio track; default a new \"Room tone\" track"),
            .init("crossfade", .number, "Seconds, default 0.25"),
        ]),
        RecipeSpec(name: "fill_gaps", group: "Sound", summary: "Fills every gap between a dialogue track's sounds with room tone so the background never drops out.", args: [
            .init("track", .string, "The dialogue track"),
            .init("media", .string, "Media with the room tone"),
            .init("source_start", .sourceTime, "Start of a quiet stretch, as room_tone"),
            .init("source_end", .sourceTime, "End of the quiet stretch"),
            .init("into", .string, "Audio track for the fill; default a new \"Room tone\" track"),
            .init("min_gap", .number, "Shortest gap filled, default 0.04"),
            .init("crossfade", .number, "Seconds, default 0.25 (half of a shorter gap)"),
        ]),
        RecipeSpec(name: "sync_audio", group: "Sound", summary: "Lines up dual-system sound by waveform, links it to the picture and mutes the camera mic.", args: [
            .init("audio", .string, "Media id of the separate recorder"),
            .init("clips", .ids, "Video clips; default every clip of that camera media on V1"),
            .init("track", .string, "Audio track; default a new \"Production sound\""),
            .init("keep_camera", .bool, "Keep the camera sound, default false"),
            .init("channel", .string, "Recorder channel to sync by (\"ch3\", \"mix:1,2\"); default its analysis channel or every channel with sound"),
            .init("camera_channel", .string, "The same for the camera"),
            .init("play", .string, "Routing the placed sound plays, e.g. \"ch2\"; default as recorded"),
        ]),
        RecipeSpec(name: "speed_ramp", group: "Time", summary: "Ramps a clip into slow motion and back.", args: [
            .init("clip", .string, "Clip id"),
            .init("at", .time, "Center of the ramp; default the clip's middle"),
            .init("speed", .number, "Slowest speed, default 0.3"),
            .init("ramp", .number, "Seconds to ramp each way, default 0.3"),
            .init("hold", .number, "Seconds held at speed, default 0.8"),
        ]),
        RecipeSpec(name: "freeze_frame", group: "Time", summary: "Holds a frame; speech pauses with it, music plays on.", args: [
            .init("at", .time, "Frame to hold"),
            .init("duration", .number, "Seconds, default 1.5"),
            .init("track", .string, "Default the top video at that time"),
            .init("zoom", .number, "Scale reached over the hold, default 1 (e.g. 1.08 pushes in)"),
        ]),
        RecipeSpec(name: "punch_in", group: "Framing", summary: "Scales up alternate shots to hide jump cuts; centers on faces when shots are analyzed.", args: [
            .init("clips", .ids, "Default every other jump cut on track"),
            .init("track", .string, "Default V1"),
            .init("amount", .number, "Scale, default 1.15"),
            .init("settle", .bool, "Start slightly tighter and ease out, default false"),
        ]),
        RecipeSpec(name: "pip", group: "Framing", summary: "Picture-in-picture in a corner.", args: [
            .init("clip", .string, "Clip id"),
            .init("corner", .string, "top_left, top_right, bottom_left, bottom_right (default) or center"),
            .init("size", .number, "Fraction of the frame, default 0.3"),
            .init("margin", .number, "Default 0.04"),
            .init("roundness", .number, "Corner rounding, default 0.12"),
            .init("border", .color, "Border color or none"),
        ]),
        RecipeSpec(name: "split_screen", group: "Framing", summary: "Shows clips side by side.", args: [
            .init("clips", .ids, "Clip ids"),
            .init("layout", .string, "lr (default), tb or grid"),
            .init("gap", .number, "Default 0.01"),
        ]),
        RecipeSpec(name: "reframe", group: "Framing", summary: "Changes the canvas aspect, following faces or the salient subject when shots are analyzed.", args: [
            .init("aspect", .string, "\"9:16\" (default), \"1:1\", \"4:5\" or \"16:9\""),
            .init("height", .integer, "Long side in pixels, default the current one"),
        ]),
        RecipeSpec(name: "follow", group: "Framing", summary: "Keeps a graphic, title or overlay on its subject wherever the media plays.", args: [
            .init("clip", .string, "The clip to move"),
            .init("target", .string, "\"track:<id>\" (media_track) or \"face:<media>[:n]\""),
            .init("offset_x", .number, "Fraction of the frame, default 0"),
            .init("offset_y", .number, "Fraction of the frame, default 0; negative is above"),
            .init("smooth", .number, "Default 0.2"),
        ]),
        RecipeSpec(name: "beat_cut", group: "Rhythm", summary: "Cuts footage to the analyzed music beats.", args: [
            .init("media", .ids, "Media ids (analyzed shots, best first)"),
            .init("sources", .objects, "Or explicit source ranges", fields: [
                .init("media", .string, "Media id"),
                .init("start", .sourceTime, "Source start, default 0"),
                .init("end", .sourceTime, "Source end, default the media's end"),
            ]),
            .init("start", .time, "Timeline start, default 0"),
            .init("end", .time, "Timeline end, default the timeline's end"),
            .init("every", .integer, "Beats per shot: 1, 2 (default) or 4"),
            .init("track", .string, "Default \"new\""),
            .init("align", .string, "fill (default: the first shot also covers the time before the first beat, so nothing is black), zero (same) or first_beat (trims the music's head so its first beat lands at start)"),
        ]),
        RecipeSpec(name: "music_fit", group: "Rhythm", summary: "Cuts out or repeats whole bars at downbeats so the song keeps its own ending.", args: [
            .init("clip", .string, "The music clip"),
            .init("length", .number, "Seconds"),
            .init("end", .time, "Or the timeline time to end on"),
            .init("fade_out", .number, "Seconds, default 1.5"),
        ]),
        RecipeSpec(name: "multicam_switch", group: "Rhythm", summary: "Syncs angles by their sound and cuts per speaker turn in the pause before each new speaker, never inside a word; with shot analysis, each speaker goes to the angle where their face is seen talking. Or pass cuts to switch angles by hand: splits there and plays that angle in sync from then on.", args: [
            .init("angles", .ids, "Media ids"),
            .init("audio", .string, "Media with the main sound; default the first angle"),
            .init("signal", .string, "auto (default: whose own mic is loudest when each angle records its person, else speaker analysis), mics or speakers"),
            .init("speakers", .object, "{\"S1\": media, …}; default S1→first angle, S2→second…"),
            .init("wide", .string, "Media for long turns"),
            .init("reaction", .any, "true or seconds: cut to the listener in turns longer than that (default 5)"),
            .init("start", .sourceTime, "Source seconds of the audio to start at"),
            .init("end", .sourceTime, "Source seconds of the audio to end at"),
            .init("min_shot", .number, "Default 1.0"),
            .init("max_shot", .number, "Longer turns get cutaways to the wide or the other angle; default 8, 0 for no limit"),
            .init("at", .time, "Timeline time to place the edit, default 0"),
            .init("track", .string, "Default V1"),
            .init("channel", .string, "Source channel(s) of each angle to sync and compare mics by, e.g. \"ch3\""),
            .init("audio_channel", .string, "The main sound's channel to sync to"),
            .init("cuts", .objects, "Switch by hand instead", fields: [
                .init("at", .time, "Timeline time"),
                .init("angle", .string, "Media id"),
            ]),
        ]),
        RecipeSpec(name: "look", group: "Style", summary: "Adds a look on an adjustment layer.", args: [
            .init("look", .string, ColorMath.looks.joined(separator: ", ") + "; default teal_orange"),
            .init("amount", .number, "Default 0.8"),
            .init("grain", .number, "Default 0.2"),
            .init("vignette", .number, "Default 0.4"),
            .init("start", .time, "Default 0"),
            .init("end", .time, "Default the timeline's end"),
        ]),
        RecipeSpec(name: "glitch", group: "Style", summary: "Adds glitch hits on an adjustment track.", args: [
            .init("at", .times, "Times or anchors of the hits"),
            .init("duration", .number, "Seconds, default 0.3"),
            .init("amount", .number, "Default 0.8"),
        ]),
        RecipeSpec(name: "whip_pan", group: "Style", summary: "Whip-pan transition at a cut.", args: [
            .init("cut", .string, "\"clip_a|clip_b\""),
            .init("direction", .string, "Default left"),
            .init("duration", .number, "Seconds, default 0.35"),
        ]),
        RecipeSpec(name: "kinetic_text", group: "Style", summary: "Spoken words appear as they are said.", args: [
            .init("start", .time, "Timeline time or word anchor"),
            .init("end", .time, "Timeline time or word anchor"),
            .init("preset", .string, "Word animation, default pop"),
            .init("size", .number, "Default 0.09"),
            .init("y", .number, "Default 0.5"),
            .init("color", .color, "Default white"),
            .init("highlight", .color, "Accent color"),
            .init("uppercase", .bool, "Default false"),
            .init("max_width", .number, "Default 0.8"),
        ]),
        RecipeSpec(name: "template", group: "Style", summary: "Inserts a saved template (template_save).", args: [
            .init("template", .string, "Template name; omit to list templates"),
            .init("name", .string, "Same as template", hidden: true),
            .init("at", .time, "Default 0"),
            .init("values", .object, "{field: text}"),
        ]),
        RecipeSpec(name: "match_color", group: "Color", summary: "Shot matching like Resolve's: measures each shot's tones and color (inside its crop, ignoring letterbox bars; robust to a few extreme pixels) and adds a match LUT (effect \"match\") in front of its other color effects. Lightness moves at most ±20 L unless allow_large, colorfulness at most ±25%, black and white stay put; warns when a shot isn't comparable with the reference.", args: [
            .init("clips", .ids, "Clips to match; default every media clip on V1"),
            .init("track", .string, "Or every media clip on this track"),
            .init("reference", .string, "Clip whose look the others match"),
            .init("reference_at", .time, "Timeline time of the exact reference frame (picks the clip there when reference is omitted)"),
            .init("strength", .number, "0…1, default 0.8"),
            .init("allow_large", .bool, "Lift the lightness cap, default false"),
        ]),
        RecipeSpec(name: "grade_group", group: "Color", summary: "Adds one shared effect with that id to every clip (clips added to an existing group copy its settings). Change the group with param_set target \"group:<id>\" and fx.<id>.<param>; effect_add target \"group:<id>\" works too.", args: [
            .init("clips", .ids, "Clip ids"),
            .init("track", .string, "Or every media clip on this track"),
            .init("id", .string, "Group id, default group1"),
            .init("effect", .object, "The shared effect, default color.wheels", fields: [
                .init("type", .string, "Picture effect type"),
                .init("params", .object, "Parameter values"),
                .init("mix", .number, "0…1"),
            ]),
        ]),
        RecipeSpec(name: "qualify", group: "Color", summary: "The eyedropper: samples the picture as the effect receives it and sets its hue/saturation/luma qualifier ranges and matte cleanup to cover the sampled colors.", args: [
            .init("clip", .string, "Media clip"),
            .init("x", .number, "Frame fraction of the color to key"),
            .init("y", .number, "Frame fraction of the color to key"),
            .init("radius", .number, "Sample radius, default 0.02"),
            .init("face", .bool, "Sample skin of a face instead of x, y"),
            .init("n", .integer, "Face index, largest first, default 0"),
            .init("at", .time, "Default the clip's middle"),
            .init("effect", .string, "Existing effect id to key; default a new one"),
            .init("type", .string, "Type of a new effect, default color.wheels"),
            .init("window", .bool, "With face: an ellipse window on the face (default true)"),
        ]),
        RecipeSpec(name: "remove_object", group: "Finishing", summary: "Paints an object out with the background from other frames where it shows (aligned to the camera's motion, temporal median), a clean plate if given, and patch-based inpainting that continues lines where no frame shows it; rendered in the background as a processed copy.", args: [
            .init("clip", .string, "Video clip"),
            .init("track", .string, "\"track:<id>\" from media_track"),
            .init("box", .object, "Or the object's box in source frame fractions, tracked now", fields: [
                .init("x", .number, "Left"), .init("y", .number, "Top"), .init("width", .number, "Width"), .init("height", .number, "Height"),
            ]),
            .init("at", .time, "Timeline time of box, default the clip's start"),
            .init("fixed", .bool, "Keep the box still (logos, bugs)"),
            .init("label", .string, "Name of the new object track"),
            .init("padding", .number, "Fraction of frame height, default 0.02"),
            .init("window", .number, "Seconds searched each side, default 1.5"),
            .init("feather", .number, "Default 0.004"),
            .init("fill", .string, "patch (default) or smooth, for pixels no frame shows"),
            .init("clean_plate", .string, "Image of the background without the object"),
            .init("clean_plate_at", .time, "Or a timeline time where the background shows"),
        ]),
    ]

    static var recipeNames: [String] { recipes.map(\.name) }

    static func recipe(_ name: String) -> RecipeSpec? { recipes.first { $0.name == name } }

    /// "Sound: duck, loudness_normalize…. Time: …", in table order.
    static var recipeGroups: String {
        var groups: [(String, [String])] = []
        for r in recipes {
            if let i = groups.firstIndex(where: { $0.0 == r.group }) { groups[i].1.append(r.name) } else { groups.append((r.group, [r.name])) }
        }
        return groups.map { "\($0.0): \($0.1.joined(separator: ", "))" }.joined(separator: ". ")
    }

    static var recipeDescription: String {
        "Common multi-step edits as one undoable step that reports what it changed (dry_run:true previews). \(recipeGroups). catalog recipe=<name> lists a recipe's arguments; unknown arguments are refused."
    }

    /// Problems with a recipe call's `args`: unknown names (with the closest declared ones) and values of the wrong kind.
    static func recipeArgumentProblems(_ name: String, _ args: JSON?) -> [String] {
        guard let spec = recipe(name) else {
            let close = recipeNames.map { ($0, editDistance($0, name)) }.filter { $0.1 <= max(2, name.count / 3) }.sorted { $0.1 < $1.1 }.prefix(3).map(\.0)
            return ["there is no such recipe" + (close.isEmpty ? " (recipes: \(recipeNames.joined(separator: ", ")))" : " (did you mean \(close.joined(separator: " or "))?)")]
        }
        guard let args, args != .null else { return [] }
        guard let o = args.object else { return ["args is an object"] }
        var out = unknownArguments(args, schema: spec.schema, path: "args.").map { "doesn't take " + $0 }
        for a in spec.args {
            if let v = o[a.name], let why = a.mismatch(v) { out.append(why) }
        }
        return out
    }

    /// The recipe call's `args`, recording which names the recipe reads.
    func recipeArgs(_ args: Args) -> Args {
        let reads = ArgReads()
        lastRecipeReads = reads
        return Args(args.raw["args"], reads: reads)
    }

    /// catalog recipe=<name>: the recipe's arguments; "all" lists every recipe with its argument names.
    static func recipeManual(_ name: String) throws -> String {
        if name == "all" {
            return recipes.map { "\($0.name) {\($0.listedArgs.map(\.name).joined(separator: ", "))}: \($0.summary)" }.joined(separator: "\n")
                + "\ncatalog recipe=<name> describes each argument."
        }
        guard let spec = recipe(name) else { throw EditError("No recipe \(name). Recipes: \(recipeNames.joined(separator: ", "))") }
        return spec.manual + "\nPreview with recipe {\"name\": \"\(name)\", \"args\": {…}, \"dry_run\": true}."
    }
}
