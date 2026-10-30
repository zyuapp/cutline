import CoreGraphics
import CutlineCore
import CutlineEngine
import Foundation

extension Toolbox {
    func moreRecipes(_ name: String, _ a: Args, dry: Bool) async throws -> ToolResult {
        let b = try session.requireBundle()
        let current = try session.project()
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
                    let x = Project.roomToneCrossfade(crossfade, range: r, fps: p.canvas.fps)
                    lines.append("\(fmt2(r.start))–\(fmt2(r.end))s: \(ids.count) clip(s)" + (x < crossfade - 1e-9 ? ", crossfade \(fmt(x))s to fit" : abs(x - crossfade) > 1e-9 ? ", crossfade \(fmt(x))s on the frame grid" : ""))
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
            let clip = try a.optString("clip").map { id -> (clip: Clip, track: String) in
                guard let loc = current.locateClip(id) else { throw EditError("No clip \(id)") }
                return (current.tracks[loc.track].clips[loc.clip], current.tracks[loc.track].id)
            }
            let at = try a.optTime("at") ?? clip.map { $0.clip.start + $0.clip.duration / 2 } ?? a.time("at")
            if let c = clip?.clip, at < c.start || at >= c.end { throw EditError("at \(fmt2(at))s is outside \(c.id) (\(fmt2(c.start))–\(fmt2(c.end))s)") }
            let transcripts = b.transcripts(for: current)
            let speech = Set(current.timelineWords(transcripts: transcripts).compactMap { w in current.locateClip(w.clipId).map { current.tracks[$0.track].id } })
            return try runEdit("Freeze frame at \(fmt2(at))s", dry: dry) { p in
                try p.freezeFrame(at: at, trackId: a.optString("track") ?? clip?.track, duration: a.optDouble("duration") ?? 1.5, zoom: a.optDouble("zoom") ?? 1, pauseTracks: speech) + (speech.isEmpty ? "" : " Speech on \(speech.sorted().joined(separator: ", ")) pauses with it; music plays on.")
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
            var spans: [(mediaId: String, range: TimeRange?)] = []
            if let sources = a.value("sources")?.array {
                for s in sources {
                    let sa = Args(s)
                    let id = try sa.string("media")
                    guard let m = current.mediaAsset(id) else { throw EditError("No media \(id)") }
                    spans.append((id, TimeRange(try sa.optSourceTime("start") ?? 0, try sa.optSourceTime("end") ?? m.duration)))
                }
            } else {
                guard let ids = a.strings("media") else { throw EditError("Pass media or sources") }
                for id in ids {
                    guard current.mediaAsset(id) != nil else { throw EditError("No media \(id)") }
                    spans.append((id, nil))
                }
            }
            let (footage, notes, shots) = try await beatFootage(spans, project: current, bundle: b)
            let align = try a.optString("align").map { v -> BeatAlign in
                guard let al = BeatAlign(rawValue: v) else { throw EditError("align is fill, zero or first_beat") }
                return al
            } ?? .fill
            var music: [String] = []
            for t in current.tracks where !t.muted {
                for c in t.clips where c.kind == .media && c.end > lo && c.start < hi {
                    if let id = c.mediaId, index.music.contains(id), index.beats[id] != nil { music.append(c.id) }
                }
            }
            let loudness = current.timelineBeatEnergy(index)
            let energy: ((TimeRange) -> Double?)? = loudness.isEmpty ? nil : { r in
                let inside = loudness.filter { $0.t >= r.start - 1e-3 && $0.t < r.end - 1e-3 }.map(\.energy)
                if !inside.isEmpty { return inside.reduce(0, +) / Double(inside.count) }
                return loudness.min { abs($0.t - r.start) < abs($1.t - r.start) }?.energy
            }
            return try runEdit("Cut to the beat", dry: dry) { p in
                var trackId = a.optString("track") ?? "new"
                if trackId == "new" { trackId = p.addTrack(kind: .video, name: "Beat cut").id }
                let before = p
                return try p.beatCut(footage: footage, beats: beats, every: a.optInt("every") ?? 2, trackId: trackId, from: lo, align: align, music: music, energy: energy) { c in
                    Toolbox.fillFraming(c, before, shots)
                } + notes.map { "\n" + $0 }.joined()
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
            let times = try (a.value("at")?.array ?? (a.value("at").map { [$0] } ?? [])).map { try Args.parseTime($0, name: "at") }
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
            let lo = try a.time("start")
            var words: [(text: String, start: Seconds, end: Seconds)]
            var how: String
            if let custom = a.value("text") {
                let list = (custom.array?.compactMap(\.string) ?? custom.string.map { [$0] } ?? []).flatMap { $0.split(whereSeparator: \.isWhitespace).map(String.init) }
                guard !list.isEmpty else { throw EditError("text has no words") }
                let timing = a.optString("timing") ?? "even"
                guard ["even", "beats", "downbeats"].contains(timing) else { throw EditError("timing is even, beats or downbeats") }
                let hi = try a.optTime("end") ?? (lo + 0.5 * Double(list.count))
                guard hi > lo else { throw EditError("end must be after start") }
                var times: [Seconds]
                if timing == "even" {
                    times = list.indices.map { lo + (hi - lo) * Double($0) / Double(list.count) }
                    how = "evenly over \(fmt2(lo))–\(fmt2(hi))s"
                } else {
                    let beats = current.timelineBeats(b.anchorIndex(for: current), downbeats: timing == "downbeats").filter { $0 >= lo - 1e-3 && $0 < hi }
                    guard beats.count >= list.count else { throw EditError("\(beats.count) \(timing) between \(fmt2(lo)) and \(fmt2(hi))s for \(list.count) words" + (beats.isEmpty ? "; analyze the music's beats (media_analyze features:[\"beats\"])" : "; pass a later end or fewer words")) }
                    times = Array(beats.prefix(list.count))
                    how = "one per \(timing == "beats" ? "beat" : "downbeat")"
                }
                let ends = Array(times.dropFirst()) + [max(hi, times.last! + 0.4)]
                words = list.indices.map { (list[$0], times[$0], ends[$0]) }
            } else {
                let hi = try a.time("end")
                words = current.timelineWords(transcripts: b.transcripts(for: current)).filter { $0.start >= lo - 0.02 && $0.start < hi }.map { ($0.text, $0.start, $0.end) }
                guard !words.isEmpty else { throw EditError("No transcribed speech between \(fmt2(lo)) and \(fmt2(hi)); pass text for your own words") }
                words = words.map { ($0.text, $0.start, min($0.end, hi)) }
                how = "as they're spoken"
            }
            let upper = a.bool("uppercase", default: false)
            var spec = TextSpec(text: words.map { upper ? $0.text.uppercased() : $0.text }.joined(separator: " "), size: a.optDouble("size") ?? 0.09, weight: 800, color: try a.color("color") ?? .white, stroke: .black, strokeWidth: 0.06, y: a.optDouble("y") ?? 0.5, maxWidth: a.optDouble("max_width") ?? 0.8, animationIn: .none, animationOut: .fade)
            let start = words[0].start
            spec.animator = TextAnimator(unit: .word, preset: TextAnimator.Preset(rawValue: a.optString("preset") ?? "pop") ?? .pop, color: try a.color("highlight"), sync: true)
            spec.unitTimes = words.map { $0.start - start }
            let length = max(0.5, words.last!.end + 0.6 - start)
            return try runEdit("Kinetic text", dry: dry) { p in
                let t = p.addTrack(kind: .video, name: "Kinetic text")
                let c = Clip(id: Project.newClipId(), kind: .text, name: "kinetic", start: start, duration: length, text: spec)
                try p.addClip(c, trackId: t.id, mode: .place)
                return "Added \(c.id) on \(t.id): \(words.count) words appear \(how) (\(fmt2(c.start))–\(fmt2(c.end))s). Restyle with param_set text.* or text_add-style animator via clip_update."
            }
        case "match_color":
            return try await matchColorRecipe(a, dry: dry)
        case "qualify":
            return try await qualifyRecipe(a, dry: dry)
        case "sky_replace":
            return try await skyReplaceRecipe(a, dry: dry)
        case "split_at_shots":
            return try splitAtShotsRecipe(a, dry: dry)
        case "safe_zone_fix":
            return try safeZoneFixRecipe(a, dry: dry)
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
            let spec = Args(a.value("effect"))
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

    static func shotIndex(_ b: ProjectBundle, _ p: Project, media only: Set<String>? = nil) -> [String: ShotAnalysis] {
        var out: [String: ShotAnalysis] = [:]
        for m in p.media where only?.contains(m.id) ?? true {
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
