import CoreGraphics
import CutlineCore
import CutlineEngine
import Foundation

extension Toolbox {
    func registerMulticamTools() {
        add(Tool(name: "multicam_create", description: "Build a multicam clip from synced recordings of one event, like a multicam clip in Final Cut or a multi-camera source sequence in Premiere: every angle stays inside it, in sync, and the timeline clip plays one active angle per range (switch with multicam_cut or recipe multicam_switch clip:<id>), so any cut can be changed to another angle later. sync: audio (default: cross-correlates each angle's sound with the first one that has sound), timecode (source timecode), marker (points: the source time of one shared moment, e.g. a clap, in every angle) or in_points (points as each angle's in point, default 0). audio names sound-only recorders to add as angles and the sound heard by default (default: the first angle with sound); audio_follows_video plays each range's own camera sound instead. Places the clip on track (default V1) at at (default the end of the track) unless place:false. Review the angles with multicam_angles and timeline_frames multicam:true; export plays the active angles; FCPXML and XML keep them multicam.", schema: Schema.object([
            "angles": Schema.strings("Media ids of the cameras, in angle order (1, 2, …)"),
            "names": Schema.strings("Angle names, default the media ids"),
            "audio": Schema.strings("Sound-only media to add as angles, or angles to hear by default"),
            "sync": Schema.string("audio (default), timecode, marker or in_points"),
            "points": ["type": "object", "additionalProperties": ["type": ["number", "string"]], "description": "For marker or in_points: {media: source seconds} of the shared moment or in point"],
            "name": Schema.string("Multicam name"),
            "track": Schema.string("Video track for the clip, default V1"),
            "at": Schema.time("Timeline time for the clip, default the end of the track"),
            "place": Schema.bool("Put the clip on the timeline, default true"),
            "audio_follows_video": Schema.bool("Each range plays the active camera's own sound"),
            "channel": Schema.string("Source channel(s) to sync by, e.g. \"ch1\""),
            "force": Schema.bool("Keep angles whose sound syncs with confidence under \(fmt2(Toolbox.minSyncConfidence)) (left out by default)"),
            "dry_run": Schema.bool("Report what would change without applying it"),
        ], required: ["angles"])) { [unowned self] args in
            try await self.createMulticam(args)
        })

        add(Tool(name: "multicam_angles", description: "A multicam clip's angles (number, name, media, sync offset, picture/sound) and its switching: the active angle and sound per range in timeline time, or at one time with at. Use it to review cuts before changing them with multicam_cut; timeline_frames multicam:true shows every angle at a time side by side.", schema: Schema.object([
            "clip": Schema.string("Multicam clip id (default: the only one)"),
            "at": Schema.time("Only the active angle at this timeline time"),
        ])) { [unowned self] args in
            let p = try self.session.project()
            let clip = try Toolbox.multicamClip(args.optString("clip"), p)
            return .text(Toolbox.describeAngles(clip, p, at: try args.optTime("at")))
        })

        addEdit(EditTool(name: "multicam_cut", description: "Switch a multicam clip's angle: at switches from that timeline time until the next cut (like cutting live in an angle viewer); from + to switches just that range and keeps what follows. angle is a number, name or media id. audio switches the sound for that range too (angles with sound); without at/from, audio sets the clip's sound everywhere and audio_follows_video:true makes the sound follow the picture. The angle structure stays, so a cut can be switched again any time.", schema: Schema.object([
            "clip": Schema.string("Multicam clip id (default: the one under at/from on V1, or the only one)"),
            "at": Schema.time("Switch from here until the next cut"),
            "from": Schema.time("Switch this range only: start"),
            "to": Schema.time("Switch this range only: end"),
            "angle": Schema.string("Angle number, name or media id"),
            "audio": Schema.strings("Sound angle(s) for the range, or for the whole clip without at/from"),
            "audio_follows_video": Schema.bool("Sound follows the active angle"),
        ]), label: { a, _ in "Multicam cut to \(a.optString("angle") ?? a.strings("audio")?.joined(separator: "+") ?? "sound")" }) { p, args in
            let at = try args.optTime("at") ?? args.optTime("from")
            let clip = try Toolbox.multicamClip(args.optString("clip"), p, at: at)
            if at == nil {
                guard args.has("audio") || args.has("audio_follows_video") else { throw EditError("Pass at (or from/to) with angle, or audio / audio_follows_video for the clip's sound") }
                try p.setMulticamSound(clip.id, audio: args.strings("audio"), followsVideo: args.optBool("audio_follows_video"))
                let c = p.clip(clip.id)!
                return "\(clip.id) sound: " + (c.multicam?.audioFollowsVideo == true ? "follows the picture" : (c.multicam?.audio ?? p.multicamSetup(c)?.audio ?? []).joined(separator: "+"))
            }
            guard args.has("angle") || args.has("audio") else { throw EditError("Pass angle (number, name or media id) and/or audio") }
            if let follows = args.optBool("audio_follows_video") { try p.setMulticamSound(clip.id, audio: nil, followsVideo: follows) }
            let line = try p.switchMulticam(clip.id, from: at!, to: try args.optTime("to"), angle: args.optString("angle"), audio: args.strings("audio"))
            return line + "\n" + Toolbox.rangeLines(p.clip(clip.id)!, p).joined(separator: "\n")
        })
    }

    /// The multicam clip named, else the one under `at` (V1 first), else the project's only one.
    static func multicamClip(_ id: String?, _ p: Project, at: Seconds? = nil) throws -> Clip {
        if let id {
            guard let c = p.clip(id) else { throw EditError("No clip \(id)") }
            guard p.multicamSetup(c) != nil else { throw EditError("\(id) is not a multicam clip; build one with multicam_create") }
            return c
        }
        let all = p.tracks.flatMap { t in t.clips.filter { p.multicamSetup($0) != nil } }
        if let at, let hit = p.tracks.compactMap({ $0.clip(at: at) }).first(where: { p.multicamSetup($0) != nil }) { return hit }
        guard let only = all.first else { throw EditError("No multicam clip on the timeline; build one with multicam_create") }
        guard all.count == 1 else { throw EditError("Several multicam clips (\(all.map(\.id).joined(separator: ", "))); pass clip") }
        return only
    }

    static func rangeLines(_ c: Clip, _ p: Project) -> [String] {
        guard let setup = p.multicamSetup(c) else { return [] }
        return p.visibleAngleRanges(c).map { r in
            "  \(fmt2(r.range.start))–\(fmt2(r.range.end))s  angle \(setup.number(r.angle)) \(r.angle)  sound " + r.audio.map { "\(setup.number($0)) \($0)" }.joined(separator: "+")
        }
    }

    static func describeAngles(_ c: Clip, _ p: Project, at: Seconds?) -> String {
        guard let setup = p.multicamSetup(c), let seq = c.mediaId.flatMap({ p.sequence($0) }) else { return "" }
        var lines = ["\(c.id) multicam \"\(seq.name)\" \(fmt2(c.start))–\(fmt2(c.end))s (multicam time \(fmt2(c.sourceIn))–\(fmt2(c.sourceIn + c.duration)) of \(fmt2(seq.duration))s, synced by \(setup.sync))"]
        for (i, a) in setup.angles.enumerated() {
            let kind = [a.video ? "picture" : nil, a.audio ? "sound" : nil].compactMap { $0 }.joined(separator: "+")
            lines.append("  \(i + 1) \(a.name): \(a.mediaId) \(kind), source = multicam time \(a.offset >= 0 ? "+" : "−") \(String(format: "%.3f", abs(a.offset)))s" + (setup.audio.contains(a.name) ? ", default sound" : ""))
        }
        if c.multicam?.audioFollowsVideo == true { lines.append("Sound follows the picture.") }
        let ranges = p.visibleAngleRanges(c)
        if let at {
            guard let r = ranges.last(where: { $0.range.start <= at + 1e-6 }) ?? ranges.first else { return lines.joined(separator: "\n") }
            lines.append("At \(fmt2(at))s: angle \(setup.number(r.angle)) \(r.angle), sound \(r.audio.joined(separator: "+")) (\(fmt2(r.range.start))–\(fmt2(r.range.end))s)")
        } else {
            let counts = Dictionary(grouping: ranges, by: \.angle).mapValues(\.count)
            lines.append("\(ranges.count) range(s): " + counts.sorted { $0.key < $1.key }.map { "\($0.key) ×\($0.value)" }.joined(separator: ", "))
            lines += rangeLines(c, p).prefix(60)
            if ranges.count > 60 { lines.append("  …and \(ranges.count - 60) more") }
        }
        return lines.joined(separator: "\n")
    }

    /// Sound syncs below this confidence are not trusted: the angle is left out unless forced.
    static let minSyncConfidence = 0.3

    /// Each angle's source time at one shared moment, by sound, timecode or given points; `unsure` lists the angles
    /// whose sound synced below `minSyncConfidence`.
    func multicamOffsets(_ ids: [String], method: String, points: [String: Seconds], channel: String?, project p: Project) async throws -> (offsets: [String: Seconds], notes: [String], unsure: [(id: String, offset: Seconds, confidence: Double)]) {
        var offsets: [String: Seconds] = [:]
        var notes: [String] = []
        var unsure: [(id: String, offset: Seconds, confidence: Double)] = []
        switch method {
        case "audio":
            guard let refId = ids.first(where: { p.mediaAsset($0)?.hasAudio == true }), let ref = p.mediaAsset(refId) else { throw EditError("No angle has sound to sync by; use sync timecode, marker or in_points") }
            offsets[refId] = 0
            let refURL = try await heard(ref, channel)
            for id in ids where offsets[id] == nil {
                guard let m = p.mediaAsset(id) else { throw EditError("No media \(id)") }
                guard m.hasAudio else { throw EditError("\(id) has no sound to sync by; pass sync marker with points, or timecode") }
                let r = try await AudioSync.offset(reference: refURL, other: try await heard(m, channel))
                offsets[id] = r.offset
                notes.append("\(id) \(r.offset >= 0 ? "+" : "")\(String(format: "%.3f", r.offset))s (confidence \(fmt2(r.confidence)))")
                if r.confidence < Toolbox.minSyncConfidence { unsure.append((id, r.offset, r.confidence)) }
                else if r.confidence < 0.5 { notes.append("warning: \(id) synced with low confidence; check it with timeline_frames multicam:true") }
            }
            notes.insert("synced by sound to \(refId)", at: 0)
        case "timecode":
            for id in ids {
                guard let m = p.mediaAsset(id) else { throw EditError("No media \(id)") }
                guard let tc = m.timecodeStart else { throw EditError("\(id) has no source timecode; use sync audio or marker") }
                offsets[id] = -tc
            }
            notes.append("synced by source timecode")
        case "marker", "in_points":
            for id in ids {
                guard p.mediaAsset(id) != nil else { throw EditError("No media \(id)") }
                guard let t = points[id] ?? (method == "in_points" ? 0 : nil) else { throw EditError("sync marker needs points {\"\(id)\": source seconds of the shared moment} for every angle") }
                offsets[id] = t
            }
            notes.append(method == "marker" ? "synced on the marked moment" : "synced on the in points")
        default:
            throw EditError("sync is audio, timecode, marker or in_points")
        }
        return (offsets, notes, unsure)
    }

    func createMulticam(_ args: Args) async throws -> ToolResult {
        let p0 = try session.project()
        guard let angles = args.strings("angles"), !angles.isEmpty else { throw EditError("Pass angles: the media ids of the cameras") }
        let names = args.strings("names") ?? []
        let audioIds = (args.strings("audio") ?? []).filter { !angles.contains($0) }
        var ids = angles + audioIds
        var points: [String: Seconds] = [:]
        for (k, v) in args.value("points")?.object ?? [:] { points[k] = try Args.parseTime(v, name: "points") }
        let method = args.optString("sync") ?? "audio"
        let synced = try await multicamOffsets(ids, method: method, points: points, channel: args.optString("channel"), project: p0)
        var offsets = synced.offsets, notes = synced.notes
        let unsure = synced.unsure
        var named = Dictionary(ids.enumerated().map { i, id in (id, i < names.count ? names[i] : id) }, uniquingKeysWith: { a, _ in a })
        var audio = args.strings("audio") ?? []
        if !unsure.isEmpty {
            let list = unsure.map { String(format: "%@ (confidence %.2f at %+.1fs)", $0.id, $0.confidence, $0.offset) }.joined(separator: ", ")
            if args.bool("force", default: false) {
                notes.append("warning: kept \(list) on force:true though their sound barely matches; check them with timeline_frames multicam:true")
            } else {
                let gone = Set(unsure.map(\.id))
                ids.removeAll { gone.contains($0) }
                audio.removeAll { gone.contains($0) }
                for id in gone { offsets[id] = nil; named[id] = nil }
                guard ids.contains(where: { p0.mediaAsset($0)?.hasVideo == true }), ids.count > 1 else {
                    throw EditError("Sound sync failed: \(list) don't match the reference sound (confidence under \(fmt2(Toolbox.minSyncConfidence))). Sync by timecode (sync:\"timecode\") or a shared moment such as a clap (sync:\"marker\" with points), or pass force:true to keep these offsets")
                }
                notes.append("left out \(list): the sound doesn't match the reference well enough to trust the offset (confidence under \(fmt2(Toolbox.minSyncConfidence))). Sync by timecode (sync:\"timecode\") or a shared moment (sync:\"marker\" with points), or pass force:true to keep it")
            }
        }
        let kept = ids
        let keptAudio = audio
        let dry = args.bool("dry_run", default: false)
        return try runEdit("Create multicam from \(angles.filter(kept.contains).count) angles", dry: dry) { p in
            let list = kept.map { id in (name: named[id] ?? id, mediaId: id, offset: offsets[id] ?? 0) }
            let seq = try p.createMulticam(name: args.optString("name") ?? "Multicam \(p.sequences.filter { $0.multicam != nil }.count + 1)", angles: list, audio: keptAudio, sync: method)
            p.addSyncGroup(offsets)
            var out = ["Multicam \(seq.id) \"\(seq.name)\" (\(fmt2(seq.duration))s), " + notes.joined(separator: ", ") + "."]
            if let o = p.multicamOverlap(seq) { out.append("All video angles overlap at multicam time \(fmt2(o.start))–\(fmt2(o.end))s.") }
            if args.bool("place", default: true) {
                let trackId = args.optString("track") ?? "V1"
                guard let ti = p.trackIndex(trackId), p.tracks[ti].kind == .video else { throw EditError("No video track \(trackId)") }
                let at = try args.optTime("at") ?? (p.tracks[ti].clips.map(\.end).max() ?? 0)
                var c = Clip(id: Project.newClipId(), kind: .sequence, name: seq.name, mediaId: seq.id, start: at, duration: seq.duration)
                c.multicam = MulticamSwitch(cuts: [AngleCut(at: 0, angle: seq.multicam!.videoAngles[0].name)], audioFollowsVideo: args.bool("audio_follows_video", default: false))
                let placed = try p.addClip(c, trackId: trackId, mode: .overwrite)
                out.append("Placed \(placed.id) on \(trackId) at \(fmt2(placed.start))–\(fmt2(placed.end))s.")
            }
            out.append(Toolbox.describeAngles(p.tracks.flatMap(\.clips).last { $0.mediaId == seq.id } ?? Clip(id: "-", kind: .sequence, mediaId: seq.id, start: 0, duration: seq.duration), p, at: nil).components(separatedBy: "\n").dropFirst().prefix(kept.count).joined(separator: "\n"))
            let id = p.tracks.flatMap(\.clips).last { $0.mediaId == seq.id }?.id ?? "<id>"
            out.append("Switch angles with recipe multicam_switch clip:\(id) (by speaker) or multicam_cut; see them all with timeline_frames multicam:true.")
            return out.joined(separator: "\n")
        }
    }

    /// timeline_frames multicam:true: every angle of the multicam clip at each time, the active one marked.
    func multicamFrames(_ args: Args) async throws -> ToolResult {
        let p = try session.project()
        let first = try Toolbox.multicamClip(args.optString("clip"), p, at: (args.raw["times"]?.array?.first).flatMap { try? Args.parseTime($0, name: "times") })
        let times = try Toolbox.sampleTimes(args, start: first.start, end: first.end, defaultCount: 1)
        var frames: [LabeledFrame] = []
        var lines: [String] = []
        var columns = 1
        for t in times {
            let clip = (try? Toolbox.multicamClip(args.optString("clip"), p, at: t)) ?? first
            guard let setup = p.multicamSetup(clip), t >= clip.start - 1e-6, t < clip.end + 1e-6 else { lines.append("\(fmt2(t))s: no multicam clip here"); continue }
            let m = Project.multicamTime(clip, timeline: t)
            let ranges = p.angleRanges(clip)
            let active = ranges.last { $0.range.start <= m + 1e-6 } ?? ranges.first
            let video = setup.videoAngles
            columns = max(columns, min(video.count, 4))
            let cell = Toolbox.cellWidth(width: p.canvas.width, height: p.canvas.height, count: video.count)
            var shown: [String] = []
            for a in video {
                guard let media = p.mediaAsset(a.mediaId) else { continue }
                let n = setup.number(a.name)
                let on = a.name == active?.angle
                let source = m + a.offset
                let label = "\(fmt2(t))s  \(n) \(a.name)" + (on ? "  ● LIVE" : "")
                if source < 0 || source > media.duration {
                    if let blank = Toolbox.blankFrame(width: media.width, height: media.height) { frames.append(LabeledFrame(time: t, label: label + " (no footage)", image: blank)) }
                    shown.append("\(n) \(a.name) no footage")
                    continue
                }
                var f = try await Frames.media(media, times: [source], maxSize: CGSize(width: cell * 1.5, height: cell * 1.5))
                guard var g = f.popLast() else { continue }
                g.label = label
                if on { g.image = Frames.annotate(g.image, boxes: [(NormRect(x: 0.005, y: 0.005, width: 0.99, height: 0.99), CGColor(red: 0.95, green: 0.25, blue: 0.2, alpha: 1), nil)]) }
                frames.append(g)
                shown.append("\(n) \(a.name)@\(fmt2(source))" + (on ? " LIVE" : ""))
            }
            lines.append("\(fmt2(t))s \(clip.id) (multicam \(fmt2(m))): " + shown.joined(separator: "  ") + "; sound " + (active?.audio.joined(separator: "+") ?? "—"))
        }
        guard let jpeg = Frames.contactSheet(frames, columns: columns, cellWidth: Toolbox.cellWidth(width: p.canvas.width, height: p.canvas.height, count: columns)) else { throw EditError("Could not render the angles") }
        var r = ToolResult.text(lines.joined(separator: "\n") + "\nSwitch with multicam_cut clip:\(first.id) at:<time> angle:<number>.")
        r.addImage(jpeg)
        return r
    }

    static func blankFrame(width: Int, height: Int) -> CGImage? {
        let w = max(16, min(width, 640)), h = max(9, w * max(height, 1) / max(width, 1))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 0.15, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }
}

extension Toolbox {
    /// recipe multicam_switch: cuts by who speaks, on a multicam clip (clip, or angles to build one), or by hand (cuts).
    func multicam(_ a: Args, dry: Bool, bundle b: ProjectBundle, project current: Project) async throws -> ToolResult {
        let trackId = a.optString("track") ?? "V1"
        if let raw = a.value("cuts")?.array {
            let cuts = try raw.map { item -> (at: Seconds, angle: String) in
                guard let o = item.object else { throw EditError("Each cut is {at, angle}") }
                let sub = Args(.object(o))
                return (try sub.time("at"), try sub.string("angle"))
            }
            guard !cuts.isEmpty else { throw EditError("Pass cuts: [{at, angle}]") }
            return try runEdit("Switch \(cuts.count) angle(s)", dry: dry) { p in
                var lines: [String] = []
                for c in cuts.sorted(by: { $0.at < $1.at }) {
                    let hit = try a.optString("clip").map { try Toolbox.multicamClip($0, p) } ?? p.trackIndex(trackId).flatMap { p.tracks[$0].clip(at: p.canvas.snap(c.at)) }
                    if let hit, p.multicamSetup(hit) != nil {
                        lines.append(try p.switchMulticam(hit.id, from: c.at, angle: c.angle))
                    } else {
                        lines += try p.switchAngles([c], trackId: trackId)
                    }
                }
                return "Switched angles on \(trackId):\n" + lines.joined(separator: "\n")
            }
        }
        if let id = a.optString("clip") {
            let clip = try Toolbox.multicamClip(id, current)
            return try await multicamAuto(a, dry: dry, bundle: b, project: current, clip: clip)
        }
        // Without clip or angles: the timeline's multicam clip, when there is exactly one.
        if a.strings("angles") == nil, current.tracks.contains(where: { $0.clips.contains { current.multicamSetup($0) != nil } }) {
            return try await multicamAuto(a, dry: dry, bundle: b, project: current, clip: try Toolbox.multicamClip(nil, current))
        }
        guard let angles = a.strings("angles"), angles.count >= 2 else { throw EditError("Pass clip (a multicam clip), at least two angles (media ids), or cuts: [{at, angle}] to switch angles by hand") }
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
            if r.confidence < Toolbox.minSyncConfidence, !a.bool("force", default: false) {
                throw EditError(String(format: "%@'s sound doesn't match %@ (sync confidence %.2f at %+.1fs, under %.2f), so its offset can't be trusted. Build the multicam by timecode or a shared moment (multicam_create sync:\"timecode\" or sync:\"marker\" with points) and pass clip, or pass force:true", id, audioId, r.confidence, r.offset, Toolbox.minSyncConfidence))
            }
            if r.confidence < 0.5 { notes.append("warning: \(id) synced with low confidence; check it with timeline_frames") }
        }
        let lo = try a.optSourceTime("start") ?? 0
        var hi = try a.optSourceTime("end") ?? audio.duration
        for (id, off) in offsets { if let m = current.mediaAsset(id) { hi = min(hi, m.duration - off) } }
        guard hi > lo else { throw EditError("The angles don't overlap in time between start and end") }
        let plan = try await planMulticam(a, angles: angles, audioId: audioId, offsets: offsets, range: TimeRange(lo, hi), bundle: b, project: current) { $0 }
        let at = try a.optTime("at") ?? 0
        let summary = "Synced: " + (notes.isEmpty ? "single angle" : notes.joined(separator: ", "))
        if a.bool("flat", default: false) {
            return try flatMulticam(plan, offsets: offsets, audioId: audioId, angles: angles, range: TimeRange(lo, hi), at: at, trackId: trackId, summary: summary, dry: dry, bundle: b, project: current)
        }
        let wide = a.optString("wide").map { [$0] } ?? []
        var ids: [String] = []
        for id in angles + wide where !ids.contains(id) { ids.append(id) }
        if !ids.contains(audioId) { ids.append(audioId) }
        let framingShots = Toolbox.shotIndex(b, current, media: Set(ids))
        return try runEdit("Multicam edit from \(angles.count) angles", dry: dry) { p in
            guard let ti = p.trackIndex(trackId), p.tracks[ti].kind == .video else { throw EditError("No video track \(trackId)") }
            let seq = try p.createMulticam(name: a.optString("title") ?? "Multicam \(p.sequences.filter { $0.multicam != nil }.count + 1)", angles: ids.map { (name: $0, mediaId: $0, offset: offsets[$0] ?? 0) }, audio: [audioId], sync: "audio")
            p.addSyncGroup(offsets)
            let setup = seq.multicam!
            // Each camera is framed once for the whole clip, so faces stay in view where fill crops it.
            var framed = 0
            if let si = p.sequences.firstIndex(where: { $0.id == seq.id }) {
                for t in p.sequences[si].tracks.indices where p.sequences[si].tracks[t].kind == .video {
                    for k in p.sequences[si].tracks[t].clips.indices {
                        guard let f = Toolbox.fillFraming(p.sequences[si].tracks[t].clips[k], p, framingShots) else { continue }
                        p.sequences[si].tracks[t].clips[k].transform.x = f.x
                        p.sequences[si].tracks[t].clips[k].transform.y = f.y
                        framed += 1
                    }
                }
            }
            let ref = setup.angle(audioId)!.offset
            p.deleteRange(TimeRange(at, at + (hi - lo)), trackIds: [trackId], ripple: false)
            var c = Clip(id: Project.newClipId(), kind: .sequence, name: seq.name, mediaId: seq.id, start: at, duration: p.canvas.snap(hi - lo), sourceIn: lo - ref)
            c.multicam = MulticamSwitch(cuts: [])
            let placed = try p.addClip(c, trackId: trackId, mode: .overwrite)
            try p.setMulticamCuts(placed.id, cuts: plan.shots.map { (at: Project.timelineTime(placed, multicam: $0.start - ref), angle: setup.angle($0.angle)?.name ?? $0.angle) })
            return summary + ". " + plan.describe(on: trackId) + " in multicam clip \(placed.id) (\(ids.count) angles kept in sync inside it) with \(audioId)'s sound."
                + (framed > 0 ? " \(framed) angle(s) framed so faces stay in view where fill crops them." : "")
                + " Review with multicam_angles or timeline_frames multicam:true; change a cut with multicam_cut clip:\(placed.id) at:<time> angle:<n>."
        }
    }

    /// Re-cuts an existing multicam clip by who speaks, keeping its angles.
    func multicamAuto(_ a: Args, dry: Bool, bundle b: ProjectBundle, project current: Project, clip: Clip) async throws -> ToolResult {
        let setup = current.multicamSetup(clip)!
        let videos = setup.videoAngles
        let resolve: (String) -> String = { setup.angle($0)?.mediaId ?? $0 }
        let angles = (a.strings("angles") ?? videos.map(\.name)).map(resolve)
        guard angles.count >= 2 else { throw EditError("\(clip.id) needs at least two video angles to switch between") }
        guard let audioAngle = a.optString("audio").flatMap({ setup.angle($0) }) ?? setup.audio.first.flatMap({ setup.angle($0) }) ?? setup.angles.first(where: \.audio),
              let audio = current.mediaAsset(audioAngle.mediaId) else { throw EditError("\(clip.id) has no angle with sound to cut by") }
        var offsets: [String: Seconds] = [:]
        for x in setup.angles where offsets[x.mediaId] == nil { offsets[x.mediaId] = x.offset - audioAngle.offset }
        let lo = max(try a.optSourceTime("start") ?? 0, clip.sourceIn + audioAngle.offset, 0)
        let hi = min(try a.optSourceTime("end") ?? audio.duration, clip.sourceIn + clip.duration + audioAngle.offset, audio.duration)
        guard hi > lo else { throw EditError("\(audioAngle.name)'s sound doesn't cover \(clip.id)") }
        var args = a
        if let w = a.optString("wide") {
            var raw = a.raw
            raw["wide"] = .string(resolve(w))
            args = Args(raw: raw)
        }
        let plan = try await planMulticam(args, angles: angles, audioId: audioAngle.mediaId, offsets: offsets, range: TimeRange(lo, hi), bundle: b, project: current, resolve: resolve)
        return try runEdit("Multicam switch \(clip.id) by speaker", dry: dry) { p in
            let c = p.clip(clip.id)!
            try p.setMulticamCuts(c.id, cuts: plan.shots.map { shot in (at: Project.timelineTime(c, multicam: shot.start - audioAngle.offset), angle: setup.angles.first { $0.mediaId == shot.angle && $0.video }?.name ?? shot.angle) })
            return plan.describe(on: c.id) + " The angles stay inside \(c.id): multicam_cut changes any range."
        }
    }

    struct MulticamPlanOut {
        var shots: [MulticamShot]
        var how: String
        var minShot: Seconds

        func describe(on target: String) -> String {
            let counts = Dictionary(grouping: shots, by: \.angle).mapValues(\.count)
            let extras = shots.filter { $0.kind != "speaker" }
            let longest = shots.map(\.duration).max() ?? 0
            return "Speakers from \(how). Cut \(shots.count) shots on \(target) (" + counts.sorted { $0.key < $1.key }.map { "\($0.key) ×\($0.value)" }.joined(separator: ", ") + ", none under \(fmt2(minShot))s, longest \(fmt2(longest))s, cuts in the pauses before each new speaker"
                + (extras.isEmpty ? "" : ", \(extras.count) reaction/wide cutaway(s)") + ")"
        }
    }

    /// Shots by who speaks over `range` of `audioId`'s source time; each angle's source is audio time + its offset.
    func planMulticam(_ a: Args, angles: [String], audioId: String, offsets: [String: Seconds], range: TimeRange, bundle b: ProjectBundle, project current: Project, resolve: (String) -> String) async throws -> MulticamPlanOut {
        guard let transcript = b.transcript(audioId) else {
            throw EditError("\(audioId) has no transcript to find speaker turns; run media_analyze media_id:\"\(audioId)\" features:[\"transcript\", \"speakers\"]")
        }
        let lo = range.start, hi = range.end
        let spoken = transcript.words.enumerated().filter { $0.element.end > lo && $0.element.start < hi }
        // Who speaks: whose mic is loudest when each angle records its own person, else the voice analysis.
        let signal = a.optString("signal") ?? "auto"
        var labels: [String?]?
        var how = ""
        if signal != "speakers" {
            var levels: [String: [[Double]]] = [:]
            for id in angles {
                guard let m = current.mediaAsset(id), m.hasAudio else { continue }
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
            // Each speaker goes to the angle where their face is seen talking, when active-speaker analysis shows it.
            var talking: [String: [TimeRange]] = [:]
            for id in angles {
                guard let active = b.analysis(ActiveSpeakers.self, id, "activespeakers") else { continue }
                let off = offsets[id] ?? 0
                talking[id] = active.spans.filter(\.isConfident).map { TimeRange($0.start - off, $0.end - off) }
            }
            let byFace = MulticamPlan.anglesBySpeaker(turns: speakers.segments, talking: talking)
            map.merge(byFace) { _, face in face }
            for (k, v) in a.value("speakers")?.object ?? [:] { if let m = v.string { map[k] = resolve(m) } }
            if !byFace.isEmpty { how += (how.isEmpty ? "speaker analysis" : "") + ", angles matched to talking faces" }
            labels = spoken.map { i, _ in speakers.wordSpeakers.indices.contains(i) ? speakers.wordSpeakers[i].flatMap { map[$0] } : nil }
            if how.isEmpty { how = "speaker analysis" }
            how += " (" + map.sorted { $0.key < $1.key }.map { "\($0.key)→\($0.value)" }.joined(separator: ", ") + ")"
        }
        let words = zip(spoken, labels!).map { MulticamWord(start: $0.element.start, end: $0.element.end, text: $0.element.text, angle: $1) }
        var options = MulticamOptions()
        options.minShot = a.optDouble("min_shot") ?? 1.0
        options.wide = a.optString("wide")
        options.angles = angles
        if let m = a.optDouble("max_shot") { options.maxShot = m > 0 ? m : nil }
        if let r = a.value("reaction") {
            if r.bool == true { options.reactionAfter = 5 } else if let n = r.double { options.reactionAfter = n }
        }
        let shots = MulticamPlan.shots(words: words, range: range, first: words.first?.angle ?? angles[0], options: options)
        return MulticamPlanOut(shots: shots, how: how, minShot: options.minShot)
    }

    /// The shots laid out as separate clips (flat:true), with the sound on a new track.
    func flatMulticam(_ plan: MulticamPlanOut, offsets: [String: Seconds], audioId: String, angles: [String], range: TimeRange, at: Seconds, trackId: String, summary: String, dry: Bool, bundle b: ProjectBundle, project current: Project) throws -> ToolResult {
        let lo = range.start, hi = range.end
        let shots = plan.shots
        let framingShots = Toolbox.shotIndex(b, current, media: Set(angles))
        return try runEdit("Multicam edit from \(angles.count) angles", dry: dry) { p in
            guard let ti = p.trackIndex(trackId), p.tracks[ti].kind == .video else { throw EditError("No video track \(trackId)") }
            p.deleteRange(TimeRange(at, at + (hi - lo)), trackIds: [trackId], ripple: false)
            // Cut points snap to frames and each shot ends where the next begins, so no slivers of background show.
            let cutsAt = shots.map { p.canvas.snap(at + $0.start - lo) } + [p.canvas.snap(at + hi - lo)]
            var framed = 0
            for (i, s) in shots.enumerated() where cutsAt[i + 1] - cutsAt[i] >= p.canvas.frameDuration {
                var c = Clip(id: Project.newClipId(), kind: .media, mediaId: s.angle, start: cutsAt[i], duration: cutsAt[i + 1] - cutsAt[i], sourceIn: cutsAt[i] - at + lo + (offsets[s.angle] ?? 0))
                c.transform.fit = .fill
                if let f = Toolbox.fillFraming(c, p, framingShots) {
                    c.transform.x = f.x
                    c.transform.y = f.y
                    framed += 1
                }
                c.volume = 0
                try p.addClip(c, trackId: trackId, mode: .overwrite)
            }
            p.addSyncGroup(offsets)
            let audioTrack = p.addTrack(kind: .audio, name: "Multicam sound")
            try p.addClip(Clip(id: Project.newClipId(), kind: .media, mediaId: audioId, start: at, duration: hi - lo, sourceIn: lo), trackId: audioTrack.id, mode: .place)
            return summary + ". " + plan.describe(on: trackId) + " with \(audioId)'s sound on \(audioTrack.id)."
                + (framed > 0 ? " \(framed) shot(s) framed so faces stay in view where fill crops the angle." : "")
                + " Recut by hand with recipe multicam_switch cuts:[{at, angle}]."
        }
    }
}
