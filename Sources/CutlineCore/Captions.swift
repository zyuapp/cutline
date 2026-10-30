import Foundation

public struct CaptionWord: Equatable, Hashable, Sendable {
    public var text: String
    public var start: Seconds
    public var end: Seconds
    /// The transcript word this came from, as "<mediaId>.w<index>".
    public var anchor: String? = nil
    /// A cue must start at this word.
    public var breakBefore = false
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
    /// Index in the media's transcript, so "<mediaId>.w<index>" is this word's anchor.
    public var wordIndex: Int
}

extension Project {
    /// Words heard on the timeline, mapped from source transcripts through every clip.
    public func timelineWords(transcripts: [String: Transcript], trackIds: [String] = []) -> [TimelineWord] {
        var out: [TimelineWord] = []
        for track in flattenedForSound where !track.muted && (trackIds.isEmpty || trackIds.contains(track.id)) {
            for clip in track.clips where clip.kind == .media && clip.volume > 0.001 {
                guard let mid = clip.mediaId, let tr = transcripts[mid] else { continue }
                let heard = clip.audioSourceRange, span = clip.audioRange
                for (wi, w) in tr.words.enumerated() {
                    let mid = (w.start + w.end) / 2
                    guard mid >= heard.start, mid < heard.end else { continue }
                    let s = max(span.start, clip.timelineTime(atSource: w.start))
                    let e = min(span.end, clip.timelineTime(atSource: w.end))
                    out.append(TimelineWord(text: w.text, start: s, end: max(e, s + 0.05), clipId: clip.id, mediaId: tr.mediaId, sourceStart: w.start, wordIndex: wi))
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

    /// Tracks captioned by default: those with the dialogue role, or else every track whose role or name
    /// isn't music, effects or ambience.
    public var captionTrackIds: [String] {
        let sound = flattenedForSound
        let dialogue = sound.filter { $0.role?.lowercased() == "dialogue" }.map(\.id)
        if !dialogue.isEmpty { return dialogue }
        let background = ["music", "effects", "sfx", "fx", "ambience", "ambient", "amb", "atmos", "atmosphere", "room tone", "roomtone", "foley", "score", "bed"]
        return sound.filter { t in
            let tags = [t.role, t.name].compactMap { $0?.lowercased() }
            return !tags.contains { tag in background.contains { tag == $0 || tag.hasPrefix($0 + " ") || tag.hasSuffix(" " + $0) } }
        }.map(\.id)
    }

    /// Timeline words the captions read: the caption tracks, or the dialogue tracks when none are set.
    public func captionTimelineWords(transcripts: [String: Transcript]) -> [TimelineWord] {
        let ids = captions.trackIds.isEmpty ? captionTrackIds : captions.trackIds
        guard !ids.isEmpty else { return [] }
        return timelineWords(transcripts: transcripts, trackIds: ids)
    }

    /// Timeline spans where two clips' speech overlaps, which a single caption track can't show cleanly.
    public func overlappingSpeech(transcripts: [String: Transcript]) -> [TimeRange] {
        let words = captionTimelineWords(transcripts: transcripts)
        var spans: [TimeRange] = []
        for (i, a) in words.enumerated() {
            for b in words[(i + 1)...] {
                if b.start >= a.end - 0.05 { break }
                if b.clipId != a.clipId { spans.append(TimeRange(b.start, min(a.end, b.end))) }
            }
        }
        return TimeRange.merged(spans, tolerance: 0.5)
    }

    public func captionSegments(transcripts: [String: Transcript]) -> [CaptionSegment] {
        let style = captions.style
        let hidden = Set(captions.hiddenWords.map { $0.lowercased() })
        let replacements = Dictionary(captions.replacements.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { a, _ in a })
        var words: [CaptionWord] = []
        var run: (edit: CaptionEdit, words: [TimelineWord])?
        func flush() {
            guard let r = run else { return }
            run = nil
            if r.edit.hidden == true { return }
            let start = r.words[0].start + (r.edit.startOffset ?? 0)
            let end = max(start + 0.05, r.words.last!.end + (r.edit.endOffset ?? 0))
            let anchor = "\(r.edit.mediaId).w\(r.words[0].wordIndex)"
            var made: [CaptionWord]
            if let text = r.edit.text {
                let tokens = text.split(whereSeparator: \.isWhitespace).map { style.uppercase ? $0.uppercased() : String($0) }
                let total = Double(max(1, tokens.reduce(0) { $0 + $1.count + 1 }))
                var t = start
                made = tokens.map { tok in
                    let d = (end - start) * Double(tok.count + 1) / total
                    defer { t += d }
                    return CaptionWord(text: tok, start: t, end: t + d, anchor: anchor)
                }
            } else {
                made = r.words.map { CaptionWord(text: style.uppercase ? $0.text.uppercased() : $0.text, start: $0.start, end: $0.end, anchor: "\($0.mediaId).w\($0.wordIndex)") }
                if !made.isEmpty {
                    made[0].start = start
                    made[made.count - 1].end = end
                }
            }
            if r.edit.breakBefore == true, !made.isEmpty { made[0].breakBefore = true }
            words += made
        }
        for w in captionTimelineWords(transcripts: transcripts) {
            if let edit = captions.edits.last(where: { $0.covers(w.mediaId, w.wordIndex) }) {
                if let r = run, r.edit == edit, r.words.last?.clipId == w.clipId {
                    run!.words.append(w)
                } else {
                    flush()
                    run = (edit, [w])
                }
                continue
            }
            flush()
            let norm = w.text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)).lowercased()
            if hidden.contains(norm) { continue }
            var text = w.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let rep = replacements[norm] {
                let trailing = String(text.reversed().prefix { $0.isPunctuation }.reversed())
                text = rep + trailing
            }
            if style.uppercase { text = text.uppercased() }
            guard !text.isEmpty else { continue }
            words.append(CaptionWord(text: text, start: w.start, end: w.end, anchor: "\(w.mediaId).w\(w.wordIndex)"))
        }
        flush()
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
                if gap > 0.6 || current.count >= perSegment || tooLong || endsSentence || w.breakBefore {
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
                    let merged = CaptionWord(text: (captions.style.uppercase ? value.uppercased() : value) + trailing, start: words[i].start, end: words[i + parts.count - 1].end, anchor: words[i].anchor, breakBefore: words[i].breakBefore)
                    words.replaceSubrange(i..<(i + parts.count), with: [merged])
                }
                i += 1
            }
        }
    }
}

extension Clip {
    /// Transform at a time relative to the clip start, with animation and fades applied.
    public func resolvedTransform(at local: Seconds) -> Transform {
        var t = transform
        if !anim.isEmpty {
            t.scale = number("transform.scale", at: local, default: t.scale)
            t.x = number("transform.x", at: local, default: t.x)
            t.y = number("transform.y", at: local, default: t.y)
            t.rotation = number("transform.rotation", at: local, default: t.rotation)
            t.opacity = number("transform.opacity", at: local, default: t.opacity)
            t.crop.left = number("transform.crop.left", at: local, default: t.crop.left)
            t.crop.top = number("transform.crop.top", at: local, default: t.crop.top)
            t.crop.right = number("transform.crop.right", at: local, default: t.crop.right)
            t.crop.bottom = number("transform.crop.bottom", at: local, default: t.crop.bottom)
            t.anchorX = number("transform.anchor_x", at: local, default: t.anchorX)
            t.anchorY = number("transform.anchor_y", at: local, default: t.anchorY)
            t.rotateX = number("transform.rotate_x", at: local, default: t.rotateX)
            t.rotateY = number("transform.rotate_y", at: local, default: t.rotateY)
            t.perspective = number("transform.perspective", at: local, default: t.perspective)
        }
        var fade = 1.0
        if fadeIn > 0 { fade = min(fade, local / fadeIn) }
        if fadeOut > 0 { fade = min(fade, (duration - local) / fadeOut) }
        t.opacity *= min(max(fade, 0), 1)
        return t
    }
}
