import AppKit
import CutlineCore
import CutlineEngine
import Foundation

extension Toolbox {
    func registerExportTools() {
        add(Tool(name: "export", description: "Render the timeline, or check it against a platform first. platform (youtube, youtube_shorts, tiktok, instagram_reels, instagram_feed, x, linkedin, broadcast) picks codec and checks shape, length, loudness and that text clears the app's UI. Writes subtitles (embedded track and/or .srt/.vtt), chapters from markers (embedded and a YouTube description list), and interchange files for finishing in other editors (otio for DaVinci Resolve/Premiere via OTIO, fcpxml for Final Cut Pro). Defaults to <project>/exports/<name>.mp4 with HEVC. Blocks until done.", schema: Schema.object([
            "path": Schema.string("Output file path"),
            "preset": Schema.string("hevc (default, small and sharp), h264 (most compatible), prores (editing master, .mov), prores4444 (with alpha)", values: ExportPreset.allCases.map(\.rawValue)),
            "platform": Schema.string("Delivery target; sets the preset and runs its checks", values: Platform.all.map(\.id)),
            "bitrate_mbps": Schema.number("Video bitrate in megabits per second; default high quality for the size"),
            "start": Schema.time("Export from this timeline time"),
            "end": Schema.time("Export until this timeline time"),
            "subtitles": Schema.string("Soft subtitles from the transcripts: none (default), embed, sidecar (.srt and .vtt) or both", values: ["none", "embed", "sidecar", "both"]),
            "closed_captions": Schema.bool("Embed CEA-608 closed captions (broadcast, Apple TV, platform ingest) and write an .scc file beside the video, from the transcripts"),
            "chapters": Schema.bool("Chapters from markers, embedded plus a .chapters.txt list; default true with 2+ markers"),
            "interchange": Schema.strings("Also write otio, fcpxml, edl and/or xml (Final Cut Pro 7 XML, best for Premiere and Resolve) next to the video"),
            "check_only": Schema.bool("Only run the platform checks; render nothing"),
            "reveal": Schema.bool("Show the file in Finder when done, default false"),
            "deliver": Schema.string("What to make: video (default); audio (mix only, see audio_format); stems (one audio file per role: dialogue, music, effects, in the master layout); stills (frames at `times`); image_sequence; gif; archive (copy the project and its media, trimmed with trim:true, to path)", values: ["video", "audio", "stems", "stills", "image_sequence", "gif", "archive"]),
            "audio_format": Schema.string("For audio and stems, default wav24", values: Delivery.AudioFormat.allCases.map(\.rawValue)),
            "downmix": Schema.string("For audio and stems: fold the master layout (5.1/7.1) down to stereo or mono (ITU-R BS.775); default keeps the layout", values: AudioLayout.allCases.map(\.rawValue)),
            "image_format": Schema.string("For stills and image sequences, default png", values: Delivery.StillFormat.allCases.map(\.rawValue)),
            "times": Schema.numbers("For stills: timeline times"),
            "trim": Schema.bool("For archive: copy only the used parts of each file plus 1 s handles"),
            "variants": ["type": "array", "description": "Render several versions in one call: [{name, ops: [{tool, args}], and any export argument such as platform, path, start, end}]. Each variant applies its ops (any tools, e.g. recipe reframe, text edits, a different hook), exports, then the project returns to how it was.", "items": ["type": "object"]],
        ])) { [unowned self] args in
            let b = try session.requireBundle()
            if let variants = args.raw["variants"]?.array, !variants.isEmpty {
                return try await exportVariants(variants, base: args)
            }
            if let kind = args.optString("deliver"), kind != "video" {
                return try await deliver(kind, args)
            }
            let platform = try args.optString("platform").map { id -> Platform in
                guard let pl = Platform.named(id) else { throw EditError("Unknown platform \(id). Platforms: \(Platform.all.map(\.id).joined(separator: ", "))") }
                return pl
            }
            let preset = try args.enumValue("preset", ExportPreset.self) ?? platform.flatMap { ExportPreset(rawValue: $0.preset) } ?? .hevc
            let p0 = try session.project()
            guard p0.duration > 0 else { throw EditError("The timeline is empty") }
            var range: TimeRange?
            if args.has("start") || args.has("end") { range = TimeRange(try args.optTime("start") ?? 0, try args.optTime("end") ?? p0.duration) }

            var report: [String] = []
            if let platform {
                var warnings = platform.check(p0)
                let mix = try await LoudnessMeter.measure(try await session.timeline(for: p0), range: range)
                if mix.integrated.isFinite, abs(mix.integrated - platform.loudness) > 1 {
                    warnings.append("Loudness is \(fmt1(mix.integrated)) LUFS; \(platform.name) normalizes to \(fmt1(platform.loudness)). Run recipe loudness_normalize target_lufs:\(Int(platform.loudness)).")
                }
                if mix.truePeakDb > -0.9 { warnings.append("True peak \(fmt1(mix.truePeakDb)) dBTP is above −1; add a limiter (recipe loudness_normalize limit:true).") }
                let text = try await measureText(p0, range: range, platform: platform)
                warnings += text.filter { $0.contains("outside") || $0.contains("hard to read") }.map { $0.trimmingCharacters(in: .whitespaces) }
                report.append("\(platform.name) check: " + (warnings.isEmpty ? "ready." : "\(warnings.count) issue(s)"))
                report += warnings.map { "  - " + $0 }
                if !platform.notes.isEmpty { report.append("  Note: " + platform.notes) }
                if args.bool("check_only", default: false) { return .text(report.joined(separator: "\n")) }
            } else if args.bool("check_only", default: false) {
                throw EditError("check_only needs a platform")
            }

            let built = try await session.timeline()
            let p = built.scene.project
            var url = args.optString("path").map { session.resolve($0) } ?? b.exportsURL.appendingPathComponent(Toolbox.safeName(p.name) + (platform.map { "-" + $0.id } ?? "")).appendingPathExtension(preset.fileExtension)
            if url.pathExtension.isEmpty { url.appendPathExtension(preset.fileExtension) }
            let base = url.deletingPathExtension()
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let transcripts = b.transcripts(for: p)

            let subs = args.optString("subtitles") ?? "none"
            var cues: [TimedText] = []
            if subs != "none" {
                cues = p.subtitleCues(transcripts: transcripts).map { TimedText(start: $0.start, end: $0.end, text: $0.text) }
                if cues.isEmpty { report.append("No transcribed speech on the timeline, so no subtitles.") }
                if subs == "sidecar" || subs == "both" {
                    try p.subtitles(.srt, transcripts: transcripts).write(to: base.appendingPathExtension("srt"), atomically: true, encoding: .utf8)
                    try p.subtitles(.vtt, transcripts: transcripts).write(to: base.appendingPathExtension("vtt"), atomically: true, encoding: .utf8)
                    report.append("Subtitles: \(base.lastPathComponent).srt and .vtt (\(cues.count) cues)")
                }
            }
            var closed: [TimedText] = []
            if args.bool("closed_captions", default: false) {
                closed = p.subtitleCues(transcripts: transcripts, maxCharsPerLine: 32, maxLines: 2).map { TimedText(start: $0.start, end: $0.end, text: $0.text) }
                if closed.isEmpty { report.append("No transcribed speech, so no closed captions.") } else {
                    try CEA608.scc(closed, fps: p.canvas.fps).write(to: base.appendingPathExtension("scc"), atomically: true, encoding: .utf8)
                    report.append("Closed captions: \(closed.count) cues embedded (CEA-608, CC1) and \(base.lastPathComponent).scc")
                }
            }
            var chapters: [TimedText] = []
            if args.bool("chapters", default: p.markers.count >= 2) {
                let list = p.chapters()
                for (i, c) in list.enumerated() {
                    chapters.append(TimedText(start: c.time, end: i + 1 < list.count ? list[i + 1].time : p.duration, text: c.title))
                }
                if !chapters.isEmpty {
                    try p.youtubeChapterList().write(to: base.appendingPathExtension("chapters.txt"), atomically: true, encoding: .utf8)
                    report.append("Chapters: \(chapters.count) embedded; description list in \(base.lastPathComponent).chapters.txt")
                }
            }
            for kind in args.strings("interchange") ?? [] {
                switch kind {
                case "otio": try p.otio().write(to: base.appendingPathExtension("otio"))
                case "fcpxml": try p.fcpxml().write(to: base.appendingPathExtension("fcpxml"), atomically: true, encoding: .utf8)
                case "edl": try p.edl(title: p.name).write(to: base.appendingPathExtension("edl"), atomically: true, encoding: .utf8)
                case "xml": try p.xmeml().write(to: base.appendingPathExtension("xml"), atomically: true, encoding: .utf8)
                default: throw EditError("interchange is otio, fcpxml, edl or xml (Final Cut Pro 7 XML for Premiere and Resolve)")
                }
                report.append("Interchange: \(base.lastPathComponent).\(kind)")
            }

            try? session.sendPreview(["action": "export", "state": "started", "path": url.path])
            let started = Date()
            let project = b.url.path
            var options = ExportOptions(preset: preset, bitrateMbps: args.optDouble("bitrate_mbps"), range: range, subtitles: subs == "embed" || subs == "both" ? cues : [], chapters: chapters)
            options.closedCaptions = closed
            try await Exporter.export(built, to: url, options: options) { fraction in
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
            let seconds = check.duration
            let mbps = seconds > 0 ? Double(size) * 8 / seconds / 1_000_000 : 0
            report.insert("Exported \(url.path)\n\(check.width)×\(check.height), \(fmt2(seconds))s, \(String(format: "%.1f", Double(size) / 1_048_576)) MB (\(fmt1(mbps)) Mb/s), \(preset.rawValue), \(p.master.layout.title) audio, took \(fmt1(Date().timeIntervalSince(started)))s", at: 0)
            return .text(report.joined(separator: "\n"))
        })
    }
}

extension Toolbox {
    func exportVariants(_ variants: [JSON], base: Args) async throws -> ToolResult {
        let b = try session.requireBundle()
        guard let start = b.loadHistory().current?.id else { throw EditError("The project has no history yet") }
        guard let exporter = tools["export"] else { throw EditError("export is unavailable") }
        var report: [String] = []
        defer { _ = try? b.checkout(start) }
        for (i, v) in variants.enumerated() {
            guard case .object(var o) = v else { throw EditError("variants[\(i)] must be an object") }
            let name = o["name"]?.string ?? "variant\(i + 1)"
            for (j, op) in (o["ops"]?.array ?? []).enumerated() {
                guard let tool = op["tool"]?.string, let t = tools[tool], tool != "export" else { throw EditError("variants[\(i)].ops[\(j)]: unknown tool") }
                installResolvers(try? session.project())
                let r = try await t.run(Args(op["args"] ?? [:]))
                if r.isError { throw EditError("\(name), op \(j + 1) (\(tool)): \(r.plainText)") }
            }
            o["ops"] = nil
            o["name"] = nil
            if o["path"] == nil {
                let p = try session.project()
                let ext = (o["preset"]?.string).flatMap(ExportPreset.init(rawValue:))?.fileExtension ?? "mp4"
                o["path"] = .string(b.exportsURL.appendingPathComponent(Toolbox.safeName(p.name) + "-" + Toolbox.safeName(name)).appendingPathExtension(ext).path)
            }
            for (k, val) in base.raw where k != "variants" && o[k] == nil { o[k] = val }
            installResolvers(try? session.project())
            let r = try await exporter.run(Args(.object(o)))
            report.append("\(name): " + r.plainText.replacingOccurrences(of: "\n", with: "\n  "))
            _ = try b.checkout(start)
        }
        return .text(report.joined(separator: "\n") + "\nThe project is back at \(start).")
    }
}

extension Toolbox {
    func deliver(_ kind: String, _ args: Args) async throws -> ToolResult {
        let b = try session.requireBundle()
        let p = try session.project()
        guard p.duration > 0 else { throw EditError("The timeline is empty") }
        var range: TimeRange?
        if args.has("start") || args.has("end") { range = TimeRange(try args.optTime("start") ?? 0, try args.optTime("end") ?? p.duration) }
        let stem = Toolbox.safeName(p.name)
        let started = Date()
        switch kind {
        case "audio":
            let format = try args.enumValue("audio_format", Delivery.AudioFormat.self) ?? .wav24
            let url = args.optString("path").map { session.resolve($0) } ?? b.exportsURL.appendingPathComponent(stem).appendingPathExtension(format.fileExtension)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let layout = try args.enumValue("downmix", AudioLayout.self)
            try await Delivery.audio(try await session.timeline(for: p), range: range, to: url, format: format, layout: layout)
            return .text("Wrote \(url.path) (\(format.rawValue), \((layout ?? p.master.layout).title)), took \(fmt1(Date().timeIntervalSince(started)))s")
        case "stems":
            let format = try args.enumValue("audio_format", Delivery.AudioFormat.self) ?? .wav24
            let dir = args.optString("path").map { session.resolve($0) } ?? b.exportsURL.appendingPathComponent(stem + " stems", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let roles = p.roles(transcripts: b.transcripts(for: p))
            var lines: [String] = []
            for role in Set(roles.values).sorted() {
                var solo = p
                for i in solo.tracks.indices where roles[solo.tracks[i].id] != role { solo.tracks[i].muted = true }
                // Stems are pre-master so they sum back to the mix; the master bus effects stay off.
                solo.master.effects = []
                let url = dir.appendingPathComponent("\(stem) - \(role)").appendingPathExtension(format.fileExtension)
                try await Delivery.audio(try await session.timeline(for: solo), range: range, to: url, format: format, layout: try args.enumValue("downmix", AudioLayout.self))
                let tracks = roles.filter { $0.value == role }.keys.sorted()
                lines.append("\(role): \(url.lastPathComponent) (\(tracks.joined(separator: ", ")))")
            }
            return .text("Wrote \(roles.isEmpty ? 0 : Set(roles.values).count) stems to \(dir.path):\n" + lines.joined(separator: "\n") + "\nSet roles with track_update role.")
        case "stills":
            guard let times = args.raw["times"]?.array?.compactMap({ try? Args.parseTime($0, name: "times") }), !times.isEmpty else { throw EditError("Pass times") }
            let format = try args.enumValue("image_format", Delivery.StillFormat.self) ?? .png
            let dir = args.optString("path").map { session.resolve($0) } ?? b.exportsURL.appendingPathComponent(stem + " stills", isDirectory: true)
            let urls = try await Delivery.stills(try await session.timeline(for: p), times: times, to: dir, format: format, name: stem)
            return .text("Wrote \(urls.count) stills to \(dir.path): " + urls.map(\.lastPathComponent).joined(separator: ", "))
        case "image_sequence":
            let format = try args.enumValue("image_format", Delivery.StillFormat.self) ?? .png
            let dir = args.optString("path").map { session.resolve($0) } ?? b.exportsURL.appendingPathComponent(stem + " frames", isDirectory: true)
            let n = try await Delivery.imageSequence(try await session.timeline(for: p), range: range, to: dir, format: format)
            return .text("Wrote \(n) frames to \(dir.path), took \(fmt1(Date().timeIntervalSince(started)))s")
        case "gif":
            let url = args.optString("path").map { session.resolve($0) } ?? b.exportsURL.appendingPathComponent(stem).appendingPathExtension("gif")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try await Delivery.gif(try await session.timeline(for: p), range: range ?? TimeRange(0, min(p.duration, 10)), to: url)
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            return .text("Wrote \(url.path) (\(String(format: "%.1f", Double(size) / 1_048_576)) MB)")
        case "archive":
            guard let path = args.optString("path") else { throw EditError("Pass path, a folder for the archived project") }
            let dir = session.resolve(path)
            let media = dir.appendingPathComponent("Media", isDirectory: true)
            try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
            let (collected, bytes) = try await Consolidate.collect(p, to: media, trim: args.bool("trim", default: false))
            let bundleURL = dir.appendingPathComponent(stem).appendingPathExtension("cutline")
            try? FileManager.default.removeItem(at: bundleURL)
            try ProjectBundle.create(at: bundleURL, project: collected)
            for m in p.media where collected.mediaAsset(m.id) != nil {
                for kind in ["transcript", "audio", "visual", "beats", "speakers", "shots", "sounds", "tracks"] {
                    let f = b.analysisURL.appendingPathComponent("\(m.id).\(kind).json")
                    try? FileManager.default.copyItem(at: f, to: bundleURL.appendingPathComponent("analysis/\(m.id).\(kind).json"))
                }
            }
            return .text("Archived to \(bundleURL.path) with \(collected.media.count) media files (\(String(format: "%.1f", Double(bytes) / 1_048_576)) MB)\(args.bool("trim", default: false) ? ", trimmed to the used ranges; trimmed media get new ids, so re-run media_analyze there" : "").")
        default:
            throw EditError("deliver is video, audio, stems, stills, image_sequence, gif or archive")
        }
    }
}
