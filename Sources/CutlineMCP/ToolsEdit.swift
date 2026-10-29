import CutlineCore
import CutlineEngine
import Foundation

extension Toolbox {
    static let transformProps: [String: JSON] = [
        "fit": Schema.string("fit (letterbox, default), fill (cover the canvas, cropping overflow; use for vertical videos from landscape footage) or stretch", values: ["fit", "fill", "stretch"]),
        "scale": Schema.number("1 = size given by fit"),
        "x": Schema.number("Horizontal offset as a fraction of canvas width, + moves right"),
        "y": Schema.number("Vertical offset as a fraction of canvas height, + moves down"),
        "rotation": Schema.number("Degrees clockwise"),
        "opacity": Schema.number("0–1"),
        "crop": Schema.object(["left": Schema.number("fraction"), "top": Schema.number("fraction"), "right": Schema.number("fraction"), "bottom": Schema.number("fraction")]),
        "fade_in": Schema.time("Picture fade-in duration"),
        "fade_out": Schema.time("Picture fade-out duration"),
        "keyframes": Schema.array(Schema.object([
            "time": Schema.number("Seconds from the clip start"),
            "scale": Schema.number("scale"), "x": Schema.number("x"), "y": Schema.number("y"),
            "rotation": Schema.number("rotation"), "opacity": Schema.number("opacity"),
            "easing": Schema.string("Easing into this keyframe", values: ["linear", "easeIn", "easeOut", "easeInOut"]),
        ], required: ["time"]), "Animate transform values over the clip (e.g. Ken Burns zoom: scale 1 at 0 → 1.15 at end). Replaces existing keyframes; [] clears them."),
    ]

    static let textProps: [String: JSON] = [
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
        addEdit(EditTool(name: "clip_add", description: "Put a media file (or a solid color) on the timeline. Default track: V1 for video/images, A1 for audio-only files. Use track \"new\" to put b-roll or overlays on a fresh layer above. Without start, the clip is appended after the track's last clip.", schema: Schema.object([
            "media_id": Schema.string("Media to place"),
            "color": Schema.string("Hex color for a solid color clip instead of media"),
            "track": Schema.string("Track id, or \"new\" for a new layer on top"),
            "start": Schema.time("Timeline start"),
            "mode": Schema.string("place (exact start, fail on overlap; default when start is given), append (default without start), overwrite (replace what is under it), insert (push everything later, on all tracks)", values: PlaceMode.allCases.map(\.rawValue)),
            "source_in": Schema.time("Source start, default 0"),
            "source_out": Schema.time("Source end, default the end of the media"),
            "duration": Schema.time("Timeline duration; required for images and solids (default 5)"),
            "speed": Schema.number("Playback speed, 1 = normal"),
            "volume": Schema.number("0–2, 1 = unchanged, 0 = silent"),
            "audio_fade_in": Schema.time("Audio fade-in"),
            "audio_fade_out": Schema.time("Audio fade-out"),
            "name": Schema.string("Label shown in the preview timeline"),
        ].merging(Toolbox.transformProps) { a, _ in a }), label: { a, p in a.optString("media_id").map { id in "Add " + (p.mediaAsset(id)?.name ?? id) } ?? "Add a color clip" }) { p, args in
            var clip: Clip
            var defaultTrack = "V1"
            if let mid = args.optString("media_id") {
                guard let m = p.mediaAsset(mid) else { throw EditError("No media \(mid). Known: \(p.media.map(\.id).joined(separator: ", "))") }
                let sIn = try args.optTime("source_in") ?? 0
                let speed = args.optDouble("speed") ?? 1
                var dur: Seconds
                if m.isImage {
                    dur = try args.optTime("duration") ?? 5
                } else if let sOut = try args.optTime("source_out") {
                    dur = (sOut - sIn) / speed
                } else if let d = try args.optTime("duration") {
                    dur = d
                } else {
                    dur = (m.duration - sIn) / speed
                }
                clip = Clip(id: Project.newClipId(), kind: .media, name: args.optString("name") ?? m.name, mediaId: mid, start: 0, duration: dur, sourceIn: m.isImage ? 0 : sIn, speed: speed)
                if !m.hasVideo { defaultTrack = p.tracks.first { $0.kind == .audio }?.id ?? "A1" }
            } else if let color = try args.color("color") {
                clip = Clip(id: Project.newClipId(), kind: .solid, name: args.optString("name") ?? "Color", start: 0, duration: try args.optTime("duration") ?? 5, color: color)
            } else {
                throw EditError("Pass media_id or color")
            }
            if let v = args.optDouble("volume") { clip.volume = v }
            if let v = try args.optTime("audio_fade_in") { clip.audioFadeIn = v }
            if let v = try args.optTime("audio_fade_out") { clip.audioFadeOut = v }
            try Toolbox.applyTransform(&clip, args)
            var trackId = args.optString("track") ?? defaultTrack
            if trackId == "new" {
                let kind: TrackKind = clip.kind == .media && !(p.mediaAsset(clip.mediaId!)?.hasVideo ?? true) ? .audio : .video
                let index = kind == .video ? (p.tracks.lastIndex { $0.kind == .video }.map { $0 + 1 } ?? 0) : p.tracks.count
                trackId = p.addTrack(kind: kind, name: kind == .video ? "Overlay" : "Audio", index: index).id
            }
            let start = try args.optTime("start")
            let mode = try args.enumValue("mode", PlaceMode.self) ?? (start == nil ? .append : .place)
            clip.start = start ?? 0
            let placed = try p.addClip(clip, trackId: trackId, mode: mode)
            return "Added \(placed.id) on \(trackId) at \(fmt(placed.start))–\(fmt(placed.end))"
        })

        addEdit(EditTool(name: "text_add", description: "Add a title, lower third, label or call-out. Goes on a text layer above the video (created as needed, a new one if the range is busy).", schema: Schema.object(Toolbox.textProps.merging([
            "start": Schema.time("Timeline start"),
            "duration": Schema.time("How long it shows, default 3"),
            "track": Schema.string("Track id; default picks or creates a text layer"),
        ]) { a, _ in a }.merging(Toolbox.transformProps.filter { ["scale", "rotation", "opacity", "keyframes", "x", "y"].contains($0.key) }) { a, _ in a }, required: ["text", "start"]), label: { a, _ in "Add title “\(Toolbox.excerpt(a.optString("text") ?? "", 34))”" }) { p, args in
            var spec = TextSpec(text: try args.string("text"))
            try Toolbox.applyText(&spec, args)
            let start = p.canvas.snap(try args.time("start"))
            let duration = try args.optTime("duration") ?? 3
            var clip = Clip(id: Project.newClipId(), kind: .text, name: String(spec.text.prefix(30)), start: start, duration: duration, text: spec)
            try Toolbox.applyTransform(&clip, args)
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

        addEdit(EditTool(name: "clip_update", description: "Change any property of a clip: timing (start, duration, source_in/source_out trims, speed), audio (volume, fades), picture (fit, scale, position, rotation, opacity, crop, fades, keyframes) or text styling. Changing source range or speed recomputes duration. If the new end collides with the next clip, pass ripple=true to shift later clips on that track.", schema: Schema.object([
            "clip_id": Schema.string("Clip id"),
            "start": Schema.time("New timeline start"),
            "duration": Schema.time("New timeline duration (trims the end)"),
            "source_in": Schema.time("New source start (trims the head, start stays)"),
            "source_out": Schema.time("New source end"),
            "speed": Schema.number("Playback speed; keeps the source range"),
            "volume": Schema.number("0–2"),
            "audio_fade_in": Schema.time("Audio fade-in"),
            "audio_fade_out": Schema.time("Audio fade-out"),
            "color": Schema.string("Solid clip color"),
            "name": Schema.string("Label"),
            "ripple": Schema.bool("Shift later clips on the track by the change in end time, default false"),
        ].merging(Toolbox.transformProps) { a, _ in a }.merging(Toolbox.textProps) { a, _ in a }, required: ["clip_id"]), label: { a, p in Toolbox.describeUpdate(a, p) }) { p, args in
            let id = try args.string("clip_id")
            guard var c = p.clip(id) else { throw EditError("No clip \(id)") }
            if let s = try args.optTime("start") { c.start = s }
            if let v = args.optDouble("speed") {
                let src = c.duration * c.speed
                c.speed = v
                c.duration = src / v
            }
            let sIn = try args.optTime("source_in"), sOut = try args.optTime("source_out")
            if sIn != nil || sOut != nil {
                let newIn = sIn ?? c.sourceIn
                let newOut = sOut ?? c.sourceOut
                guard newOut > newIn else { throw EditError("source_out must be after source_in") }
                c.sourceIn = newIn
                c.duration = (newOut - newIn) / c.speed
            }
            if let d = try args.optTime("duration") { c.duration = d }
            if let v = args.optDouble("volume") { c.volume = v }
            if let v = try args.optTime("audio_fade_in") { c.audioFadeIn = v }
            if let v = try args.optTime("audio_fade_out") { c.audioFadeOut = v }
            if let v = try args.color("color") { c.color = v }
            if let v = args.optString("name") { c.name = v }
            try Toolbox.applyTransform(&c, args)
            if c.kind == .text, var spec = c.text {
                if let t = args.optString("text") { spec.text = t }
                try Toolbox.applyText(&spec, args)
                c.text = spec
            }
            try p.replaceClip(c, ripple: args.bool("ripple", default: false))
            let now = p.clip(id)!
            return "Updated \(id): \(Describe.clip(now, p))"
        })

        addEdit(EditTool(name: "clip_move", description: "Move a clip to a new start and/or track. Fails if the destination is occupied on the same track; on another track it overwrites.", schema: Schema.object([
            "clip_id": Schema.string("Clip id"),
            "start": Schema.time("New timeline start"),
            "track": Schema.string("Destination track id"),
        ], required: ["clip_id", "start"]), label: { a, p in "Move \(Toolbox.clipName(a.optString("clip_id"), p))" }) { p, args in
            let id = try args.string("clip_id")
            try p.moveClip(id, start: try args.time("start"), trackId: args.optString("track"))
            let c = p.clip(id)!
            return "Moved \(id) to \(fmt(c.start))–\(fmt(c.end))"
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
            "ranges": Schema.array(Schema.numbers("[start, end]"), "Source ranges to remove, e.g. [[12.4, 15.0], [31.2, 31.8]]"),
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
                "start": Schema.time("Source start"),
                "end": Schema.time("Source end"),
            ], required: ["media_id", "start", "end"]), "Segments in playback order"),
            "track": Schema.string("Track id, default V1"),
            "at": Schema.time("Timeline start, default the track end (or 0 with replace)"),
            "replace": Schema.bool("Clear the track first, default false"),
            "fit": Schema.string("Framing for every placed clip; fill crops landscape footage to cover a vertical canvas", values: ["fit", "fill", "stretch"]),
        ], required: ["segments"]), label: { a, _ in "Assemble \(a.raw["segments"]?.array?.count ?? 0) takes" }) { p, args in
            guard let raw = args.raw["segments"]?.array, !raw.isEmpty else { throw EditError("segments is empty") }
            let segs = try raw.map { j -> SourceSegment in
                let a = Args(j)
                return SourceSegment(mediaId: try a.string("media_id"), sourceIn: try a.time("start"), sourceOut: try a.time("end"))
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

        addEdit(EditTool(name: "marker_add", description: "Drop a labeled marker on the timeline (shown to the human), e.g. chapter points.", schema: Schema.object([
            "time": Schema.time("Timeline time"),
            "label": Schema.string("Label"),
        ], required: ["time", "label"]), label: { a, _ in "Mark “\(a.optString("label") ?? "")”" }) { p, args in
            let m = Marker(id: IDs.make("m"), time: try args.time("time"), label: try args.string("label"))
            p.markers.append(m)
            p.markers.sort { $0.time < $1.time }
            return "Added marker \(m.id)"
        })

        addEdit(EditTool(name: "marker_remove", description: "Remove markers by id, or all.", schema: Schema.object([
            "marker_ids": Schema.strings("Marker ids"),
            "all": Schema.bool("Remove every marker"),
        ]), label: { _, _ in "Remove markers" }) { p, args in
            if args.bool("all", default: false) { p.markers.removeAll() } else {
                let ids = Set(args.strings("marker_ids") ?? [])
                p.markers.removeAll { ids.contains($0.id) }
            }
            return "Markers: \(p.markers.count)"
        })

        let batchable = edits.keys.sorted()
        add(Tool(name: "batch", description: "Run several edit tools in order as ONE history entry (one undo step). If any fails, nothing is applied. Use for multi-step changes like adding b-roll with a title and music ducking.", schema: Schema.object([
            "label": Schema.string("History label for the whole change"),
            "operations": Schema.array(Schema.object([
                "tool": Schema.string("Edit tool name", values: batchable),
                "args": ["type": "object", "description": "That tool's arguments"],
            ], required: ["tool"]), "Edits to apply in order"),
        ], required: ["operations"])) { [unowned self] args in
            guard let ops = args.raw["operations"]?.array, !ops.isEmpty else { throw EditError("operations is empty") }
            var lines: [String] = []
            let label = args.optString("label") ?? "Batch of \(ops.count) edits"
            let p = try session.edit(label) { p in
                for (i, op) in ops.enumerated() {
                    let name = op["tool"]?.string ?? ""
                    guard let e = edits[name] else { throw EditError("Operation \(i + 1): \(name) is not an edit tool") }
                    do {
                        lines.append(try e.apply(&p, Args(op["args"])))
                    } catch {
                        throw EditError("Operation \(i + 1) (\(name)) failed, nothing applied: \(error.localizedDescription)")
                    }
                }
                try p.validate()
            }
            return .text(lines.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n") + "\n" + footer(p))
        })
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
        if !keys.isDisjoint(with: ["source_in", "source_out", "duration"]) { return "Trim \(name)" }
        if !keys.isDisjoint(with: ["fade_in", "fade_out", "audio_fade_in", "audio_fade_out"]) { return "Fade \(name)" }
        if !keys.isDisjoint(with: ["volume"]) { return "Change volume of \(name)" }
        if !keys.isDisjoint(with: ["keyframes"]) { return "Animate \(name)" }
        if !keys.isDisjoint(with: ["fit", "scale", "x", "y", "rotation", "crop", "opacity"]) { return "Reframe \(name)" }
        if keys.contains("start") { return "Move \(name)" }
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
                return TimeRange(try Args.parseTime(pair[0], name: "start"), try Args.parseTime(pair[1], name: "end"))
            }
            let o = Args(r)
            return TimeRange(try o.time("start"), try o.time("end"))
        }
    }

    static func applyTransform(_ c: inout Clip, _ args: Args) throws {
        var t = c.transform
        if let v = try args.enumValue("fit", FitMode.self) { t.fit = v }
        if let v = args.optDouble("scale") { t.scale = v }
        if let v = args.optDouble("x") { t.x = v }
        if let v = args.optDouble("y") { t.y = v }
        if let v = args.optDouble("rotation") { t.rotation = v }
        if let v = args.optDouble("opacity") { t.opacity = v }
        if let crop = args.raw["crop"]?.object {
            let a = Args(raw: crop)
            t.crop = Crop(left: a.optDouble("left") ?? 0, top: a.optDouble("top") ?? 0, right: a.optDouble("right") ?? 0, bottom: a.optDouble("bottom") ?? 0)
        }
        c.transform = t
        if let v = try args.optTime("fade_in") { c.fadeIn = v }
        if let v = try args.optTime("fade_out") { c.fadeOut = v }
        if let ks = args.raw["keyframes"]?.array {
            c.keyframes = try ks.map { k in
                let a = Args(k)
                return Keyframe(time: try a.time("time"), scale: a.optDouble("scale"), x: a.optDouble("x"), y: a.optDouble("y"), rotation: a.optDouble("rotation"), opacity: a.optDouble("opacity"), easing: try a.enumValue("easing", Easing.self) ?? .easeInOut)
            }
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
