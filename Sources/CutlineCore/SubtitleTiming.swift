import Foundation

/// Reading-speed timing of translated subtitles: a translation keeps the spoken cue's words but rarely its length,
/// so its cues are re-timed to the language's reading speed (`SubtitleRules`).
extension Project {
    /// How far a cue may start after the speech it shows, when the cue before it borrows its time.
    static let readingLagMs = 500
    /// How far a cue may start before the speech it shows.
    static let readingLeadMs = 250

    /// Characters a viewer reads in `cue`, spaces and line breaks not counted.
    public static func readChars(_ cue: SubtitleCue) -> Int { cue.lines.joined().filter { !$0.isWhitespace }.count }

    /// Milliseconds `cue` needs on screen at `rules`' reading speed, within the 1–7 s cue limits.
    static func readingMs(_ cue: SubtitleCue, _ rules: SubtitleRules) -> Int {
        min(cueMaxMs, max(cueMinMs, Int((Double(readChars(cue)) / rules.charsPerSecond * 1000).rounded(.up))))
    }

    /// `cues` (in order, not overlapping) re-timed so each can be read at `rules`' speed where time allows: a cue
    /// too fast first runs on into the silence after it, then starts up to `readingLeadMs` earlier into the silence
    /// before it, then takes spare time from its neighbours (the next cue starting at most `readingLagMs` after its
    /// speech, the previous one ending earlier while it stays readable). Cues stay `gapMs` apart (two frames),
    /// never longer than 7 s and inside the program (`durationMs`).
    static func retimedForReading(_ cues: [SubtitleCue], rules: (SubtitleCue) -> SubtitleRules, gapMs: Int, durationMs: Int) -> [SubtitleCue] {
        var out = cues
        let original = cues.map(\.startMs)
        let perCue = cues.map(rules)
        func need(_ i: Int) -> Int { readingMs(out[i], perCue[i]) }
        func dur(_ i: Int) -> Int { out[i].endMs - out[i].startMs }
        func slack(_ i: Int) -> Int { max(0, dur(i) - max(need(i), cueMinMs)) }
        let lastEnd = durationMs > 0 ? durationMs : Int.max
        for i in out.indices.dropLast() where out[i].endMs > out[i + 1].startMs - gapMs {
            out[i].endMs = max(out[i].startMs + 1, out[i + 1].startMs - gapMs)
        }
        for i in out.indices where dur(i) < need(i) {
            // Run on into the silence after it.
            let nextStart = i + 1 < out.count ? out[i + 1].startMs : lastEnd
            out[i].endMs = max(out[i].endMs, min(out[i].startMs + need(i), nextStart - gapMs, out[i].startMs + cueMaxMs))
            // Start earlier into the silence before it.
            if dur(i) < need(i) {
                let floor = max(i > 0 ? out[i - 1].endMs + gapMs : 0, original[i] - readingLeadMs, out[i].endMs - cueMaxMs)
                out[i].startMs = min(out[i].startMs, max(floor, out[i].endMs - need(i)))
            }
            // Take spare time from the next cue, delaying it a little.
            if dur(i) < need(i), i + 1 < out.count {
                let shift = min(need(i) - dur(i), slack(i + 1), max(0, original[i + 1] + readingLagMs - out[i + 1].startMs), out[i].startMs + cueMaxMs - out[i].endMs)
                if shift > 0 {
                    out[i + 1].startMs += shift
                    out[i].endMs = out[i + 1].startMs - gapMs
                }
            }
            // Take spare time from the previous cue, ending it earlier.
            if dur(i) < need(i), i > 0 {
                let lowest = max(original[i] - readingLeadMs, out[i].endMs - cueMaxMs, out[i - 1].startMs + max(need(i - 1), cueMinMs) + gapMs)
                let target = max(out[i].endMs - need(i), lowest)
                if target < out[i].startMs {
                    out[i].startMs = target
                    out[i - 1].endMs = min(out[i - 1].endMs, target - gapMs)
                }
            }
        }
        return out
    }

    /// `parts` (consecutive runs of `words`) with each boundary moved up to three words to the nearest clause end
    /// (punctuation) where every part still fits `lines` lines of `width`.
    static func clauseAligned(_ parts: [[CaptionWord]], width: Int, lines: Int) -> [[CaptionWord]] {
        guard parts.count > 1 else { return parts }
        var out = parts
        for b in 0..<(out.count - 1) {
            guard let last = out[b].last, !endsClause(last.text) else { continue }
            let joined = out[b] + out[b + 1]
            let at = out[b].count
            let options = (1...3).flatMap { [at - $0, at + $0] }.filter { $0 > 0 && $0 < joined.count }
            guard let k = options.first(where: { k in
                endsClause(joined[k - 1].text) && fits(Array(joined[..<k]), width: width, lines: lines) && fits(Array(joined[k...]), width: width, lines: lines)
            }) else { continue }
            out[b] = Array(joined[..<k])
            out[b + 1] = Array(joined[k...])
        }
        return out
    }

    /// Cues of `language` that still read faster than its rules allow after re-timing, with the rules.
    public func readingSpeedProblems(language: String, transcripts: [String: Transcript]) -> (rules: SubtitleRules, cues: Int, tooFast: [SubtitleCue]) {
        let cues = subtitleCues(transcripts: transcripts, language: language)
        let rules = subtitleRules(language: language, transcripts: transcripts)
        return (rules, cues.count, rules.tooFast(cues))
    }

    /// Indices of the shared cues (`captionCues`) whose `language` subtitles still read too fast.
    public func tooFastCaptionCues(language: String, transcripts: [String: Transcript]) -> [Int] {
        let fast = readingSpeedProblems(language: language, transcripts: transcripts).tooFast
        let shared = captionCues(transcripts: transcripts)
        var index: [String: Int] = [:]
        for (i, c) in shared.enumerated() { for w in c.words { if let a = w.anchor { index[a] = i } } }
        return Array(Set(fast.flatMap { $0.anchors.compactMap { index[$0] } })).sorted()
    }

    /// `text` without what a subtitle can drop: fillers, hedges, stutters and repeated words. Nil when nothing goes.
    public static func condensedForSubtitles(_ text: String) -> String? {
        let fillers: Set<String> = ["um", "uh", "er", "erm", "ah", "hmm", "mm", "basically", "actually", "literally", "really", "just", "very", "totally", "honestly", "obviously"]
        // Only as an opening word followed by a comma ("So, …", "Well, …").
        let openers: Set<String> = ["so", "well", "like", "okay", "ok", "right", "now"]
        let phrases = ["you know", "i mean", "i guess", "to be honest", "at the end of the day", "in order to"]
        var s = " " + text + " "
        for p in phrases {
            s = s.replacingOccurrences(of: #"(?i)([\s,])"# + NSRegularExpression.escapedPattern(for: p) + #"([\s,.!?])"#, with: p == "in order to" ? "$1to$2" : "$1$2", options: .regularExpression)
        }
        var words: [String] = []
        for raw in s.split(whereSeparator: \.isWhitespace).map(String.init) {
            let bare = raw.lowercased().trimmingCharacters(in: .punctuationCharacters)
            if bare.isEmpty { if var last = words.popLast() { last += raw; words.append(last) }; continue }
            if fillers.contains(bare) && !raw.contains(where: { ".?!".contains($0) }) || openers.contains(bare) && raw.hasSuffix(",") { continue }
            if let last = words.last, last.lowercased().trimmingCharacters(in: .punctuationCharacters) == bare { continue }
            words.append(raw)
        }
        var out = words.joined(separator: " ").replacingOccurrences(of: #"\s*,\s*,+"#, with: ",", options: .regularExpression)
            .replacingOccurrences(of: #"^[,\s]+|[,\s]+$"#, with: "", options: .regularExpression)
        if let f = out.first, text.first?.isUppercase == true { out = f.uppercased() + out.dropFirst() }
        return out.count < text.trimmingCharacters(in: .whitespaces).count && !out.isEmpty ? out : nil
    }
}
