import CutlineCore
import CutlineEngine
import Foundation

extension Toolbox {
    /// How long the preview app has to pick up a request before the tool says it isn't there.
    nonisolated(unsafe) static var voiceOverAckTimeout: Double = 4

    func registerVoiceOverTool() {
        add(Tool(name: "voiceover_record", description: "Record voice-over or ADR in the preview app: the human sees a countdown, a level meter, the take number and the script as a teleprompter, hears the program from start − preroll (on headphones; mute_program:true for silence), and the microphone is recorded from start to end (preroll and 0.5 s past end kept as handles) as 48 kHz 24-bit mono WAV in the project (media/recordings). Each take is imported, transcribed and tagged (metadata scene/take, tag \"<id> take N\"); the last take without level problems is placed at start on the track, lined up after input latency is taken out. Other takes stay as alternate media with their source_in. Reports peak/RMS and warns about clipping or a quiet take. Needs the preview app open on this project and microphone access for Cutline. If wait runs out, call again with id to collect.", schema: Schema.object([
            "start": Schema.time("Timeline start of the line"),
            "end": Schema.time("Timeline end of the line, instead of duration"),
            "duration": Schema.number("Length of the line in seconds"),
            "track": Schema.string("Track id, or \"new\"; default the Voice-over track free over the line, made as needed"),
            "countdown": Schema.integer("Seconds counted down before the program rolls, default 3"),
            "preroll": Schema.number("Program seconds played before start, default 2"),
            "mute_program": Schema.bool("Record without program sound, default false"),
            "takes": Schema.integer("Takes recorded back to back, default 1"),
            "script": Schema.string("The line, shown to the human as a teleprompter"),
            "wait": Schema.number("Seconds to wait for the recording; default the takes' length plus 15"),
            "id": Schema.string("Collect a recording that outlasted wait (vo1…) instead of starting one"),
            "analyze": Schema.bool("Transcribe the takes, default true"),
            "test_input": Schema.string("A sound file the app plays as the microphone, for tests without one"),
        ])) { [unowned self] args in
            let b = try session.requireBundle()
            if let id = args.optString("id") {
                let dir = b.recordingsURL.appendingPathComponent(id, isDirectory: true)
                guard let request = VoiceOver.read(VoiceOverRequest.self, from: VoiceOver.requestURL(dir)) else { throw EditError("No recording \(id) in this project") }
                return try await finishVoiceOver(request, dir: dir, args: args, wait: args.optDouble("wait") ?? 30)
            }
            let start = try args.time("start")
            let end: Seconds
            if let e = try args.optTime("end") { end = e } else if let d = args.optDouble("duration") { end = start + d } else { throw EditError("Pass end or duration") }
            guard end > start else { throw EditError("end must be after start") }
            guard end - start <= 600 else { throw EditError("A line is at most 600 s; record longer narration in parts") }
            let takes = args.optInt("takes") ?? 1
            guard (1...20).contains(takes) else { throw EditError("takes is 1…20") }
            let countdown = args.optInt("countdown") ?? 3
            guard (0...10).contains(countdown) else { throw EditError("countdown is 0…10 seconds") }
            let preroll = args.optDouble("preroll") ?? 2
            guard (0...30).contains(preroll) else { throw EditError("preroll is 0…30 seconds") }
            if let track = args.optString("track"), track != "new" {
                guard let t = try session.project().tracks.first(where: { $0.id == track }) else { throw EditError("No track \(track)") }
                guard t.kind == .audio else { throw EditError("\(track) is a video track; record onto an audio track or \"new\"") }
            }
            let test = args.optString("test_input").map { session.resolve($0).path }
            if let test, !FileManager.default.fileExists(atPath: test) { throw EditError("test_input \(test) doesn't exist") }
            try FileManager.default.createDirectory(at: b.recordingsURL, withIntermediateDirectories: true)
            let id = VoiceOver.nextId(in: b.recordingsURL)
            let dir = b.recordingsURL.appendingPathComponent(id, isDirectory: true)
            let request = VoiceOverRequest(id: id, start: start, end: end, countdown: countdown, preroll: preroll, muteProgram: args.bool("mute_program", default: false),
                                           takes: takes, script: args.optString("script"), testInput: test)
            try VoiceOver.write(request, to: VoiceOver.requestURL(dir))
            try session.sendPreview(["action": "record", "request": VoiceOver.requestURL(dir).path])
            let ack = Date().addingTimeInterval(Toolbox.voiceOverAckTimeout)
            while VoiceOver.read(VoiceOverResult.self, from: VoiceOver.resultURL(dir)) == nil {
                guard Date() < ack else {
                    try? FileManager.default.removeItem(at: dir)
                    throw EditError("The Cutline preview app didn't pick up the recording. Open it on this project (preview_seek open:true), then call voiceover_record again.")
                }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            let length = Double(countdown) + (start - request.rollFrom) + (end - start) + request.postroll + 1
            return try await finishVoiceOver(request, dir: dir, args: args, wait: args.optDouble("wait") ?? Double(takes) * length + 15)
        })
    }

    /// Waits for the app's result, then imports, transcribes, tags and places the takes.
    func finishVoiceOver(_ request: VoiceOverRequest, dir: URL, args: Args, wait: Double) async throws -> ToolResult {
        let deadline = Date().addingTimeInterval(wait)
        var result = VoiceOver.read(VoiceOverResult.self, from: VoiceOver.resultURL(dir))
        while !(result?.status.isFinal ?? false), Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
            result = VoiceOver.read(VoiceOverResult.self, from: VoiceOver.resultURL(dir))
        }
        guard let result else { throw EditError("Recording \(request.id) never started; the preview app didn't answer. Open it on this project (preview_seek open:true) and record again.") }
        switch result.status {
        case .recording:
            return .text("Recording \(request.id) is still going (take \(result.currentTake ?? 1) of \(request.takes), \(result.takes.count) done). Call voiceover_record id:\"\(request.id)\" to collect it.")
        case .failed:
            throw EditError(result.error ?? "Recording \(request.id) failed in the preview app.")
        case .cancelled:
            return .text("Recording \(request.id) was stopped before any take was recorded. Nothing was added.")
        case .done:
            break
        }
        let b = try session.requireBundle()
        var lines: [String] = []
        let paths = result.takes.map(\.file)
        let imported = try await importMedia(paths, args: Args(raw: ["analyze": .bool(false)]))
        if imported.isError { throw EditError(imported.plainText) }
        var p = try b.loadProject()
        var ids: [Int: String] = [:]
        for t in result.takes {
            guard let m = p.media.first(where: { $0.path == t.file }) else { throw EditError("Take \(t.take) at \(t.file) didn't import:\n" + imported.plainText) }
            ids[t.take] = m.id
        }
        if args.bool("analyze", default: true) {
            for t in result.takes {
                guard let id = ids[t.take], let m = p.mediaAsset(id), b.transcript(id) == nil else { continue }
                _ = try? await session.analyze(m, features: [.transcript], language: "en-US", explicit: false)
            }
        }
        let keep = VoiceOver.preferredTake(result.takes)!
        let alreadyPlaced = p.tracks.flatMap(\.clips).first { c in ids.values.contains(c.mediaId ?? "") }
        var placedLine: String
        if let alreadyPlaced {
            placedLine = "Already placed as \(alreadyPlaced.id) (\(alreadyPlaced.mediaId ?? "")) at \(fmt(alreadyPlaced.start))."
        } else {
            var placed: (clip: Clip, track: String)?
            p = try session.edit("Record voice-over \(request.id) (\(result.takes.count) take\(result.takes.count == 1 ? "" : "s"))") { p in
                placed = try p.placeVoiceOver(keep, mediaId: ids[keep.take]!, track: args.optString("track"), sessionId: request.id)
                for t in result.takes { p.tagVoiceOver(t, mediaId: ids[t.take]!, sessionId: request.id, placed: t.take == keep.take) }
            }
            let c = placed!.clip
            placedLine = "Placed take \(keep.take) as \(c.id) on \(placed!.track) at \(fmt(c.start))–\(fmt(c.end)) (source_in \(String(format: "%.4f", c.sourceIn)))."
        }
        try? session.sendPreview(["action": "rebuild"])
        lines.append("Recorded \(request.id): \(result.takes.count) take(s) of \(fmt(request.start))–\(fmt(request.end)). " + placedLine)
        for t in result.takes {
            let id = ids[t.take]!
            var line = "  take \(t.take) → \(id): \(fmt2(t.duration))s line, \(fmt2(t.fileDuration))s file (\(fmt2(t.sourceIn))s head), peak \(String(format: "%.1f", t.levels.peakDB)) dBFS, RMS \(String(format: "%.1f", t.levels.rmsDB)) dBFS"
            line += ", \(t.device), input latency \(Int((t.inputLatency * 1000).rounded())) ms compensated"
            if let said = b.transcript(id)?.words.filter({ $0.end > t.sourceIn && $0.start < t.sourceIn + t.duration }).map(\.text).joined(separator: " "), !said.isEmpty {
                line += "; said “\(Toolbox.excerpt(said, 120))”"
            }
            if t.take != keep.take { line += "; alternate: clip_add media_id:\"\(id)\" start:\(fmt(t.start)) source_in:\(String(format: "%.4f", t.sourceIn)) duration:\(fmt(t.duration))" }
            lines.append(line)
            lines += t.levels.warnings.map { "    Warning: \($0)" }
        }
        if let script = request.script { lines.append("Script: “\(Toolbox.excerpt(script, 160))”") }
        lines.append(footer(p))
        return .text(lines.joined(separator: "\n"))
    }
}
