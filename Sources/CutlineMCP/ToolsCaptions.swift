import CutlineCore
import Foundation

extension Toolbox {
    func registerCaptionTools() {
        add(Tool(name: "captions_list", description: "List the caption cues on the timeline with their times, text and the source words they cover (\"<media>.wN\"), which tracks are captioned, and where two people talk over each other. Burned-in captions, subtitles (SRT/VTT, embedded) and closed captions share these cues; a cue with more words than the caption style's max_words_per_line × max_lines shows burned-in as consecutive pages (noted per cue). Use the word anchors with caption_edit.", schema: Schema.object([
            "start": Schema.time("Only from this timeline time"),
            "end": Schema.time("Only until this timeline time"),
        ])) { [unowned self] args in
            let b = try session.requireBundle()
            let p = try session.project()
            let transcripts = b.transcripts(for: p)
            let lo = try args.optTime("start") ?? 0, hi = try args.optTime("end") ?? .infinity
            let cues = p.captionCues(transcripts: transcripts).filter { $0.end > lo && $0.start < hi }
            let pages = p.captionSegments(transcripts: transcripts)
            let ids = p.captions.trackIds.isEmpty ? p.captionTrackIds : p.captions.trackIds
            let names = ids.compactMap { id in p.tracks.first { $0.id == id }.map { "\($0.name) (\(id))" } }
            var lines = ["Captioned tracks: " + (names.isEmpty ? "none" : names.joined(separator: ", ")) + (p.captions.trackIds.isEmpty ? " — dialogue by default; set track_ids in captions_set or a track's role to change" : "")]
            if !p.captions.enabled { lines.append("Captions are off on the picture (captions_set); subtitles and closed captions on export use these cues too.") }
            for c in cues {
                let first = c.words.first?.anchor ?? "?", last = c.words.last?.endAnchor ?? "?"
                let shown = pages.filter { $0.start >= c.start - 1e-6 && $0.start < c.end - 1e-6 }.count
                lines.append("#\(c.id) [\(fmt2(c.start))–\(fmt2(c.end))] \(c.text)   (\(first)…\(last))" + (shown > 1 ? " — burned in as \(shown) pages" : ""))
            }
            if cues.isEmpty { lines.append("No caption cues in that range.") }
            let overlaps = p.overlappingSpeech(transcripts: transcripts).filter { $0.end > lo && $0.start < hi }
            if !overlaps.isEmpty {
                lines.append("Overlapping speech (captions interleave both voices): " + overlaps.map { "\(fmt2($0.start))–\(fmt2($0.end))" }.joined(separator: ", ") + ". Hide one voice with caption_edit hidden:true, or restrict track_ids.")
            }
            if !p.captions.edits.isEmpty { lines.append("\(p.captions.edits.count) cue edit(s) applied.") }
            return .text(lines.joined(separator: "\n"))
        })

        addEdit(EditTool(name: "caption_edit", description: "Correct one caption cue: rewrite its text, shift its timing, hide it, start a new cue at a word (break_before), or join it with the next cue (merge). Pick the cue by timeline time (at) or by its source words (from/to, \"<media>.wN\" from captions_list). Edits follow the words through later cuts and apply to burned-in captions, subtitles and closed captions alike. clear:true removes edits on those words. To fix a misheard word everywhere use captions_set replacements; to fix the transcript itself use transcript_edit.", schema: Schema.object([
            "at": Schema.time("Timeline time inside the cue"),
            "from": Schema.string("First word, \"<media>.wN\""),
            "to": Schema.string("Last word, \"<media>.wN\" (default: from)"),
            "text": Schema.string("New text for those words"),
            "start_offset": Schema.number("Seconds added to the cue's start (negative = earlier)"),
            "end_offset": Schema.number("Seconds added to the cue's end"),
            "hidden": Schema.bool("Hide those words from captions"),
            "break_before": Schema.bool("Start a new cue at the first word"),
            "merge": Schema.bool("Join the cue (at at, or holding from) with the next cue"),
            "clear": Schema.bool("Remove edits on those words"),
        ]), label: { a, _ in a.bool("clear", default: false) ? "Clear caption edit" : a.bool("merge", default: false) ? "Merge caption cues" : a.optString("text").map { "Caption text: \($0.prefix(30))" } ?? (a.bool("hidden", default: false) ? "Hide caption" : "Retime caption") }) { [unowned self] p, args in
            let b = try session.requireBundle()
            let transcripts = b.transcripts(for: p)
            let cues = p.captionCues(transcripts: transcripts)
            if args.bool("merge", default: false) {
                let index: Int?
                if let from = args.optString("from") {
                    let (m, w) = try Toolbox.wordAnchor(from)
                    index = cues.firstIndex { c in Project.cueWords(c).map { $0.media == m && $0.first <= w && w <= $0.last } ?? false }
                } else if let at = try args.optTime("at") {
                    index = cues.firstIndex { $0.start <= at && at < $0.end }
                } else {
                    throw EditError("Pass at, or from, for the cue to merge with the next")
                }
                guard let index else { throw EditError("No caption cue there; see captions_list") }
                return try p.mergeCaptionCue(index, transcripts: transcripts)
            }
            var media: String, first: Int, last: Int
            if let from = args.optString("from") {
                (media, first) = try Toolbox.wordAnchor(from)
                let to = try args.optString("to").map(Toolbox.wordAnchor) ?? (media, first)
                guard to.0 == media else { throw EditError("from and to must be words of one media file") }
                (first, last) = (min(first, to.1), max(first, to.1))
            } else if let at = try args.optTime("at") {
                guard let cue = cues.first(where: { $0.start <= at && at < $0.end }) else { throw EditError("No caption cue at \(fmt2(at))s; see captions_list") }
                guard cue.words.contains(where: { $0.anchor != nil }) else { throw EditError("That cue has no source words") }
                guard let span = Project.cueWords(cue) else { throw EditError("That cue mixes two clips' words; use from/to") }
                (media, first, last) = span
            } else {
                throw EditError("Pass at, or from (and to)")
            }
            guard let t = transcripts[media], last < t.words.count else { throw EditError("No word \(media).w\(last)") }
            let clearing = args.bool("clear", default: false)
            p.captions.edits.removeAll { $0.mediaId == media && $0.fromWord <= last && $0.toWord >= first && (clearing || !$0.isMergeOnly) }
            if clearing { return "Cleared caption edits on \(media).w\(first)–w\(last)" }
            let edit = CaptionEdit(mediaId: media, fromWord: first, toWord: last, text: args.optString("text"), startOffset: args.optDouble("start_offset"), endOffset: args.optDouble("end_offset"), hidden: args.optBool("hidden"), breakBefore: args.optBool("break_before"))
            guard edit.text != nil || edit.startOffset != nil || edit.endOffset != nil || edit.hidden != nil || edit.breakBefore != nil else { throw EditError("Pass text, start_offset, end_offset, hidden, break_before or merge") }
            p.captions.edits.append(edit)
            let old = t.words[first...last].map(\.text).joined(separator: " ")
            return "Caption edit on \(media).w\(first)–w\(last) (\"\(old)\")"
        })

        add(Tool(name: "transcript_edit", description: "Correct a media file's transcript and who speaks: replace misheard words (from/to + text), add missed words (insert), set the speaker of words (from/to + speaker) or rename speakers everywhere (rename {\"S1\": \"Anna\"}). Captions, subtitles, timeline_transcript and speaker-based recipes use the corrected transcript. Replacing words with a different number of words shifts later word ids; the result says by how much.", schema: Schema.object([
            "media_id": Schema.string("Media id"),
            "from": Schema.string("First word: \"wN\" or \"<media>.wN\""),
            "to": Schema.string("Last word (default: from)"),
            "text": Schema.string("Replacement text for words from…to"),
            "insert": Schema.object([
                "text": Schema.string("Words to add"),
                "start": Schema.time("Source start"),
                "end": Schema.time("Source end"),
            ], required: ["text", "start", "end"]),
            "speaker": Schema.string("Speaker of words from…to, e.g. S2 or a name"),
            "rename": ["type": "object", "additionalProperties": ["type": "string"], "description": "Rename speakers, e.g. {\"S1\": \"Anna\", \"S3\": \"Anna\"} (merges S3 into Anna)"],
        ], required: ["media_id"])) { [unowned self] args in
            let b = try session.requireBundle()
            let id = try args.string("media_id")
            guard var t = b.transcript(id) else { throw EditError("No transcript for \(id). Call media_analyze.") }
            var speakers = b.analysis(SpeakerAnalysis.self, id, "speakers")
            var report: [String] = []
            var shift: (after: Int, by: Int)?

            var range: ClosedRange<Int>?
            if let from = args.optString("from") {
                let a = try Toolbox.wordIndex(from, media: id)
                let z = try args.optString("to").map { try Toolbox.wordIndex($0, media: id) } ?? a
                guard min(a, z) >= 0, max(a, z) < t.words.count else { throw EditError("Words run w0–w\(t.words.count - 1)") }
                range = min(a, z)...max(a, z)
            }
            if let text = args.optString("text") {
                guard let r = range else { throw EditError("text needs from (and to)") }
                let old = t.words[r].map(\.text).joined(separator: " ")
                let n = try t.replaceWords(r, with: text)
                speakers?.spliceWords(r.lowerBound..<(r.upperBound + 1), count: n)
                report.append("w\(r.lowerBound)–w\(r.upperBound) \"\(old)\" → \"\(text)\"")
                if n != r.count {
                    shift = (r.upperBound, n - r.count)
                    report.append("Words after w\(r.upperBound) moved by \(n - r.count > 0 ? "+" : "")\(n - r.count) (now w\(r.lowerBound)–w\(r.lowerBound + n - 1) for the new words)")
                }
                range = n > 0 ? r.lowerBound...(r.lowerBound + n - 1) : nil
            }
            if let ins = args.raw["insert"]?.object {
                let sub = Args(.object(ins))
                let text = try sub.string("text")
                guard let s = try sub.optTime("start"), let e = try sub.optTime("end"), e > s else { throw EditError("insert needs start < end") }
                let r = t.insertWords(text, start: s, end: e)
                speakers?.spliceWords(r.lowerBound..<r.lowerBound, count: r.count)
                shift = (r.lowerBound - 1, r.count)
                report.append("Inserted \"\(text)\" as w\(r.lowerBound)–w\(r.upperBound - 1); later words moved by +\(r.count)")
                if range == nil { range = r.lowerBound...(r.upperBound - 1) }
            }
            if let who = args.optString("speaker") {
                guard let r = range else { throw EditError("speaker needs from (and to)") }
                var sa = speakers ?? SpeakerAnalysis(mediaId: id, speakers: [], segments: [], wordSpeakers: [], emphasis: [])
                sa.assign(r, to: who, transcript: t)
                speakers = sa
                report.append("w\(r.lowerBound)–w\(r.upperBound) spoken by \(who)")
            }
            if let names = args.raw["rename"]?.object {
                guard var sa = speakers else { throw EditError("No speaker analysis for \(id) to rename") }
                let map = names.compactMapValues(\.string)
                sa.rename(map, transcript: t)
                speakers = sa
                report.append("Renamed " + map.map { "\($0.key) → \($0.value)" }.sorted().joined(separator: ", "))
            }
            guard !report.isEmpty else { throw EditError("Pass text, insert, speaker or rename") }
            try b.saveTranscript(t)
            if let speakers { try b.saveAnalysis(speakers, id, "speakers") }
            if let shift, try session.project().captions.edits.contains(where: { $0.mediaId == id && $0.toWord > shift.after }) {
                _ = try session.edit("Follow transcript word ids") { p in
                    for i in p.captions.edits.indices where p.captions.edits[i].mediaId == id {
                        if p.captions.edits[i].fromWord > shift.after { p.captions.edits[i].fromWord += shift.by }
                        if p.captions.edits[i].toWord > shift.after { p.captions.edits[i].toWord += shift.by }
                    }
                }
            }
            try? session.sendPreview(["action": "rebuild"])
            if let s = speakers, s.speakers.count > 1 { report.append("Speakers: " + s.speakers.joined(separator: ", ")) }
            return .text(report.joined(separator: "\n"))
        })
    }

    /// "<media>.wN" → (media, N).
    static func wordAnchor(_ s: String) throws -> (String, Int) {
        guard let r = s.range(of: ".w", options: .backwards), let n = Int(s[r.upperBound...]) else { throw EditError("\"\(s)\" isn't a word anchor like \"<media>.w12\"") }
        return (String(s[..<r.lowerBound]), n)
    }

    /// "wN", "N" or "<media>.wN" → N.
    static func wordIndex(_ s: String, media: String) throws -> Int {
        if let n = Int(s) { return n }
        if s.hasPrefix("w"), let n = Int(s.dropFirst()) { return n }
        let (m, n) = try wordAnchor(s)
        guard m == media else { throw EditError("\(s) is a word of \(m), not \(media)") }
        return n
    }
}
