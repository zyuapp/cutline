import Foundation

public enum SubtitleFormat: String, CaseIterable, Sendable {
    case srt, vtt
}

/// One subtitle on the timeline, timed in milliseconds.
public struct SubtitleCue: Equatable, Sendable {
    public var startMs: Int
    public var endMs: Int
    public var lines: [String]
    /// The transcript words shown, as "<mediaId>.w<index>".
    public var anchors: [String] = []

    public var start: Seconds { Double(startMs) / 1000 }
    public var end: Seconds { Double(endMs) / 1000 }
    public var text: String { lines.joined(separator: "\n") }
}

/// A caption cue: the words shown together and when. Burned-in captions, subtitles and closed captions all start
/// from these cues (`Project.captionCues`).
public struct CaptionCue: Equatable, Sendable {
    public var id: Int
    public var startMs: Int
    public var endMs: Int
    public var words: [CaptionWord]

    public var start: Seconds { Double(startMs) / 1000 }
    public var end: Seconds { Double(endMs) / 1000 }
    public var text: String { Project.joinWords(words.map(\.text)) }
}

extension Project {
    /// Line width and line count the shared cues are built for (broadcast subtitles).
    public static let cueCharsPerLine = 42
    public static let cueLines = 2
    static let cueMinMs = 1000, cueMaxMs = 7000, cueGapMs = 100, cueLingerMs = 300
    static let cuePause: Seconds = 0.7

    /// The caption cues every output shares. Cues keep to broadcast rules: at most 2 lines of 42 characters,
    /// 1–7 s on screen, at least 0.1 s apart, breaking at sentence ends, clause punctuation and pauses. A sentence's
    /// last word never sits alone when it can join the cue before it (or take a word from it). Speech in Chinese,
    /// Japanese or Korean script keeps to that language's line length (`SubtitleRules`).
    public func captionCues(transcripts: [String: Transcript]) -> [CaptionCue] {
        let words = captionWords(transcripts: transcripts)
        let width = SubtitleRules.forText(words.prefix(40).map(\.text).joined())?.columns ?? Self.cueCharsPerLine
        let groups = Self.cueGroups(words, maxChars: width, maxLines: Self.cueLines)
        return zip(groups, Self.cueTimes(groups, durationMs: Self.ms(duration))).enumerated().map { i, pair in
            CaptionCue(id: i, startMs: pair.1.0, endMs: pair.1.1, words: pair.0)
        }
    }

    /// Subtitles for the words heard on the timeline, with the caption replacements and hidden words applied.
    /// With `range`, only cues inside it, clipped to it and timed from its start.
    /// `offset` delays every cue, e.g. by a leader before the program, so times count from the file's first frame.
    /// `language` picks a translation (`captions.translations`); nil is the spoken language.
    public func subtitles(_ format: SubtitleFormat, transcripts: [String: Transcript], maxCharsPerLine: Int? = nil, maxLines: Int = 2, range: TimeRange? = nil, offset: Seconds = 0, language: String? = nil) -> String {
        let shift = Self.ms(offset)
        let cues = subtitleCues(transcripts: transcripts, maxCharsPerLine: maxCharsPerLine, maxLines: maxLines, range: range, language: language)
            .map { SubtitleCue(startMs: $0.startMs + shift, endMs: $0.endMs + shift, lines: $0.lines) }
        switch format {
        case .srt:
            return cues.enumerated().map { i, c in
                "\(i + 1)\n\(Self.subtitleTime(c.startMs, ",")) --> \(Self.subtitleTime(c.endMs, ","))\n\(c.lines.joined(separator: "\n"))\n"
            }.joined(separator: "\n")
        case .vtt:
            let body = cues.map { c in
                let text = c.lines.map(Self.vttEscape).joined(separator: "\n")
                return "\(Self.subtitleTime(c.startMs, ".")) --> \(Self.subtitleTime(c.endMs, "."))\n\(text)\n"
            }
            return (["WEBVTT\n"] + body).joined(separator: "\n")
        }
    }

    /// The shared `captionCues`, each wrapped to `maxCharsPerLine`. A cue that needs more than `maxLines` lines at that
    /// width is split into the fewest consecutive cues that fit, with their characters evened out; otherwise cue
    /// boundaries and timing are the shared ones. In a translation (`language`) the translated text is wrapped the
    /// same way, a cue too long for its lines is split within its own time (at clause ends where they fit), and cues are
    /// re-timed to the language's reading speed (`retimedForReading`). `maxCharsPerLine` is in columns (a
    /// full-width character takes two); nil uses the language's line length (`SubtitleRules`, 42 for most languages,
    /// 13 full-width characters for Japanese), and Chinese and Japanese lines break between characters by `textUnits`.
    public func subtitleCues(transcripts: [String: Transcript], maxCharsPerLine: Int? = nil, maxLines: Int = 2, range: TimeRange? = nil, language: String? = nil) -> [SubtitleCue] {
        let shared = captionCues(transcripts: transcripts, language: language)
        let translated = language.map { captions.translations[Self.languageTag($0)] != nil } ?? false
        let rules = translated ? SubtitleRules.forLanguage(language!) : SubtitleRules.forText(shared.prefix(20).map(\.text).joined()) ?? .standard
        let width = max(1, maxCharsPerLine ?? rules.columns), rows = max(1, maxLines)
        var cues: [SubtitleCue]
        if translated {
            cues = shared.flatMap { c -> [SubtitleCue] in
                // A cue left untranslated keeps its own script's line length.
                let width = rules.wide && maxCharsPerLine == nil && SubtitleRules.forText(c.text) == nil ? SubtitleRules.standard.columns : width
                let parts = Self.clauseAligned(Self.splitToFit(c.words, width: width, lines: rows), width: width, lines: rows)
                let total = Double(max(1, parts.reduce(0) { $0 + Self.columns(Self.joinWords($1.map(\.text))) }))
                var at = Double(c.startMs)
                return parts.map { g in
                    let d = Double(c.endMs - c.startMs) * Double(Self.columns(Self.joinWords(g.map(\.text)))) / total
                    defer { at += d }
                    return SubtitleCue(startMs: Int(at.rounded()), endMs: Int((at + d).rounded()), lines: Self.balancedLines(g.map(\.text), width: width), anchors: g.compactMap(\.anchor))
                }
            }
            cues = Self.retimedForReading(cues, rules: { rules.wide && SubtitleRules.forText($0.text) == nil ? .standard : rules }, gapMs: max(1, Self.ms(2 * canvas.frameDuration)), durationMs: Self.ms(duration))
        } else if shared.allSatisfy({ Self.fits($0.words, width: width, lines: rows) }) {
            cues = shared.map { SubtitleCue(startMs: $0.startMs, endMs: $0.endMs, lines: Self.balancedLines($0.words.map(\.text), width: width), anchors: $0.words.compactMap(\.anchor)) }
        } else {
            let groups = shared.flatMap { Self.splitToFit($0.words, width: width, lines: rows) }
            cues = zip(groups, Self.cueTimes(groups, durationMs: Self.ms(duration))).map { g, t in
                SubtitleCue(startMs: t.0, endMs: t.1, lines: Self.balancedLines(g.map(\.text), width: width), anchors: g.compactMap(\.anchor))
            }
        }
        guard let range else { return cues }
        let lo = Self.ms(range.start), hi = Self.ms(range.end)
        return cues.compactMap { c in
            let s = max(c.startMs, lo), e = min(c.endMs, hi)
            return e > s ? SubtitleCue(startMs: s - lo, endMs: e - lo, lines: c.lines, anchors: c.anchors) : nil
        }
    }

    /// "<media>.wN" → (media, N).
    public static func parseWordAnchor(_ s: String) -> (media: String, word: Int)? {
        guard let r = s.range(of: ".w", options: .backwards), let n = Int(s[r.upperBound...]) else { return nil }
        return (String(s[..<r.lowerBound]), n)
    }

    /// The source words a cue covers: (media, first word, last word), or nil when it mixes media files.
    public static func cueWords(_ cue: CaptionCue) -> (media: String, first: Int, last: Int)? {
        let refs = cue.words.flatMap { [$0.anchor, $0.endAnchor] }.compactMap { $0.flatMap(parseWordAnchor) }
        guard let m = refs.first?.media, refs.allSatisfy({ $0.media == m }) else { return nil }
        return (m, refs.map(\.word).min()!, refs.map(\.word).max()!)
    }

    /// Joins shared cue `index` with the one after it, by a merge edit on its last word that follows later cuts.
    /// A break_before on the next cue's first word is dropped. Fails when the two together exceed the cue limits.
    @discardableResult
    public mutating func mergeCaptionCue(_ index: Int, transcripts: [String: Transcript]) throws -> String {
        let cues = captionCues(transcripts: transcripts)
        guard cues.indices.contains(index) else { throw EditError("No caption cue \(index)") }
        guard index + 1 < cues.count else { throw EditError("That is the last caption cue; nothing follows it to merge") }
        let cue = cues[index], next = cues[index + 1]
        guard let tail = cue.words.last?.endAnchor.flatMap(Self.parseWordAnchor), let headAnchor = next.words.first?.anchor,
              let head = Self.parseWordAnchor(headAnchor) else { throw EditError("Those cues have no source words") }
        let before = captions
        captions.edits.removeAll { $0.isMergeOnly && $0.mediaId == tail.media && $0.toWord == tail.word }
        captions.edits.append(CaptionEdit(mediaId: tail.media, fromWord: tail.word, toWord: tail.word, mergeNext: true))
        for i in captions.edits.indices.reversed() where captions.edits[i].breakBefore == true && captions.edits[i].mediaId == head.media && captions.edits[i].fromWord == head.word {
            captions.edits[i].breakBefore = nil
            let e = captions.edits[i]
            if e.text == nil, e.startOffset == nil, e.endOffset == nil, e.hidden == nil, e.mergeNext == nil { captions.edits.remove(at: i) }
        }
        let after = captionCues(transcripts: transcripts)
        guard let merged = after.first(where: { c in c.words.contains { $0.anchor == headAnchor } && c.words.contains { $0.endAnchor == cue.words.last?.endAnchor } }) else {
            captions = before
            let text = cue.text + " " + next.text
            throw EditError("Together they'd be \(text.count) characters over \(fmt2(next.words.last!.end - cue.words[0].start))s; a cue holds at most \(Self.cueLines) lines of \(Self.cueCharsPerLine) characters and \(Self.cueMaxMs / 1000) s. Shorten the text (caption_edit text) or move a break (break_before) instead")
        }
        return "Merged \"\(cue.text)\" with \"\(next.text)\": [\(fmt2(merged.start))–\(fmt2(merged.end))] \(merged.text)"
    }

    static func ms(_ t: Seconds) -> Int { Int((t * 1000).rounded()) }

    static func fits(_ ws: [CaptionWord], width: Int, lines: Int) -> Bool {
        wrap(ws.map(\.text), width: width).count <= lines
    }

    /// Words grouped into cues by the broadcast rules (see `captionCues`).
    static func cueGroups(_ words: [CaptionWord], maxChars: Int, maxLines: Int) -> [[CaptionWord]] {
        let maxChars = max(1, maxChars), lineLimit = max(1, maxLines)
        func fits(_ ws: [CaptionWord]) -> Bool { Self.fits(ws, width: maxChars, lines: lineLimit) }
        func span(_ ws: [CaptionWord]) -> Double { (ws.last!.end - ws[0].start) * 1000 }

        var groups: [[CaptionWord]] = []
        var cur: [CaptionWord] = []
        for w in words {
            if let last = cur.last {
                let hard = !fits(cur + [w]) || (w.end - cur[0].start) * 1000 > Double(cueMaxMs)
                let soft = w.start - last.end >= cuePause
                    || endsSentence(last.text)
                    || (endsClause(last.text) && Self.columns(Self.joinWords(cur.map(\.text))) > maxChars)
                if w.breakBefore || (soft && !last.joinNext) {
                    groups.append(cur)
                    cur = []
                } else if hard {
                    // Prefer the latest punctuation or pause in the second half of the cue.
                    let split = (max(1, cur.count / 2)..<cur.count).last { k in
                        !cur[k - 1].joinNext && (endsClause(cur[k - 1].text) || cur[k].start - cur[k - 1].end >= 0.25)
                    }
                    if let k = split {
                        groups.append(Array(cur[..<k]))
                        cur = Array(cur[k...])
                    }
                    if !fits(cur + [w]) || (w.end - cur[0].start) * 1000 > Double(cueMaxMs) {
                        groups.append(cur)
                        cur = []
                    }
                }
            }
            cur.append(w)
        }
        if !cur.isEmpty { groups.append(cur) }

        func chars(_ ws: [CaptionWord]) -> Int { Self.columns(Self.joinWords(ws.map(\.text))) }
        // Where a length limit broke a sentence, even out the two cues so its end isn't left nearly alone;
        // a single last word joins the cue before it when they fit together.
        var i = 1
        while i < groups.count {
            let b = groups[i], a = groups[i - 1]
            guard !b[0].breakBefore, !endsSentence(a.last!.text), b[0].start - a.last!.end < cuePause, chars(b) * 2 < chars(a) else {
                i += 1
                continue
            }
            if b.count == 1, endsSentence(b[0].text), fits(a + b), span(a + b) <= Double(cueMaxMs) {
                groups[i - 1] = a + b
                groups.remove(at: i)
                continue
            }
            var na = a, nb = b
            while na.count > 1, !na[na.count - 2].joinNext, !na.last!.breakBefore {
                let tryA = Array(na.dropLast()), tryB = [na.last!] + nb
                guard chars(tryB) <= chars(tryA), fits(tryB), span(tryB) <= Double(cueMaxMs) else { break }
                (na, nb) = (tryA, tryB)
            }
            groups[i - 1] = na
            groups[i] = nb
            i += 1
        }

        // Fold cues too short to read into the next one when it follows closely, unless the short cue ends a
        // sentence it didn't start.
        i = 0
        while i + 1 < groups.count {
            let g = groups[i], n = groups[i + 1]
            let short = span(g) < Double(cueMinMs)
            let close = (n[0].start - g.last!.end) * 1000 < Double(cueMinMs + cueGapMs)
            let tail = i > 0 && !endsSentence(groups[i - 1].last!.text) && endsSentence(g.last!.text) && !g.last!.joinNext
            let merged = g + n
            if short, close, !tail, !n[0].breakBefore, fits(merged), span(merged) <= Double(cueMaxMs) {
                groups[i] = merged
                groups.remove(at: i + 1)
            } else {
                i += 1
            }
        }
        return groups
    }

    /// Start and end in milliseconds for each group: from the first word to the last word plus a linger, at least
    /// `cueMinMs` and at most `cueMaxMs` long, `cueGapMs` apart.
    static func cueTimes(_ groups: [[CaptionWord]], durationMs: Int) -> [(Int, Int)] {
        var out: [(Int, Int)] = []
        for g in groups {
            var start = ms(g[0].start)
            if let prev = out.last, start < prev.1 + cueGapMs {
                // Trim the previous cue as far as its minimum allows, then delay this one.
                out[out.count - 1].1 = max(start - cueGapMs, prev.0 + cueMinMs)
                start = max(start, out[out.count - 1].1 + cueGapMs)
            }
            var end = min(max(ms(g.last!.end) + cueLingerMs, start + cueMinMs), start + cueMaxMs)
            if durationMs >= start + cueMinMs { end = min(end, durationMs) }
            out.append((start, end))
        }
        return out
    }

    /// The fewest consecutive runs of `words` that each wrap into `lines` lines of `width`, with characters evened out.
    static func splitToFit(_ words: [CaptionWord], width: Int, lines: Int) -> [[CaptionWord]] {
        guard !fits(words, width: width, lines: lines) else { return [words] }
        var greedy: [[CaptionWord]] = []
        var cur: [CaptionWord] = []
        for w in words {
            if !cur.isEmpty, !fits(cur + [w], width: width, lines: lines) {
                greedy.append(cur)
                cur = []
            }
            cur.append(w)
        }
        if !cur.isEmpty { greedy.append(cur) }
        let k = greedy.count
        if words.contains(where: { $0.text.contains(where: \.isUnspaced) }) {
            let texts = words.map(\.text)
            let parts = unspacedLines(texts, width: Int.max, count: k) { r in fits(Array(words[r]), width: width, lines: lines) }
            return parts.map { Array(words[$0]) }
        }
        let sizes = words.map { Self.columns($0.text) + 1 }
        let total = Double(sizes.reduce(0, +))
        var parts: [[CaptionWord]] = []
        var from = 0, acc = 0
        for (i, s) in sizes.enumerated() {
            acc += s
            let target = total * Double(parts.count + 1) / Double(k)
            let remainingParts = k - parts.count - 1
            if parts.count < k - 1, Double(acc) >= target - Double(s) / 2, words.count - (i + 1) >= remainingParts {
                parts.append(Array(words[from...i]))
                from = i + 1
            }
        }
        if from < words.count { parts.append(Array(words[from...])) }
        return parts.allSatisfy({ fits($0, width: width, lines: lines) }) ? parts : greedy
    }

    /// Greedy word wrap in columns (`columns`); a word longer than `width` gets a line of its own.
    static func wrap(_ words: [String], width: Int) -> [String] {
        let words = words.filter { !$0.isEmpty }
        return greedyLines(words, width: width).map { joinWords(words[$0]) }
    }

    /// The fewest lines that fit `width`, with their lengths evened out; Chinese and Japanese lines also break at
    /// punctuation and particles where they can (`unspacedLines`).
    static func balancedLines(_ words: [String], width: Int) -> [String] {
        if words.contains(where: { $0.contains(where: \.isUnspaced) }) {
            let units = words.filter { !$0.isEmpty }
            return unspacedLines(units, width: width).map { joinWords(units[$0]) }
        }
        let best = wrap(words, width: width)
        guard best.count > 1 else { return best }
        var lines = best
        var w = width - 1
        while w > 0 {
            let candidate = wrap(words, width: w)
            if candidate.count > best.count { break }
            lines = candidate
            w -= 1
        }
        return lines
    }

    static func endsSentence(_ word: String) -> Bool {
        let t = word.trimmingCharacters(in: CharacterSet(charactersIn: "\"')]”’」』）"))
        return t.last.map { ".?!…。？！".contains($0) } ?? false
    }

    static func endsClause(_ word: String) -> Bool {
        endsSentence(word) || (word.last.map { ",;:—、，；：".contains($0) } ?? false)
    }

    static func subtitleTime(_ ms: Int, _ separator: String) -> String {
        let ms = max(0, ms)
        return String(format: "%02d:%02d:%02d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60) + separator + String(format: "%03d", ms % 1000)
    }

    static func vttEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
}
