import CoreGraphics
import CutlineCore
import CutlineEngine
import Foundation

extension Toolbox {
    static let recipeNames = ["duck", "loudness_normalize", "split_edit", "room_tone", "fill_gaps", "speed_ramp", "freeze_frame", "punch_in", "pip", "split_screen", "reframe", "beat_cut", "music_fit", "look", "glitch", "whip_pan", "template", "multicam_switch", "kinetic_text", "follow", "sync_audio", "match_color", "grade_group", "qualify"]

    static let recipeDocs = """
        duck: {music: clip or track ids (default: audio tracks without speech), under: track ids with speech, amount_db: 12, attack: 0.3, release: 0.8}. \
        loudness_normalize: {target_lufs: -14, ceiling_db: -1.5 (true-peak ceiling), limit: true, persist: true, off: false}; sets master gain and a limiter for preview and, with persist, keeps the target on the master so every export measures the mix and conforms it (gain plus true-peak limiter) even after later mix changes; off:true clears the target. \
        split_edit: {edit: "clip_a|clip_b", offset: seconds (+ J cut, − L cut)}. \
        room_tone: {start, end (timeline), media, source_start, source_end (a quiet stretch of that media's sound, in source time; 2 s or more sounds best), track (default a new audio track "Room tone"), crossfade: 0.25}; fills the range with that room tone, looped from varied start points with short crossfades so the repeat isn't heard. \
        fill_gaps: {track: the dialogue track, media, source_start, source_end (a quiet stretch, as room_tone), into (default a new audio track "Room tone"), min_gap: 0.04, crossfade: 0.25 (shortened to half of a shorter gap)}; fills every gap between that track's sounds with room tone so the background never drops out. \
        speed_ramp: {clip, at: time (default middle), speed: 0.3, ramp: 0.3, hold: 0.8}. \
        freeze_frame: {at: time, duration: 1.5, track (default top video at that time), zoom: 1 (e.g. 1.08 pushes in)}. \
        punch_in: {clips (default: every other jump cut on track), track: "V1", amount: 1.15, settle: false (start slightly tighter and ease out)}; centers on faces when shots are analyzed. \
        pip: {clip, corner: top_left|top_right|bottom_left|bottom_right|center, size: 0.3, margin: 0.04, roundness: 0.12, border: color or none}. \
        split_screen: {clips: [ids], layout: lr|tb|grid, gap: 0.01}. \
        reframe: {aspect: "9:16"|"1:1"|"4:5"|"16:9", height: 1920}; follows faces or the salient subject when shots are analyzed. \
        beat_cut: {media: [ids] (uses analyzed shots, best first) or sources: [{media, start, end}], start, end (timeline), every: 1|2|4 beats, track: "new"}. \
        music_fit: {clip (music clip), length (seconds) or end (timeline time or anchor to end on), fade_out: 1.5}; cuts out or repeats whole bars at downbeats so the song keeps its own ending. \
        look: {look: teal_orange|warm_film|cool_night|bleach_bypass|vintage_fade|high_contrast_bw|golden_hour|matrix_green|pastel|noir, amount: 0.8, grain: 0.2, vignette: 0.4, start, end}; adds an adjustment layer. \
        glitch: {at: [times or anchors], duration: 0.3, amount: 0.8}; adds glitch hits on an adjustment track. \
        whip_pan: {cut: "clip_a|clip_b", direction: left, duration: 0.35}. \
        template: {template: name (omit to list templates), at: time, values: {field: text}}. \
        match_color: {clips: [ids] and/or track (default every media clip on V1), reference: clip id whose look the others match, reference_at: timeline time of the exact reference frame (picks the clip there when reference is omitted), strength: 0.8 (0…1), allow_large: false}; shot matching like Resolve's: measures each shot's tones and color (inside its crop, ignoring letterbox bars; robust to a few extreme pixels) and adds a match LUT (effect "match") in front of its other color effects; lightness moves at most ±20 L unless allow_large, colorfulness at most ±25%, black and white stay put; warns when a shot isn't comparable with the reference (big lightness or colorfulness gap, different tones or content). \
        qualify: {clip, x, y (frame fractions of a color to key, with radius: 0.02) or face: true (n: 0, largest first), at: timeline time (default the clip's middle), effect: existing effect id to key (default a new one), type: "color.wheels" for a new effect, window: true with face (an ellipse window on the face)}; the eyedropper: samples the picture as that effect receives it and sets its hue/saturation/luma qualifier ranges and matte cleanup to cover the sampled colors. \
        grade_group: {clips: [ids] (or track: "V1" for every media clip on it), id: "group1", effect: {type: "color.wheels", params: {...}}}; adds one shared effect with that id to every clip (adding clips to an existing group copies its current settings). Change the whole group at once with param_set target "group:group1" and fx.group1.<param>; effect_add target "group:group1" works too. \
        sync_audio: {clips: [video clip ids] (default every clip of that camera media on V1), audio: media id of the separate recorder, track: audio track (default new "Production sound"), keep_camera: false, channel: recorder channel to sync by ("ch3", "mix:1,2"; default its analysis channel or every channel with sound), camera_channel: the same for the camera, play: routing the placed sound plays, e.g. "ch2" (default as recorded)}; lines up dual-system sound by waveform, links it to the picture and mutes the camera mic. \
        follow: {clip: the graphic, title or overlay to move, target: "track:<id>" (media_track) or "face:<media>[:n]", offset_x: 0, offset_y: -0.1 (fractions of the frame; negative is above), smooth: 0.2}; keeps the clip on its subject wherever the media plays. \
        kinetic_text: {start, end (timeline or word anchors), preset: pop, unit: word, size: 0.09, y: 0.5, color, highlight: color, uppercase: false, max_width: 0.8}; spoken words appear as they are said. \
        multicam_switch: {angles: [media ids], audio: media with the main sound (default first angle), signal: auto|mics|speakers (auto: whose own mic is loudest when each angle records its person, else speaker analysis), speakers: {"S1": media, ...} (default S1→first angle, S2→second…), wide: media for long turns, reaction: true or seconds (cut to the listener in turns longer than that, default 5), start, end (source seconds of audio), min_shot: 1.0, at: timeline time, track: "V1", channel: source channel(s) of each angle to sync and compare mics by, e.g. "ch3" (default its analysis channel or every channel with sound), audio_channel: the main sound's channel to sync to}; syncs angles by their sound and cuts per speaker turn in the pause before each new speaker, never inside a word. Or {cuts: [{at: timeline time, angle: media}], track: "V1"} to switch angles by hand like a multicam editor: splits there and plays that angle in sync from then on.
        """

    func moreRecipes(_ name: String, _ a: Args, dry: Bool) async throws -> ToolResult {
        let b = try session.requireBundle()
        let current = try session.project()
        // Face-driven recipes are only as good as the shot analysis; wait briefly for it, then say if it's still missing.
        if ["reframe", "punch_in", "follow"].contains(name) {
            let used = Set(current.tracks.flatMap(\.clips).compactMap(\.mediaId))
            if session.jobs.active.contains(where: { used.contains($0.mediaId) && $0.features.contains("shots") }) {
                await session.jobs.wait(timeout: 240)
            }
            if let job = session.jobs.active.first(where: { used.contains($0.mediaId) && $0.features.contains("shots") }) {
                throw EditError("Shot and face analysis of \(job.mediaId) is still running (\(Int(job.progress * 100))%); call analysis_read wait: 300, then run \(name) again")
            }
        }
        switch name {
        case "room_tone", "fill_gaps":
            let mid = try a.string("media")
            let source = TimeRange(try a.sourceTime("source_start"), try a.sourceTime("source_end"))
            let crossfade = a.optDouble("crossfade") ?? 0.25
            var ranges: [TimeRange]
            if name == "room_tone" {
                ranges = [TimeRange(try a.time("start"), try a.time("end"))]
                guard ranges[0].duration > 0 else { throw EditError("end must be after start") }
            } else {
                let dialogue = try a.string("track")
                ranges = try current.soundGaps(trackId: dialogue, minGap: a.optDouble("min_gap") ?? 0.04)
                guard !ranges.isEmpty else { throw EditError("\(dialogue) has no gaps between its sounds") }
            }
            let fill = ranges
            return try runEdit(name == "room_tone" ? "Room tone \(fmt2(fill[0].start))–\(fmt2(fill[0].end))s" : "Fill \(fill.count) gap(s) with room tone", dry: dry) { p in
                var trackId = a.optString(name == "room_tone" ? "track" : "into") ?? ""
                if p.trackIndex(trackId) == nil { trackId = p.addTrack(kind: .audio, name: "Room tone").id }
                var lines: [String] = []
                var skipped = 0
                for r in fill {
                    let ids = try p.fillRoomTone(r, mediaId: mid, source: source, trackId: trackId, crossfade: crossfade)
                    if ids.isEmpty { skipped += 1; continue }
                    let x = Project.roomToneCrossfade(crossfade, range: r)
                    lines.append("\(fmt2(r.start))–\(fmt2(r.end))s: \(ids.count) clip(s)" + (x < crossfade - 1e-9 ? ", crossfade \(fmt2(x))s to fit" : ""))
                }
                if skipped > 0 { lines.append("\(skipped) gap(s) shorter than a frame left as they are") }
                return "Room tone from \(mid) \(fmt2(source.start))–\(fmt2(source.end))s on \(trackId), crossfaded \(fmt2(crossfade))s: " + lines.joined(separator: "; ") + ". Set its level with param_set target \(trackId)/* audio.volume or track_update volume."
            }
        case "speed_ramp":
            let id = try a.string("clip")
            return try runEdit("Speed ramp on \(Toolbox.clipName(id, current))", dry: dry) { p in
                let done = try p.speedRamp(id, at: try a.optTime("at"), speed: a.optDouble("speed") ?? 0.3, ramp: a.optDouble("ramp") ?? 0.3, hold: a.optDouble("hold") ?? 0.8)
                return done + (p.retimedSpeechWarning(id, transcripts: b.transcripts(for: p)).map { "\n" + $0 } ?? "")
            }
        case "freeze_frame":
            let at = try a.time("at")
            let transcripts = b.transcripts(for: current)
            let speech = Set(current.timelineWords(transcripts: transcripts).compactMap { w in current.locateClip(w.clipId).map { current.tracks[$0.track].id } })
            return try runEdit("Freeze frame at \(fmt2(at))s", dry: dry) { p in
                try p.freezeFrame(at: at, trackId: a.optString("track"), duration: a.optDouble("duration") ?? 1.5, zoom: a.optDouble("zoom") ?? 1, pauseTracks: speech) + (speech.isEmpty ? "" : " Speech on \(speech.sorted().joined(separator: ", ")) pauses with it; music plays on.")
            }
        case "punch_in":
            let shots = Toolbox.shotIndex(b, current)
            let ids = a.strings("clips") ?? current.jumpCuts(trackId: a.optString("track") ?? "V1")
            guard !ids.isEmpty else { throw EditError("No jump cuts found on \(a.optString("track") ?? "V1"); pass clips") }
            return try runEdit("Punch in on \(ids.count) clip(s)", dry: dry) { p in
                try p.punchIn(ids, amount: a.optDouble("amount") ?? 1.15, settle: a.bool("settle", default: false)) { c in Toolbox.subjectCenter(c, shots) }
            }
        case "pip":
            let id = try a.string("clip")
            return try runEdit("Picture-in-picture \(Toolbox.clipName(id, current))", dry: dry) { p in
                try p.pictureInPicture(id, corner: a.optString("corner") ?? "bottom_right", size: a.optDouble("size") ?? 0.3, margin: a.optDouble("margin") ?? 0.04, roundness: a.optDouble("roundness") ?? 0.12, border: try a.color("border"))
            }
        case "split_screen":
            guard let ids = a.strings("clips") else { throw EditError("Pass clips") }
            return try runEdit("Split screen", dry: dry) { p in
                try p.splitScreen(ids, layout: a.optString("layout") ?? "lr", gap: a.optDouble("gap") ?? 0.01)
            }
        case "reframe":
            let parts = (a.optString("aspect") ?? "9:16").split(separator: ":").compactMap { Double($0) }
            guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { throw EditError("aspect is like \"9:16\"") }
            let longSide = Double(a.optInt("height") ?? max(current.canvas.width, current.canvas.height))
            let (w, h): (Double, Double) = parts[0] >= parts[1] ? (longSide, longSide * parts[1] / parts[0]) : (longSide * parts[0] / parts[1], longSide)
            let shots = Toolbox.shotIndex(b, current)
            return try runEdit("Reframe to \(a.optString("aspect") ?? "9:16")", dry: dry) { p in
                try p.reframe(width: Int((w / 2).rounded()) * 2, height: Int((h / 2).rounded()) * 2) { c in Toolbox.subjectPath(c, shots) }
            }
        case "beat_cut":
            let index = b.anchorIndex(for: current)
            let lo = try a.optTime("start") ?? 0, hi = try a.optTime("end") ?? current.duration
            let beats = current.timelineBeats(index).filter { $0 >= lo - 1e-3 && $0 <= hi + 1e-3 }
            guard beats.count >= 2 else { throw EditError("No analyzed music beats between \(fmt2(lo)) and \(fmt2(hi)); put music on the timeline and run media_analyze features:[\"beats\"]") }
            var pool: [(mediaId: String, range: TimeRange)] = []
            if let sources = a.raw["sources"]?.array {
                for s in sources {
                    let sa = Args(s)
                    pool.append((try sa.string("media"), TimeRange(try sa.optSourceTime("start") ?? 0, try sa.optSourceTime("end") ?? current.mediaAsset(try sa.string("media"))?.duration ?? 0)))
                }
            } else {
                guard let ids = a.strings("media") else { throw EditError("Pass media or sources") }
                for id in ids {
                    guard let m = current.mediaAsset(id) else { throw EditError("No media \(id)") }
                    if let shots = b.analysis(ShotAnalysis.self, id, "shots"), !m.isImage {
                        pool += shots.shots.sorted { ($0.aesthetics ?? 0) > ($1.aesthetics ?? 0) }.map { (id, TimeRange($0.start, $0.end)) }
                    } else if let cuts = index.shots[id], cuts.count > 1 {
                        pool += cuts.map { (id, $0) }
                    } else if m.isImage {
                        pool.append((id, TimeRange(0, 3600)))
                    } else {
                        // Unanalyzed footage: windows spread across the file rather than its opening seconds.
                        let n = max(1, min(8, Int(m.duration / 4)))
                        pool += (0..<n).map { k in (id, TimeRange(m.duration * Double(k) / Double(n), m.duration * Double(k + 1) / Double(n))) }
                    }
                }
            }
            return try runEdit("Cut to the beat", dry: dry) { p in
                var trackId = a.optString("track") ?? "new"
                if trackId == "new" { trackId = p.addTrack(kind: .video, name: "Beat cut").id }
                return try p.beatCut(pool: pool, beats: beats, every: a.optInt("every") ?? 2, trackId: trackId)
            }
        case "music_fit":
            let clipId = try a.string("clip")
            guard let clip = current.clip(clipId), let mid = clip.mediaId else { throw EditError("No media clip \(clipId)") }
            guard let beats = b.analysis(BeatAnalysis.self, mid, "beats") else { throw EditError("No beat analysis for \(mid); run media_analyze features:[\"beats\"]") }
            let length: Seconds
            if let l = a.optDouble("length") { length = l } else if let e = try a.optTime("end") { length = e - clip.start } else { throw EditError("Pass length or end") }
            return try runEdit("Fit music to \(fmt2(length))s", dry: dry) { p in
                try p.fitMusic(clipId: clipId, length: length, downbeats: beats.downbeats, fadeOut: a.optDouble("fade_out") ?? 1.5)
            }
        case "look":
            let look = a.optString("look") ?? "teal_orange"
            guard ColorMath.looks.contains(look) else { throw EditError("Looks: \(ColorMath.looks.joined(separator: ", "))") }
            let lo = try a.optTime("start") ?? 0, hi = try a.optTime("end") ?? current.duration
            return try runEdit("Add \(look.replacingOccurrences(of: "_", with: " ")) look", dry: dry) { p in
                let t = p.addTrack(kind: .video, name: "Look")
                var c = Clip(id: Project.newClipId(), kind: .adjustment, name: look.replacingOccurrences(of: "_", with: " "), start: lo, duration: hi - lo)
                c.effects.append(Effect(id: "look1", type: "color.look", params: ["look": .string(look), "amount": .number(a.optDouble("amount") ?? 0.8)]))
                let grain = a.optDouble("grain") ?? 0.2, vignette = a.optDouble("vignette") ?? 0.4
                if grain > 0 { c.effects.append(Effect(id: "grain1", type: "stylize.grain", params: ["amount": .number(grain)])) }
                if vignette > 0 { c.effects.append(Effect(id: "vignette1", type: "stylize.vignette", params: ["amount": .number(vignette)])) }
                try p.addClip(c, trackId: t.id, mode: .place)
                return "Added a \(look) adjustment layer \(c.id) on \(t.id) over \(fmt2(lo))–\(fmt2(hi))s (look1\(grain > 0 ? ", grain1" : "")\(vignette > 0 ? ", vignette1" : "")). Tune with param_set fx.look1.amount or remove the track."
            }
        case "glitch":
            let times = try (a.raw["at"]?.array ?? (a.raw["at"].map { [$0] } ?? [])).map { try Args.parseTime($0, name: "at") }
            guard !times.isEmpty else { throw EditError("Pass at: [times]") }
            let d = a.optDouble("duration") ?? 0.3, amount = a.optDouble("amount") ?? 0.8
            return try runEdit("Add \(times.count) glitch hit(s)", dry: dry) { p in
                let t = p.tracks.first { $0.name == "Glitch" && $0.kind == .video } ?? p.addTrack(kind: .video, name: "Glitch")
                var ids: [String] = []
                for time in times {
                    var c = Clip(id: Project.newClipId(), kind: .adjustment, name: "glitch", start: max(0, time - d / 2), duration: d)
                    c.effects.append(Effect(id: "glitch1", type: "stylize.glitch", params: ["amount": .number(amount)]))
                    c.anim["fx.glitch1.amount"] = Curve(keys: [CurveKey(t: 0, v: .number(0), ease: .linear), CurveKey(t: d * 0.3, v: .number(amount), ease: .easeOut), CurveKey(t: d, v: .number(0), ease: .easeIn)])
                    try p.addClip(c, trackId: t.id, mode: .overwrite)
                    ids.append(c.id)
                }
                return "Glitch hits on \(t.id): " + zip(ids, times).map { "\($0.0) at \(fmt2($0.1))s" }.joined(separator: ", ")
            }
        case "whip_pan":
            let cut = try Toolbox.cutPair(try a.string("cut"))
            return try runEdit("Whip pan", dry: dry) { p in
                var tr = p.transitions.first { $0.from == cut.0 && $0.to == cut.1 } ?? Transition(id: p.nextTransitionId(), from: cut.0, to: cut.1, type: "whip", duration: 0.35)
                tr.type = "whip"
                tr.duration = a.optDouble("duration") ?? 0.35
                tr.params = ["direction": .string(a.optString("direction") ?? "left")]
                tr.ease = .easeInOut
                var probe = p
                probe.transitions.removeAll { $0.id == tr.id }
                try probe.checkTransition(tr)
                p.transitions.removeAll { $0.id == tr.id }
                p.transitions.append(tr)
                return Toolbox.describeTransition(tr, p)
            }
        case "template":
            return try applyTemplate(a, dry: dry)
        case "kinetic_text":
            let lo = try a.time("start"), hi = try a.time("end")
            let words = current.timelineWords(transcripts: b.transcripts(for: current)).filter { $0.start >= lo - 0.02 && $0.start < hi }
            guard !words.isEmpty else { throw EditError("No transcribed speech between \(fmt2(lo)) and \(fmt2(hi))") }
            let upper = a.bool("uppercase", default: false)
            var spec = TextSpec(text: words.map { upper ? $0.text.uppercased() : $0.text }.joined(separator: " "), size: a.optDouble("size") ?? 0.09, weight: 800, color: try a.color("color") ?? .white, stroke: .black, strokeWidth: 0.06, y: a.optDouble("y") ?? 0.5, maxWidth: a.optDouble("max_width") ?? 0.8, animationIn: .none, animationOut: .fade)
            let start = words[0].start
            spec.animator = TextAnimator(unit: .word, preset: TextAnimator.Preset(rawValue: a.optString("preset") ?? "pop") ?? .pop, color: try a.color("highlight"), sync: true)
            spec.unitTimes = words.map { $0.start - start }
            return try runEdit("Kinetic text", dry: dry) { p in
                let t = p.addTrack(kind: .video, name: "Kinetic text")
                let c = Clip(id: Project.newClipId(), kind: .text, name: "kinetic", start: start, duration: max(0.5, min(hi, words.last!.end + 0.6) - start), text: spec)
                try p.addClip(c, trackId: t.id, mode: .place)
                return "Added \(c.id) on \(t.id): \(words.count) words appear as they're spoken (\(fmt2(c.start))–\(fmt2(c.end))s). Restyle with param_set text.* or text_add-style animator via clip_update."
            }
        case "match_color":
            return try await matchColorRecipe(a, dry: dry)
        case "qualify":
            return try await qualifyRecipe(a, dry: dry)
        case "grade_group":
            let group = a.optString("id") ?? "group1"
            guard group.range(of: #"^[A-Za-z][A-Za-z0-9_]*$"#, options: .regularExpression) != nil else { throw EditError("Group ids are letters, digits and _, starting with a letter") }
            var ids = a.strings("clips") ?? []
            if let tid = a.optString("track") {
                guard let i = current.trackIndex(tid) else { throw EditError("No track \(tid)") }
                ids += current.tracks[i].clips.filter { $0.kind == .media || $0.kind == .sequence }.map(\.id)
            }
            guard !ids.isEmpty else { throw EditError("Pass clips (ids) or track") }
            for id in ids where current.clip(id) == nil { throw EditError("No clip \(id)") }
            let spec = Args(a.raw["effect"])
            let existing = current.tracks.flatMap(\.clips).compactMap { $0.effects.first { $0.id == group } }.first
            guard let type = spec.optString("type") ?? existing?.type ?? (a.has("effect") ? nil : "color.wheels") else { throw EditError("effect needs a type, e.g. {\"type\": \"color.wheels\", \"params\": {\"saturation\": 0.1}}") }
            guard let et = EffectCatalog.type(type), !EffectCatalog.isAudio(type), et.category != "generator" else { throw EditError("\(type) is not a picture effect") }
            if let existing, existing.type != type { throw EditError("Group \(group) is a \(existing.type); pick another id") }
            return try runEdit("Grade group \(group) on \(ids.count) clip(s)", dry: dry) { p in
                var raw: [String: JSON] = ["id": .string(group), "type": .string(type)]
                if let params = spec.raw["params"] { raw["params"] = params }
                if let mix = spec.raw["mix"] { raw["mix"] = mix }
                var added: [String] = [], updated: [String] = []
                for id in ids {
                    guard let loc = p.locateClip(id) else { continue }
                    var c = p.tracks[loc.track].clips[loc.clip]
                    let had = c.effects.contains { $0.id == group }
                    let plan = try Toolbox.planEffect(&c.effects, Args(raw: raw), owner: id)
                    if !had, let existing, let i = c.effects.firstIndex(where: { $0.id == group }) {
                        c.effects[i].params = existing.params
                        c.effects[i].mix = existing.mix
                    }
                    for (path, v) in plan.values { try c.set(path, v) }
                    p.tracks[loc.track].clips[loc.clip] = c
                    if had { updated.append(id) } else { added.append(id) }
                }
                let members = Toolbox.groupMembers(group, p)
                return "Group \(group) (\(type)): " + (added.isEmpty ? "" : "added to \(added.joined(separator: ", ")). ") + (updated.isEmpty ? "" : "updated on \(updated.joined(separator: ", ")). ") + "\(members.count) clip(s) share it; change them together with param_set {\"target\": \"group:\(group)\", \"set\": {\"fx.\(group).<param>\": …}}."
            }
        case "sync_audio":
            let audioId = try a.string("audio")
            guard let rec = current.mediaAsset(audioId), rec.hasAudio else { throw EditError("\(audioId) has no sound") }
            let ids = a.strings("clips") ?? current.tracks.first { $0.kind == .video }.map { $0.clips.filter { $0.kind == .media }.map(\.id) } ?? []
            var offsets: [String: (Seconds, Double)] = [:]
            let recHeard = try await heard(rec, a.optString("channel"))
            let play = try a.optString("play").map { raw -> ChannelRouting in
                guard let r = ChannelRouting(rawValue: raw) else { throw EditError("play is \(ChannelRouting.help)") }
                return r
            }
            for id in ids {
                guard let c = current.clip(id), let mid = c.mediaId, let cam = current.mediaAsset(mid) else { throw EditError("No clip \(id)") }
                guard cam.hasAudio else { throw EditError("\(id)'s media has no camera sound to sync against") }
                if offsets[mid] == nil { offsets[mid] = try await AudioSync.offset(reference: try await heard(cam, a.optString("camera_channel")), other: recHeard, maxOffset: max(60, rec.duration)) }
            }
            let keep = a.bool("keep_camera", default: false)
            let found = offsets
            return try runEdit("Sync \(audioId) to \(ids.count) clip(s)", dry: dry) { p in
                var trackId = a.optString("track") ?? ""
                if p.trackIndex(trackId) == nil { trackId = p.addTrack(kind: .audio, name: "Production sound").id }
                var lines: [String] = []
                for id in ids {
                    guard let loc = p.locateClip(id) else { continue }
                    var c = p.tracks[loc.track].clips[loc.clip]
                    guard let (off, conf) = c.mediaId.flatMap({ found[$0] }) else { continue }
                    p.addSyncGroup([c.mediaId!: 0, audioId: off])
                    let link = c.link ?? IDs.make("lnk")
                    c.link = link
                    if !keep { c.volume = 0 }
                    p.tracks[loc.track].clips[loc.clip] = c
                    var s = Clip(id: Project.newClipId(), kind: .media, name: rec.name, mediaId: audioId, start: c.start, duration: c.duration, sourceIn: c.sourceIn + off, speed: c.speed)
                    s.link = link
                    if let play, !play.isAsRecorded { s.channels = play }
                    try p.addClip(s, trackId: trackId, mode: .overwrite)
                    lines.append("\(id) ↔ \(s.id) (offset \(String(format: "%+.3f", off))s, confidence \(fmt2(conf)))")
                }
                return "Synced and linked on \(trackId)" + (keep ? "" : ", camera sound muted") + ": " + lines.joined(separator: "; ")
            }
        case "follow":
            let id = try a.string("clip")
            let target = try a.string("target")
            guard let c = current.clip(id) else { throw EditError("No clip \(id)") }
            if target.hasPrefix("track:"), let found = current.media.lazy.compactMap({ m in (b.analysis([ObjectTrack].self, m.id, "tracks") ?? []).first { $0.id == String(target.dropFirst(6)) } }).first,
               found.samples.contains(where: { $0.corners != nil }) {
                return try runEdit("Pin \(Toolbox.clipName(id, current)) to \(found.label)", dry: dry) { p in
                    try Toolbox.pin(&p, clipId: id, corners: found.samples, mediaId: found.mediaId)
                }
            }
            let text = c.kind == .text
            let dx = a.optDouble("offset_x") ?? 0, dy = a.optDouble("offset_y") ?? 0
            let smooth = JSON.number(a.optDouble("smooth") ?? 0.2)
            let bind: [String: JSON] = [
                text ? "text.x" : "transform.x": ["source": .string(target + ".x"), "offset": .number(dx), "smooth": smooth],
                text ? "text.y" : "transform.y": ["source": .string(target + ".y"), "offset": .number(dy), "smooth": smooth],
            ]
            return try runEdit("\(Toolbox.clipName(id, current)) follows \(target)", dry: dry) { p in
                try self.applyBindings(&p, targets: [.clip(id)], bind)
            }
        case "multicam_switch":
            return try await multicam(a, dry: dry, bundle: b, project: current)
        default:
            throw EditError("Unknown recipe \(name). Recipes: \(Toolbox.recipeNames.joined(separator: ", "))")
        }
    }

    static func shotIndex(_ b: ProjectBundle, _ p: Project) -> [String: ShotAnalysis] {
        var out: [String: ShotAnalysis] = [:]
        for m in p.media {
            guard var s = b.analysis(ShotAnalysis.self, m.id, "shots") else { continue }
            // With active-speaker analysis, keep only the talking face at each moment so framing follows dialogue.
            if let active = b.analysis(ActiveSpeakers.self, m.id, "activespeakers"), !active.spans.isEmpty {
                s.faces = s.faces.map { track in
                    var t = track
                    t.samples = track.samples.filter { sample in active.face(at: sample.t).map { $0 == track.id } ?? true }
                    return t
                }
            }
            out[m.id] = s
        }
        return out
    }

    /// Where the subject sits in a clip's source frame: the largest face, else the salient region.
    static func subjectCenter(_ c: Clip, _ shots: [String: ShotAnalysis]) -> (x: Double, y: Double)? {
        let path = subjectPath(c, shots)
        guard !path.isEmpty else { return nil }
        return (path.map(\.x).reduce(0, +) / Double(path.count), path.map(\.y).reduce(0, +) / Double(path.count))
    }

    static func subjectPath(_ c: Clip, _ shots: [String: ShotAnalysis]) -> [(t: Seconds, x: Double, y: Double)] {
        guard let id = c.mediaId, let a = shots[id] else { return [] }
        let lo = min(c.sourceIn, c.sourceOut), hi = max(c.sourceIn, c.sourceOut)
        let faces = a.faces.flatMap(\.samples).filter { $0.t >= lo - 0.5 && $0.t <= hi + 0.5 }
        if !faces.isEmpty {
            // Per sample time, follow the biggest face.
            let byTime = Dictionary(grouping: faces) { ($0.t * 10).rounded() / 10 }
            return byTime.keys.sorted().compactMap { t in byTime[t]!.max { $0.box.area < $1.box.area }.map { (t, $0.box.midX, $0.box.midY) } }
        }
        return a.shots.filter { $0.end > lo && $0.start < hi }.compactMap { s in s.saliency.map { ((s.start + s.end) / 2, $0.midX, $0.midY) } }
    }
}

extension Toolbox {
    func multicam(_ a: Args, dry: Bool, bundle b: ProjectBundle, project current: Project) async throws -> ToolResult {
        let trackId = a.optString("track") ?? "V1"
        if let raw = a.raw["cuts"]?.array {
            let cuts = try raw.map { item -> (at: Seconds, angle: String) in
                guard let o = item.object else { throw EditError("Each cut is {at, angle}") }
                let sub = Args(.object(o))
                return (try sub.time("at"), try sub.string("angle"))
            }
            guard !cuts.isEmpty else { throw EditError("Pass cuts: [{at, angle}]") }
            return try runEdit("Switch \(cuts.count) angle(s)", dry: dry) { p in
                "Switched angles on \(trackId):\n" + (try p.switchAngles(cuts, trackId: trackId)).joined(separator: "\n")
            }
        }
        guard let angles = a.strings("angles"), angles.count >= 2 else { throw EditError("Pass at least two angles (media ids), or cuts: [{at, angle}] to switch angles by hand") }
        let audioId = a.optString("audio") ?? angles[0]
        guard let audio = current.mediaAsset(audioId), audio.hasAudio else { throw EditError("\(audioId) has no sound to sync and cut by") }
        var offsets: [String: Seconds] = [audioId: 0]
        var notes: [String] = []
        for id in Set(angles + [a.optString("wide")].compactMap { $0 }) where id != audioId {
            guard let m = current.mediaAsset(id) else { throw EditError("No media \(id)") }
            guard m.hasAudio else { throw EditError("\(id) has no sound, so it can't be synced") }
            let r = try await AudioSync.offset(reference: try await heard(audio, a.optString("audio_channel")), other: try await heard(m, a.optString("channel")))
            offsets[id] = r.offset
            notes.append("\(id) \(r.offset >= 0 ? "+" : "")\(String(format: "%.3f", r.offset))s (confidence \(fmt2(r.confidence)))")
            if r.confidence < 0.5 { notes.append("warning: \(id) synced with low confidence; check it with timeline_frames") }
        }
        guard let transcript = b.transcript(audioId) else {
            throw EditError("\(audioId) has no transcript to find speaker turns; run media_analyze media_id:\"\(audioId)\" features:[\"transcript\", \"speakers\"]")
        }
        let lo = try a.optSourceTime("start") ?? 0
        var hi = try a.optSourceTime("end") ?? audio.duration
        for (id, off) in offsets { if let m = current.mediaAsset(id) { hi = min(hi, m.duration - off) } }
        guard hi > lo else { throw EditError("The angles don't overlap in time between start and end") }
        let spoken = transcript.words.enumerated().filter { $0.element.end > lo && $0.element.start < hi }

        // Who speaks: whose mic is loudest when each angle records its own person, else the voice analysis.
        let signal = a.optString("signal") ?? "auto"
        var labels: [String?]?
        var how = ""
        if signal != "speakers" {
            var levels: [String: [[Double]]] = [:]
            for id in angles {
                guard let m = current.mediaAsset(id) else { continue }
                levels[id] = try await MulticamAudio.wordLevels(url: try await heard(m, a.optString("channel")), offset: offsets[id] ?? 0, words: spoken.map { TimeRange($0.element.start, $0.element.end) })
            }
            let loud = MulticamPlan.loudestAngles(levels)
            if signal == "mics" || loud.margin >= 3 {
                labels = loud.angles
                how = "the loudest angle's mic (median margin \(fmt1(loud.margin)) dB)"
            } else {
                how = "speaker analysis (the angles' mics differ by only \(fmt1(loud.margin)) dB, so they hear the same sound)"
            }
        }
        if labels == nil {
            guard let speakers = b.analysis(SpeakerAnalysis.self, audioId, "speakers") else {
                throw EditError("\(audioId) has no speaker analysis and the angles' mics don't tell speakers apart; run media_analyze media_id:\"\(audioId)\" features:[\"speakers\"]")
            }
            var map: [String: String] = [:]
            for (i, s) in speakers.speakers.enumerated() { map[s] = angles[min(i, angles.count - 1)] }
            for (k, v) in a.raw["speakers"]?.object ?? [:] { if let m = v.string { map[k] = m } }
            labels = spoken.map { i, _ in speakers.wordSpeakers.indices.contains(i) ? speakers.wordSpeakers[i].flatMap { map[$0] } : nil }
            if how.isEmpty { how = "speaker analysis" }
            how += " (" + map.sorted { $0.key < $1.key }.map { "\($0.key)→\($0.value)" }.joined(separator: ", ") + ")"
        }
        let words = zip(spoken, labels!).map { MulticamWord(start: $0.element.start, end: $0.element.end, text: $0.element.text, angle: $1) }
        var options = MulticamOptions()
        options.minShot = a.optDouble("min_shot") ?? 1.0
        options.wide = a.optString("wide")
        if let r = a.raw["reaction"] {
            if r.bool == true { options.reactionAfter = 5 } else if let n = r.double { options.reactionAfter = n }
        }
        let shots = MulticamPlan.shots(words: words, range: TimeRange(lo, hi), first: words.first?.angle ?? angles[0], options: options)
        let at = try a.optTime("at") ?? 0
        let summary = notes
        return try runEdit("Multicam edit from \(angles.count) angles", dry: dry) { p in
            guard let ti = p.trackIndex(trackId), p.tracks[ti].kind == .video else { throw EditError("No video track \(trackId)") }
            p.deleteRange(TimeRange(at, at + (hi - lo)), trackIds: [trackId], ripple: false)
            // Cut points snap to frames and each shot ends where the next begins, so no slivers of background show.
            let cutsAt = shots.map { p.canvas.snap(at + $0.start - lo) } + [p.canvas.snap(at + hi - lo)]
            for (i, s) in shots.enumerated() where cutsAt[i + 1] - cutsAt[i] >= p.canvas.frameDuration {
                var c = Clip(id: Project.newClipId(), kind: .media, mediaId: s.angle, start: cutsAt[i], duration: cutsAt[i + 1] - cutsAt[i], sourceIn: cutsAt[i] - at + lo + (offsets[s.angle] ?? 0))
                c.transform.fit = .fill
                c.volume = 0
                try p.addClip(c, trackId: trackId, mode: .overwrite)
            }
            p.addSyncGroup(offsets)
            let audioTrack = p.addTrack(kind: .audio, name: "Multicam sound")
            try p.addClip(Clip(id: Project.newClipId(), kind: .media, mediaId: audioId, start: at, duration: hi - lo, sourceIn: lo), trackId: audioTrack.id, mode: .place)
            let counts = Dictionary(grouping: shots, by: \.angle).mapValues(\.count)
            let extras = shots.filter { $0.kind != "speaker" }
            return "Synced: " + (summary.isEmpty ? "single angle" : summary.joined(separator: ", ")) + ". Speakers from \(how). Cut \(shots.count) shots on \(trackId) (" + counts.sorted { $0.key < $1.key }.map { "\($0.key) ×\($0.value)" }.joined(separator: ", ") + ", none under \(fmt2(options.minShot))s, cuts in the pauses before each new speaker"
                + (extras.isEmpty ? "" : ", \(extras.count) reaction/wide cutaway(s)") + ") with \(audioId)'s sound on \(audioTrack.id). Recut by hand with recipe multicam_switch cuts:[{at, angle}]."
        }
    }
}

extension Toolbox {
    /// Clips in a grade group: every clip carrying an effect with the group's id.
    static func groupMembers(_ group: String, _ p: Project) -> [String] {
        p.tracks.flatMap(\.clips).filter { c in c.effects.contains { $0.id == group } }.map(\.id)
    }

    /// Targets for "group:<id>", or nil when `name` is not a group reference.
    static func groupTargets(_ name: String, _ p: Project) throws -> [Target]? {
        guard name.hasPrefix("group:") else { return nil }
        let group = String(name.dropFirst(6))
        let members = groupMembers(group, p)
        guard !members.isEmpty else { throw EditError("No clips in group \(group); create it with recipe grade_group {clips, id: \"\(group)\", effect}") }
        return members.map { .clip($0) }
    }

    /// Writes RGBA float cube data (red fastest) as a .cube LUT.
    static func writeCube(_ rgba: [Float], size: Int, title: String, to url: URL) throws {
        var text = "TITLE \"\(title)\"\nLUT_3D_SIZE \(size)\n"
        text.reserveCapacity(size * size * size * 24)
        for i in 0..<(size * size * size) {
            text += String(format: "%.6f %.6f %.6f\n", rgba[i * 4], rgba[i * 4 + 1], rgba[i * 4 + 2])
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}
