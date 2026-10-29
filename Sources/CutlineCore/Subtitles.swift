import Foundation

public enum SubtitleFormat: String, CaseIterable, Sendable {
    case srt, vtt
}

/// One subtitle on the timeline, timed in milliseconds.
public struct SubtitleCue: Equatable, Sendable {
    public var startMs: Int
    public var endMs: Int
    public var lines: [String]

    public var start: Seconds { Double(startMs) / 1000 }
    public var end: Seconds { Double(endMs) / 1000 }
    public var text: String { lines.joined(separator: "\n") }
}

extension Project {
    /// Subtitles for the words heard on the timeline, with the caption replacements and hidden words applied.
    /// Cues keep to broadcast rules: at most `maxLines` lines of `maxCharsPerLine`, 1–7 s on screen,
    /// at least 0.1 s apart, breaking at sentence ends, clause punctuation and pauses.
    public func subtitles(_ format: SubtitleFormat, transcripts: [String: Transcript], maxCharsPerLine: Int = 42, maxLines: Int = 2) -> String {
        let cues = subtitleCues(transcripts: transcripts, maxCharsPerLine: maxCharsPerLine, maxLines: maxLines)
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

    public func subtitleCues(transcripts: [String: Transcript], maxCharsPerLine: Int = 42, maxLines: Int = 2) -> [SubtitleCue] {
        let maxChars = max(1, maxCharsPerLine), lineLimit = max(1, maxLines)
        let minMs = 1000, maxMs = 7000, gapMs = 100, lingerMs = 300
        let pause: Seconds = 0.7

        // Caption styling is for burnt-in captions; subtitles keep the spoken casing.
        var plain = self
        plain.captions.style.uppercase = false
        let words = plain.captionSegments(transcripts: transcripts).flatMap(\.words)

        func fits(_ ws: [CaptionWord]) -> Bool {
            Self.wrap(ws.map(\.text), width: maxChars).count <= lineLimit
        }

        var groups: [[CaptionWord]] = []
        var cur: [CaptionWord] = []
        for w in words {
            if let last = cur.last {
                let breakNow = w.start - last.end >= pause
                    || Self.endsSentence(last.text)
                    || (Self.endsClause(last.text) && cur.map(\.text).joined(separator: " ").count > maxChars)
                    || (w.end - cur[0].start) * 1000 > Double(maxMs)
                if breakNow {
                    groups.append(cur)
                    cur = []
                } else if !fits(cur + [w]) {
                    // Prefer the latest punctuation or pause in the second half of the cue.
                    let split = (max(1, cur.count / 2)..<cur.count).last { k in
                        Self.endsClause(cur[k - 1].text) || cur[k].start - cur[k - 1].end >= 0.25
                    }
                    if let k = split {
                        groups.append(Array(cur[..<k]))
                        cur = Array(cur[k...])
                    }
                    if !fits(cur + [w]) || (w.end - cur[0].start) * 1000 > Double(maxMs) {
                        groups.append(cur)
                        cur = []
                    }
                }
            }
            cur.append(w)
        }
        if !cur.isEmpty { groups.append(cur) }

        // Fold cues too short to read into the next one when it follows closely.
        var i = 0
        while i + 1 < groups.count {
            let g = groups[i], n = groups[i + 1]
            let short = (g.last!.end - g[0].start) * 1000 < Double(minMs)
            let close = (n[0].start - g.last!.end) * 1000 < Double(minMs + gapMs)
            let merged = g + n
            if short, close, fits(merged), (merged.last!.end - merged[0].start) * 1000 <= Double(maxMs) {
                groups[i] = merged
                groups.remove(at: i + 1)
            } else {
                i += 1
            }
        }

        func ms(_ t: Seconds) -> Int { Int((t * 1000).rounded()) }
        let durationMs = ms(duration)
        var cues: [SubtitleCue] = []
        for g in groups {
            var start = ms(g[0].start)
            if let prev = cues.last, start < prev.endMs + gapMs {
                // Trim the previous cue as far as its minimum allows, then delay this one.
                cues[cues.count - 1].endMs = max(start - gapMs, prev.startMs + minMs)
                start = max(start, cues[cues.count - 1].endMs + gapMs)
            }
            var end = min(max(ms(g.last!.end) + lingerMs, start + minMs), start + maxMs)
            if durationMs >= start + minMs { end = min(end, durationMs) }
            cues.append(SubtitleCue(startMs: start, endMs: end, lines: Self.balancedLines(g.map(\.text), width: maxChars)))
        }
        return cues
    }

    /// Greedy word wrap; a word longer than `width` gets a line of its own.
    static func wrap(_ words: [String], width: Int) -> [String] {
        var lines: [String] = []
        var line = ""
        for w in words {
            if line.isEmpty {
                line = w
            } else if line.count + 1 + w.count <= width {
                line += " " + w
            } else {
                lines.append(line)
                line = w
            }
        }
        if !line.isEmpty { lines.append(line) }
        return lines
    }

    /// The fewest lines that fit `width`, with their lengths evened out.
    static func balancedLines(_ words: [String], width: Int) -> [String] {
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
        let t = word.trimmingCharacters(in: CharacterSet(charactersIn: "\"')]”’"))
        return t.last.map { ".?!…".contains($0) } ?? false
    }

    static func endsClause(_ word: String) -> Bool {
        endsSentence(word) || (word.last.map { ",;:—".contains($0) } ?? false)
    }

    static func subtitleTime(_ ms: Int, _ separator: String) -> String {
        let ms = max(0, ms)
        return String(format: "%02d:%02d:%02d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60) + separator + String(format: "%03d", ms % 1000)
    }

    static func vttEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
}
