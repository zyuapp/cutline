import CoreImage
import CutlineCore
import CutlineEngine
import Foundation

extension Toolbox {
    func registerAudioTools() {
        add(Tool(name: "timeline_measure", description: "Measure the edit as exported. sound: integrated loudness (LUFS), short-term and momentary maximums, loudness range and sample peak for the mix (and each track with tracks:true); targets −14 LUFS for streaming and social, −16 podcasts, −23 broadcast; peaks at or below −1 dBFS. picture: exposure (luma with 2nd/98th percentiles), clipped whites, crushed blacks, saturation and color cast per shot, shot-to-shot mismatches, black stretches, flash frames and photosensitive flashing; letterbox or pillarbox bars and background around fit pictures are left out of picture and scopes numbers. text: each title's and caption's contrast against the picture behind it (WCAG; aim for 4.5:1) and whether it sits inside the title-safe area. compare: shot-to-shot color continuity of the graded picture: each shot's median L/a/b, colorfulness and CIEDE2000 ΔE against a reference shot.", schema: Schema.object([
            "reference": Schema.time("For compare: the reference shot, as a clip id or a timeline time (default the first shot)"),
            "start": Schema.time("From this timeline time or anchor"),
            "end": Schema.time("Until this timeline time or anchor"),
            "what": Schema.strings("Any of sound, picture, text, scopes, compare; default sound, picture and text. scopes renders waveform, RGB parade, vectorscope and histogram of the frame at `at`, with their numbers"),
            "at": Schema.time("Timeline time for scopes, default the middle"),
            "tracks": Schema.bool("Also measure each track's sound on its own, default false"),
            "platform": Schema.string("Check text against this platform's UI-free area", values: Platform.all.map(\.id)),
        ])) { [unowned self] args in
            let p = try session.project()
            guard p.duration > 0 else { throw EditError("The timeline is empty") }
            var range: TimeRange?
            if args.has("start") || args.has("end") { range = TimeRange(try args.optTime("start") ?? 0, try args.optTime("end") ?? p.duration) }
            let what = Set(args.strings("what") ?? ["sound", "picture", "text"])
            var lines: [String] = []
            var sheet: Data?
            if what.contains("scopes") {
                let (text, image) = try await measureScopes(p, at: try args.optTime("at") ?? p.duration / 2)
                lines += text
                sheet = image
            }
            if what.contains("sound") { lines += try await measureSound(p, range: range, tracks: args.bool("tracks", default: false)) }
            if what.contains("picture") { lines += try await measurePicture(p, range: range) }
            if what.contains("text") { lines += try await measureText(p, range: range, platform: args.optString("platform").flatMap(Platform.named)) }
            if what.contains("compare") {
                let ref = args.optString("reference").flatMap { p.clip($0) == nil ? nil : $0 }
                var at: Seconds?
                if ref == nil, args.has("reference") {
                    do { at = try args.optTime("reference") } catch { throw EditError("reference is a clip id or a timeline time; there is no clip \(args.optString("reference") ?? "")") }
                }
                lines += try await measureCompare(p, reference: ref, referenceTime: at, range: range)
            }
            guard !lines.isEmpty else { throw EditError("what is any of sound, picture, text, scopes, compare") }
            var r = ToolResult.text(lines.joined(separator: "\n"))
            if let sheet { r.addImage(sheet) }
            return r
        })

        add(Tool(name: "recipe", description: Toolbox.recipeDescription, schema: Schema.object([
            "name": Schema.string("Recipe", values: Toolbox.recipeNames),
            "args": ["type": "object", "description": "The recipe's arguments; catalog recipe=<name> lists them"],
            "dry_run": Schema.bool("Report what would change without applying it"),
            "wait": Schema.number("Seconds to wait for analysis the recipe reads that is still running (up to 600); default 0 runs now and warns what's missing"),
        ], required: ["name"])) { [unowned self] args in
            let needs = recipeNeeds(try args.string("name"), Args(args.raw["args"]), try session.project())
            let warnings = try await analysisWarnings(needs, wait: args.optDouble("wait") ?? 0)
            var result = try await runRecipe(args)
            if !warnings.isEmpty { result.addText(warnings.joined(separator: "\n")) }
            return result
        })
        registerBusTools()
    }

    func runRecipe(_ args: Args) async throws -> ToolResult {
        let a = recipeArgs(args)
        let dry = args.bool("dry_run", default: false)
        switch try args.string("name") {
        case "duck": return try runEdit("Duck music under speech", dry: dry) { p in try self.duck(&p, a) }
        case "split_edit":
            let edit = try a.string("edit")
            let parts = edit.split(separator: "|").map(String.init)
            guard parts.count == 2 else { throw EditError("edit is \"clip_a|clip_b\"") }
            let requested = try a.double("offset")
            return try runEdit(requested >= 0 ? "J cut into \(Toolbox.clipName(parts[1], try session.project()))" : "L cut out of \(Toolbox.clipName(parts[0], try session.project()))", dry: dry) { p in
                let offset = try p.splitEdit(left: parts[0], right: parts[1], offset: requested, subframe: a.bool("subframe", default: false))
                let note = p.snapNote(requested, offset)
                return offset >= 0
                    ? "\(parts[1])'s sound now starts \(fmt(offset))s before its picture, under the end of \(parts[0])\(note)."
                    : "\(parts[0])'s sound now continues \(fmt(-offset))s over the start of \(parts[1])\(note)."
            }
        case "loudness_normalize":
            if a.bool("off", default: false) {
                return try runEdit("Clear the loudness target", dry: dry) { p in
                    let had = p.master.targetSummary
                    p.master.loudnessTarget = nil
                    p.master.truePeakCeiling = nil
                    return had.map { "Cleared the master loudness target (\($0)); export delivers the mix as it is." } ?? "There was no loudness target."
                }
            }
            let target = a.optDouble("target_lufs") ?? -14
            // −1.5 leaves room for lossy encoders, which overshoot the limiter by a few tenths of a dB.
            let ceiling = a.optDouble("ceiling_db") ?? -1.5
            let limit = a.bool("limit", default: true)
            let persist = a.bool("persist", default: true)
            guard (-60 ... -5).contains(target), (-20...0).contains(ceiling) else { throw EditError("target_lufs is −60…−5 and ceiling_db −20…0") }
            let original = try session.project()
            var p = original
            let first = try await LoudnessMeter.measure(try await session.timeline(for: p))
            guard first.integrated.isFinite else { throw EditError("The mix is silent") }
            // Gain toward the target, limit peaks, re-measure: limiting costs a little loudness, so repeat.
            var report = first
            for _ in 0..<3 {
                p.master.gainDb = min(24, max(-40, p.master.gainDb + (target - report.integrated)))
                if limit {
                    p.master.effects.removeAll { $0.id == "loudness_limiter" }
                    p.master.effects.append(Effect(id: "loudness_limiter", type: "audio.limiter", params: ["ceiling": .number(ceiling), "release_ms": .number(20)]))
                }
                report = try await LoudnessMeter.measure(try await session.timeline(for: p))
                if abs(report.integrated - target) < 0.3 { break }
            }
            var note = "Mix was \(fmt1(first.integrated)) LUFS with peaks at \(fmt1(first.peakDb)) dBFS. Now \(fmt1(report.integrated)) LUFS, peaks \(fmt1(report.peakDb)) dBFS (master gain \(fmt1(p.master.gainDb)) dB" + (limit ? ", master limiter at \(fmt1(ceiling)) dBFS)." : ").")
            if !limit && report.peakDb > ceiling { note += " Peaks exceed \(fmt1(ceiling)) dBFS; run again with limit:true or lower the target." }
            if persist {
                p.master.loudnessTarget = target
                p.master.truePeakCeiling = ceiling == MasterAudio.defaultCeiling ? nil : ceiling
                note += " Kept as the master loudness target: every export and audio mix is measured and conformed to \(fmt1(target)) LUFS, true peak ≤ \(fmt1(ceiling)) dBTP, even after later mix changes (persist:false for a one-off gain, off:true to clear)."
            }
            session.measuredMix[try session.stems().masterKey(for: p)] = report
            let final = p
            return try runEdit("Normalize loudness to \(fmt1(target)) LUFS", dry: dry) { proj in
                proj.master = final.master
                return note
            }
        case "remove_object":
            return try await removeObject(a, dry: dry)
        case "dme_buses":
            return try dmeBuses(a, dry: dry)
        default:
            return try await moreRecipes(try args.string("name"), a, dry: dry)
        }
    }

    func measureSound(_ p: Project, range: TimeRange?, tracks: Bool) async throws -> [String] {
        let mix = try await LoudnessMeter.measure(try await session.timeline(for: p), range: range)
        var lines = ["Sound mix: " + mix.summary + (p.master.gainDb != 0 ? " (master gain \(fmt1(p.master.gainDb)) dB)" : "")]
        if range == nil { session.measuredMix[try session.stems().masterKey(for: p)] = mix }
        if let target = p.master.targetSummary, let drift = p.master.drift(integrated: mix.integrated, truePeak: mix.truePeakDb) {
            lines.append("  Loudness target \(target): " + drift + (range == nil ? "" : " (measured over the range; export measures what it delivers)"))
        }
        if tracks {
            for track in p.tracks where track.clips.contains(where: { $0.kind == .media && ($0.mediaId.flatMap { p.mediaAsset($0) }?.hasAudio ?? false) }) && !track.muted {
                var solo = p
                for i in solo.tracks.indices where solo.tracks[i].id != track.id { solo.tracks[i].muted = true }
                let r = try await LoudnessMeter.measure(try await session.timeline(for: solo), range: range)
                lines.append("  \(track.id) \"\(track.name)\": " + r.summary)
            }
        }
        if mix.truePeakDb > -0.9 { lines.append("  Warning: true peak reaches \(fmt1(mix.truePeakDb)) dBTP; add audio.limiter (ceiling −1) to the loudest track or the master, or lower the gain.") }
        return lines
    }

    func measureScopes(_ p: Project, at t: Seconds) async throws -> ([String], Data?) {
        let built = try await session.timeline(for: p)
        guard let frame = try await Frames.timeline(built, times: [t], maxSize: CGSize(width: 1280, height: 1280)).first else { return (["No frame at \(fmt2(t))"], nil) }
        let image = CIImage(cgImage: frame.image)
        let ctx = CIContext()
        let space = p.canvas.colorSpace
        var cells: [LabeledFrame] = [LabeledFrame(time: t, label: "Frame " + Frames.timecode(t), image: frame.image)]
        for (kind, name) in [(Scopes.Kind.waveform, "Waveform"), (.parade, "RGB parade"), (.vectorscope, "Vectorscope"), (.histogram, "Histogram")] {
            let size = CGSize(width: 768, height: 432)
            if let img = Scopes.render(image, kind: kind, size: size, context: ctx, space: space) { cells.append(LabeledFrame(time: t, label: name, image: img)) }
        }
        var lines = ["Scopes at \(fmt2(t))s (code values 0–1):"]
        if let s = Scopes.stats(image, context: ctx, space: space, background: p.canvas.background) {
            func ch(_ c: Scopes.ChannelStats) -> String { "\(fmt2(c.low))–\(fmt2(c.high)) median \(fmt2(c.median))" }
            if s.picture < 0.98 { lines.append("  Numbers cover the picture only (\(Int((s.picture * 100).rounded()))% of the frame); letterbox, pillarbox or background bars are left out") }
            lines.append("  Luma \(ch(s.parade.luma)); R \(ch(s.parade.red)); G \(ch(s.parade.green)); B \(ch(s.parade.blue))")
            lines.append("  Clipped \(fmt1(s.clipped * 100))%, crushed \(fmt1(s.crushed * 100))%")
            let v = s.vectorscope
            lines.append("  Vectorscope: hue \(Int(v.hue))°, centroid saturation \(fmt2(v.saturation)), average \(fmt2(v.meanSaturation))" + (v.skinToneOffset.map { ", \(fmt1($0))° off the skin-tone line" } ?? ""))
            let spread = [s.parade.red.median, s.parade.green.median, s.parade.blue.median]
            if (spread.max()! - spread.min()!) > 0.06 { lines.append("  Channel medians differ by \(fmt2(spread.max()! - spread.min()!)): a color cast; balance with color.adjust temperature/tint or color.grade") }
        }
        return (lines, Frames.contactSheet(cells, columns: 2, cellWidth: 520))
    }

    func measurePicture(_ p: Project, range: TimeRange?) async throws -> [String] {
        let scale = min(1, 320 / Double(max(p.canvas.width, p.canvas.height)))
        let built = try await session.timeline(for: p, renderScale: scale)
        let r = try await PictureMeter.measure(built, range: range)
        guard !r.frames.isEmpty else { return ["Picture: no frames in range"] }
        func summary(_ fs: ArraySlice<FrameStats>) -> String {
            let n = Double(fs.count)
            let luma = fs.map(\.luma).reduce(0, +) / n, lo = fs.map(\.p2).reduce(0, +) / n, hi = fs.map(\.p98).reduce(0, +) / n
            let clip = fs.map(\.clipped).reduce(0, +) / n, crush = fs.map(\.crushed).reduce(0, +) / n, sat = fs.map(\.saturation).reduce(0, +) / n
            let cb = fs.map(\.cb).reduce(0, +) / n, cr = fs.map(\.cr).reduce(0, +) / n
            var s = "luma \(fmt2(luma)) (\(fmt2(lo))–\(fmt2(hi))), sat \(fmt2(sat))"
            if clip > 0.005 { s += ", clipped whites \(fmt1(clip * 100))%" }
            if crush > 0.02 { s += ", crushed blacks \(fmt1(crush * 100))%" }
            let cast = Toolbox.castName(cb: cb, cr: cr)
            if !cast.isEmpty { s += ", cast \(cast)" }
            let picture = fs.map(\.picture).reduce(0, +) / n
            if picture < 0.98 { s += " (picture \(Int((picture * 100).rounded()))% of frame, bars excluded)" }
            return s
        }
        var lines = ["Picture (\(r.frames.count) frames): " + summary(r.frames[...])]
        // Shots: spans between cuts on the visible video tracks.
        var cuts = Set<Double>([0, p.duration])
        for t in p.tracks where t.kind == .video && !t.hidden { for c in t.clips where c.kind == .media || c.kind == .solid { cuts.insert(c.start); cuts.insert(c.end) } }
        let bounds = cuts.sorted()
        var previous: (luma: Double, cb: Double, cr: Double, label: String)?
        for (a, z) in zip(bounds, bounds.dropFirst()) where z - a > 0.3 {
            let fs = r.frames.filter { $0.time >= a + 0.05 && $0.time < z - 0.05 }
            guard !fs.isEmpty else { continue }
            // Attribute the shot to the layer showing most of the frame; list smaller layers over it.
            let layers = p.pictureLayers(at: (a + z) / 2).sorted { $0.visible > $1.visible }
            let others = layers.dropFirst().filter { $0.visible >= 0.005 }.map { "\($0.clip.id) \(Int(($0.visible * 100).rounded()))%" }
            let label = "\(fmt2(a))–\(fmt2(z)) \(layers.first?.clip.id ?? "")" + (others.isEmpty ? "" : " (with " + others.joined(separator: ", ") + ")")
            lines.append("  \(label): " + summary(fs[...]))
            let n = Double(fs.count)
            let cur = (luma: fs.map(\.luma).reduce(0, +) / n, cb: fs.map(\.cb).reduce(0, +) / n, cr: fs.map(\.cr).reduce(0, +) / n, label: label)
            if let prev = previous {
                var why: [String] = []
                if abs(cur.luma - prev.luma) > 0.15 { why.append("brightness \(fmt2(prev.luma))→\(fmt2(cur.luma))") }
                if hypot(cur.cb - prev.cb, cur.cr - prev.cr) > 0.035 { why.append("color cast") }
                if !why.isEmpty { lines.append("    mismatch with the shot before: " + why.joined(separator: ", ")) }
            }
            previous = cur
        }
        if !r.black.isEmpty { lines.append("Black: " + r.black.map { "\(fmt2($0.start))–\(fmt2($0.end))" }.joined(separator: ", ")) }
        if !r.flashFrames.isEmpty { lines.append("Flash frames (1–2 frames that jump in brightness): " + r.flashFrames.map { fmt2($0) }.joined(separator: ", ")) }
        if !r.flashes.isEmpty { lines.append("Warning: more than 3 flashes per second at " + r.flashes.map { "\(fmt2($0.start))–\(fmt2($0.end))" }.joined(separator: ", ") + " (photosensitive seizure risk, WCAG 2.3.1)") }
        let short = p.tracks.filter { $0.kind == .video }.flatMap(\.clips).filter { $0.duration < 2.5 / p.canvas.fps }
        if !short.isEmpty { lines.append("Clips shorter than 3 frames: " + short.map(\.id).joined(separator: ", ")) }
        return lines
    }

    static func castName(cb: Double, cr: Double) -> String {
        guard hypot(cb, cr) > 0.02 else { return "" }
        let angle = atan2(cr, cb) * 180 / .pi
        let name: String = switch angle {
        case -22.5..<22.5: "blue"
        case 22.5..<67.5: "magenta"
        case 67.5..<112.5: "red"
        case 112.5..<157.5: "orange"
        case -67.5 ..< -22.5: "cyan"
        case -112.5 ..< -67.5: "green"
        case -157.5 ..< -112.5: "yellow-green"
        default: "yellow"
        }
        return "\(name) \(fmt2(hypot(cb, cr)))"
    }

    func measureText(_ p: Project, range: TimeRange?, platform: Platform? = nil) async throws -> [String] {
        let b = try session.requireBundle()
        let transcripts = b.transcripts(for: p)
        var bare = p
        for i in bare.tracks.indices { bare.tracks[i].clips.removeAll { $0.kind == .text || $0.generatorText(at: min($0.duration * 0.5, max(0.5, $0.duration * 0.3))) != nil } }
        bare.captions.enabled = false
        let built = try await session.timeline(for: bare, renderScale: min(1, 640 / Double(max(p.canvas.width, p.canvas.height))))
        let captions = p.captions.enabled ? p.captionSegments(transcripts: transcripts) : []
        let safe = platform?.safe ?? CGRect(x: 0.05, y: 0.05, width: 0.9, height: 0.9)
        let safeName = platform.map { "\($0.name)'s UI-free area" } ?? "title-safe"
        var checks = try await PictureMeter.checkText(p, captions: captions, safe: safe) { t in
            try await Frames.timeline(built, times: [t], maxSize: CGSize(width: 640, height: 640))[0].image
        }
        if let range { checks = checks.filter { $0.time >= range.start && $0.time < range.end } }
        guard !checks.isEmpty else { return ["Text: no titles or captions"] }
        var lines = ["Text (contrast against the picture behind; WCAG asks 4.5:1, 3:1 for large text):"]
        for c in checks {
            var s = "  \(c.label) at \(fmt2(c.time))s: contrast \(fmt1(c.contrast)):1"
            if c.contrast < 3 { s += " — hard to read; add text.stroke, text.background, a darker/lighter color, or move it" }
            else if c.contrast < 4.5 { s += " — fine for large text only" }
            s += c.safeOverflow > 0.001 ? ", outside \(safeName) by \(fmt1(c.safeOverflow * 100))% of the frame" : ", inside \(safeName)"
            lines.append(s)
        }
        return lines
    }

    /// Applies an edit body as one history entry, or reports it without applying when dry.
    func runEdit(_ label: String, dry: Bool, _ body: (inout Project) throws -> String) throws -> ToolResult {
        let before = try session.project()
        if dry {
            var p = before
            let summary = try body(&p)
            p.pruneTransitions()
            try p.validate()
            return .text("Dry run, nothing changed.\n" + summary + Toolbox.changesText(p, before))
        }
        var summary = ""
        let p = try session.edit(label) { summary = try body(&$0) }
        return .text(summary + Toolbox.changesText(p, before) + newIssues(p, before) + "\n" + footer(p))
    }

    func duck(_ p: inout Project, _ a: Args) throws -> String {
        let b = try session.requireBundle()
        let transcripts = b.transcripts(for: p)
        var musicClips: [String] = []
        var musicTracks: Set<String> = []
        let speechTracks = Set(p.timelineWords(transcripts: transcripts).compactMap { w in p.locateClip(w.clipId).map { p.tracks[$0.track].id } })
        let requested = a.strings("music") ?? p.tracks.filter { $0.kind == .audio && !speechTracks.contains($0.id) && !$0.clips.isEmpty }.map(\.id)
        guard !requested.isEmpty else { throw EditError("No music to duck: pass music with clip or track ids") }
        for id in requested {
            if let i = p.trackIndex(id) {
                musicTracks.insert(id)
                musicClips += p.tracks[i].clips.filter { $0.kind == .media }.map(\.id)
            } else if let loc = p.locateClip(id) {
                musicTracks.insert(p.tracks[loc.track].id)
                musicClips.append(id)
            } else {
                throw EditError("No clip or track \(id)")
            }
        }
        let under = a.strings("under") ?? p.tracks.map(\.id).filter { !musicTracks.contains($0) }
        let speech = p.speechRanges(transcripts: transcripts, trackIds: under)
        guard !speech.isEmpty else { throw EditError("No transcribed speech on \(under.joined(separator: ", ")); run media_analyze on the voice media") }
        let amount = a.optDouble("amount_db") ?? 12
        let dips = try p.duck(clipIds: musicClips, under: speech, amountDb: amount, attack: a.optDouble("attack") ?? 0.3, release: a.optDouble("release") ?? 0.8)
        let spoken = speech.map(\.duration).reduce(0, +)
        return "Ducked \(musicClips.count) music clip(s) by \(fmt1(amount)) dB under \(speech.count) stretches of speech (\(fmt1(spoken))s), \(dips) dips. Check with timeline_measure tracks:true or adjust with param_set audio.volume."
    }
}
