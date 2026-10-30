import AppKit
import CutlineCore
import CutlineEngine
import Foundation

extension Toolbox {
    func registerExportTools() {
        add(Tool(name: "export", description: "Render the timeline, or check it against a platform first. platform (youtube, youtube_shorts, tiktok, instagram_reels, instagram_feed, x, linkedin, broadcast_eu, broadcast_us, broadcast) picks codec and checks shape, length, loudness, true peak and that text clears the app's UI; broadcast targets also check frame size, frame rate and mastering codec. .mov files carry a QuickTime timecode track starting at the canvas start timecode (01:00:00:00 unless canvas_set timecode_start); MP4 can't carry one. leader:true prepends bars and tone, a slate and a 2-pop so the program starts on the hour. Writes subtitles (embedded track and/or .srt/.vtt), chapters from markers (embedded and a YouTube description list), and interchange files for finishing in other editors (otio for DaVinci Resolve/Premiere via OTIO, fcpxml for Final Cut Pro). Defaults to <project>/exports/<name>.mp4 with HEVC. Blocks until done.", schema: Schema.object([
            "path": Schema.string("Output file path"),
            "preset": Schema.string("hevc (default, small and sharp), hevc_10bit (Main 10), h264 (most compatible, 8-bit only), prores (422), prores_hq (broadcast master), prores_lt, prores_proxy (offline), prores4444 (with alpha), prores4444xq. ProRes writes .mov. With ffmpeg installed: dnxhr_hq, dnxhr_hqx (10-bit), dnxhr_sq, dnxhr_lb (.mov, or container mxf for MXF OP1a) and xdcam_hd422 (MPEG-2 4:2:2 50 Mb/s long GOP, 1920×1080, eight 24-bit PCM channels, MXF OP1a); these render a ProRes intermediate that ffmpeg encodes, keeping timecode, audio channels and color tags. 10-bit H.264 isn't available", values: ExportPreset.allCases.map(\.rawValue)),
            "platform": Schema.string("Delivery target; sets the preset and runs its checks", values: Platform.all.map(\.id)),
            "bitrate_mbps": Schema.number("Video bitrate in megabits per second; default high quality for the size (HDR HEVC: 20 Mb/s at 1080p30, scaled with size and frame rate)"),
            "hdr": ["type": "object", "description": "HDR10 static metadata for PQ (canvas color_space rec2020_pq) HEVC exports, always written: mastering display (SMPTE ST 2086) and content light levels. Defaults: P3-D65 1000 cd/m² mastering display, MaxCLL and MaxFALL measured from the render (one extra render pass)",
                    "properties": [
                        "mastering": Schema.string("Primaries of the grading monitor, default p3_d65", values: HDRMetadata.MasteringPrimaries.allCases.map(\.rawValue)),
                        "max_nits": Schema.number("Mastering display peak, cd/m² (default 1000)"),
                        "min_nits": Schema.number("Mastering display black, cd/m² (default 0.0001)"),
                        "max_cll": Schema.integer("MaxCLL in cd/m²; default measured"),
                        "max_fall": Schema.integer("MaxFALL in cd/m²; default measured"),
                    ]],
            "container": Schema.string("File format for HEVC and H.264: mp4 (default) or mov (QuickTime, carries a timecode track); ProRes is always mov. DNxHR: mov (default) or mxf (OP1a, one track per audio channel); XDCAM is always mxf. A path ending .mov or .mxf also picks it", values: ["mp4", "mov", "mxf"]),
            "timecode_start": Schema.string("Timecode of the first program frame, \"hh:mm:ss:ff\"; default the canvas start timecode (01:00:00:00 unless set with canvas_set)"),
            "leader": ["type": ["boolean", "object"], "description": "Broadcast leader before the program: true, or {bars, slate, black, pop, version}. SMPTE color bars with 1 kHz tone at −20 dBFS (bars seconds, default 10), a slate with title, date, duration, loudness, audio layout and version (slate seconds, default 10), then black (default 10) with a 2-pop 2 s before the program (pop, default true). The timecode track starts earlier so the program starts at timecode_start (bars at 00:59:30:00 by default)",
                       "properties": [
                           "bars": Schema.integer("Seconds of bars and tone, default 10"),
                           "slate": Schema.integer("Seconds of slate, default 10"),
                           "black": Schema.integer("Seconds of black after the slate, default 10"),
                           "pop": Schema.bool("1 kHz 2-pop two seconds before the program, default true"),
                           "version": Schema.string("Version shown on the slate, default the current history entry"),
                       ]],
            "start": Schema.time("Export from this timeline time"),
            "end": Schema.time("Export until this timeline time"),
            "subtitles": Schema.string("Soft subtitles from the transcripts: none (default), embed, sidecar (subtitle_formats, default .srt and .vtt) or both; ttml, imsc or ebu-tt-d writes just that sidecar", values: ["none", "embed", "sidecar", "both"] + TimedTextFormat.allCases.map(\.rawValue)),
            "subtitle_formats": Schema.strings("Sidecar formats, from srt, vtt, ttml (TTML 2), imsc (IMSC 1.1 Text profile, e.g. Netflix) and ebu-tt-d (EBU-TT-D broadcast); default [\"srt\", \"vtt\"]. All share the same cues"),
            "subtitle_position": Schema.string("TTML-family sidecars: region at the bottom (default) or top of the title-safe area", values: ["bottom", "top"]),
            "subtitle_speakers": Schema.bool("TTML-family sidecars: color each speaker's lines (from speaker analysis) and name them as agents; default false"),
            "interlaced": Schema.string("Interlaced master (1080i broadcast): tff (HD) or bff; renders at the field rate and weaves. ProRes, DNxHR and XDCAM presets; ffmpeg's DNxHR is progressive only, so interlaced DNx is written as DNxHD 1080i (1920×1080 at 25 or 29.97 fps, tff only: hq → DNxHD 220/185, hqx → 220x/185x, sq → 145/120; lb has no interlaced tier)", values: ["tff", "bff"]),
            "closed_captions": Schema.bool("Embed CEA-608 closed captions (broadcast, Apple TV, platform ingest) and write an .scc file beside the video, from the transcripts"),
            "chapters": Schema.bool("Chapters from markers, embedded plus a .chapters.txt list; default true with 2+ markers"),
            "interchange": Schema.strings("Also write otio, fcpxml, edl and/or xml (Final Cut Pro 7 XML, best for Premiere and Resolve) next to the video. Each comes with <name>.<format>.notes.txt listing, clip by clip, what the format can't carry (generators, effects, grades beyond a CDL, …); the report prints it"),
            "render_graphics": Schema.bool("With interchange or a timeline file path: render each generator clip (shapes, particles, lower thirds, title presets) to <name>_graphics/<clip>.mov, ProRes 4444 with alpha, full frame, and reference it as media in the timeline file, as finishing houses take baked graphics. Without it, title presets become titles with their text and other graphics offline placeholders with that file name; Cutline reads either back as the original generator"),
            "bake_luts": Schema.bool("With interchange or a timeline file path: write each graded clip's whole color stack (CDL, wheels, curves, HSL, looks, LUTs, qualified corrections) as a 33³ .cube in <name>_luts/ and name it in the clip's note or comment (GRADE LUT <path>) for a colorist to load; Cutline reads it back as color.lut"),
            "check_only": Schema.bool("Only run the platform checks; render nothing"),
            "strict": Schema.bool("With platform: refuse to export when the platform check finds issues, listing them; default false exports anyway and leads the report with them"),
            "reveal": Schema.bool("Show the file in Finder when done, default false"),
            "deliver": Schema.string("What to make: video (default); audio (mix only, see audio_format); stems (one audio file per role: dialogue, music, effects and clip subroles, in the master layout; stems:\"buses\" for one per bus plus M&E); stills (frames at `times`); image_sequence; gif; archive (copy the project and its media, trimmed with trim:true, to path)", values: ["video", "audio", "stems", "stills", "image_sequence", "gif", "archive"]),
            "audio_format": Schema.string("For audio and stems, default wav24", values: Delivery.AudioFormat.allCases.map(\.rawValue)),
            "stems": Schema.string("For stems: roles (default; track roles and clip audio.role subroles) or buses (one file per bus feeding the master, a \"direct\" file for tracks routed straight to it, and M&E)", values: ["roles", "buses"]),
            "music_and_effects": Schema.bool("For stems: also write M&E, everything except dialogue (default true for buses)"),
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
            let platformChoice = try args.optString("platform").map { id -> Platform in
                guard let pl = Platform.named(id) else { throw EditError("Unknown platform \(id). Platforms: \(Platform.all.map(\.id).joined(separator: ", "))") }
                return pl
            }
            if let name = args.optString("preset"), let why = ExportPreset.unavailable(name) { throw EditError(why) }
            let p0 = try session.project()
            let platform = platformChoice.map { $0.resolved(for: p0) }
            let preset = try args.enumValue("preset", ExportPreset.self) ?? platform.flatMap { ExportPreset(rawValue: $0.preset) } ?? .hevc
            guard p0.duration > 0 else { throw EditError("The timeline is empty") }
            var range: TimeRange?
            if args.has("start") || args.has("end") { range = TimeRange(try args.optTime("start") ?? 0, try args.optTime("end") ?? p0.duration) }

            var report: [String] = []
            // Report lines that go before the export summary: the platform check when it found issues.
            var lead = 0
            var loudness: LoudnessReport?
            if let platform {
                var warnings = platform.check(p0, preset: args.has("preset") ? preset.rawValue : nil)
                let mix = try await LoudnessMeter.measure(try await session.timeline(for: p0), range: range)
                loudness = mix
                if range == nil { session.measuredMix[try session.stems().masterKey(for: p0)] = mix }
                // With a master loudness target, export conforms the mix, so the target is what gets checked.
                let delivered = p0.master.loudnessTarget ?? mix.integrated
                let peak = p0.master.loudnessTarget == nil ? mix.truePeakDb : min(mix.truePeakDb, p0.master.ceiling)
                if delivered.isFinite, abs(delivered - platform.loudness) > platform.loudnessTolerance {
                    warnings.append((p0.master.loudnessTarget == nil ? "Loudness is \(fmt1(mix.integrated)) LUFS" : "The master loudness target is \(fmt1(delivered)) LUFS") + "; \(platform.name) needs \(fmt1(platform.loudness)) ±\(fmt1(platform.loudnessTolerance)). Run recipe loudness_normalize target_lufs:\(Int(platform.loudness)).")
                }
                if peak > platform.truePeak + 0.1 { warnings.append("True peak \(fmt1(peak)) dBTP is above \(fmt1(platform.truePeak)); add a limiter (recipe loudness_normalize ceiling_db:\(fmt1(platform.truePeak - 0.5))).") }
                let text = try await measureText(p0, range: range, platform: platform)
                warnings += text.filter { $0.contains("outside") || $0.contains("hard to read") }.map { $0.trimmingCharacters(in: .whitespaces) }
                let checkOnly = args.bool("check_only", default: false)
                if args.bool("strict", default: false), !checkOnly, !warnings.isEmpty {
                    throw EditError("Not exported: the \(platform.name) check found \(warnings.count) issue(s):\n" + warnings.map { "  - " + $0 }.joined(separator: "\n") + "\nFix them, or export without strict to render anyway.")
                }
                report.append("\(platform.name) check: " + (warnings.isEmpty ? "ready." : "\(warnings.count) issue(s)" + (checkOnly ? "" : ", exported anyway (strict:true refuses)")))
                report += warnings.map { "  - " + $0 }
                if !platform.notes.isEmpty { report.append("  Note: " + platform.notes) }
                if let d = p0.master.drift(integrated: mix.integrated, truePeak: mix.truePeakDb) { report.append("Master loudness target: " + d) }
                if checkOnly { return .text(report.joined(separator: "\n")) }
                if !warnings.isEmpty { lead = report.count }
            } else if args.bool("check_only", default: false) || args.bool("strict", default: false) {
                throw EditError("\(args.bool("check_only", default: false) ? "check_only" : "strict") needs a platform")
            }

            if let target = args.optString("path").map({ session.resolve($0) }), ["otio", "fcpxml", "edl", "xml"].contains(target.pathExtension.lowercased()) {
                // A timeline file path writes just that file.
                let p = try session.project()
                let ext = target.pathExtension.lowercased()
                let format = InterchangeFormat(rawValue: ext) ?? .xml
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                let notes = try await writeInterchange(p, format, to: target, base: target.deletingPathExtension(), args: args)
                return .text("Wrote \(target.path) (timeline \(p.currentTimelineName), \(p.tracks.flatMap(\.clips).count) clips, \(fmt2(p.duration))s); no video rendered.\n" + notes.joined(separator: "\n"))
            }
            let built = try await session.timeline()
            let p = built.scene.project
            let container = try args.enumValue("container", Container.self)
            if container == .mxf, !preset.isDNxHR, preset != .xdcam_hd422 { throw EditError("container mxf is for the DNxHR and XDCAM presets") }
            let ext = preset.isProRes ? "mov" : preset == .xdcam_hd422 ? "mxf" : container?.rawValue ?? preset.fileExtension
            var url = args.optString("path").map { session.resolve($0) } ?? b.exportsURL.appendingPathComponent(Toolbox.safeName(p.name) + (platform.map { "-" + $0.id } ?? "")).appendingPathExtension(ext)
            if url.pathExtension.isEmpty { url.appendPathExtension(ext) }
            if preset.isProRes, url.pathExtension.lowercased() != "mov" { url = url.deletingPathExtension().appendingPathExtension("mov"); report.append("ProRes is QuickTime, so the file is \(url.lastPathComponent).") }
            if preset == .xdcam_hd422, url.pathExtension.lowercased() != "mxf" { url = url.deletingPathExtension().appendingPathExtension("mxf"); report.append("XDCAM HD422 is MXF, so the file is \(url.lastPathComponent).") }
            if preset.isDNxHR, !["mov", "mxf"].contains(url.pathExtension.lowercased()) { url = url.deletingPathExtension().appendingPathExtension(ext); report.append("DNxHR goes in QuickTime or MXF, so the file is \(url.lastPathComponent).") }
            if container == .mov, url.pathExtension.lowercased() != "mov" { throw EditError("container mov needs a path ending .mov") }
            if container == .mxf, url.pathExtension.lowercased() != "mxf" { throw EditError("container mxf needs a path ending .mxf") }
            let fields = try args.enumValue("interlaced", FieldOrder.self)
            if preset.needsFFmpeg, let why = FFmpegDelivery.check(p, preset: preset, container: url.pathExtension.lowercased(), fields: fields) { throw EditError(why) }
            if preset.isDNxHR, fields == .tff, let tier = FFmpegDelivery.interlacedDNxHD(preset, fps: p.canvas.fps) {
                report.append("ffmpeg's DNxHR is progressive only, so this interlaced master is \(tier.name) 1080i (\(preset.title)'s interlaced tier, \(tier.tenBit ? "10" : "8")-bit, top field first).")
            }
            let base = url.deletingPathExtension()
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let transcripts = b.transcripts(for: p)

            let subs = args.optString("subtitles") ?? "none"
            var cues: [TimedText] = []
            if subs != "none" {
                cues = p.subtitleCues(transcripts: transcripts).map { TimedText(start: $0.start, end: $0.end, text: $0.text) }
                if cues.isEmpty { report.append("No transcribed speech on the timeline, so no subtitles.") }
                let overlaps = p.overlappingSpeech(transcripts: transcripts)
                if !overlaps.isEmpty { report.append("Overlapping speech at " + overlaps.prefix(5).map { "\(fmt2($0.start))s" }.joined(separator: ", ") + " interleaves two voices in the subtitles; see captions_list.") }
                if subs != "embed" {
                    // Zero is the file's first frame, so a leader delays them.
                    let lead = try leaderSpec(args.raw["leader"]).map { p.canvas.timecodeFormat.seconds($0.frames(p.canvas.timecodeFormat)) } ?? 0
                    report += try writeSubtitleSidecars(p, args, transcripts: transcripts, range: range, base: base, bundle: b, offset: lead)
                }
            }
            var closed: [TimedText] = []
            var sccCues: [TimedText] = []
            if args.bool("closed_captions", default: false) {
                closed = p.subtitleCues(transcripts: transcripts, maxCharsPerLine: 32, maxLines: 4).map { TimedText(start: $0.start, end: $0.end, text: $0.text) }
                if closed.isEmpty { report.append("No transcribed speech, so no closed captions.") } else {
                    sccCues = p.subtitleCues(transcripts: transcripts, maxCharsPerLine: 32, maxLines: 4, range: range).map { TimedText(start: $0.start, end: $0.end, text: $0.text) }
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
            let kinds = try (args.strings("interchange") ?? []).map { kind -> InterchangeFormat in
                guard let f = InterchangeFormat(rawValue: kind) else { throw EditError("interchange is otio, fcpxml, edl or xml (Final Cut Pro 7 XML for Premiere and Resolve)") }
                return f
            }
            var made: InterchangeOptions?
            for format in kinds {
                if made == nil { made = try await interchangeOptions(p0, base: base, args: args, report: &report) }
                report += try await writeInterchange(p0, format, to: base.appendingPathExtension(format.rawValue), base: base, args: args, options: made)
            }

            try? session.sendPreview(["action": "export", "state": "started", "path": url.path])
            let started = Date()
            let project = b.url.path
            var options = ExportOptions(preset: preset, bitrateMbps: args.optDouble("bitrate_mbps"), range: range, subtitles: subs == "embed" || subs == "both" ? cues : [], chapters: chapters)
            options.interlaced = fields
            if options.interlaced != nil { report.append("Interlaced \(options.interlaced!.rawValue == "tff" ? "top" : "bottom") field first at \(fmt2(p.canvas.fps * 2)) fields/s") }
            options.closedCaptions = closed
            if let o = args.raw["hdr"]?.object {
                var meta = HDRMetadata()
                if let m = o["mastering"]?.string {
                    guard let primaries = HDRMetadata.MasteringPrimaries(rawValue: m) else { throw EditError("hdr.mastering is one of \(HDRMetadata.MasteringPrimaries.allCases.map(\.rawValue).joined(separator: ", "))") }
                    meta.primaries = primaries
                }
                if let v = o["max_nits"]?.double { meta.maxLuminance = v }
                if let v = o["min_nits"]?.double { meta.minLuminance = v }
                meta.maxCLL = o["max_cll"]?.double.map { Int($0.rounded()) }
                meta.maxFALL = o["max_fall"]?.double.map { Int($0.rounded()) }
                guard meta.maxLuminance > meta.minLuminance, meta.minLuminance >= 0 else { throw EditError("hdr.max_nits must be above hdr.min_nits") }
                options.hdr = meta
            }
            let tcFormat = p.canvas.timecodeFormat
            if let tc = args.optString("timecode_start") {
                guard let f = tcFormat.frames(tc) else { throw EditError("timecode_start is hh:mm:ss:ff with frames below \(tcFormat.nominal), e.g. 01:00:00:00") }
                options.timecodeStart = tcFormat.string(f)
            }
            let programTC = options.timecodeStart ?? p.canvas.startTimecode
            if let leader = try leaderSpec(args.raw["leader"]) {
                var l = leader
                let mix: LoudnessReport
                if let loudness { mix = loudness } else { mix = try await LoudnessMeter.measure(built, range: range) }
                let length = (range?.end ?? p.duration) - (range?.start ?? 0)
                let date = DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .none)
                let version = args.raw["leader"]?["version"]?.string ?? b.loadHistory().current?.id ?? "1"
                l.title = p.name
                l.slate = [
                    .init("Date", date),
                    .init("Version", version),
                    .init("Program start", programTC),
                    .init("Duration", tcFormat.string(tcFormat.frameCount(length))),
                    .init("Picture", "\(p.canvas.width)×\(p.canvas.height) \(Describe.fmtFps(p.canvas.fps))p \(preset.title)"),
                    .init("Audio", "\(p.master.layout.title), 48 kHz" + (preset.isProRes ? " 24-bit PCM" : "")),
                    .init("Loudness", p.master.loudnessTarget.map { "\(fmt1($0)) LUFS integrated, ≤ \(fmt1(p.master.ceiling)) dBTP true peak" } ?? (mix.integrated.isFinite ? "\(fmt1(mix.integrated)) LUFS integrated, \(fmt1(mix.truePeakDb)) dBTP true peak" : "silent")),
                ] + (platform.map { [.init("Delivery", $0.name)] } ?? [])
                options.leader = l
                let start = tcFormat.string((tcFormat.frames(programTC) ?? 0) - l.frames(tcFormat))
                report.append("Leader: \(l.barsSeconds)s bars and 1 kHz tone at −20 dBFS from \(start), \(l.slateSeconds)s slate, \(l.blackSeconds)s black" + (l.pop && l.blackSeconds >= 2 ? " with a 2-pop" : "") + "; program at \(programTC)")
            }
            if !sccCues.isEmpty {
                // Labeled on the delivered file's timecode track: program start timecode at the range start, after any leader.
                let programFrame = (tcFormat.frames(programTC) ?? 0) + tcFormat.frameCount(range?.start ?? 0)
                try CEA608.scc(sccCues, fps: p.canvas.fps, start: programFrame, format: tcFormat).write(to: base.appendingPathExtension("scc"), atomically: true, encoding: .utf8)
                report.append("Closed captions: \(closed.count) cues embedded (CEA-608, CC1) and \(base.lastPathComponent).scc, timed on the file's timecode from \(tcFormat.string(programFrame))")
            }
            if preset.needsFFmpeg, !options.subtitles.isEmpty || !options.closedCaptions.isEmpty || !options.chapters.isEmpty {
                report.append("\(preset.title) files carry no subtitle, caption or chapter tracks; use the sidecar files.")
                options.subtitles = []
                options.closedCaptions = []
                options.chapters = []
            }
            let conform: LoudnessConform?
            do {
                conform = try await Exporter.export(built, to: url, options: options) { fraction in
                    DistributedNotificationCenter.default().postNotificationName(PreviewControl.notification, object: nil, userInfo: ["action": "export", "state": "progress", "progress": fraction, "project": project], deliverImmediately: true)
                }
            } catch {
                try? session.sendPreview(["action": "export", "state": "failed", "path": url.path])
                throw EditError("Export failed, nothing was left at \(url.path): \(error.localizedDescription)")
            }
            if let conform { report.append(conform.summary) }
            if range == nil, let conform { session.measuredMix[try session.stems().masterKey(for: p)] = conform.before }
            try? session.sendPreview(["action": "export", "state": "finished", "path": url.path])
            if preset.needsFFmpeg {
                report.insert(try await Toolbox.describeFFmpegExport(url, preset: preset, took: Date().timeIntervalSince(started)), at: lead)
                return .text(report.joined(separator: "\n"))
            }
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
            let timecode = try await TimecodeTrack.read(url)
            report.insert("Exported \(url.path)\n\(check.width)×\(check.height), \(fmt2(seconds))s, \(String(format: "%.1f", Double(size) / 1_048_576)) MB (\(fmt1(mbps)) Mb/s), \(preset.title), \(p.master.layout.title) audio, took \(fmt1(Date().timeIntervalSince(started)))s", at: lead)
            if let hdr = try await HDRMetadata.read(url) {
                report.append("HDR10: \(hdr.primaries.rawValue) mastering display \(fmt1(hdr.maxLuminance))/\(hdr.minLuminance) cd/m², MaxCLL \(hdr.maxCLL ?? 0), MaxFALL \(hdr.maxFALL ?? 0)" + (options.hdr?.maxCLL == nil ? " (measured)" : ""))
            }
            report.insert(timecode.map { "Timecode track starts at \($0)" + (tcFormat.dropFrame ? " (drop frame)" : "") } ?? "No timecode track: MP4 can't carry one; export with container:\"mov\" for a timecode track.", at: lead + 1)
            return .text(report.joined(separator: "\n"))
        })
    }
}

extension Toolbox {
    /// Baked LUTs (bake_luts) and rendered graphics (render_graphics) beside `base`, for the interchange files.
    func interchangeOptions(_ p: Project, base: URL, args: Args, report: inout [String]) async throws -> InterchangeOptions {
        let graphics = URL(fileURLWithPath: base.path + "_graphics", isDirectory: true)
        var o = InterchangeOptions(graphicsFolder: graphics.path)
        if args.bool("bake_luts", default: false) {
            let dir = URL(fileURLWithPath: base.path + "_luts", isDirectory: true)
            let graded = p.gradedClips
            if !graded.isEmpty { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
            for c in graded {
                guard let cube = p.bakedLUT(c) else { continue }
                let url = dir.appendingPathComponent(Project.safeFileName(c.id)).appendingPathExtension("cube")
                try cube.write(to: url, atomically: true, encoding: .utf8)
                o.luts[c.id] = url.path
            }
            report.append(graded.isEmpty ? "bake_luts: no graded clips." : "Baked LUTs: \(o.luts.count) clip grade(s) as 33³ .cube in \(dir.lastPathComponent)/")
        }
        if args.bool("render_graphics", default: false) {
            let clips = p.generatorClips
            if !clips.isEmpty { try FileManager.default.createDirectory(at: graphics, withIntermediateDirectories: true) }
            for (clip, scope) in clips {
                guard let alone = scope.isolating(clip.id) else { continue }
                let url = graphics.appendingPathComponent(Project.safeFileName(clip.id)).appendingPathExtension("mov")
                try? FileManager.default.removeItem(at: url)
                do {
                    _ = try await Exporter.export(try await session.timeline(for: alone), to: url, options: ExportOptions(preset: .prores4444)) { _ in }
                    o.graphics[clip.id] = url.path
                } catch {
                    report.append("Graphic \(clip.id) didn't render (\(error.localizedDescription)); it goes out as an offline placeholder.")
                }
            }
            report.append(clips.isEmpty ? "render_graphics: no generator clips." : "Rendered graphics: \(o.graphics.count) clip(s) as ProRes 4444 with alpha in \(graphics.lastPathComponent)/")
        }
        return o
    }

    /// Writes one interchange file and its notes beside it; returns report lines with the notes.
    func writeInterchange(_ p: Project, _ format: InterchangeFormat, to url: URL, base: URL, args: Args, options: InterchangeOptions? = nil) async throws -> [String] {
        var lines: [String] = []
        let o: InterchangeOptions
        if let options { o = options } else { o = try await interchangeOptions(p, base: base, args: args, report: &lines) }
        let made = try p.interchange(format, options: o)
        try made.data.write(to: url)
        let notesURL = URL(fileURLWithPath: url.path + ".notes.txt")
        try made.notesText(project: p.name, format: format).write(to: notesURL, atomically: true, encoding: .utf8)
        lines.append("Interchange: \(url.lastPathComponent) (\(format.title)); " + (made.notes.isEmpty ? "carries everything." : "\(made.notes.count) thing(s) it can't carry, in \(notesURL.lastPathComponent):"))
        lines += made.notes.prefix(15).map { "  - " + $0 }
        if made.notes.count > 15 { lines.append("  … \(made.notes.count - 15) more in \(notesURL.lastPathComponent)") }
        return lines
    }

    enum Container: String { case mp4, mov, mxf }

    /// What ffprobe reads back from a DNxHR or XDCAM export.
    static func describeFFmpegExport(_ url: URL, preset: ExportPreset, took: Seconds) async throws -> String {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        let mb = String(format: "%.1f", Double(size) / 1_048_576)
        guard let ffprobe = FFmpeg.tools()?.ffprobe else { return "Exported \(url.path) (\(preset.title), \(mb) MB); ffprobe isn't installed to check it" }
        let info = try await FFmpeg.probe(url, ffprobe: ffprobe)
        let mbps = info.duration > 0 ? Double(size) * 8 / info.duration / 1_000_000 : 0
        var lines = ["Exported \(url.path)"]
        if let v = info.video {
            let wrapper = info.formatName.lowercased() == "mxf" ? "MXF OP1a" : "QuickTime"
            lines.append("\(v.width)×\(v.height) \(Describe.fmtFps((v.frameRate * 1000).rounded() / 1000))fps, \(fmt2(info.duration))s, \(mb) MB (\(fmt1(mbps)) Mb/s), \(preset.title): \(v.codec) \(v.profile ?? "") \(v.pixelFormat ?? "") in \(wrapper), took \(fmt1(took))s")
        }
        let a = info.audio
        if let first = a.first {
            lines.append("Audio: \(info.audioChannels) channel\(info.audioChannels == 1 ? "" : "s") in \(a.count) track\(a.count == 1 ? "" : "s"), \(first.codec) \(first.sampleRate / 1000) kHz \(first.bitsPerSample)-bit")
        } else {
            lines.append("No audio")
        }
        lines.append(info.timecode.map { "Timecode starts at \($0)" } ?? "No timecode")
        return lines.joined(separator: "\n")
    }

    /// The `leader` argument: true, false, or {bars, slate, black, pop, version}.
    func leaderSpec(_ j: JSON?) throws -> Leader? {
        guard let j, !j.isNull else { return nil }
        if let b = j.bool { return b ? Leader() : nil }
        guard j.object != nil else { throw EditError("leader is true or {bars, slate, black, pop, version}") }
        let a = Args(j)
        func seconds(_ k: String, _ d: Int) throws -> Int {
            guard let v = a.optDouble(k) else { return d }
            guard v >= 0, v <= 120, v.rounded() == v else { throw EditError("leader.\(k) is whole seconds from 0 to 120") }
            return Int(v)
        }
        let l = Leader(barsSeconds: try seconds("bars", 10), slateSeconds: try seconds("slate", 10), blackSeconds: try seconds("black", 10), pop: a.bool("pop", default: true))
        guard l.totalSeconds > 0 else { return nil }
        return l
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
                try checkArguments(tool, op["args"], schema: t.schema)
                installResolvers(try? session.project())
                let r = try await t.run(Args(op["args"] ?? [:]))
                if r.isError { throw EditError("\(name), op \(j + 1) (\(tool)): \(r.plainText)") }
            }
            o["ops"] = nil
            o["name"] = nil
            if o["path"] == nil {
                let p = try session.project()
                let ext = (o["preset"]?.string ?? base.optString("preset")).flatMap(ExportPreset.init(rawValue:))?.fileExtension ?? o["container"]?.string ?? base.optString("container") ?? "mp4"
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
            let conform = try await Delivery.audio(try await session.timeline(for: p), range: range, to: url, format: format, layout: layout)
            return .text("Wrote \(url.path) (\(format.rawValue), \((layout ?? p.master.layout).title)), took \(fmt1(Date().timeIntervalSince(started)))s" + (conform.map { "\n" + $0.summary } ?? ""))
        case "stems":
            return try await deliverStems(args, project: p, bundle: b, range: range, name: stem)
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

extension Toolbox {
    /// Writes the subtitle sidecars an export asks for; returns report lines.
    func writeSubtitleSidecars(_ p: Project, _ args: Args, transcripts: [String: Transcript], range: TimeRange?, base: URL, bundle b: ProjectBundle, offset: Seconds = 0) throws -> [String] {
        let subs = args.optString("subtitles") ?? "sidecar"
        let formats = TimedTextFormat(rawValue: subs).map { [$0.rawValue] } ?? args.strings("subtitle_formats") ?? ["srt", "vtt"]
        var options = TimedTextOptions()
        if let pos = args.optString("subtitle_position") { options.position = pos }
        options.speakerColors = args.bool("subtitle_speakers", default: false)
        var analyses: [String: SpeakerAnalysis] = [:]
        let speaker: (String) -> String? = { anchor in
            guard let (media, word) = Project.parseWordAnchor(anchor) else { return nil }
            if analyses[media] == nil { analyses[media] = b.analysis(SpeakerAnalysis.self, media, "speakers") }
            guard let a = analyses[media], a.wordSpeakers.indices.contains(word), let s = a.wordSpeakers[word] else { return nil }
            return media + " " + s
        }
        var files: [String] = []
        var notes: [String] = []
        for f in formats {
            switch f {
            case "srt", "vtt":
                try p.subtitles(f == "srt" ? .srt : .vtt, transcripts: transcripts, range: range, offset: offset).write(to: base.appendingPathExtension(f), atomically: true, encoding: .utf8)
                files.append(base.lastPathComponent + "." + f)
            default:
                guard let format = TimedTextFormat(rawValue: f) else { throw EditError("subtitle_formats are srt, vtt, \(TimedTextFormat.allCases.map(\.rawValue).joined(separator: ", "))") }
                let xml = p.timedText(format, transcripts: transcripts, range: range, options: options, speaker: speaker)
                let problems = Project.timedTextProblems(xml, format: format)
                if !problems.isEmpty { notes.append("\(f) check: " + problems.prefix(3).joined(separator: "; ")) }
                try xml.write(to: base.appendingPathExtension(format.fileSuffix), atomically: true, encoding: .utf8)
                files.append(base.lastPathComponent + "." + format.fileSuffix)
            }
        }
        let count = p.subtitleCues(transcripts: transcripts, range: range).count
        return ["Subtitles: " + files.joined(separator: ", ") + " (\(count) cues)"] + notes
    }
}
