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
                    let notes = try await session.analyze(m, transcript: m.hasAudio, audio: m.hasAudio, scenes: m.hasVideo, language: args.optString("language") ?? "en-US")
                    if !notes.isEmpty { line += " — " + notes }
                }
                lines.append(line)
            }
            return .text(lines.joined(separator: "\n") + "\nNext: media_transcript to read speech, media_frames to look at footage.")
        })

        add(Tool(name: "media_analyze", description: "Re-run analysis for one media file, e.g. with another language.", schema: Schema.object([
            "media_id": Schema.string("Media id"),
            "transcript": Schema.bool("Transcribe speech, default true"),
            "scenes": Schema.bool("Detect scene cuts, default true"),
            "language": Schema.string("Speech language, default en-US"),
        ], required: ["media_id"])) { [unowned self] args in
            let p = try session.project()
            let id = try args.string("media_id")
            guard let m = p.mediaAsset(id) else { throw EditError("No media \(id)") }
            let notes = try await session.analyze(m, transcript: args.bool("transcript", default: true), audio: true, scenes: args.bool("scenes", default: true), language: args.optString("language") ?? "en-US")
            return .text("\(id): \(notes)")
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
            let words = t.words.filter { $0.end > lo && $0.start < hi }
            guard !words.isEmpty else { return .text("No speech in that range.") }
            if args.bool("words", default: false) {
                return .text(words.map { "\(fmt2($0.start))–\(fmt2($0.end)) \($0.text)\($0.isFiller ? "  (filler)" : "")" }.joined(separator: "\n"))
            }
            let lines = Describe.sentences(words, text: { $0.isFiller ? "*\($0.text)*" : $0.text }, start: \.start, end: \.end).map { s in
                "[\(fmt2(s.0))–\(fmt2(s.1))] \(s.2)" + (s.3.map { "   (pause \(fmt1($0))s)" } ?? "")
            }
            let media = try session.project().mediaAsset(id)
            return .text("\(id) transcript (source time, \(fmt2(media?.duration ?? 0))s long):\n" + lines.joined(separator: "\n"))
        })

        add(Tool(name: "media_frames", description: "Look at source footage: returns a labeled contact sheet of frames from one media file (source time). Use it to pick b-roll, find shots, or check framing before editing.", schema: Schema.object([
            "media_id": Schema.string("Media id"),
            "times": Schema.numbers("Exact source times to show"),
            "count": Schema.integer("Evenly spaced frames when times is omitted, default 8, max 24"),
            "start": Schema.time("Range start for count"),
            "end": Schema.time("Range end for count"),
        ], required: ["media_id"])) { [unowned self] args in
            let id = try args.string("media_id")
            guard let m = try session.project().mediaAsset(id) else { throw EditError("No media \(id)") }
            guard m.hasVideo else { throw EditError("\(id) has no picture") }
            let times = try Toolbox.sampleTimes(args, start: 0, end: m.duration)
            let cell = Toolbox.cellWidth(width: m.width, height: m.height, count: times.count)
            let frames = try await Frames.media(m, times: times, maxSize: CGSize(width: cell * 2, height: cell * 2))
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
            for f in frames {
                let visible = p.tracks.reversed().compactMap { t -> String? in
                    guard !t.hidden, let c = t.clip(at: f.time) else { return nil }
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
                    lines.append("  [\(fmt2(s.0))–\(fmt2(s.1))] \(s.2)" + (s.3.map { "   (pause \(fmt1($0))s)" } ?? ""))
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

        add(Tool(name: "export", description: "Render the timeline to a video file. Defaults to <project>/exports/<name>.mp4 with HEVC. Blocks until done.", schema: Schema.object([
            "path": Schema.string("Output file path"),
            "preset": Schema.string("hevc (default, small and sharp), h264 (most compatible) or prores (editing master, .mov)", values: ExportPreset.allCases.map(\.rawValue)),
            "start": Schema.time("Export from this timeline time"),
            "end": Schema.time("Export until this timeline time"),
            "reveal": Schema.bool("Show the file in Finder when done, default false"),
        ])) { [unowned self] args in
            let b = try session.requireBundle()
            let preset = try args.enumValue("preset", ExportPreset.self) ?? .hevc
            let built = try await session.timeline()
            let p = built.scene.project
            guard p.duration > 0 else { throw EditError("The timeline is empty") }
            var url = args.optString("path").map { session.resolve($0) } ?? b.exportsURL.appendingPathComponent(Toolbox.safeName(p.name)).appendingPathExtension(preset.fileExtension)
            if url.pathExtension.isEmpty { url.appendPathExtension(preset.fileExtension) }
            var range: TimeRange?
            if args.has("start") || args.has("end") { range = TimeRange(try args.optTime("start") ?? 0, try args.optTime("end") ?? p.duration) }
            try? session.sendPreview(["action": "export", "state": "started", "path": url.path])
            let started = Date()
            let project = b.url.path
            try await Exporter.export(built, to: url, preset: preset, range: range) { fraction in
                DistributedNotificationCenter.default().postNotificationName(PreviewControl.notification, object: nil, userInfo: ["action": "export", "state": "progress", "progress": fraction, "project": project], deliverImmediately: true)
            }
            try? session.sendPreview(["action": "export", "state": "finished", "path": url.path])
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            let check = try await MediaProbe.probe(url, id: "export")
            if args.bool("reveal", default: false) {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                proc.arguments = ["-R", url.path]
                try? proc.run()
            }
            return .text("Exported \(url.path)\n\(check.width)×\(check.height), \(fmt2(check.duration))s, \(String(format: "%.1f", Double(size) / 1_048_576)) MB, \(preset.rawValue), took \(fmt1(Date().timeIntervalSince(started)))s")
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
