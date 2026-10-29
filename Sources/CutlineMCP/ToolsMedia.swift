import AVFoundation
import CutlineCore
import CutlineEngine
import Foundation

extension Toolbox {
    func registerMediaTools() {
        add(Tool(name: "media_import", description: "Add media files (video, audio, images) to the project. By default each file is analyzed: word-level transcript (on-device speech recognition), pauses from audio levels, and scene cuts. Media is referenced in place, not copied. Returns media ids to use in edits.", schema: Schema.object([
            "paths": Schema.strings("Files or folders to import; folders import every media file inside"),
            "analyze": Schema.bool("Run analysis, default true"),
            "language": Schema.string("Speech language, default en-US"),
        ], required: ["paths"])) { [unowned self] args in
            let b = try session.requireBundle()
            guard let paths = args.strings("paths"), !paths.isEmpty else { throw EditError("paths is empty") }
            var files: [URL] = []
            for path in paths {
                let url = session.resolve(path)
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { throw EditError("Not found: \(url.path)") }
                if isDir.boolValue {
                    let items = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
                    files += items.filter { Toolbox.mediaExtensions.contains($0.pathExtension.lowercased()) }.sorted { $0.path < $1.path }
                } else {
                    files.append(url)
                }
            }
            var project = try b.loadProject()
            var imported: [MediaAsset] = []
            var lines: [String] = []
            for url in files {
                if let existing = project.media.first(where: { $0.path == url.path }) {
                    lines.append("\(existing.id): already imported")
                    continue
                }
                let id = Toolbox.mediaId(for: url, existing: Set(project.media.map(\.id)))
                let m = try await MediaProbe.probe(url, id: id)
                project.media.append(m)
                imported.append(m)
            }
            if !imported.isEmpty {
                try session.edit("Import \(imported.map(\.name).joined(separator: ", "))") { $0.media += imported }
            }
            let analyze = args.bool("analyze", default: true)
            for m in imported {
                var line = "\(m.id): \(m.isImage ? "image" : fmt2(m.duration) + "s") \(m.hasVideo ? "\(m.width)×\(m.height)" : "audio only")"
                if analyze {
                    let (now, later) = Session.defaultFeatures(m)
                    let language = args.optString("language") ?? "en-US"
                    let notes = try await session.analyze(m, features: now, language: language, explicit: false)
                    if !notes.isEmpty { line += " — " + notes }
                    if !later.isEmpty {
                        let job = session.jobs.enqueue(m.id, later, bundle: try session.requireBundle().url) { [session] progress in
                            try await session.analyze(m, features: later, language: language, explicit: false, progress: progress)
                        }
                        line += " — \(later.map(\.rawValue).joined(separator: " and ")) analyzing in the background (\(job))"
                    }
                }
                lines.append(line)
            }
            return .text(lines.joined(separator: "\n") + "\nNext: media_transcript to read speech, media_frames to look at footage.")
        })

        add(Tool(name: "media_analyze", description: "Analyze media (import already runs the defaults). Features: transcript (words, pauses), scenes (cuts), beats (tempo, beats, downbeats; anchors <media>.b12, beat:12), speakers (who speaks when, word emphasis), shots (per-shot descriptions, shot size, people, on-screen text, faces, saliency, aesthetics; anchors <media>.s3), sounds (laughter, applause, music, etc.). Read results with analysis_read. Long analysis can run in the background; analysis_read and project_status show progress.", schema: Schema.object([
            "media_id": ["description": "Media id, a list of ids, or \"all\"", "anyOf": [["type": "string"], ["type": "array", "items": ["type": "string"]]]],
            "features": Schema.strings("Default: transcript, scenes, beats, speakers, shots, sounds as the media allows"),
            "language": Schema.string("Speech language, default en-US"),
            "background": Schema.bool("Return immediately and analyze in the background, default false"),
        ], required: ["media_id"])) { [unowned self] args in
            let p = try session.project()
            var ids = args.strings("media_id") ?? []
            if ids == ["all"] { ids = p.media.map(\.id) }
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
                    let job = session.jobs.enqueue(m.id, requested, bundle: try session.requireBundle().url) { [session] progress in
                        try await session.analyze(m, features: requested, language: language, explicit: explicit, progress: progress)
                    }
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

        add(Tool(name: "media_transcript", description: "Read what is said in a media file, in SOURCE time (use these times with source_cut, assemble and clip source_in/source_out). Sentences show [start–end]; filler words are marked *um*; pauses ≥0.4s are noted. words=true lists every word with its time.", schema: Schema.object([
            "media_id": Schema.string("Media id"),
            "start": Schema.time("Only from this source time"),
            "end": Schema.time("Only until this source time"),
            "words": Schema.bool("List individual words with times, default false"),
        ], required: ["media_id"])) { [unowned self] args in
            let b = try session.requireBundle()
            let id = try args.string("media_id")
            guard let t = b.transcript(id) else { throw EditError("No transcript for \(id). Call media_analyze.") }
            let lo = try args.optTime("start") ?? 0, hi = try args.optTime("end") ?? .infinity
            let words = t.words.enumerated().filter { $0.element.end > lo && $0.element.start < hi }
            guard !words.isEmpty else { return .text("No speech in that range.") }
            if args.bool("words", default: false) {
                return .text(words.map { "w\($0.offset) \(fmt2($0.element.start))–\(fmt2($0.element.end)) \($0.element.text)\($0.element.isFiller ? "  (filler)" : "")" }.joined(separator: "\n"))
            }
            let speakers = b.analysis(SpeakerAnalysis.self, id, "speakers")
            let multi = (speakers?.speakers.count ?? 0) > 1
            func who(_ i: Int) -> String? { speakers.flatMap { $0.wordSpeakers.indices.contains(i) ? $0.wordSpeakers[i] : nil } }
            func shown(_ w: (offset: Int, element: Word)) -> String {
                if w.element.isFiller { return "*\(w.element.text)*" }
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
                    "[w\(s.first.offset)–w\(s.last.offset)  \(fmt2(s.start))–\(fmt2(s.end))] " + (multi ? "\(who(s.first.offset) ?? "?"): " : "") + s.text + (s.pauseAfter.map { "   (pause \(fmt1($0))s)" } ?? "")
                }
            }
            let media = try session.project().mediaAsset(id)
            let legend = (multi ? " S1, S2… are speakers." : "") + (speakers != nil ? " **word** is stressed." : "")
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
        ])) { [unowned self] args in
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
                    return "\(t.id):\(c.id)" + (c.kind == .media ? "@\(fmt2(c.sourceTime(atTimeline: f.time)))" : "")
                }
                lines.append("\(fmt2(f.time))s  " + (visible.isEmpty ? "(background)" : visible.joined(separator: "  ")))
            }
            var r = ToolResult.text(lines.joined(separator: "\n"))
            r.addImage(jpeg)
            return r
        })

        add(Tool(name: "timeline_transcript", description: "Read what the edited timeline says, in TIMELINE time, grouped by clip so you can check cuts land between words. Shows remaining pauses ≥0.4s and leftover filler words.", schema: Schema.object([
            "start": Schema.time("From timeline time"),
            "end": Schema.time("Until timeline time"),
        ])) { [unowned self] args in
            let b = try session.requireBundle()
            let p = try b.loadProject()
            let words = p.timelineWords(transcripts: b.transcripts(for: p))
            let lo = try args.optTime("start") ?? 0, hi = try args.optTime("end") ?? .infinity
            let shown = words.filter { $0.end > lo && $0.start < hi }
            guard !shown.isEmpty else { return .text("No transcribed speech on the timeline in that range.") }
            var lines: [String] = []
            var clipId = ""
            var group: [TimelineWord] = []
            func flush() {
                guard let first = group.first, let c = p.clip(first.clipId) else { return }
                lines.append("── \(c.id) \(fmt2(c.start))–\(fmt2(c.end)) (\(c.mediaId ?? "") src \(fmt2(c.sourceIn))–\(fmt2(c.sourceOut)))")
                for s in Describe.sentences(group, text: { Word(text: $0.text, start: 0, end: 0).isFiller ? "*\($0.text)*" : $0.text }, start: \.start, end: \.end) {
                    lines.append("  [\(fmt2(s.start))–\(fmt2(s.end)) \(s.first.mediaId).w\(s.first.wordIndex)–w\(s.last.wordIndex)] \(s.text)" + (s.pauseAfter.map { "   (pause \(fmt1($0))s)" } ?? ""))
                }
                group = []
            }
            for w in shown {
                if w.clipId != clipId { flush(); clipId = w.clipId }
                group.append(w)
            }
            flush()
            let fillers = shown.filter { Word(text: $0.text, start: 0, end: 0).isFiller }.count
            return .text(lines.joined(separator: "\n") + "\n\(shown.count) words, \(fillers) fillers, timeline \(fmt2(p.duration))s")
        })
    }

    static let mediaExtensions: Set<String> = Set(["mov", "mp4", "m4v", "mkv", "avi", "mp3", "m4a", "wav", "aif", "aiff", "caf", "aac", "flac"]).union(MediaProbe.imageExtensions)

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
