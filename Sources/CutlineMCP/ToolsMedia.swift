import AVFoundation
import CutlineCore
import CutlineEngine
import Foundation

extension Toolbox {
    func registerMediaTools() {
        add(Tool(name: "media_import", description: "Add media files (video, audio, images) to the project, or relink missing ones. By default each file is analyzed: word-level transcript (on-device speech recognition), pauses from audio levels, and scene cuts. Media is referenced in place, not copied. Each file is checked to decode; files macOS can't play (MXF, DNxHR, XDCAM, MPEG-2…) are transcoded with ffmpeg to a ProRes 422 HQ mezzanine in the project cache (timecode, frame rate, field order and every audio channel kept; long files in the background) while interchange exports keep naming the original. Interlaced media is detected and deinterlaced. Camera RAW: ProRes RAW files, CinemaDNG (a folder of .dng frames is one clip) and raw stills (DNG, CR3, NEF, ARW…) are developed to scene-linear light with raw.* controls (catalog type=raw); BRAW, R3D, ARRIRAW and Canon RAW Light are recognized and reported with what to export instead. A file that can't be imported is listed with its codec and the fix; the others still import. Returns the path → media id mapping to use in edits.", schema: Schema.object([
            "paths": Schema.strings("Files or folders to import; folders import every media file inside, and a folder of DNG frames (or each such sub-folder) is one CinemaDNG clip"),
            "fps": Schema.number("Frame rate of CinemaDNG frames that don't record one (default 24)"),
            "analyze": Schema.bool("Run analysis, default true"),
            "language": Schema.string("Speech language, default en-US"),
            "relink": Schema.bool("Instead of importing, find missing media inside paths (folders searched recursively) and point the project at them"),
        ], required: ["paths"])) { [unowned self] args in
            _ = try session.requireBundle()
            guard let paths = args.strings("paths"), !paths.isEmpty else { throw EditError("paths is empty") }
            if args.bool("relink", default: false) {
                var found: [(String, String)] = []
                let p = try session.edit("Relink media") { p in
                    found = p.relinkAll(searchRoots: paths.map { session.resolve($0) }) { FileManager.default.fileExists(atPath: $0) }
                }
                let still = p.missingMedia { FileManager.default.fileExists(atPath: $0) }
                let transcodes = try await transcodeRelinked(found.map(\.0))
                return .text((found.isEmpty ? "Nothing relinked." : "Relinked " + found.map { "\($0.0) → \($0.1)" }.joined(separator: ", ")) + (still.isEmpty ? "" : "\nStill missing: " + still.map(\.id).joined(separator: ", ")) + transcodes.map { "\n" + $0 }.joined() + "\n" + footer(try session.project()))
            }
            return try await importMedia(paths, args: args)
        })
        registerRelinkTool()

        add(Tool(name: "media_analyze", description: "Analyze media (import already runs the defaults). Features: transcript (words, pauses), scenes (cuts), beats (tempo, beats, downbeats; anchors <media>.b12, beat:12), speakers (who speaks when, word emphasis), shots (per-shot descriptions, shot size, people, on-screen text, faces, saliency, aesthetics; anchors <media>.s3), sounds (laughter, applause, music, etc.). Read results with analysis_read. Long analysis can run in the background; analysis_read and project_status show progress.", schema: Schema.object([
            "media_id": ["description": "Media id, a list of ids, or \"all\"", "anyOf": [["type": "string"], ["type": "array", "items": ["type": "string"]]]],
            "features": Schema.strings("Default: transcript, scenes, beats, speakers, shots, sounds as the media allows"),
            "language": Schema.string("Speech language, default en-US"),
            "background": Schema.bool("Return immediately and analyze in the background, default false"),
            "log": Schema.string("Set the camera log encoding instead of analyzing (\"none\" for normal video); log clips are converted into the canvas color space with input.tone and input.exposure", values: ["none"] + LogProfile.allCases.map(\.rawValue)),
            "signal_range": Schema.string("Whether log code values are legal (video, default) or full range", values: ["video", "full"]),
            "channel": Schema.string("Source channel(s) transcript, speakers, beats, sounds and sync listen to, kept for later analysis: \"ch3\", \"ch3+ch4\", \"mix:1,3\", left, right; \"auto\" (default) uses the first track, or for multichannel files every channel with sound. media_list shows each file's channels"),
            "vocabulary": Schema.strings("Names and terms the transcript should spell this way (characters, products), kept for later analysis; [] clears. Caption replacement targets and named speakers are added automatically. The recognizer's alternative readings that contain a term are preferred, and sound-alike names are respelled"),
        ], required: ["media_id"])) { [unowned self] args in
            if let log = args.optString("log") {
                let ids = args.strings("media_id") ?? []
                let p = try session.edit("Set log encoding of \(ids.joined(separator: ", "))") { p in
                    for id in ids {
                        guard let i = p.media.firstIndex(where: { $0.id == id }) else { throw EditError("No media \(id)") }
                        try Toolbox.applyLog(&p.media[i], args)
                    }
                }
                return .text("\(ids.joined(separator: ", ")): log \(log) (media_organize log sets it too)\n" + footer(p))
            }
            var p = try session.project()
            var ids = args.strings("media_id") ?? []
            if ids == ["all"] { ids = p.media.map(\.id) }
            if let raw = args.optString("channel") {
                let routing: ChannelRouting?
                if raw == "auto" { routing = nil } else {
                    guard let r = ChannelRouting(rawValue: raw) else { throw EditError("channel is auto or \(ChannelRouting.help)") }
                    routing = r
                }
                for id in ids {
                    guard let m = p.mediaAsset(id) else { throw EditError("No media \(id)") }
                    if let routing, let why = routing.problem(count: m.sourceChannelCount) { throw EditError("\(id) channel \(routing.rawValue): \(why)") }
                }
                if ids.contains(where: { p.mediaAsset($0)?.analysisChannel != routing }) {
                    p = try session.edit("Analyze \(ids.joined(separator: ", ")) from \(routing?.rawValue ?? "the default channels")") { p in
                        for id in ids { if let i = p.media.firstIndex(where: { $0.id == id }) { p.media[i].analysisChannel = routing } }
                    }
                }
            }
            if let terms = args.strings("vocabulary") {
                for id in ids where p.mediaAsset(id) == nil { throw EditError("No media \(id)") }
                p = try session.edit("Transcript vocabulary of \(ids.joined(separator: ", "))") { p in
                    for id in ids { if let i = p.media.firstIndex(where: { $0.id == id }) { p.media[i].vocabulary = terms.isEmpty ? nil : terms } }
                }
            }
            let requested = try (args.strings("features") ?? Feature.allCases.map(\.rawValue)).map { f in
                guard let v = Feature(rawValue: f) else { throw EditError("Unknown feature \(f). Features: \(Feature.allCases.map(\.rawValue).joined(separator: ", "))") }
                return v
            }
            let explicit = args.has("features")
            let language = args.optString("language") ?? "en-US"
            var lines: [String] = []
            for id in ids {
                guard let m = p.mediaAsset(id) else { throw EditError("No media \(id)") }
                if args.bool("background", default: false) {
                    let job = session.jobs.enqueue(m.id, requested, bundle: try session.requireBundle().url, language: language, explicit: explicit)
                    lines.append("\(id): queued \(job)")
                } else {
                    lines.append("\(id): " + (try await session.analyze(m, features: requested, language: language, explicit: explicit)).ifEmptyText("nothing to analyze"))
                }
            }
            return .text(lines.joined(separator: "\n"))
        })

        add(Tool(name: "media_remove", description: "Remove media that no clip uses.", schema: Schema.object(["media_id": Schema.string("Media id")], required: ["media_id"])) { [unowned self] args in
            let id = try args.string("media_id")
            let p = try session.edit("Remove media \(id)") { p in
                if let c = p.tracks.flatMap(\.clips).first(where: { $0.mediaId == id }) { throw EditError("\(c.id) still uses \(id)") }
                p.media.removeAll { $0.id == id }
            }
            return .text("Removed \(id)\n" + footer(p))
        })

        add(Tool(name: "media_transcript", description: "Read what is said in a media file, in SOURCE time (use these times with source_cut, assemble and clip source_in/source_out). Sentences show [start–end]; filler words are marked *um*; words the recognizer was unsure of (confidence under 0.5) are marked [word?]; pauses ≥0.4s are noted. words=true lists every word with its time and confidence; low_confidence=true lists only the unsure words with their sentence, to check by ear or media_frames and fix with transcript_edit.", schema: Schema.object([
            "media_id": Schema.string("Media id"),
            "start": Schema.time("Only from this source time"),
            "end": Schema.time("Only until this source time"),
            "words": Schema.bool("List individual words with times, default false"),
            "low_confidence": Schema.bool("List only words under 0.5 confidence, with their sentence"),
        ], required: ["media_id"])) { [unowned self] args in
            let b = try session.requireBundle()
            let id = try args.string("media_id")
            guard let t = b.transcript(id) else { throw EditError("No transcript for \(id). Call media_analyze.") }
            let lo = try args.optTime("start") ?? 0, hi = try args.optTime("end") ?? .infinity
            let words = t.words.enumerated().filter { $0.element.end > lo && $0.element.start < hi }
            guard !words.isEmpty else { return .text("No speech in that range.") }
            if args.bool("low_confidence", default: false) {
                let unsure = words.filter(\.element.isLowConfidence)
                guard !unsure.isEmpty else { return .text(t.words.contains { $0.confidence != nil } ? "No low-confidence words in that range." : "This transcript has no confidence scores; run media_analyze features:[\"transcript\"] to get them.") }
                return .text("\(unsure.count) of \(words.count) words under \(fmt1(Word.lowConfidence)) confidence:\n" + unsure.map { w in
                    let around = t.words[max(0, w.offset - 4)...min(t.words.count - 1, w.offset + 4)].map(\.text).joined(separator: " ")
                    return "w\(w.offset) \(fmt2(w.element.start))–\(fmt2(w.element.end)) \"\(w.element.text)\" \(fmt2(w.element.confidence ?? 0))  …\(around)…"
                }.joined(separator: "\n"))
            }
            if args.bool("words", default: false) {
                return .text(words.map { "w\($0.offset) \(fmt2($0.element.start))–\(fmt2($0.element.end)) \($0.element.text)\($0.element.confidence.map { " (\(fmt2($0)))" } ?? "")\($0.element.isFiller ? "  (filler)" : "")" }.joined(separator: "\n"))
            }
            let speakers = b.analysis(SpeakerAnalysis.self, id, "speakers")
            let multi = (speakers?.speakers.count ?? 0) > 1
            func who(_ i: Int) -> String? { speakers.flatMap { $0.wordSpeakers.indices.contains(i) ? $0.wordSpeakers[i] : nil } }
            var unsureTurns = 0
            /// The speaker turn under most of a sentence was scored below 0.5.
            func unsureTurn(_ a: Seconds, _ b: Seconds) -> Bool {
                let mid = (a + b) / 2
                guard let seg = speakers?.segments.first(where: { $0.start <= mid && mid < $0.end }), let c = seg.confidence, c < 0.5 else { return false }
                unsureTurns += 1
                return true
            }
            func shown(_ w: (offset: Int, element: Word)) -> String {
                if w.element.isFiller { return "*\(w.element.text)*" }
                if w.element.isLowConfidence { return "[\(w.element.text)?]" }
                if let e = speakers?.emphasis, e.indices.contains(w.offset), e[w.offset] >= 0.75 { return "**\(w.element.text)**" }
                return w.element.text
            }
            // One run per speaker turn so sentences never span two speakers.
            var runs: [[(offset: Int, element: Word)]] = []
            for w in words {
                if let last = runs.last?.last, !multi || who(last.offset) == who(w.offset) { runs[runs.count - 1].append(w) } else { runs.append([w]) }
            }
            let lines = runs.flatMap { run in
                Describe.sentences(run, text: shown, start: \.element.start, end: \.element.end).map { s in
                    "[w\(s.first.offset)–w\(s.last.offset)  \(fmt2(s.start))–\(fmt2(s.end))] " + (multi ? "\(who(s.first.offset) ?? "?")\(unsureTurn(s.start, s.end) ? "?" : ""): " : "") + s.text + (s.pauseAfter.map { "   (pause \(fmt1($0))s)" } ?? "")
                }
            }
            let media = try session.project().mediaAsset(id)
            let legend = (multi ? " S1, S2… are speakers" + (unsureTurns > 0 ? "; S2? marks an uncertain turn (transcript_edit speaker fixes it)." : ".") : "") + (speakers != nil ? " **word** is stressed." : "") + (words.contains { $0.element.isLowConfidence } ? " [word?] is uncertain (low_confidence:true lists them)." : "")
            return .text("\(id) transcript (source time, \(fmt2(media?.duration ?? 0))s long).\(legend) Word ids work as anchors, e.g. \"\(id).w\(words[0].offset)\" or \"\(id).w\(words[0].offset).end\":\n" + lines.joined(separator: "\n"))
        })

        add(Tool(name: "media_frames", description: "Look at source footage: returns a labeled contact sheet of frames from one media file (source time). Use it to pick b-roll, find shots, or check framing before editing.", schema: Schema.object([
            "media_id": Schema.string("Media id"),
            "times": Schema.numbers("Exact source times to show"),
            "count": Schema.integer("Evenly spaced frames when times is omitted, default 8, max 24"),
            "start": Schema.time("Range start for count"),
            "end": Schema.time("Range end for count"),
            "overlay": Schema.bool("Draw tracked faces, the salient subject and the shot size (needs shot analysis)"),
        ], required: ["media_id"])) { [unowned self] args in
            let id = try args.string("media_id")
            guard let m = try session.project().mediaAsset(id) else { throw EditError("No media \(id)") }
            guard m.hasVideo else { throw EditError("\(id) has no picture") }
            let times = try Toolbox.sampleTimes(args, start: 0, end: m.duration)
            let cell = Toolbox.cellWidth(width: m.width, height: m.height, count: times.count)
            var frames = try await Frames.media(m, times: times, maxSize: CGSize(width: cell * 2, height: cell * 2))
            if args.bool("overlay", default: false) {
                guard let shots = try session.requireBundle().analysis(ShotAnalysis.self, id, "shots") else { throw EditError("overlay needs shot analysis; run media_analyze features:[\"shots\"]") }
                frames = frames.map { f in
                    var boxes: [(NormRect, CGColor, String?)] = []
                    for track in shots.faces {
                        guard let near = track.samples.min(by: { abs($0.t - f.time) < abs($1.t - f.time) }), abs(near.t - f.time) <= 0.6 else { continue }
                        boxes.append((near.box, CGColor(red: 0.94, green: 0.81, blue: 0.43, alpha: 1), "face\(track.id)"))
                    }
                    let shot = shots.shot(at: f.time)
                    if let sal = shot?.saliency { boxes.append((sal, CGColor(red: 0.66, green: 0.71, blue: 0.96, alpha: 1), "subject")) }
                    var g = f
                    g.image = Frames.annotate(f.image, boxes: boxes)
                    if let shot { g.label += "  s\(shot.index) \(shot.size)" }
                    return g
                }
            }
            guard let jpeg = Frames.contactSheet(frames, cellWidth: cell) else { throw EditError("Could not render frames") }
            var r = ToolResult.text("\(id): \(frames.count) frames at source " + frames.map { fmt2($0.time) }.joined(separator: ", "))
            r.addImage(jpeg)
            return r
        })

        add(Tool(name: "timeline_frames", description: "See the edited video: renders timeline frames through the real compositor (layers, transforms, text, captions) exactly as export will. Use it to verify every visual edit. Returns a labeled contact sheet plus which clip is visible at each time.", schema: Schema.object([
            "times": Schema.numbers("Exact timeline times to render"),
            "count": Schema.integer("Evenly spaced frames when times is omitted, default 6, max 24"),
            "start": Schema.time("Range start for count"),
            "end": Schema.time("Range end for count"),
            "size": Schema.string("small (default) or large for detail checks such as text legibility", values: ["small", "large"]),
            "view": Schema.string("picture (default), or matte: white where one clip effect acts and black where it doesn't (its limit window and/or qualifier, mask, chroma key or person/subject/object mask), to check a key or secondary; needs clip, and effect unless the clip has one masked effect", values: ["picture", "matte"]),
            "clip": Schema.string("For view matte: the clip whose effect to show; for multicam: the multicam clip"),
            "effect": Schema.string("For view matte: the effect id on that clip"),
            "multicam": Schema.bool("Angle viewer: every angle of the multicam clip at each time (default one frame at the clip's middle), the live angle outlined in red"),
        ])) { [unowned self] args in
            if args.optString("view") == "matte" { return try await self.matteFrames(args) }
            if args.bool("multicam", default: false) { return try await self.multicamFrames(args) }
            let built = try await session.timeline()
            let p = built.scene.project
            guard p.duration > 0 else { throw EditError("The timeline is empty") }
            let times = try Toolbox.sampleTimes(args, start: 0, end: p.duration, defaultCount: 6)
            let large = args.optString("size") == "large"
            let cell = large ? (p.canvas.width >= p.canvas.height ? 960.0 : 540.0) : Toolbox.cellWidth(width: p.canvas.width, height: p.canvas.height, count: times.count)
            let frames = try await Frames.timeline(built, times: times, maxSize: CGSize(width: cell * 1.5, height: cell * 1.5))
            guard let jpeg = Frames.contactSheet(frames, columns: large ? min(2, frames.count) : nil, cellWidth: cell) else { throw EditError("Could not render frames") }
            var lines: [String] = []
            let windows = p.transitionWindows.filter(\.transition.hasVideo)
            for f in frames {
                let visible = p.tracks.reversed().compactMap { t -> String? in
                    guard !t.hidden else { return nil }
                    if let w = windows.first(where: { $0.trackId == t.id && $0.contains(f.time) }) {
                        return "\(t.id):\(w.transition.id) \(w.transition.type) \(Int((w.progress(at: f.time) * 100).rounded()))% \(w.transition.from ?? "∅")→\(w.transition.to ?? "∅")"
                    }
                    guard let c = t.clip(at: f.time) else { return nil }
                    let angle = p.visibleAngleRanges(c).last { $0.range.start <= f.time + 1e-6 }.map { " angle \($0.angle)" } ?? ""
                    return "\(t.id):\(c.id)" + (c.kind == .media ? "@\(fmt2(c.sourceTime(atTimeline: f.time)))" : angle)
                }
                lines.append("\(fmt2(f.time))s  " + (visible.isEmpty ? "(background)" : visible.joined(separator: "  ")))
            }
            var r = ToolResult.text(lines.joined(separator: "\n"))
            r.addImage(jpeg)
            return r
        })

        add(Tool(name: "timeline_transcript", description: "Read what the edited timeline says, in TIMELINE time, grouped by clip so you can check cuts land between words. Reads the dialogue tracks the captions use (the dialogue role, else every track not named or roled music, effects or ambience; captions_set track_ids overrides); all_tracks:true reads every track. Shows remaining pauses ≥0.4s and leftover filler words.", schema: Schema.object([
            "start": Schema.time("From timeline time"),
            "end": Schema.time("Until timeline time"),
            "all_tracks": Schema.bool("Read every track, including music, effects and ambience; default false"),
        ])) { [unowned self] args in
            let b = try session.requireBundle()
            let p = try b.loadProject()
            let transcripts = b.transcripts(for: p)
            let all = args.bool("all_tracks", default: false)
            let words = all ? p.timelineWords(transcripts: transcripts) : p.captionTimelineWords(transcripts: transcripts)
            let lo = try args.optTime("start") ?? 0, hi = try args.optTime("end") ?? .infinity
            let shown = words.filter { $0.end > lo && $0.start < hi }
            let skipped = all ? [] : Toolbox.otherSpeechTracks(p, transcripts: transcripts, shown: words)
            let note = skipped.isEmpty ? "" : "\nNot read: \(skipped.joined(separator: ", ")) (not dialogue; all_tracks:true includes them)"
            guard !shown.isEmpty else { return .text("No transcribed speech on the dialogue tracks in that range." + note) }
            var lines: [String] = []
            // One header per clip, clips in order of their first word.
            var order: [String] = []
            var byClip: [String: [TimelineWord]] = [:]
            for w in shown {
                if byClip[w.clipId] == nil { order.append(w.clipId) }
                byClip[w.clipId, default: []].append(w)
            }
            // Words inside nested sequences come from "<sequence clip>/<inner>" clips placed on the timeline.
            var heard: [String: (clip: Clip, track: String)] = [:]
            for t in p.flattenedForSound { for c in t.clips { heard[c.id] = (c, t.id) } }
            for id in order {
                guard let group = byClip[id], let (c, trackId) = heard[id] else { continue }
                let nested = id.contains("/") ? " in nested \(id.split(separator: "/").first.map(String.init) ?? "")" : ""
                lines.append("── \(c.id) on \(trackId)\(nested) \(fmt2(c.start))–\(fmt2(c.end)) (\(c.mediaId ?? "") src \(fmt2(c.sourceIn))–\(fmt2(c.sourceOut)))")
                for s in Describe.sentences(group, text: { Word(text: $0.text, start: 0, end: 0).isFiller ? "*\($0.text)*" : $0.text }, start: \.start, end: \.end) {
                    lines.append("  [\(fmt2(s.start))–\(fmt2(s.end)) \(s.first.mediaId).w\(s.first.wordIndex)–w\(s.last.wordIndex)] \(s.text)" + (s.pauseAfter.map { "   (pause \(fmt1($0))s)" } ?? ""))
                }
            }
            let fillers = shown.filter { Word(text: $0.text, start: 0, end: 0).isFiller }.count
            return .text(lines.joined(separator: "\n") + "\n\(shown.count) words, \(fillers) fillers, timeline \(fmt2(p.duration))s" + note)
        })
    }

    /// Tracks with transcribed words that the dialogue reading leaves out, as "A3 \"Room tone\"".
    static func otherSpeechTracks(_ p: Project, transcripts: [String: Transcript], shown: [TimelineWord]) -> [String] {
        let read = Set(shown.map(\.clipId))
        var ids: [String] = []
        var trackOf: [String: Track] = [:]
        for t in p.flattenedForSound { for c in t.clips { trackOf[c.id] = t } }
        for w in p.timelineWords(transcripts: transcripts) where !read.contains(w.clipId) {
            guard let t = trackOf[w.clipId] else { continue }
            let label = "\(t.id) \"\(t.name)\""
            if !ids.contains(label) { ids.append(label) }
        }
        return ids
    }

    /// timeline_frames view:"matte": renders where one clip effect acts, white on black.
    func matteFrames(_ args: Args) async throws -> ToolResult {
        let b = try session.requireBundle()
        let p = try session.project()
        let clipId = try args.string("clip")
        guard let clip = p.clip(clipId) else { throw EditError("No clip \(clipId)") }
        func masked(_ e: Effect) -> Bool {
            let limit = e.params["limit"]?.string ?? "none"
            return (EffectCatalog.type(e.type)?.category == "mask" && e.type != "mask.matte") || limit != "none" || clip.anim["fx.\(e.id).limit"] != nil
        }
        let list = clip.effects.map { "\($0.id) (\($0.type))" }.joined(separator: ", ").ifEmptyText("none")
        let effectId: String
        if let id = args.optString("effect") {
            effectId = id
        } else {
            let candidates = clip.effects.filter(masked)
            guard candidates.count == 1 else { throw EditError("Pass effect: \(clipId) has \(candidates.isEmpty ? "no masked effects" : "several masked effects"). Effects: \(list)") }
            effectId = candidates[0].id
        }
        guard let fx = clip.effects.first(where: { $0.id == effectId }) else { throw EditError("\(clipId) has no effect \(effectId). Effects: \(list)") }
        if fx.type == "mask.matte" { throw EditError("\(effectId) is a track matte; look at its matte track with timeline_frames instead") }
        let built = try await session.timeline(for: p, shared: false)
        built.scene.matteView = RenderScene.MatteView(clip: clipId, effect: effectId)
        let frame = 1 / p.canvas.fps
        let times = try Toolbox.sampleTimes(args, start: clip.start, end: max(clip.start + frame, clip.end - frame), defaultCount: 4)
        let large = args.optString("size") == "large"
        let cell = large ? (p.canvas.width >= p.canvas.height ? 960.0 : 540.0) : Toolbox.cellWidth(width: p.canvas.width, height: p.canvas.height, count: times.count)
        var frames = try await Frames.timeline(built, times: times, maxSize: CGSize(width: cell * 1.5, height: cell * 1.5))
        var lines = ["Matte of \(effectId) (\(fx.type)) on \(clipId): white is where it acts fully, gray partly, black not at all."]
        for (i, f) in frames.enumerated() {
            let inside = f.time >= clip.start && f.time < clip.end
            let (full, partial) = Toolbox.matteCoverage(f.image)
            frames[i].label += inside ? "" : " (clip not playing)"
            let elsewhere = inside && !fx.acts(atSource: clip.sourceTime(atTimeline: f.time)) ? " (\(effectId) acts only in another shot)" : ""
            lines.append("\(fmt2(f.time))s  " + (inside ? "\(Int((full * 100).rounded()))% of the frame white, \(Int((partial * 100).rounded()))% partial" + elsewhere : "\(clipId) is not on screen"))
        }
        guard let jpeg = Frames.contactSheet(frames, columns: large ? min(2, frames.count) : nil, cellWidth: cell) else { throw EditError("Could not render frames") }
        var r = ToolResult.text(lines.joined(separator: "\n"))
        r.addImage(jpeg)
        return r
    }

    /// Shares of a gray image above 0.9 and between 0.1 and 0.9.
    static func matteCoverage(_ img: CGImage) -> (Double, Double) {
        let w = img.width, h = img.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue), let data = ctx.data else { return (0, 0) }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        let px = data.assumingMemoryBound(to: UInt8.self)
        var full = 0, partial = 0
        for i in 0..<(w * h) {
            if px[i] >= 230 { full += 1 } else if px[i] > 25 { partial += 1 }
        }
        let n = Double(max(1, w * h))
        return (Double(full) / n, Double(partial) / n)
    }

    static let mediaExtensions: Set<String> = Set(["mov", "mp4", "m4v", "mkv", "avi", "mxf", "mts", "m2ts", "mpg", "mpeg", "m2v", "webm", "mp3", "m4a", "wav", "aif", "aiff", "caf", "aac", "flac"]).union(MediaProbe.imageExtensions).union(Toolbox.rawExtensions)

    static func mediaId(for url: URL, existing: Set<String>) -> String {
        let base = url.deletingPathExtension().lastPathComponent.lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : "-" }
            .reduce(into: "") { s, c in if !(c == "-" && s.hasSuffix("-")) { s.append(c) } }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let stem = String((base.isEmpty ? "media" : base).prefix(24))
        var id = stem
        var n = 2
        while existing.contains(id) { id = "\(stem)-\(n)"; n += 1 }
        return id
    }

    static func safeName(_ s: String) -> String {
        let cleaned = s.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == " " ? $0 : "-" }
        return String(cleaned).trimmingCharacters(in: .whitespaces).isEmpty ? "export" : String(cleaned)
    }

    static func sampleTimes(_ args: Args, start: Seconds, end: Seconds, defaultCount: Int = 8) throws -> [Seconds] {
        if let raw = args.raw["times"]?.array, !raw.isEmpty {
            return try raw.prefix(24).map { try Args.parseTime($0, name: "times") }
        }
        let lo = try args.optTime("start") ?? start
        let hi = try args.optTime("end") ?? end
        guard hi > lo else { throw EditError("end must be after start") }
        return Frames.spread(min(24, max(1, args.optInt("count") ?? defaultCount)), from: lo, to: hi)
    }

    static func cellWidth(width: Int, height: Int, count: Int) -> CGFloat {
        let landscape = width >= height
        let base: CGFloat = count <= 2 ? 640 : count <= 4 ? 480 : 360
        return landscape ? base : base * 0.6
    }
}
