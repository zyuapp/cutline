import Foundation

extension Project {
    /// "pt_BR" → "pt-BR".
    public static func languageTag(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "_", with: "-")
    }

    /// The language transcripts on the timeline are in, as a tag ("en"), from the first transcript's locale.
    public func spokenLanguage(transcripts: [String: Transcript]) -> String {
        let ids = captionTimelineWords(transcripts: transcripts).map(\.mediaId)
        let locale = ids.first.flatMap { transcripts[$0]?.locale } ?? transcripts.values.first?.locale ?? "en-US"
        return Locale(identifier: locale).language.languageCode?.identifier ?? "en"
    }

    /// Text of each shared cue (`cues`, by index) in `language`, nil where no translation covers it. A translation keyed
    /// to a span of several cues (a cue split after translating) is shared out over them by source length. `stale`
    /// counts translations whose words no longer start and end a cue.
    public func cueTranslations(_ language: String, cues: [CaptionCue]) -> (texts: [String?], stale: Int) {
        var texts = [String?](repeating: nil, count: cues.count)
        guard let list = captions.translations[Self.languageTag(language)], !list.isEmpty else { return (texts, 0) }
        var starts: [String: Int] = [:], ends: [String: Int] = [:]
        for (i, c) in cues.enumerated() {
            if let a = c.words.first?.anchor, starts[a] == nil { starts[a] = i }
            if let z = c.words.last?.endAnchor { ends[z] = i }
        }
        var stale = 0
        for t in list {
            guard let i = starts[t.from], let j = ends[t.to], j >= i else { stale += 1; continue }
            let parts = j == i ? [t.text] : Self.share(t.text, over: cues[i...j].map { $0.text.count })
            for (k, part) in parts.enumerated() where !part.isEmpty {
                texts[i + k] = texts[i + k].map { Self.joinWords([$0, part]) } ?? part
            }
        }
        return (texts, stale)
    }

    /// `text` cut between words (`textUnits`) into `weights.count` consecutive parts sized like the weights.
    static func share(_ text: String, over weights: [Int]) -> [String] {
        let tokens = textUnits(text)
        let total = Double(max(1, weights.reduce(0, +)))
        var out: [String] = []
        var from = 0, acc = 0.0
        for (k, w) in weights.enumerated() {
            acc += Double(w)
            let to = k == weights.count - 1 ? tokens.count : min(tokens.count, Int((Double(tokens.count) * acc / total).rounded()))
            out.append(joinWords(tokens[from..<max(from, to)]))
            from = max(from, to)
        }
        return out
    }

    /// The shared cues in `language` (nil or the spoken language: as spoken). A translated cue keeps its time and
    /// source anchors; its words are the translation's, spread over the cue's spoken span by length. Cues with no
    /// translation keep the spoken text.
    public func captionCues(transcripts: [String: Transcript], language: String?) -> [CaptionCue] {
        let cues = captionCues(transcripts: transcripts)
        guard let language, captions.translations[Self.languageTag(language)] != nil else { return cues }
        let texts = cueTranslations(language, cues: cues).texts
        return zip(cues, texts).map { cue, text in
            guard let text, let first = cue.words.first, let last = cue.words.last else { return cue }
            let tokens = Self.textUnits(text)
            let total = Double(max(1, tokens.reduce(0) { $0 + $1.count + 1 }))
            let span = max(0.05, last.end - first.start)
            var t = first.start
            var c = cue
            c.words = tokens.map { tok in
                let d = span * Double(tok.count + 1) / total
                defer { t += d }
                return CaptionWord(text: tok, start: t, end: t + d, anchor: first.anchor, lastAnchor: last.endAnchor)
            }
            return c
        }
    }

    /// Stores `texts` (by shared cue index) as `language`'s translation of those cues, replacing earlier ones for
    /// the same words. Returns how many were stored.
    @discardableResult
    public mutating func setCaptionTranslations(_ language: String, texts: [Int: String], transcripts: [String: Transcript]) throws -> Int {
        let cues = captionCues(transcripts: transcripts)
        let tag = Self.languageTag(language)
        guard !tag.isEmpty else { throw EditError("Name the language, e.g. \"fr\"") }
        var list = captions.translations[tag] ?? []
        var stored = 0
        for (i, text) in texts.sorted(by: { $0.key < $1.key }) {
            guard cues.indices.contains(i) else { throw EditError("No caption cue \(i); captions_list shows \(cues.count) cues (#0–#\(max(0, cues.count - 1)))") }
            guard let a = cues[i].words.first?.anchor, let z = cues[i].words.last?.endAnchor else { continue }
            let clean = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            list.removeAll { $0.from == a || $0.to == z }
            if !clean.isEmpty { list.append(CaptionTranslation(from: a, to: z, text: clean)) }
            stored += 1
        }
        captions.translations[tag] = list.isEmpty ? nil : list
        return stored
    }

    /// Matches cues read from a subtitle file to the shared cues: each file cue goes to the cue it overlaps most
    /// in time; several file cues on one cue are joined.
    public func translationTexts(from file: [SubtitleCue], transcripts: [String: Transcript]) -> [Int: String] {
        let cues = captionCues(transcripts: transcripts)
        var out: [Int: String] = [:]
        for f in file {
            let best = cues.indices.max { a, b in
                overlap(cues[a], f) < overlap(cues[b], f)
            }
            guard let i = best, overlap(cues[i], f) > 0 else { continue }
            let text = Self.joinWords(f.lines)
            out[i] = out[i].map { $0 + " " + text } ?? text
        }
        return out
    }

    private func overlap(_ c: CaptionCue, _ f: SubtitleCue) -> Int {
        max(0, min(c.endMs, f.endMs) - max(c.startMs, f.startMs))
    }

    /// Cues of an .srt or .vtt document. Cue settings, styling tags and NOTE/STYLE blocks are dropped.
    public static func parseSubtitles(_ text: String) -> [SubtitleCue] {
        let blocks = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n")
        var out: [SubtitleCue] = []
        for block in blocks {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: true).map { String($0).trimmingCharacters(in: .whitespaces) }
            guard let k = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = lines[k].components(separatedBy: "-->")
            guard parts.count == 2, let s = parseCueTime(parts[0]), let e = parseCueTime(parts[1].split(separator: " ").first.map(String.init) ?? "") else { continue }
            let body = lines[(k + 1)...].map { $0.replacingOccurrences(of: #"<[^>]+>|\{\\[^}]*\}"#, with: "", options: .regularExpression) }
                .map { $0.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&amp;", with: "&") }
                .filter { !$0.isEmpty }
            guard !body.isEmpty, e > s else { continue }
            out.append(SubtitleCue(startMs: s, endMs: e, lines: body))
        }
        return out
    }

    /// "00:01:02,345", "01:02.345" → milliseconds.
    static func parseCueTime(_ s: String) -> Int? {
        let t = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let parts = t.split(separator: ":").map(String.init)
        guard (2...3).contains(parts.count), let sec = Double(parts.last!) else { return nil }
        let nums = parts.dropLast().compactMap { Int($0) }
        guard nums.count == parts.count - 1 else { return nil }
        let h = parts.count == 3 ? nums[0] : 0, m = nums.last!
        return Int(((Double(h * 3600 + m * 60) + sec) * 1000).rounded())
    }
}
