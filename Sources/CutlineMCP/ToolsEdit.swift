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
    ]

    func registerEditTools() {
        addEdit(EditTool(name: "clip_add", description: "Put media, a solid color, or an adjustment layer on the timeline. Default track: V1 for video and images, A1 for audio-only files; \"new\" makes a new layer on top. Without start the clip is appended after the track's last clip. An adjustment layer has no picture: effects on it (effect_add) apply to every layer below it for its duration.", schema: Schema.object([
            "media_id": Schema.string("Media to place"),
            "color": Schema.string("Hex color for a solid color clip"),
            "adjustment": Schema.bool("Make an adjustment layer"),
            "generator": Schema.string("Draw a graphic: shape.rect, shape.ellipse, shape.line, shape.arrow, shape.highlight, callout, lower_third, progress_bar, counter, gradient, grid_overlay (catalog type=<id> for params; animate them as fx.gen.<param>)"),
            "params": ["type": "object", "description": "Generator parameters, e.g. {\"title\": \"Ada Lovelace\", \"subtitle\": \"Mathematician\"}"],
            "track": Schema.string("Track id, or \"new\" for a new layer on top"),
            "start": Schema.time("Timeline start (seconds or anchor)"),
            "end": Schema.time("Timeline end, instead of duration"),
            "mode": Schema.string("place (exact start, fail on overlap; default when start is given), append (default without start), overwrite (replace what is under it), insert (push everything later, on all tracks)", values: PlaceMode.allCases.map(\.rawValue)),
            "source_in": Schema.time("Source start (seconds in the media, or a word anchor like \"talk.w12\")"),
            "source_out": Schema.time("Source end (seconds or word anchor such as \"talk.w40.end\")"),
            "duration": Schema.time("Timeline duration; images, solids and adjustment layers default to 5"),
            "speed": Schema.number("Playback speed, 1 = normal. With source_in, source_out and a duration or end, speed is computed to fit (fit to fill)"),
            "name": Schema.string("Label shown in the preview timeline"),
        ].merging(Toolbox.setProp) { a, _ in a }), label: { a, p in a.optString("media_id").map { id in "Add " + (p.mediaAsset(id)?.name ?? id) } ?? (a.bool("adjustment", default: false) ? "Add adjustment layer" : "Add a color clip") }) { p, args in
            var clip: Clip
            var defaultTrack = "V1"
            let start = try args.optTime("start")
            let end = try args.optTime("end")
            let span = start.flatMap { s in end.map { $0 - s } }
            if let mid = args.optString("media_id") {
                guard let m = p.mediaAsset(mid) else { throw EditError("No media \(mid). Known: \(p.media.map(\.id).joined(separator: ", "))") }
                let sIn = try args.optSourceTime("source_in") ?? 0
                var speed = args.optDouble("speed") ?? 1
                var dur: Seconds
                if m.isImage {
                    dur = try span ?? args.optTime("duration") ?? 5
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
                clip = Clip(id: Project.newClipId(), kind: .media, name: args.optString("name") ?? m.name, mediaId: mid, start: 0, duration: dur, sourceIn: m.isImage ? 0 : sIn, speed: speed)
                if !m.hasVideo { defaultTrack = p.tracks.first { $0.kind == .audio }?.id ?? "A1" }
            } else if let gen = args.optString("generator") {
                guard let spec = GeneratorCatalog.type(gen) else { throw EditError("No generator \(gen). Generators: \(GeneratorCatalog.all.map(\.id).joined(separator: ", "))") }
                var params: [String: ParamValue] = [:]
                for (k, v) in args.raw["params"]?.object ?? [:] {
                    guard let ps = spec.spec(k) else { throw EditError("\(gen) has no parameter \(k). Parameters: \(spec.params.map(\.name).joined(separator: ", "))") }
                    params[k] = try ps.validate(try Toolbox.paramValue(v), path: k)
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
            var trackId = args.optString("track") ?? defaultTrack
            if trackId == "new" {
                let kind: TrackKind = clip.kind == .media && !(p.mediaAsset(clip.mediaId!)?.hasVideo ?? true) ? .audio : .video
                let index = kind == .video ? (p.tracks.lastIndex { $0.kind == .video }.map { $0 + 1 } ?? 0) : p.tracks.count
                trackId = p.addTrack(kind: kind, name: clip.kind == .adjustment ? "Adjustment" : kind == .video ? "Overlay" : "Audio", index: index).id
            }
            let mode = try args.enumValue("mode", PlaceMode.self) ?? (start == nil ? .append : .place)
            clip.start = start ?? 0
            let placed = try p.addClip(clip, trackId: trackId, mode: mode)
            return "Added \(placed.id) on \(trackId) at \(fmt(placed.start))–\(fmt(placed.end))"
        })

        addEdit(EditTool(name: "text_add", description: "Add a title, lower third, label or call-out. Goes on a text layer above the video (created as needed, a new one if the range is busy).", schema: Schema.object(Toolbox.textProps.merging([
            "start": Schema.time("Timeline start (seconds or anchor such as \"talk.w40\")"),
            "end": Schema.time("Timeline end, instead of duration (e.g. \"talk.w46.end\")"),
            "duration": Schema.time("How long it shows, default 3"),
            "track": Schema.string("Track id; default picks or creates a text layer"),
        ]) { a, _ in a }.merging(Toolbox.setProp) { a, _ in a }, required: ["text", "start"]), label: { a, _ in "Add title “\(Toolbox.excerpt(a.optString("text") ?? "", 34))”" }) { p, args in
            var spec = TextSpec(text: try args.string("text"))
            try Toolbox.applyText(&spec, args)
            let start = p.canvas.snap(try args.time("start"))
            let duration = try args.optTime("end").map { $0 - start } ?? args.optTime("duration") ?? 3
            var clip = Clip(id: Project.newClipId(), kind: .text, name: String(spec.text.prefix(30)), start: start, duration: duration, text: spec)
            try Toolbox.applySet(&clip, args)
            let range = TimeRange(start, start + duration)
            let trackId: String
            if let t = args.optString("track") {
                trackId = t
            } else if let free = p.tracks.last(where: { t in
                t.kind == .video && !t.clips.isEmpty && t.clips.allSatisfy { $0.kind == .text } && !t.clips.contains { TimeRange($0.start, $0.end).intersection(range) != nil }
            }) {
                trackId = free.id
            } else {
                trackId = p.addTrack(kind: .video, name: "Text", index: p.tracks.lastIndex { $0.kind == .video }.map { $0 + 1 } ?? 0).id
            }
            let placed = try p.addClip(clip, trackId: trackId, mode: .place)
            return "Added text \(placed.id) on \(trackId) at \(fmt(placed.start))–\(fmt(placed.end))"
        })

        addEdit(EditTool(name: "clip_update", description: "Change a clip's timing or place: move it (start, track), trim it (source_in/source_out keep the start; duration or end trim the tail), change speed (keeps the source range), rename it, or change a title's words. Appearance, audio levels and animation go through param_set and effect_add. If the new end collides with the next clip, pass ripple=true to shift later clips on that track.", schema: Schema.object([
            "clip_id": Schema.string("Clip id"),
            "start": Schema.time("New timeline start (seconds or anchor)"),
            "end": Schema.time("New timeline end; trims the tail"),
            "duration": Schema.time("New timeline duration; trims the tail"),
            "source_in": Schema.time("New source start (seconds or word anchor); trims the head, start stays"),
            "source_out": Schema.time("New source end (seconds or word anchor)"),
            "speed": Schema.number("Playback speed; keeps the source range"),
            "track": Schema.string("Move to this track (overwrites what is there)"),
            "name": Schema.string("Label"),
            "text": Schema.string("New words for a title clip"),
            "ripple": Schema.bool("Shift later clips on the track by the change in end time, default false"),
        ], required: ["clip_id"]), label: { a, p in Toolbox.describeUpdate(a, p) }) { p, args in
            let id = try args.string("clip_id")
            guard var c = p.clip(id) else { throw EditError("No clip \(id)") }
            if let v = args.optDouble("speed") {
                let src = c.duration * c.speed
                c.speed = v
                c.duration = src / v
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
            if let s = try args.optTime("start") { c.start = s }
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
            try p.replaceClip(c, ripple: args.bool("ripple", default: false))
            let now = p.clip(id)!
            return "Updated \(id): \(Describe.clip(now, p))"
        })

        addEdit(EditTool(name: "clip_split", description: "Split at a timeline time: one clip (clip_id) or every clip under that time on the given tracks (default all).", schema: Schema.object([
            "time": Schema.time("Timeline time"),
            "clip_id": Schema.string("Only split this clip"),
            "track_ids": Schema.strings("Only these tracks when clip_id is omitted"),
        ], required: ["time"]), label: { a, _ in "Split at \(Toolbox.timeLabel(a.raw["time"]))" }) { p, args in
            let t = try args.time("time")
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
            try p.deleteClips(ids, ripple: args.bool("ripple", default: false))
            return "Deleted \(ids.joined(separator: ", "))"
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
        ], required: ["segments"]), label: { a, _ in "Assemble \(a.raw["segments"]?.array?.count ?? 0) takes" }) { p, args in
            guard let raw = args.raw["segments"]?.array, !raw.isEmpty else { throw EditError("segments is empty") }
            let segs = try raw.map { j -> SourceSegment in
                let a = Args(j)
                return SourceSegment(mediaId: try a.string("media_id"), sourceIn: try a.sourceTime("start"), sourceOut: try a.sourceTime("end"))
            }
            let replace = args.bool("replace", default: false)
            var made = try p.assemble(segs, trackId: args.optString("track") ?? "V1", at: try args.optTime("at") ?? (replace ? 0 : nil), replaceTrack: replace)
            if let fit = try args.enumValue("fit", FitMode.self) {
                for i in made.indices {
                    made[i].transform.fit = fit
                    try p.replaceClip(made[i])
                }
            }
            return "Placed \(made.count) clips: " + made.map { "\($0.id) \(fmt2($0.start))–\(fmt2($0.end))" }.joined(separator: ", ")
        })

        addEdit(EditTool(name: "cut_silences", description: "Tighten talking footage: remove pauses longer than min_pause (leaving `keep` seconds of breathing room) and, by default, filler words (um, uh…). Works in source time on every clip of the media, rippling all tracks. Check the result with timeline_transcript.", schema: Schema.object([
            "media_id": Schema.string("Media id; default every transcribed media on the timeline"),
            "min_pause": Schema.time("Only pauses at least this long, default 0.5"),
            "keep": Schema.time("Pause length to leave behind, default 0.2"),
            "fillers": Schema.bool("Also remove filler words, default true"),
        ]), label: { a, _ in a.bool("fillers", default: true) ? "Cut pauses and filler words" : "Cut pauses" }) { [unowned self] p, args in
            let b = try session.requireBundle()
            let minPause = try args.optTime("min_pause") ?? 0.5
            let keep = try args.optTime("keep") ?? 0.2
            let ids = args.optString("media_id").map { [$0] } ?? Array(Set(p.tracks.flatMap(\.clips).compactMap(\.mediaId))).sorted()
            var report: [String] = []
            for id in ids {
                guard let audio = b.audioAnalysis(id) else { continue }
                var ranges = audio.silences.filter { $0.duration >= minPause }.map { TimeRange($0.start + keep / 2, $0.end - keep / 2) }
                var fillerCount = 0
                if args.bool("fillers", default: true), let t = b.transcript(id) {
                    let fillers = t.words.filter(\.isFiller).map { TimeRange($0.start, $0.end) }
                    fillerCount = fillers.filter { !p.timelineRanges(mediaId: id, sourceRanges: [$0]).isEmpty }.count
                    ranges += fillers
                }
                let removed = p.cutSourceRanges(mediaId: id, ranges: TimeRange.merged(ranges, tolerance: 0.05))
                if !removed.isEmpty {
                    report.append("\(id): \(removed.count) cuts, \(fmt2(removed.map(\.duration).reduce(0, +)))s removed (\(fillerCount) fillers)")
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

        addEdit(EditTool(name: "track_update", description: "Rename, mute, hide, set volume of, or remove a track.", schema: Schema.object([
            "track_id": Schema.string("Track id"),
            "name": Schema.string("Name"),
            "muted": Schema.bool("Mute audio"),
            "hidden": Schema.bool("Hide picture"),
            "volume": Schema.number("0–2, multiplies clip volumes (e.g. 0.25 to duck music under speech)"),
            "remove": Schema.bool("Delete the track and its clips"),
            "role": Schema.string("Audio role for stem export: dialogue, music, effects, or a custom name"),
        ], required: ["track_id"]), label: { a, p in Toolbox.describeTrackUpdate(a, p) }) { p, args in
            let id = try args.string("track_id")
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
            "max_words_per_line": Schema.integer("Words per line"),
            "max_lines": Schema.integer("Lines per caption"),
            "animation": Schema.string("Animation", values: CaptionAnimation.allCases.map(\.rawValue)),
            "replacements": ["type": "object", "additionalProperties": ["type": "string"], "description": "Word fixes, e.g. {\"cut line\": \"Cutline\"}; merged into existing ones, empty string value deletes"],
            "hidden_words": Schema.strings("Words never captioned, e.g. fillers you kept in the audio"),
            "track_ids": Schema.strings("Only caption speech from these tracks"),
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
            p.captions = c
            return c.enabled ? "Captions on (\(s.animation.rawValue), size \(fmt2(s.size)), y \(fmt2(s.y)))" : "Captions off"
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
            "update": Schema.array(Schema.object(["id": Schema.string("Marker id or label"), "kind": Schema.string("New kind"), "label": Schema.string("New label"), "note": Schema.string("New note")], required: ["id"]), "Change markers, e.g. mark a to-do done"),
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
        add(Tool(name: "batch", description: "Run several edit tools in order as ONE history entry (one undo step). If any fails, nothing is applied. Name an operation's result with as:\"x\" (the clip or effect it created) and use \"$x\" in later arguments, e.g. add an adjustment layer as \"adj\" then effect_add target \"$adj\". dry_run:true reports the combined changes without applying them.", schema: Schema.object([
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
            var vars: [String: String] = [:]
            let label = args.optString("label") ?? "Batch of \(ops.count) edits"
            let before = try session.project()
            let run: (inout Project) throws -> Void = { p in
                for (i, op) in ops.enumerated() {
                    let name = op["tool"]?.string ?? ""
                    guard let e = self.edits[name] else { throw EditError("Operation \(i + 1): \(name) is not an edit tool") }
                    let opArgs = Toolbox.substitute(op["args"] ?? [:], vars)
                    let clipsBefore = Set(p.tracks.flatMap(\.clips).map(\.id))
                    let fxBefore = Set(p.tracks.flatMap { t in t.effects.map(\.id) + t.clips.flatMap { $0.effects.map(\.id) } })
                    do {
                        self.installResolvers(p)
                        lines.append(try e.apply(&p, Args(opArgs)))
                    } catch {
                        throw EditError("Operation \(i + 1) (\(name)) failed, nothing applied: \(error.localizedDescription)")
                    }
                    if let v = op["as"]?.string {
                        let newClips = Set(p.tracks.flatMap(\.clips).map(\.id)).subtracting(clipsBefore)
                        let newFx = Set(p.tracks.flatMap { t in t.effects.map(\.id) + t.clips.flatMap { $0.effects.map(\.id) } }).subtracting(fxBefore)
                        guard let made = newClips.sorted().first ?? newFx.sorted().first else { throw EditError("Operation \(i + 1) created nothing to name \(v)") }
                        vars[v] = made
                        lines[lines.count - 1] += " [$\(v) = \(made)]"
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
            var result = ToolResult.text(lines.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n") + Toolbox.changesText(p, before) + newIssues(p, before) + "\n" + footer(p))
            if let times = args.raw["verify"]?.array?.compactMap(\.double), !times.isEmpty {
                let built = try await session.timeline(for: p)
                let cell = Toolbox.cellWidth(width: p.canvas.width, height: p.canvas.height, count: times.count)
                let frames = try await Frames.timeline(built, times: Array(times.prefix(12)), maxSize: CGSize(width: cell * 1.5, height: cell * 1.5))
                if let jpeg = Frames.contactSheet(frames, cellWidth: cell) { result.addImage(jpeg) }
            }
            return result
        })
    }

    /// Replaces "$name" in every string (and object key) with the id bound by an earlier operation.
    static func substitute(_ j: JSON, _ vars: [String: String]) -> JSON {
        guard !vars.isEmpty else { return j }
        func sub(_ s: String) -> String {
            var out = s
            for (k, v) in vars.sorted(by: { $0.key.count > $1.key.count }) { out = out.replacingOccurrences(of: "$" + k, with: v) }
            return out
        }
        switch j {
        case .string(let s): return .string(sub(s))
        case .array(let a): return .array(a.map { substitute($0, vars) })
        case .object(let o): return .object(Dictionary(o.map { (sub($0.key), substitute($0.value, vars)) }, uniquingKeysWith: { a, _ in a }))
        default: return j
        }
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
        let keys = Set(a.raw.keys).subtracting(["clip_id", "ripple"])
        if keys.contains("speed") { return "Change speed of \(name)" }
        if !keys.isDisjoint(with: ["source_in", "source_out", "duration", "end"]) { return "Trim \(name)" }
        if !keys.isDisjoint(with: ["start", "track"]) { return "Move \(name)" }
        if keys.contains("text") { return "Reword \(name)" }
        if keys == ["name"] { return "Rename \(name)" }
        return "Restyle \(name)"
    }

    static func describeTrackUpdate(_ a: Args, _ p: Project) -> String {
        let id = a.optString("track_id") ?? ""
        let name = p.tracks.first { $0.id == id }?.name ?? id
        if a.bool("remove", default: false) { return "Remove \(name) track" }
        if let m = a.optBool("muted") { return m ? "Mute \(name)" : "Unmute \(name)" }
        if let h = a.optBool("hidden") { return h ? "Hide \(name)" : "Show \(name)" }
        if a.optDouble("volume") != nil { return "Set \(name) volume" }
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
        default: throw EditError("Parameter values are numbers, booleans or strings; got \(j.encoded())")
        }
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
