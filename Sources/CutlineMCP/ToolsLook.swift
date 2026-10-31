import CutlineCore
import CutlineEngine
import Foundation

extension Toolbox {
    func registerLookTools() {
        let targetSchema: JSON = ["type": ["string", "array"], "items": ["type": "string"], "description": "Clip id, track id, \"V1/*\" for every clip on a track, \"master\" (param_set gain_db and layout), \"bus:<id>\" (effect_add), or a list of these"]

        addEdit(EditTool(name: "param_set", description: "Set or animate any parameter of clips or tracks by path: transform.scale/x/y/rotation/opacity/fit/crop.*, blend, fade.in/out, audio.volume, audio.channels (stereo, left, right, mono_mix, swap: left or right plays one mic of a two-channel recording on both sides; \"ch3\", \"ch3+ch4\" or \"mix:1,3\" pick any source channels across a multitrack file's audio tracks), surround panning (audio.pan_x/pan_y/center/lfe, heard when the master layout is 5.1 or 7.1), text.*, color, and fx.<effect id>.<param> for effects. Animate with keys [time, value, ease?]; times are timeline seconds or anchors (\"talk.w12\", \"clip_x.end-0.5\"), or seconds from the clip start with relative:true. Eases: linear, easeIn, easeOut, easeInOut (default), hold, back, elastic, bounce, or \"bezier(x1, y1, x2, y2)\" for a custom curve. Numbers and colors interpolate. project_status with target lists a clip's paths and values; catalog explains every effect parameter.", schema: Schema.object([
            "target": targetSchema,
            "set": ["type": "object", "description": "{path: value}, e.g. {\"transform.scale\": 1.2, \"blend\": \"screen\", \"fx.glow1.amount\": 0.8}"],
            "animate": ["type": "object", "description": "{path: [[time, value, ease?], ...]}, e.g. {\"transform.scale\": [[\"clip_x.start\", 1], [\"clip_x.end\", 1.15, \"easeOut\"]]}. Replaces that path's existing animation."],
            "unset": Schema.strings("Paths whose animation is removed (or reset to default when not animated)"),
            "relative": Schema.bool("Key times are seconds from each clip's start, default false"),
            "subframe": Schema.bool("Keep audio.fade_in/fade_out/lead/lag sample-accurate instead of snapping them to whole frames, default false"),
            "bind": ["type": "object", "description": .string(Toolbox.bindDocs)],
        ], required: ["target"]), label: { a, p in Toolbox.describeParamSet(a, p) }) { [unowned self] p, args in
            let targets = try Toolbox.resolveTargets(args.raw["target"], p)
            if let bind = args.raw["bind"]?.object {
                return try self.applyBindings(&p, targets: targets, bind)
            }
            var lines: [String] = []
            for target in targets {
                switch target {
                case .clip(let id):
                    guard let loc = p.locateClip(id) else { continue }
                    if args.optString("type") == "distort.stabilize", p.tracks[loc.track].clips[loc.clip].kind != .media { throw EditError("Stabilize works on video clips") }
                    var c = p.tracks[loc.track].clips[loc.clip]
                    lines.append(try Toolbox.applyParams(&c, args, canvas: p.canvas))
                    p.tracks[loc.track].clips[loc.clip] = c
                case .track(let i):
                    var t = p.tracks[i]
                    var changed: [String] = []
                    for (path, raw) in (args.raw["animate"]?.object ?? [:]) {
                        guard path == "volume" else { throw EditError("Only a track's volume can be animated (fader automation); animate clip parameters on \(t.id)/*") }
                        guard let list = raw.array else { throw EditError("animate.volume is a list of [time, value, ease?]") }
                        var keys: [CurveKey] = []
                        for k in list {
                            guard let arr = k.array, arr.count >= 2, let v = arr[1].double, v >= 0, v <= 4 else { throw EditError("Track volume keys are [timeline time, 0…4, ease?]") }
                            keys.append(CurveKey(t: try Args.parseTime(arr[0], name: "time"), v: .number(v), ease: arr.count > 2 ? Easing(rawValue: arr[2].string ?? "") ?? .easeInOut : .easeInOut))
                        }
                        t.volumeCurve = keys.isEmpty ? nil : Curve(keys: keys)
                        changed.append("volume automation (\(keys.count) keys)")
                    }
                    if args.strings("unset")?.contains("volume") == true { t.volumeCurve = nil; changed.append("volume automation removed") }
                    for (raw, v) in (args.raw["set"]?.object ?? [:]).sorted(by: { $0.key < $1.key }) {
                        let path = Effect.resolvedPath(raw, in: t.effects)
                        try t.set(path, try Toolbox.paramValue(v))
                        changed.append("\(path)=\(try Toolbox.paramValue(v))")
                    }
                    p.tracks[i] = t
                    lines.append("\(t.id): " + changed.joined(separator: ", "))
                case .master:
                    for (path, v) in (args.raw["set"]?.object ?? [:]).sorted(by: { $0.key < $1.key }) {
                        if path == "layout" {
                            guard let name = v.string, let layout = AudioLayout(name: name) else { throw EditError("layout is one of \(AudioLayout.allCases.map(\.rawValue).joined(separator: ", ")) (or 5.1, 7.1)") }
                            lines.append("master layout \(p.master.layout.title)→\(layout.title)")
                            p.master.layout = layout
                            continue
                        }
                        guard path == "gain_db", let n = v.double else { throw EditError("The master has gain_db (number, -40…24) and layout (stereo, mono, surround51, surround71)") }
                        guard n >= -40, n <= 24 else { throw EditError("gain_db must be between -40 and 24") }
                        let before = p.master.gainDb
                        p.master.gainDb = n
                        lines.append("master gain_db \(fmt1(before))→\(fmt1(n))")
                    }
                case .bus(let id):
                    throw EditError("param_set doesn't reach buses; audio_bus bus:\"\(id)\" sets its fader (volume, gain_db, volume_keys), mute, solo and effect params")
                }
            }
            return Toolbox.compactTargets(lines, p)
        })

        addEdit(EditTool(name: "effect_add", description: "Add, update, reorder or remove an effect on clips or tracks. Effects stack in order on each clip: blur, sharpen, color correction, black and white, glow, vignette, film grain, pixelate, posterize, drop shadow, border, distortions, and rect/ellipse masks (feathered, inverted, animatable). Effects on an adjustment layer (clip_add adjustment:true) apply to everything below it. Audio effects (audio.eq, compressor, gate, limiter, voice_isolation, reverb, delay, character, pitch, and repair: denoise, deess, dehum, declick, plus pan and width) go on a clip (its sound only), a track (every clip's sound on it) or the master; they are rendered offline, so preview and export match. Finishing: video.denoise (temporal noise reduction, rendered in the background), video.rolling_shutter (skew/jello repair, rendered in the background), lens fixes distort.lens (barrel/fisheye/GoPro presets), distort.chromatic_aberration and color.vignette_correct, and mask.object (roto of a media_track object: params {track: \"trk1\"}); recipe track_mask makes a mask.shape follow a track. Passing an existing id updates that effect. Animate parameters afterwards with param_set path fx.<id>.<param>. Call catalog for each type's parameters.", schema: Schema.object([
            "target": targetSchema,
            "type": Schema.string("Effect type", values: EffectCatalog.listed.map(\.id)),
            "params": ["type": "object", "description": "Parameter values; unset ones use catalog defaults"],
            "id": Schema.string("Effect id to create or update; default type-based such as \"vignette1\""),
            "index": Schema.integer("Position in the stack, 0 first; default last"),
            "mix": Schema.number("0 original … 1 full effect"),
            "enabled": Schema.bool("Turn on or off"),
            "remove": Schema.bool("Remove the effect with this id (or every effect of this type)"),
            "scope": Schema.string("On clips: shot limits the effect to the shot (scene cuts) playing at at, the default for a color effect given at on a clip that plays several shots; clip acts throughout", values: ["clip", "shot"]),
            "at": Schema.time("Timeline time picking the shot for scope shot"),
        ], required: ["target"]), label: { a, p in Toolbox.describeEffectEdit(a, p) }) { [unowned self] p, args in
            let targets = try Toolbox.resolveTargets(args.raw["target"], p)
            var lines: [String] = []
            for target in targets {
                switch target {
                case .master:
                    if let t = args.optString("type"), !EffectCatalog.isAudio(t) { throw EditError("The master only takes audio.* effects") }
                    var probe = Track(id: "master", kind: .audio, name: "Master", effects: p.master.effects)
                    let plan = try Toolbox.planEffect(&probe.effects, args, owner: "master")
                    for (path, v) in plan.values { try probe.set(path, v) }
                    p.master.effects = probe.effects
                    lines.append(Toolbox.describePlan(plan, effects: probe.effects, owner: "master"))
                case .bus(let id):
                    if let t = args.optString("type"), !EffectCatalog.isAudio(t) { throw EditError("Buses take audio effects (audio.* or an Audio Unit); \(t) isn't one") }
                    guard let bi = p.buses.firstIndex(where: { $0.id == id }) else { continue }
                    var probe = Track(id: id, kind: .audio, name: p.buses[bi].name, effects: p.buses[bi].effects)
                    let plan = try Toolbox.planEffect(&probe.effects, args, owner: "bus \(id)")
                    for (path, v) in plan.values { try probe.set(path, v) }
                    p.buses[bi].effects = probe.effects
                    lines.append(Toolbox.describePlan(plan, effects: probe.effects, owner: "bus \(id)").replacingOccurrences(of: " Animate with param_set path fx.\(plan.effectId).<param>.", with: ""))
                case .clip(let id):
                    guard let loc = p.locateClip(id) else { continue }
                    var c = p.tracks[loc.track].clips[loc.clip]
                    let removedBefore = Set(c.effects.map(\.id))
                    let plan = try Toolbox.planEffect(&c.effects, args, owner: id)
                    for gone in removedBefore.subtracting(c.effects.map(\.id)) {
                        for key in c.anim.keys where key.hasPrefix("fx.\(gone).") { c.anim[key] = nil }
                    }
                    for (path, v) in plan.values { try c.set(path, v) }
                    if args.raw["params"]?.object?["track"] != nil { try self.fillTrackedBoxes(&c, effectId: plan.effectId, project: p) }
                    let shot = plan.removed ? nil : try self.limitToShot(&c, effectId: plan.effectId, args, p)
                    p.tracks[loc.track].clips[loc.clip] = c
                    lines.append(Toolbox.describePlan(plan, effects: c.effects, owner: id) + (shot.map { " Acts only in \($0)." } ?? ""))
                case .track(let i):
                    var t = p.tracks[i]
                    if let type = args.optString("type"), t.kind == .audio, !EffectCatalog.isAudio(type) {
                        throw EditError("\(t.id) is an audio track; only audio.* effects apply to it")
                    }
                    let plan = try Toolbox.planEffect(&t.effects, args, owner: t.id)
                    for (path, v) in plan.values { try t.set(path, v) }
                    p.tracks[i] = t
                    lines.append(Toolbox.describePlan(plan, effects: t.effects, owner: t.id))
                }
            }
            return Toolbox.compactTargets(lines, p)
        })

        add(Tool(name: "catalog", description: "Look up what Cutline can do. No arguments: effect types by category, transitions, blend modes, eases, parameter paths and time anchors. type: one effect's parameters with ranges, units and an example call. search: a task or words (\"blur a face\", \"remove silences\", \"logo\") ranked across how-tos, effects, recipes, tools and parameters, with example calls. paths: every clip and track parameter path.", schema: Schema.object([
            "type": Schema.string("Effect or transition type id such as stylize.vignette or wipe"),
            "search": Schema.string("A task or words, e.g. \"face blur\", \"stabilize\" or \"warm\""),
            "paths": Schema.bool("List every clip and track parameter path"),
            "recipe": Schema.string("A recipe's arguments, or \"all\""),
            "tool": Schema.string("A tool's full description and every argument"),
            "plugins": Schema.bool("List installed Audio Unit effects (use their id as an effect_add type; catalog type=<id> lists parameters)"),
        ])) { [unowned self] args in
            if let t = args.optString("tool") { return .text(try toolManual(t)) }
            if args.bool("plugins", default: false) {
                let list = AudioUnitHost.installedEffects()
                return .text(list.isEmpty ? "No Audio Unit effects installed." : list.map { "\($0.id): \($0.name) by \($0.manufacturer)\($0.apple ? " (built in)" : "")" }.joined(separator: "\n"))
            }
            if let id = args.optString("type"), ProAudioCatalog.isPlugin(id) {
                return .text(Toolbox.describeEffectType(try await Toolbox.registerPlugin(id)))
            }
            if let r = args.optString("recipe") { return .text(try Toolbox.recipeManual(r)) }
            if args.optString("type") == "raw" { return .text(rawCatalog()) }
            if let id = args.optString("type") {
                if let t = TransitionCatalog.type(id) { return .text(Toolbox.describeTransitionType(t)) }
                guard let t = EffectCatalog.type(id) else { throw EditError("No effect or transition \(id). Effects: \(EffectCatalog.listed.map(\.id).joined(separator: ", ")). Transitions: \(TransitionCatalog.all.map(\.id).joined(separator: ", "))") }
                return .text(Toolbox.describeEffectType(t))
            }
            if let q = args.optString("search") { return .text(catalogSearch(q)) }
            if args.bool("paths", default: false) { return .text(Toolbox.describePaths()) }
            return .text(Toolbox.catalogOverview())
        })
    }

    enum Target {
        case clip(String)
        case track(Int)
        case master
        case bus(String)
    }

    /// The bus `name` names: "bus:<id>", a bus id or name, or a role whose DME bus exists ("bus:dialogue" → DIA).
    static func busTarget(_ name: String, _ p: Project) throws -> String? {
        let explicit = name.lowercased().hasPrefix("bus:")
        let key = explicit ? String(name.dropFirst(4)) : name
        let role = ["dialogue": "dialogue", "dialog": "dialogue", "dia": "dialogue", "music": "music", "mus": "music", "effects": "effects", "fx": "effects", "sfx": "effects"][key.lowercased()]
        if let b = p.buses.first(where: { $0.id == key }) ?? p.buses.first(where: { $0.id.lowercased() == key.lowercased() || $0.name.lowercased() == key.lowercased() })
            ?? role.flatMap({ r in p.buses.first { $0.id == Project.dmeBus(r) } }) {
            return b.id
        }
        guard explicit else { return nil }
        throw EditError("No bus \(key)." + (p.buses.isEmpty ? " The project has no buses: add one with audio_bus bus:\"\(role.map(Project.dmeBus) ?? key.uppercased())\" (or recipe dme_buses for DIA/MUS/FX), then route tracks with track_update output." : " Buses: " + p.buses.map { "\($0.id) \"\($0.name)\"" }.joined(separator: ", ")))
    }

    static func resolveTargets(_ j: JSON?, _ p: Project) throws -> [Target] {
        let names: [String] = j?.array?.compactMap(\.string) ?? (j?.string.map { [$0] } ?? [])
        guard !names.isEmpty else { throw EditError("target is required: a clip id, track id, or \"V1/*\"") }
        var out: [Target] = []
        for n in names {
            if n == "master" {
                out.append(.master)
            } else if let group = try groupTargets(n, p) {
                out += group
            } else if n.hasSuffix("/*") {
                let tid = String(n.dropLast(2))
                guard let i = p.trackIndex(tid) else { throw EditError("No track \(tid)") }
                out += p.tracks[i].clips.map { .clip($0.id) }
            } else if p.clip(n) != nil {
                out.append(.clip(n))
            } else if let i = p.trackIndex(n) {
                out.append(.track(i))
            } else if let bus = try busTarget(n, p) {
                out.append(.bus(bus))
            } else {
                throw EditError("No clip, track or bus \(n). Clips look like clip_ab12cd, tracks like V1 or A1, buses like \"bus:DIA\"" + (p.buses.isEmpty ? "." : " (buses: \(p.buses.map(\.id).joined(separator: ", "))).") + " Master: \"master\".")
            }
        }
        return out
    }

    static func targetLabel(_ j: JSON?, _ p: Project) -> String {
        let names: [String] = j?.array?.compactMap(\.string) ?? (j?.string.map { [$0] } ?? [])
        if names.count == 1, let n = names.first {
            if n.hasSuffix("/*") { return "every clip on \(n.dropLast(2))" }
            if p.clip(n) != nil { return clipName(n, p) }
            return p.tracks.first { $0.id == n }.map { "\($0.name) track" } ?? n
        }
        return "\(names.count) clips"
    }

    static func describeParamSet(_ a: Args, _ p: Project) -> String {
        let target = targetLabel(a.raw["target"], p)
        if a.raw["bind"] != nil { return "Bind parameters of \(target)" }
        let animated = (a.raw["animate"]?.object?.keys.sorted() ?? []).map(Clip.canonical)
        let setValues = a.raw["set"]?.object ?? [:]
        let set = setValues.keys.sorted().map(Clip.canonical)
        let unset = (a.strings("unset") ?? []).map(Clip.canonical)
        if set == ["time.reverse"], animated.isEmpty, unset.isEmpty {
            return (setValues.values.first?.bool ?? (setValues.values.first?.string == "true") ? "Reverse " : "Play forwards ") + target
        }
        if set == ["layout"] { return "Change master layout to \(setValues["layout"]?.string ?? "?")" }
        if set == ["gain_db"] { return "Set master gain" }
        if set == ["name"], animated.isEmpty, unset.isEmpty { return "Rename \(target)" }
        let paths = animated + set + unset
        var topics: [String] = []
        for path in paths {
            let topic: String
            if path.hasPrefix("fx.") { topic = "effect" }
            else if path.hasPrefix("audio.pan") || path == "audio.center" || path == "audio.lfe" { topic = "surround panning" }
            else if path.hasPrefix("audio.fade") { topic = "sound fades" }
            else if path == "audio.lead" || path == "audio.lag" { topic = "split edit" }
            else if path.hasPrefix("audio.") || path == "volume" { topic = "volume" }
            else if path.hasPrefix("text.") { topic = "text style" }
            else if path == "time.speed" { topic = "speed" }
            else if path == "time.reverse" { topic = "direction" }
            else if path == "time.interpolate" { topic = "slow-motion smoothing" }
            else if path.hasPrefix("input.") { topic = "log conversion" }
            else if path.hasPrefix("transform.crop") { topic = "crop" }
            else if path == "blend" { topic = "blend" }
            else if path.hasPrefix("fade.") { topic = "fades" }
            else if path == "name" { topic = "name" }
            else if path.hasPrefix("transform.") || path == "color" { topic = path == "color" ? "color" : "framing" }
            else { topic = path }
            if !topics.contains(topic) { topics.append(topic) }
        }
        let what = topics.isEmpty ? "parameters" : topics.count <= 2 ? topics.joined(separator: " and ") : "\(topics.count) kinds of parameter"
        if !animated.isEmpty { return "Animate \(what) of \(target)" }
        if !unset.isEmpty && set.isEmpty { return "Reset \(what) of \(target)" }
        return "Set \(what) of \(target)"
    }

    /// Applies set, animate and unset to one clip and describes the result.
    /// Sound edges and fades that interchange carries in frames, so edits keep them on the frame grid.
    static let frameGridAudioPaths: Set<String> = ["audio.fade_in", "audio.fade_out", "audio.lead", "audio.lag"]

    static func applyParams(_ c: inout Clip, _ args: Args, canvas: Canvas) throws -> String {
        var parts: [String] = []
        let subframe = args.bool("subframe", default: false)
        for (raw, v) in (args.raw["set"]?.object ?? [:]).sorted(by: { $0.key < $1.key }) {
            let path = c.resolvedPath(raw)
            let before = c.staticValue(path)
            let canonical = Clip.canonical(path)
            var value = try paramValue(v)
            var snapped = ""
            if !subframe, Toolbox.frameGridAudioPaths.contains(canonical), let n = value.number, abs(canvas.snap(n) - n) > 1e-6 {
                value = .number(canvas.snap(n))
                snapped = " (snapped from \(fmt(n))s to the \(Describe.fmtFps(canvas.fps))fps frame grid; subframe:true keeps it sample-accurate)"
            }
            try c.set(path, value)
            parts.append("\(canonical) \(before.map(\.description) ?? "–")→\(c.staticValue(canonical).map(\.description) ?? "?")" + snapped + (c.animationKeys(canonical) != nil ? " (animated; the animation still wins)" : ""))
        }
        let relative = args.bool("relative", default: false)
        for (given, raw) in (args.raw["animate"]?.object ?? [:]).sorted(by: { $0.key < $1.key }) {
            let path = c.resolvedPath(given)
            guard let list = raw.array else { throw EditError("animate.\(path) must be a list of [time, value, ease?]") }
            var keys: [CurveKey] = []
            for k in list {
                let (tj, vj, ej): (JSON, JSON, JSON?)
                if let arr = k.array, arr.count >= 2 {
                    (tj, vj, ej) = (arr[0], arr[1], arr.count > 2 ? arr[2] : nil)
                } else if let o = k.object, let t = o["t"] ?? o["time"], let v = o["v"] ?? o["value"] {
                    (tj, vj, ej) = (t, v, o["ease"])
                } else {
                    throw EditError("Each key in animate.\(path) is [time, value, ease?] or {t, v, ease}")
                }
                let t = try Args.parseTime(tj, name: "time")
                let local = relative ? t : t - c.start
                var ease = Easing.easeInOut
                var bezier: [Double]?
                if let arr = ej?.array, arr.count == 4 {
                    bezier = arr.compactMap(\.double)
                } else if let e = ej?.string, e.hasPrefix("bezier(") || e.hasPrefix("cubic-bezier(") {
                    let nums = e.drop { $0 != "(" }.dropFirst().dropLast().split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                    guard nums.count == 4 else { throw EditError("Bezier eases look like \"bezier(0.2, 0, 0, 1)\"") }
                    bezier = nums
                } else if let e = ej?.string {
                    guard let parsed = Easing(rawValue: e) else { throw EditError("Unknown ease \(e). Use \(Easing.allCases.map(\.rawValue).joined(separator: ", ")), or \"bezier(x1, y1, x2, y2)\"") }
                    ease = parsed
                }
                if let b = bezier, b.count != 4 || b[0] < 0 || b[0] > 1 || b[2] < 0 || b[2] > 1 { throw EditError("Bezier x values must be within 0…1") }
                keys.append(CurveKey(t: canvas.snap(local), v: try paramValue(vj), ease: ease, bezier: bezier))
            }
            try c.animate(path, keys: keys)
            let canonical = Clip.canonical(path)
            let outside = keys.filter { $0.t < -1e-6 || $0.t > c.duration + 1e-6 }
            var line = "animate \(canonical): " + (c.animationKeys(canonical) ?? []).map { "\(fmt2($0.t))s→\($0.v)" }.joined(separator: ", ")
            if !outside.isEmpty { line += " (warning: \(outside.count) keys fall outside the clip's 0–\(fmt2(c.duration))s)" }
            parts.append(line)
        }
        for path in args.strings("unset") ?? [] {
            let canonical = c.resolvedPath(path)
            if c.anim[canonical] != nil {
                c.anim[canonical] = nil
                parts.append("stopped animating \(canonical)")
            } else {
                let spec = try c.spec(canonical)
                try c.set(canonical, spec.defaultValue)
                parts.append("reset \(canonical) to \(spec.defaultValue)")
            }
        }
        return "\(c.id): " + (parts.isEmpty ? "nothing to change" : parts.joined(separator: "; "))
    }

    struct EffectPlan {
        var effectId: String
        var created = false
        var removed = false
        var values: [(String, ParamValue)] = []
    }

    /// Adds, removes or reorders one effect in a stack, and lists the parameter values to set on it.
    static func planEffect(_ stack: inout [Effect], _ args: Args, owner: String) throws -> EffectPlan {
        let id = args.optString("id")
        let typeId = args.optString("type")
        if args.bool("remove", default: false) {
            let before = stack.count
            if let id { stack.removeAll { $0.id == id } } else if let typeId { stack.removeAll { $0.type == typeId } } else { throw EditError("remove needs id or type") }
            guard stack.count < before else { throw EditError("\(owner) has no such effect. Effects: \(stack.map(\.id).joined(separator: ", ").ifEmptyText("none"))") }
            return EffectPlan(effectId: id ?? typeId!, removed: true)
        }
        var index: Int
        var plan: EffectPlan
        if let id, let i = stack.firstIndex(where: { $0.id == id }) {
            if let typeId, typeId != stack[i].type { throw EditError("\(id) is a \(stack[i].type); remove it first or pick another id") }
            index = i
            plan = EffectPlan(effectId: id)
        } else {
            guard let typeId else { throw EditError("Pass type to add an effect" + (id.map { ", or an existing id (\($0) was not found)" } ?? "")) }
            guard EffectCatalog.type(typeId) != nil else { throw EditError("No effect \(typeId). Types: \(EffectCatalog.listed.map(\.id).joined(separator: ", "))") }
            let base = EffectCatalog.shortName(typeId)
            var n = 1
            while stack.contains(where: { $0.id == "\(base)\(n)" }) { n += 1 }
            let newId = id ?? "\(base)\(n)"
            guard newId.range(of: #"^[A-Za-z][A-Za-z0-9_]*$"#, options: .regularExpression) != nil else { throw EditError("Effect ids are letters, digits and _, starting with a letter") }
            stack.append(Effect(id: newId, type: typeId))
            index = stack.count - 1
            plan = EffectPlan(effectId: newId, created: true)
        }
        if let target = args.optInt("index") {
            let e = stack.remove(at: index)
            stack.insert(e, at: min(max(0, target), stack.count))
        }
        let effectType = EffectCatalog.type(stack[index].type)
        for (name, v) in (args.raw["params"]?.object ?? [:]).sorted(by: { $0.key < $1.key }) {
            plan.values.append(("fx.\(plan.effectId).\(effectType?.paramName(for: name) ?? name)", try paramValue(v)))
        }
        if let m = args.optDouble("mix") { plan.values.append(("fx.\(plan.effectId).mix", .number(m))) }
        if let en = args.optBool("enabled") { plan.values.append(("fx.\(plan.effectId).enabled", .bool(en))) }
        return plan
    }

    static func describePlan(_ plan: EffectPlan, effects: [Effect], owner: String) -> String {
        let order = effects.map(\.id).joined(separator: " → ").ifEmptyText("none")
        if plan.removed { return "\(owner): removed \(plan.effectId). Stack: \(order)." }
        let effect = effects.first { $0.id == plan.effectId }
        let type = effect?.type ?? ""
        // Values as stored, after validation normalized them.
        let applied = plan.values.map { v -> String in
            let name = String(v.0.split(separator: ".").last ?? "")
            return "\(name) \(effect?.params[name] ?? v.1)"
        }
        return "\(owner): \(plan.created ? "added" : "updated") \(plan.effectId) (\(type))" + (applied.isEmpty ? "" : ": " + applied.joined(separator: ", ")) + ". Stack: \(order). Animate with param_set path fx.\(plan.effectId).<param>."
    }

    static func describeEffectType(_ t: EffectType) -> String {
        var lines = ["\(t.id): \(t.summary)", "Parameters:"]
        lines += t.params.map { "  " + $0.line }
        lines.append("  mix: number 0…1, default 1, animatable. Blend between original and full effect.")
        lines.append("  enabled: bool, default true.")
        if t.category == "generator", GeneratorCatalog.type(t.id) != nil { return (lines + Toolbox.generatorExample(t)).joined(separator: "\n") }
        let example = t.params.prefix(2).map { "\"\($0.name)\": \($0.defaultValue)" }.joined(separator: ", ")
        lines.append("Example: effect_add {\"target\": \"clip_ab12cd\", \"type\": \"\(t.id)\", \"params\": {\(example)}}")
        if let p = t.params.first(where: { $0.animatable }) {
            lines.append("Animate: param_set {\"target\": \"clip_ab12cd\", \"animate\": {\"fx.\(EffectCatalog.shortName(t.id))1.\(p.name)\": [[\"clip_ab12cd.start\", \(p.defaultValue)], [\"clip_ab12cd.end\", …]]}}")
        }
        return lines.joined(separator: "\n")
    }

    static func describePaths() -> String {
        let sample: [(String, Clip)] = [
            ("Media clips", Clip(id: "x", kind: .media, start: 0, duration: 1)),
            ("Title clips (text_add)", Clip(id: "x", kind: .text, start: 0, duration: 1, text: TextSpec(text: ""))),
            ("Solid color clips", Clip(id: "x", kind: .solid, start: 0, duration: 1)),
            ("Adjustment layers", Clip(id: "x", kind: .adjustment, start: 0, duration: 1)),
        ]
        var lines: [String] = []
        var seen = Set<String>()
        for (title, clip) in sample {
            let specs = clip.fixedSpecs.filter { !seen.contains($0.name) }
            guard !specs.isEmpty else { continue }
            lines.append("\(title):")
            for s in specs {
                seen.insert(s.name)
                lines.append("  " + s.line)
            }
        }
        lines.append("Effects on any clip: fx.<effect id>.<param>, fx.<id>.mix, fx.<id>.enabled (see catalog type).")
        lines.append("Tracks: " + Track.specs.map(\.line).joined(separator: " | ") + " | fx.<id>.<param>")
        lines.append("Aliases: opacity, scale, x, y, rotation, fit, volume.")
        return lines.joined(separator: "\n")
    }

    static func catalogOverview() -> String {
        var lines: [String] = ["Effects (effect_add; catalog type=<id> for parameters):"]
        for (cat, summary) in EffectCatalog.categories {
            lines.append("  \(cat): \(summary)")
            for t in EffectCatalog.listed where t.category == cat { lines.append("    \(t.id): \(t.summary)") }
        }
        lines.append("Generators (clip_add generator:<id>, params; animate fx.gen.<param>, and a shape layer's shapes as fx.gen.<shape id>.<property>, e.g. fx.gen.ring.trim_end):")
        for t in GeneratorCatalog.all { lines.append("    \(t.id): \(t.summary)") }
        lines.append("Transitions (transition_set; catalog type=<id> for parameters):")
        for t in TransitionCatalog.all { lines.append("    \(t.id): \(t.summary)") }
        lines += [
            "Secondaries and grade nodes (blur, color, stylize and distort effects): limit rect/ellipse/qualifier/rect+qualifier/ellipse+qualifier keys an effect to a window and/or an HSL qualifier (q_hue, q_hue_width, q_hue_soft, q_sat_min/max/soft, q_luma_min/max/soft, q_preset skin, cleanup q_clean_black, q_clean_white, q_denoise, q_blur; recipe qualify samples ranges from the picture; timeline_frames view:\"matte\" shows the key). node groups consecutive effects into one grade node; node_mode serial (default), parallel (branches from one input, changes added), layer (composited in order with node_blend and node_opacity inside each node's key) or outside (the inverse of the previous node's key). project_status target=<clip> shows the node graph.",
            "Blend modes (param_set blend): " + BlendMode.allCases.map(\.rawValue).joined(separator: ", "),
            "Eases for animation keys: " + Easing.allCases.map(\.rawValue).joined(separator: ", ") + ", or \"bezier(x1, y1, x2, y2)\" for a custom curve (CSS cubic-bezier control points, x within 0…1; the graph editor's handles), e.g. \"bezier(0.2, 0, 0, 1)\" for a fast start that settles",
            "3D: param_set transform.3d true puts a layer in 3D space (transform.z depth, rotate_x/rotate_y/rotation); clip_add generator \"camera\" adds a camera that orbits, dollies, zooms and focuses (animate fx.gen.orbit, distance, fov, zoom, focus_distance, blur). Neighbouring 3D layers draw far to near.",
            "Parameter paths: transform.{scale,x,y,rotation,opacity,fit,crop.left|top|right|bottom,3d,z}, blend, fade.{in,out}, audio.{volume,fade_in,fade_out,lead,lag,channels}, text.*, color, fx.<id>.<param>. catalog paths=true lists them all.",
            "Units: lengths are fractions of frame height; positions (text.x/y, fx.gen.x/y, transform.pos_x/pos_y) are fractions of the frame with 0,0 top left, but transform.x/y offset the clip's center from the frame center (0 centered, ±0.5 on an edge); angles are degrees clockwise.",
            "Time anchors (anywhere a time is taken): seconds, \"m:ss.f\", \"<media>.w12\" / \"<media>.w12.end\" (transcript words; source-time arguments resolve them in the media), \"<media>.b8\" / \"<media>.d2\" / \"<media>.s3\" (beats, downbeats, shots), \"beat:12\", \"<media>@01:00:12:10\" (that media's source timecode at its own rate, \";\" before the frames for drop frame; a source time), \"tc:00:00:10:00\" (timeline timecode), \"<clip id>.start\" / \".end\", \"marker:<label>\", \"start\", \"end\", each with optional +/- seconds.",
            "Every edit tool takes dry_run:true to preview its changes. batch groups edits into one undo step and can name results with as:\"x\" for later \"$x\"; in any tool \"$last\", \"$last_clip\", \"$last_track\", \"$last_media\" and \"$last_effect\" are the latest ids created.",
            Toolbox.busDocs,
        ]
        return lines.joined(separator: "\n")
    }
}

extension String {
    func ifEmptyText(_ fallback: String) -> String { isEmpty ? fallback : self }
}
