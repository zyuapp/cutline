import Foundation

/// Line length and reading speed subtitles keep to in a language, from the Netflix timed text style guides
/// (adult programs): Japanese 13 full-width characters a line at 4 characters/s, Chinese 16 at 9, Korean 16 at 12,
/// Thai 35 at 15, English 42 at 20, other languages 42 at 17.
public struct SubtitleRules: Equatable, Sendable {
    /// Characters a line holds; full-width ones when `wide`.
    public var maxCharsPerLine: Int
    /// Characters a viewer reads per second.
    public var charsPerSecond: Double
    /// Lines are counted in full-width characters (Chinese, Japanese, Korean).
    public var wide: Bool

    public init(maxCharsPerLine: Int, charsPerSecond: Double, wide: Bool = false) {
        self.maxCharsPerLine = maxCharsPerLine
        self.charsPerSecond = charsPerSecond
        self.wide = wide
    }

    /// Line width in columns, a full-width character taking two (`Project.columns`).
    public var columns: Int { wide ? maxCharsPerLine * 2 : maxCharsPerLine }

    public static let standard = SubtitleRules(maxCharsPerLine: 42, charsPerSecond: 17)

    /// The rules for a language tag ("ja", "zh-Hant", "pt_BR").
    public static func forLanguage(_ tag: String) -> SubtitleRules {
        let t = Project.languageTag(tag).lowercased()
        let code = String(t.split(separator: "-").first ?? Substring(t))
        switch code {
        case "ja", "jpn": return SubtitleRules(maxCharsPerLine: 13, charsPerSecond: 4, wide: true)
        case "zh", "zho", "chi", "yue", "cmn": return SubtitleRules(maxCharsPerLine: 16, charsPerSecond: 9, wide: true)
        case "ko", "kor": return SubtitleRules(maxCharsPerLine: 16, charsPerSecond: 12, wide: true)
        case "th", "tha": return SubtitleRules(maxCharsPerLine: 35, charsPerSecond: 15)
        case "en", "eng": return SubtitleRules(maxCharsPerLine: 42, charsPerSecond: 20)
        default: return .standard
        }
    }

    /// The rules for text written in Chinese, Japanese or Korean script; nil for other scripts.
    public static func forText(_ text: String) -> SubtitleRules? {
        var han = false
        for s in text.unicodeScalars {
            switch s.value {
            case 0x3040...0x30FF, 0x31F0...0x31FF: return forLanguage("ja")
            case 0x1100...0x11FF, 0x3130...0x318F, 0xAC00...0xD7AF: return forLanguage("ko")
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FFFF: han = true
            default: continue
            }
        }
        return han ? forLanguage("zh") : nil
    }

    /// Cues that need more than `charsPerSecond` to read, spaces and line breaks not counted.
    public func tooFast(_ cues: [SubtitleCue]) -> [SubtitleCue] {
        cues.filter { c in
            let chars = c.lines.joined().filter { !$0.isWhitespace }.count
            return Double(chars) > charsPerSecond * max(c.end - c.start, 0.001) + 1e-9
        }
    }
}

extension Character {
    /// Han, kana, CJK punctuation and full-width forms: scripts written without spaces between words.
    var isUnspaced: Bool {
        guard let v = unicodeScalars.first?.value else { return false }
        switch v {
        case 0x3000...0x303F, 0x3040...0x30FF, 0x31F0...0x31FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0xFF00...0xFF60, 0xFFE0...0xFFE6, 0x20000...0x2FFFF: return true
        default: return false
        }
    }

    /// Takes two columns on screen: unspaced CJK characters and Hangul.
    var isWide: Bool {
        guard let v = unicodeScalars.first?.value else { return false }
        if isUnspaced { return true }
        switch v {
        case 0x1100...0x11FF, 0x3130...0x318F, 0xAC00...0xD7AF: return true
        default: return false
        }
    }
}

extension Project {
    /// Line rules for subtitles in `language` (a translation tag), else the spoken language.
    public func subtitleRules(language: String?, transcripts: [String: Transcript]) -> SubtitleRules {
        if let language, captions.translations[Self.languageTag(language)] != nil { return .forLanguage(language) }
        let spoken = captionCues(transcripts: transcripts).prefix(20).map(\.text).joined()
        return SubtitleRules.forText(spoken) ?? .forLanguage(spokenLanguage(transcripts: transcripts))
    }

    /// Screen width of `s` in columns: two for a full-width character, one for others.
    public static func columns(_ s: String) -> Int { s.reduce(0) { $0 + ($1.isWide ? 2 : 1) } }

    /// What goes between two words on a line: nothing next to Chinese or Japanese text, else a space.
    public static func wordSeparator(_ a: String, _ b: String) -> String {
        (a.last?.isUnspaced ?? false) || (b.first?.isUnspaced ?? false) ? "" : " "
    }

    /// Words joined as a line shows them (`wordSeparator`).
    public static func joinWords<S: Sequence>(_ words: S) -> String where S.Element == String {
        var out = ""
        for w in words { out += out.isEmpty ? w : wordSeparator(out, w) + w }
        return out
    }

    /// Characters that never start a line (kinsoku): closing brackets and punctuation, small kana, the long vowel
    /// mark and iteration marks.
    static let noLineStart: Set<Character> = Set("、。，．・：；？！゛゜ー〜～…‥々〻ゝゞヽヾ」』）］｝〉》】〕〙〗〟’”),.!?:;%ぁぃぅぇぉっゃゅょゎゕゖァィゥェォッャュョヮヵヶㇰㇱㇲㇳㇴㇵㇶㇷㇸㇹㇺㇻㇼㇽㇾㇿ")
    /// Characters that never end a line: opening brackets and quotes.
    static let noLineEnd: Set<Character> = Set("「『（［｛〈《【〔〘〖〝‘“([{")
    static let japaneseParticles: Set<String> = ["は", "が", "を", "に", "で", "と", "も", "へ", "の", "や", "か", "ね", "よ", "から", "まで", "より"]

    /// The units a line may break between. Text with Chinese or Japanese characters is cut between characters, with
    /// numbers and Latin words kept whole, closing punctuation and small kana kept on the unit before and opening
    /// brackets on the unit after (kinsoku). Other text is its space-separated words.
    public static func textUnits(_ text: String) -> [String] {
        guard text.contains(where: \.isUnspaced) else { return text.split(whereSeparator: \.isWhitespace).map(String.init) }
        var units: [String] = []
        var open = ""
        var latin = false
        for ch in text {
            if ch.isWhitespace { latin = false; continue }
            if noLineStart.contains(ch), open.isEmpty, !units.isEmpty {
                units[units.count - 1].append(ch)
                if ch.isUnspaced { latin = false }
                continue
            }
            if noLineEnd.contains(ch) { open.append(ch); latin = false; continue }
            if ch.isUnspaced {
                units.append(open + String(ch))
                open = ""
                latin = false
            } else if latin, open.isEmpty {
                units[units.count - 1].append(ch)
            } else {
                units.append(open + String(ch))
                open = ""
                latin = true
            }
        }
        if !open.isEmpty { if units.isEmpty { units.append(open) } else { units[units.count - 1] += open } }
        return units
    }

    /// How good a line break after unit `i` is: after punctuation best, then after a Japanese particle or between
    /// scripts; inside a run of one script (most likely one word) worst.
    static func breakScore(_ units: [String], after i: Int) -> Double {
        let a = units[i], b = units[i + 1]
        guard let last = a.last, let first = b.first else { return 0 }
        if "、。，．！？：；…‥」』）】〕〉》,.!?;:".contains(last) { return 3 }
        func script(_ c: Character) -> Int {
            guard let v = c.unicodeScalars.first?.value else { return 0 }
            switch v {
            case 0x3040...0x309F: return 1
            case 0x30A0...0x30FF, 0x31F0...0x31FF: return 2
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FFFF: return 3
            default: return c.isUnspaced ? 4 : 5
            }
        }
        let sa = script(last), sb = script(first)
        if sa == 1, sb != 1 {
            let tail = String(a.suffix(2))
            return japaneseParticles.contains(tail) || japaneseParticles.contains(String(last)) ? 2 : 1
        }
        if sa != sb { return 1 }
        return sa == 5 ? 0.5 : -1
    }

    /// Lines of Chinese or Japanese units within `width` columns: the fewest lines, then the breaks that best fall at
    /// punctuation and particles while keeping the lines even. A unit wider than a line gets one of its own.
    /// With `count` and `fits`, `count` runs that each satisfy `fits` instead (a cue split into several).
    static func unspacedLines(_ units: [String], width: Int, count: Int? = nil, fits: ((Range<Int>) -> Bool)? = nil) -> [Range<Int>] {
        let n = units.count
        guard n > 1 else { return n == 1 ? [0..<1] : [] }
        let count = min(n, count ?? greedyLines(units, width: width).count)
        guard count > 1 else { return [0..<n] }
        func w(_ r: Range<Int>) -> Int { columns(joinWords(units[r])) }
        let avg = Double(w(0..<n)) / Double(count)
        let scale = Double(max(1, width == Int.max ? Int(avg) : width))
        func lineCost(_ r: Range<Int>) -> Double? {
            let lw = w(r)
            if let fits { guard fits(r) else { return nil } } else { guard lw <= width || r.count == 1 else { return nil } }
            let d = (Double(lw) - avg) / scale
            return 4 * d * d
        }
        // best[k][j]: cheapest split of units[0..<j] into k lines, with the start of its last line.
        var best = [[(cost: Double, from: Int)?]](repeating: [(Double, Int)?](repeating: nil, count: n + 1), count: count + 1)
        best[0][0] = (0, 0)
        for k in 1...count {
            for j in 1...n {
                for i in (k - 1)..<j {
                    guard let prev = best[k - 1][i], let c = lineCost(i..<j) else { continue }
                    let total = prev.cost + c - (i > 0 ? breakScore(units, after: i - 1) : 0)
                    if best[k][j].map({ total < $0.cost }) ?? true { best[k][j] = (total, i) }
                }
            }
        }
        guard best[count][n] != nil else {
            guard let fits else { return greedyLines(units, width: width) }
            var out: [Range<Int>] = []
            var start = 0
            for j in 1...n where j - start > 1 && !fits(start..<j) {
                out.append(start..<(j - 1))
                start = j - 1
            }
            return out + [start..<n]
        }
        var out: [Range<Int>] = []
        var j = n
        for k in stride(from: count, to: 0, by: -1) {
            let i = best[k][j]!.from
            out.insert(i..<j, at: 0)
            j = i
        }
        return out
    }

    /// The fewest lines of `words` within `width` columns, evened out (`unspacedLines` for Chinese and Japanese).
    static func lineGroups(_ words: [String], width: Int) -> [Range<Int>] {
        if words.contains(where: { $0.contains(where: \.isUnspaced) }) { return unspacedLines(words, width: width) }
        let best = greedyLines(words, width: width)
        guard best.count > 1 else { return best }
        var lines = best
        var w = width - 1
        while w > 0 {
            let candidate = greedyLines(words, width: w)
            if candidate.count > best.count { break }
            lines = candidate
            w -= 1
        }
        return lines
    }

    /// Greedy lines of `words` within `width` columns; a word wider than a line gets one of its own.
    static func greedyLines(_ words: [String], width: Int) -> [Range<Int>] {
        var out: [Range<Int>] = []
        var start = 0
        var line = ""
        for (i, w) in words.enumerated() {
            if i == start { line = w; continue }
            let next = line + wordSeparator(line, w) + w
            if columns(next) <= width {
                line = next
            } else {
                out.append(start..<i)
                start = i
                line = w
            }
        }
        if start < words.count { out.append(start..<words.count) }
        return out
    }
}
