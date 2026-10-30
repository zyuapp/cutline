import Foundation

/// Timeline files other editors read.
public enum InterchangeFormat: String, CaseIterable, Sendable {
    case otio, fcpxml, edl, xml

    public var title: String {
        switch self {
        case .otio: "OpenTimelineIO"
        case .fcpxml: "FCPXML"
        case .edl: "CMX 3600 EDL"
        case .xml: "Final Cut Pro 7 XML"
        }
    }
}

/// Files made beside an interchange export for what its format can't draw or grade.
public struct InterchangeOptions: Sendable {
    /// Clip id → a ProRes 4444 with alpha of that clip, rendered full frame, referenced as media in its place.
    public var graphics: [String: String]
    /// Clip id → a .cube of the clip's whole color stack, named in its note or comment for a colorist to load.
    public var luts: [String: String]
    /// Where graphics that weren't rendered would be; their offline placeholders point there.
    public var graphicsFolder: String

    public init(graphics: [String: String] = [:], luts: [String: String] = [:], graphicsFolder: String = "") {
        self.graphics = graphics
        self.luts = luts
        self.graphicsFolder = graphicsFolder
    }
}

/// An interchange file and what it couldn't carry.
public struct InterchangeExport: Sendable {
    public var data: Data
    /// One line per loss, most naming the clip: "clip_x title.card → exported as a Basic Title with its text; animation lost".
    public var notes: [String]

    /// The notes file written beside the export.
    public func notesText(project: String, format: InterchangeFormat) -> String {
        let head = "\(format.title) export of \(project): " + (notes.isEmpty ? "everything on the timeline is carried." : "\(notes.count) thing(s) the format can't carry exactly.")
        return ([head, ""] + notes.map { "- " + $0 }).joined(separator: "\n") + "\n"
    }
}

/// What writers need beyond the project: clips replaced for the export, by id, and baked grades.
struct InterchangeContext {
    /// Clips as they are in the project, for those the export writes as something else (a title, baked or offline graphics).
    var originals: [String: Clip] = [:]
    var luts: [String: String] = [:]

    /// The Cutline clip a writer embeds for Cutline to read back, when the format can't carry it.
    func embedded(_ c: Clip) -> Clip? {
        if let o = originals[c.id] { return o }
        return c.kind == .text || c.kind == .solid || c.kind == .generator ? c : nil
    }
}

extension Project {
    /// The prefix of Cutline's clip JSON in comments and metadata.
    static let clipTag = "Cutline clip "
    /// FCPXML metadata key holding Cutline's clip JSON.
    static let fcpClipKey = "com.cutline.clip"
    /// Names a .cube holding a clip's whole grade in notes and comments: "GRADE LUT <path>".
    static let gradeLUTTag = "GRADE LUT"

    static func clipJSON(_ c: Clip) -> String {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? e.encode(c)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    /// A clip from Cutline's JSON, placed like `placed` (its id, start and length).
    static func restoredClip(json: String, placed: Clip) -> Clip? {
        let body = json.hasPrefix(clipTag) ? String(json.dropFirst(clipTag.count)) : json
        guard var c = try? JSONDecoder().decode(Clip.self, from: Data(body.utf8)) else { return nil }
        c.id = placed.id
        c.start = placed.start
        c.duration = placed.duration
        return c
    }

    /// Writes `format` with what `options` made for it.
    public func interchange(_ format: InterchangeFormat, options: InterchangeOptions = InterchangeOptions()) throws -> InterchangeExport {
        let (p, ctx) = prepared(for: format, options: options)
        let data: Data
        switch format {
        case .otio: data = try p.otio(ctx)
        case .fcpxml: data = Data(p.fcpxml(ctx).utf8)
        case .edl: data = Data(p.edl(title: name, ctx).utf8)
        case .xml: data = Data(p.xmeml(ctx).utf8)
        }
        return InterchangeExport(data: data, notes: interchangeLosses(format, options: options))
    }

    // MARK: Graphics

    /// Generator clips, on the timeline and in nested sequences, with the timeline or sequence that holds them.
    public var generatorClips: [(clip: Clip, scope: Project)] {
        tracks.flatMap { t in t.kind == .video ? t.clips.filter { $0.kind == .generator }.map { ($0, self) } : [] }
            + sequences.flatMap { s in
                let scope = inside(s)
                return s.tracks.flatMap { t in t.kind == .video ? t.clips.filter { $0.kind == .generator }.map { ($0, scope) } : [] }
            }
    }

    /// The clip alone on a transparent frame from time zero, for rendering it as a graphic with alpha.
    public func isolating(_ clipId: String) -> Project? {
        guard var c = clip(clipId), c.kind != .media || tracks.contains(where: { $0.kind == .video && $0.clips.contains { $0.id == clipId } }) else { return nil }
        var p = self
        c.start = 0
        p.canvas.background = RGBA(r: 0, g: 0, b: 0, a: 0)
        p.tracks = [Track(id: "V1", kind: .video, name: "Graphic", clips: [c])]
        p.transitions = []
        p.markers = []
        p.captions.enabled = false
        return p
    }

    /// The words a generator shows, as a title for targets that only have titles.
    static func titleSpec(_ c: Clip) -> TextSpec? {
        guard let gen = c.effects.first(where: { GeneratorCatalog.type($0.type) != nil }) else { return nil }
        let frame = 1.0 / 30
        guard let words = c.generatorText(at: c.duration / 2) ?? c.generatorText(at: max(0, c.duration - frame)) else { return nil }
        var spec = TextSpec(text: words.text, size: max(words.size, 0.01), color: words.color, background: words.background, shadow: false, y: words.y,
                            animationIn: .none, animationOut: .none)
        spec.font = c.generatorValue("font", at: 0)?.string ?? "system"
        let x = c.generatorValue("x", at: 0)?.number ?? 0.5
        if gen.type.contains("lower_third") || gen.type == "callout" {
            spec.align = .left
            spec.maxWidth = 0.5
            spec.x = gen.type == "callout" ? c.generatorValue("label_x", at: 0)?.number ?? 0.3 : x + spec.maxWidth / 2
        } else {
            spec.x = x
        }
        return spec
    }

    /// The project as `format` is written: generators become baked graphics, titles, or offline placeholders
    /// (OTIO keeps them, with all their settings in Cutline metadata, unless baked).
    func prepared(for format: InterchangeFormat, options: InterchangeOptions) -> (Project, InterchangeContext) {
        var p = self
        var ctx = InterchangeContext(luts: options.luts)
        var added: [MediaAsset] = []
        func graphicAsset(_ c: Clip, path: String) -> String {
            let id = "graphic-" + Importer.slug(c.id)
            if !added.contains(where: { $0.id == id }) {
                added.append(MediaAsset(id: id, path: path, name: (path as NSString).deletingPathExtension.components(separatedBy: "/").last ?? id,
                                          duration: c.duration, width: canvas.width, height: canvas.height, fps: canvas.fps, hasVideo: true, hasAudio: false))
            }
            return id
        }
        func convert(_ tracks: inout [Track]) {
            for t in tracks.indices where tracks[t].kind == .video {
                for i in tracks[t].clips.indices where tracks[t].clips[i].kind == .generator {
                    let c = tracks[t].clips[i]
                    var made: Clip
                    if let file = options.graphics[c.id] {
                        made = Clip(id: c.id, kind: .media, name: c.name ?? Project.graphicName(c), mediaId: graphicAsset(c, path: file), start: c.start, duration: c.duration)
                        made.volume = 0
                    } else if format == .otio {
                        continue
                    } else if let spec = Project.titleSpec(c) {
                        made = Clip(id: c.id, kind: .text, name: c.name ?? Project.graphicName(c), start: c.start, duration: c.duration, transform: c.transform, text: spec)
                    } else {
                        let folder = options.graphicsFolder.isEmpty ? "Graphics" : options.graphicsFolder
                        made = Clip(id: c.id, kind: .media, name: c.name ?? Project.graphicName(c),
                                    mediaId: graphicAsset(c, path: (folder as NSString).appendingPathComponent(Project.safeFileName(c.id) + ".mov")), start: c.start, duration: c.duration)
                        made.volume = 0
                    }
                    made.link = c.link
                    ctx.originals[c.id] = c
                    tracks[t].clips[i] = made
                }
            }
        }
        convert(&p.tracks)
        for s in p.sequences.indices { convert(&p.sequences[s].tracks) }
        p.media += added
        return (p, ctx)
    }

    /// "title.card", "shape", … : the generator a clip draws.
    static func graphicName(_ c: Clip) -> String {
        c.effects.first(where: { GeneratorCatalog.type($0.type) != nil })?.type ?? c.kind.rawValue
    }

    // MARK: Grades

    /// Every enabled color effect of the clip that a 3D LUT can hold, in order: primaries, HSL, monochrome, invert,
    /// and qualified (not windowed) corrections, at their static values.
    func colorStack(_ c: Clip) -> [Effect] {
        c.effects.filter { e in
            guard e.enabled, e.mix > 0, EffectCatalog.type(e.type)?.category == "color" else { return false }
            let limit = e.params["limit"]?.string ?? "none"
            return limit == "none" || limit == "qualifier"
        }
    }

    /// The clip's whole color stack as one transform, or nil when it has none.
    public func colorStackTransform(_ c: Clip) -> ColorMath.Transform? {
        let fs: [ColorMath.Transform] = colorStack(c).compactMap { e in
            var f: ColorMath.Transform?
            switch e.type {
            case "color.hsl":
                f = try? ColorMath.hsl(range: e.params["range"]?.string ?? "blues", hue: Float(CDL.param(e, "hue")), saturation: Float(CDL.param(e, "saturation")),
                                       lightness: Float(CDL.param(e, "lightness")))
                f = f.map { ColorMath.blend($0, amount: Float(e.mix)) }
            case "color.monochrome":
                let tint = (e.params["color"] ?? .string("#FFFFFF")).color ?? .white
                let amount = Float(e.params["amount"]?.number ?? 1)
                let k = SIMD3<Float>(Float(tint.r), Float(tint.g), Float(tint.b))
                f = ColorMath.blend({ c in SIMD3(repeating: ColorMath.luma(c)) * k }, amount: amount * Float(e.mix))
            case "color.invert":
                f = ColorMath.blend({ c in 1 - c }, amount: Float(e.mix))
            default:
                f = CDL.transform(e)
            }
            guard let g = f else { return nil }
            if (e.params["limit"]?.string ?? "none") == "qualifier" {
                let q = Qualifier(params: e.params)
                return { c in let w = q.weight(c); return c + (g(c) - c) * w }
            }
            return g
        }
        guard !fs.isEmpty else { return nil }
        return { c in fs.reduce(c) { $1($0) } }
    }

    /// A `size`³ .cube of the clip's whole color stack, or nil when it has none.
    public func bakedLUT(_ c: Clip, size: Int = 33) -> String? {
        guard let f = colorStackTransform(c) else { return nil }
        let rgba = ColorMath.cubeData(size: size, f)
        var text = "TITLE \"\(c.name ?? c.id) grade\"\n# Cutline color stack: \(colorStack(c).map(\.type).joined(separator: ", "))\nLUT_3D_SIZE \(size)\n"
        text.reserveCapacity(size * size * size * 28)
        for i in 0..<(size * size * size) {
            text += String(format: "%.6f %.6f %.6f\n", rgba[i * 4], rgba[i * 4 + 1], rgba[i * 4 + 2])
        }
        return text
    }

    /// Clips whose color stack a baked LUT would hold, on the timeline and in nested sequences.
    public var gradedClips: [Clip] {
        (tracks + sequences.flatMap(\.tracks)).filter { $0.kind == .video }.flatMap(\.clips).filter { $0.kind == .media && !colorStack($0).isEmpty }
    }

    // MARK: Losses

    /// What `format` can't carry, clip by clip, as the exporters write it.
    public func interchangeLosses(_ format: InterchangeFormat, options: InterchangeOptions = InterchangeOptions()) -> [String] {
        var out: [String] = []
        let otio = format == .otio, edl = format == .edl, fcp = format == .fcpxml
        let cutlineOnly = otio ? " (kept in Cutline metadata; other apps ignore it)" : ""
        let restores = edl ? "" : "; Cutline reads it back from its metadata"
        func label(_ c: Clip) -> String { c.name.map { "\(c.id) (\($0))" } ?? c.id }

        func clipLosses(_ c: Clip, track: Track, scope: Project) {
            let name = label(c)
            let video = track.kind == .video
            switch c.kind {
            case .generator:
                let type = Project.graphicName(c)
                if let file = options.graphics[c.id] {
                    out.append("\(name) \(type) → rendered to \((file as NSString).lastPathComponent) (ProRes 4444 with alpha) and referenced as media; it no longer changes with its parameters" + restores)
                } else if otio {
                    out.append("\(name) \(type) → a gap with the generator in Cutline metadata; other apps show nothing there (export with render_graphics for a rendered file)")
                } else if let spec = Project.titleSpec(c) {
                    let what = fcp ? "a Basic Title" : edl ? "nothing (EDLs list media only)" : "a Text generator"
                    out.append("\(name) \(type) → " + (edl ? "not in the EDL; render_graphics bakes it to a file the EDL can list" : "exported as \(what) with its text \"\(spec.text.prefix(40))\"; its design and animation lost" + restores))
                } else {
                    out.append("\(name) \(type) → offline placeholder \(Project.safeFileName(c.id)).mov; render_graphics bakes it to that file" + restores)
                }
                return
            case .text:
                guard let t = c.text else { return }
                if edl { out.append("\(name) text \"\(t.text.prefix(40))\" → not in the EDL (EDLs list media only)"); return }
                var lost: [String] = []
                if t.animationIn != .none || t.animationOut != .none || t.animator != nil { lost.append("animation") }
                if t.spans?.isEmpty == false { lost.append("styled spans") }
                if fcp, c.transform != Transform() { lost.append("clip transform") }
                if !otio {
                    if t.background != nil { lost.append("background") }
                    if t.stroke != nil, fcp { lost.append("outline") }
                    if t.shadow { lost.append("shadow") }
                    if t.letterSpacing != 0 { lost.append("letter spacing") }
                }
                if !lost.isEmpty {
                    let what = otio ? "a gap with the title in Cutline metadata" : fcp ? "a Basic Title with text, font, size, color and position" : (t.stroke != nil ? "an Outline Text generator" : "a Text generator") + " with text, font, size, color and position"
                    out.append("\(name) text → \(what); \(lost.joined(separator: ", ")) lost" + (otio ? "" : restores))
                } else if otio {
                    out.append("\(name) text → a gap with the title in Cutline metadata; other apps show nothing there")
                }
            case .solid:
                if edl { out.append("\(name) solid → not in the EDL (EDLs list media only)") }
            case .adjustment:
                let fx = c.effects.map(\.type)
                out.append("\(name) adjustment layer" + (fx.isEmpty ? "" : " (\(fx.joined(separator: ", ")))") + " → " + (otio ? "a gap with its effects in Cutline metadata; other apps don't apply them" : "not carried; its effects don't reach the clips below"))
                return
            case .sequence:
                if edl { out.append("\(name) nested sequence → flattened into the events it plays") }
            case .media:
                break
            }
            guard video else {
                audioLosses(c, name: name)
                return
            }
            // Picture
            var lost: [String] = []
            let t = c.transform
            if edl, t.x != 0 || t.y != 0 || t.scale != 1 || t.rotation != 0 || !t.crop.isEmpty || t.opacity < 1 || t.fit == .fill { lost.append("position, scale, rotation, crop and opacity") }
            if !edl, !otio {
                if t.anchorX != 0.5 || t.anchorY != 0.5 { lost.append("anchor point") }
                if t.rotateX != 0 || t.rotateY != 0 || t.threeD || t.z != 0 { lost.append("3D placement") }
                if t.motionBlur > 0 { lost.append("motion blur") }
                if format == .xml, t.fit == .fill { lost.append("fill conform") }
            }
            if !otio {
                let keyed = c.anim.keys.filter { $0 != "audio.volume" }.sorted()
                if !keyed.isEmpty { lost.append("keyframes on " + keyed.prefix(4).joined(separator: ", ") + (keyed.count > 4 ? ", …" : "")) }
                if c.blend != .normal { lost.append("\(c.blend.rawValue) blend") }
                if c.fadeIn > 0 || c.fadeOut > 0 { lost.append("picture fades") }
                if c.reverse, fcp { lost.append("reverse") }
                if c.interpolate != nil { lost.append("\(c.interpolate!) frame interpolation") }
                if c.inputTone != nil || c.inputExposure != nil { lost.append("log input tone mapping") }
            }
            if !lost.isEmpty { out.append("\(name) → \(lost.joined(separator: ", ")) not carried" + cutlineOnly) }
            if c.kind == .media || c.kind == .sequence { gradeLosses(c, name: name) }
            let other = c.effects.filter { e in
                let cat = EffectCatalog.type(e.type)?.category ?? ""
                return e.enabled && cat != "color" && cat != "generator" && cat != "audio"
            }
            if !other.isEmpty { out.append("\(name) \(other.map(\.type).joined(separator: ", ")) → not carried" + cutlineOnly) }
            if c.kind == .media, let m = c.mediaId.flatMap(scope.mediaAsset), m.hasAudio, !m.isImage { audioLosses(c, name: name) }
        }

        func gradeLosses(_ c: Clip, name: String) {
            let stack = colorStack(c)
            let windowed = c.effects.filter { e in e.enabled && EffectCatalog.type(e.type)?.category == "color" && !["none", "qualifier"].contains(e.params["limit"]?.string ?? "none") }
            for e in windowed { out.append("\(name) \(e.type) limited to a \(e.params["limit"]?.string ?? "window") → not representable; left out of the CDL" + (options.luts[c.id] != nil ? " and the baked LUT" : "")) }
            guard !stack.isEmpty else { return }
            let lut = options.luts[c.id].map { "; whole grade baked to \(($0 as NSString).lastPathComponent)" } ?? ""
            let primary = c.primaryColor
            let exact = stack.count == 1 && primary.count == 1 && primary[0].mix >= 1 && (
                primary[0].type == "color.cdl" || (primary[0].type == "color.grade" && CDL.grade(primary[0]) != nil) || (primary[0].type == "color.wheels" && CDL.wheels(primary[0]) != nil))
            let animated = stack.filter { e in c.anim.keys.contains { $0.hasPrefix("fx.\(e.id).") } }.map(\.type)
            if !animated.isEmpty { out.append("\(name) animated \(animated.joined(separator: ", ")) → carried at its static values") }
            if otio {
                if !exact { out.append("\(name) \(stack.map(\.type).joined(separator: ", ")) → other apps get the CDL approximation in the cdl metadata\(lut); Cutline keeps the effects") }
                return
            }
            if exact {
                if !lut.isEmpty { out.append("\(name) \(stack[0].type) → exact as a CDL\(lut)") }
                return
            }
            let types = stack.map(\.type).joined(separator: " + ")
            let approximate = c.cdl != nil
            let lone = stack.count == 1 && stack[0].type == "color.lut"
            out.append("\(name) \(types) → " + (lone ? "named as its LUT file" : "not representable; " + (approximate ? "CDL approximation" : "no CDL")) + lut + (options.luts.isEmpty && !lone ? " (bake_luts writes the whole grade as a .cube)" : ""))
        }

        func audioLosses(_ c: Clip, name: String) {
            var lost: [String] = []
            let fx = c.effects.filter { $0.enabled && EffectCatalog.type($0.type)?.category == "audio" }.map(\.type)
            if !fx.isEmpty { lost.append(fx.joined(separator: ", ")) }
            if !otio {
                if c.surround != nil { lost.append("surround panning") }
                if c.channels != nil { lost.append("channel routing") }
                if c.role != nil { lost.append("audio role \(c.role!)") }
            }
            if edl, c.anim["audio.volume"] != nil || abs(c.volume - 1) > 1e-6 { lost.append("level") }
            if edl, c.audioFadeIn > 0 || c.audioFadeOut > 0 { lost.append("fades") }
            if !lost.isEmpty { out.append("\(name) sound → \(lost.joined(separator: ", ")) not carried" + cutlineOnly) }
        }

        func scan(_ scope: Project, label prefix: String) {
            var videoIndex = 0, audioIndex = 0
            for track in scope.tracks {
                if track.kind == .video { videoIndex += 1 } else { audioIndex += 1 }
                if edl, prefix.isEmpty, (track.kind == .video && videoIndex > 1) || (track.kind == .audio && audioIndex > 2), !track.clips.isEmpty {
                    out.append("Track \(track.id) (\(track.name), \(track.clips.count) clips) → not in the EDL, which carries the main video track and two audio tracks")
                    continue
                }
                let fx = track.effects.filter(\.enabled).map(\.type)
                if !fx.isEmpty { out.append("\(prefix)Track \(track.id) effects \(fx.joined(separator: ", ")) → not carried" + (otio ? " (their names only in Cutline metadata)" : "")) }
                if track.output != nil || !track.sends.isEmpty { out.append("\(prefix)Track \(track.id) bus routing → not carried; levels fold into the clips") }
                for c in track.clips { clipLosses(c, track: track, scope: scope) }
            }
            for tr in scope.transitions {
                let carried: Set<String> = edl || format == .xml ? ["dissolve", "dip", "wipe"] : fcp ? ["dissolve", "dip"] : Set(TransitionCatalog.all.map(\.id))
                if !carried.contains(tr.type) { out.append("\(prefix)Transition \(tr.id) \(tr.type) → exported as a \(edl || format == .xml ? "dissolve" : "Cross Dissolve")") }
                if !otio, !tr.params.isEmpty { out.append("\(prefix)Transition \(tr.id) \(tr.type) settings → not carried") }
                if edl, tr.align != .start, tr.from != nil, tr.to != nil { out.append("\(prefix)Transition \(tr.id) → starts at its edit in the EDL, so the cut moves to the transition's start") }
            }
        }
        scan(self, label: "")
        for s in sequences {
            scan(inside(s), label: edl ? "Sequence \(s.name) (flattened): " : "Sequence \(s.name): ")
        }
        if captions.enabled { out.append("Captions → not in timeline files; export subtitles (srt, vtt, ttml) beside the video") }
        if !master.effects.isEmpty || master.loudnessTarget != nil { out.append("Master bus processing (\((master.effects.map(\.type) + (master.loudnessTarget != nil ? ["loudness target"] : [])).joined(separator: ", "))) → not carried") }
        if !buses.isEmpty { out.append("\(buses.count) audio bus(es) → not carried; track levels fold into the clips") }
        if edl, !markers.isEmpty, markers.contains(where: { $0.time < 0 }) { out.append("Markers before the program start → not in the EDL") }
        return out
    }
}

extension Project {
    /// A clip id safe as a file name.
    public static func safeFileName(_ s: String) -> String {
        String(s.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" })
    }
}
