import Foundation

public struct CaptionWord: Equatable, Hashable, Sendable {
    public var text: String
    public var start: Seconds
    public var end: Seconds
}

/// A block of caption text on the timeline.
public struct CaptionSegment: Equatable, Hashable, Sendable, Identifiable {
    public var id: Int
    public var start: Seconds
    public var end: Seconds
    /// Each line is a list of words.
    public var lines: [[CaptionWord]]

    public var words: [CaptionWord] { lines.flatMap { $0 } }
    public var text: String { lines.map { $0.map(\.text).joined(separator: " ") }.joined(separator: "\n") }
}

/// A transcript word placed on the timeline.
public struct TimelineWord: Equatable, Sendable {
    public var text: String
    public var start: Seconds
    public var end: Seconds
    public var clipId: String
    public var mediaId: String
    public var sourceStart: Seconds
}

extension Project {
    /// Words heard on the timeline, mapped from source transcripts through every clip.
    public func timelineWords(transcripts: [String: Transcript], trackIds: [String] = []) -> [TimelineWord] {
        var out: [TimelineWord] = []
        for track in tracks where !track.muted && (trackIds.isEmpty || trackIds.contains(track.id)) {
            for clip in track.clips where clip.kind == .media && clip.volume > 0.001 {
                guard let mid = clip.mediaId, let tr = transcripts[mid] else { continue }
                for w in tr.words {
                    let mid = (w.start + w.end) / 2
                    guard mid >= clip.sourceIn, mid < clip.sourceOut else { continue }
                    let s = max(clip.start, clip.timelineTime(atSource: w.start))
                    let e = min(clip.end, clip.timelineTime(atSource: w.end))
                    out.append(TimelineWord(text: w.text, start: s, end: max(e, s + 0.05), clipId: clip.id, mediaId: tr.mediaId, sourceStart: w.start))
                }
            }
        }
        out.sort { $0.start < $1.start }
        var deduped: [TimelineWord] = []
        for w in out {
            if let last = deduped.last, last.text == w.text, abs(last.start - w.start) < 0.05 { continue }
            deduped.append(w)
        }
        return deduped
    }

    public func captionSegments(transcripts: [String: Transcript]) -> [CaptionSegment] {
        let style = captions.style
        let hidden = Set(captions.hiddenWords.map { $0.lowercased() })
        let replacements = Dictionary(captions.replacements.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { a, _ in a })
        var words: [CaptionWord] = []
        for w in timelineWords(transcripts: transcripts, trackIds: captions.trackIds) {
            let norm = w.text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)).lowercased()
            if hidden.contains(norm) { continue }
            var text = w.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let rep = replacements[norm] {
                let trailing = String(text.reversed().prefix { $0.isPunctuation }.reversed())
                text = rep + trailing
            }
            if style.uppercase { text = text.uppercased() }
            guard !text.isEmpty else { continue }
            words.append(CaptionWord(text: text, start: w.start, end: w.end))
        }
        mergeMultiWordReplacements(&words, replacements: replacements)

        let perLine = max(1, style.maxWordsPerLine)
        let perSegment = perLine * max(1, style.maxLines)
        var groups: [[CaptionWord]] = []
        var current: [CaptionWord] = []
        for w in words {
            if let last = current.last {
                let gap = w.start - last.end
                let endsSentence = last.text.last.map { ".?!".contains($0) } ?? false
                let tooLong = w.end - current[0].start > 3.2
                if gap > 0.6 || current.count >= perSegment || tooLong || endsSentence {
                    groups.append(current)
                    current = []
                }
            }
            current.append(w)
        }
        if !current.isEmpty { groups.append(current) }

        var segments: [CaptionSegment] = []
        for (i, g) in groups.enumerated() {
            let lineCount = Int((Double(g.count) / Double(perLine)).rounded(.up))
            let size = Int((Double(g.count) / Double(lineCount)).rounded(.up))
            let lines = stride(from: 0, to: g.count, by: size).map { Array(g[$0..<min($0 + size, g.count)]) }
            let nextStart = i + 1 < groups.count ? groups[i + 1][0].start : .infinity
            let end = min(g.last!.end + 0.35, nextStart, duration)
            segments.append(CaptionSegment(id: i, start: g[0].start, end: max(end, g.last!.end), lines: lines))
        }
        return segments
    }

    private func mergeMultiWordReplacements(_ words: inout [CaptionWord], replacements: [String: String]) {
        let multi = replacements.filter { $0.key.contains(" ") }
        guard !multi.isEmpty else { return }
        for (key, value) in multi {
            let parts = key.split(separator: " ").map(String.init)
            var i = 0
            while i + parts.count <= words.count {
                let window = words[i..<(i + parts.count)].map {
                    $0.text.trimmingCharacters(in: .punctuationCharacters).lowercased()
                }
                if window == parts {
                    let trailing = String(words[i + parts.count - 1].text.reversed().prefix { $0.isPunctuation }.reversed())
                    let merged = CaptionWord(text: (captions.style.uppercase ? value.uppercased() : value) + trailing, start: words[i].start, end: words[i + parts.count - 1].end)
                    words.replaceSubrange(i..<(i + parts.count), with: [merged])
                }
                i += 1
            }
        }
    }
}

extension Clip {
    /// Transform at a time relative to the clip start, with keyframes and fades applied.
    public func resolvedTransform(at local: Seconds) -> Transform {
        var t = transform
        if !keyframes.isEmpty {
            let ks = keyframes.sorted { $0.time < $1.time }
            func value(_ path: KeyPath<Keyframe, Double?>, base: Double) -> Double {
                let frames = ks.compactMap { k in k[keyPath: path].map { (k.time, $0, k.easing) } }
                guard let first = frames.first else { return base }
                if local <= first.0 { return first.1 }
                for (a, b) in zip(frames, frames.dropFirst()) where local < b.0 {
                    let p = b.2.apply((local - a.0) / max(b.0 - a.0, 1e-9))
                    return a.1 + (b.1 - a.1) * p
                }
                return frames.last!.1
            }
            t.scale = value(\.scale, base: t.scale)
            t.x = value(\.x, base: t.x)
            t.y = value(\.y, base: t.y)
            t.rotation = value(\.rotation, base: t.rotation)
            t.opacity = value(\.opacity, base: t.opacity)
        }
        var fade = 1.0
        if fadeIn > 0 { fade = min(fade, local / fadeIn) }
        if fadeOut > 0 { fade = min(fade, (duration - local) / fadeOut) }
        t.opacity *= min(max(fade, 0), 1)
        return t
    }
}
