import Foundation

extension Transcript {
    /// Parts of `speech` at least `minimum` seconds long that no word covers, kept `margin` clear of the words around them.
    public func unheardSpeech(_ speech: [TimeRange], minimum: Seconds = 0.8, margin: Seconds = 0.2) -> [TimeRange] {
        let covered = TimeRange.merged(words.map { TimeRange($0.start - margin, $0.end + margin) })
        var out: [TimeRange] = []
        for s in TimeRange.merged(speech) {
            var pieces = [s]
            for c in covered where c.end > s.start && c.start < s.end {
                pieces = pieces.flatMap { p -> [TimeRange] in
                    guard p.intersection(c) != nil else { return [p] }
                    return [TimeRange(p.start, c.start), TimeRange(c.end, p.end)].filter { $0.duration > 0 }
                }
            }
            out += pieces.filter { $0.duration >= minimum }
        }
        return out
    }

    /// Share of words the recognizer was unsure of.
    public var lowConfidenceShare: Double {
        words.isEmpty ? 0 : Double(words.filter(\.isLowConfidence).count) / Double(words.count)
    }

    /// Takes `other`'s reading (e.g. of voice-isolated audio) of each stretch of speech where it scores clearly
    /// higher. Stretches are split at pauses of `pause` seconds in either reading; a reading scores the sum of its
    /// words' confidence there, the expected number of right words, and must beat the other by `margin` words.
    /// Returns the stretches replaced.
    @discardableResult
    public mutating func adoptBetter(_ other: Transcript, pause: Seconds = 0.5, margin: Double = 1) -> Int {
        let all = (words.map { ($0, true) } + other.words.map { ($0, false) }).sorted { $0.0.start < $1.0.start }
        var stretches: [[(Word, Bool)]] = []
        var end = -Double.infinity
        for item in all {
            if item.0.start - end >= pause || stretches.isEmpty { stretches.append([]) }
            stretches[stretches.count - 1].append(item)
            end = max(end, item.0.end)
        }
        var out: [Word] = []
        var replaced = 0
        for s in stretches {
            let mine = s.filter(\.1).map(\.0), theirs = s.filter { !$0.1 }.map(\.0)
            func score(_ ws: [Word]) -> Double { ws.map { $0.confidence ?? 0.9 }.reduce(0, +) }
            if !theirs.isEmpty, score(theirs) > score(mine) + margin {
                out += theirs
                replaced += 1
            } else {
                out += mine
            }
        }
        words = out
        return replaced
    }

    /// Adds the `found` words whose midpoint falls inside one of `spans`, that overlap no existing word and don't
    /// repeat a neighbor within a second, when on average they are at least `minConfidence` sure.
    /// Returns how many were added.
    @discardableResult
    public mutating func addRecovered(_ found: [Word], in spans: [TimeRange], minConfidence: Double = 0.4) -> Int {
        var added: [Word] = []
        for w in found {
            let mid = (w.start + w.end) / 2
            guard spans.contains(where: { $0.start <= mid && mid < $0.end }) else { continue }
            guard !(words + added).contains(where: { $0.start < w.end - 0.01 && $0.end > w.start + 0.01 }) else { continue }
            guard !words.contains(where: { $0.normalized == w.normalized && abs($0.start - w.start) < 1 }) else { continue }
            added.append(w)
        }
        let sure = added.map { $0.confidence ?? 1 }.reduce(0, +) / Double(max(1, added.count))
        guard !added.isEmpty, sure >= minConfidence else { return 0 }
        words = (words + added).sorted { $0.start < $1.start }
        return added.count
    }

    /// Respells words that sound like a single-word vocabulary term ("Tom" → "Thom" for the name Thom): a
    /// capitalized or low-confidence word with the same sound key, or a low-confidence word of four letters or more
    /// within two edits that starts with the same letter. Punctuation stays. Returns (index, old, new) per change.
    @discardableResult
    public mutating func applyVocabulary(_ terms: [String]) -> [(Int, String, String)] {
        let single = terms.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty && !$0.contains(" ") }
        guard !single.isEmpty else { return [] }
        let known = Set(single.map { $0.lowercased() })
        var changes: [(Int, String, String)] = []
        for i in words.indices {
            let w = words[i]
            let core = w.normalized
            guard core.count >= 2, !known.contains(core), core.allSatisfy(\.isLetter) else { continue }
            let capitalized = w.text.first { $0.isLetter }?.isUppercase ?? false
            let low = w.isLowConfidence
            let match = single.first { term in
                let t = term.lowercased()
                if (capitalized || low), Vocabulary.soundKey(t) == Vocabulary.soundKey(core), Vocabulary.editDistance(t, core) <= max(1, t.count / 2) { return true }
                return low && t.count >= 4 && core.count >= 4 && t.first == core.first && Vocabulary.editDistance(t, core) <= 2
            }
            guard let term = match else { continue }
            let lead = String(w.text.prefix { !$0.isLetter && !$0.isNumber })
            let trail = String(w.text.reversed().prefix { !$0.isLetter && !$0.isNumber }.reversed())
            words[i].text = lead + term + trail
            changes.append((i, w.text, words[i].text))
        }
        return changes
    }
}

/// Spellings a transcript should use: names and product terms.
public enum Vocabulary {
    /// The terms for `media`: its own transcript vocabulary, the targets of caption replacements and the names given
    /// to speakers (`speakerNames`, without the automatic S1, S2…).
    public static func terms(_ project: Project, media: MediaAsset, speakerNames: [String] = []) -> [String] {
        var out: [String] = media.vocabulary ?? []
        out += project.captions.replacements.values.filter { v in v.contains { $0.isLetter } }
        out += speakerNames.filter { $0.range(of: #"^S\d+$"#, options: .regularExpression) == nil }
        var seen = Set<String>()
        return out.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    /// Lowercased words of `s` without punctuation.
    public static func tokens(_ s: String) -> [String] {
        s.lowercased().split { !$0.isLetter && !$0.isNumber && $0 != "'" }.map(String.init)
    }

    /// The terms `text` contains as whole words.
    public static func found(_ terms: [String], in text: String) -> Set<String> {
        let words = tokens(text)
        var out = Set<String>()
        for term in terms {
            let t = tokens(term)
            guard !t.isEmpty, words.count >= t.count else { continue }
            if (0...(words.count - t.count)).contains(where: { Array(words[$0..<($0 + t.count)]) == t }) { out.insert(term.lowercased()) }
        }
        return out
    }

    /// Index of the first of `alternatives` (the recognizer's best first) that spells a term the best one doesn't, else 0.
    public static func preferred(_ alternatives: [String], terms: [String]) -> Int {
        guard let best = alternatives.first, !terms.isEmpty else { return 0 }
        let have = found(terms, in: best)
        return alternatives.indices.dropFirst().first { !found(terms, in: alternatives[$0]).subtracting(have).isEmpty } ?? 0
    }

    /// A rough sound key: consonant skeleton after common English spelling folds ("Thom" and "Tom" → "tm").
    public static func soundKey(_ s: String) -> String {
        var t = s.lowercased().filter(\.isLetter)
        for (a, b) in [("ph", "f"), ("ck", "k"), ("th", "t"), ("gh", "g"), ("wh", "w"), ("sch", "sk"), ("q", "k"), ("x", "ks"), ("z", "s")] {
            t = t.replacingOccurrences(of: a, with: b)
        }
        if t.hasPrefix("kn") { t.removeFirst() }
        var folded = ""
        for (i, c) in t.enumerated() {
            let next = t.dropFirst(i + 1).first
            var ch = c
            if c == "c" { ch = next.map { "eiy".contains($0) } == true ? "s" : "k" }
            folded.append(ch)
        }
        guard let first = folded.first else { return "" }
        var out = String(first)
        for c in folded.dropFirst() where !"aeiouyhw".contains(c) {
            if out.last != c { out.append(c) }
        }
        return out
    }

    public static func editDistance(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        guard !x.isEmpty else { return y.count }
        guard !y.isEmpty else { return x.count }
        var row = Array(0...y.count)
        for i in 1...x.count {
            var prev = row[0]
            row[0] = i
            for j in 1...y.count {
                let cur = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, prev + (x[i - 1] == y[j - 1] ? 0 : 1))
                prev = cur
            }
        }
        return row[y.count]
    }
}
