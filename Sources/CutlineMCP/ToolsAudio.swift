import CutlineCore
import CutlineEngine
import Foundation

extension Toolbox {
    func registerAudioTools() {
        add(Tool(name: "timeline_measure", description: "Measure the edit's sound as exported, with audio effects applied: integrated loudness (LUFS), short-term and momentary maximums, loudness range and sample peak, for the whole mix and optionally each track. Targets: −14 LUFS for streaming and social, −16 for podcasts, −23 for broadcast (EBU R128); keep peaks at or below −1 dBFS.", schema: Schema.object([
            "start": Schema.time("From this timeline time or anchor"),
            "end": Schema.time("Until this timeline time or anchor"),
            "tracks": Schema.bool("Also measure each track on its own, default false"),
        ])) { [unowned self] args in
            let p = try session.project()
            guard p.duration > 0 else { throw EditError("The timeline is empty") }
            var range: TimeRange?
            if args.has("start") || args.has("end") { range = TimeRange(try args.optTime("start") ?? 0, try args.optTime("end") ?? p.duration) }
            let mix = try await LoudnessMeter.measure(try await session.timeline(for: p), range: range)
            var lines = ["Mix: " + mix.summary + (p.master.gainDb != 0 ? " (master gain \(fmt1(p.master.gainDb)) dB)" : "")]
            if args.bool("tracks", default: false) {
                for track in p.tracks where track.clips.contains(where: { $0.kind == .media }) && !track.muted {
                    var solo = p
                    for i in solo.tracks.indices where solo.tracks[i].id != track.id { solo.tracks[i].muted = true }
                    let r = try await LoudnessMeter.measure(try await session.timeline(for: solo), range: range)
                    lines.append("\(track.id) \"\(track.name)\": " + r.summary)
                }
            }
            if mix.peakDb > -1 { lines.append("Warning: peaks reach \(fmt1(mix.peakDb)) dBFS; add audio.limiter (ceiling −1) to the loudest track or lower the gain.") }
            return .text(lines.joined(separator: "\n"))
        })

        add(Tool(name: "recipe", description: "Common multi-step edits, done in one undoable step. duck: lower music while people speak (writes audio.volume animation from the transcripts). loudness_normalize: measure the mix and set the master gain to hit a loudness target. split_edit: J or L cut between two adjacent clips, so sound leads or trails the picture. Each reports exactly what it changed; dry_run:true previews.", schema: Schema.object([
            "name": Schema.string("Recipe", values: ["duck", "loudness_normalize", "split_edit"]),
            "args": ["type": "object", "description": """
                duck: {music: clip or track ids (default: audio tracks without speech), under: track ids with speech (default: all others), amount_db: 12, attack: 0.3, release: 0.8}. \
                loudness_normalize: {target_lufs: -14, ceiling_db: -1, limit: true (adds or tunes a master limiter so peaks stay under the ceiling)}. \
                split_edit: {edit: "clip_a|clip_b", offset: seconds (+ J cut: clip_b's sound starts early; − L cut: clip_a's sound runs over clip_b)}.
                """],
            "dry_run": Schema.bool("Report what would change without applying it"),
        ], required: ["name"])) { [unowned self] args in
            let a = Args(args.raw["args"])
            let dry = args.bool("dry_run", default: false)
            switch try args.string("name") {
            case "duck": return try runEdit("Duck music under speech", dry: dry) { p in try self.duck(&p, a) }
            case "split_edit":
                let edit = try a.string("edit")
                let parts = edit.split(separator: "|").map(String.init)
                guard parts.count == 2 else { throw EditError("edit is \"clip_a|clip_b\"") }
                let offset = try a.double("offset")
                return try runEdit(offset >= 0 ? "J cut into \(Toolbox.clipName(parts[1], try session.project()))" : "L cut out of \(Toolbox.clipName(parts[0], try session.project()))", dry: dry) { p in
                    try p.splitEdit(left: parts[0], right: parts[1], offset: offset)
                    return offset >= 0
                        ? "\(parts[1])'s sound now starts \(fmt2(offset))s before its picture, under the end of \(parts[0])."
                        : "\(parts[0])'s sound now continues \(fmt2(-offset))s over the start of \(parts[1])."
                }
            case "loudness_normalize":
                let target = a.optDouble("target_lufs") ?? -14
                let ceiling = a.optDouble("ceiling_db") ?? -1
                let limit = a.bool("limit", default: true)
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
                let final = p
                return try runEdit("Normalize loudness to \(fmt1(target)) LUFS", dry: dry) { proj in
                    proj.master = final.master
                    return note
                }
            default:
                throw EditError("Unknown recipe")
            }
        })
    }

    /// Applies an edit body as one history entry, or reports it without applying when dry.
    func runEdit(_ label: String, dry: Bool, _ body: (inout Project) throws -> String) throws -> ToolResult {
        let before = try session.project()
        if dry {
            var p = before
            let summary = try body(&p)
            try p.validate()
            return .text("Dry run, nothing changed.\n" + summary + Toolbox.changesText(p, before))
        }
        var summary = ""
        let p = try session.edit(label) { summary = try body(&$0) }
        return .text(summary + Toolbox.changesText(p, before) + "\n" + footer(p))
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
