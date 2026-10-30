import CutlineCore
import CutlineEngine
import Foundation

/// Export's master delivery options: audio track layouts, dialogue-gated loudness and the sidecars platforms expect.
extension Toolbox {
    /// audio_tracks: a preset, a list "mix,me,dia@mono", or [{content, layout, name}] (or tokens); else the platform's layout.
    func audioTrackSpecs(_ args: Args, platform: Platform?) throws -> [AudioTrackSpec] {
        guard let raw = args.raw["audio_tracks"], !raw.isNull else { return try platform?.audioTracks.map { try AudioTrackSpec.parse($0) } ?? [] }
        if let s = raw.string { return s.lowercased() == "none" ? [] : try AudioTrackSpec.parse(s) }
        guard let items = raw.array else { throw EditError("audio_tracks is a preset, a list like \"mix,me,dia,mus,fx,amb\", or [{content, layout, name}]") }
        let specs = try items.enumerated().flatMap { i, item -> [AudioTrackSpec] in
            if let s = item.string { return try AudioTrackSpec.parse(s) }
            guard let o = item.object, let content = o["content"]?.string else { throw EditError("audio_tracks[\(i)] is {content, layout, name}, content one of mix, me, dia, mus, fx, amb, bus:<id>, role:<name>, silence, tone") }
            return [AudioTrackSpec(try AudioTrackSpec.parseContent(content), layout: try o["layout"]?.string.map(AudioTrackSpec.parseLayout), name: o["name"]?.string)]
        }
        guard !specs.isEmpty else { throw EditError("audio_tracks is empty") }
        return specs
    }

    /// Timed-text sidecar formats the export writes.
    static func sidecarFormats(_ args: Args, platform: Platform?) -> [String] {
        let subs = args.optString("subtitles") ?? platform?.subtitleFormat ?? "none"
        if TimedTextFormat(rawValue: subs) != nil { return [subs] }
        return subs == "sidecar" || subs == "both" ? args.strings("subtitle_formats") ?? ["srt", "vtt"] : []
    }

    /// Where dialogue plays on the timeline: transcribed speech on dialogue clips, else the dialogue stem's clips.
    func dialogueSpans(_ p: Project) async -> [TimeRange] {
        let inference = await roleInference(p)
        let speech = inference.speechRanges(p)
        return speech.isEmpty ? p.dialogueClipSpans(inference.stemRoles) : speech
    }

    /// Resolves each track's content to the timeline playing it and puts the layout on `options`.
    func applyAudioTracks(_ options: inout ExportOptions, specs: [AudioTrackSpec], project p: Project, args: Args, dialogue: [TimeRange]?) async throws {
        options.loudnessGate = dialogue
        guard !specs.isEmpty else { return }
        let roles = await roleInference(p).stemRoles
        var built: [(Project, BuiltTimeline)] = []
        var jobs: [AudioTracks.Job] = []
        for s in specs {
            guard s.content != .mix, let source = try p.audioTrackSource(s.content, roles: roles, layout: specs) else {
                jobs.append(AudioTracks.Job(s))
                continue
            }
            if let b = built.first(where: { $0.0 == source })?.1 {
                jobs.append(AudioTracks.Job(s, timeline: b))
                continue
            }
            let b = try await session.timeline(for: source, shared: false)
            built.append((source, b))
            jobs.append(AudioTracks.Job(s, timeline: b))
        }
        options.audioTracks = jobs
        options.audioPacking = try args.enumValue("audio_tracks_as", AudioTrackSpec.Packing.self) ?? .tracks
        options.audioTracksReport = AudioTracks.Report()
    }

    /// Report lines for a rendered audio track layout, and its track sheet beside the file.
    func audioTracksSummary(_ options: ExportOptions, url: URL, base: URL) throws -> [String] {
        guard let tracks = options.audioTracksReport?.tracks, !tracks.isEmpty else { return [] }
        let mxf = url.pathExtension.lowercased() == "mxf"
        func level(_ r: AudioTracks.Rendered) -> String {
            guard let l = r.loudness else { return r.spec.content == .tone ? "1 kHz −20 dBFS" : "silent" }
            return l.integrated.isFinite ? "\(fmt1(l.gatedIntegrated)) LUFS\(l.dialogue != nil ? " dialogue-gated" : ""), \(fmt1(l.truePeakDb)) dBTP" : "silent"
        }
        var sheet = ["Channel\tName\tContent\tLayout\tLevel"]
        var parts: [String] = []
        var ch = 1
        for r in tracks {
            let n = r.spec.layout.channelCount
            for (i, name) in r.spec.channelNames.enumerated() { sheet.append("\(ch + i)\t\(name)\t\(r.spec.token)\t\(r.spec.layout.title)\t\(level(r))") }
            parts.append((n == 1 ? "ch\(ch)" : "ch\(ch)-\(ch + n - 1)") + " \(r.spec.name) (\(r.spec.layout.title)) \(level(r))")
            ch += n
        }
        // XDCAM HD422 always carries eight mono channels; the ones the layout leaves free are silent.
        let padded = options.preset == .xdcam_hd422 ? max(0, 9 - ch) : 0
        if padded > 0 {
            for k in ch...8 { sheet.append("\(k)\tsilent\t-\tMono\tsilent") }
            parts.append((padded == 1 ? "ch8" : "ch\(ch)-8") + " silent (XDCAM always carries 8)")
        }
        let sheetURL = base.appendingPathExtension("tracks.txt")
        try sheet.joined(separator: "\n").appending("\n").write(to: sheetURL, atomically: true, encoding: .utf8)
        let packing = mxf ? "\(ch - 1 + padded) mono MXF tracks" : options.audioPacking == .channels && tracks.count > 1 ? "one \(ch - 1)-channel track" : "\(tracks.count) named tracks"
        var lines = ["Audio tracks (\(packing)): " + parts.joined(separator: ", ") + "; channel sheet \(sheetURL.lastPathComponent)"]
        if tracks.contains(where: { $0.spec.content != .mix && $0.spec.content.isProgram }) { lines.append("Stems and M&E are pre-master (no master effects or loudness conform), so they sum to the unprocessed mix.") }
        return lines
    }
}
