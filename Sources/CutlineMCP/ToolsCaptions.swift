import CutlineCore
import CutlineEngine
import Foundation

extension Toolbox {
    /// "ja: 18 subtitles re-timed to 4 characters/s (lines of 13 full-width); 2 still read too fast: #3 at 10.20s …".
    static func readingReport(_ p: Project, _ lang: String, transcripts: [String: Transcript]) -> String {
        let r = p.readingSpeedProblems(language: lang, transcripts: transcripts)
        let rules = "\(fmt1(r.rules.charsPerSecond)) characters/s, lines of \(r.rules.maxCharsPerLine)\(r.rules.wide ? " full-width" : "")"
        guard !r.tooFast.isEmpty else { return "\(r.cues) subtitles re-timed to \(rules); all read in time." }
        let worst = r.tooFast.prefix(4).map { c in
            "\(fmt2(c.start))s (\(fmt1(Double(Project.readChars(c)) / max(0.001, c.end - c.start))) chars/s)"
        }
        return "\(r.cues) subtitles re-timed to \(rules); \(r.tooFast.count) still read too fast: " + worst.joined(separator: ", ") + (r.tooFast.count > 4 ? ", …" : "") + ". Shorten them (captions_translate cues) or give them more time."
    }

    func registerCaptionTools() {
        add(Tool(name: "captions_list", description: "List the caption cues on the timeline with their times, text (uncertain words marked [word?]) and the source words they cover (\"<media>.wN\"), which tracks are captioned, and where two people talk over each other. Burned-in captions, subtitles (SRT/VTT, embedded) and closed captions share these cues; a cue with more words than the caption style's max_words_per_line × max_lines shows burned-in as consecutive pages (noted per cue). Use the word anchors with caption_edit.", schema: Schema.object([
            "start": Schema.time("Only from this timeline time"),
            "end": Schema.time("Only until this timeline time"),
            "language": Schema.string("Also show each cue's translation in this language (captions_translate)"),
        ])) { [unowned self] args in
            let b = try session.requireBundle()
            let p = try session.project()
            let transcripts = b.transcripts(for: p)
            let lo = try args.optTime("start") ?? 0, hi = try args.optTime("end") ?? .infinity
            let all = p.captionCues(transcripts: transcripts)
            let cues = all.filter { $0.end > lo && $0.start < hi }
            let shownLanguage = args.optString("language").map(Project.languageTag)
            let translated = shownLanguage.map { p.cueTranslations($0, cues: all).texts } ?? []
            let pages = p.captionSegments(transcripts: transcripts)
            let ids = p.captions.trackIds.isEmpty ? p.captionTrackIds : p.captions.trackIds
            let names = ids.compactMap { id in p.tracks.first { $0.id == id }.map { "\($0.name) (\(id))" } }
            var lines = ["Captioned tracks: " + (names.isEmpty ? "none" : names.joined(separator: ", ")) + (p.captions.trackIds.isEmpty ? " — dialogue by default; set track_ids in captions_set or a track's role to change" : "")]
            if !p.captions.enabled { lines.append("Captions are off on the picture (captions_set); subtitles and closed captions on export use these cues too.") }
            var unsure = 0
            func marked(_ w: CaptionWord) -> String {
                guard w.lastAnchor == nil, let (m, n) = w.anchor.flatMap(Project.parseWordAnchor), let tw = transcripts[m]?.words, tw.indices.contains(n), tw[n].isLowConfidence, Vocabulary.tokens(w.text) == Vocabulary.tokens(tw[n].text) else { return w.text }
                unsure += 1
                return "[\(w.text)?]"
            }
            for c in cues {
                let first = c.words.first?.anchor ?? "?", last = c.words.last?.endAnchor ?? "?"
                let shown = pages.filter { $0.start >= c.start - 1e-6 && $0.start < c.end - 1e-6 }.count
                lines.append("#\(c.id) [\(fmt2(c.start))–\(fmt2(c.end))] \(c.words.map(marked).joined(separator: " "))   (\(first)…\(last))" + (shown > 1 ? " — burned in as \(shown) pages" : ""))
                if let lang = shownLanguage { lines.append("    \(lang): " + ((translated.indices.contains(c.id) ? translated[c.id] : nil) ?? "(untranslated)")) }
            }
            for lang in p.captions.translations.keys.sorted() {
                let (texts, stale) = p.cueTranslations(lang, cues: all)
                let missing = texts.indices.filter { texts[$0] == nil }
                lines.append("Translation \(lang): \(all.count - missing.count)/\(all.count) cues" + (missing.isEmpty ? "" : ", untranslated #" + missing.prefix(8).map(String.init).joined(separator: ", #") + (missing.count > 8 ? "…" : "")) + (stale > 0 ? ", \(stale) no longer match a cue" : "") + (p.captions.language == lang ? " (burned in)" : ""))
            }
            if unsure > 0 { lines.append("\(unsure) word(s) the recognizer was unsure of are marked [word?]; fix with caption_edit or transcript_edit.") }
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

        add(Tool(name: "captions_translate", description: "Translate the caption cues into other languages for subtitles. With only language (or languages: [..] for several at once), Apple's on-device Translation framework translates every cue in context (runs of consecutive cues as one document, so pronouns and tu/vous-style register stay consistent; register formal|informal picks one) (each language must be installed in System Settings › General › Language & Region › Translation Languages; a server can't download one); with several languages, one that can't be translated is reported and the rest are stored. cues [{id, text}] stores your own translation per cue (ids from captions_list), and file imports an .srt or .vtt, matching its cues to these by time; both take one language. Translations are keyed by each cue's source words, so they follow later edits; subtitles are rewrapped to each language's line limits and re-timed to its reading speed (into the pauses around a cue and spare time of its neighbours), and the result lists cues still too fast to read. Export them with export subtitle_languages; captions_set language burns one in; captions_list language shows them. clear:true removes the language(s).", schema: Schema.object([
            "language": Schema.string("Target language tag, e.g. fr, de, pt-BR"),
            "languages": Schema.strings("Several target languages translated in one call, e.g. [\"fr\", \"de\", \"ja\"]"),
            "cues": Schema.array(Schema.object(["id": Schema.integer("Cue number from captions_list"), "text": Schema.string("Translated text; \"\" removes")], required: ["id", "text"]), "Your translation of these cues"),
            "file": Schema.string("An .srt or .vtt in that language to import"),
            "clear": Schema.bool("Remove these languages' translations"),
            "condense": Schema.bool("On-device: cues still too fast to read after re-timing are translated again from a condensed source (fillers, hedges and repeats dropped) and the shorter text kept; default true"),
            "register": Schema.string("On-device: how the listener is addressed where the language distinguishes (French tu/vous, German du/Sie); default follows the dialogue, consistently across cues", values: Translator.Register.allCases.map(\.rawValue)),
        ])) { [unowned self] args in
            let b = try session.requireBundle()
            var langs: [String] = []
            for raw in (args.strings("languages") ?? []) + [args.optString("language")].compactMap({ $0 }) {
                let tag = Project.languageTag(raw)
                if !tag.isEmpty, !langs.contains(tag) { langs.append(tag) }
            }
            guard !langs.isEmpty else { throw EditError("Pass language (e.g. \"fr\") or languages: [\"fr\", \"de\"]") }
            let register = try args.optString("register").map { v -> Translator.Register in
                guard let r = Translator.Register(rawValue: v.lowercased()) else { throw EditError("register is formal or informal") }
                return r
            }
            let p0 = try session.project()
            let transcripts = b.transcripts(for: p0)
            let cues = p0.captionCues(transcripts: transcripts)
            let list = langs.joined(separator: ", ")
            if args.bool("clear", default: false) {
                _ = try session.edit("Remove \(list) captions") { p in
                    for lang in langs {
                        p.captions.translations[lang] = nil
                        if p.captions.language == lang { p.captions.language = nil }
                    }
                }
                return .text("Removed the \(list) translation\(langs.count > 1 ? "s" : "").")
            }
            guard !cues.isEmpty else { throw EditError("No caption cues to translate: the timeline has no transcribed speech on its caption tracks") }
            var texts: [String: [Int: String]] = [:]
            var how: [String: String] = [:]
            var failed: [(String, String)] = []
            if let items = args.raw["cues"]?.array {
                guard langs.count == 1 else { throw EditError("cues hold one language's text; pass a single language") }
                var t: [Int: String] = [:]
                for item in items {
                    guard let id = item["id"]?.double.map({ Int($0) }) else { throw EditError("Each cue needs id and text") }
                    t[id] = item["text"]?.string ?? ""
                }
                texts[langs[0]] = t
                how[langs[0]] = "from your text"
            } else if let path = args.optString("file") {
                guard langs.count == 1 else { throw EditError("A subtitle file holds one language; pass a single language") }
                let url = session.resolve(path)
                guard let raw = try? String(contentsOf: url, encoding: .utf8) else { throw EditError("Cannot read \(url.path)") }
                let parsed = Project.parseSubtitles(raw)
                guard !parsed.isEmpty else { throw EditError("\(url.lastPathComponent) has no SRT or VTT cues") }
                texts[langs[0]] = p0.translationTexts(from: parsed, transcripts: transcripts)
                how[langs[0]] = "from \(url.lastPathComponent) (\(parsed.count) cues matched by time)"
            } else {
                let source = p0.spokenLanguage(transcripts: transcripts)
                for lang in langs {
                    do {
                        let out = try await Translator.translate(cues.map(\.text), from: source, to: lang, context: true, register: register)
                        texts[lang] = Dictionary(uniqueKeysWithValues: out.enumerated().map { ($0.offset, $0.element) })
                        how[lang] = "on-device (\(source)→\(lang))"
                    } catch {
                        // A single language keeps its full error; with several, the others still translate.
                        if langs.count == 1 { throw error }
                        failed.append((lang, (error as? EditError)?.message ?? error.localizedDescription))
                    }
                }
            }
            let done = langs.filter { texts[$0] != nil }
            guard !done.isEmpty else { throw EditError(failed.map { "\($0.0): \($0.1)" }.joined(separator: "\n")) }
            var condensed: [String: Int] = [:]
            if args.raw["cues"] == nil, !args.has("file"), args.bool("condense", default: true) {
                let source = p0.spokenLanguage(transcripts: transcripts)
                for lang in done {
                    var q = p0
                    try q.setCaptionTranslations(lang, texts: texts[lang]!, transcripts: transcripts)
                    let sources = q.tooFastCaptionCues(language: lang, transcripts: transcripts).compactMap { i in Project.condensedForSubtitles(cues[i].text).map { (i, $0) } }
                    guard !sources.isEmpty, let out = try? await Translator.translate(sources.map(\.1), from: source, to: lang, register: register) else { continue }
                    let now = q.cueTranslations(lang, cues: cues).texts
                    for ((i, _), t) in zip(sources, out) where !t.isEmpty && t.count < (now[i]?.count ?? 0) {
                        texts[lang]![i] = t
                        condensed[lang, default: 0] += 1
                    }
                }
            }
            var stored: [String: Int] = [:]
            let p = try session.edit("Translate captions to \(done.joined(separator: ", "))") { p in
                for lang in done { stored[lang] = try p.setCaptionTranslations(lang, texts: texts[lang]!, transcripts: transcripts) }
            }
            var lines: [String] = []
            for lang in done {
                let now = p.cueTranslations(lang, cues: cues).texts
                let missing = now.indices.filter { now[$0] == nil }
                lines.append("\(lang): \(stored[lang] ?? 0) cue(s) translated \(how[lang] ?? ""); \(cues.count - missing.count)/\(cues.count) cues have \(lang) text" + (missing.isEmpty ? "." : " (untranslated #" + missing.prefix(10).map(String.init).joined(separator: ", #") + ")."))
                lines.append("  " + Toolbox.readingReport(p, lang, transcripts: transcripts) + (condensed[lang].map { " \($0) cue(s) condensed to read in time." } ?? ""))
                if done.count == 1 {
                    for i in now.indices.prefix(3) { lines.append("#\(i) \(cues[i].text) → \(now[i] ?? "—")") }
                } else if let first = now.first {
                    lines.append("  #0 → \(first ?? "—")")
                }
            }
            for (lang, why) in failed { lines.append("\(lang): not translated: \(why)") }
            let tags = done.map { "\"\($0)\"" }.joined(separator: ", ")
            lines.append("Export with subtitle_languages:[\(tags)]; review with captions_list language:\(done.count == 1 ? tags : "<one of them>").")
            try? session.sendPreview(["action": "rebuild"])
            return .text(lines.joined(separator: "\n"))
        })

        add(Tool(name: "transcript_edit", description: "Correct a media file's transcript and who speaks: replace misheard words (from/to + text), add missed words (insert), set the speaker of words (from/to + speaker; pinned, so re-analysis keeps it and labels the rest of that voice to match) or rename speakers everywhere (rename {\"S1\": \"Anna\"}). Captions, subtitles, timeline_transcript and speaker-based recipes use the corrected transcript. Replacing words with a different number of words shifts later word ids; the result says by how much.", schema: Schema.object([
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
                report.append("w\(r.lowerBound)–w\(r.upperBound) spoken by \(who) (pinned: media_analyze features:[\"speakers\"] keeps it and names the rest of this voice in the scene)")
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
            func moved(_ anchor: String) -> String {
                guard let (m, n) = Project.parseWordAnchor(anchor), m == id, let shift, n > shift.after else { return anchor }
                return "\(m).w\(n + shift.by)"
            }
            let project = try session.project()
            let translationsMove = project.captions.translations.values.joined().contains { moved($0.from) != $0.from || moved($0.to) != $0.to }
            if let shift, translationsMove || project.captions.edits.contains(where: { $0.mediaId == id && $0.toWord > shift.after }) {
                _ = try session.edit("Follow transcript word ids") { p in
                    for i in p.captions.edits.indices where p.captions.edits[i].mediaId == id {
                        if p.captions.edits[i].fromWord > shift.after { p.captions.edits[i].fromWord += shift.by }
                        if p.captions.edits[i].toWord > shift.after { p.captions.edits[i].toWord += shift.by }
                    }
                    for (lang, list) in p.captions.translations {
                        p.captions.translations[lang] = list.map { CaptionTranslation(from: moved($0.from), to: moved($0.to), text: $0.text) }
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
