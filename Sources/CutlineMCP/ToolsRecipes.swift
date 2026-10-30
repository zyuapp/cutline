import CoreGraphics
import CutlineCore
import CutlineEngine
import Foundation

extension Toolbox {
    static let recipeNames = ["duck", "loudness_normalize", "split_edit", "speed_ramp", "freeze_frame", "punch_in", "pip", "split_screen", "reframe", "beat_cut", "music_fit", "look", "glitch", "whip_pan", "template", "multicam_switch", "kinetic_text", "follow", "sync_audio", "match_color"]

    static let recipeDocs = """
        duck: {music: clip or track ids (default: audio tracks without speech), under: track ids with speech, amount_db: 12, attack: 0.3, release: 0.8}. \
        loudness_normalize: {target_lufs: -14, ceiling_db: -1.5, limit: true}. \
        split_edit: {edit: "clip_a|clip_b", offset: seconds (+ J cut, − L cut)}. \
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
        match_color: {clips: [ids] (default every media clip on V1), reference: clip id whose look the others match, strength: 0.8}; shot matching like Resolve's: measures each shot's color and exposure and adds a match LUT (effect "match") in front of its other color effects. \
        sync_audio: {clips: [video clip ids] (default every clip of that camera media on V1), audio: media id of the separate recorder, track: audio track (default new "Production sound"), keep_camera: false}; lines up dual-system sound by waveform, links it to the picture and mutes the camera mic. \
        follow: {clip: the graphic, title or overlay to move, target: "track:<id>" (media_track) or "face:<media>[:n]", offset_x: 0, offset_y: -0.1 (fractions of the frame; negative is above), smooth: 0.2}; keeps the clip on its subject wherever the media plays. \
        kinetic_text: {start, end (timeline or word anchors), preset: pop, unit: word, size: 0.09, y: 0.5, color, highlight: color, uppercase: false, max_width: 0.8}; spoken words appear as they are said. \
        multicam_switch: {angles: [media ids], audio: media with the main sound (default first angle), speakers: {"S1": media, ...} (default S1→first angle, S2→second…), wide: media for long turns and crosstalk, start, end (source seconds of audio), min_shot: 1.5, at: timeline time, track: "V1"}; syncs angles by their sound and cuts to whoever speaks.
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
        case "speed_ramp":
            let id = try a.string("clip")
            return try runEdit("Speed ramp on \(Toolbox.clipName(id, current))", dry: dry) { p in
                try p.speedRamp(id, at: try a.optTime("at"), speed: a.optDouble("speed") ?? 0.3, ramp: a.optDouble("ramp") ?? 0.3, hold: a.optDouble("hold") ?? 0.8)
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
            let refId = try a.string("reference")
            guard let ref = current.clip(refId), ref.kind == .media else { throw EditError("reference must be a media clip") }
            let ids = (a.strings("clips") ?? current.tracks.first { $0.kind == .video }.map { $0.clips.filter { $0.kind == .media }.map(\.id) } ?? []).filter { $0 != refId }
            let strength = a.optDouble("strength") ?? 0.8
            let refStats = try await Toolbox.colorStats(ref, current)
            var files: [String: URL] = [:]
            let dir = b.cacheURL.appendingPathComponent("looks", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var report: [String] = []
            for id in ids {
                guard let c = current.clip(id), c.kind == .media else { continue }
                let st = try await Toolbox.colorStats(c, current)
                let f = ColorMatch.transform(from: st, to: refStats, strength: strength)
                let url = dir.appendingPathComponent("match-\(id)-\(refId).cube")
                try Toolbox.writeCube(ColorMath.cubeData(size: 33, f), size: 33, title: "Match \(id) to \(refId)", to: url)
                files[id] = url
                report.append(String(format: "%@ (L %.0f→%.0f, a %.1f→%.1f, b %.1f→%.1f)", id, st.mean.x, refStats.mean.x, st.mean.y, refStats.mean.y, st.mean.z, refStats.mean.z))
            }
            let made = files
            return try runEdit("Match \(made.count) shot(s) to \(Toolbox.clipName(refId, current))", dry: dry) { p in
                for (id, url) in made {
                    guard let loc = p.locateClip(id) else { continue }
                    p.tracks[loc.track].clips[loc.clip].effects.removeAll { $0.id == "match" }
                    p.tracks[loc.track].clips[loc.clip].effects.insert(Effect(id: "match", type: "color.lut", params: ["file": .string(url.path)]), at: 0)
                }
                return "Matched to \(refId): " + report.joined(separator: "; ") + ". Tune with param_set fx.match.mix."
            }
        case "sync_audio":
            let audioId = try a.string("audio")
            guard let rec = current.mediaAsset(audioId), rec.hasAudio else { throw EditError("\(audioId) has no sound") }
            let ids = a.strings("clips") ?? current.tracks.first { $0.kind == .video }.map { $0.clips.filter { $0.kind == .media }.map(\.id) } ?? []
            var offsets: [String: (Seconds, Double)] = [:]
            for id in ids {
                guard let c = current.clip(id), let mid = c.mediaId, let cam = current.mediaAsset(mid) else { throw EditError("No clip \(id)") }
                guard cam.hasAudio else { throw EditError("\(id)'s media has no camera sound to sync against") }
                if offsets[mid] == nil { offsets[mid] = try await AudioSync.offset(reference: cam.url, other: rec.url, maxOffset: max(60, rec.duration)) }
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
                    try p.addClip(s, trackId: trackId, mode: .overwrite)
                    lines.append("\(id) ↔ \(s.id) (offset \(String(format: "%+.3f", off))s, confidence \(fmt2(conf)))")
                }
                return "Synced and linked on \(trackId)" + (keep ? "" : ", camera sound muted") + ": " + lines.joined(separator: "; ")
            }
        case "follow":
            let id = try a.string("clip")
            let target = try a.string("target")
            guard let c = current.clip(id) else { throw EditError("No clip \(id)") }
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
        guard let angles = a.strings("angles"), angles.count >= 2 else { throw EditError("Pass at least two angles (media ids)") }
        let audioId = a.optString("audio") ?? angles[0]
        guard let audio = current.mediaAsset(audioId), audio.hasAudio else { throw EditError("\(audioId) has no sound to sync and cut by") }
        var offsets: [String: Seconds] = [audioId: 0]
        var notes: [String] = []
        for id in Set(angles + [a.optString("wide")].compactMap { $0 }) where id != audioId {
            guard let m = current.mediaAsset(id) else { throw EditError("No media \(id)") }
            guard m.hasAudio else { throw EditError("\(id) has no sound, so it can't be synced") }
            let r = try await AudioSync.offset(reference: audio.url, other: m.url)
            offsets[id] = r.offset
            notes.append("\(id) \(r.offset >= 0 ? "+" : "")\(String(format: "%.3f", r.offset))s (confidence \(fmt2(r.confidence)))")
            if r.confidence < 0.5 { notes.append("warning: \(id) synced with low confidence; check it with timeline_frames") }
        }
        guard let speakers = b.analysis(SpeakerAnalysis.self, audioId, "speakers") else {
            throw EditError("\(audioId) has no speaker analysis; run media_analyze media_id:\"\(audioId)\" features:[\"speakers\"]")
        }
        var map: [String: String] = [:]
        for (i, s) in speakers.speakers.enumerated() { map[s] = angles[min(i, angles.count - 1)] }
        for (k, v) in a.raw["speakers"]?.object ?? [:] { if let m = v.string { map[k] = m } }
        let wide = a.optString("wide")
        let lo = try a.optSourceTime("start") ?? 0
        var hi = try a.optSourceTime("end") ?? audio.duration
        for (id, off) in offsets { if let m = current.mediaAsset(id) { hi = min(hi, m.duration - off) } }
        let minShot = a.optDouble("min_shot") ?? 1.5
        // Turns, merged so no shot is shorter than min_shot.
        var turns: [(s: Seconds, e: Seconds, angle: String)] = []
        for seg in speakers.segments where seg.end > lo && seg.start < hi {
            let angle = map[seg.speaker] ?? angles[0]
            let s = max(lo, seg.start), e = min(hi, seg.end)
            if let last = turns.last, last.angle == angle || e - s < minShot {
                turns[turns.count - 1].e = e
            } else if let last = turns.last, s - last.e > 0 {
                turns[turns.count - 1].e = s
                turns.append((s, e, angle))
            } else {
                turns.append((turns.last?.e ?? lo, e, angle))
            }
        }
        if turns.isEmpty { turns = [(lo, hi, angles[0])] }
        turns[0].s = lo
        turns[turns.count - 1].e = hi
        if let wide {
            var out: [(s: Seconds, e: Seconds, angle: String)] = []
            for t in turns {
                if t.e - t.s > 12 {
                    let mid = (t.s + t.e) / 2
                    out += [(t.s, mid - 1.5, t.angle), (mid - 1.5, mid + 1.5, wide), (mid + 1.5, t.e, t.angle)]
                } else { out.append(t) }
            }
            turns = out
        }
        let at = try a.optTime("at") ?? 0
        let finalTurns = turns
        let summary = notes
        return try runEdit("Multicam edit from \(angles.count) angles", dry: dry) { p in
            let trackId = a.optString("track") ?? "V1"
            guard let ti = p.trackIndex(trackId), p.tracks[ti].kind == .video else { throw EditError("No video track \(trackId)") }
            p.deleteRange(TimeRange(at, at + (hi - lo)), trackIds: [trackId], ripple: false)
            // Cut points snap to frames and each shot ends where the next begins, so no slivers of background show.
            let cutsAt = finalTurns.map { p.canvas.snap(at + $0.s - lo) } + [p.canvas.snap(at + hi - lo)]
            for (i, t) in finalTurns.enumerated() where cutsAt[i + 1] - cutsAt[i] >= p.canvas.frameDuration {
                var c = Clip(id: Project.newClipId(), kind: .media, mediaId: t.angle, start: cutsAt[i], duration: cutsAt[i + 1] - cutsAt[i], sourceIn: cutsAt[i] - at + lo + (offsets[t.angle] ?? 0))
                c.transform.fit = .fill
                c.volume = 0
                try p.addClip(c, trackId: trackId, mode: .overwrite)
            }
            p.addSyncGroup(offsets)
            let audioTrack = p.addTrack(kind: .audio, name: "Multicam sound")
            try p.addClip(Clip(id: Project.newClipId(), kind: .media, mediaId: audioId, start: at, duration: hi - lo, sourceIn: lo), trackId: audioTrack.id, mode: .place)
            let counts = Dictionary(grouping: finalTurns, by: \.angle).mapValues(\.count)
            return "Synced: " + (summary.isEmpty ? "single angle" : summary.joined(separator: ", ")) + ". Cut \(finalTurns.count) shots on \(trackId) (" + counts.sorted { $0.key < $1.key }.map { "\($0.key) ×\($0.value)" }.joined(separator: ", ") + ") with \(audioId)'s sound on \(audioTrack.id)."
        }
    }
}

extension Toolbox {
    /// Lab statistics of a clip's picture from three frames across what it plays.
    static func colorStats(_ c: Clip, _ p: Project) async throws -> ColorMatch.Stats {
        guard let m = c.mediaId.flatMap({ p.mediaAsset($0) }), m.hasVideo else { throw EditError("\(c.id) has no picture") }
        let times = m.isImage ? [0.0] : [0.2, 0.5, 0.8].map { min(c.sourceIn, c.sourceOut) + abs(c.sourceOut - c.sourceIn) * $0 }
        var pixels: [SIMD3<Float>] = []
        for f in try await Frames.media(m, times: times, maxSize: CGSize(width: 160, height: 160)) {
            let w = f.image.width, h = f.image.height
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let data = ctx.data else { continue }
            ctx.draw(f.image, in: CGRect(x: 0, y: 0, width: w, height: h))
            let px = data.assumingMemoryBound(to: UInt8.self)
            for i in stride(from: 0, to: w * h, by: 2) {
                pixels.append(SIMD3(Float(px[i * 4]) / 255, Float(px[i * 4 + 1]) / 255, Float(px[i * 4 + 2]) / 255))
            }
        }
        return ColorMatch.stats(pixels)
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
