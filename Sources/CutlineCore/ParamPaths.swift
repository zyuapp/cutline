import Foundation

/// Every clip and track property is addressed by a path such as "transform.scale",
/// "audio.volume", "text.color" or "fx.blur1.radius". Paths are what agents set,
/// animate and read back.
extension Clip {
    static let transformSpecs: [ParamSpec] = [
        ParamSpec("transform.fit", .choice(FitMode.allCases.map(\.rawValue)), .string("fit"), "fit letterboxes, fill covers the frame, stretch distorts"),
        ParamSpec("transform.scale", .number, .number(1), min: 0, max: 50, "1 is the size given by fit"),
        ParamSpec("transform.x", .number, .number(0), min: -10, max: 10, unit: "of frame width", "Horizontal offset of the center; positive moves right"),
        ParamSpec("transform.y", .number, .number(0), min: -10, max: 10, unit: "of frame height", "Vertical offset of the center; positive moves down"),
        ParamSpec("transform.rotation", .number, .number(0), min: -36000, max: 36000, unit: "degrees", "Clockwise rotation"),
        ParamSpec("transform.opacity", .number, .number(1), min: 0, max: 1, "Opacity"),
        ParamSpec("transform.anchor_x", .number, .number(0.5), min: -2, max: 3, "Pivot for scale and rotation, 0 left to 1 right of the clip's frame"),
        ParamSpec("transform.anchor_y", .number, .number(0.5), min: -2, max: 3, "Pivot, 0 top to 1 bottom"),
        ParamSpec("transform.rotate_x", .number, .number(0), min: -360, max: 360, unit: "degrees", "3D tilt around the horizontal axis; positive tips the top away"),
        ParamSpec("transform.rotate_y", .number, .number(0), min: -360, max: 360, unit: "degrees", "3D turn around the vertical axis; positive turns the right side away"),
        ParamSpec("transform.perspective", .number, .number(2), min: 0.3, max: 50, unit: "frame heights", "Camera distance for 2D tilts (layers without transform.3d); smaller is more dramatic"),
        ParamSpec("transform.3d", .bool, .bool(false), "Place the layer in 3D space, seen through the camera (clip_add generator \"camera\"; a default front camera without one). Uses transform.z, rotate_x, rotate_y and rotation; 3D layers on neighbouring tracks are drawn far to near"),
        ParamSpec("transform.z", .number, .number(0), min: -100, max: 100, unit: "frame heights", "Depth of a 3D layer; positive moves it away from the camera"),
        ParamSpec("transform.motion_blur", .number, .number(0), min: 0, max: 720, unit: "degrees shutter", "Blur along the clip's own animated motion; 180 is film-like"),
        ParamSpec("transform.crop.left", .number, .number(0), min: 0, max: 0.95, "Fraction of the source removed from the left"),
        ParamSpec("transform.crop.top", .number, .number(0), min: 0, max: 0.95, "Fraction removed from the top"),
        ParamSpec("transform.crop.right", .number, .number(0), min: 0, max: 0.95, "Fraction removed from the right"),
        ParamSpec("transform.crop.bottom", .number, .number(0), min: 0, max: 0.95, "Fraction removed from the bottom"),
        ParamSpec("blend", .choice(BlendMode.allCases.map(\.rawValue)), .string("normal"), "How the picture combines with the layers below"),
        ParamSpec("fade.in", .number, .number(0), min: 0, unit: "seconds", animatable: false, "Picture fade-in"),
        ParamSpec("fade.out", .number, .number(0), min: 0, unit: "seconds", animatable: false, "Picture fade-out"),
        ParamSpec("name", .text, .string(""), "Label shown in the preview timeline"),
    ]

    static let timeSpecs: [ParamSpec] = [
        ParamSpec("time.speed", .number, .number(1), min: 0, max: 100, unit: "×", "Playback speed; animate it for speed ramps (0 holds a frame). The clip keeps its timeline length, so the source range it uses grows or shrinks"),
        ParamSpec("time.reverse", .bool, .bool(false), "Play the clip backwards"),
        ParamSpec("input.tone", .choice(ToneMap.allCases.map(\.rawValue)), .string("aces"), "For log footage: how scene light is mapped to the display (aces: ACES 1.3 output transform as in Resolve; aces_fit: lighter ACES approximation; hable; reinhard; none)"),
        ParamSpec("input.exposure", .number, .number(0), min: -6, max: 6, unit: "stops", animatable: false, "For log footage: exposure before the tone map"),
        ParamSpec("time.interpolate", .choice(["none", "blend", "flow"]), .string("none"), "Smooth slow motion: blend mixes neighbouring frames, flow synthesizes new ones with optical flow (rendered once, cached)"),
    ]

    static let audioSpecs: [ParamSpec] = [
        ParamSpec("audio.volume", .number, .number(1), min: 0, max: 4, unit: "gain", "1 unchanged, 0 silent, 2 is about +6 dB"),
        ParamSpec("audio.fade_in", .number, .number(0), min: 0, unit: "seconds", animatable: false, "Audio fade-in"),
        ParamSpec("audio.fade_out", .number, .number(0), min: 0, unit: "seconds", animatable: false, "Audio fade-out"),
        ParamSpec("audio.lead", .number, .number(0), min: -30, max: 30, unit: "seconds", animatable: false, "J cut: sound starts this long before the picture (negative: later)"),
        ParamSpec("audio.lag", .number, .number(0), min: -30, max: 30, unit: "seconds", animatable: false, "L cut: sound continues this long after the picture (negative: ends earlier)"),
        ParamSpec("audio.channels", .text, .string("stereo"), animatable: false, "Which recorded channels play: stereo is the first track as recorded; left or right alone on both sides (pick the lav or the boom of a two-mic file), mono_mix sums them, swap exchanges them; \"ch3\" plays any source channel on both sides, \"ch3+ch4\" a pair as left and right, \"mix:1,3\" sums channels at 1/n. Channels count across all of the file's audio tracks (media_list shows them)"),
        ParamSpec("audio.role", .text, .string(""), animatable: false, "Audio role of this clip for stems, overriding its track's: \"role.subrole\" (e.g. \"dialogue.room tone\", what room_tone sets) stays in its main role's stem, a plain name (e.g. \"ambience\") gets its own; empty follows the track"),
    ] + Clip.surroundSpecs

    /// Used when the master layout is 5.1 or 7.1.
    public static let surroundSpecs: [ParamSpec] = [
        ParamSpec("audio.pan_x", .number, .number(0), min: -1, max: 1, "Surround position: -1 left … 1 right; stereo sources keep their width (left channel at pan_x−1, right at pan_x+1)"),
        ParamSpec("audio.pan_y", .number, .number(1), min: -1, max: 1, "Surround position: 1 front … -1 back; 0 is the side, the middle (0, 0) spreads to every speaker"),
        ParamSpec("audio.center", .number, .number(1), min: 0, max: 1, "Share of a front-center image on the C speaker; 0 makes a phantom center from L and R"),
        ParamSpec("audio.lfe", .number, .number(0), min: 0, max: 1, "Send to the LFE channel, low-passed at 120 Hz"),
    ]

    static let textSpecs: [ParamSpec] = [
        ParamSpec("text.text", .text, .string(""), "The words; \\n breaks lines"),
        ParamSpec("text.font", .text, .string("system"), "system, rounded, serif, mono, or an installed family"),
        ParamSpec("text.size", .number, .number(0.07), min: 0.005, max: 1, unit: "of the shorter canvas side", "Font size"),
        ParamSpec("text.weight", .number, .number(700), min: 100, max: 900, animatable: false, "Font weight"),
        ParamSpec("text.color", .color, .string("#FFFFFF"), "Fill color"),
        ParamSpec("text.background", .color, .string("none"), "Box behind the text, or none"),
        ParamSpec("text.stroke", .color, .string("none"), "Outline color, or none"),
        ParamSpec("text.stroke_width", .number, .number(0), min: 0, max: 0.5, unit: "of font size", "Outline width"),
        ParamSpec("text.shadow", .bool, .bool(true), "Soft drop shadow"),
        ParamSpec("text.align", .choice(TextAlign.allCases.map(\.rawValue)), .string("center"), "Line alignment"),
        ParamSpec("text.x", .number, .number(0.5), min: -1, max: 2, "Center of the text box, 0 left to 1 right"),
        ParamSpec("text.y", .number, .number(0.5), min: -1, max: 2, "Center of the text box, 0 top to 1 bottom"),
        ParamSpec("text.max_width", .number, .number(0.85), min: 0.05, max: 2, unit: "of frame width", "Wrap width"),
        ParamSpec("text.letter_spacing", .number, .number(0), min: -0.2, max: 2, unit: "of font size", "Extra space between letters"),
        ParamSpec("text.animation_in", .choice(TextAnimation.allCases.map(\.rawValue)), .string("fade"), "Entrance preset"),
        ParamSpec("text.animation_out", .choice(TextAnimation.allCases.map(\.rawValue)), .string("fade"), "Exit preset"),
    ]

    static let solidSpecs: [ParamSpec] = [
        ParamSpec("color", .color, .string("#000000"), "Fill color"),
    ]

    /// The fixed (non-effect) parameters this clip has.
    public var fixedSpecs: [ParamSpec] {
        switch kind {
        case .media: return Clip.transformSpecs + Clip.timeSpecs + Clip.audioSpecs + (raw == nil ? [] : CameraRaw.specs)
        case .text: return Clip.transformSpecs + Clip.textSpecs
        case .solid: return Clip.transformSpecs + Clip.solidSpecs
        case .adjustment: return Clip.transformSpecs.filter { $0.name == "transform.opacity" || $0.name.hasPrefix("fade.") || $0.name == "name" }
        case .generator: return Clip.transformSpecs.filter { $0.name != "transform.fit" && !$0.name.hasPrefix("transform.crop") }
        case .sequence: return Clip.transformSpecs.filter { $0.name != "transform.fit" && !$0.name.hasPrefix("transform.crop") } + Clip.audioSpecs.filter { $0.name == "audio.volume" } + Clip.surroundSpecs
        }
    }

    /// Accepts "opacity" for "transform.opacity" and "scale" for "transform.scale".
    public static func canonical(_ path: String) -> String {
        let aliases = ["transform.rotate_z": "transform.rotation", "z": "transform.z", "opacity": "transform.opacity", "scale": "transform.scale", "x": "transform.x", "y": "transform.y", "rotation": "transform.rotation", "fit": "transform.fit", "volume": "audio.volume"]
        return aliases[path] ?? path
    }

    public func spec(_ rawPath: String) throws -> ParamSpec {
        let path = Clip.canonical(rawPath)
        if path.hasPrefix("fx.") {
            let parts = path.split(separator: ".", maxSplits: 2).map(String.init)
            guard parts.count == 3 else { throw EditError("Effect paths look like fx.<effect id>.<param>, got \(path)") }
            guard let e = effect(parts[1]) else {
                throw EditError("\(id) has no effect \(parts[1]). Effects: \(effects.map(\.id).joined(separator: ", ").ifEmpty("none")). Add one with effect_add.")
            }
            return try Clip.effectSpec(e, param: parts[2], path: path)
        }
        if let s = fixedSpecs.first(where: { $0.name == path }) { return s }
        if kind == .media, let s = CameraRaw.specs.first(where: { $0.name == path }) { return s }
        let names = fixedSpecs.map(\.name)
        let guess = names.min { editDistance($0, path) < editDistance($1, path) } ?? ""
        throw EditError("\(kind.rawValue) clips have no parameter \(path). Did you mean \(guess)? Call project_status with target \(id) for the full list.")
    }

    static func effectSpec(_ e: Effect, param: String, path: String) throws -> ParamSpec {
        if param == "mix" { return ParamSpec(path, .number, .number(1), min: 0, max: 1, "Blend between original (0) and full effect (1)") }
        if param == "enabled" { return ParamSpec(path, .bool, .bool(true), "Turn the effect on or off") }
        guard let type = EffectCatalog.type(e.type) else { throw EditError("Unknown effect type \(e.type)") }
        guard var s = type.spec(param) ?? GeneratorCatalog.spec(type: e.type, name: param, params: e.params) else {
            let shapes = e.type == "shape" ? " Shape properties are <shape id>.<property> with ids \(((try? ShapeLayers.parse(e.params["shapes"]?.string ?? "")) ?? []).map(\.id).joined(separator: ", ")) and properties \(ShapeLayers.props.map(\.name).joined(separator: ", "))." : ""
            throw EditError("\(e.type) has no parameter \(param). Parameters: \((type.params.map(\.name) + ["mix", "enabled"]).joined(separator: ", ")).\(shapes)")
        }
        s.name = path
        return s
    }

    /// The value set on the clip, ignoring animation.
    public func staticValue(_ rawPath: String) -> ParamValue? {
        let path = Clip.canonical(rawPath)
        if path.hasPrefix("fx.") {
            let parts = path.split(separator: ".", maxSplits: 2).map(String.init)
            guard parts.count == 3, let e = effect(parts[1]) else { return nil }
            switch parts[2] {
            case "mix": return .number(e.mix)
            case "enabled": return .bool(e.enabled)
            default: return e.params[parts[2]] ?? GeneratorCatalog.defaultValue(type: e.type, name: parts[2], params: e.params) ?? EffectCatalog.type(e.type)?.spec(parts[2])?.defaultValue
            }
        }
        let t = transform
        switch path {
        case "transform.fit": return .string(t.fit.rawValue)
        case "transform.scale": return .number(t.scale)
        case "transform.x": return .number(t.x)
        case "transform.y": return .number(t.y)
        case "transform.rotation": return .number(t.rotation)
        case "transform.opacity": return .number(t.opacity)
        case "transform.crop.left": return .number(t.crop.left)
        case "transform.crop.top": return .number(t.crop.top)
        case "transform.crop.right": return .number(t.crop.right)
        case "transform.crop.bottom": return .number(t.crop.bottom)
        case "blend": return .string(blend.rawValue)
        case "fade.in": return .number(fadeIn)
        case "fade.out": return .number(fadeOut)
        case "name": return .string(name ?? "")
        case "audio.volume": return .number(volume)
        case "audio.fade_in": return .number(audioFadeIn)
        case "audio.fade_out": return .number(audioFadeOut)
        case "transform.anchor_x": return .number(transform.anchorX)
        case "transform.anchor_y": return .number(transform.anchorY)
        case "transform.rotate_x": return .number(transform.rotateX)
        case "transform.rotate_y": return .number(transform.rotateY)
        case "transform.perspective": return .number(transform.perspective)
        case "transform.3d": return .bool(transform.threeD)
        case "transform.z": return .number(transform.z)
        case "transform.motion_blur": return .number(transform.motionBlur)
        case "time.speed": return .number(speed)
        case "time.reverse": return .bool(reverse)
        case "input.tone": return .string((inputTone ?? .aces).rawValue)
        case "input.exposure": return .number(inputExposure ?? 0)
        case "time.interpolate": return .string(interpolate ?? "none")
        case "audio.lead": return .number(audioLead)
        case "audio.lag": return .number(audioLag)
        case "audio.channels": return .string((channels ?? .stereo).rawValue)
        case "audio.role": return .string(role ?? "")
        case "audio.pan_x": return .number((surround ?? .standard).x)
        case "audio.pan_y": return .number((surround ?? .standard).y)
        case "audio.center": return .number((surround ?? .standard).center)
        case "audio.lfe": return .number((surround ?? .standard).lfe)
        case "color": return .string((color ?? .black).hex)
        default: break
        }
        if path.hasPrefix("raw.") { return kind == .media ? CameraRaw.value(raw, path) : nil }
        guard path.hasPrefix("text."), let s = text else { return nil }
        switch path {
        case "text.text": return .string(s.text)
        case "text.font": return .string(s.font)
        case "text.size": return .number(s.size)
        case "text.weight": return .number(Double(s.weight))
        case "text.color": return .string(s.color.hex)
        case "text.background": return .string(s.background?.hex ?? "none")
        case "text.stroke": return .string(s.stroke?.hex ?? "none")
        case "text.stroke_width": return .number(s.strokeWidth)
        case "text.shadow": return .bool(s.shadow)
        case "text.align": return .string(s.align.rawValue)
        case "text.x": return .number(s.x)
        case "text.y": return .number(s.y)
        case "text.max_width": return .number(s.maxWidth)
        case "text.letter_spacing": return .number(s.letterSpacing)
        case "text.animation_in": return .string(s.animationIn.rawValue)
        case "text.animation_out": return .string(s.animationOut.rawValue)
        default: return nil
        }
    }

    /// The value at a time from the clip start, with animation applied.
    public func value(_ path: String, at local: Seconds) -> ParamValue? {
        let p = Clip.canonical(path)
        return anim[p]?.value(at: local) ?? staticValue(p)
    }

    public func number(_ path: String, at local: Seconds, default d: Double = 0) -> Double {
        value(path, at: local)?.number ?? d
    }

    /// Validates and sets a static value. Animation on the same path is kept and still wins.
    public mutating func set(_ rawPath: String, _ raw: ParamValue) throws {
        let path = Clip.canonical(rawPath)
        let spec = try spec(path)
        let clearsColor = spec.kind == .color && (raw.string?.lowercased() == "none") && (path == "text.background" || path == "text.stroke")
        let v = clearsColor ? raw : try spec.validate(raw, path: path)
        if path.hasPrefix("fx.") {
            let parts = path.split(separator: ".", maxSplits: 2).map(String.init)
            guard let i = effects.firstIndex(where: { $0.id == parts[1] }) else { return }
            switch parts[2] {
            case "mix": effects[i].mix = v.number ?? 1
            case "enabled": effects[i].enabled = v.bool ?? true
            default:
                try Effect.checkResource(type: effects[i].type, param: parts[2], value: v)
                effects[i].params[parts[2]] = v
            }
            return
        }
        let n = v.number ?? 0
        switch path {
        case "transform.fit": transform.fit = FitMode(rawValue: v.string ?? "") ?? .fit
        case "transform.scale": transform.scale = n
        case "transform.x": transform.x = n
        case "transform.y": transform.y = n
        case "transform.rotation": transform.rotation = n
        case "transform.opacity": transform.opacity = n
        case "transform.anchor_x": transform.anchorX = n
        case "transform.anchor_y": transform.anchorY = n
        case "transform.rotate_x": transform.rotateX = n
        case "transform.rotate_y": transform.rotateY = n
        case "transform.perspective": transform.perspective = n
        case "transform.3d": transform.threeD = v.bool ?? false
        case "transform.z": transform.z = n
        case "transform.motion_blur": transform.motionBlur = n
        case "transform.crop.left": transform.crop.left = n
        case "transform.crop.top": transform.crop.top = n
        case "transform.crop.right": transform.crop.right = n
        case "transform.crop.bottom": transform.crop.bottom = n
        case "blend": blend = BlendMode(rawValue: v.string ?? "") ?? .normal
        case "fade.in": fadeIn = min(n, duration)
        case "fade.out": fadeOut = min(n, duration)
        case "name": name = v.string
        case "audio.volume": volume = n
        case "audio.fade_in": audioFadeIn = min(n, duration)
        case "audio.fade_out": audioFadeOut = min(n, duration)
        case "time.speed":
            guard n >= 0.01 else { throw EditError("A constant speed must be at least 0.01; animate time.speed to 0 to hold a frame, or use recipe freeze_frame") }
            speed = n
        case "time.reverse": reverse = v.bool ?? false
        case "input.tone": inputTone = ToneMap(rawValue: v.string ?? "")
        case "input.exposure": inputExposure = n
        case "time.interpolate": interpolate = v.string == "none" ? nil : v.string
        case "audio.lead": audioLead = n
        case "audio.lag": audioLag = n
        case "audio.channels":
            guard let routing = ChannelRouting(rawValue: v.string ?? "") else { throw EditError("audio.channels is \(ChannelRouting.help); got \(v)") }
            channels = routing == .stereo ? nil : routing
        case "audio.role":
            let r = (v.string ?? "").trimmingCharacters(in: .whitespaces)
            role = r.isEmpty ? nil : r
        case "audio.pan_x", "audio.pan_y", "audio.center", "audio.lfe":
            var s = surround ?? .standard
            switch path {
            case "audio.pan_x": s.x = n
            case "audio.pan_y": s.y = n
            case "audio.center": s.center = n
            default: s.lfe = n
            }
            surround = s == .standard ? nil : s
        case "color": color = v.color
        case _ where path.hasPrefix("raw."): CameraRaw.set(&self.raw, path, n)
        default:
            guard path.hasPrefix("text."), var s = text else { throw EditError("Cannot set \(path) on \(id)") }
            switch path {
            case "text.text": s.text = v.string ?? ""
            case "text.font": s.font = v.string ?? "system"
            case "text.size": s.size = n
            case "text.weight": s.weight = Int(n)
            case "text.color": s.color = v.color ?? .white
            case "text.background": s.background = v.color
            case "text.stroke":
                s.stroke = v.color
                if s.stroke != nil && s.strokeWidth == 0 { s.strokeWidth = 0.08 }
            case "text.stroke_width": s.strokeWidth = n
            case "text.shadow": s.shadow = v.bool ?? true
            case "text.align": s.align = TextAlign(rawValue: v.string ?? "") ?? .center
            case "text.x": s.x = n
            case "text.y": s.y = n
            case "text.max_width": s.maxWidth = n
            case "text.letter_spacing": s.letterSpacing = n
            case "text.animation_in": s.animationIn = TextAnimation(rawValue: v.string ?? "") ?? .none
            case "text.animation_out": s.animationOut = TextAnimation(rawValue: v.string ?? "") ?? .none
            default: throw EditError("Cannot set \(path) on \(id)")
            }
            text = s
        }
    }

    /// Replaces the animation on a path. Key times are seconds from the clip start.
    public mutating func animate(_ rawPath: String, keys: [CurveKey]) throws {
        let path = Clip.canonical(rawPath)
        let spec = try spec(path)
        guard spec.animatable else { throw EditError("\(path) can't be animated; set it with set instead") }
        guard !keys.isEmpty else { anim[path] = nil; return }
        var checked: [CurveKey] = []
        for k in keys {
            var k = k
            k.v = try spec.validate(k.v, path: path)
            checked.append(k)
        }
        anim[path] = Curve(keys: checked)
    }

    /// Text styling at a time from the clip start, with animated values applied.
    public func resolvedText(at local: Seconds) -> TextSpec? {
        guard var s = text else { return nil }
        guard anim.keys.contains(where: { $0.hasPrefix("text.") }) else { return s }
        func num(_ p: String) -> Double? { anim[p]?.value(at: local)?.number }
        func col(_ p: String) -> RGBA? { anim[p]?.value(at: local)?.color }
        if let v = num("text.size") { s.size = v }
        if let v = num("text.x") { s.x = v }
        if let v = num("text.y") { s.y = v }
        if let v = num("text.max_width") { s.maxWidth = v }
        if let v = num("text.letter_spacing") { s.letterSpacing = v }
        if let v = num("text.stroke_width") { s.strokeWidth = v }
        if let v = col("text.color") { s.color = v }
        if let v = col("text.background") { s.background = v }
        if let v = col("text.stroke") { s.stroke = v }
        return s
    }

    /// Every parameter with its current value, for describing a clip to an agent.
    public func parameterTree() -> [(path: String, value: ParamValue, animated: Int)] {
        var out: [(String, ParamValue, Int)] = []
        for s in fixedSpecs {
            if let v = staticValue(s.name) { out.append((s.name, v, anim[s.name]?.keys.count ?? 0)) }
        }
        for e in effects {
            out.append(("fx.\(e.id).mix", .number(e.mix), anim["fx.\(e.id).mix"]?.keys.count ?? 0))
            if !e.enabled { out.append(("fx.\(e.id).enabled", .bool(false), 0)) }
            // Qualifier and node parameters are listed once the effect uses them.
            let qualified = (e.params["limit"]?.string ?? "").contains("qualifier")
            let noded = e.params.keys.contains { $0.hasPrefix("node") }
            for p in EffectCatalog.type(e.type)?.params ?? [] {
                let path = "fx.\(e.id).\(p.name)"
                let set = e.params[p.name] != nil || anim[path] != nil
                if !set && ((p.name.hasPrefix("q_") && !qualified) || (p.name.hasPrefix("node") && !noded)) { continue }
                out.append((path, e.params[p.name] ?? p.defaultValue, anim[path]?.keys.count ?? 0))
            }
            if e.type == "shape" {
                for (name, v) in ShapeLayers.names(shapes: e.params["shapes"]?.string ?? GeneratorCatalog.defaultShapes) where e.params[name] != nil || anim["fx.\(e.id).\(name)"] != nil {
                    out.append(("fx.\(e.id).\(name)", e.params[name] ?? v, anim["fx.\(e.id).\(name)"]?.keys.count ?? 0))
                }
            }
        }
        return out
    }

    /// Removes an effect and any animation of its parameters.
    public mutating func removeEffect(_ effectId: String) throws {
        guard let i = effects.firstIndex(where: { $0.id == effectId }) else { throw EditError("\(id) has no effect \(effectId)") }
        effects.remove(at: i)
        for key in anim.keys where key.hasPrefix("fx.\(effectId).") { anim[key] = nil }
    }

    /// A short unused id such as "blur1" for a new effect of this type.
    public func nextEffectId(_ type: String) -> String {
        let base = EffectCatalog.shortName(type)
        var n = 1
        while effects.contains(where: { $0.id == "\(base)\(n)" }) { n += 1 }
        return "\(base)\(n)"
    }
}

extension Track {
    public static let specs: [ParamSpec] = [
        ParamSpec("volume", .number, .number(1), min: 0, max: 4, unit: "gain", animatable: false, "Multiplies every clip's volume on the track"),
        ParamSpec("muted", .bool, .bool(false), "Silence the track"),
        ParamSpec("hidden", .bool, .bool(false), "Hide the track's picture"),
        ParamSpec("name", .text, .string(""), "Track name"),
    ]

    public func spec(_ path: String) throws -> ParamSpec {
        if path.hasPrefix("fx.") {
            let parts = path.split(separator: ".", maxSplits: 2).map(String.init)
            guard parts.count == 3, let e = effects.first(where: { $0.id == parts[1] }) else { throw EditError("Track \(id) has no effect at \(path)") }
            return try Clip.effectSpec(e, param: parts[2], path: path)
        }
        guard let s = Track.specs.first(where: { $0.name == path }) else {
            throw EditError("Tracks have \(Track.specs.map(\.name).joined(separator: ", ")) and fx.<id>.<param>; got \(path)")
        }
        return s
    }

    public mutating func set(_ path: String, _ raw: ParamValue) throws {
        let v = try spec(path).validate(raw, path: path)
        if path.hasPrefix("fx.") {
            let parts = path.split(separator: ".", maxSplits: 2).map(String.init)
            guard let i = effects.firstIndex(where: { $0.id == parts[1] }) else { return }
            switch parts[2] {
            case "mix": effects[i].mix = v.number ?? 1
            case "enabled": effects[i].enabled = v.bool ?? true
            default:
                try Effect.checkResource(type: effects[i].type, param: parts[2], value: v)
                effects[i].params[parts[2]] = v
            }
            return
        }
        switch path {
        case "volume": volume = v.number ?? 1
        case "muted": muted = v.bool ?? false
        case "hidden": hidden = v.bool ?? false
        case "name": name = v.string ?? name
        default: break
        }
    }

    public func nextEffectId(_ type: String) -> String {
        let base = EffectCatalog.shortName(type)
        var n = 1
        while effects.contains(where: { $0.id == "\(base)\(n)" }) { n += 1 }
        return "\(base)\(n)"
    }
}

extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}

public func editDistance(_ a: String, _ b: String) -> Int {
    let a = Array(a), b = Array(b)
    guard !a.isEmpty else { return b.count }
    guard !b.isEmpty else { return a.count }
    var prev = Array(0...b.count)
    for i in 1...a.count {
        var cur = [i] + Array(repeating: 0, count: b.count)
        for j in 1...b.count {
            cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
        }
        prev = cur
    }
    return prev[b.count]
}

extension Effect {
    /// Checks parameters that are only meaningful once parsed or loaded: curve strings and LUT files.
    public static func checkResource(type: String, param: String, value: ParamValue) throws {
        guard let s = value.string, !s.isEmpty else { return }
        switch (type, param) {
        case ("color.curves", _):
            _ = try ColorMath.curves(master: s, red: nil, green: nil, blue: nil)
        case ("color.hue_curves", _):
            if let f = HueCurves.Family(rawValue: param) { _ = try HueCurves { $0 == f ? s : nil } }
        case ("shape", "shapes"):
            _ = try ShapeLayers.parse(s)
        case ("particles", "image"):
            guard FileManager.default.fileExists(atPath: s) else { throw EditError("No image file \(s)") }
        case ("color.lut", "file"):
            guard let text = try? String(contentsOfFile: s, encoding: .utf8) else { throw EditError("Cannot read LUT file \(s)") }
            _ = try ColorMath.parseCube(text)
        default:
            break
        }
    }
}
