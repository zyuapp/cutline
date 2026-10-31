import CutlineCore
import CutlineEngine
import Foundation

extension Toolbox {
    static let setProp: [String: JSON] = [
        "set": ["type": "object", "description": "Initial parameter values by path, e.g. {\"transform.fit\": \"fill\", \"transform.scale\": 1.2, \"audio.volume\": 0.5}. See catalog for paths."],
    ]

    static let textProps: [String: JSON] = [
        "animator": ["type": "object", "description": "Animate each word, letter or line: {unit: word|char|line, preset: pop|fade|slide_up|slide_down|typewriter|blur_in|scale_in|highlight|bounce|wave, stagger: 0.06, duration: 0.35, ease, color (highlight accent), out: preset}. null removes it."],
        "text": Schema.string("The words; \\n for line breaks"),
        "font": Schema.string("system (SF Pro), rounded, serif, mono, or an installed family such as Helvetica Neue, Avenir Next, Futura, Georgia"),
        "size": Schema.number("Font size as a fraction of the canvas's shorter side, e.g. 0.07 title, 0.045 lower third"),
        "weight": Schema.integer("100–900, default 700"),
        "color": Schema.string("Hex text color"),
        "background": Schema.string("Hex box color behind the text, or none"),
        "stroke": Schema.string("Hex outline color, or none"),
        "stroke_width": Schema.number("Outline width as a fraction of font size, e.g. 0.08"),
        "shadow": Schema.bool("Soft drop shadow, default true"),
        "align": Schema.string("Line alignment", values: ["left", "center", "right"]),
        "text_x": Schema.number("Center of the text as a fraction of canvas width from the left, default 0.5"),
        "text_y": Schema.number("Center of the text as a fraction of canvas height from the top, default 0.5"),
        "max_width": Schema.number("Wrap width as a fraction of canvas width, default 0.85"),
        "letter_spacing": Schema.number("Extra spacing as a fraction of font size, e.g. 0.05"),
        "animation_in": Schema.string("Entrance", values: TextAnimation.allCases.map(\.rawValue)),
        "animation_out": Schema.string("Exit", values: TextAnimation.allCases.map(\.rawValue)),
        "spans": Schema.array(Schema.object([
            "match": Schema.string("Restyle every occurrence of this text (case-insensitive)"),
            "text": Schema.string("Same as match"),
            "from": Schema.integer("Or: first character index"),
            "to": Schema.integer("Character index after the last"),
            "color": Schema.string("Hex"),
            "font": Schema.string("Font family"),
            "weight": Schema.integer("100–900"),
            "scale": Schema.number("Size relative to the title, e.g. 1.4"),
            "italic": Schema.bool("Italic"),
            "underline": Schema.bool("Underline"),
            "highlight": Schema.string("Hex marker box behind these characters"),
        ]), "Style parts of the text differently (one word in another color, a bigger name, a highlighted phrase). Replaces existing spans; [] clears. Every span property shows on static and animated titles; text_add warns about spans that match nothing"),
    ]

    func registerEditTools() {
        addEdit(EditTool(name: "clip_add", description: "Put media, a solid color, or an adjustment layer on the timeline. Default track: V1 for video and images, A1 for audio-only files; \"new\" makes a new layer on top. Without start the clip is appended after the track's last clip. An adjustment layer has no picture: effects on it (effect_add) apply to every layer below it for its duration. Retiming sound past ±10% (fit to fill or speed) is reported as a warning; to fill time with ambience, room tone or a music bed, pass loop:true, which repeats the source range instead of stretching it. A media clip set to transform.fit fill is framed from shot analysis so faces (else the salient subject) stay in view, unless transform.x or transform.y is set.", schema: Schema.object([
            "media_id": Schema.string("Media to place"),
            "color": Schema.string("Hex color for a solid color clip"),
            "adjustment": Schema.bool("Make an adjustment layer"),
            "generator": Schema.string("Draw a graphic: \(GeneratorCatalog.all.map(\.id).joined(separator: ", ")). shape is a shape layer (paths, strokes, trim paths, morphs, repeaters), particles an emitter, title.* designed titles that build on and off by themselves, camera the 3D camera for layers with transform.3d. catalog type=<id> for params; animate them as fx.gen.<param> (shape layers: fx.gen.<shape id>.<property>, e.g. fx.gen.ring.trim_end)"),
            "params": ["type": "object", "description": "Generator parameters, e.g. {\"title\": \"Ada Lovelace\", \"subtitle\": \"Mathematician\"}; shape takes {\"shapes\": [{\"id\": \"ring\", \"type\": \"ellipse\", \"width\": 0.3, \"height\": 0.3, \"stroke\": \"#FFFFFF\", \"stroke_width\": 0.01, \"trim_end\": 0}]}"],
            "track": Schema.string("Track id, or \"new\" for a new layer on top"),
            "start": Schema.time("Timeline start (seconds or anchor)"),
            "end": Schema.time("Timeline end, instead of duration"),
            "mode": Schema.string("place (exact start, fail on overlap; default when start is given), append (default without start), overwrite (replace what is under it), insert (push everything later, on all tracks)", values: PlaceMode.allCases.map(\.rawValue)),
            "source_in": Schema.time("Source start (seconds in the media, a word anchor like \"talk.w12\", or source timecode like \"talk@01:00:12:10\")"),
            "source_out": Schema.time("Source end (seconds or word anchor such as \"talk.w40.end\")"),
            "duration": Schema.time("Timeline duration; images, solids and adjustment layers default to 5"),
            "speed": Schema.number("Playback speed, 1 = normal. With source_in, source_out and a duration or end, speed is computed to fit (fit to fill)"),
            "loop": Schema.bool("Sound only (audio-only media, or any media on an audio track): repeat source_in–source_out end to end to fill duration or end, as several clips, instead of retiming"),
            "allow_stretch": Schema.bool("Allow slowing audio-only media below 0.25×, which is refused by default"),
            "name": Schema.string("Label shown in the preview timeline"),
            "channels": Schema.string("Which source channels the clip plays (audio.channels): \(ChannelRouting.help). \"split\" lays every source channel of a multitrack recording on its own audio track as a mono clip (ch1, ch2…), linked with the picture (its own sound off) so they move, trim and delete together"),
            "audio_tracks": Schema.strings("With channels:\"split\": one existing audio track per source channel; default new tracks"),
        ].merging(Toolbox.setProp) { a, _ in a }), label: { a, p in a.optString("media_id").map { id in "Add " + (p.mediaAsset(id)?.name ?? id) + (a.optString("channels") == "split" ? " split into channels" : "") } ?? (a.bool("adjustment", default: false) ? "Add adjustment layer" : "Add a color clip") }) { [unowned self] p, args in
            if let mid = args.optString("media_id") { self.fillChannels(&p, mid) }
            var clip: Clip
            var defaultTrack = "V1"
            var warning: String?
            var loopSource: TimeRange?
            var loopLength: Seconds = 0
            let start = try args.optTime("start")
            let end = try args.optTime("end")
            let span = start.flatMap { s in end.map { $0 - s } }
            if let mid = args.optString("media_id") {
                guard let m = p.mediaAsset(mid) else { throw EditError("No media \(mid). Known: \(p.media.map(\.id).joined(separator: ", "))") }
                let sIn = try args.optSourceTime("source_in") ?? 0
                var speed = args.optDouble("speed") ?? 1
                if args.has("speed") { try Clip.checkSpeed(speed) }
                var dur: Seconds
                if m.isImage {
                    dur = try span ?? args.optTime("duration") ?? 5
                } else if args.bool("loop", default: false) {
                    guard m.hasAudio else { throw EditError("\(mid) has no sound to loop") }
                    guard let fill = try span ?? args.optTime("duration"), fill > 0 else { throw EditError("loop needs the length to fill: duration, or start and end") }
                    let sOut = try args.optSourceTime("source_out") ?? m.duration
                    guard sOut > sIn else { throw EditError("source_out must be after source_in") }
                    loopSource = TimeRange(sIn, sOut)
                    loopLength = fill
                    dur = min(fill, (sOut - sIn) / speed)
                } else if let sOut = try args.optSourceTime("source_out"), args.optDouble("speed") == nil, let fill = try span ?? args.optTime("duration") {
                    // Fit to fill: the source range is retimed to the requested length.
                    guard fill > 0, sOut > sIn else { throw EditError("source_out must be after source_in") }
                    speed = (sOut - sIn) / fill
                    dur = fill
                } else if let sOut = try args.optSourceTime("source_out") {
                    dur = (sOut - sIn) / speed
                } else if let d = try span ?? args.optTime("duration") {
                    dur = d
                } else {
                    dur = (m.duration - sIn) / speed
                }
                if !m.isImage {
                    try Clip.checkAudioStretch(speed: speed, media: m, allow: args.bool("allow_stretch", default: false))
                    warning = Clip.retimeWarning(speed: speed, hasAudio: m.hasAudio)
                }
                clip = Clip(id: Project.newClipId(), kind: .media, name: args.optString("name") ?? m.name, mediaId: mid, start: 0, duration: dur, sourceIn: m.isImage ? 0 : sIn, speed: speed)
                if !m.hasVideo { defaultTrack = p.tracks.first { $0.kind == .audio }?.id ?? "A1" }
            } else if let gen = args.optString("generator") {
                guard let spec = GeneratorCatalog.type(gen) else { throw EditError("No generator \(gen). Generators: \(GeneratorCatalog.all.map(\.id).joined(separator: ", "))") }
                var params: [String: ParamValue] = [:]
                let given = args.raw["params"]?.object ?? [:]
                // The shape list goes first: shape properties are looked up in it.
                for (given, v) in given.sorted(by: { ($0.key == "shapes" ? 0 : 1, $0.key) < ($1.key == "shapes" ? 0 : 1, $1.key) }) {
                    let k = GeneratorCatalog.spec(type: gen, name: given, params: params) == nil ? spec.paramName(for: given) ?? given : given
                    guard let ps = GeneratorCatalog.spec(type: gen, name: k, params: params) else { throw EditError("\(gen) has no parameter \(k). Parameters: \(spec.params.map(\.name).joined(separator: ", "))") }
                    let value = try ps.validate(try Toolbox.paramValue(v), path: k)
                    try Effect.checkResource(type: gen, param: k, value: value)
                    params[k] = value
                }
                clip = Clip(id: Project.newClipId(), kind: .generator, name: args.optString("name") ?? (gen.split(separator: ".").last.map(String.init) ?? gen).replacingOccurrences(of: "_", with: " "), start: 0, duration: try span ?? args.optTime("duration") ?? 5, effects: [Effect(id: "gen", type: gen, params: params)])
                defaultTrack = "new"
            } else if args.bool("adjustment", default: false) {
                clip = Clip(id: Project.newClipId(), kind: .adjustment, name: args.optString("name") ?? "Adjustment", start: 0, duration: try span ?? args.optTime("duration") ?? 5)
                defaultTrack = "new"
            } else if let color = try args.color("color") {
                clip = Clip(id: Project.newClipId(), kind: .solid, name: args.optString("name") ?? "Color", start: 0, duration: try span ?? args.optTime("duration") ?? 5, color: color)
            } else {
                throw EditError("Pass media_id, color, generator, or adjustment: true")
            }
            try Toolbox.applySet(&clip, args)
            let placedBy = Set(args.raw["set"]?.object?.keys.map { $0 } ?? [])
            var framing = ""
            if clip.kind == .media, clip.transform.fit == .fill, placedBy.isDisjoint(with: ["transform.x", "transform.y", "transform.pos_x", "transform.pos_y", "x", "y"]), let mid = clip.mediaId, let b = try? session.requireBundle(),
               let f = Toolbox.fillFraming(clip, p, Toolbox.shotIndex(b, p, media: [mid])) {
                clip.transform.x = f.x
                clip.transform.y = f.y
                framing = "; framed to keep faces or the subject in view (transform.x \(fmt2(f.x)), y \(fmt2(f.y)))"
            }
            let split = args.optString("channels") == "split"
            if let raw = args.optString("channels"), !split {
                guard clip.kind == .media else { throw EditError("channels is for media clips") }
                guard let r = ChannelRouting(rawValue: raw) else { throw EditError("channels is split or \(ChannelRouting.help)") }
                clip.channels = r.isAsRecorded ? nil : r
            }
            if split {
                guard clip.kind == .media, let m = p.mediaAsset(clip.mediaId!) else { throw EditError("channels:\"split\" needs media_id") }
                guard args.optString("track") != "new" || m.hasVideo else { throw EditError("channels:\"split\" makes its own audio tracks; pass audio_tracks to use existing ones") }
                let mode = try args.enumValue("mode", PlaceMode.self) ?? (start == nil ? .append : .place)
                clip.start = start ?? 0
                var picture = args.optString("track") ?? "V1"
                if picture == "new" { picture = p.addTrack(kind: .video, name: "Overlay", index: p.tracks.lastIndex { $0.kind == .video }.map { $0 + 1 } ?? 0).id }
                let made = try p.addSplitChannels(clip, pictureTrack: picture, audioTracks: args.strings("audio_tracks"), mode: mode)
                let first = made.channels.first.flatMap { p.clip($0.clip) }
                return "Split \(m.id) into \(made.channels.count) mono clip(s)" + (first.map { " at \(fmt($0.start))–\(fmt($0.end))" } ?? "") + ": "
                    + made.channels.map { "\($0.clip) on \($0.track)" }.joined(separator: ", ")
                    + (made.picture.map { "; picture \($0) on \(picture) with its own sound off" } ?? "") + ", all linked."
            }
            var trackId = args.optString("track") ?? defaultTrack
            if trackId == "new" {
                let kind: TrackKind = clip.kind == .media && !(p.mediaAsset(clip.mediaId!)?.hasVideo ?? true) ? .audio : .video
                let index = kind == .video ? (p.tracks.lastIndex { $0.kind == .video }.map { $0 + 1 } ?? 0) : p.tracks.count
                trackId = p.addTrack(kind: kind, name: clip.kind == .adjustment ? "Adjustment" : kind == .video ? "Overlay" : "Audio", index: index).id
            }
            let mode = try args.enumValue("mode", PlaceMode.self) ?? (start == nil ? .append : .place)
            clip.start = start ?? 0
            if let loopSource, let ti = p.trackIndex(trackId) {
                let m = p.mediaAsset(clip.mediaId!)!
                guard p.tracks[ti].kind == .audio || !m.hasVideo else { throw EditError("loop repeats sound only: put it on an audio track (track: \"A1\" or \"new\"), or use recipe room_tone") }
                guard mode != .insert else { throw EditError("loop places with mode place, append or overwrite") }
                let at = mode == .append ? p.tracks[ti].end : clip.start
                let pieces = try p.loopPieces(start: at, duration: loopLength, source: loopSource, speed: clip.speed)
                var ids: [String] = []
                for piece in pieces {
                    var c = clip
                    c.id = Project.newClipId()
                    c.start = piece.start
                    c.duration = piece.duration
                    c.sourceIn = piece.sourceIn
                    ids.append(try p.addClip(c, trackId: trackId, mode: mode == .append ? .place : mode).id)
                }
                return "Added \(ids.count) clip(s) on \(trackId) at \(fmt(pieces.first?.start ?? at))–\(fmt(pieces.last.map { $0.start + $0.duration } ?? at)), looping \(clip.mediaId!) \(fmt2(loopSource.start))–\(fmt2(loopSource.end))s: \(ids.joined(separator: ", "))"
            }
            let placed = try p.addClip(clip, trackId: trackId, mode: mode)
            return "Added \(placed.id) on \(trackId) at \(fmt(placed.start))–\(fmt(placed.end))" + framing + (warning.map { ". " + $0 } ?? "")
        })

        addEdit(EditTool(name: "text_add", description: "Add a title, lower third, label or call-out. Goes on a text layer above the video (created as needed, a new one if the range is busy).", schema: Schema.object(Toolbox.textProps.merging([
            "start": Schema.time("Timeline start (seconds or anchor such as \"talk.w40\")"),
            "end": Schema.time("Timeline end, instead of duration (e.g. \"talk.w46.end\")"),
            "duration": Schema.time("How long it shows, default 3"),
            "track": Schema.string("Track id; default picks or creates a text layer"),
            "subtitles": Schema.string("Instead of one title, import an .srt or .vtt file as titles on a new track, styled by the other arguments (default: bottom, boxed); offset shifts them"),
            "offset": Schema.number("Seconds added to imported subtitle times"),
            "preset": Schema.string("A ready style: lower_third, title_card or caption_box (a styled title the other arguments adjust), or an animated title graphic: lower_third_modern, lower_third_box, lower_third_pill, lower_third_line, card, quote, end_card, data_callout (title.* generators; text's first line is the name or title, the next lines the role or subtitle; change it later with param_set fx.gen.<param>)"),
        ]) { a, _ in a }.merging(Toolbox.setProp) { a, _ in a }), label: { a, _ in a.has("subtitles") ? "Import subtitles" : "Add title “\(Toolbox.excerpt(a.optString("text") ?? "", 34))”" }) { p, args in
            if let file = args.optString("subtitles") {
                let url = URL(fileURLWithPath: (file as NSString).expandingTildeInPath)
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { throw EditError("Cannot read \(file)") }
                let cues = url.pathExtension.lowercased() == "vtt" ? try Importer.vtt(text) : try Importer.srt(text)
                let track = p.addTrack(kind: .video, name: "Subtitles")
                let shift = args.optDouble("offset") ?? 0
                for cue in cues {
                    var spec = TextSpec(text: cue.text, size: 0.045, weight: 600, background: RGBA(hex: "#000000B3"), shadow: false, y: 0.88, maxWidth: 0.8, animationIn: .none, animationOut: .none)
                    try Toolbox.applyText(&spec, args)
                    let clip = Clip(id: Project.newClipId(), kind: .text, name: String(cue.text.prefix(30)), start: cue.start + shift, duration: max(p.canvas.frameDuration, cue.end - cue.start), text: spec)
                    try p.addClip(clip, trackId: track.id, mode: .overwrite)
                }
                return "Imported \(cues.count) subtitles from \(url.lastPathComponent) onto \(track.id)."
            }
            let words = try args.string("text")
            var spec = try Toolbox.textPreset(args.optString("preset"), words) ?? TextSpec(text: words)
            try Toolbox.applyText(&spec, args)
            guard args.has("start") else { throw EditError("Pass start") }
            let start = p.canvas.snap(try args.time("start"))
            let duration = try args.optTime("end").map { $0 - start } ?? args.optTime("duration") ?? 3
            let graphic = try args.optString("preset").flatMap { try Toolbox.titleGraphic($0, words, args) }
            var clip = graphic.map { Clip(id: Project.newClipId(), kind: .generator, name: String(words.replacingOccurrences(of: "\n", with: " ").prefix(30)), start: start, duration: duration, effects: [$0]) }
                ?? Clip(id: Project.newClipId(), kind: .text, name: String(spec.text.prefix(30)), start: start, duration: duration, text: spec)
            try Toolbox.applySet(&clip, args)
            let range = TimeRange(start, start + duration)
            let trackId: String
            if let t = args.optString("track") {
                trackId = t
            } else if let free = p.tracks.last(where: { t in
                t.kind == .video && !t.clips.isEmpty && t.clips.allSatisfy { $0.kind == .text || ($0.kind == .generator && $0.effects.first?.type.hasPrefix("title.") == true) } && !t.clips.contains { TimeRange($0.start, $0.end).intersection(range) != nil }
            }) {
                trackId = free.id
            } else {
                trackId = p.addTrack(kind: .video, name: "Text", index: p.tracks.lastIndex { $0.kind == .video }.map { $0 + 1 } ?? 0).id
            }
            let placed = try p.addClip(clip, trackId: trackId, mode: .place)
            if let g = graphic {
                let shown = g.params.filter { $0.value.string?.isEmpty == false }.sorted { $0.key < $1.key }.map { "\($0.key) \"\($0.value.string!)\"" }.joined(separator: ", ")
                return "Added \(g.type) graphic \(placed.id) on \(trackId) at \(fmt(placed.start))–\(fmt(placed.end)) (\(shown)); restyle with param_set fx.gen.<param> (catalog type:\(g.type))."
            }
            return "Added text \(placed.id) on \(trackId) at \(fmt(placed.start))–\(fmt(placed.end))" + spec.spanWarnings.map { "\nWarning: " + $0 }.joined()
        })

        addEdit(EditTool(name: "clip_update", description: "Change a clip's timing or place: move it (start, track), trim it (source_in/source_out keep the start; duration or end trim the tail), change speed (keeps the source range), rename it, or change a title's words. Appearance, audio levels and animation go through param_set and effect_add. If the new end collides with the next clip, pass ripple=true to shift later clips on that track; a speed change ripples by default when the next clip butts against it (ripple:false keeps the gap). detach_audio moves its sound to a linked audio clip; attach_audio folds it back.", schema: Schema.object([
            "clip_id": Schema.string("Clip id"),
            "start": Schema.time("New timeline start (seconds or anchor)"),
            "end": Schema.time("New timeline end; trims the tail"),
            "duration": Schema.time("New timeline duration; trims the tail"),
            "source_in": Schema.time("New source start (seconds or word anchor); trims the head, start stays"),
            "source_out": Schema.time("New source end (seconds or word anchor)"),
            "speed": Schema.number("Playback speed; keeps the source range. Sound past ±10% is reported as a warning"),
            "allow_stretch": Schema.bool("Allow slowing audio-only media below 0.25×, which is refused by default"),
            "track": Schema.string("Move to this track (overwrites what is there)"),
            "name": Schema.string("Label"),
            "text": Schema.string("New words for a title clip"),
            "ripple": Schema.bool("Shift later clips on the track by the change in end time; default false, except for a speed change of a clip the next one butts against"),
            "media_id": Schema.string("Replace edit: swap in other media at the same place and length (source_in picks where it starts)"),
            "link": Schema.strings("Link this clip with these clips so they move, split and delete together (e.g. picture and its separately recorded sound)"),
            "unlink": Schema.bool("Break this clip's link"),
            "detach_audio": Schema.bool("Split a picture clip's sound off onto a linked clip on an audio track (audio_track, default a \"Sound of <track>\" track): its split lead/lag, channel routing, level and automation, fades and audio effects move with it and the picture goes silent; the two stay linked so they move together"),
            "attach_audio": Schema.bool("Fold a detached sound clip back into its linked picture (pass either clip): it must play the same media in sync; where they start or end apart it becomes a split edit"),
            "audio_track": Schema.string("With detach_audio: the audio track for the sound"),
        ], required: ["clip_id"]), label: { a, p in Toolbox.describeUpdate(a, p) }) { p, args in
            let id = try args.string("clip_id")
            guard var c = p.clip(id) else { throw EditError("No clip \(id)") }
            if args.bool("detach_audio", default: false) {
                let had = (lead: c.audioLead, lag: c.audioLag)
                let (sound, track) = try p.detachAudio(id, to: args.optString("audio_track"))
                var line = "Detached \(id)'s sound to \(sound.id) on \(track) at \(fmt2(sound.start))–\(fmt2(sound.end))s (source \(fmt2(sound.sourceIn))–\(fmt2(sound.sourceOut)))"
                if had.lead != 0 || had.lag != 0 { line += ", keeping its split edit (sound \(had.lead >= 0 ? "leads" : "starts") \(fmt2(abs(had.lead)))s, \(had.lag >= 0 ? "lags" : "ends") \(fmt2(abs(had.lag)))s)" }
                return line + "; \(id) is now silent and linked with it. attach_audio:true folds it back."
            }
            if args.bool("attach_audio", default: false) {
                let (pic, sound) = try p.attachAudio(id)
                guard let now = p.clip(pic) else { throw EditError("No clip \(pic)") }
                let split = now.audioLead != 0 || now.audioLag != 0
                return "Folded \(sound)'s sound back into \(pic)" + (split ? " as a split edit (sound \(fmt2(now.audioRange.start))–\(fmt2(now.audioRange.end))s, picture \(fmt2(now.start))–\(fmt2(now.end))s)" : "") + "; \(sound) is removed."
            }
            if args.bool("unlink", default: false) { c.link = nil }
            if let others = args.strings("link") {
                let group = c.link ?? IDs.make("lnk")
                c.link = group
                for o in others {
                    guard let loc = p.locateClip(o) else { throw EditError("No clip \(o)") }
                    p.tracks[loc.track].clips[loc.clip].link = group
                }
            }
            if let mid = args.optString("media_id") {
                guard let m = p.mediaAsset(mid) else { throw EditError("No media \(mid)") }
                guard c.kind == .media else { throw EditError("Replace edits work on media clips") }
                let synced = c.mediaId.flatMap { p.syncedTime(c.sourceIn, from: $0, to: mid) }
                c.mediaId = mid
                c.name = m.name
                // Synced angles keep the same moment; other media keep the source time where possible.
                if try args.optSourceTime("source_in") == nil { c.sourceIn = m.isImage ? 0 : synced ?? min(c.sourceIn, max(0, m.duration - c.duration * c.speed)) }
            }
            var warning: String?
            if let v = args.optDouble("speed") {
                try Clip.checkSpeed(v)
                let src = c.duration * c.speed
                c.speed = v
                c.duration = src / v
                if let m = c.mediaId.flatMap({ p.mediaAsset($0) }), c.kind == .media, !m.isImage {
                    try Clip.checkAudioStretch(speed: v, media: m, allow: args.bool("allow_stretch", default: false))
                    warning = Clip.retimeWarning(speed: v, hasAudio: m.hasAudio)
                }
            }
            let sIn = try args.optSourceTime("source_in"), sOut = try args.optSourceTime("source_out")
            if sIn != nil || sOut != nil {
                let newIn = sIn ?? c.sourceIn
                let newOut = sOut ?? c.sourceOut
                guard newOut > newIn else { throw EditError("source_out must be after source_in") }
                c.sourceIn = newIn
                c.duration = (newOut - newIn) / c.speed
            }
            if let d = try args.optTime("duration") { c.duration = d }
            if let s = try args.optTime("start") {
                let delta = s - c.start
                c.start = s
                for other in p.linked(id) {
                    guard let loc = p.locateClip(other) else { continue }
                    p.tracks[loc.track].clips[loc.clip].start += delta
                }
            }
            if let e = try args.optTime("end") { c.duration = e - c.start }
            if let v = args.optString("name") { c.name = v }
            if let t = args.optString("text") {
                guard c.kind == .text else { throw EditError("\(id) is not a title") }
                c.text?.text = t
            }
            if let track = args.optString("track"), p.locateClip(id).map({ p.tracks[$0.track].id }) != track {
                try p.moveClip(id, start: c.start, trackId: track)
                guard var moved = p.clip(id) else { throw EditError("Move failed") }
                moved.duration = c.duration; moved.sourceIn = c.sourceIn; moved.speed = c.speed; moved.name = c.name; moved.text = c.text
                c = moved
            }
            // A speed change keeps the clip butted to the next one on its track unless ripple:false.
            var rippleNote = ""
            var ripple = args.bool("ripple", default: false)
            if args.has("speed"), let loc = p.locateClip(id), let old = p.clip(id), abs(old.end - c.end) > 1e-6 {
                let butted = p.tracks[loc.track].clips.contains { $0.id != id && abs($0.start - old.end) < p.canvas.frameDuration / 2 }
                if !args.has("ripple"), butted, !args.has("end"), !args.has("duration"), !args.has("track") {
                    ripple = true
                    rippleNote = ". Later clips on \(p.tracks[loc.track].id) moved \(fmt2(abs(c.end - old.end)))s \(c.end > old.end ? "later" : "earlier") to stay butted (ripple:false \(c.end > old.end ? "refuses the overlap instead" : "keeps the gap"))"
                } else if !ripple, butted, c.end < old.end {
                    rippleNote = ". This leaves a \(fmt2(old.end - c.end))s gap before the next clip; ripple:true closes it"
                }
            }
            try p.replaceClip(c, ripple: ripple)
            let now = p.clip(id)!
            return "Updated \(id): \(Describe.clip(now, p))" + (warning.map { ". " + $0 } ?? "") + rippleNote
        })

        addEdit(EditTool(name: "clip_split", description: "Split at a timeline time: one clip (clip_id) or every clip under that time on the given tracks (default all).", schema: Schema.object([
            "at": Schema.time("Timeline time"),
            "clip_id": Schema.string("Only split this clip"),
            "track_ids": Schema.strings("Only these tracks when clip_id is omitted"),
        ], required: ["at"]), label: { a, _ in "Split at \(Toolbox.timeLabel(a.raw["at"]))" }) { p, args in
            let t = try args.time("at")
            if let id = args.optString("clip_id") {
                let (a, b) = try p.splitClip(id, at: t)
                return "Split into \(a) and \(b)"
            }
            let made = p.splitAll(at: t, trackIds: args.strings("track_ids"))
            guard !made.isEmpty else { throw EditError("No clip spans \(fmt(t))") }
            return "Split \(made.count) clips; new right halves: \(made.joined(separator: ", "))"
        })

        addEdit(EditTool(name: "clip_delete", description: "Delete clips. ripple=true closes the gap on each clip's own track only (other tracks do not move). To cut a moment out of everything in sync, use range_delete.", schema: Schema.object([
            "clip_ids": Schema.strings("Clip ids"),
            "ripple": Schema.bool("Close the gap on the clip's track, default false"),
        ], required: ["clip_ids"]), label: { a, p in let ids = a.strings("clip_ids") ?? []; return ids.count == 1 ? "Delete \(Toolbox.clipName(ids[0], p))" : "Delete \(ids.count) clips" }) { p, args in
            let ids = args.strings("clip_ids") ?? []
            let sound = try p.deleteClips(ids, ripple: args.bool("ripple", default: false))
            return "Deleted \(ids.joined(separator: ", "))" + (sound.isEmpty ? "" : "\nSplit edits: " + sound.joined(separator: "; "))
        })

        addEdit(EditTool(name: "range_delete", description: "Cut a timeline range out of every track (or only track_ids). With ripple (default) everything later moves up so tracks stay in sync.", schema: Schema.object([
            "start": Schema.time("Timeline start"),
            "end": Schema.time("Timeline end"),
            "track_ids": Schema.strings("Limit to these tracks"),
            "ripple": Schema.bool("Close the gap, default true"),
        ], required: ["start", "end"]), label: { a, _ in "Cut \(Toolbox.timeLabel(a.raw["start"]))–\(Toolbox.timeLabel(a.raw["end"]))" }) { p, args in
            let r = TimeRange(try args.time("start"), try args.time("end"))
            guard r.duration > 0 else { throw EditError("end must be after start") }
            p.deleteRange(r, trackIds: args.strings("track_ids"), ripple: args.bool("ripple", default: true))
            return "Removed \(fmt(r.start))–\(fmt(r.end)) (\(fmt2(r.duration))s)"
        })

        addEdit(EditTool(name: "source_cut", description: "Cut source ranges of a media file out of the timeline wherever they play, rippling all tracks. Ranges are SOURCE times from media_transcript, so they stay valid after earlier edits. The main tool for removing flubs, repeated takes, tangents or specific words.", schema: Schema.object([
            "media_id": Schema.string("Media id"),
            "ranges": Schema.array(Schema.numbers("[start, end]"), "Source ranges to remove, as seconds or word anchors, e.g. [[12.4, 15.0], [\"talk.w88\", \"talk.w93.end\"]]"),
        ], required: ["media_id", "ranges"]), label: { a, p in let n = a.raw["ranges"]?.array?.count ?? 0; let id = a.optString("media_id") ?? ""; return "Cut \(n) \(n == 1 ? "moment" : "moments") from \(p.mediaAsset(id)?.name ?? id)" }) { p, args in
            let id = try args.string("media_id")
            guard p.mediaAsset(id) != nil else { throw EditError("No media \(id)") }
            let ranges = try Toolbox.ranges(args.raw["ranges"])
            let removed = p.cutSourceRanges(mediaId: id, ranges: ranges)
            guard !removed.isEmpty else { throw EditError("None of those source ranges are on the timeline") }
            return "Removed \(removed.count) ranges, \(fmt2(removed.map(\.duration).reduce(0, +)))s total"
        })

        addEdit(EditTool(name: "assemble", description: "Build a sequence from source segments, in the order given, end to end on one track. Ideal for a rough cut: pick the good sentences from media_transcript (source times) and lay them down. replace=true clears the track first.", schema: Schema.object([
            "segments": Schema.array(Schema.object([
                "media_id": Schema.string("Media id"),
                "start": Schema.time("Source start, or a word anchor such as \"talk.w12\""),
                "end": Schema.time("Source end, or a word anchor such as \"talk.w30.end\""),
            ], required: ["media_id", "start", "end"]), "Segments in playback order"),
            "track": Schema.string("Track id, default V1"),
            "at": Schema.time("Timeline start, default the track end (or 0 with replace)"),
            "replace": Schema.bool("Clear the track first, default false"),
            "fit": Schema.string("Framing for every placed clip; fill crops landscape footage to cover a vertical canvas", values: ["fit", "fill", "stretch"]),
            "pad": ["type": ["number", "array"], "items": ["type": "number"], "description": "Handles around the words of transcribed segments, seconds: [before, after] or one number for both; default [0.08, 0.12]. Handles stop at the neighbouring words; 0 cuts at the word edges. Clip ends round out to whole frames so the last word is never cut"],
        ], required: ["segments"]), label: { a, _ in "Assemble \(a.raw["segments"]?.array?.count ?? 0) takes" }) { [unowned self] p, args in
            guard let raw = args.raw["segments"]?.array, !raw.isEmpty else { throw EditError("segments is empty") }
            var pad = (before: 0.08, after: 0.12)
            if let n = args.raw["pad"]?.double { pad = (n, n) } else if let list = args.raw["pad"]?.array?.compactMap(\.double) {
                guard list.count == 2 else { throw EditError("pad is one number or [before, after]") }
                pad = (list[0], list[1])
            }
            guard pad.before >= 0, pad.after >= 0, pad.before <= 2, pad.after <= 2 else { throw EditError("pad is 0–2 seconds") }
            var transcripts: [String: Transcript] = [:]
            var padded = 0
            let requested = try raw.map { j -> SourceSegment in
                let a = Args(j)
                return SourceSegment(mediaId: try a.string("media_id"), sourceIn: try a.sourceTime("start"), sourceOut: try a.sourceTime("end"))
            }
            let handled = requested.map { seg -> SourceSegment in
                if transcripts[seg.mediaId] == nil { transcripts[seg.mediaId] = session.bundle?.transcript(seg.mediaId) }
                guard seg.sourceOut > seg.sourceIn, let t = transcripts[seg.mediaId], let m = p.mediaAsset(seg.mediaId), !m.isImage else { return seg }
                let out = seg.withHandles(t, before: pad.before, after: pad.after, fps: p.canvas.fps, duration: m.duration)
                if out != seg { padded += 1 }
                return out
            }
            let segs = SourceSegment.butted(handled, requested: requested, fps: p.canvas.fps)
            let butts = zip(segs, handled).filter { abs($0.sourceIn - $1.sourceIn) > 1e-9 }.count
            let replace = args.bool("replace", default: false)
            var made = try p.assemble(segs, trackId: args.optString("track") ?? "V1", at: try args.optTime("at") ?? (replace ? 0 : nil), replaceTrack: replace)
            if let fit = try args.enumValue("fit", FitMode.self) {
                for i in made.indices {
                    made[i].transform.fit = fit
                    try p.replaceClip(made[i])
                }
            }
            return "Placed \(made.count) clips: " + made.map { "\($0.id) \(fmt2($0.start))–\(fmt2($0.end)) (src \(fmt2($0.sourceIn))–\(fmt2($0.sourceOut)))" }.joined(separator: ", ")
                + (padded == 0 ? "" : "\nHandles: \(padded) segment(s) start \(fmt2(pad.before))s before their first word and end \(fmt2(pad.after))s after their last (stopping at neighbouring words), in whole frames; pad changes them")
                + (butts == 0 ? "" : "\nContiguous takes of the same source share their edit (\(butts) edit(s)), so no frame plays twice")
        })

        addEdit(EditTool(name: "cut_silences", description: "Tighten talking footage: remove pauses longer than min_pause (leaving `keep` seconds of breathing room) and, by default, filler words (um, uh…). Gaps between words under music or other sound, or as loud as the speech, are kept and reported (include_music:true cuts them). Works in source time on every clip of the media, rippling all tracks. Check the result with timeline_transcript.", schema: Schema.object([
            "media_id": Schema.string("Media id; default every transcribed media on the timeline"),
            "min_pause": Schema.time("Only pauses at least this long, default 0.5"),
            "keep": Schema.time("Pause length to leave behind, default 0.2"),
            "fillers": Schema.bool("Also remove filler words, default true"),
            "by": Schema.string("Where pauses come from: speech (default with a transcript: gaps between transcribed words that are quiet and hold no music or other sound, from the level and sound analysis) or level (quiet audio from the level analysis; the fallback without a transcript)", values: ["speech", "level"]),
            "include_music": Schema.bool("With by speech: also cut gaps under music, other sound (action, effects) or as loud as the speech, default false"),
        ]), label: { a, _ in a.bool("fillers", default: true) ? "Cut pauses and filler words" : "Cut pauses" }) { [unowned self] p, args in
            let b = try session.requireBundle()
            let minPause = try args.optTime("min_pause") ?? 0.5
            let keep = try args.optTime("keep") ?? 0.2
            let by = args.optString("by")
            let fillersToo = args.bool("fillers", default: true)
            let includeMusic = args.bool("include_music", default: false)
            let ids = args.optString("media_id").map { [$0] } ?? Array(Set(p.tracks.flatMap(\.clips).compactMap(\.mediaId))).sorted()
            var report: [String] = []
            for id in ids {
                let t = b.transcript(id)
                let speech = by == "speech" || (by == nil && t?.words.isEmpty == false)
                if by == "speech", t == nil { throw EditError("\(id) has no transcript for by:\"speech\"; run media_analyze, or use by:\"level\"") }
                let pauses: [TimeRange]
                var keptNote: String?
                if speech, let t {
                    let gaps = t.pauses(atLeast: minPause, skippingFillers: fillersToo).filter { !p.timelineRanges(mediaId: id, sourceRanges: [$0]).isEmpty }
                    let sorted = SpeechPauses(gaps: gaps, words: t.words, sounds: b.analysis(SoundEvents.self, id, "sounds")?.events, levels: b.audioAnalysis(id), includeMusic: includeMusic)
                    pauses = sorted.cut
                    keptNote = sorted.keptSummary.map { $0 + " (include_music:true cuts them too)" }
                    if b.analysis(SoundEvents.self, id, "sounds") == nil, b.audioAnalysis(id) == nil, !gaps.isEmpty { keptNote = "no sound or level analysis, so every gap between words counted as a pause (media_analyze features:[\"sounds\"] tells music and action apart)" }
                } else {
                    guard let audio = b.audioAnalysis(id) else { continue }
                    pauses = audio.silences.filter { $0.duration >= minPause }.map { TimeRange($0.start, $0.end) }
                }
                var ranges = pauses.map { TimeRange($0.start + keep / 2, $0.end - keep / 2) }.filter { $0.duration > 0 }
                var fillerCount = 0
                if fillersToo, let t {
                    let fillers = t.words.filter(\.isFiller).map { TimeRange($0.start, $0.end) }
                    fillerCount = fillers.filter { !p.timelineRanges(mediaId: id, sourceRanges: [$0]).isEmpty }.count
                    ranges += fillers
                }
                let heard = pauses.filter { !p.timelineRanges(mediaId: id, sourceRanges: [$0]).isEmpty }.count
                let removed = p.cutSourceRanges(mediaId: id, ranges: TimeRange.merged(ranges, tolerance: 0.05))
                if !removed.isEmpty {
                    report.append("\(id): \(removed.count) cuts, \(fmt2(removed.map(\.duration).reduce(0, +)))s removed (\(heard) pauses ≥\(fmt2(minPause))s from \(speech ? "gaps between transcribed words" : "audio level"), \(fillerCount) fillers)" + (keptNote.map { "; " + $0 } ?? ""))
                } else if let keptNote {
                    report.append("\(id): nothing cut; \(keptNote)")
                }
            }
            guard !report.isEmpty else { throw EditError("Nothing to cut. Is the media analyzed and on the timeline?") }
            return report.joined(separator: "\n")
        })

        addEdit(EditTool(name: "track_add", description: "Add a track. Video tracks stack: later ones draw on top.", schema: Schema.object([
            "kind": Schema.string("video or audio", values: ["video", "audio"]),
            "name": Schema.string("Name"),
            "position": Schema.integer("Index from the bottom; default top of its kind"),
        ], required: ["kind"]), label: { a, _ in "Add \(a.optString("kind") ?? "video") track" }) { p, args in
            let kind = try args.enumValue("kind", TrackKind.self) ?? .video
            let index = args.optInt("position") ?? (kind == .video ? (p.tracks.lastIndex { $0.kind == .video }.map { $0 + 1 } ?? 0) : p.tracks.count)
            let t = p.addTrack(kind: kind, name: args.optString("name"), index: index)
            return "Added track \(t.id)"
        })

        addEdit(EditTool(name: "track_update", description: "Rename, mute, hide, set volume of, route (output, sends) or remove a track.", schema: Schema.object([
            "track": Schema.string("Track id"),
            "name": Schema.string("Name"),
            "muted": Schema.bool("Mute audio"),
            "hidden": Schema.bool("Hide picture"),
            "volume": Schema.number("0–2, multiplies clip volumes (e.g. 0.25 to duck music under speech)"),
            "remove": Schema.bool("Delete the track and its clips"),
            "role": Schema.string("Audio role for stem export: dialogue, music, effects, or a custom name"),
        ].merging(Toolbox.trackRoutingSchema) { a, _ in a }, required: ["track"]), label: { a, p in Toolbox.describeTrackUpdate(a, p) }) { p, args in
            let id = try args.string("track")
            guard let i = p.trackIndex(id) else { throw EditError("No track \(id)") }
            if args.bool("remove", default: false) {
                try p.removeTrack(id)
                return "Removed track \(id)"
            }
            if let v = args.optString("name") { p.tracks[i].name = v }
            if let v = args.optBool("muted") { p.tracks[i].muted = v }
            if let v = args.optBool("hidden") { p.tracks[i].hidden = v }
            if let v = args.optDouble("volume") { p.tracks[i].volume = v }
            if let v = args.optString("role") { p.tracks[i].role = v.isEmpty ? nil : v }
            try Toolbox.applyTrackRouting(&p.tracks[i], args)
            return "Updated track \(id)"
        })

        addEdit(EditTool(name: "captions_set", description: "Turn on and style captions. Captions are generated live from the transcripts of clips on the timeline, so they always match the current edit. Presets: karaoke (spoken word highlighted), bold (big uppercase, 1–3 words, social style), clean (subtitles on a dark box), reveal (words appear as spoken), minimal. Fix misheard words with replacements.", schema: Schema.object([
            "enabled": Schema.bool("Show captions, default true"),
            "preset": Schema.string("Starting style", values: ["karaoke", "bold", "clean", "reveal", "minimal"]),
            "font": Schema.string("Font, as for text"),
            "size": Schema.number("Font size as a fraction of the canvas's shorter side"),
            "weight": Schema.integer("100–900"),
            "color": Schema.string("Hex"),
            "highlight_color": Schema.string("Hex color of the spoken word (karaoke)"),
            "background": Schema.string("Hex box color or none"),
            "stroke": Schema.string("Hex outline or none"),
            "stroke_width": Schema.number("Fraction of font size"),
            "uppercase": Schema.bool("Uppercase"),
            "y": Schema.number("Vertical center as a fraction of canvas height, default 0.82"),
            "max_width": Schema.number("Fraction of canvas width"),
            "max_words_per_line": Schema.integer("Words per line on the picture"),
            "max_lines": Schema.integer("Lines on the picture at once; a cue with more words than max_words_per_line × max_lines shows as consecutive pages, while subtitles and closed captions keep the cue whole"),
            "animation": Schema.string("Animation", values: CaptionAnimation.allCases.map(\.rawValue)),
            "replacements": ["type": "object", "additionalProperties": ["type": "string"], "description": "Word fixes, e.g. {\"cut line\": \"Cutline\"}; merged into existing ones, empty string value deletes"],
            "hidden_words": Schema.strings("Words never captioned, e.g. fillers you kept in the audio"),
            "track_ids": Schema.strings("Only caption speech from these tracks"),
            "platform": Schema.string("Keep captions inside this platform's UI-free area (y and max_width are pulled in as needed): a platform id, auto (default: on a 9:16 canvas the area clear of TikTok, Reels and Shorts UI) or none"),
            "language": Schema.string("Burn in this translation (captions_translate) instead of the spoken words; \"\" for the spoken language. Cue times stay; words are spread over each cue"),
        ]), label: { a, _ in a.bool("enabled", default: true) ? (a.optString("preset").map { "Captions: \($0) style" } ?? "Restyle captions") : "Turn off captions" }) { p, args in
            var c = p.captions
            c.enabled = args.bool("enabled", default: true)
            if let preset = args.optString("preset") { c.style = try Toolbox.captionPreset(preset) }
            var s = c.style
            if let v = args.optString("font") { s.font = v }
            if let v = args.optDouble("size") { s.size = v }
            if let v = args.optInt("weight") { s.weight = v }
            if let v = try args.color("color") { s.color = v }
            if let v = try args.color("highlight_color") { s.highlightColor = v }
            if args.clearsColor("background") { s.background = nil } else if let v = try args.color("background") { s.background = v }
            if args.clearsColor("stroke") { s.stroke = nil } else if let v = try args.color("stroke") { s.stroke = v }
            if let v = args.optDouble("stroke_width") { s.strokeWidth = v }
            if let v = args.optBool("uppercase") { s.uppercase = v }
            if let v = args.optDouble("y") { s.y = v }
            if let v = args.optDouble("max_width") { s.maxWidth = v }
            if let v = args.optInt("max_words_per_line") { s.maxWordsPerLine = v }
            if let v = args.optInt("max_lines") { s.maxLines = v }
            if let v = try args.enumValue("animation", CaptionAnimation.self) { s.animation = v }
            c.style = s
            if let reps = args.raw["replacements"]?.object {
                for (k, v) in reps {
                    if let str = v.string, !str.isEmpty { c.replacements[k] = str } else { c.replacements.removeValue(forKey: k) }
                }
            }
            if let v = args.strings("hidden_words") { c.hiddenWords = v }
            if let v = args.strings("track_ids") { c.trackIds = v }
            if let v = args.optString("platform") {
                guard v == "none" || v == "auto" || Platform.named(v) != nil else { throw EditError("platform is a platform id (\(Platform.all.map(\.id).joined(separator: ", "))), auto or none") }
                c.platform = v == "auto" ? nil : v
            }
            if let v = args.optString("language") {
                let tag = Project.languageTag(v)
                guard tag.isEmpty || c.translations[tag] != nil else { throw EditError("No \(tag) translation yet; run captions_translate language:\"\(tag)\" first" + (c.translations.isEmpty ? "" : " (translated: \(c.translations.keys.sorted().joined(separator: ", ")))")) }
                c.language = tag.isEmpty ? nil : tag
            }
            p.captions = c
            guard c.enabled else { return "Captions off" }
            let shown = p.captionStyle
            var text = "Captions on (\(s.animation.rawValue), size \(fmt2(s.size)), y \(fmt2(shown.y)), max_width \(fmt2(shown.maxWidth))"
            if let area = p.captionSafeArea {
                text += shown == s ? ", inside \(area.name)" : "; kept inside \(area.name)" + (shown.y != s.y ? ": y \(fmt2(s.y))→\(fmt2(shown.y))" : ":") + (shown.maxWidth != s.maxWidth ? " max_width \(fmt2(s.maxWidth))→\(fmt2(shown.maxWidth))" : "") + (shown.x.map { " x \(fmt2($0))" } ?? "") + "; platform:\"none\" places them exactly as set"
            }
            return text + (c.language.map { ", in \($0)" } ?? "") + ")"
        })

        addEdit(EditTool(name: "markers", description: "Timeline markers (chapters, to-dos, notes; labels work as anchors \"marker:<label>\") and, with media_id, source tags on footage: keyword ranges plus favorite/reject ratings, like Final Cut's keywords. Tags show in analysis_read and help pick takes.", schema: Schema.object([
            "add": Schema.array(Schema.object([
                "time": Schema.time("Timeline time or anchor (with media_id: source start)"),
                "label": Schema.string("Label or keyword"),
                "kind": Schema.string("Marker kind", values: ["standard", "chapter", "todo", "done", "comment"]),
                "color": Schema.string("Marker color, hex or name"),
                "note": Schema.string("Longer note"),
                "end": Schema.time("Ranged marker or tag end"),
                "rating": Schema.string("For media tags", values: ["favorite", "reject"]),
            ], required: ["time", "label"]), "Markers or tags to add"),
            "update": Schema.array(Schema.object(["id": Schema.string("Marker id or label"), "kind": Schema.string("New kind", values: ["standard", "chapter", "todo", "done", "comment"]), "label": Schema.string("New label"), "note": Schema.string("New note")], required: ["id"]), "Change markers, e.g. mark a to-do done"),
            "remove": Schema.strings("Marker ids or labels (or tag labels with media_id) to remove"),
            "remove_all": Schema.bool("Remove every marker (or every tag of media_id) first"),
            "media_id": Schema.string("Tag this media file's source ranges instead of the timeline"),
        ]), label: { a, _ in
            let added = a.raw["add"]?.array?.compactMap { $0["label"]?.string } ?? []
            return added.isEmpty ? "Remove markers" : "Mark " + added.map { "“\($0)”" }.joined(separator: ", ")
        }) { p, args in
            if let mid = args.optString("media_id") {
                guard let mi = p.media.firstIndex(where: { $0.id == mid }) else { throw EditError("No media \(mid)") }
                var tags = p.media[mi].tags ?? []
                if args.bool("remove_all", default: false) { tags.removeAll() }
                if let labels = args.strings("remove") { tags.removeAll { labels.contains($0.label) } }
                for m in args.raw["add"]?.array ?? [] {
                    let a = Args(m)
                    let s = try a.sourceTime("time")
                    tags.append(MediaTag(label: try a.string("label"), start: s, end: try a.optSourceTime("end") ?? (p.media[mi].isImage ? 0 : p.media[mi].duration), rating: a.optString("rating")))
                }
                p.media[mi].tags = tags.isEmpty ? nil : tags.sorted { $0.start < $1.start }
                return "\(mid) tags: " + tags.map { "\($0.label)\($0.rating.map { " (\($0))" } ?? "") \(fmt2($0.start))–\(fmt2($0.end))" }.joined(separator: ", ").ifEmptyText("none")
            }
            if args.bool("remove_all", default: false) { p.markers.removeAll() }
            for u in args.raw["update"]?.array ?? [] {
                let a = Args(u)
                let key = try a.string("id").lowercased()
                guard let i = p.markers.firstIndex(where: { $0.id.lowercased() == key || $0.label.lowercased() == key }) else { throw EditError("No marker \(key)") }
                if let k = a.optString("kind") { p.markers[i].kind = k == "standard" ? nil : k }
                if let l = a.optString("label") { p.markers[i].label = l }
                if let n = a.optString("note") { p.markers[i].note = n }
            }
            if let ids = args.strings("remove") {
                let set = Set(ids.map { $0.lowercased() })
                p.markers.removeAll { set.contains($0.id.lowercased()) || set.contains($0.label.lowercased()) }
            }
            var made: [String] = []
            for m in args.raw["add"]?.array ?? [] {
                let a = Args(m)
                var marker = Marker(id: IDs.make("m"), time: p.canvas.snap(try a.time("time")), label: try a.string("label"))
                if let k = a.optString("kind"), k != "standard" { marker.kind = k }
                marker.color = try a.color("color")
                marker.note = a.optString("note")
                if let end = try a.optTime("end") { marker.duration = max(0, end - marker.time) }
                p.markers.append(marker)
                made.append("\(marker.id) “\(marker.label)” @\(fmt2(marker.time))")
            }
            p.markers.sort { $0.time < $1.time }
            return (made.isEmpty ? "" : "Added " + made.joined(separator: ", ") + ". ") + "\(p.markers.count) markers"
        })

    }

    func registerBatchTool() {
        let batchable = edits.keys.sorted()
        add(Tool(name: "batch", description: "Run several edit tools in order as ONE history entry (one undo step). If any fails, nothing is applied. Name an operation's result with as:\"x\" (the clip, effect, track or media it created) and use \"$x\" in later arguments (names last the session, and as works on any tool call too), e.g. add an adjustment layer as \"adj\" then effect_add target \"$adj\"; \"$last\", \"$last_clip\", \"$last_effect\", \"$last_track\" and \"$last_media\" name the latest creations, here and in any tool. dry_run:true reports the combined changes without applying them.", schema: Schema.object([
            "label": Schema.string("History label for the whole change"),
            "operations": Schema.array(Schema.object([
                "tool": Schema.string("Edit tool name", values: batchable),
                "args": ["type": "object", "description": "That tool's arguments"],
                "as": Schema.string("Name for the clip or effect this operation creates"),
            ], required: ["tool"]), "Edits to apply in order"),
            "dry_run": Schema.bool("Report what would change without applying it"),
            "if_history": Schema.string("Apply only if the current history entry is this id (guards against edits made since you last looked)"),
            "verify": Schema.numbers("Timeline times to render after applying; the frames come back with the result"),
        ], required: ["operations"])) { [unowned self] args in
            guard let ops = args.raw["operations"]?.array, !ops.isEmpty else { throw EditError("operations is empty") }
            if let expected = args.optString("if_history"), let current = try session.requireBundle().loadHistory().current?.id, current != expected {
                throw EditError("The project changed since \(expected) (now at \(current)); call history diff id:\"\(expected)\" and retry")
            }
            var lines: [String] = []
            var vars = session.names
            var last = session.lastRefs
            let label = args.optString("label") ?? "Batch of \(ops.count) edits"
            let before = try session.project()
            let run: (inout Project) throws -> Void = { p in
                for (i, op) in ops.enumerated() {
                    let name = op["tool"]?.string ?? ""
                    guard let e = self.edits[name] else {
                        throw EditError("Operation \(i + 1): \(name) can't run inside batch" + (name == "recipe" ? "; call recipe on its own (it is already one undo step)" : "") + ". Batchable tools: \(self.edits.keys.sorted().joined(separator: ", "))")
                    }
                    let opBefore = p
                    do {
                        let opArgs = try Toolbox.resolveLast(Toolbox.substitute(op["args"] ?? [:], vars), last, strict: false)
                        self.installResolvers(p)
                        lines.append(try e.apply(&p, Args(opArgs)))
                    } catch {
                        throw EditError("Operation \(i + 1) (\(name)) failed, nothing applied: \(error.localizedDescription)")
                    }
                    let made = Toolbox.created(opBefore, p)
                    if let first = made.first { last["last"] = first.ids[0] }
                    for m in made { last["last_" + m.kind] = m.ids[0] }
                    if let v = op["as"]?.string {
                        guard let id = made.first?.ids.first else { throw EditError("Operation \(i + 1) created nothing to name \(v)") }
                        vars[v] = id
                        lines[lines.count - 1] += " [$\(v) = \(id)]"
                    }
                }
                p.pruneTransitions()
                try p.validate()
            }
            if args.bool("dry_run", default: false) {
                var p = before
                try run(&p)
                return .text("Dry run, nothing changed.\n" + lines.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n") + Toolbox.changesText(p, before))
            }
            let p = try session.edit(label, run)
            session.names.merge(vars) { _, new in new }
            let queued = session.queuePictures(p).map { "\n" + $0 }.joined()
            var result = ToolResult.text(lines.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n") + Toolbox.changesText(p, before) + newIssues(p, before) + queued + "\n" + footer(p))
            if let times = args.raw["verify"]?.array?.compactMap(\.double), !times.isEmpty {
                let built = try await session.timeline(for: p)
                let cell = Toolbox.cellWidth(width: p.canvas.width, height: p.canvas.height, count: times.count)
                let frames = try await Frames.timeline(built, times: Array(times.prefix(12)), maxSize: CGSize(width: cell * 1.5, height: cell * 1.5))
                if let jpeg = Frames.contactSheet(frames, cellWidth: cell) { result.addImage(jpeg) }
            }
            return result
        })
    }

    /// Replaces "$name" in every string (and object key) with the id bound by an earlier operation; with
    /// `skippingText`, free-text arguments (`literalKeys`) keep their words.
    static func substitute(_ j: JSON, _ vars: [String: String], skippingText: Bool = false, key: String? = nil) -> JSON {
        guard !vars.isEmpty else { return j }
        func sub(_ s: String) -> String {
            guard s.contains("$") else { return s }
            var out = s
            for (k, v) in vars.sorted(by: { $0.key.count > $1.key.count }) { out = out.replacingOccurrences(of: "$" + k, with: v) }
            return out
        }
        switch j {
        case .string(let s): return skippingText && literalKeys.contains(key ?? "") ? j : .string(sub(s))
        case .array(let a): return .array(a.map { substitute($0, vars, skippingText: skippingText, key: key) })
        case .object(let o): return .object(Dictionary(o.map { (sub($0.key), substitute($0.value, vars, skippingText: skippingText, key: $0.key)) }, uniquingKeysWith: { a, _ in a }))
        default: return j
        }
    }

    static func isName(_ s: String) -> Bool {
        s.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil
    }

    /// Batch operations with as given inside their args, moved beside them.
    static func liftingBatchNames(_ args: JSON?) -> JSON? {
        guard case .object(var o)? = args, let ops = o["operations"]?.array else { return args }
        o["operations"] = .array(ops.map { op in
            guard case .object(var m) = op, case .object(var inner)? = m["args"], let v = inner.removeValue(forKey: "as") else { return op }
            if m["as"] == nil { m["as"] = v }
            m["args"] = .object(inner)
            return .object(m)
        })
        return .object(o)
    }

    /// Shortens text at a word boundary, with an ellipsis.
    static func excerpt(_ s: String, _ limit: Int) -> String {
        let flat = s.replacingOccurrences(of: "\n", with: " ")
        guard flat.count > limit else { return flat }
        let cut = flat.prefix(limit)
        let words = cut.split(separator: " ").dropLast()
        return (words.isEmpty ? String(cut) : words.joined(separator: " ")) + "…"
    }

    static func clipName(_ id: String?, _ p: Project) -> String {
        guard let id, let c = p.clip(id) else { return "clip" }
        switch c.kind {
        case .text: return "title “\(excerpt(c.text?.text ?? "", 28))”"
        case .solid: return "color clip"
        case .media: return c.name ?? c.mediaId.flatMap { p.mediaAsset($0)?.name } ?? "clip"
        case .adjustment: return c.name ?? "adjustment layer"
        case .generator: return c.name ?? (c.effects.first.map { $0.type.replacingOccurrences(of: "_", with: " ") } ?? "graphic")
        case .sequence: return c.name ?? c.mediaId.flatMap { p.sequence($0)?.name } ?? "nested sequence"
        }
    }

    static func timeLabel(_ j: JSON?) -> String {
        guard let j, let t = try? Args.parseTime(j, name: "time") else { return "?" }
        return Frames.timecode(t)
    }

    static func describeUpdate(_ a: Args, _ p: Project) -> String {
        let name = clipName(a.optString("clip_id"), p)
        let keys = Set(a.raw.keys).subtracting(["clip_id", "ripple", "dry_run"])
        if let m = a.optString("media_id") { return "Replace \(name) with \(p.mediaAsset(m)?.name ?? m)" }
        if a.bool("detach_audio", default: false) { return "Detach sound of \(name)" }
        if a.bool("attach_audio", default: false) { return "Attach sound of \(name)" }
        if keys == ["unlink"] { return "Unlink \(name)" }
        if keys == ["link"] { return "Link \(name) with \(a.strings("link")?.count ?? 0) clip(s)" }
        if keys.contains("speed") { return "Change speed of \(name)" }
        if !keys.isDisjoint(with: ["source_in", "source_out", "duration", "end"]) { return "Trim \(name)" }
        if !keys.isDisjoint(with: ["start", "track"]) { return "Move \(name)" }
        if keys.contains("text") { return "Reword \(name)" }
        if keys == ["name"] { return "Rename \(name)" }
        return "Update \(name)"
    }

    static func describeTrackUpdate(_ a: Args, _ p: Project) -> String {
        let id = a.optString("track") ?? ""
        let name = p.tracks.first { $0.id == id }?.name ?? id
        if a.bool("remove", default: false) { return "Remove \(name) track" }
        if let m = a.optBool("muted") { return m ? "Mute \(name)" : "Unmute \(name)" }
        if let h = a.optBool("hidden") { return h ? "Hide \(name)" : "Show \(name)" }
        if a.optDouble("volume") != nil { return "Set \(name) volume" }
        if let r = a.optString("role") { return "Set \(name) role to \(r)" }
        if let o = a.optString("output") { return "Route \(name) to \(o)" }
        if a.has("sends") { return "Set \(name) sends" }
        return "Rename \(name)"
    }

    static func ranges(_ j: JSON?) throws -> [TimeRange] {
        guard let a = j?.array else { throw EditError("ranges must be an array of [start, end]") }
        return try a.map { r in
            if let pair = r.array, pair.count == 2 {
                return TimeRange(try Args.parseSourceTime(pair[0], name: "start"), try Args.parseSourceTime(pair[1], name: "end"))
            }
            let o = Args(r)
            return TimeRange(try o.sourceTime("start"), try o.sourceTime("end"))
        }
    }

    /// Applies the `set` object of a tool call: {path: value}.
    static func applySet(_ c: inout Clip, _ args: Args) throws {
        guard let set = args.raw["set"]?.object else { return }
        for (path, v) in set.sorted(by: { $0.key < $1.key }) { try c.set(path, try paramValue(v)) }
    }

    static func paramValue(_ j: JSON) throws -> ParamValue {
        switch j {
        case .number(let n): return .number(n)
        case .bool(let b): return .bool(b)
        case .string(let s): return .string(s)
        // Lists and objects (a shape layer's shapes) are kept as their JSON text.
        case .array, .object: return .string(j.encoded())
        default: throw EditError("Parameter values are numbers, booleans or strings; got \(j.encoded())")
        }
    }

    static let textPresets = ["lower_third", "title_card", "caption_box"]

    /// The starting style of a text_add preset; nil without one or for a title graphic.
    static func textPreset(_ name: String?, _ text: String) throws -> TextSpec? {
        guard let name else { return nil }
        switch name.lowercased().replacingOccurrences(of: "-", with: "_").replacingOccurrences(of: " ", with: "_") {
        case "lower_third", "lowerthird", "name_title", "chyron":
            return TextSpec(text: text, size: 0.045, weight: 650, background: RGBA(hex: "#000000A6"), shadow: false, align: .left, x: 0.27, y: 0.82, maxWidth: 0.45, animationIn: .slideUp)
        case "title_card", "title", "headline", "card_title":
            return TextSpec(text: text, size: 0.1, weight: 800, shadow: true, y: 0.5, maxWidth: 0.8, letterSpacing: 0.02, animationIn: .pop)
        case "caption_box", "caption", "subtitle", "boxed":
            return TextSpec(text: text, size: 0.045, weight: 600, background: RGBA(hex: "#000000B3"), shadow: false, y: 0.88, maxWidth: 0.8, animationIn: .none, animationOut: .none)
        default:
            guard titleGraphicType(name) != nil else {
                let graphics = GeneratorCatalog.all.map(\.id).filter { $0.hasPrefix("title.") }.map { String($0.dropFirst(6)) }
                throw EditError("No text preset \(name). Styles: \(textPresets.joined(separator: ", ")); title graphics: \(graphics.joined(separator: ", "))")
            }
            return nil
        }
    }

    static func titleGraphicType(_ name: String) -> String? {
        let key = name.lowercased().replacingOccurrences(of: "-", with: "_")
        return [key, "title." + key].first { $0.hasPrefix("title.") && GeneratorCatalog.type($0) != nil }
    }

    /// A title.* generator for preset `name` with `text` split into its fields: the first line is the name or
    /// title, the rest the role or subtitle (a quote's last line starting with a dash is its author).
    static func titleGraphic(_ name: String, _ text: String, _ args: Args) throws -> Effect? {
        guard try textPreset(name, text) == nil, let type = titleGraphicType(name), let spec = GeneratorCatalog.type(type) else { return nil }
        let lines = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var params: [String: ParamValue] = [:]
        func set(_ k: String, _ v: String) { if spec.spec(k) != nil, !v.isEmpty { params[k] = .string(v) } }
        switch type {
        case "title.quote":
            var body = lines
            if body.count > 1, let last = body.last, last.hasPrefix("—") || last.hasPrefix("-") || last.hasPrefix("–") {
                set("author", last.trimmingCharacters(in: CharacterSet(charactersIn: "—–- ")))
                body.removeLast()
            }
            set("quote", body.joined(separator: " "))
        case "title.data_callout":
            set("label", lines.joined(separator: " "))
        default:
            set("title", lines.first ?? text)
            set("subtitle", lines.dropFirst().joined(separator: " "))
        }
        if let v = try args.color("color"), spec.spec("text_color") != nil { params["text_color"] = .string(v.hex) }
        if let v = args.optString("font"), spec.spec("font") != nil { params["font"] = .string(v) }
        if let v = args.optDouble("size"), spec.spec("size") != nil { params["size"] = .number(v) }
        if let v = args.optDouble("text_x"), spec.spec("x") != nil { params["x"] = .number(v) }
        if let v = args.optDouble("text_y"), spec.spec("y") != nil { params["y"] = .number(v) }
        return Effect(id: "gen", type: type, params: params)
    }

    static func applyText(_ s: inout TextSpec, _ args: Args) throws {
        if let v = args.optString("font") { s.font = v }
        if let v = args.optDouble("size") { s.size = v }
        if let v = args.optInt("weight") { s.weight = v }
        if let v = try args.color("color") { s.color = v }
        if args.clearsColor("background") { s.background = nil } else if let v = try args.color("background") { s.background = v }
        if args.clearsColor("stroke") { s.stroke = nil } else if let v = try args.color("stroke") { s.stroke = v }
        if let v = args.optDouble("stroke_width") { s.strokeWidth = v }
        if s.stroke != nil && s.strokeWidth == 0 { s.strokeWidth = 0.08 }
        if let v = args.optBool("shadow") { s.shadow = v }
        if let v = try args.enumValue("align", TextAlign.self) { s.align = v }
        if let v = args.optDouble("text_x") { s.x = v }
        if let v = args.optDouble("text_y") { s.y = v }
        if let v = args.optDouble("max_width") { s.maxWidth = v }
        if let v = args.optDouble("letter_spacing") { s.letterSpacing = v }
        if let v = try args.enumValue("animation_in", TextAnimation.self) { s.animationIn = v }
        if let v = try args.enumValue("animation_out", TextAnimation.self) { s.animationOut = v }
        if let list = args.raw["spans"]?.array {
            s.spans = try list.map { j in
                let a = Args(j)
                let span = TextSpan(match: a.optString("match") ?? a.optString("text"), from: a.optInt("from"), to: a.optInt("to"), color: try a.color("color"), font: a.optString("font"), weight: a.optInt("weight"), scale: a.optDouble("scale"), italic: a.optBool("italic"), underline: a.optBool("underline"), highlight: try a.color("highlight"))
                guard span.match != nil || span.from != nil || span.to != nil else { throw EditError("Each span needs match or from/to") }
                return span
            }
            if s.spans?.isEmpty == true { s.spans = nil }
        }
        if let raw = args.raw["animator"] {
            if raw.isNull || raw.string == "none" { s.animator = nil } else {
                do { s.animator = try JSONDecoder().decode(TextAnimator.self, from: JSONEncoder().encode(raw)) } catch {
                    throw EditError("animator is {unit: char|word|line, preset: \(TextAnimator.Preset.allCases.map(\.rawValue).joined(separator: "|")), stagger, duration, ease, color, sync, out}")
                }
            }
        }
    }

    static func captionPreset(_ name: String) throws -> CaptionStyle {
        switch name {
        case "karaoke": return CaptionStyle()
        case "bold": return CaptionStyle(size: 0.075, weight: 900, highlightColor: RGBA(hex: "#FFD60A")!, strokeWidth: 0.1, uppercase: true, y: 0.68, maxWordsPerLine: 3, maxLines: 1, animation: .pop)
        case "clean": return CaptionStyle(size: 0.042, weight: 600, background: RGBA(hex: "#000000B3")!, stroke: nil, strokeWidth: 0, shadow: false, y: 0.87, maxWordsPerLine: 8, maxLines: 2, animation: .none)
        case "reveal": return CaptionStyle(size: 0.055, weight: 800, strokeWidth: 0.08, y: 0.8, maxWordsPerLine: 5, maxLines: 2, animation: .reveal)
        case "minimal": return CaptionStyle(size: 0.04, weight: 500, stroke: nil, strokeWidth: 0, shadow: true, y: 0.88, maxWordsPerLine: 8, maxLines: 1, animation: .none)
        default: throw EditError("Unknown caption preset \(name)")
        }
    }
}
