import Foundation

extension Transcript {
    /// Replaces words `range` with the words of `text`, sharing the old span out by length.
    /// Returns how many words now stand in place of the old ones.
    @discardableResult
    public mutating func replaceWords(_ range: ClosedRange<Int>, with text: String) throws -> Int {
        guard range.lowerBound >= 0, range.upperBound < words.count else { throw EditError("Words w\(range.lowerBound)–w\(range.upperBound) are outside the transcript (w0–w\(words.count - 1))") }
        let start = words[range.lowerBound].start, end = words[range.upperBound].end
        let tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        let total = Double(max(1, tokens.reduce(0) { $0 + $1.count + 1 }))
        var t = start
        let made = tokens.map { tok -> Word in
            let d = (end - start) * Double(tok.count + 1) / total
            defer { t += d }
            return Word(text: tok, start: t, end: t + d)
        }
        words.replaceSubrange(range, with: made)
        return made.count
    }

    /// Inserts words spoken between `start` and `end` (source time) that recognition missed.
    @discardableResult
    public mutating func insertWords(_ text: String, start: Seconds, end: Seconds) -> Range<Int> {
        let at = words.firstIndex { $0.start >= start } ?? words.count
        let tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        let total = Double(max(1, tokens.reduce(0) { $0 + $1.count + 1 }))
        var t = start
        let made = tokens.map { tok -> Word in
            let d = (end - start) * Double(tok.count + 1) / total
            defer { t += d }
            return Word(text: tok, start: t, end: t + d)
        }
        words.insert(contentsOf: made, at: at)
        return at..<(at + made.count)
    }
}

extension SpeakerAnalysis {
    /// Keeps the per-word arrays parallel after `old` words became `count` words.
    public mutating func spliceWords(_ old: Range<Int>, count: Int) {
        let lo = min(old.lowerBound, wordSpeakers.count), hi = min(old.upperBound, wordSpeakers.count)
        let who = lo < wordSpeakers.count ? wordSpeakers[lo] : (lo > 0 ? wordSpeakers[lo - 1] : nil)
        wordSpeakers.replaceSubrange(lo..<hi, with: Array(repeating: who, count: count))
        let elo = min(old.lowerBound, emphasis.count), ehi = min(old.upperBound, emphasis.count)
        emphasis.replaceSubrange(elo..<ehi, with: Array(repeating: 0, count: count))
    }

    /// Sets who speaks words `range` and rebuilds the turns from the words.
    public mutating func assign(_ range: ClosedRange<Int>, to speaker: String, transcript: Transcript) {
        if wordSpeakers.count < transcript.words.count { wordSpeakers += Array(repeating: nil, count: transcript.words.count - wordSpeakers.count) }
        if emphasis.count < transcript.words.count { emphasis += Array(repeating: 0, count: transcript.words.count - emphasis.count) }
        for i in range where i < wordSpeakers.count { wordSpeakers[i] = speaker }
        rebuildSegments(transcript)
    }

    /// Renames speakers everywhere, e.g. ["S1": "Anna"]. Two names mapped to one merge.
    public mutating func rename(_ names: [String: String], transcript: Transcript) {
        wordSpeakers = wordSpeakers.map { $0.map { names[$0] ?? $0 } }
        for i in segments.indices { segments[i].speaker = names[segments[i].speaker] ?? segments[i].speaker }
        rebuildSegments(transcript)
    }

    /// Turns from consecutive words with one speaker, keeping speakers in order of first appearance.
    public mutating func rebuildSegments(_ transcript: Transcript) {
        let old = segments
        var segs: [SpeakerSegment] = []
        for (i, w) in transcript.words.enumerated() {
            guard i < wordSpeakers.count, let who = wordSpeakers[i] else { continue }
            if let last = segs.last, last.speaker == who {
                segs[segs.count - 1].end = max(last.end, w.end)
            } else {
                if let last = segs.last, last.end > w.start { segs[segs.count - 1].end = w.start }
                segs.append(SpeakerSegment(start: w.start, end: w.end, speaker: who))
            }
        }
        // A rebuilt turn is as certain as the least certain scored turn it overlaps.
        for i in segs.indices {
            let scores = old.filter { $0.end > segs[i].start && $0.start < segs[i].end }.compactMap(\.confidence)
            segs[i].confidence = scores.min()
        }
        segments = segs
        var order: [String] = []
        for s in segs where !order.contains(s.speaker) { order.append(s.speaker) }
        speakers = order
    }
}
